"""queued: a small in-memory job queue with a billing ledger on top.

Modules:
  queue.py   - JobQueue: priority dispatch with a bounded in-flight window.
  worker.py  - Worker: dequeue/run/report loop used by the worker pool.
  ledger.py  - Ledger: per-tenant charges and monthly invoice totals.
  store.py   - storage backends the ledger writes through to.
  metrics.py - aggregation helpers for the dashboard.
  api.py     - thin request handlers wiring the above together.
"""

__version__ = "0.3.0"
