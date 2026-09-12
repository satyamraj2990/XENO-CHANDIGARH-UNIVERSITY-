# Comm-Log Target Base Reconciliation

**SQLite-based reconciliation of merchant communication logs for the October 2026 Diwali campaign.**

This repository contains a reproducible, source-controlled version of the reconciliation workflow. The raw CSV files are loaded into a local SQLite database, then SQL business rules calculate the Finance-reportable `target_base`.

This project reconciles **30 raw communication-log records** against the Finance-reported `target_base` by applying campaign eligibility, processing, delivery, and retry-deduplication rules.

> **Final `target_base`: 22**

---

## 📌 Problem Statement

Merchant **501** has communication logs associated with its **Diwali campaigns** during **October 2026**.

The raw communication log contains **30 records**, but Finance reports a `target_base` of **22**.

The goal of this project is to determine **exactly how the raw count of 30 is reconciled to the final Finance-reportable count of 22**, while correctly handling:

* Campaign lifecycle states
* Processing status
* Delivery status
* Retry campaigns
* Parent-child campaign relationships
* Customer deduplication
* Repeated events in standalone campaigns


## 🎯 Final Result

| Metric                 |  Count |
| ---------------------- | -----: |
| Raw communication logs |     30 |
| Finance `target_base`  | **22** |

### Reconciliation Bridge

|      Step | Description               | Result | Reason                                     |
| --------: | ------------------------- | -----: | ------------------------------------------ |
|         0 | Naive count               | **30** | Starting point: all raw communication logs |
|         1 | Merchant & October filter | **30** | Scope to merchant `501` and October 2026   |
|         2 | Diwali campaign filter    | **30** | Keep campaigns matching `%Diwali%`         |
|         3 | Processing status         | **26** | Exclude campaigns awaiting approval        |
|         4 | Delivery status `900`     | **22** | Exclude failed/non-qualifying deliveries   |
|         5 | Retry deduplication       | **22** | Count retry customers once                 |
| **Final** | **Finance `target_base`** | **22** | **Final reportable target count**          |


## 📐 Business Rules

The reconciliation follows these rules:

1. **Merchant Scope**

   * Only merchant `501` is considered.

2. **Date Scope**

   * Only communication logs sent during **October 2026** are considered.
   * Date range:

     ```text
     2026-10-01 ≤ sent_time < 2026-11-01
     ```

3. **Campaign Scope**

   * Only campaigns whose names contain `Diwali` are included.
   * Matching rule:

     ```sql
     name LIKE '%Diwali%'
     ```

4. **Campaign Eligibility**

   * Campaigns must have:

     ```text
     creation_status IN
     ('approved', 'aborted', 'resumed', 'stopped')
     ```
   * Campaigns must have:

     ```text
     processing_status = 'processed'
     ```

5. **Communication Type**

   * Only campaign communications with:

     ```text
     communication_type = 2
     ```

     are included.

6. **Delivery Status**

   * Only successfully delivered communications are included:

     ```text
     delivery_status = 900
     ```

7. **Retry Deduplication**

   * Retry campaigns form parent-child relationships.
   * Customers appearing across the same retry family are counted **once**.

8. **Standalone Campaigns**

   * Repeated communication events are preserved for standalone campaigns.
   * Therefore, standalone campaigns use event-level counting rather than customer-level deduplication.

---

## 🔍 Key Insight

The most important part of the reconciliation is the handling of **retry campaigns**.

A retry campaign is linked to its original campaign through the `parent_id` relationship:

```text
Root Campaign
     │
     ├── Retry Campaign 1
     │       │
     │       └── Retry Campaign 2
     │
     └── Retry Campaign 3
```

The same customer may therefore appear in multiple communication logs within the same retry family.

### Example

```text
Customer 101
   │
   ├── Original campaign → Delivered
   ├── Retry campaign 1  → Delivered
   └── Retry campaign 2  → Delivered
```

A naive event count would produce:

```text
3 communications
```

But Finance should count:

```text
1 customer
```

Therefore, retry families use:

```sql
COUNT(DISTINCT customer_id)
```

while standalone campaigns preserve repeated events using:

```sql
COUNT(log_id)
```

---

## 🧠 Reconciliation Logic

The final query performs the reconciliation in several stages.

### 1. Select eligible campaigns

First, campaigns are filtered by merchant, campaign name, creation status, and processing status.

```sql
eligible_campaigns AS (
    SELECT c.id, c.parent_id, c.name
    FROM campaign AS c
    WHERE c.merchant_id = 501
      AND c.name LIKE '%Diwali%'
      AND c.creation_status IN (
          'approved',
          'aborted',
          'resumed',
          'stopped'
      )
      AND c.processing_status = 'processed'
)
```

### 2. Resolve retry families

A recursive CTE walks through the parent-child campaign relationships and maps every retry campaign back to its root campaign.

```sql
campaign_ancestors (campaign_id, root_id) AS (
    SELECT id, id
    FROM eligible_campaigns
    WHERE parent_id IS NULL

    UNION ALL

    SELECT child.id, parent.root_id
    FROM eligible_campaigns AS child
    JOIN campaign_ancestors AS parent
      ON child.parent_id = parent.campaign_id
)
```

