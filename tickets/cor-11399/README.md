# COR-11399 — Entity search: RDS (old) vs OpenSearch (new)

## Summary
- **OpenSearch is much faster under load.** At 100 requests/second it answers in about **0.3–0.6 s**
  on average; RDS takes **3.4–5 s**.
- **OpenSearch keeps up; RDS does not.** RDS could not handle about half of the requests at peak
  load; OpenSearch missed fewer than 4%.
- **No errors** on either side: every request that was sent returned a valid response.
- **Search results are mostly the same, with a few intended differences** (see below).

## Load test results
4 runs, the request rate ramped up to 100 requests/second (local app against shared dev databases).

| | RDS (old) | OpenSearch (new) |
|---|---|---|
| Average response time | 3.4 – 5.0 s | 0.3 – 0.6 s |
| Slowest 5% of requests take more than | 11.6 – 14.9 s | 0.9 – 1.8 s |
| Requests it couldn't keep up with (of ~3,450) | 1,495 – 1,898 | 63 – 120 |
| Failed requests | 0 | 0 |

Every run adds two rows (RDS, OpenSearch) to `entity-search-load.csv`.

Why: RDS checks every entity name for the search text on each request, so it slows down as traffic
grows. OpenSearch uses a search index built for this and stays fast.

## What changes for users
Results were compared on real data. Most searches return the same companies. Intended differences:

| Search | RDS (old) | OpenSearch (new) |
|---|---|---|
| Text inside a word, e.g. `apple` | also finds `Pineapple`, `Grapple` | finds only names with a word starting with `apple` |
| Several words, e.g. `tesla inc` | only the exact phrase | all words, in any order: also `AC Tesla, Inc.` |
| Punctuation, e.g. `coca-cola` | only `coca-cola` | also `Coca Cola` |
| Leading "the", e.g. `the walt disney` | needs "the" in the name | ignores "the" |
| Names starting with "The" | returned without "The" | returned as stored, with "The" |
| Order of results | exact match, then names starting with the term, then A–Z | same, but A–Z treats punctuation differently |

Open items:
- Decide whether the "The" difference in returned names is acceptable or needs a fix.
- 3 entities were found by only one side although their names match. This points to a data
  difference between the two databases; to be checked.

## How to run (for developers)
1. Start the local app with `REQUIRE_AUTH=false` and `LEGACY_ENTITY_SEARCH=true`
   (otherwise both endpoints use OpenSearch).
2. From this folder: `k6 run entity-search-load.js`

Files:
- `entity-search-load.js` — the load test.
- `search-terms.json` — searches used by the test.
- `entity-search-load.csv` — results, two rows per run.

⚠️ The test hits shared dev databases. Don't raise the 100 requests/second limit there, and avoid
running it while others are testing.
