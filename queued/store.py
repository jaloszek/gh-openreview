"""Durable-ish storage backends for ledger entries.

`FileStore` is what production uses; `InMemoryStore` backs the unit tests
and any offline tooling that doesn't want a filesystem dependency.
"""

import json
import os


class InMemoryStore:
    def __init__(self):
        self.written = []

    def write(self, entry):
        self.written.append(entry)

    def all(self):
        return list(self.written)


class FileStore:
    """Append-only newline-delimited JSON file, one ledger entry per line."""

    def __init__(self, path):
        self.path = path

    def write(self, entry):
        record = {
            "tenant_id": entry.tenant_id,
            "amount_cents": entry.amount_cents,
            "kind": entry.kind,
        }
        with open(self.path, "a") as fh:
            fh.write(json.dumps(record))
            fh.write("\n")

    def all(self):
        if not os.path.exists(self.path):
            return []
        records = []
        with open(self.path) as fh:
            for line in fh:
                line = line.strip()
                if line:
                    records.append(json.loads(line))
        return records


class RetryingStore:
    """Wraps another store, retrying a write once on IOError."""

    def __init__(self, inner, max_attempts=2):
        self.inner = inner
        self.max_attempts = max_attempts

    def write(self, entry):
        last_error = None
        for attempt in range(self.max_attempts):
            try:
                self.inner.write(entry)
                return
            except IOError as exc:
                last_error = exc
        raise last_error

    def all(self):
        return self.inner.all()
