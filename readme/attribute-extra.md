# How attributes work (`attribute_extra`)

Client DB, rules-engine-3.0. Source: `storage/repositories/clientDb/RestrictionRepository.ts`, `serverless/public/functions/tradeProcessV2/service.ts`.

## Model: EAV (entity–attribute–value)

Records do not have a column per property. A record is a thin header row; every property is a separate row in `attribute_extra`.

| Table | Role |
|---|---|
| `disclosures` | Header for disclosure records: `disc_id`, `disc_type`, audit fields, `is_active`. No business values. |
| `disclosure_types` | `disc_type_id` → name, e.g. `RESTRICTION`. |
| `attribute_extra_types` | Attribute catalog: `attribute_extra_type_id` → `attribute_type` name (`SECURITY_ID`, `CID`, `STATUS`, `RESTRICTION_LIST_ID`, `ACCOUNT_MANAGED`, …). |
| `attribute_extra` | The values: `attribute_id` (owner record id), `attribute_extra_type_id`, `attribute_value` (text), `created_date`, `is_active`. |

```
disclosures (disc_id = '101', disc_type → RESTRICTION)
   │
   └─ attribute_extra (attribute_id = '101')
        ├─ type → SECURITY_ID          value = 'SEC-AAPL-COMMON'
        ├─ type → RESTRICTION_LIST_ID  value = '7'
        └─ type → STATUS               value = 'Active'
```

Key points:
- `attribute_id` is a generic owner id — a `disc_id` for disclosures, an account id for accounts (see `isAccountManaged`).
- `attribute_value` is always text → compare with casts, e.g. `rl.restriction_list_id::text`.
- Type ids differ per DB, so queries resolve them by name first:

```sql
WITH attr_types AS (
    SELECT
        (SELECT attribute_extra_type_id FROM attribute_extra_types WHERE attribute_type = 'CID')         AS cid_type,
        (SELECT attribute_extra_type_id FROM attribute_extra_types WHERE attribute_type = 'SECURITY_ID') AS security_id_type
)
```

## Inspect one record

```sql
SELECT ae.attribute_id, aet.attribute_type, ae.attribute_value, ae.created_date
FROM attribute_extra ae
JOIN attribute_extra_types aet ON aet.attribute_extra_type_id = ae.attribute_extra_type_id
WHERE ae.attribute_id = '<disc_id or account id>'
ORDER BY ae.created_date;
```

## Why `disclosures` is still joined

`attribute_extra` is shared by many record kinds (restrictions, preclearances, accounts, …) and does not say which kind a row belongs to. Only `disclosures.disc_type` does.

Example — trade in Apple:

| disc_id | disc_type | SECURITY_ID attribute |
|---|---|---|
| 101 | RESTRICTION | SEC-AAPL-COMMON |
| 205 | PRECLEARANCE | SEC-AAPL-COMMON |

A lookup by `SECURITY_ID` alone finds both. Joining `disclosures` + `disclosure_types ... AND dt.disc_type = 'RESTRICTION'` keeps only 101; without it an approved preclearance would count as a restriction hit. The inner join also drops orphan attribute rows.

## Example: restriction lookup (`RestrictionRepository.getRestrictions`)

1. **Candidates** (`buildCandidatesCte`) — disclosures pointing at the traded security, two ways:
   - by `SECURITY_ID` in `:securityIds` (traded security + `matched_securities`) — restriction on a specific instrument;
   - by `CID` in `:entityIds` (issuer) — restriction on the whole company, catches every instrument it issued.
   - `UNION` dedupes. The CID branch is omitted when `entityIds` is empty (`IN ()` is invalid in Postgres).
2. **Type filter** — join `disclosures` / `disclosure_types`, keep `RESTRICTION`.
3. **List filter** — `RESTRICTION_LIST_ID` attribute → `restriction_lists`, name `LIKE ANY (:listNames)`.
4. **Status as of trade date** — a `STATUS = 'Active'` row created on/before `activeDate`, with no later `Cleared`/`Inactive` row before `activeDate`.
5. **Optional attributes** — with `include.attributes`, all attributes of each hit are aggregated into JSON (`[{attributeType, attributeValue}]`) for attribute-based rule filtering in `securityListRule`.

Data:

| attribute_id | type | value |
|---|---|---|
| 101 | SECURITY_ID | SEC-AAPL-COMMON |
| 101 | RESTRICTION_LIST_ID | 7 |
| 102 | CID | ENT-APPLE |
| 102 | RESTRICTION_LIST_ID | 7 |
| 103 | SECURITY_ID | SEC-MSFT-COMMON |

Trade in an Apple bond: `securityIds = ['SEC-AAPL-BOND', 'SEC-AAPL-COMMON']`, `entityIds = ['ENT-APPLE']` → candidates `{101, 102}` (103 excluded) → both hit list 7 if active.

## History via append-only rows

The restriction query assumes status changes are appended as new rows (not updated in place), ordered by `created_date`. Inferred from the query, not verified against the write side. This is what lets the query answer "was it active on the trade date?" for past dates.

Caveat: `disclosures.is_active` is **not** checked by the restriction query — activity comes only from `STATUS` rows. Intentional or a gap — not determined.
