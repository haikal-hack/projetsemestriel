"""SQLite connection helpers for WaterWatch.

Usage:
    from database import get_connection

    conn = get_connection()
    rows = conn.execute("SELECT * FROM water_meters").fetchall()
    print(rows[0]["meter_name"])      # rows behave like dictionaries
    conn.close()

The database file is ``waterwatch.db`` next to this file. Set the
``WATERWATCH_DB`` environment variable to use another path.
"""

import os
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
DB_PATH = Path(os.environ.get("WATERWATCH_DB", BASE_DIR / "waterwatch.db"))
SCHEMA_PATH = BASE_DIR / "schema.sql"
SAMPLE_DATA_PATH = BASE_DIR / "sample_data.sql"

# A command that is not confirmed by the (virtual) ESP32 within this delay
# is marked EXPIRED by expire_stale_commands().
COMMAND_TIMEOUT_SECONDS = 30

ISO_FORMAT = "%Y-%m-%dT%H:%M:%SZ"


def utc_now_iso() -> str:
    """Current time in UTC, ISO 8601, e.g. '2026-11-27T09:30:00Z'."""
    return datetime.now(timezone.utc).strftime(ISO_FORMAT)


def get_connection(db_path=None) -> sqlite3.Connection:
    """Open a connection with the settings WaterWatch relies on."""
    conn = sqlite3.connect(db_path or DB_PATH, timeout=10, check_same_thread=False)
    conn.row_factory = sqlite3.Row            # access columns by name
    conn.execute("PRAGMA foreign_keys = ON")  # SQLite ignores FKs unless enabled per connection
    conn.execute("PRAGMA journal_mode = WAL") # lets Streamlit read while a simulator writes
    conn.execute("PRAGMA busy_timeout = 5000")
    return conn


# ---------------------------------------------------------------------
# Operations where several statements must succeed together.
# `with conn:` = one transaction: COMMIT if the block succeeds, ROLLBACK if it raises.
# ---------------------------------------------------------------------
def confirm_valve_command(conn: sqlite3.Connection, command_id: int, executed_at: str | None = None) -> None:
    """Call this ONLY when the ESP32 (virtual or real) has confirmed execution.

    In one transaction it marks the command CONFIRMED and updates the valve's
    confirmed state. A command that is not in SENT status cannot be confirmed.
    """
    executed_at = executed_at or utc_now_iso()
    with conn:
        cur = conn.execute(
            "UPDATE valve_commands SET status = 'CONFIRMED', executed_at = ? "
            "WHERE id = ? AND status = 'SENT'",
            (executed_at, command_id),
        )
        if cur.rowcount != 1:
            raise ValueError(f"Command {command_id} does not exist or is not in SENT status")
        conn.execute(
            """
            UPDATE valves
               SET valve_status = (SELECT CASE command WHEN 'OPEN' THEN 'OPEN' ELSE 'CLOSED' END
                                     FROM valve_commands WHERE id = :cid),
                   last_status_update = :ts
             WHERE id = (SELECT valve_id FROM valve_commands WHERE id = :cid)
            """,
            {"cid": command_id, "ts": executed_at},
        )


def expire_stale_commands(conn: sqlite3.Connection, timeout_seconds: int = COMMAND_TIMEOUT_SECONDS) -> int:
    """Mark as EXPIRED the commands that waited longer than the timeout.

    Returns the number of commands expired. The valve state is NOT changed:
    an unconfirmed command proves nothing about the physical valve.
    """
    cutoff = (datetime.now(timezone.utc) - timedelta(seconds=timeout_seconds)).strftime(ISO_FORMAT)
    with conn:
        cur = conn.execute(
            """
            UPDATE valve_commands
               SET status = 'EXPIRED',
                   error_message = 'No confirmation received within ' || ? || ' seconds'
             WHERE (status = 'SENT'    AND sent_at      <= ?)
                OR (status = 'PENDING' AND requested_at <= ?)
            """,
            (timeout_seconds, cutoff, cutoff),
        )
        return cur.rowcount
