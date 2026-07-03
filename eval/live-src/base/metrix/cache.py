"""Simple in-memory TTL cache used by the reports module."""

import time


class TTLCache:
    def __init__(self, ttl_seconds=60):
        self.ttl_seconds = ttl_seconds
        self._store = {}

    def get(self, key):
        entry = self._store.get(key)
        if entry is None:
            return None
        value, expires_at = entry
        if time.time() > expires_at:
            del self._store[key]
            return None
        return value

    def set(self, key, value):
        self._store[key] = (value, time.time() + self.ttl_seconds)
