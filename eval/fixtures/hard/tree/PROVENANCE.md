# tree/ provenance — hard

Verified (TASK-42): `hard/tree/queued/` already contained the full project
before this task — all six shipped modules plus `__init__.py`:
`__init__.py`, `api.py`, `ledger.py`, `metrics.py`, `queue.py`, `store.py`,
`worker.py` — matching `eval/hard-src/head/queued/` exactly (this fixture's
source of truth; see `eval/hard-src/BUGS.md`). `pr.diff` touches `api.py`,
`ledger.py`, `metrics.py`, `queue.py`, `worker.py`; `store.py` and
`__init__.py` were already present as non-diff-touched full-project context.
No files added or changed by this task.
