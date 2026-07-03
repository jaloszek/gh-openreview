"""Sqlite-backed storage for tenant usage events, with query caching."""

import logging
import sqlite3

from metrix.cache import TTLCache

logger = logging.getLogger(__name__)

QUERY_CACHE_TTL_SECONDS = 30


class Storage:
    """Thin wrapper around a single sqlite database of usage events."""

    def __init__(self, db_path):
        self._db_path = db_path
        self._query_cache = TTLCache(ttl_seconds=QUERY_CACHE_TTL_SECONDS)

    def connect(self):
        """Open a fresh connection to the events database."""
        return sqlite3.connect(self._db_path)

    def events_for_tenant(self, tenant, since):
        """Return kind/amount/created_at rows for a tenant since an ISO timestamp.

        Cached briefly since the dashboard polls this endpoint every few
        seconds for the same tenant/since pair.
        """
        cache_key = (tenant, since)
        return self._query_cache.get_or_load(cache_key, lambda _: self._query(tenant, since))

    def _query(self, tenant, since):
        conn = self.connect()
        try:
            cur = conn.execute(
                "SELECT kind, amount, created_at FROM events "
                "WHERE tenant = ? AND created_at >= ?",
                (tenant, since),
            )
            rows = cur.fetchall()
            return rows
        finally:
            conn.close()

    def insert_event(self, tenant, kind, amount, created_at):
        conn = self.connect()
        try:
            conn.execute(
                "INSERT INTO events (tenant, kind, amount, created_at) VALUES (?, ?, ?, ?)",
                (tenant, kind, amount, created_at),
            )
            conn.commit()
        finally:
            conn.close()

    def flush_pending(self, pending):
        """Best-effort write of events queued while the DB was unavailable."""
        conn = self.connect()
        try:
            for ev in pending:
                try:
                    conn.execute(
                        "INSERT INTO events (tenant, kind, amount, created_at) VALUES (?, ?, ?, ?)",
                        ev,
                    )
                except Exception:
                    pass
            conn.commit()
        finally:
            conn.close()
