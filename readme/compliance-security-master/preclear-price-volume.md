# Preclear, price and volume helpers

Small endpoints the compliance rules engine calls while it checks trades and preclearance requests.
Code: `controllers/securityController.ts`, `services/securityService.ts`, `services/preclearService.ts`, SQL in `utils/queries.ts`.

Related docs: `api-reference.md`, `data-and-replication.md`, `../compliance-rules-engine/security-master.md`, `../compliance-rules-engine/preclear-rules-engine.md`.

| Endpoint (prefix `/security-master/factset`) | DB | Answer |
|---|---|---|
| `GET /get-preclear-expiration-date` | ADMIN + RDS | Last day a preclearance is valid |
| `GET /security-preclear-match` | RDS | Is the traded security the precleared one? |
| `GET /security-price` | RDS (recent) / Redshift (older) | Price on or before a date |
| `GET /security-average-daily-volume` | Redshift | Average daily traded volume |
| `POST /fetch-healthcare-sic-codes` | RDS | Is the company in a healthcare SIC code? |

---

## 1. Preclear expiration date

`GET /get-preclear-expiration-date?preclear_approval_date=2026-11-20&pdl_client_code=sand&no_of_days=5`

### Input
| Param | Rule |
|---|---|
| `preclear_approval_date` | required, ISO date; only the `YYYY-MM-DD` part is used |
| `pdl_client_code` | required, lowercased |
| `no_of_days` | optional number. Given → `max(floor(n), 0)` is the window. Missing / empty → read from the client config |

### Window from client config (`preclearService.getClientsApprovalBus`)
ADMIN DB:
```sql
SELECT COALESCE((parameters->>'APPROVAL_WINDOW_BUS_DAYS')::int, 0)
FROM rulesenginedb.trade_configs_v2
WHERE client_id = $1
  AND version = (SELECT trade_config_version FROM rulesenginedb.clients_v2 WHERE id = $1 LIMIT 1)
```
- `client_id` / `id` are `CITEXT`, so the lowercased code still matches (see `../compliance-rules-engine/client-config.md`).
- No row or any DB error → **0** (error only logged).

### Algorithm (`prclrExpNewDate`)
1. `expiration` = the N-th business day from the approval date. Day 0 = approval date, or the next Monday if it falls on a weekend. Weekends are skipped.
2. Count **NASDAQ** holidays (`ref_calendar_holidays`, `fref_exchange_code = 'NASQ'`) in `[start, expiration]` (RDS).
3. Count = 0 → done. Else: `start = expiration`, `N = count`, repeat; later passes count from `start + 1`.
4. At most 5 passes; not settled → error → **500**.

Returns `[{ "preclear_expiration_date": "YYYY-MM-DD" }]`.

**Example:** approval Fri 2026-11-20, window 5 → Fri 2026-11-27. Thanksgiving (Thu 11-26) is in range → 1 more business day from 11-27 → **Mon 2026-11-30**. Next range 11-28..11-30 has no holiday → done.

Notes:
- Only the NASDAQ calendar is used, for all clients and all markets.
- A holiday on the approval date itself is counted and extends the window by one day.

---

## 2. Preclear match

`GET /security-preclear-match?preclear_sec_id=<fsym_id>&trade_sec_id=<fsym_id>`

```sql
SELECT EXISTS (SELECT 1 FROM all_securities preclear
               JOIN all_securities trade ON trade.fsym_security_id = preclear.fsym_security_id
               WHERE preclear.fsym_id = $1 AND trade.fsym_id = $2) AS matched
```
- Returns `true` / `false` (in `data`).
- True when both ids belong to the same share class, e.g. a preclear on `AAPL-US` (`-R`) covers a trade on another listing (`-L`) of the same `-S` id.
- Custom (`-SS`) and futures ids are not in `all_securities` → always `false`, even for the same id (inferred; whether the caller compares equal ids first is not in this repo).

---

## 3. Security price

`GET /security-price?date=2026-11-02&security_id=MH33D6-R&currency_code=USD`

| Param | Rule |
|---|---|
| `date` | required ISO date |
| `security_id` | required, any `fsym_id` grain |
| `currency_code` | 3 letters, uppercased, default `USD` |

### Routing
`date` older than **today (UTC) − 7 days** → Redshift, else RDS. Reason: RDS `security_prices` holds only recent history (see `data-and-replication.md` §3).

| | RDS (`securityPriceDataRds`) | Redshift (`securityPriceDataQuery`) |
|---|---|---|
| Ids searched | all `fsym_id`s of the input's share class (sub-select on `all_securities`) | same, fetched first through `securityMatch()` on RDS; none → 404 |
| Table | `security_prices` | `factsetdb1.fgp_v1.fgp_global_prices` |
| Window | `price_date` in `[date − 30 days, date]`, same currency | same |
| Pick | latest `price_date`, then highest `volume` | same |

Returns one row `{ fsym_id, price_date, currency, price, price_high, price_low, price_open }`. No row → **404** `No security price data found for the given parameters`.

- The price can be up to 30 days old, and can come from any listing of the share class (the one with the highest volume that day).
- The rules engine reads `data.price` and uses `0` on any error (`../compliance-rules-engine/security-master.md`).

---

## 4. Average daily volume

`GET /security-average-daily-volume?security_id=MH33D6-R&lookback_days=20`

- `lookback_days`: integer 1–180, default 20.
- Redshift query `getAverageDailyVolumeQ`:
  1. find the share class (`fsym_security_id`) of `security_id` in `sym_coverage`;
  2. take all its **regional** ids (`regional_flag = 1`) — all exchanges;
  3. read `fgp_global_prices.volume` for the last `lookback_days × 3` calendar days up to **today** (not a given date);
  4. per id and day, `MAX(volume)` (removes currency duplicates); per day, `SUM` across regions;
  5. keep the most recent `lookback_days` days that have volume; average them.
- Always 200:
  ```json
  { "security_id": "MH33D6-R", "average_daily_volume": 51234567.5, "lookback_days": 20,
    "days_used": 20, "window_start": "2026-10-08", "window_end": "2026-11-04" }
  ```
  No FactSet data → `average_daily_volume: null`, `days_used: 0`. The caller should skip the rule then (code comment).
- `days_used` can be smaller than `lookback_days` (halts, new listings).

---

## 5. Healthcare SIC check

`POST /fetch-healthcare-sic-codes` with `{ "entityId": "000C7F-E", "sicCodes": ["80%", "283%", "64%"] }`

- `sicCodes` are joined with `|` and used as a `SIMILAR TO` pattern: `'80%|283%|64%'`.
- Entity id is resolved through `sym_merged_entity_id` first.
- RDS `entity_base_info.primary_sic_code` (from FactSet `sym_entity_sector`).
- Returns `[{ factset_entity_id, current_entity_id, primary_sic_code }]` when it matches, else `[]`. Empty `sicCodes` → `[]`.
- The rules engine treats a non-empty list as "healthcare" (`../compliance-rules-engine/security-master.md`).
- The code list comes from the caller. `utils/queries.ts:healthcareSicCodes` (80, 64, 283, 632 on Redshift) is not used.

---

## 6. Notes and unknowns

- Expiration uses only the NASDAQ holiday calendar; a holiday table that is empty or stale gives a too-early date. `refresh_ref_calendar_holidays()` aborts the swap if the source returns 0 rows, but its schedule is not in the repo.
- Price routing uses the server clock (UTC); a request for "8 days ago" goes to Redshift.
- `SIMILAR TO` treats `_`, `|`, `*`, `+`, `(`, `[` as pattern characters; codes are expected to be digits plus `%`.
