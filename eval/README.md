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
- **`quiet/`** — a boring, real `--format json` CLI flag + README blurb with
  **zero** bugs but salted nit bait (vague name, magic number, missing
  docstring). Budget-only (no golden TSV): `eval/golden/quiet.expect`
  (`MAX_IMPORTANTS=0`, `MAX_NITS=2`).
- **`subtle/`** — a small "refactor: extract helpers, no behavior change"
  diff across `invoice.py`/`pager.py` hiding **3 real bugs**: a reordered
  reset that stales a balance read, a `<`→`<=` boundary slip moved into an
  extracted helper, and a dropped error path while inlining. Answer key:
  `eval/golden/subtle.tsv`; scored at `RUNS_DEFAULT=5`, recall only (no
  must-catch — subtle misses are signal, not build failures).
- **`noisy/`** — a big PR (14 files) adding cache/buffer/exporter/scheduler/
  notifications/retry/metrics/validators infrastructure, mixed with
  legitimate churn (a dropped-in test file, a deleted legacy module,
  wiring changes). Plants 3 critical bugs (silent event-buffer data loss,
  export path traversal, a scheduler `KeyError` on the default job list)
  and 4 moderate ones. Answer key: `eval/golden/noisy.tsv`;
  `eval/golden/noisy.expect` requires catching the 3 criticals
  (`MUST_CATCH=C01,C02,C03`) within a noise budget (`MAX_NITS=3`,
  `MAX_TOTAL=12`).
- **`kotlin/`** — multi-language coverage: an invented Kotlin console-app
  expense tracker (`Main.kt`/`Ledger.kt`/`Parser.kt`/`Report.kt`) gets a
  "feat: add budgets and monthly report" PR planting **8 bugs**, mostly
  Kotlin-specific (`!!` on a legitimately-nullable lookup, a `lateinit var`
  read before `initialize()`, `===` vs `==`, a `when` over an enum made
  non-exhaustive by a newly added case, integer division in money math, a
  dropped `runCatching` failure, an unsynchronized `MutableList` shared
  across coroutines, an off-by-one `until`/`..` swap). Answer key:
  `eval/golden/kotlin.tsv`; recall-only, no expect file, like `playground`.

## Design rationale — the three review scenarios

`clean`/`playground` above test *finding* and *not hallucinating*. Real-world
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
   the cap, bounded total findings).** The aim mirrors what a senior
   reviewer does on a big PR: surface what matters, refuse to drown the
   author.

Together: `clean`/`quiet` guard the noise floor, `subtle` guards depth,
`noisy` guards prioritization, and `playground` stays the broad smoke test.
Note: the eval does **not** run `gather.sh` — fixtures feed `passes.sh`
directly — so the diff compression ladder is not exercised here; noisy
fixtures must stay within the diff budget on their own.

### Expectations files

The golden TSV can only express "find these bugs". Budgets and hard
requirements need a second, optional per-fixture file:
`eval/golden/<name>.expect` — plain `KEY=VALUE` lines (`#` comments allowed):

| Key | Meaning |
|-----|---------|
| `MAX_IMPORTANTS=<n>` | rendered important findings above `n` ⇒ FAIL |
| `MAX_NITS=<n>` | rendered nits above `n` ⇒ FAIL |
| `MAX_TOTAL=<n>` | total rendered findings above `n` ⇒ FAIL |
| `MUST_CATCH=<id,id,…>` | golden ids that must be matched (union across runs) by a finding rendered as `important` ⇒ else FAIL |
| `RUNS_DEFAULT=<k>` | repetitions when `EVAL_RUNS` is not explicitly set (the env var always wins) |

Grading depends on which files exist for a fixture:

- **golden only** — today's behavior: recall/precision, no hard fail.
- **golden + expect** — recall/precision *and* budget/must-catch enforcement.
- **expect only** (e.g. `quiet`) — budget-only: recall/precision is skipped
  (there's no answer key), budgets are enforced.
- **neither** — clean control: any important finding fails the run.

Violations print a `✗ expectation failed: ...` line, add
`<fixture> expect_<key> pass|fail` rows to `scorecard.tsv`, and make
`run.sh` exit non-zero once all fixtures have run.

## Adding a fixture

1. `mkdir eval/fixtures/<name>` and add the frozen scratch files:
   `pr.diff`, `pr-meta.json` (shape of `gh pr view --json title,body,files`),
   `pr-commits.md`, `linked-issues.md`, `pr-comments.md`, `prev-review.md`
   (use the placeholder texts gather emits — e.g. `(no linked issues)` — when
   a file has no content).
2. Add `eval/fixtures/<name>/tree/` — the **post-PR state** of the invented
   project: every file the diff touches (with the diff applied) plus any
   module the touched code imports/references, so the checkout looks like a
   real PR head. `run.sh` copies `tree/` into the run dir root before
   `lib/passes.sh` runs, so the model's file reads land on real source
   instead of an empty project (a fixture without `tree/` still runs, but
   `run.sh` warns once that agentic file reads will see an empty project —
   this taints any finding that depends on reading beyond the diff).
3. `bash eval/freeze.sh eval/fixtures/<name>` — regenerates the derived
   `pr-numbered.diff` and `commentable-lines.tsv` from `pr.diff` with the
   same awk transforms as `lib/gather.sh`, and checks `tree/` for
   consistency: for every hunk in `pr.diff`, the added/context (new-side)
   lines must byte-match the `tree/` copy of that file at the same line
   offsets. A mismatch fails loudly, printing both the diff's line and the
   tree's line, so a stale or hand-edited `tree/` file can't silently drift
   from `pr.diff`. Re-run it whenever `pr.diff` or `tree/` changes.
4. For a scored fixture, add `eval/golden/<name>.tsv`
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
   all of them for you). `tree/` = the real PR-head checkout at
   `<pre-fix-head>`: `git worktree add`/`git archive` that commit and copy the
   result in, rather than hand-authoring it.
3. Golden TSV: one row pointing at the line the fix commit changed, with a
   description written from the fix commit message.

This repo's own `1b3e315` ("model input silently ignored") is a ready-made
seed. ~5–10 replay fixtures make prompt A/B results meaningful; the planted
fixtures stay the fast smoke gate.
