# Comm-Log Target Base Reconciliation

**SQLite-based reconciliation of merchant communication logs for the October 2026 Diwali campaign.**

This project determines how **30 raw communication-log records** reconcile to the Finance-reported **`target_base = 22`** using Python, SQLite, and SQL business rules.

> **🎯 Finance `target_base`: 22**

---

## 📌 Problem

Merchant **501** has communication logs for Diwali campaigns during October 2026.

The raw data contains **30 records**, but Finance reports **22**.

The task is to identify the business rules responsible for the difference and reproduce the Finance number reliably.

---

## 🔍 Investigation & Dead Ends

Three approaches were evaluated:

```text
┌──────────────────────────────────────────────────────────────────────┐
│                    INVESTIGATION FLOW                                │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ① Naive Count                                                       │
│                                                                      │
│     COUNT(*) → 30                                                    │
│     ❌ Mismatch: +8                                                  │
│     Ineligible campaigns and non-qualifying deliveries included      │
│                                                                      │
│                         ↓                                            │
│                                                                      │
│  ② Global Customer Deduplication                                    │
│                                                                      │
│     COUNT(DISTINCT customer_id) → 19                                 │
│     ❌ Mismatch: -3                                                  │
│     Valid repeated events in standalone campaigns were removed       │
│                                                                      │
│                         ↓                                            │
│                                                                      │
│  ③ Tiered Business Logic                                             │
│                                                                      │
│     Retry families → DISTINCT customer                               │
│     Standalone     → communication event                             │
│                                                                      │
│     ✅ Result: 22 — Exact Finance Match                              │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

**Key finding:** deduplication is required for retry families, but **must not be applied globally**.

---

## 📐 Business Rules

| Rule            | Condition                                   |
| --------------- | ------------------------------------------- |
| Merchant        | `merchant_id = 501`                         |
| Date            | `2026-10-01 ≤ sent_time < 2026-11-01`       |
| Campaign        | `name LIKE '%Diwali%'`                      |
| Creation status | `approved`, `aborted`, `resumed`, `stopped` |
| Processing      | `processed`                                 |
| Communication   | `communication_type = 2`                    |
| Delivery        | `delivery_status = 900`                     |
| Retry family    | `COUNT(DISTINCT customer_id)`               |
| Standalone      | `COUNT(log_id)`                             |

### Reconciliation

| Stage                 | Records |
| --------------------- | ------: |
| Raw logs              |  **30** |
| Eligible + processed  |  **26** |
| Successful deliveries |  **22** |
| Final Finance count   |  **22** |

---

## 🔗 Retry-Family Resolution

Retry campaigns are connected through `parent_id`.

```text
                 Root Campaign
                      │
              ┌───────┴───────┐
              ▼               ▼
           Retry 1          Retry 3
              │
              ▼
           Retry 2
```

A recursive CTE maps every campaign to its root:

```sql
WITH RECURSIVE campaign_ancestors (campaign_id, root_id) AS (
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

The final aggregation applies the appropriate counting method:

```sql
CASE
    WHEN is_retry_family
        THEN COUNT(DISTINCT customer_id)
    ELSE COUNT(log_id)
END
```

---

## 🏗️ Architecture

```text
┌──────────────────────┐
│     Raw CSV Files    │
│ campaign.csv         │
│ communication_log.csv│
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│    ingest_csv.py     │
│      CSV → SQLite    │
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│      comm_log.db     │
│ campaign             │
│ communication_log    │
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│ Investigation +      │
│ Final Reconciliation │
│        SQL           │
└──────────┬───────────┘
           │
           ▼
     Finance `22`
```

---

## 🗃️ Project Structure

```text
comm-log-target-base-reconciliation/
│
├── data/
│   └── raw/
│       ├── campaign.csv
│       └── communication_log.csv
│
├── sql/
│   └── finalresult.sql
│
├── src/
│   ├── __init__.py
│   └── ingest_csv.py
│
├── architecture.md
├── reconciliation_bridge.pdf
└── README.md
```

| File                              | Purpose                                         |
| --------------------------------- | ----------------------------------------------- |
| `data/raw/campaign.csv`           | Source campaign data                            |
| `data/raw/communication_log.csv`  | Source communication-log data                   |
| `data/comm_log.db`                | Generated local SQLite database (not committed)  |
| `sql/finalresult.sql`             | SQLite setup, diagnostics, and final reconciliation query |
| `src/__init__.py`                 | Python package marker                           |
| `src/ingest_csv.py`               | Standard-library CSV → SQLite ingestion script  |
| `architecture.md`                 | Architecture and execution flow                 |
| `reconciliation_bridge.pdf`       | Reconciliation reference document              |
| `README.md`                       | Project documentation                           |

Each run recreates `data/comm_log.db` from the CSV inputs, so the generated database can be deleted and rebuilt at any time. The database is ignored by Git; the raw data and `sql/finalresult.sql` are the reproducible project inputs.

---

## ⚙️ Tech Stack

**Python 3 · SQLite · SQL · CSV · Python Standard Library**

---

## 🚀 Run

From the project root:

```bash
python src\ingest_csv.py
```

Expected result:

```text
Raw communication logs : 30
Eligible + processed   : 26
Successful deliveries  : 22
Final target_base      : 22
```

Optional direct SQL execution:

```powershell
sqlite3 < sql\finalresult.sql
```

The SQL script expects to be run from the project root and imports the CSV files using
relative paths. This command is optional because `ingest_csv.py` already performs the
complete workflow and prints the final `target_base`.
---

## 🧩 Technical Concepts

* Recursive CTEs
* Parent-child hierarchy traversal
* Retry-family resolution
* Conditional aggregation
* `COUNT(DISTINCT ...)`
* SQLite data modeling
* CSV ingestion
* SQL-based reconciliation
* Business-rule implementation
* Reproducible data pipelines

---

## 🏁 Result

The investigation established that neither a raw event count nor global customer deduplication matches Finance.

The correct rule is:

```text
Retry family → customer-level deduplication
Standalone   → event-level counting
```

**Final Finance `target_base = 22`.**
