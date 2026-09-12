# Working Notes: Reconciliation Architecture

```text
+-------------------------------------------------------------+
|                 RAW INPUT AND INGESTION                    |
|                                                             |
|  data/raw/campaign.csv                                     |
|  data/raw/communication_log.csv                            |
|                         |                                   |
|                         v                                   |
|  src/ingest_csv.py                                         |
|  Python standard library: csv + sqlite3                    |
|                         |                                   |
|                         v                                   |
|  data/comm_log.db                                          |
|  +-------------------+      +-----------------------------+ |
|  | campaign          |      | communication_log           | |
|  | id                |      | communication_id           | |
|  | parent_id         |      | customer_id                 | |
|  | creation_status   |      | delivery_status             | |
|  | processing_status |      | sent_time                   | |
|  +-------------------+      +-----------------------------+ |
+-------------------------------------------------------------+
                              |
                              v
+-------------------------------------------------------------+
|                     JOIN TABLES                             |
|                                                             |
|  campaign.id = communication_log.communication_id           |
|  Scope: merchant_id = 501                                   |
|  Scope: communication_type = '2'                            |
|  Scope: campaign name LIKE '%Diwali%'                       |
|  Naive count: 30 rows                                       |
+-------------------------------------------------------------+
                              |
                              v
+-------------------------------------------------------------+
|                 FILTER: DATE LIMITS                         |
|                                                             |
|  sent_time >= '2026-10-01'                                  |
|  sent_time <  '2026-11-01'                                  |
|  Half-open interval captures all October timestamps          |
|  Rows retained: 30                                          |
+-------------------------------------------------------------+
                              |
                              v
+-------------------------------------------------------------+
|              FILTER: CAMPAIGN ELIGIBILITY                   |
|                                                             |
|  creation_status IN                                         |
|    ('approved', 'aborted', 'resumed', 'stopped')             |
|  processing_status = 'processed'                            |
|  Exclude approval_awaiting campaign rows                    |
|  [Drops 4 approval-pending rows]                            |
|  Rows retained: 26                                          |
+-------------------------------------------------------------+
                              |
                              v
+-------------------------------------------------------------+
|             FILTER: REMOVE FAILED STATUS                    |
|                                                             |
|  communication_type = 2                                    |
|  Keep delivery_status = 900                                |
|  Exclude non-900 delivery rows                             |
|  [Drops 4 failed send attempts]                             |
|  Rows retained: 22                                          |
+-------------------------------------------------------------+
                              |
                              v
+-------------------------------------------------------------+
|              RESOLVE RETRY CAMPAIGN CHAINS                  |
|                                                             |
|  Recursive CTE follows campaign.parent_id                   |
|  Root campaign identifies the underlying communication       |
|  Example: Campaign A -> Retry B -> Retry C                  |
+-------------------------------------------------------------+
                              |
                              v
+-------------------------------------------------------------+
|          DEDUPLICATE RETRY-FAMILY CUSTOMERS                 |
|                                                             |
|  Retry family: COUNT(DISTINCT customer_id)                  |
|  One customer counts once across retry campaigns             |
|  [No additional reduction after eligibility filtering]      |
|  Contribution remains: 22                                   |
+-------------------------------------------------------------+
                              |
                              v
+-------------------------------------------------------------+
|          PRESERVE STANDALONE CAMPAIGN EVENTS                |
|                                                             |
|  No retry descendants: COUNT(log_id)                       |
|  Legitimate repeated standalone sends remain separate        |
+-------------------------------------------------------------+
                              |
                              v
+=============================================================+
|                    FINAL OUTPUT LAYER                       |
|                                                             |
|                    target_base: 22                          |
|                                                             |
+=============================================================+
```

## Methodology Breakdown

The reconciliation starts with a naive join between `campaign` and
`communication_log`. The join is scoped to merchant `501`, campaign communications,
Diwali campaign names, and October 2026. This produces 30 operational log rows.

The delivery filter keeps status `900` and removes four failed attempts with status
`1100`, leaving 26 rows. The campaign eligibility filter then removes four rows from
the `approval_awaiting` campaign because Finance reports only campaigns whose
creation workflow is finalized and whose processing workflow is complete.

The final SQL uses a recursive CTE to follow `campaign.parent_id` and map every
eligible retry campaign to its root campaign. Customers are counted once across a
retry family, while repeated events in a genuinely standalone campaign remain
separate. The final reconciliation therefore returns `target_base = 22`.

## Runtime Output

`src/ingest_csv.py` creates `data/comm_log.db`, imports 7 campaign rows and 30
communication-log rows, prints the six-step bridge in a compact table, and ends
with `target_base = 22`. The bridge is cumulative: lifecycle eligibility reduces
the count from 30 to 26, delivered-status filtering reduces it to 22, and retry
deduplication preserves the final value of 22.