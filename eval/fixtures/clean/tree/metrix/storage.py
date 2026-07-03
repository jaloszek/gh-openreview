"""Sqlite-backed storage for tenant usage events."""

import logging
import sqlite3

logger = logging.getLogger(__name__)

# minimal fixed schema; migrations aren't implemented
SCHEMA = (
    "CREATE TABLE IF NOT EXISTS events ("
    "tenant TEXT, kind TEXT, amount REAL, created_at TEXT)"
)


class Storage:
    """Thin wrapper around a single sqlite database of usage events."""

    def __init__(self, db_path, timeout=5):
        self._db_path = db_path
        self._timeout = timeout

    def connect(self):
        """Open a fresh connection to the events database."""
        conn = sqlite3.connect(self._db_path, timeout=self._timeout)
        conn.execute(SCHEMA)
        return conn

    def insert_event(self, tenant, kind, amount, ts):
        conn = self.connect()
        try:
            conn.execute(
                "INSERT INTO events (tenant, kind, amount, created_at) VALUES (?, ?, ?, ?)",
                (tenant, kind, amount, ts),
            )
            conn.commit()
        finally:
            conn.close()
