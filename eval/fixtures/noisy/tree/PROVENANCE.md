# tree/ provenance — noisy

`noisy`'s diff touches `metrix/{cache,eventbuffer,exporter,scheduler,
notifications,retry,metrics_registry,validators,config,billing,storage,
worker}.py` and `tests/test_metrix.py` (plus one file deletion) — all of
those are left exactly as the diff leaves them (golden: C01–C03, M01–M04).

**Known pre-existing issue, out of scope for this task:** `billing.py`,
`storage.py`, and `worker.py` here are diff-touched (noisy's own diff
modifies them to wire in the new infra modules), but their pre-image already
carried `playground`'s planted bugs (`range(len(events) - 1)`,
`int(amount * 100)` truncation, unbound `resp` on `URLError`) and the diff
does not remove them. This task's constraint is "never overwrite/contradict
a file the fixture's diff touches" — fixing this would mean hand-editing
`noisy`'s diff-touched tree files (or `pr.diff` itself), which is out of
bounds here. `noisy.expect` has no `MAX_IMPORTANTS` cap (only
`MUST_CATCH=C01,C02,C03`, `MAX_NITS=3`, `MAX_TOTAL=12`), so extra importants
found in `billing.py`/`worker.py` don't fail the fixture on their own, but
could eat into `MAX_TOTAL`. Flagging for a future task rather than fixing
here.

Everything below is newly added (not diff-touched, full-project fill-in):

| File | Source | Bug-free? |
|---|---|---|
| `metrix/api.py` | `eval/fixtures/clean/tree/metrix/api.py` | yes |
| `metrix/auth.py` | reconstructed pre-`playground`-diff base (`patch -R eval/fixtures/playground/pr.diff`) | yes |
| `metrix/cli.py` | `eval/fixtures/quiet/tree/metrix/cli.py` | yes |
| `metrix/invoice.py` | reconstructed pre-`subtle`-diff base (`patch -R eval/fixtures/subtle/pr.diff`) | yes |
| `metrix/pager.py` | reconstructed pre-`subtle`-diff base (`patch -R`) | yes |

`metrix/api.py`'s `auth.verify_password()` call doesn't match this fixture's
added `auth.py::check_basic()` (same cosmetic, import-safe-only mismatch
documented in `playground/tree/PROVENANCE.md`) — harmless since `api.py` is
never executed by the eval harness, only importable.
