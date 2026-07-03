# eval — offline scoring harness for the review engine

Frozen-input regression eval (see `docs/implementation-notes.md` §3): each
fixture under `eval/fixtures/<name>/` is a **frozen scratch snapshot** — the
exact files `lib/gather.sh` would produce for a PR. The runner executes only
`lib/passes.sh` + `lib/render.sh` against a copy of the fixture, so **no
GitHub token, no live PR, and no CI dependency** are needed — just opencode
credentials for the model passes.

## Run it

```bash
# fast, deterministic, no LLM — the merge gate for harness changes
bash eval/run.sh --selftest

# score the seeded-bug fixture (only OPENREVIEW_MODEL required)
OPENREVIEW_MODEL=opencode/deepseek-v4-flash-free bash eval/run.sh playground

# the clean control — exits non-zero if ANY important finding appears
bash eval/run.sh clean

# all fixtures, 3 repetitions each (per-bug "found m/k" column)
EVAL_RUNS=3 bash eval/run.sh
```

Human-readable scorecard goes to stdout (recall overall / important-only /
per-category, precision, finding + nit counts, per-bug `found m/k`).
Machine-readable results land in `eval/.work/scorecard.tsv`
(`fixture \t key \t value`). Everything under `eval/.work/` is disposable
and gitignored.

## Env vars

| Var | Meaning |
|-----|---------|
| `EVAL_RUNS` | repetitions per fixture (default 1). Hosted APIs are nondeterministic even at temp 0 — use 3–5 for prompt A/B work. |
| `OPENREVIEW_MODEL` | generate-pass model (same resolution as the action, see `lib/common.sh`) |
| `OPENREVIEW_VERIFY_MODEL`, `OPENREVIEW_CHEAP_MODEL`, `OPENREVIEW_PASS_TIMEOUT` | passed through to `lib/passes.sh` unchanged |

## Fixtures

- **`playground/`** — an invented 4-file Python project (`metrix`) with **12
  seeded bugs**: 2 logic/off-by-one, 2 null/edge, 2 error handling,
  1 resource leak, 1 race, 2 security, 1 convention violation, 1 subtle.
  Golden truth: `eval/golden/playground.tsv`
  (`id \t file \t line \t category \t sev \t description`; `line` is the
  buggy line in the new file).
- **`clean/`** — a rename-only refactor of the same project, verified clean.
  A fixture **without** a golden TSV is treated as a clean control: any
  important finding makes the eval exit non-zero.

Matching is deterministic: a finding hits a golden bug when the file matches
and the line is within ±5. Bugs seeded fewer than ~10 lines apart can be hit
by one finding — keep seeded bugs spread out.

## Adding a fixture

1. `mkdir eval/fixtures/<name>` and add the frozen scratch files:
   `pr.diff`, `pr-meta.json` (shape of `gh pr view --json title,body,files`),
   `pr-commits.md`, `linked-issues.md`, `pr-comments.md`, `prev-review.md`
   (use the placeholder texts gather emits — e.g. `(no linked issues)` — when
   a file has no content).
2. `bash eval/freeze.sh eval/fixtures/<name>` — regenerates the derived
   `pr-numbered.diff` and `commentable-lines.tsv` from `pr.diff` with the
   same awk transforms as `lib/gather.sh`. Re-run it whenever `pr.diff`
   changes.
3. For a scored fixture, add `eval/golden/<name>.tsv`. Omit the golden file
   for a clean control.

### Replay fixtures (historical bug replay)

The highest-signal growth path: for a real **fix commit**, freeze the
pre-fix state as a fixture — the fix commit IS the golden finding.

1. `git diff <base> <pre-fix-head> > pr.diff` for the PR that introduced the
   bug (or revert the fix on a scratch branch and diff that).
2. Fill in the context files from the real PR
   (`gh pr view --json title,body,files`, `gh pr diff`, etc. — the local-run
   recipe in `CLAUDE.md` shows a token-scoped `lib/gather.sh` invocation that
   produces all of them for you).
3. Golden TSV: one row pointing at the line the fix commit changed, with a
   description written from the fix commit message.

This repo's own `1b3e315` ("model input silently ignored") is a ready-made
seed. ~5–10 replay fixtures make prompt A/B results meaningful; the seeded
playground stays the fast smoke gate.
