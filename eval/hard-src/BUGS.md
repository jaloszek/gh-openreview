# Hard fixture — answer key

`base/` -> `head/` for a small job-queue + billing-ledger service (`queued/`),
plants **10 bugs**: 4 deep-diagnosis (right line, wrong-mechanism trap), 3
adjacent/interaction (mechanism lives in code the diff never touches), 2
omissions, and 1 easy control. Frozen at `eval/fixtures/hard/`, answer key
`eval/golden/hard.tsv`. **Human review of the planted bugs is required before
this fixture is trusted for scoring** — flagging per the task spec.

Diffstat (`base/` vs `head/`):

```
queued/api.py     | 32 +++++++++++++++++++++++++++++---
queued/ledger.py  | 21 +++++++++++++--------
queued/metrics.py | 14 +++++++++-----
queued/queue.py   | 14 ++++++++++++--
queued/worker.py  | 20 ++++++++++++++------
5 files changed, 77 insertions(+), 24 deletions(-)
(queued/api.py: +29/-3, queued/ledger.py: +13/-8, queued/metrics.py: +9/-5,
 queued/queue.py: +12/-2, queued/worker.py: +14/-6)
```

## Deep-diagnosis (scope=diff, mechanism ERE required)

Each of these reads, at a glance, as a DIFFERENT plausible bug than the one
actually planted — the mechanism ERE is written to match only the real
explanation.

| id | file | line | category | shallow (wrong) reading | correct mechanism |
|----|------|------|----------|--------------------------|--------------------|
| D01 | `queued/metrics.py` | 14 | logic | "cost from jobs with no metadata is silently treated as 0, masking missing cost data" | denominator changed from count-of-`done` jobs to `len(jobs)` (all jobs, including pending/failed with no cost), permanently under-reporting the average |
| D02 | `queued/worker.py` | 32 | logic | "if `job.metadata` isn't a dict this blows up" | `now_ms` (milliseconds) is compared directly against `STALE_AFTER_SECONDS` (still a seconds constant) — staleness now triggers ~1000x too eagerly |
| D03 | `queued/queue.py` | 47 | logic | "docstring references a removed `_dispatching` flag, stale comment, needs cleanup" | boundary changed from `<` to `<=`, so `has_capacity` now allows one job beyond `max_concurrency` to be dispatched (off-by-one) |
| D04 | `queued/ledger.py` | 64 | logic | "`int(order.total * order.tax_rate)` truncates the tax instead of rounding" | `total` is recomputed as `subtotal + tax` instead of the already-discounted `total + tax`, so the discount is silently dropped from the final total |

Grep evidence:
```
grep -n 'return total_cents // len(jobs)' eval/hard-src/head/queued/metrics.py       # D01
grep -n 'return now_ms - started_ms > STALE_AFTER_SECONDS' eval/hard-src/head/queued/worker.py  # D02
grep -n 'return self._in_flight <= self._max_concurrency' eval/hard-src/head/queued/queue.py     # D03
grep -n 'order.total = order.subtotal + order.tax_cents' eval/hard-src/head/queued/ledger.py      # D04
```

## Adjacent/interaction (scope=adjacent, mechanism ERE required)

The diff makes a change that is fine by itself; the bug is in UNCHANGED code
that the diff never touches.

| id | file | line | what the diff changed | what breaks in unchanged code |
|----|------|------|------------------------|--------------------------------|
| A01 | `queued/metrics.py` | 36 (`primary_label`) | `api.submit_job` stops coercing `tags=None` to `[]` (feature: ad-hoc jobs without tags) | `primary_label`'s `job.tags[0]` now raises `TypeError` on the newly-possible `None` |
| A02 | `queued/ledger.py` | 51 (`invoice_summary`) | `MIN_CHARGE_CENTS` changes from `100` to `0` (feature: allow zero-cost entries) | `invoice_summary`'s `if not entry.amount_cents: continue` still treats zero-cost entries as placeholders, silently excluding the now-legitimate zero-cost charges from the invoice |
| A03 | `queued/queue.py` | 66 (`mark_done`) | `Worker.dispatch` starts writing `self.queue._leases[job.job_id] = now_ms` on every dispatch (feature: lease bookkeeping for the upcoming reaper) | `mark_done` (unchanged) never deletes the lease entry, so `_leases` grows without bound |

