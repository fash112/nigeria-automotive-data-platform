"""
Lands raw CSV source extracts into the bronze layer.

Bronze rules:
  * data is written exactly as received
  * nothing is cleaned, cast, filtered or joined
  * every file is partitioned by ingest date
  * an _ingested_at column is added for SLA monitoring

Locally this writes to a DuckDB file. In Azure the same logic writes
Parquet to ADLS Gen2 under bronze/{source}/{entity}/ingest_date=YYYY-MM-DD/.
"""

from datetime import date
from pathlib import Path

import duckdb
import pandas as pd

RAW = Path("data/raw")
DB = Path("data/warehouse.duckdb")

SOURCES = {
    "dms": {
        "work_orders": "dms_work_orders.csv",
        "work_order_lines": "dms_work_order_lines.csv",
        "technicians": "dms_technicians.csv",
    },
    "erp": {
        "parts": "erp_parts.csv",
        "stock_movements": "erp_stock_movements.csv",
        "suppliers": "erp_suppliers.csv",
    },
    "crm": {"customers": "crm_customers.csv", "vehicles": "crm_vehicles.csv"},
    "pos": {"invoices": "pos_invoices.csv", "payments": "pos_payments.csv"},
    "telematics": {"events": "telematics_events.csv"},
}


def main() -> None:
    DB.parent.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(str(DB))

    for source, tables in SOURCES.items():
        con.execute(f"create schema if not exists bronze_{source}")

        for table, filename in tables.items():
            path = RAW / filename
            if not path.exists():
                print(f"  skip {source}.{table} — {filename} not found")
                continue

            df = pd.read_csv(path, dtype=str)
            if "_ingested_at" not in df.columns:
                df["_ingested_at"] = pd.Timestamp.now("UTC").strftime("%Y-%m-%d %H:%M:%S")
            df["_ingest_date"] = date.today().isoformat()

            con.execute(f"drop table if exists bronze_{source}.{table}")
            con.register("incoming", df)
            con.execute(f"create table bronze_{source}.{table} as select * from incoming")
            print(f"  loaded bronze_{source}.{table:<16} {len(df):>8,} rows")

    con.close()
    print(f"\nBronze layer written to {DB.resolve()}")


if __name__ == "__main__":
    main()