This allows the query to treat:

```text
Original → Retry → Retry → Retry
```

as a single campaign family.

### 3. Filter qualifying deliveries

Only communication logs satisfying the reporting rules are retained:

```sql
communication_type = 2
delivery_status = 900
merchant_id = 501
sent_time within October 2026
```

### 4. Identify retry families

The query determines whether each campaign root has retry descendants.

```sql
EXISTS (
    SELECT 1
    FROM eligible_campaigns AS child
    WHERE child.parent_id = root_id
)
```

### 5. Calculate the contribution

The final aggregation applies different counting rules:

```sql
CASE
    WHEN is_retry_family
        THEN COUNT(DISTINCT customer_id)
    ELSE COUNT(log_id)
END
```

This gives the correct Finance-reportable contribution for each campaign family.

---

## 🗃️ Project Structure

```text
comm-log-target-base-reconciliation/
│
├── data/
│   ├── raw/
│   │   ├── campaign.csv
│   │   └── communication_log.csv
│   │
│   └── comm_log.db
│
├── sql/
│   ├── 01_schema_init.sql
│   ├── 02_investigation.sql
│   └── 03_final_reconciliation.sql
│
├── src/
│   └── ingest_csv.py
│
├── architecture.md
└── README.md
```

### File Overview

| File                              | Purpose                                         |
| --------------------------------- | ----------------------------------------------- |
| `data/raw/campaign.csv`           | Source campaign data                            |
| `data/raw/communication_log.csv`  | Source communication-log data                   |
| `data/comm_log.db`                | Generated local SQLite database (not committed)  |
| `sql/01_schema_init.sql`          | SQLite schema and CSV import alternative        |
| `sql/02_investigation.sql`        | Diagnostic and investigation queries            |
| `sql/03_final_reconciliation.sql` | Production-style recursive reconciliation query |
| `src/ingest_csv.py`               | Standard-library CSV → SQLite ingestion script  |
| `architecture.md`                 | Architecture and execution flow                 |
| `README.md`                       | Project documentation                           |

Each run recreates `data/comm_log.db` from the CSV inputs, so the generated database can be deleted and rebuilt at any time. The database is ignored by Git; the raw data, schema, investigation queries, and reconciliation query are the reproducible project inputs.

---

## ⚙️ Tech Stack

* **Python 3**
* **SQLite**
* **SQL**
* **CSV**
* Python Standard Library

The ingestion script intentionally uses Python's standard library rather than requiring external packages.

---

## 🚀 Getting Started

### Prerequisites

Make sure the following are installed:

* Python 3
* SQLite CLI *(optional if you only use the Python script)*

Verify Python:

```powershell
python --version
```

Verify SQLite:

```powershell
sqlite3 --version
```

---

## ▶️ Run the Reconciliation

From the project root:

```powershell
python src\ingest_csv.py
```

The script:

1. Reads both CSV source files.
2. Creates/populates the SQLite database.
3. Loads the campaign and communication-log data.
4. Runs the reconciliation.
5. Prints the reconciliation bridge.
6. Prints the final `target_base`.

### Expected Result

```text
Step | Description              | Result | Reason
-----+--------------------------+--------+------------------------------------
0    | Naive count              | 30     | (starting point) raw logs
1    | Merchant & Oct filter    | 30     | Scope to merchant 501 and Oct 2026
2    | Diwali campaign filter   | 30     | Filter to '%Diwali%' campaigns
3    | Processing status        | 26     | Exclude approval_awaiting campaigns
4    | Delivery status (900)    | 22     | Exclude failed deliveries (!= 900)
5    | Retry deduplication      | 22     | Retry once; keep standalone sends

target_base = 22
```

**No second command is required for the complete reconciliation.**

---

## 🔎 Run SQL Queries Directly

If you want to inspect individual query outputs, run:

### Investigation Queries

```powershell
sqlite3 data\comm_log.db < sql\02_investigation.sql
```

### Final Reconciliation

```powershell
sqlite3 data\comm_log.db < sql\03_final_reconciliation.sql
```

These commands are optional because `ingest_csv.py` already performs the complete workflow.

---

## 🏗️ Architecture

The project follows a simple ingestion → database → reconciliation pipeline:

```text
          ┌──────────────────────┐
          │   campaign.csv       │
          └──────────┬───────────┘
                     │
                     │
          ┌──────────▼───────────┐
          │    ingest_csv.py     │
          │                      │
          │ CSV → SQLite         │
          └──────────┬───────────┘
                     │
                     ▼
          ┌──────────────────────┐
          │    comm_log.db       │
          │                      │
          │ campaign             │
          │ communication_log    │
          └──────────┬───────────┘
                     │
                     ▼
          ┌──────────────────────┐
          │ Investigation SQL    │
          │        +             │
          │ Final Reconciliation │
          └──────────┬───────────┘
                     │
                     ▼
          ┌──────────────────────┐
          │ Finance target_base  │
          │                      │
          │         22           │
          └──────────────────────┘
```

