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
- **`recall_deep`** — of the bugs it found (right file/line), how many did
  it diagnose for the *right reason*? A golden row can carry an optional
  `mechanism` ERE (see below); a matched finding whose title+body doesn't
  match it is a **shallow hit** — right line, wrong explanation.
- **`recall_adjacent`** — bugs whose root cause lives in unchanged code next
  to the diff, matched by mechanism only (not line). Reported separately,
  never folded into the main recall numbers.

### Golden TSV columns 7–8 (optional, back-compat)

`id file line category sev description` is the original 6-column format and
still works unchanged. Two optional trailing columns add depth/adjacency
scoring:

- **`scope`** — `diff` (default, if omitted) or `adjacent`. `adjacent` means
  the bug's mechanism lives in code the diff didn't touch; it's matched by
  file + `mechanism` only (line is not part of the hit test), and it's
  reported under `recall_adjacent`, never the main recall.
- **`mechanism`** — a case-insensitive ERE matched against the winning
  finding's `title` + `body`. For `scope=diff` it's optional and splits a
  line-hit into deep (matches) vs. shallow (doesn't); for `scope=adjacent`
  it's **required** — it's the only way an adjacent bug is ever matched.
  Case-insensitivity works by lower-casing both the pattern and the text
  before matching, so avoid uppercase-only character classes (`[A-Z]`) in a
  mechanism ERE — they will never match.

Examples:

```
# scope=diff + mechanism: same-line hit graded deep vs. shallow
D01	lib/foo.py	10	logic	important	off-by-one undercounts	diff	skips the last

# scope=adjacent: only matched by mechanism, anywhere in the file
D03	lib/bar.py	5	race	important	counter never decremented by unchanged code	adjacent	counter is (never|not) decremented
```

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
- **`hard/`** — an invented job-queue + billing-ledger service (`queued/`,
  5 files) whose "feat: ad-hoc jobs, cancellation, lease tracking + ledger
  cleanup" PR plants **10 bugs** aimed squarely at the two gaps `scope`/
  `mechanism` scoring exists to measure: **4 deep-diagnosis** bugs where the
  same line also admits a different, wrong, equally-plausible finding (a
  wrong-denominator aggregation, a seconds-vs-milliseconds comparison, a
  `<`/`<=` boundary flip dressed up as cleanup, a `subtotal`/`total`
  near-twin mix-up that drops a discount); **3 adjacent/interaction** bugs
  whose mechanism lives in code the diff never touches (a newly-possible
  `None` hits an unchanged helper, a changed constant an unchanged check
  still assumes, a new lease counter whose unchanged release path never
  updates it); **2 omissions** (a dropped retry, a new status case missing
  from an unchanged label map); **1 easy control** (an obvious null-deref).
  Source at `eval/hard-src/{base,head}/`, answer key at `eval/hard-src/BUGS.md`
  (id/file/line/scope/category/mechanism/description + grep evidence) and
  `eval/golden/hard.tsv` (`eval/golden/hard.expect`: `RUNS_DEFAULT=3`).
  **Dual-use:** `eval/hard-src/{base,head}` also seed a second, permanently
  open live playground PR (see "Live playground PR" below) so the identical
  diff can be reviewed offline (this fixture) and live (Fable) side by side.
  Human review of the planted bugs is recommended before trusting this
  fixture for scoring.

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
2. Add `eval/fixtures/<name>/tree/` — the **post-PR state of the COMPLETE
   project**, not just the files the diff touches: every module the invented
   project ships, so the checkout looks like a real full PR-head checkout
   instead of an island of 2-4 files. `run.sh` copies `tree/` into the run
   dir root before `lib/passes.sh` runs, so the model's file reads — inside
   the diff's files or anywhere else in the project — land on real source
   instead of an empty/incomplete tree (a fixture without `tree/` still
   runs, but `run.sh` warns once that agentic file reads will see an empty
   project — this taints any finding that depends on reading beyond the
   diff). This matters most for `recall_adjacent` scoring (see `hard/`
   below): a bug whose mechanism lives in unchanged code is only findable if
   that unchanged code is actually present in the checkout.
   Files the diff touches keep whatever content the diff leaves them at —
   never hand-edit those. Files the diff does NOT touch are free supporting
   context: source them from the fixture's own other diff-touched files
   where a genuinely bug-free version already exists (reverse-apply the
   owning diff with `patch -R` to reconstruct a pre-bug base when needed),
   or hand-fix the one specific planted bug in a copy borrowed from a
   fixture that shares the same invented project, so a fixture's noise
   budget is never contaminated by another fixture's planted bug leaking in
   through an unrelated "context" file. Document every added/replaced file's
   source and reasoning in a `tree/PROVENANCE.md` — see
   `eval/fixtures/playground/tree/PROVENANCE.md` for the pattern.
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

## Live playground PR

Everything above runs against **frozen** context files — no GitHub, no
token, no `gh` calls. That's fast and deterministic, but it can't exercise
`lib/gather.sh`'s live fetches, `lib/post.sh`'s edit-in-place/prune logic,
the sticky comment's state block, skip/incremental re-review behavior on
follow-up pushes, or real GitHub-token scoping. For that we keep one
permanently-open PR the action reviews for real.

`eval/live-src/` holds the seed material: `base/` is the pre-PR project
state, `head/` is the PR with **8 seeded bugs** documented (id, file, line,
category, description) in `eval/live-src/BUGS.md` — the answer key. The bugs
are deliberately different from `eval/fixtures/playground/` (and scored
against a different golden file) so a hit here can't be confused with an
offline fixture result.

### One-time setup (maintainer only)

This repo does not create or manage this PR automatically — a human does,
and it must **stay open indefinitely** (do not merge or close it):

```bash
git checkout -b eval/live-playground main
cp -R eval/live-src/base/metrix .
git add metrix && git commit -m "chore: live playground base"
cp -R eval/live-src/head/metrix .
git add metrix && git commit -m "chore: live playground head (8 seeded bugs)"
git push -u origin eval/live-playground
gh pr create --draft --title "eval: live playground (do not merge)" \
  --body "Permanently-open PR for exercising the live review pipeline. See eval/live-src/BUGS.md for the seeded bugs. Do not merge." \
  --label do-not-merge --base main --head eval/live-playground
```

### Getting a fresh review

Re-running the workflow against the same PR normally reuses prior state
(skip/incremental behavior) — to force a full fresh pass while still
editing the same sticky comment, either:

- re-run the workflow manually with the `restart: true` input, or
- comment `@openreview restart` on the PR (trusted authors only).

Three operational facts learned live (2026-07-04):

- **Playground branches must NEVER contain the answer keys.** Branches cut
  from main after the fixture merge carry `eval/` — and a reviewer that
  greps the checkout can (and did, with disclosure) hit `BUGS.md`/golden
  files mid-review. Strip them: on the base branch `git rm -r eval && git
  commit`, merge into the head branch, push. Both playgrounds were
  decontaminated this way on 2026-07-04. **Extended 2026-07-06: strip
  `docs/` as well** — the improvement plan and task specs now describe the
  seeded bugs and their mechanisms (benchmark sections, wave-4 specs), so
  they are answer-key material too. `eval/refresh-playground.sh` (below)
  strips `eval`, `docs`, and `PROVENANCE.md` on every refresh.

- **The playground runs the PR branch's engine**, not main's (`uses: ./action`
  after checking out the PR head). After engine changes on main, refresh it
  with `eval/refresh-playground.sh <base-branch> <head-branch>`, e.g.
  `eval/refresh-playground.sh eval/live-playground-base eval/live-playground`
  — it merges main into the base branch, strips the answer-key material,
  then merges the base branch into the head branch the same way, and pushes
  both (never force, never touches main). Run it with cwd inside the repo
  clone you want refreshed; it refuses a dirty working tree or a missing
  branch, and always restores the branch you started on.
- **Display-only changes don't invalidate the skip guard** (by design — the
  fingerprint covers passes.sh/prompts/models, not render.sh), so a format
  upgrade won't re-render an already-reviewed PR on its own. Use
  `@openreview restart` to force a re-render.

