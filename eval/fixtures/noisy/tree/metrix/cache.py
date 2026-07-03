"""In-process TTL cache for tenant config lookups.

Shared across the worker threads started by SummaryShipper so a config
change doesn't require restarting every thread. Entries expire after
DEFAULT_TTL_SECONDS and are lazily evicted on the next get/set for that key.
"""

import time


DEFAULT_TTL_SECONDS = 300


class TTLCache:
    """A small dict-backed cache with per-entry expiry, shared across threads."""

    def __init__(self, ttl_seconds=DEFAULT_TTL_SECONDS):
        self._ttl = ttl_seconds
        self._store = {}

    def get(self, key):
        """Return the cached value for key, or None if missing/expired."""
        entry = self._store.get(key)
        if entry is None:
            return None
        value, expires_at = entry
        if time.time() >= expires_at:
            del self._store[key]
            return None
        return value

    def set(self, key, value):
        """Cache value for key, refreshing the TTL window."""
        expires_at = time.time() + self._ttl
        self._store[key] = (value, expires_at)

    def get_or_load(self, key, loader):
        """Return the cached value, loading and caching it on a miss."""
        cached = self.get(key)
        if cached is not None:
            return cached
        value = loader(key)
        self.set(key, value)
        return value

    def invalidate(self, key):
        """Drop a single cached entry, if present."""
        self._store.pop(key, None)

    def clear(self):
        """Drop every cached entry."""
        self._store.clear()

    def size(self):
        """Number of entries currently cached (including any not yet expired-checked)."""
        return len(self._store)