---

## 🧩 Production Query

The final reconciliation uses a **recursive CTE** to resolve parent-child retry relationships.

```sql
WITH RECURSIVE

-- Select campaigns eligible for Finance reporting.
eligible_campaigns AS (
    SELECT c.id, c.parent_id, c.name
    FROM campaign AS c
    WHERE c.merchant_id = 501
      AND c.name LIKE '%Diwali%'
      AND c.creation_status IN (
          'approved',
          'aborted',
          'resumed',
          'stopped'
      )
      AND c.processing_status = 'processed'
),

-- Resolve every retry campaign to its root campaign.
campaign_ancestors (campaign_id, root_id) AS (
    SELECT id, id
    FROM eligible_campaigns
    WHERE parent_id IS NULL

    UNION ALL

    SELECT child.id, parent.root_id
    FROM eligible_campaigns AS child
    JOIN campaign_ancestors AS parent
      ON child.parent_id = parent.campaign_id
),

-- Keep delivered campaign logs within the reporting scope.
scoped_deliveries AS (
    SELECT
        cl.id AS log_id,
        cl.customer_id,
        ca.root_id
    FROM communication_log AS cl
    JOIN campaign_ancestors AS ca
      ON ca.campaign_id = cl.communication_id
    WHERE cl.merchant_id = 501
      AND cl.communication_type = 2
      AND cl.delivery_status = 900
      AND cl.sent_time >= '2026-10-01'
      AND cl.sent_time < '2026-11-01'
),

-- Mark roots that have retry descendants.
family_shape AS (
    SELECT
        root_id,
        EXISTS (
            SELECT 1
            FROM eligible_campaigns AS child
            WHERE child.parent_id = root_id
        ) AS is_retry_family
    FROM campaign_ancestors
    GROUP BY root_id
),

-- Deduplicate retry customers while preserving
-- standalone campaign events.
family_totals AS (
    SELECT
        d.root_id,
        CASE
            WHEN s.is_retry_family
                THEN COUNT(DISTINCT d.customer_id)
            ELSE COUNT(d.log_id)
        END AS target_base_contribution
    FROM scoped_deliveries AS d
    JOIN family_shape AS s
      ON s.root_id = d.root_id
    GROUP BY
        d.root_id,
        s.is_retry_family
)

SELECT SUM(target_base_contribution) AS target_base
FROM family_totals;
```

---

## 📊 Observations & Findings

### Retry Campaigns

Retry campaigns form **parent-child chains**.

A customer may therefore appear in multiple campaign logs belonging to the same retry family.

These customers must be counted only once across the complete family.

### Failed Deliveries

Communication logs with a delivery status other than `900` remain present in the operational database but do not contribute to the Finance target base.

```text
delivery_status != 900
        ↓
Non-qualifying delivery
        ↓
Excluded from target_base
```

### Incomplete Campaign Lifecycles

Draft or approval-pending campaigns can contain rows that appear delivered.

However, those campaigns are not yet eligible for Finance reporting and are therefore excluded.

```text
Campaign not Finance-eligible
        ↓
Ignore associated logs
```

### Standalone Campaigns

Standalone campaigns do not have retry descendants.

Repeated qualifying events in these campaigns are intentionally preserved rather than deduplicated by customer.

---

## 📈 Reconciliation Summary

```text
30 Raw Logs
     │
     ▼
Merchant 501 + October 2026
     │
     ▼
30
     │
     ▼
Diwali Campaigns
     │
     ▼
30
     │
     ▼
Eligible Processing Status
     │
     ▼
26
     │
     ▼
Delivery Status = 900
     │
     ▼
22
     │
     ▼
Retry Deduplication
     │
     ▼
22
     │
     ▼
🎯 Finance target_base = 22
```

---

## 💡 Key Technical Concepts Demonstrated

This project demonstrates practical SQL/data-engineering concepts including:

* SQLite database creation
* CSV ingestion
* SQL filtering
* CTEs
* **Recursive CTEs**
* Parent-child hierarchy traversal
* Campaign-family resolution
* `COUNT(DISTINCT ...)`
* Conditional aggregation
* Data reconciliation
* Business-rule implementation
* Operational vs. Finance reporting logic
* Reproducible data pipelines

---

## 📝 Conclusion

The reconciliation demonstrates why a simple:

```sql
SELECT COUNT(*)
```

is not sufficient for determining the Finance `target_base`.

The final value of **22** is obtained by applying the complete business logic:

```text
Raw Logs
   ↓
Merchant + Date Scope
   ↓
Diwali Campaign Scope
   ↓
Campaign Eligibility
   ↓
Processed Campaigns
   ↓
Successful Deliveries
   ↓
Retry-Family Deduplication
   ↓
Finance target_base
```

### Final Answer

> **`target_base = 22`**

---

## 👤 Project Purpose

This project was built to demonstrate how raw operational communication data can be transformed into a **Finance-reportable metric using explicit business rules and reproducible SQL logic**.
