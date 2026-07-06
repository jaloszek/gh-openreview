# tree/ provenance — clean

`clean`'s diff touches `metrix/{api,auth,storage}.py` only (a rename-only
refactor, zero planted bugs) — left exactly as the diff leaves them.

Everything below is newly added full-project context; none of it is
referenced by `pr.diff`.

| File | Source | Bug-free? |
|---|---|---|
| `metrix/billing.py` | hand-debugged (all 5 `playground` bugs fixed — see `playground/tree/PROVENANCE.md`) | yes |
| `metrix/cache.py` | `eval/fixtures/noisy/tree/metrix/cache.py` | yes |
| `metrix/cli.py` | `eval/fixtures/quiet/tree/metrix/cli.py` | yes |
| `metrix/config.py` | `eval/fixtures/noisy/tree/metrix/config.py` | yes |
| `metrix/eventbuffer.py` | hand-debugged copy of noisy's version (fixes C01) | yes |
| `metrix/exporter.py` | hand-debugged copy of noisy's version (fixes C02) | yes |
| `metrix/invoice.py` | reconstructed pre-`subtle`-diff base (`patch -R eval/fixtures/subtle/pr.diff`) | yes |
| `metrix/metrics_registry.py` | hand-debugged copy of noisy's version (fixes M03) | yes |
| `metrix/notifications.py` | hand-debugged copy of noisy's version (fixes M01) | yes |
| `metrix/pager.py` | reconstructed pre-`subtle`-diff base (`patch -R`) | yes |
| `metrix/retry.py` | hand-debugged copy of noisy's version (fixes M02) | yes |
| `metrix/scheduler.py` | hand-debugged copy of noisy's version (fixes C03) | yes |
| `metrix/validators.py` | hand-debugged copy of noisy's version (fixes M04) | yes |
| `metrix/worker.py` | hand-debugged (both `playground` bugs fixed — see `playground/tree/PROVENANCE.md`) | yes |
| `tests/test_metrix.py` | `eval/fixtures/noisy/tree/tests/test_metrix.py` verbatim | yes |

Since `clean` is the zero-bug control (any rendered important finding fails
the run), every added file here is deliberately bug-free by construction —
same debugging approach as `playground`/`quiet`/`subtle` (see
`playground/tree/PROVENANCE.md` for the fix-by-fix rationale).

Known cosmetic mismatch: `metrix/cli.py` (from `quiet`) calls
`storage.Storage(db_path, timeout=30)` and `.events_for_tenant(...)`; this
fixture's own (diff-touched) `storage.py` defines `insert_event(..., ts)`
without a `timeout` kwarg or `events_for_tenant`. Import-time only — neither
`cli.py`'s `main()` nor any eval code path is executed by `run.sh`, so this
never surfaces as a runtime error, only as a documented content
inconsistency in supplementary context.
