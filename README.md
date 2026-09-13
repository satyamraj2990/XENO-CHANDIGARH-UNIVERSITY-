# Comm-Log Target Base Reconciliation

**SQLite + SQL reconciliation of merchant communication logs to determine the Finance-reportable `target_base`.**

This project investigates **30 raw communication-log records** for **Merchant 501's October 2026 Diwali campaigns** and reconciles them to the Finance-reported target base.

> **Final `target_base`: 22**

---

## Problem Statement

Finance reports a `target_base` of **22**, while the raw communication logs contain **30 records**.

The objective is to determine **why 30 ≠ 22** and build a reproducible SQL-based reconciliation that correctly handles:

* Campaign eligibility
* Processing status
* Delivery status
* Retry campaigns
* Parent-child campaign relationships
* Customer deduplication
* Repeated events in standalone campaigns

The important question was not simply:

```sql
SELECT COUNT(*)
```

but rather:

> **Which communication records are actually eligible for Finance reporting, and how should retry records be counted?**

---

# Final Reconciliation

| Step                 | Rule Applied                                |  Count | Impact               |
| -------------------- | ------------------------------------------- | -----: | -------------------- |
| Raw logs             | Starting dataset                            | **30** | Baseline             |
| Merchant + October   | Merchant `501`, October 2026                | **30** | No change            |
| Diwali campaigns     | `name LIKE '%Diwali%'`                      | **30** | No change            |
| Campaign eligibility | Approved/valid + processed                  | **26** | 4 excluded           |
| Successful delivery  | `delivery_status = 900`                     | **22** | 4 excluded           |
| Retry deduplication  | Deduplicate customers within retry families | **22** | No further reduction |

### Final Answer

```text
Finance target_base = 22
```

The reconciliation therefore explains the entire **30 → 22** difference.

---

# Audit Trail & Investigation

The final query was not written by assuming that `22` was simply a filtered count. The dataset was investigated step by step to identify where the mismatch originated.

### Investigation 1: Naive Count

The first check was simply:

```sql
SELECT COUNT(*)
FROM communication_log;
```

Result:

```text
30
```

This confirmed the raw starting point but did not explain Finance's `22`.

---

### Investigation 2: Campaign Eligibility

The next investigation joined communication logs with campaign metadata and checked campaign lifecycle states.

This revealed that some communication records were associated with campaigns that were **not Finance-eligible**, including campaigns still awaiting approval.

The important finding was:

```text
Communication log exists
        ↓
Campaign is not Finance-eligible
        ↓
Log must not contribute to target_base
```

This reduced the working population from:

```text
30 → 26
```

---

### Investigation 3: Delivery Status

The remaining records were checked against delivery status.

Only:

```text
delivery_status = 900
```

qualifies as a successful delivery.

This produced:

```text
26 → 22
```

At this point the Finance count was already reached.

---

### Investigation 4: Retry Campaigns

The remaining records were then investigated for duplicate customers across retry campaigns.

A retry campaign is connected to its original campaign through:

```text
parent_id
```

Example:

```text
Original Campaign
       │
       ├── Retry 1
       │      │
       │      └── Retry 2
       │
       └── Retry 3
```

A customer appearing in multiple campaigns within this family should contribute **once**, not once per communication event.

For example:

```text
Customer 101
   ├── Original → Delivered
   ├── Retry 1  → Delivered
   └── Retry 2  → Delivered
```

Naive event count:

```text
3
```

Finance count:

```text
1
```

Therefore retry families use:

```sql
COUNT(DISTINCT customer_id)
```

---

### Investigation 5: Why Not `DISTINCT` Everywhere?

An early/simple approach would be to apply:

```sql
COUNT(DISTINCT customer_id)
```

to the entire dataset.

That would be incorrect.

Standalone campaigns can legitimately contain multiple communication events for the same customer. Those events should remain separate.

Therefore the final logic is:

```text
Retry family
    → COUNT(DISTINCT customer_id)

Standalone campaign
    → COUNT(log_id)
```

This distinction is the key business rule behind the reconciliation.

---

# Business Rules

The final reconciliation applies the following rules:

### 1. Merchant

```text
merchant_id = 501
```

### 2. Reporting Period

```text
2026-10-01 ≤ sent_time < 2026-11-01
```

### 3. Campaign

```sql
name LIKE '%Diwali%'
```

### 4. Campaign Eligibility

```sql
creation_status IN (
    'approved',
    'aborted',
    'resumed',
    'stopped'
)
AND processing_status = 'processed'
```

