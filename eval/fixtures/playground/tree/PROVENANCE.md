# tree/ provenance — playground

`playground`'s diff creates/touches `metrix/{auth,billing,storage,worker}.py`
directly — those four files are untouched by this task (they still carry the
12 planted bugs in `eval/golden/playground.tsv`, exactly as the diff leaves
them).

Everything else below is **added supporting context** so the checkout looks
like the full `metrix` project instead of a 4-file island. None of these
files are touched by `pr.diff`, so `freeze.sh`'s hunk-consistency check does
not apply to them.

| File | Source | Bug-free? |
|---|---|---|
| `metrix/api.py` | `eval/fixtures/clean/tree/metrix/api.py` (clean's own diff-touched, bug-free version) | yes |
| `metrix/cache.py` | `eval/fixtures/noisy/tree/metrix/cache.py` (noisy's diff introduces this file; not in `noisy.tsv`, no planted bug) | yes |
| `metrix/cli.py` | `eval/fixtures/quiet/tree/metrix/cli.py` (quiet's own diff-touched, bug-free version) | yes |
| `metrix/config.py` | `eval/fixtures/noisy/tree/metrix/config.py` (not in `noisy.tsv`) | yes |
| `metrix/eventbuffer.py` | hand-debugged copy of `noisy`'s version — noisy's `push()` silently drops events when the buffer is full (golden C01); this copy adds the missing `logger.warning(...)` on the full-buffer path so the bug is not present here | yes (fixed) |
| `metrix/exporter.py` | hand-debugged copy of `noisy`'s version — noisy's `_export_path()` joins a caller-supplied filename unsanitized (golden C02, path traversal); this copy sanitizes with `os.path.basename(filename)` | yes (fixed) |
| `metrix/invoice.py` | reconstructed pre-`subtle`-diff base (`patch -R` of `eval/fixtures/subtle/pr.diff` against `subtle/tree/metrix/invoice.py`) — removes S01/S03 | yes |
| `metrix/metrics_registry.py` | hand-debugged copy of `noisy`'s version — noisy keys counters/gauges by name only, ignoring `unit` (golden M03); this copy keys by `(name, unit)` | yes (fixed) |
| `metrix/notifications.py` | hand-debugged copy of `noisy`'s version — noisy's idempotency key is `tenant+event_type` only, colliding across distinct events for the same tenant (golden M01); this copy folds a hash of `details` into the key | yes (fixed) |
| `metrix/pager.py` | reconstructed pre-`subtle`-diff base (`patch -R`) — removes S02 | yes |
| `metrix/retry.py` | hand-debugged copy of `noisy`'s version — noisy's backoff is linear (`base_delay * attempt`), not exponential as documented (golden M02); this copy uses `base_delay * 2**(attempt-1)` | yes (fixed) |
| `metrix/scheduler.py` | hand-debugged copy of `noisy`'s version — noisy's `flush-pending` job has no `interval` key, so `_due()` raises `KeyError` on the first tick (golden C03); this copy adds `"interval": 60` | yes (fixed) |
| `metrix/validators.py` | hand-debugged copy of `noisy`'s version — noisy's `validate_percentage` returns the inverted boolean (golden M04); this copy fixes the polarity | yes (fixed) |
| `tests/test_metrix.py` | `eval/fixtures/noisy/tree/tests/test_metrix.py` verbatim (not in `noisy.tsv`) | yes |

## Why hand-debugged copies instead of reuse

`noisy`'s versions of `eventbuffer.py`/`exporter.py`/`scheduler.py`/
`notifications.py`/`retry.py`/`metrics_registry.py`/`validators.py` are the
**post-diff** state for that fixture and carry noisy's own planted bugs
(C01–C03, M01–M04). Copying them verbatim into `playground/tree/` would
plant those same bugs here, where they are not in `playground.tsv` — an
opportunistic read by the model could report them as "important" and count
as unscored noise. Each was hand-fixed to the single bug line documented in
`noisy.tsv`/`noisy.expect`, keeping everything else byte-for-byte identical
to noisy's version.

## Known cosmetic mismatch (harmless for import checks)

`metrix/api.py` (from `clean`) calls `auth.verify_password(...)`, but this
fixture's own `metrix/auth.py` (diff-touched, unchanged) defines
`check_basic(...)` instead — a naming difference inherited from `clean`'s
independent rename refactor. `metrix/cli.py` similarly calls
`storage.Storage(db_path, timeout=...)` / `.events_for_tenant(...)`, and this
fixture's `storage.py` does define both, so that one is fully consistent.
The `api.py`/`auth.py` naming mismatch only matters if the code is executed
(`AttributeError`), never at import time — `python3 -c "import metrix.api"`
succeeds because `metrix/auth.py` exists as a module regardless of which
functions it defines, and neither `api.py`'s module body nor `run.sh`
executes `handle_login`. `pr.diff` never touches `api.py` or `auth.py`
together, so this is a supplementary-context blemish, not a diff-scoring
risk.
