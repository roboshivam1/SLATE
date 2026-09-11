import os
import sqlite3
from pathlib import Path

DB_PATH = os.getenv("SLATE_DB", "slate.db")
SCHEMA = Path(__file__).parent / "schema.sql"


def connect() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def init_db() -> None:
    with connect() as conn:
        conn.executescript(SCHEMA.read_text())


def query(sql: str, params: tuple = ()) -> list[sqlite3.Row]:
    with connect() as conn:
        return conn.execute(sql, params).fetchall()


def one(sql: str, params: tuple = ()) -> sqlite3.Row | None:
    with connect() as conn:
        return conn.execute(sql, params).fetchone()


def execute(sql: str, params: tuple = ()) -> int:
    """Returns lastrowid."""
    with connect() as conn:
        cur = conn.execute(sql, params)
        conn.commit()
        return cur.lastrowid
