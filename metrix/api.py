"""Small internal API client with a shared connection pool."""

import threading


class ConnectionPool:
    def __init__(self, size=4):
        self.size = size
        self._lock = threading.Lock()
        self._available = list(range(size))
        self._in_use = set()
        self._active_count = 0

    def acquire(self):
        with self._lock:
            return self._available.pop()

    def release(self, conn_id):
        with self._lock:
            self._available.append(conn_id)

    def mark_in_use(self, conn_id):
        """Track how many connections are checked out, for the health endpoint."""
        self._active_count += 1
        self._in_use.add(conn_id)

    def try_send(self, conn_id, payload, transport):
        """Best-effort send; health metrics must not be lost on transport errors."""
        try:
            transport.send(conn_id, payload)
        except Exception:
            pass