### What this exercises that offline fixtures cannot

- `lib/gather.sh` against a real PR (diff, PR meta, comments, commits) with
  a real token.
- `lib/post.sh` posting, then editing in place, then pruning stale bot
  comments across re-runs.
- The sticky comment's state block surviving across runs.
- Skip/incremental review behavior on a no-op re-run vs. the `restart` path.
- Real GitHub token scoping (the model passes still run without a token).

**Note to the maintainer:** this task does not create the branch or PR — do
that manually using the steps above, and keep it open indefinitely.

### Scoring a live PR: `eval/compare.sh`

Both live reviewers post a `` ```tsv `` fenced machine-readable block in
their sticky comment (openreview always has; `claude-code-review.yml` was
updated 2026-07-06 to require the same block behind a hidden
`<!-- claude-review -->` marker — older comments predate this and are
skipped with a warning, not scored as zero). `eval/compare.sh <pr-number>
<answer-key.md>` fetches both comments (`gh api`, read-only, no `GH_TOKEN`
plumbing needed — ambient `gh auth`), extracts the newest of each, tolerates
both the 7-column openreview schema (`sev conf path line anchored title
body`) and the leaner 6-column schema, and matches findings against a
`BUGS.md`-style answer key (`eval/hard-src/BUGS.md`, `eval/live-src/BUGS.md`)
using the same file + line-within-±5 rule as `run.sh`. It also parses each
key's "Known unseeded true positives" section into a separate `extras` set
so a reviewer finding something real-but-unplanted scores as a match, not
noise.

```bash
# score the live hard playground PR
bash eval/compare.sh 22 eval/hard-src/BUGS.md

# score the live 8-bug playground PR
bash eval/compare.sh 19 eval/live-src/BUGS.md

# deterministic matcher self-test, no network
bash eval/compare.sh --selftest
```

Output: a per-reviewer `seeded found m/k` line with per-bug hit/miss,
`extras matched`, and an `unmatched findings` list for human triage (these
are *potential* new bugs or false positives — `compare.sh` never calls them
FPs automatically). Machine-readable rows land in
`eval/.work/compare-<pr>.tsv` (`reviewer \t bug_id \t hit(0|1)`). It always
exits 0 — this is a report, not a merge gate.

Note: `compare.sh` uses a single file+line rule for every key row, unlike
`run.sh`'s golden TSVs which score `scope=adjacent` bugs by mechanism only
(location-independent). `eval/hard-src/BUGS.md`'s three adjacent/interaction
bugs (A01–A03) list the unchanged-code crash *site* as their file/line, while
a live reviewer typically cites the diff line that *caused* it — so
`compare.sh` undercounts those relative to a mechanism-aware score. Read a
`compare.sh` "miss" on an adjacent-scope id alongside the reviewer's actual
comment text before concluding it was truly missed.