### 5. Communication Type

```text
communication_type = 2
```

### 6. Successful Delivery

```text
delivery_status = 900
```

### 7. Retry Deduplication

Customers are counted once within the same retry family.

### 8. Standalone Campaigns

Repeated qualifying events are preserved at the event level.

---

# Solution Approach

The reconciliation is implemented as a sequence of SQL CTEs:

```text
Raw CSV
   ↓
SQLite
   ↓
Eligible Campaigns
   ↓
Retry Family Resolution
   ↓
Qualifying Deliveries
   ↓
Retry / Standalone Classification
   ↓
Conditional Counting
   ↓
target_base = 22
```

### Recursive CTE

A recursive CTE resolves parent-child campaign relationships:

```sql
WITH RECURSIVE campaign_ancestors AS (...)
```

This allows:

```text
Original → Retry → Retry → Retry
```

to be treated as one campaign family.

### Conditional Counting

The final aggregation applies different rules depending on campaign structure:

```sql
CASE
    WHEN is_retry_family
        THEN COUNT(DISTINCT customer_id)
    ELSE COUNT(log_id)
END
```

This prevents both:

* overcounting retry customers
* undercounting legitimate standalone events

---

# Project Structure

```text
comm-log-target-base-reconciliation/
│
├── data/
│   └── raw/
│       ├── campaign.csv
│       └── communication_log.csv
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

| File                          | Purpose                              |
| ----------------------------- | ------------------------------------ |
| `campaign.csv`                | Campaign source data                 |
| `communication_log.csv`       | Communication source data            |
| `01_schema_init.sql`          | Database schema                      |
| `02_investigation.sql`        | Investigation and diagnostic queries |
| `03_final_reconciliation.sql` | Final reconciliation logic           |
| `ingest_csv.py`               | CSV → SQLite ingestion               |
| `architecture.md`             | Visual solution architecture         |
| `README.md`                   | Project documentation                |

The generated SQLite database is intentionally not committed. It can be recreated from the source CSV files.

---

# Tech Stack

* Python 3
* SQLite
* SQL
* CSV
* Python Standard Library

No external Python packages are required.

---

# Run the Project

From the project root:

```bash
python src\ingest_csv.py
```

The script:

1. Reads the source CSV files.
2. Creates the SQLite database.
3. Loads the source data.
4. Executes the reconciliation workflow.
5. Prints the reconciliation bridge.
6. Outputs the final `target_base`.

Expected result:

```text
Raw logs                    30
Eligible campaigns          26
Successful deliveries       22
Final target_base           22
```

The complete reconciliation can be run with a single command.

---

# Inspect the SQL

For the investigation:

```bash
sqlite3 data\comm_log.db < sql\02_investigation.sql
```

For the final reconciliation:

```bash
sqlite3 data\comm_log.db < sql\03_final_reconciliation.sql
```

---

# Why This Solution?

The solution intentionally avoids treating the problem as a simple row-counting exercise.

It separates:

```text
Operational events
        ↓
Business eligibility
        ↓
Delivery qualification
        ↓
Campaign hierarchy
        ↓
Customer-level retry deduplication
        ↓
Finance reporting
```

This makes the reconciliation:

* **Reproducible**
* **Auditable**
* **Scalable**
* **Maintainable**
* **Easy to validate**

Most importantly, every reduction from **30 → 22** can be traced back to an explicit business rule.

---

# Key Technical Concepts

This project demonstrates:

* SQLite data ingestion
* SQL CTEs
* Recursive CTEs
* Parent-child hierarchy traversal
* Campaign-family resolution
* Conditional aggregation
* `COUNT(DISTINCT ...)`
* Business-rule implementation
* Data reconciliation
* Audit-trail thinking
* Operational vs Finance reporting logic

---

# Architecture

A detailed visual walkthrough of the solution is available in:

```text
architecture.md
```

It shows the complete flow from:

```text
CSV → Python ingestion → SQLite → SQL investigation
→ Retry hierarchy → Reconciliation → Finance target_base
```

---

# Final Result

```text
30 Raw Communication Logs
             ↓
     Campaign Eligibility
             ↓
             26
             ↓
    Successful Deliveries
             ↓
             22
             ↓
     Retry Deduplication
             ↓
     Finance target_base
             ↓
             22
```

> **Final Finance `target_base` = 22**

---

## Project Purpose

This project demonstrates how raw operational communication data can be transformed into a **Finance-reportable metric using explicit business rules, SQL reconciliation, hierarchical retry handling, and a reproducible data pipeline.**
