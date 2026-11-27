"""Create the WaterWatch database.

    python init_db.py                  # create tables (safe to re-run)
    python init_db.py --sample         # create tables + demo data
    python init_db.py --reset --sample # delete the database file first
"""

import argparse
import sqlite3
from pathlib import Path

from database import DB_PATH, SAMPLE_DATA_PATH, SCHEMA_PATH, get_connection

TABLES = [
    "clients", "sites", "water_meters", "readings", "thresholds",
    "alerts", "devices", "valves", "valve_commands",
]


def init_db(db_path: Path = DB_PATH, with_sample: bool = False, reset: bool = False) -> None:
    db_path = Path(db_path)
    if reset:
        for suffix in ("", "-wal", "-shm"):
            Path(str(db_path) + suffix).unlink(missing_ok=True)

    conn = get_connection(db_path)
    try:
        conn.executescript(SCHEMA_PATH.read_text(encoding="utf-8"))
        if with_sample:
            try:
                conn.executescript(SAMPLE_DATA_PATH.read_text(encoding="utf-8"))
            except sqlite3.IntegrityError as exc:
                conn.rollback()
                raise SystemExit(
                    f"Sample data could not be loaded ({exc}). "
                    "The database probably already contains it; use --reset."
                )
        print(f"Database ready: {db_path}")
        for table in TABLES:
            count = conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
            print(f"  {table:<15} {count:>5} rows")
    finally:
        conn.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Initialise the WaterWatch SQLite database.")
    parser.add_argument("--sample", action="store_true", help="load demonstration data")
    parser.add_argument("--reset", action="store_true", help="delete the existing database first")
    args = parser.parse_args()
    init_db(with_sample=args.sample, reset=args.reset)
