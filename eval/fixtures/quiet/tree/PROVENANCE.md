# tree/ provenance — quiet

`quiet`'s diff only touches `metrix/cli.py` and `README.md`
(`quiet.expect`: `MAX_IMPORTANTS=0`, `MAX_NITS=2`) — both left untouched by
this task. Every other file below is added/replaced supporting context.

## Replaced (not diff-touched, so free to fix — see "why" below)

| File | Before this task | Now |
|---|---|---|
| `metrix/auth.py` | byte-identical to `playground`'s post-diff (buggy) version — carried B03 (`IndexError` on a malformed `Authorization` header) and B10 (MD5-hashed API tokens) | reconstructed pre-`playground`-diff base (`patch -R eval/fixtures/playground/pr.diff`) — `check_basic()` only, neither bug present |
| `metrix/billing.py` | byte-identical to `playground`'s post-diff (buggy) version — carried B01, B02, B04, B11, B12 | hand-debugged: off-by-one loop fixed, ceiling division, zero-sample guard, `round()` instead of truncating `int()`, `logger.warning` instead of `print()` |
| `metrix/worker.py` | byte-identical to `playground`'s post-diff (buggy) version — carried B06 (unbound `resp` on `URLError`) and B08 (unlocked check-then-act race) | hand-debugged: early `return None` on `URLError`, `config_for` now holds `self._lock` for the whole read-modify-write |

**Why:** these three files predate this task's changes (added by the
original `TASK-25` tree/ work) but happened to be copies of `playground`'s
post-diff state, which silently plants 8 of playground's 12 golden bugs into
a fixture whose budget is `MAX_IMPORTANTS=0`. That's exactly the
contamination risk `TASK-42` calls out — fixed here since `quiet`'s own diff
never touches these files.

`metrix/storage.py` was **not** replaced — it was already a genuinely clean,
independently-evolved version (parameterized query, `conn.close()` on every
path, no leak) that predates the SQL-injection/leak bugs `playground`
introduced; left as-is.

## Added (new files, full-project fill-in)

| File | Source |
|---|---|
| `metrix/api.py` | `eval/fixtures/clean/tree/metrix/api.py` (bug-free) |
| `metrix/cache.py` | `eval/fixtures/noisy/tree/metrix/cache.py` (not in `noisy.tsv`) |
| `metrix/config.py` | `eval/fixtures/noisy/tree/metrix/config.py` (not in `noisy.tsv`) |
| `metrix/eventbuffer.py` | hand-debugged copy of noisy's version (fixes C01 — logs on full-buffer drop) |
| `metrix/exporter.py` | hand-debugged copy of noisy's version (fixes C02 — sanitizes filename with `os.path.basename`) |
| `metrix/invoice.py` | reconstructed pre-`subtle`-diff base (`patch -R eval/fixtures/subtle/pr.diff`) |
| `metrix/metrics_registry.py` | hand-debugged copy of noisy's version (fixes M03 — keys by `(name, unit)`) |
| `metrix/notifications.py` | hand-debugged copy of noisy's version (fixes M01 — idempotency key folds in a hash of `details`) |
| `metrix/pager.py` | reconstructed pre-`subtle`-diff base (`patch -R`) |
| `metrix/retry.py` | hand-debugged copy of noisy's version (fixes M02 — exponential backoff) |
| `metrix/scheduler.py` | hand-debugged copy of noisy's version (fixes C03 — `flush-pending` job gets an `interval`) |
| `metrix/validators.py` | hand-debugged copy of noisy's version (fixes M04 — polarity of `validate_percentage`) |
| `tests/test_metrix.py` | `eval/fixtures/noisy/tree/tests/test_metrix.py` verbatim |

See `eval/fixtures/playground/tree/PROVENANCE.md` for the full rationale on
why the noisy-derived infra modules are hand-debugged copies rather than
verbatim reuse, and for the one known cosmetic (import-safe, not
execution-safe) mismatch between `api.py`'s `auth.verify_password()` call
and this fixture's `auth.py::check_basic()`.
