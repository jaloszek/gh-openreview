"""Small internal API client with a shared connection pool."""

import threading


class ConnectionPool:
    def __init__(self, size=4):
        self.size = size
        self._lock = threading.Lock()
        self._available = list(range(size))

    def acquire(self):
        with self._lock:
            return self._available.pop()

    def release(self, conn_id):
        with self._lock:
            self._available.append(conn_id)
