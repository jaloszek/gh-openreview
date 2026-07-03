# eval — how we test the reviewer

## What is this, in plain words

The reviewer is an LLM pipeline, and LLMs drift: a prompt tweak that fixes
one thing quietly breaks another, and you won't notice on live PRs. This
folder is our answer — a set of **fake, frozen PRs with known bugs planted
in them**, and a script that runs the review engine against them and counts
how many planted bugs it found (and how much junk it reported).

Think of it as an exam with an answer key:

- A **fixture** is a frozen PR — the exact context files the action would
  gather for a real PR (`pr.diff`, PR title/body, comments…), saved to disk
  once. No GitHub, no token, no CI needed to use it.
- A **golden file** is the answer key — the list of bugs we planted, with
  file, line, category, and severity.
- **`run.sh`** copies a fixture into a temp dir, runs the real review passes
  (`lib/passes.sh` + `lib/render.sh`) against it, and grades the result:
  a finding "hits" a planted bug when it points at the same file within ±5
  lines.

The output is a **scorecard**:

- **recall** — of the bugs we planted, how many did it find? (overall,
  important-only, and per category)
- **precision** — of everything it reported, how much matched a planted bug?
  (the rest is potential noise)
- **per-bug `found m/k`** — with `EVAL_RUNS=3`, each bug shows how many of
  the 3 runs caught it. A bug found 1/3 is *flaky*, not caught.

Why repetitions? Hosted models are nondeterministic even at temperature 0 —
a single run can flatter or slander a prompt change. k=3 is the practical
minimum for comparing two prompt versions.

There is also a no-LLM **`--selftest`** (canned findings vs the answer key,
fully deterministic) — that's the merge gate for changes to the harness
itself.

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

Human-readable scorecard goes to stdout; machine-readable results land in
`eval/.work/scorecard.tsv`. Everything under `eval/.work/` is disposable and
gitignored.

| Env var | Meaning |
|-----|---------|
| `EVAL_RUNS` | repetitions per fixture (default 1); use 3–5 for prompt A/B work |
| `OPENREVIEW_MODEL` | generate-pass model (same resolution as the action) |
| `OPENREVIEW_VERIFY_MODEL`, `OPENREVIEW_CHEAP_MODEL`, `OPENREVIEW_PASS_TIMEOUT` | passed through to `lib/passes.sh` unchanged |

## Current fixtures

- **`playground/`** — an invented 4-file Python project with **12 planted
  bugs** across the whole taxonomy (logic/off-by-one, null/edge, error
  handling, resource leak, race, security, convention, subtle). The broad
  "can it find bugs at all" exam. Answer key:
  `eval/golden/playground.tsv`.
- **`clean/`** — a rename-only refactor with **zero** bugs. A fixture
  without a golden TSV is a clean control: any important finding fails the
  eval. This catches hallucinated problems.

## Planned fixtures — the three review scenarios

The two fixtures above test *finding* and *not hallucinating*. Real-world
reviewer quality has a third dimension: **knowing how much to say**. The
field's documented failure modes map to three PR shapes, so the target set
is:

1. **`quiet/` — a boring, obviously-fine PR.** Small, real change (a new
   config option, a doc tweak, a straightforward feature) with **no real
   bugs**, but salted with *nit bait*: slightly imperfect naming, a missing
   docstring, a magic number. The right review is near-silence.
   **Scored on a noise budget, not recall: 0 importants (hard fail), ≤2
   nits.** This is different from `clean/` — clean tests "no inventions on
   a null diff"; quiet tests "resists the urge to nitpick a real but boring
   diff" (the #1 complaint about AI reviewers in the wild: 79% of comments
   being technically-correct nits).
2. **`subtle/` — a small PR hiding exactly 3 real bugs.** Looks like an
   innocent refactor, but the reshuffle introduces genuine defects at
   different depths — e.g. reordered variable assignments creating a
   use-before-set, a boundary condition silently changed in an extracted
   helper, an error path dropped while inlining. Nothing is obvious at
   first glance; everything is definitely a bug.
   **Scored on recall of the 3 (goal 3/3), run at k=5** — subtle bugs are
   the flakiest to detect, and this is where frontier reviewers score worst
   (published benchmarks: 15–31% of human-flagged issues found from
   diff-only context).
3. **`noisy/` — a big, messy PR.** Many files, lots of legitimate churn,
   at-or-over the diff budget, with a mix of planted bugs: 2–3 **critical**
   (must-catch), several moderate, plus nit bait everywhere.
   **Scored on triage quality: recall of the must-catch criticals as
   `important` (hard requirement), plus a noise budget (nit count within
   the cap, bounded total findings).** Also exercises the diff compression
   ladder for real. The aim mirrors what a senior reviewer does on a big
   PR: surface what matters, refuse to drown the author.

Together: `clean`/`quiet` guard the noise floor, `subtle` guards depth,
`noisy` guards prioritization, and `playground` stays the broad smoke test.
(Implementation note: `quiet` and `noisy` need a small runner extension — a
per-fixture expectations file with `max_importants` / `max_nits` /
`must_catch` — the golden TSV alone can't express budgets.)

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
3. For a scored fixture, add `eval/golden/<name>.tsv`
   (`id \t file \t line \t category \t sev \t description`). Omit the
   golden file for a clean control.

Matching is deterministic: same file, line within ±5. Bugs planted fewer
than ~10 lines apart can be hit by one finding — keep them spread out.

### Replay fixtures (historical bug replay)

The highest-signal growth path: for a real **fix commit**, freeze the
pre-fix state as a fixture — the fix commit IS the golden finding.

1. `git diff <base> <pre-fix-head> > pr.diff` for the change that introduced
   the bug (or revert the fix on a scratch branch and diff that).
2. Fill in the context files from the real PR (the local-run recipe in
   `CLAUDE.md` shows a token-scoped `lib/gather.sh` invocation that produces
   all of them for you).
3. Golden TSV: one row pointing at the line the fix commit changed, with a
   description written from the fix commit message.

This repo's own `1b3e315` ("model input silently ignored") is a ready-made
seed. ~5–10 replay fixtures make prompt A/B results meaningful; the planted
fixtures stay the fast smoke gate.