Grep evidence:
```
grep -n 'return job.tags\[0\]' eval/hard-src/head/queued/metrics.py                        # A01 crash site
grep -n 'tags=tags)' eval/hard-src/head/queued/api.py                                       # A01 diff cause
grep -n 'if not entry.amount_cents:' eval/hard-src/head/queued/ledger.py                    # A02 crash site
grep -n 'MIN_CHARGE_CENTS = 0' eval/hard-src/head/queued/ledger.py                           # A02 diff cause
grep -n 'self._in_flight -= 1' eval/hard-src/head/queued/queue.py                            # A03 crash site (mark_done)
grep -n '_leases\[job.job_id\] = now_ms' eval/hard-src/head/queued/worker.py                 # A03 diff cause
```

## Omissions (scope=diff)

| id | file | line | category | description |
|----|------|------|----------|--------------|
| O01 | `queued/ledger.py` | 34 | error-handling | `record_charge`'s try/except retry-once was dropped during the "store owns retries now" cleanup, but no caller actually wraps the store in `RetryingStore` — a transient write failure now raises instead of retrying |
| O02 | `queued/api.py` | 69 | logic | `cancel_job` is new but `STATUS_LABELS` (unchanged) has no `"cancelled"` entry, so the response falls back to the raw status string instead of a human label like every other status |

Grep evidence:
```
grep -n 'self._store.write(entry)' eval/hard-src/head/queued/ledger.py    # O01 (no try/except around it)
grep -n 'job.status = "cancelled"' eval/hard-src/head/queued/api.py       # O02
```

## Easy control (scope=diff, obvious)

| id | file | line | category | description |
|----|------|------|----------|--------------|
| E01 | `queued/api.py` | 55 | null-edge | `get_job_duration_ms` does `job.metadata["started_at_ms"]` without checking `job.metadata is None` (true for any job that hasn't been dispatched yet) — `TypeError` |

Grep evidence:
```
grep -n 'job.metadata\["started_at_ms"\]' eval/hard-src/head/queued/api.py   # E01
```

## Known unseeded true positives (do not count as false positives)

Real defects in the fixture code that were NOT planted deliberately but have
been independently confirmed by reviewers and verified against the source
(2026-07-06, both live reviewers on PR #22). Scorers must exclude these from
false-positive counts; finding them is bonus signal, not noise.

| id | file | line | description | found by |
|----|------|------|-------------|----------|
| X01 | `queued/api.py` | 63-69 | `cancel_job` sets `job.status = "cancelled"` but the job stays on `queue._heap` and `dequeue` pops by id with no status check — a cancelled queued job is later dispatched and runs anyway; `actor` is accepted but never recorded | both (opencode + Fable) |
| X02 | `queued/api.py` | 30 | `priority=priority or 5` coerces the valid urgent value `priority=0` to the default 5 (falsy-zero; the heap is a min-heap, so 0 is the most urgent priority a caller can pass) | Fable only |

Grep evidence:
```
grep -n 'job.status = "cancelled"' eval/hard-src/head/queued/api.py    # X01 (no heap removal anywhere)
grep -n 'priority=priority or 5' eval/hard-src/head/queued/api.py      # X02
```

## Verification

```bash
diff -ruN eval/hard-src/base eval/hard-src/head --exclude='__pycache__'
python3 -m py_compile eval/hard-src/base/queued/*.py eval/hard-src/head/queued/*.py
bash eval/freeze.sh eval/fixtures/hard
```
