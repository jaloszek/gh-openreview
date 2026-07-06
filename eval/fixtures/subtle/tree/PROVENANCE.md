# tree/ provenance — subtle

`subtle`'s diff only touches `metrix/invoice.py` and `metrix/pager.py`
(golden: S01, S02, S03) — both left untouched by this task.

Before this task, `subtle/tree/` contained *only* those two files. Everything
below is newly added full-project context; none of it is referenced by
`pr.diff`, so `freeze.sh`'s hunk-consistency check does not apply.

| File | Source | Bug-free? |
|---|---|---|
| `metrix/api.py` | `eval/fixtures/clean/tree/metrix/api.py` | yes |
| `metrix/auth.py` | reconstructed pre-`playground`-diff base (`patch -R eval/fixtures/playground/pr.diff`) — `check_basic()` only, no B03/B10 | yes |
| `metrix/billing.py` | hand-debugged (all 5 `playground` bugs fixed — see `playground/tree/PROVENANCE.md`) | yes |
| `metrix/cache.py` | `eval/fixtures/noisy/tree/metrix/cache.py` | yes |
| `metrix/cli.py` | `eval/fixtures/quiet/tree/metrix/cli.py` | yes |
| `metrix/config.py` | `eval/fixtures/noisy/tree/metrix/config.py` | yes |
| `metrix/eventbuffer.py` | hand-debugged copy of noisy's version (fixes C01) | yes |
| `metrix/exporter.py` | hand-debugged copy of noisy's version (fixes C02) | yes |
| `metrix/metrics_registry.py` | hand-debugged copy of noisy's version (fixes M03) | yes |
| `metrix/notifications.py` | hand-debugged copy of noisy's version (fixes M01) | yes |
| `metrix/retry.py` | hand-debugged copy of noisy's version (fixes M02) | yes |
| `metrix/scheduler.py` | hand-debugged copy of noisy's version (fixes C03) | yes |
| `metrix/storage.py` | reconstructed pre-`playground`-diff base (`patch -R`) — no `events_for_tenant`/`flush_pending`, so neither B05, B07, nor B09 exist here | yes |
| `metrix/validators.py` | hand-debugged copy of noisy's version (fixes M04) | yes |
| `metrix/worker.py` | hand-debugged (both `playground` bugs fixed — see `playground/tree/PROVENANCE.md`) | yes |
| `tests/test_metrix.py` | `eval/fixtures/noisy/tree/tests/test_metrix.py` verbatim | yes |

All added files are bug-free by construction (either genuinely
pre-bug-introduction bases via `patch -R`, or hand-fixed single-line copies
of the module that introduced the only known bug in it — see
`eval/fixtures/playground/tree/PROVENANCE.md` for the fix-by-fix rationale).
This matters more here than elsewhere: `subtle.expect` runs recall-only
scoring at `RUNS_DEFAULT=5` with no noise budget, but an opportunistic
"important" finding in unrelated context files would still be pure
precision noise the model shouldn't be manufacturing.
