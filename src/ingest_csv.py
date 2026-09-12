import argparse
import csv
import sqlite3
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent


def data_path(filename: str) -> Path:
    raw_path = PROJECT_ROOT / "data" / "raw" / filename
    return raw_path if raw_path.exists() else PROJECT_ROOT / "data" / filename


DEFAULT_CAMPAIGN_CSV = data_path("campaign.csv")
DEFAULT_LOG_CSV = data_path("communication_log.csv")
DEFAULT_DATABASE = PROJECT_ROOT / "data" / "comm_log.db"


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open("r", newline="", encoding="utf-8-sig") as csv_file:
        return list(csv.DictReader(csv_file))


def nullable_integer(value: str) -> int | None:
    return int(value) if value else None


def convert(campaign_csv: Path, log_csv: Path, database: Path) -> tuple[int, int]:
    campaigns = read_csv(campaign_csv)
    communication_logs = read_csv(log_csv)

    database.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(database) as connection:
        connection.executescript(
            """
            DROP TABLE IF EXISTS campaign;
            DROP TABLE IF EXISTS communication_log;

            CREATE TABLE campaign (
                id INTEGER,
                merchant_id INTEGER,
                parent_id INTEGER,
                name TEXT,
                creation_status TEXT,
                processing_status TEXT
            );

            CREATE TABLE communication_log (
                id INTEGER,
                merchant_id INTEGER,
                communication_id INTEGER,
                customer_id TEXT,
                communication_type INTEGER,
                delivery_status INTEGER,
                sent_time TEXT,
                scheduled_time TEXT,
                credit_used INTEGER,
                channel TEXT
            );
            """
        )
        connection.executemany(
            """
            INSERT INTO campaign
                (id, merchant_id, parent_id, name, creation_status, processing_status)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                (
                    int(row["id"]),
                    int(row["merchant_id"]),
                    nullable_integer(row["parent_id"]),
                    row["name"],
                    row["creation_status"],
                    row["processing_status"],
                )
                for row in campaigns
            ),
        )
        connection.executemany(
            """
            INSERT INTO communication_log
                (id, merchant_id, communication_id, customer_id,
                 communication_type, delivery_status, sent_time,
                 scheduled_time, credit_used, channel)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                (
                    int(row["id"]),
                    int(row["merchant_id"]),
                    int(row["communication_id"]),
                    row["customer_id"],
                    int(row["communication_type"]),
                    int(row["delivery_status"]),
                    row["sent_time"],
                    row["scheduled_time"],
                    int(row["credit_used"]),
                    row["channel"],
                )
                for row in communication_logs
            ),
        )

    return len(campaigns), len(communication_logs)


def print_reconciliation_bridge(database: Path) -> None:
    queries = [
        ("0", "Naive count", "SELECT COUNT(*) FROM communication_log", "(starting point) raw logs"),
        (
            "1",
            "Merchant & Oct filter",
            """
            SELECT COUNT(*)
            FROM communication_log AS cl
            WHERE cl.merchant_id = 501
              AND cl.sent_time >= '2026-10-01'
              AND cl.sent_time < '2026-11-01'
            """,
            "Scope to merchant 501 and Oct 2026",
        ),
        (
            "2",
            "Diwali campaign filter",
            """
            SELECT COUNT(*)
            FROM communication_log AS cl
            JOIN campaign AS c ON cl.communication_id = c.id
            WHERE cl.merchant_id = 501
              AND cl.sent_time >= '2026-10-01'
              AND cl.sent_time < '2026-11-01'
              AND c.name LIKE '%Diwali%'
            """,
            "Filter to '%Diwali%' campaigns",
        ),
        (
            "3",
            "Processing status",
            """
            SELECT COUNT(*)
            FROM communication_log AS cl
            JOIN campaign AS c ON cl.communication_id = c.id
            WHERE cl.merchant_id = 501
              AND cl.sent_time >= '2026-10-01'
              AND cl.sent_time < '2026-11-01'
              AND c.name LIKE '%Diwali%'
              AND c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
              AND c.processing_status = 'processed'
            """,
            "Exclude approval_awaiting campaigns",
        ),
        (
            "4",
            "Delivery status (900)",
            """
            SELECT COUNT(*)
            FROM communication_log AS cl
            JOIN campaign AS c ON cl.communication_id = c.id
            WHERE cl.merchant_id = 501
              AND cl.sent_time >= '2026-10-01'
              AND cl.sent_time < '2026-11-01'
              AND c.name LIKE '%Diwali%'
              AND c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
              AND c.processing_status = 'processed'
              AND cl.communication_type = 2
              AND cl.delivery_status = 900
            """,
            "Exclude failed deliveries (!= 900)",
        ),
    ]
    with sqlite3.connect(database) as connection:
        rows = []
        for step, description, query, reason in queries:
            result = connection.execute(query).fetchone()[0]
            rows.append((step, description, str(result), reason))
        final_query = (PROJECT_ROOT / "sql" / "03_final_reconciliation.sql").read_text(
            encoding="utf-8"
        )
        final_result = connection.execute(final_query).fetchone()[0]
        rows.append(
            (
                "5",
                "Retry deduplication",
                str(final_result),
                "Retry once; keep standalone sends",
            )
        )

    print("Step | Description              | Result | Reason")
    print("-----+--------------------------+--------+------------------------------------")
    for row in rows:
        step, description, result, reason = row
        print(f"{step:<4} | {description:<24} | {result:<6} | {reason}")
    print(f"target_base = {final_result}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--campaign-csv", type=Path, default=DEFAULT_CAMPAIGN_CSV)
    parser.add_argument("--log-csv", type=Path, default=DEFAULT_LOG_CSV)
    parser.add_argument("--database", type=Path, default=DEFAULT_DATABASE)
    args = parser.parse_args()

    campaign_count, log_count = convert(args.campaign_csv, args.log_csv, args.database)
    print(f"Created {args.database}")
    print(f"Imported {campaign_count} campaign rows and {log_count} communication-log rows.")
    print_reconciliation_bridge(args.database)


if __name__ == "__main__":
    main()