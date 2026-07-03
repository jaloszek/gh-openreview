# Handoff-ready tasks

Self-contained tasks specced for delegation to a simpler coding agent
(Sonnet-class), one at a time. Each is deliberately narrow, has objective
acceptance criteria, and requires **no product decisions** — anything needing
judgment stays in `improvement-plan.md` until a human decides. Background
facts referenced as `IN §n` live in `implementation-notes.md`.

## Ground rules for every task (include in the handoff prompt)

- Bash 3.2 compatible (stock macOS): no `mapfile`, no associative arrays, no
  `${var,,}`. Plain awk/sed/grep; no new dependencies.
- stdout is reserved for command output; logs/progress go to stderr via the
  `common.sh` helpers (`log`/`info`/`warn`/`ok`/`die`). Never bare `echo` for
  status.
- No hard `jq` dependency — use `gh --jq`; pass values into jq filters via
  `env.VAR`, never string interpolation.
- Lint must pass before done: `shellcheck -S warning lib/*.sh` and
  `actionlint .github/workflows/*.yml`.
- Do not touch trigger/security logic beyond what the task states; read
  `SECURITY.md` first if the task touches `action/action.yml`.
- One task = one focused commit (`fix:`/`feat:`/`docs:` conventional prefix).

Recommended execution order: 01 → 02 → 03 → 04 → 05 → 13 → 06 → 08 → 07 →
10 → 11 → 09 (09 is the largest; 12 is independent). Dependencies are noted
per task; tasks without a dependency note are independent.

---

## TASK-01 — Pin the opencode version in the action (plan item T0-2)

**Files:** `action/action.yml` (install step), `README.md` (one line).

**Spec:** The install step currently runs the opencode install script
unpinned. Add an action input `opencode-version` (default: an exact known-good
version, e.g. `1.17.13` — check https://github.com/anomalyco/opencode/releases
for the latest at implementation time and use that). Pass it to the install
script: `curl -fsSL https://opencode.ai/install | bash -s -- --version
"$VERSION"` (the script also honors a `VERSION` env var; either is fine —
verified IN §1). If opencode is already on PATH with the right version, skip
install. Empty input value = latest (documented as not recommended).

**Acceptance criteria:**
- `action/action.yml` has the new input with an exact-version default and a
  description saying why pinning matters (1–3-day upstream release cadence).
- Install step uses the input; `actionlint` passes.
- README's inputs table documents the input.

## TASK-02 — Harden the bundled `opencode.json` (plan item T0-1)

**Files:** `opencode.json` (bundled config), `SECURITY.md` (short note).

**Spec (facts verified IN §1):** opencode's permission schema grew; path
containment is now the `external_directory` permission whose default (`ask`)
**hangs forever in headless CI**. Permission denies alone have documented
bypasses (subagents via the `task` tool bypass read/grep denies). Update the
bundled config to:
1. `tools`: set `bash`, `webfetch`, `websearch`, `task` to `false` (tool
   removal — the model never sees them).
2. `permission`: explicit values for every key — `bash: deny`,
   `webfetch: deny`, `websearch: deny`, `external_directory: deny`,
   `doom_loop: deny`, and explicit `allow` for `read`, `edit`, `glob`,
   `grep`; no key left at an implicit default that could resolve to `ask`.
3. Add `small_model` set to the same free default model as the action's
   `model` input default (keeps internal tasks like title generation off the
   paid tier).
4. Validate the result against the schema at `https://opencode.ai/config.json`
   (add `"$schema"` if absent).

**Acceptance criteria:**
- No permission can resolve to `ask` in headless runs.
- `task` tool disabled in both `tools` and `permission`.
- SECURITY.md's layer-1 description updated to mention `external_directory`
  and the tools-removal layer.
- JSON is valid (parse with `gh api graphql` not needed — `python3 -m
  json.tool` or `node -e` check is fine locally; keep the file plain JSON).

## TASK-03 — Word-boundary trigger match (security quick win)

**Files:** `action/action.yml` (ctx/trigger step).

**Spec:** The `issue_comment` trigger currently uses `grep -qF
"$TRIGGER_PHRASE"` — a substring match, so the phrase quoted anywhere inside a
trusted user's comment fires a run. Replace with a word-boundary regex match:
the phrase must appear as a standalone token (start-of-line or preceded by
whitespace, followed by end-of-line, whitespace, or punctuation). Escape regex
metacharacters in the configured phrase before embedding it (default phrase
`@openreview` contains none, but the input is user-configurable). Keep it
POSIX grep -E compatible (no `\b` — use explicit classes like
`(^|[[:space:]])PHRASE([[:space:][:punct:]]|$)`).

**Acceptance criteria:**
- `@openreview` at line start, mid-sentence, and end-of-comment still
  triggers; `foo@openreviewbar` and `` `@openreview` `` quoted inside a word
  do not. Include the test evidence (a few `grep` invocations with sample
  strings) in the PR/commit description.
- `actionlint` passes.

## TASK-04 — Ingress sanitization: strip invisible Unicode in gather (T0-4a)

**Files:** `lib/gather.sh`, new helper function in `lib/common.sh`.

**Spec (ranges verified IN §4):** Add a `sanitize_text` filter applied to
every fetched *text* context file (`pr-meta.json` values are left alone;
apply to `pr.diff`, `linked-issues.md`, `pr-commits.md`, `pr-comments.md`,
`prev-review.md`). Strip these codepoint ranges: tag block U+E0000–U+E007F,
zero-width U+200B–U+200D and U+FEFF, bidi controls U+202A–U+202E and
U+2066–U+2069, variation selectors U+FE00–U+FE0F and U+E0100–U+E01EF.
Implementation: a single `perl -CSD -pe 's/[\x{E0000}-\x{E007F}...]//g'` pass
(perl is present on ubuntu runners and macOS; guard with `command -v perl` and
warn+skip if absent). Count stripped characters; if >0, emit a `warn` and a
`::notice::` naming the file (visibility rule: coverage/content changes are
never silent).

**Acceptance criteria:**
- Helper in `common.sh`, used by `gather.sh` on the listed files.
- A file containing e.g. `U+200B` and `U+E0041` comes out clean; normal UTF-8
  (accents, CJK, emoji) passes through unchanged — show test evidence.
- Non-zero strip count produces a notice. `shellcheck` passes.

## TASK-05 — Egress sanitization in render (T0-3)

**Files:** `lib/render.sh`.

**Spec (rationale IN §4 — CamoLeak, mention-spam):** All model-authored text
that reaches the posted comment (finding `title`, `body`, and the whole
`@@PRDESC` block) must be defanged before rendering:
1. `@mentions`: wrap every `@[A-Za-z0-9-]+(/[A-Za-z0-9._-]+)?` token in
   backticks (GitHub does not notify for mentions inside code spans). Skip
   tokens already inside backticks.
2. Issue/PR refs: wrap `#[0-9]+` and `owner/repo#[0-9]+` tokens in backticks
   the same way.
3. Markdown images: `![alt](url)` → `[image removed: alt]`. Inline HTML
   `<img`, `<picture`, `<script`, `<iframe` tags and HTML comments
   `<!-- -->` → stripped.
4. Markdown links `[text](url)`: keep `text`, render url as a code span:
   `text (`url`)` — links become non-clickable but auditable.
5. Re-apply the TASK-04 invisible-Unicode strip to outbound text.
6. Length-cap the rendered PRDESC section at 4000 chars (truncate with a
   `[truncated]` marker).
Apply in the awk/renderer stage so `opencode-review.md` is already clean —
`post.sh` needs no change. Do NOT alter our own fixed template text (marker
header, table headers), only model-sourced fields.

**Acceptance criteria:**
- Given a crafted `review-verified.md` containing `@someuser`, `#123`,
  `![x](http://evil/p.png)`, `<img src=…>`, an HTML comment, and a markdown
  link, the rendered comment contains no active mention/ref/link/image/HTML —
  show before/after in test evidence.
- Legitimate content (code spans, plain prose, the finding table) renders
  unchanged. `shellcheck` passes.

## TASK-06 — Confidence gating in render (plan item K)

**Files:** `lib/render.sh`, `action/action.yml` (new input), `README.md`.

**Spec:** `render.sh` already parses `conf: high|med|low` and uses it only
for ordering. Add:
1. New env `OPENREVIEW_MIN_CONF` (action input `min-confidence`, default
   `low` = today's behavior, allowed values `low|med|high`). Findings below
   the threshold are dropped from the rendered comment but still counted in
   a new metrics line (`suppressed by confidence gate: N`) and in
   `metrics.env` as `FINDINGS_SUPPRESSED`.
2. Independent hard rule (always on): a `conf: low` finding is never rendered
   as 🔴 Important — demote it to nit for rendering purposes (keep original
   sev in the details block for transparency).
3. Unknown/missing `conf:` values are treated as `low` (defensive).

**Acceptance criteria:**
- Default behavior unchanged except low-conf importants render as nits.
- `min-confidence: med` drops low-conf findings entirely, with the count
  visible in the step summary (via `metrics.sh` reading the new var).
- Deterministic: same input → same output. `shellcheck` + `actionlint` pass.

## TASK-07 — Do-not-flag kill-list in the prompts (plan item M′)

**Files:** `lib/passes.sh` only (prompt text).

**Spec:** Two prompt edits, exact text below (may be lightly reflowed):
1. Generate prompt — add after the existing noise rules:
   "NEVER report any of the following, regardless of severity: pre-existing
   issues not introduced by this diff; formatting/style preferences; purely
   speculative problems ('could potentially', 'might in theory') without a
   concrete failure path; anything a standard linter or compiler would catch;
   generic security advice not tied to a specific flaw in this diff;
   suggestions to add docstrings, comments, or type hints; suggestions to
   remove unused imports; advice to 'verify' or 'ensure' something without
   evidence it is wrong; claims about symbols defined outside this diff that
   you have not opened and read. If you are not certain an issue is real, do
   not flag it."
2. Verify prompt — add as an explicit DROP criterion (deterministic, not a
   judgment call): "4. DROP any finding that falls into these categories even
   if it seems valid: docstring/comment/type-hint suggestions; unused-import
   removal; 'verify/ensure that…' advice without demonstrated incorrectness;
   pure style/formatting; findings about code outside pr.diff; findings whose
   suggested fix does not change behavior."
Do not change the record format, file paths, or any non-prompt logic.

**Acceptance criteria:**
- Both prompts contain the lists; `FORMAT_SPEC` untouched; `shellcheck`
  passes. (Behavioral validation happens via TASK-09's eval harness — run it
  before/after if it exists at implementation time and report the numbers.)

## TASK-08 — Line-numbered hunk re-encoding + anchor validation (plan item R)

**Files:** `lib/gather.sh` (new awk transform + new output file),
`lib/passes.sh` (prompt reference), `lib/render.sh` (validation).
**Depends on:** none (but land before any inline-comments work).

**Spec (format precedent IN §2 and `competitors.md` §1):**
1. In `gather.sh`, after `pr.diff` is finalized, generate `pr-numbered.diff`:
   for each hunk, prefix every unchanged/added line with its **new-file line
   number** right-aligned in a fixed 6-char column followed by `| ` (compute
   from the `@@ -a,b +c,d @@` headers in awk; deleted lines get 6 spaces +
   `| `). Keep the `diff --git` / `@@` structure intact. Also emit
   `commentable-lines.tsv`: `path<TAB>line` for every new-file line present
   in any hunk (added or context) — derived from the **same untrimmed** diff
   before exclusions/caps are applied, so validation is not fooled by
   trimming.
2. In `passes.sh`, point both passes at `$S/pr-numbered.diff` instead of
   `$S/pr.diff`, and add one line to each prompt: "Line numbers are printed
   at the start of each line — copy them exactly into loc:, never compute
   line numbers yourself."
3. In `render.sh`, validate each finding's `loc:` against
   `commentable-lines.tsv`: exact `path:line` present → keep; same path with
   the line within ±3 of a commentable line → snap to the nearest commentable
   line and keep (note the adjustment in the details block); otherwise mark
   the finding `[unanchored]` in its details block (do not drop it). Emit
   counts to `metrics.env` (`FINDINGS_UNANCHORED`).

**Acceptance criteria:**
- `pr-numbered.diff` line numbers match `awk` recomputation on 3 sample
  diffs including: multi-hunk file, new file, file with deletions only.
- `commentable-lines.tsv` contains added + context new-side lines and nothing
  from excluded paths' beyond-cap regions (it uses the untrimmed diff).
- Findings with fabricated locs get `[unanchored]`; valid locs unchanged.
- `shellcheck` passes; the eval fixture (TASK-09) still parses.

## TASK-09 — Eval harness (plan item X; design IN §3)

**Files:** new `eval/` tree, no changes to `lib/` (read-only consumer).
**Depends on:** none. **Note:** fixture bug-seeding output requires human
review before merge — flag the PR for it.

**Spec:**
1. `eval/fixtures/playground/` — a frozen scratch dir: `pr.diff` (a realistic
   multi-file diff over a small invented project — 3–5 files, mixed
   languages ok), `pr-meta.json`, `pr-commits.md`, `linked-issues.md`,
   `pr-comments.md`, `prev-review.md` (matching the shapes `gather.sh`
   produces today — copy real structures from a dry run). Seed **12 bugs**:
   2× logic/off-by-one, 2× null/edge case, 2× error handling, 1× resource
   leak, 1× race, 2× security, 1× convention violation, 1× subtle/hard. Keep
   bug density realistic (bugs embedded in plausible surrounding change).
2. `eval/fixtures/clean/` — a second frozen scratch dir whose diff is
   verified clean (refactor/rename-only).
3. `eval/golden/playground.tsv`: `id  file  line  category  sev  description`
   (tab-separated; `line` = the buggy line in the new file).
4. `eval/run.sh`: args `[fixture…]` (default: all). For each fixture ×
   `EVAL_RUNS` (default 1): copy fixture → fresh temp scratch under
   `eval/.work/`, export the env contract (`OR_DIR`, `SCRATCH`,
   `SCRATCH_REL`, models from env), run `lib/passes.sh` then `lib/render.sh`,
   parse `@@FINDING` records, match to golden: same file AND line within ±5
   → hit. Print per-fixture: recall (overall, important-only, per category),
   precision (matched/total), finding + nit counts, per-bug `found m/k`
   column; for `clean`: **exit non-zero if any important finding** appears.
   Machine-readable TSV scorecard written to `eval/.work/scorecard.tsv`.
   No GitHub token needed anywhere.
5. `eval/README.md`: how to run, env vars, how to add a replay fixture
   (freeze pre-fix state of a real fix commit; the fix is the golden).

**Acceptance criteria:**
- `EVAL_RUNS=1 eval/run.sh playground` completes locally with only
  `OPENREVIEW_MODEL` set, printing the scorecard; `eval/run.sh clean` exits
  0 on a clean result and non-zero when fed a doctored non-clean output.
- Matching logic covered by a tiny self-test (`eval/run.sh --selftest`
  matches a canned findings file against the golden TSV with known expected
  hits/misses — no LLM call).
- `shellcheck -S warning eval/run.sh` passes; `eval/.work/` gitignored.

## TASK-10 — Diff compression ladder (plan item P)

**Files:** `lib/gather.sh`.
**Depends on:** TASK-08 (operates on the same hunk-parsing awk).

**Spec (recipe IN `competitors.md` §1):** Replace the blunt `head -n
$OPENREVIEW_DIFF_MAX_LINES` with, applied only when the diff exceeds the
budget:
1. Strip deletion-only hunks; reduce fully-deleted files to a name under a
   `## Deleted files (not shown)` list appended to the diff.
2. Rank remaining file-patches: source-code files first (anything not
   matching the generated/vendored exclude classes), then by patch line count
   descending.
3. Greedily add whole file-patches until the line budget; never cut inside a
   file's patch.
4. Append `## Files not shown (over budget)` naming every file that did not
   fit, with its +/- line counts.
5. Keep the existing `::notice::` + warn behavior, now reporting
   included/omitted file counts.

**Acceptance criteria:**
- Under-budget diffs pass through byte-identical (except no trailing
  truncation marker).
- Over-budget: output ≤ budget lines (+ the two appended lists), files never
  split mid-patch, omitted files all named. Test with a synthetic 3-file
  diff and a budget forcing one file out — show evidence.
- `shellcheck` passes; `DIFF_LINES` metric still written.

## TASK-11 — Per-pass token/cost telemetry (backlog telemetry item)

**Files:** `lib/common.sh` (`oc_run`), `lib/metrics.sh`.
**Depends on:** TASK-01 (pinned version; the step_finish early-exit bug is
fixed only in recent releases — IN §1).

**Spec:** Add `--format json` to the `opencode run` invocation in `oc_run`.
Tee the JSONL to a per-pass file `$SCRATCH/oc-<pass>.jsonl` while still
discarding it from stdout (stdout stays clean). After the run, extract from
the **last** `step_finish` event: `cost`, `tokens.input`, `tokens.output`,
`tokens.reasoning`, `tokens.cache.read`, `tokens.cache.write` (parse with
awk/sed — the events are one JSON object per line; a tolerant regex extract
is acceptable, no jq). Append `PASSn_COST`, `PASSn_TOKENS_IN/OUT`,
`PASSn_CACHE_READ` to `metrics.env`; degrade gracefully (empty values, one
`warn`) if the event is missing. `metrics.sh` adds cost/token columns to the
step summary table and a `total-cost` action output.

**Acceptance criteria:**
- A local run against the eval fixture shows per-pass cost/tokens in the
  summary output; absence of step_finish does not fail the pipeline.
- Model text output/behavior unchanged (the JSON format only affects the
  event stream). `shellcheck` + `actionlint` pass.

## TASK-12 — Config-replacement warning (security quick win)

**Files:** `lib/common.sh` (`prepare_opencode_config`).

**Spec:** When config resolution selects anything other than the bundled
`opencode.json` (i.e. `OPENCODE_CONFIG` env, project config, or user config
wins), emit a `warn` + `::notice::`: "using <path> instead of the bundled
hardened config — ensure it denies bash/webfetch/websearch and sets
external_directory: deny (see SECURITY.md)". Additionally, best-effort:
grep the selected config for `"bash"` and warn specifically if no deny/false
setting for bash is detectable. No behavior change — warning only (config
precedence is a documented contract; do not alter it).

**Acceptance criteria:**
- Bundled-config runs stay silent; a project-level `opencode.json` triggers
  exactly one notice; a project config without a bash denial triggers the
  second, specific warning. `shellcheck` passes.

## TASK-13 — PR-description rating replaces the PRDESC suggestion (plan item PD)

**Files:** `lib/passes.sh` (FORMAT_SPEC + both prompts), `lib/render.sh`.
**Decided design (Decisions log #5 in `improvement-plan.md`) — no judgment
calls needed.**

**Spec:**
1. In `FORMAT_SPEC`, replace the `@@PRDESC` trailer definition with:
   ```
   Then ALWAYS end the file with exactly:
   @@PRDESC
   rating: good | could-be-improved | poor
   reason: one short line explaining the rating (omit this line when rating is good)
   ```
   Criteria to state in the spec text: `poor` = the PR description is empty,
   extremely outdated, or contradicts what the diff actually does;
   `could-be-improved` = major gaps but acceptable to merge as-is;
   `good` = everything else. The model must NOT write a replacement
   description — rating + reason only.
2. `render.sh`: parse the two fields defensively (unknown/missing rating →
   treat as `good`, i.e. render nothing). On `poor` or `could-be-improved`,
   render one line at the end of the comment:
   `> 📝 PR description: **<rating>** — <reason>` (reason passes through the
   TASK-05 egress sanitizer). Remove the old collapsed
   "Suggested PR description" block and its `.prdesc.md` plumbing.
3. Verify pass: no change needed beyond the shared FORMAT_SPEC (the verify
   prompt reuses it); confirm it does not re-rate.

**Acceptance criteria:**
- A findings file with `rating: good` renders no description section; `poor`
  + reason renders the single quoted line; missing/garbled trailer renders
  nothing and does not break finding parsing.
- No code path generates or echoes a suggested description anymore.
- `shellcheck` passes; eval fixture (TASK-09) golden flow unaffected.

## TASK-14 — Edit-in-place sticky comment (plan item S; decided 2026-07-03)

**Files:** `lib/post.sh`, `action/action.yml` (new input), `README.md`.
**Facts (verified IN §2):** `PATCH /repos/{o}/{r}/issues/comments/{id}`
updates a comment; editing does not notify watchers; body limit 65,536 chars
(budget 60k).

**Spec:**
1. `post.sh`: instead of always creating a new comment and pruning old ones —
   find the newest existing comment by `AUTHOR_LOGIN` containing
   `MARKER_MATCH`; if found, `PATCH` its body with the fresh
   `opencode-review.md`; if none, `POST` a new one. Keep the existing prune
   loop only for *extra* duplicates (older marker comments beyond the one
   edited/created). Append a final line to the body:
   `_Updated for commit <head-sha> at <UTC timestamp>_` (head SHA from
   `pr-meta.json`/env; add it to gather's meta fetch if absent).
2. Truncate the body deterministically at 60,000 chars with a
   `[comment truncated]` marker before posting (never let the API 422).
3. New action input `update-ping` (default `false`): when `true` and the run
   *edited* an existing comment and has ≥1 important finding, post a
   one-line extra comment `🔔 Review updated — <n> important finding(s); see
   the review comment above.` (this one is not marker-tagged and is pruned
   on the next run).
4. Local (non-CI) behavior unchanged in spirit: same logic via `gh api`.

**Acceptance criteria:**
- Two consecutive runs on the same PR produce ONE marker comment whose body
  reflects the second run and whose comment id is unchanged.
- First-ever run creates the comment; `update-ping: true` adds the ping only
  on updates with important findings; next run removes stale pings.
- Oversized render output is truncated, not failed. `shellcheck` +
  `actionlint` pass.

## TASK-16 — Incremental review + state block (plan item G; decided: auto + incremental)

**Files:** `lib/post.sh`, `lib/gather.sh`, `lib/common.sh` (helper),
`action/action.yml` (env plumbing only if needed), `README.md`.
**Depends on:** TASK-14 (edit-in-place, merged). **Facts:** IN §2
(patch-id semantics, ancestry checks, HTML-comment state, force-push
signals).

**Spec:**
1. **State write (post.sh):** when posting/editing the sticky comment,
   embed a hidden state block as the LAST line of the body:
   `<!-- openreview:state <base64> -->` where `<base64>` encodes one line of
   JSON: `{"v":1,"last_sha":"<head sha reviewed>","patch_id":"<id>"}`.
   Base64 avoids `-->` and quoting issues. `head sha` = the SHA gather
   recorded; `patch_id` comes from a new file `$SCRATCH/patch-id` written by
   gather (step 3). Build the JSON with printf, base64 with the `base64`
   binary (present on runners/macOS).
2. **State read (gather.sh):** when fetching the previous bot comment (it
   already finds it for `prev-review.md`), also extract the state block:
   grep the raw body for `openreview:state ([A-Za-z0-9+/=]+)`, decode,
   parse `last_sha` and `patch_id` with sed (no jq). Tolerate absence or
   garbage (treat as no state). Normalize CRLF before matching.
3. **Patch-id (gather.sh):** compute
   `git diff "$(git merge-base <base> HEAD)" HEAD | git patch-id --stable`
   (first field) and write it to `$SCRATCH/patch-id`. Base ref: the PR base
   SHA from `pr-meta.json` (add `baseRefOid` to the `gh pr view --json`
   field list if missing).
4. **Skip-if-identical:** if state `patch_id` equals the freshly computed
   one, write `SKIP_REVIEW=1` to `$SCRATCH/metrics.env`, emit an
   `::notice::` ("diff unchanged since last review — skipping"), and exit 0
   from gather with a sentinel file `$SCRATCH/skip-review`. In
   `action/action.yml`, gate the passes/render/metrics/post steps'
   existing `if:` conditions additionally on the sentinel file NOT existing
   (a tiny `test ! -f` guard step or hashFiles-style check — keep it simple:
   each subsequent step's script begins with
   `[ -f "$SCRATCH/skip-review" ] && { echo "skipped"; exit 0; }`).
5. **Incremental diff:** if state exists, `last_sha` differs from HEAD, and
   BOTH `git cat-file -e <last_sha>` and
   `git merge-base --is-ancestor <last_sha> HEAD` succeed → produce an
   ADDITIONAL file `$SCRATCH/pr-incremental.diff` = `git diff
   <last_sha>..HEAD` (two-dot), run through the same exclude filter, and
   prepend one line to the prompt context via a new file
   `$SCRATCH/incremental-note.md`: "This PR was previously reviewed at
   <last_sha>. pr-incremental.diff contains only the changes since then —
   focus your review there; the full diff is still in pr-numbered.diff for
   context." `passes.sh`: if `incremental-note.md` exists, include it and
   `pr-incremental.diff` in the pass-1 context list. On ancestry failure
   (force-push/rebase) fall back silently to full review (no incremental
   files).
6. The full diff pipeline (numbered diff, commentable lines, compression)
   stays untouched — incremental is additive context, not a replacement
   (KISS; a later iteration may trim the full diff when incremental).

**Acceptance criteria:**
- Round-trip: a state block written by post.sh is parsed back by gather.sh
  (test with a canned comment body incl. CRLF variant).
- Same-diff skip: with a canned previous state whose patch_id matches, the
  sentinel is written and downstream steps would no-op (show the guard
  firing locally).
- Force-push: with a bogus `last_sha`, no incremental files are produced and
  the run proceeds as full review.
- `shellcheck` + `actionlint` pass; state block survives the 60k truncation
  guard (truncate BEFORE appending the state line, never after).

## TASK-17 — Opt-in inline review comments (plan item J; decided: opt-in, COMMENT-only)

**Files:** `lib/render.sh` (emit findings TSV), `lib/post.sh`,
`action/action.yml` (new input), `README.md`.
**Depends on:** TASK-08 (anchor validation, merged). **Facts:** IN §2
(atomic review POST, PENDING pitfall, 422 semantics, minimizeComment).

**Spec:**
1. New input `comment-style`: `summary` (default, today's behavior) |
   `both` (summary comment + inline review). Env `OPENREVIEW_COMMENT_STYLE`.
2. `render.sh`: additionally write `$SCRATCH/findings.tsv` — one row per
   RENDERED finding: `sev<TAB>conf<TAB>path<TAB>line<TAB>anchored(0|1)<TAB>title<TAB>body`
   (body single-line, already egress-sanitized; `anchored` from the TASK-08
   validation result).
3. `post.sh`, when style=`both` and findings.tsv has ≥1 row with
   `sev=important` AND `anchored=1`:
   a. Clean up: list this PR's reviews by `AUTHOR_LOGIN` whose body contains
      `<!-- openreview:inline -->`; for each, minimize it via GraphQL
      `minimizeComment` (classifier `OUTDATED`) — query review node ids via
      GraphQL, guard with `viewerCanMinimize`; also delete any PENDING
      review by the bot (GET reviews, state PENDING → DELETE) so a crashed
      run never blocks posting.
   b. Build one JSON payload (a temp file, then
      `gh api repos/{o}/{r}/pulls/<n>/reviews --method POST --input file`):
      `event: "COMMENT"`, `body: "🤖 Inline findings from the OpenCode
      review — details in the summary comment.\n<!-- openreview:inline -->"`,
      `commit_id`: the head SHA gather recorded, and `comments[]`: for each
      qualifying finding — `path`, `line` (integer), `side: "RIGHT"`,
      `body`: `**<title>**\n\n<body>\n\n_Confidence: <conf>_`. Escape JSON
      strings correctly (printf %s + sed escaping, or build with `gh api`'s
      `--input` and a small awk JSON emitter — NO string interpolation into
      shell single-quotes).
   c. If the POST fails (any 4xx): log the error body as a `warn`, do NOT
      retry per-comment, and continue — the summary comment already carries
      every finding (fallback-by-design). Never fail the step over inline
      posting.
4. Never post APPROVE/REQUEST_CHANGES anywhere (decision #3). Suggestion
   blocks are OUT of scope for this task.
5. README: document the input and the fallback semantics.

**Acceptance criteria:**
- style=summary: byte-identical behavior to today (no findings.tsv
  consumers run).
- style=both with a canned findings.tsv (2 anchored importants, 1
  unanchored, 1 nit): payload JSON contains exactly the 2 anchored
  importants with side RIGHT and integer lines; `event` is COMMENT; body
  carries the inline marker. Validate the JSON with `python3 -m json.tool`.
- Simulated 422 (feed a bogus line): step still exits 0 and the summary
  comment flow is untouched.
- `shellcheck` + `actionlint` pass.

## TASK-18 — Free-tier data-retention warning (decision #1)

**Files:** `README.md`, `SECURITY.md`.

**Spec:** Add a short, prominent warning near the top of README (right
after the default-model mention) and a subsection in SECURITY.md: the
bundled default model runs on opencode Zen's free tier, and free-tier
traffic **may be used for model improvement/training** (paid tiers are
documented as zero-retention). Recommend setting `model`/`cheap-model` to a
paid tier (e.g. `opencode/deepseek-v4-flash`) for private or sensitive
code. One paragraph each, no restructuring.

**Acceptance criteria:** warning present in both files, factually phrased
as above; no other content changed.

## TASK-19 — Eval runner: per-fixture expectations (budgets + must-catch)

**Files:** `eval/run.sh`, `eval/README.md` (small updates), selftest assets.
**Branch note:** eval lives on `feat/eval-harness` — implement there.
**Context:** `eval/README.md` "Planned fixtures" section explains the three
review scenarios this enables. The golden TSV can only express "find
these"; budgets and hard requirements need a second, optional file.

**Spec:**
1. New optional per-fixture file `eval/golden/<name>.expect` — plain
   KEY=VALUE lines (bash-parseable with grep/cut, `#` comments allowed):
   - `MAX_IMPORTANTS=<n>` — rendered important findings above n ⇒ FAIL
   - `MAX_NITS=<n>` — rendered nits above n ⇒ FAIL
   - `MAX_TOTAL=<n>` — total rendered findings above n ⇒ FAIL
   - `MUST_CATCH=<id,id,…>` — golden ids that must be matched (union
     across runs) by a finding rendered as `important` ⇒ else FAIL
   - `RUNS_DEFAULT=<k>` — repetitions when the `EVAL_RUNS` env var is not
     explicitly set (env always wins)
2. Grading matrix by files present:
   - golden only → today's behavior (recall/precision, no hard fail).
   - golden + expect → recall/precision AND budget/must-catch enforcement.
   - expect only (no golden) → budget-only fixture (e.g. `quiet`): skip
     recall/precision, enforce budgets.
   - neither → clean control (today's behavior: any important ⇒ FAIL).
3. Violations: print a clear `✗ expectation failed: <detail>` line per
   violation, add rows to `scorecard.tsv`
   (`<fixture> expect_<key> pass|fail`), and make `run.sh` exit non-zero if
   any fixture failed expectations (aggregate at the end, don't abort other
   fixtures).
4. Extend `--selftest` with canned cases: budget pass, budget fail
   (too many nits), must-catch hit, must-catch miss, expect-only fixture.
5. README: replace the "(Implementation note: …runner extension…)"
   parenthetical with a short "Expectations files" subsection documenting
   the keys; also correct the noisy-fixture line — the eval does NOT run
   `gather.sh`, so the compression ladder is NOT exercised here; noisy
   fixtures must stay within the diff budget.

**Acceptance criteria:**
- `bash eval/run.sh --selftest` passes with the five new canned cases.
- A doctored expect file (MAX_NITS=0 against a findings file with a nit)
  makes the fixture and the overall run exit non-zero with the ✗ line.
- Existing playground/clean behavior unchanged when no expect file exists.
- `shellcheck -S warning eval/*.sh` clean.

## TASK-20 — Scenario fixtures: quiet / subtle / noisy

**Files:** `eval/fixtures/{quiet,subtle,noisy}/`, `eval/golden/`.
**Depends on:** TASK-19 (expect files). **Branch:** `feat/eval-harness`.
**Human review of planted bugs required before merge — flag it.**
Design rationale: `eval/README.md` "Planned fixtures" section.

**Spec — build each fixture per the "Adding a fixture" recipe (write
`pr.diff` + context files, then `bash eval/freeze.sh …`):**
1. **`quiet/`** — a small real change to the existing `metrix` project
   shape (e.g. add a `--format json` CLI flag + README blurb, ~60-100 diff
   lines), containing NO real bugs but salted nit bait: one slightly vague
   variable name, one magic number, one missing docstring. Context files
   say it's a routine small feature. NO golden TSV.
   `quiet.expect`: `MAX_IMPORTANTS=0`, `MAX_NITS=2`.
2. **`subtle/`** — a small diff (~120-180 lines) that reads as an innocent
   refactor of 2 files but introduces EXACTLY 3 real bugs at different
   depths: (a) two assignments reordered creating use-before-set /
   stale-value read, (b) a boundary condition silently changed while
   extracting a helper (`<` vs `<=` moved into the helper), (c) an error
   path dropped while inlining (exception swallowed or early-return lost).
   PR title/body must sell it as "refactor: extract helpers, no behavior
   change". Golden TSV with the 3 bugs (`sev: important`).
   `subtle.expect`: `RUNS_DEFAULT=5` only — no must-catch (subtle misses
   are signal, not build failures).
3. **`noisy/`** — a big PR: 10-14 files, ~1800-2500 diff lines (UNDER the
   4000 default budget — see TASK-19 note), mixing legitimate churn (moved
   code, renamed modules, config/docs updates) with planted bugs:
   3 critical (data loss / security / crash-on-common-path; ids C01-C03),
   4 moderate (ids M01-M04), plus nit bait scattered around. Golden TSV
   with all 7. `noisy.expect`: `MUST_CATCH=C01,C02,C03`, `MAX_NITS=3`,
   `MAX_TOTAL=12`.
   Keep planted bugs >10 lines apart (matcher limitation).
4. All three reuse/extend the invented Python project style; context files
   follow the same placeholder conventions as playground.

**Acceptance criteria:**
- `eval/run.sh --selftest` still passes; `freeze.sh` regenerates derived
  files cleanly for all three (commit the derived files).
- Golden line numbers verified present in each fixture's
  `commentable-lines.tsv`.
- A dry parse (no LLM): feeding each fixture's canned
  `review-verified.md`-style sample through the scoring path exercises the
  expect rules (include one canned sample per fixture under
  `eval/selftest/`).
- README fixture list updated (move quiet/subtle/noisy from "planned" to
  "current", one line each).

## TASK-21 — Kotlin console-app fixture

**Files:** `eval/fixtures/kotlin/`, `eval/golden/kotlin.tsv`.
**Depends on:** TASK-19. **Branch:** `feat/eval-harness`.
**Human review of planted bugs required before merge — flag it.**

**Spec:** Multi-language coverage — reviewer behavior differs by language,
and Kotlin has bug classes Python cannot express. Invent a small, idiomatic
Kotlin **console app** (a CLI expense tracker: `Main.kt`, `Ledger.kt`,
`Parser.kt`, `Report.kt`, ~300-400 lines total base) that would plausibly
compile — correct imports, types, and syntax (reviewed by eye; NO Kotlin
toolchain is added and nothing is compiled — fixtures are frozen text).
The PR diff (~250-350 lines, title "feat: add budgets and monthly report")
plants **8 bugs**, majority Kotlin-specific:
1. `!!` on a nullable lookup that can legitimately be null (K01, null-edge)
2. `lateinit var` accessed on a path that can run before init (K02)
3. structural vs reference equality: `===` used where `==` intended (K03)
4. `when` over an enum made non-exhaustive by a newly added enum case,
   no `else` — compiles as statement but silently skips (K04, logic)
5. integer division in money math: `amount / count` on `Int`s (K05, logic)
6. `runCatching { … }` whose failure result is dropped (`.getOrNull()`
   without handling), swallowing a parse error (K06, error-handling)
7. a `MutableList` shared across coroutines without synchronization
   (K07, race)
8. off-by-one: `until` swapped to `..` (or vice versa) in a range over
   indices (K08, logic/off-by-one)
Golden TSV with categories mapped to the existing taxonomy; `sev`
important for all except K03 if placed in a low-impact spot (author's
call, document it). No expect file (recall fixture, like playground).
Context files: realistic PR body, 2-3 commit messages, no linked issue.

**Acceptance criteria:**
- `freeze.sh` output committed; golden lines present in
  `commentable-lines.tsv`; bugs >10 lines apart.
- The base app code is coherent Kotlin (types/imports consistent, no
  pseudo-code) — spot-checkable by a Kotlin reader.
- README fixture list gains one line for `kotlin/`.
- `eval/run.sh --selftest` unaffected.

## TASK-22 — Restart flag + engine fingerprint for the skip guard

**Files:** `lib/gather.sh`, `lib/common.sh` (fingerprint helper),
`lib/post.sh` (state field), `action/action.yml` (input + comment parsing),
`README.md`.
**Depends on:** TASK-16 (incremental review) being merged — implement on a
branch based on the branch/commit that contains it (PR #10 /
`feat/incremental-inline`), or on main after it merges.
**Rationale:** (a) permanently-open eval PRs need repeatable fresh reviews
without recreating the PR; (b) TASK-16's patch-id skip would wrongly skip
re-review after PROMPT/MODEL changes — the engine changed even though the
diff didn't.

**Spec:**
1. **`restart` input** (default `false`) → env `OPENREVIEW_RESTART`. When
   `1`/`true`, `gather.sh`:
   - does NOT parse the previous state block (log
     `info "restart requested — ignoring previous review state"`),
   - never writes the skip sentinel (even on matching patch-id),
   - produces no incremental files,
   - forces `prev-review.md` to `(no previous review)`.
   Everything else unchanged: human threads still gathered, sticky comment
   still edited in place, fresh state written by post.sh.
2. **Comment trigger convenience**: in the ctx step of `action/action.yml`,
   when the (already author-gated) trigger comment matches the trigger
   phrase followed by the word `restart`
   (`(^|[[:space:]])PHRASE[[:space:]]+restart([[:space:][:punct:]]|$)`),
   export `OPENREVIEW_RESTART=1` for the run. Reuse the TASK-03 escaping
   helper for the phrase.
3. **Engine fingerprint**: new helper `engine_fingerprint` in `common.sh` —
   a short stable hash (`cksum`-based, Bash 3.2-safe) over: the contents of
   `lib/passes.sh`, the resolved main model name, and the resolved verify
   model name. `post.sh` adds `"fp":"<hash>"` to the state JSON.
   `gather.sh`'s skip-if-identical fires ONLY when BOTH `patch_id` AND `fp`
   match (missing `fp` in old state ⇒ treat as mismatch ⇒ full review).
   Log which factor invalidated the skip (`diff changed` vs
   `engine changed`).
4. README: document the input, the `@openreview restart` comment form, and
   one sentence on the fingerprint rule ("skip only when neither the diff
   nor the engine changed").

**Acceptance criteria:**
- With matching patch-id + fp and `restart=true`: full review path runs
  (no sentinel), prev-review is the placeholder, and the state block is
  rewritten (show with canned state + local run of gather's state logic).
- With matching patch-id but different fp (touch `lib/passes.sh`): skip is
  bypassed, log says engine changed.
- With both matching and no restart: skip still fires (regression).
- Comment `@openreview restart` sets the env var; plain `@openreview` does
  not. `shellcheck` + `actionlint` pass.

## TASK-23 — Prompts as versioned files (AG alternative; supersedes the named-agents refactor)

**Files:** new `prompts/` dir, `lib/passes.sh`, `lib/common.sh`
(fingerprint), `CLAUDE.md` (one line in architecture notes).
**Design decision (2026-07-03):** the opencode named-agents refactor (AG)
is DROPPED — a consumer repo's own `opencode.json` replaces the bundled
config wholesale (documented precedence), which would delete the agent
definitions and break `--agent` runs. This task delivers AG's actual value
(versioned, reviewable prompt files) with zero coupling to opencode's
config: prompts stay plain files read by `passes.sh`.

**Spec:**
1. Create `prompts/generate.txt`, `prompts/verify.txt`, `prompts/prep.txt`,
   `prompts/format-spec.txt` containing the STATIC blocks currently inlined
   in `lib/passes.sh` (persona + rules + kill-list for generate; the verify
   rules + DROP criteria; the prep/intent-compression prompt body; the
   shared FORMAT_SPEC). Dynamic parts (context file lists, incremental
   note, sandbox path coaching that embeds `$S`) STAY assembled in
   `passes.sh` — do not invent a templating language; the files hold only
   the big static text, `passes.sh` `cat`s them and concatenates exactly as
   before.
2. Resolve the prompts dir relative to the script:
   `PROMPTS_DIR="${OPENREVIEW_PROMPTS_DIR:-$(cd "$(dirname "$0")/.." && pwd)/prompts}"`
   — works in the action checkout and local runs. `die` with a clear
   message if a prompt file is missing.
3. **Fingerprint interaction (critical):** `engine_fingerprint` in
   `common.sh` currently hashes `lib/passes.sh` — extend it to also hash
   every file in `prompts/` (stable order: `LC_ALL=C sort` the paths). A
   prompt edit must invalidate the skip guard exactly like a passes.sh
   edit.
4. Verification: capture the fully-assembled prompt for each pass BEFORE
   the refactor (reconstruct from git) and AFTER — they must be
   byte-identical for the same inputs. Include the diff evidence (empty)
   in the summary.

**Acceptance criteria:**
- Assembled prompts byte-identical pre/post refactor (show evidence).
- Missing prompt file ⇒ clean `die`, not a silent empty prompt.
- Fingerprint changes when any `prompts/*.txt` changes (show two hashes).
- `shellcheck -S warning lib/*.sh` clean; eval `--selftest` unaffected (if
  eval/ exists on the branch).

## TASK-24 — Org dispatch workflow + setup guide (Part 3, step 1)

**Files:** new `.github/workflows/review-dispatch.yml`, new
`docs/org-setup.md`, `action/action.yml` (two new optional inputs),
`README.md` (pointer).
**Context:** `docs/improvement-plan.md` §3.1 (the verified App-token
pattern); `docs/implementation-notes.md` §2. This ships the org-wide
manual-invocation story: fork this repo into an org → dispatch a review of
ANY org PR from the fork. It cannot be live-tested in this personal repo
(no App registered) — it must be actionlint-clean and defensively written;
live validation happens on first org install.

**Spec:**
1. **Action inputs:** add optional `target-repo` (owner/repo) and
   `pr-number` to `action/action.yml`. When both are set, the ctx step uses
   them directly as `OR_REPO`/`OR_PR` (skipping event-payload parsing);
   when unset, behavior is unchanged. Document that dispatch callers must
   also check out the target repo themselves.
2. **`review-dispatch.yml`** (`workflow_dispatch`) with inputs: `repo`
   (owner/repo within the org), `pr` (number), `restart` (boolean, default
   false). Job steps:
   a. Fail fast with a readable error if `vars.REVIEWER_APP_CLIENT_ID` or
      `secrets.REVIEWER_APP_PRIVATE_KEY` is missing ("see
      docs/org-setup.md").
   b. Mint the token with `actions/create-github-app-token@v2`:
      `owner: ${{ github.repository_owner }}`, `repositories:` the repo
      NAME only (strip the owner prefix from the input in a small step),
      `permission-contents: read`, `permission-pull-requests: write`,
      `permission-issues: write`.
   c. `actions/checkout@v4` of the fork itself (for the action code) into
      the workspace root, then a second checkout of the TARGET repo
      (`repository: ${{ inputs.repo }}`, `ref: refs/pull/${{ inputs.pr }}/head`,
      `fetch-depth: 0`, `token:` the minted token) into a `target/`
      subdirectory.
   d. Run the local action (`uses: ./action`) passing `target-repo`,
      `pr-number`, `restart`, `github-token:` (minted token), and model
      inputs from org vars/secrets. NOTE: verify how the action locates the
      repo dir (`OR_DIR` = git toplevel of the CURRENT working dir) — the
      composite action's steps must run against `target/`; check how
      action.yml sets OR_DIR today and either add a `working-directory`
      input or an explicit `target-dir` input, and document which you
      chose.
3. **`docs/org-setup.md`** — the 10-minute checklist for an org admin:
   register a GitHub App (webhook OFF; permissions metadata:read,
   contents:read, pull-requests:write, issues:write), install org-wide,
   store client ID (org variable) + private key (org secret) + model key
   (org secret); invocation examples
   (`gh workflow run review-dispatch.yml -R org/fork -f repo=org/target -f pr=123`,
   the Actions-tab route, `-f restart=true`); a security trade-offs section
   (who can dispatch = write access to the fork; per-run `repositories:`
   scoping; recommend branch protection + CODEOWNERS on the fork). Link it
   from README.
4. Do NOT touch existing workflows or the trigger logic in the action's
   event path (SECURITY.md rules apply).

**Acceptance criteria:**
- `actionlint .github/workflows/*.yml` clean; `shellcheck` clean for any
  touched lib file.
- Dry-run evidence: with `target-repo`/`pr-number` shimmed locally, ctx
  resolution yields the right `OR_REPO`/`OR_PR` without an event payload;
  without them, existing event parsing untouched (regression evidence).
- `docs/org-setup.md` complete enough that an org admin needs no other
  document; README links it.
- The dispatch workflow contains NO `pull_request_target` and never exposes
  the App private key beyond the token-mint step.

## TASK-25 — Eval fidelity: fixture source trees

**Files:** `eval/run.sh`, every `eval/fixtures/<name>/` (new `tree/` dir),
`eval/freeze.sh` (consistency check), `eval/README.md`.
**Motivation (found by the first full-suite run, 2026-07-03):** fixtures are
scratch snapshots only — the invented project's source files do NOT exist in
the run dir. The agentic model is told it may open changed files for context;
when it does, it finds an empty tree and (correctly, from its view) reports
phantom problems. Concretely: the `quiet` fixture failed its
`MAX_IMPORTANTS=0` budget with "imports reference nonexistent modules —
`metrix/` doesn't exist", which is a **harness artifact, not an engine
failure**. All fixtures' numbers are potentially tainted the same way.

**Spec:**
1. Each fixture gains `tree/` — the **post-PR state** of the invented
   project: every file the diff touches (with the diff applied) plus any
   module the code imports/references, so the checkout looks like a real PR
   head. Author them by applying each fixture's `pr.diff` to the invented
   base sources (for `playground`/`quiet`/`subtle`/`noisy` reuse the shared
   `metrix` project; `kotlin` gets its `src/*.kt`; `clean` gets its
   renamed files). Verify per fixture: for every file in the diff, the
   `tree/` copy's content around each hunk matches the hunk's new-side
   lines (write a small check into `freeze.sh` — compare each hunk's added/
   context lines against the tree file at the hunk's line offsets; fail
   loudly on mismatch).
2. `eval/run.sh`: copy `tree/` contents into the run dir ROOT (the project
   dir opencode sees) before the git-init step; scratch files keep going to
   `.openreview-tmp/` as today. Fixtures without `tree/` keep working (warn
   once: "no tree/ — agentic file reads will see an empty project").
3. README: document `tree/` in "Adding a fixture" and in the replay-fixture
   recipe (for replays, `tree/` = the real PR-head checkout of touched
   files).
4. Live spot-check (opencode + free model available locally): re-run the
   `quiet` fixture once — the phantom-imports important finding must
   disappear; include the result in the summary. (If credentials are
   unavailable, say so; the structural checks are the merge gate.)

**Acceptance criteria:**
- All 6 fixtures have `tree/`; `freeze.sh`'s new consistency check passes
  for all of them and fails loudly on a doctored mismatch (show both).
- `eval/run.sh --selftest` still passes; runs copy the tree into place.
- `shellcheck -S warning eval/*.sh` clean.
- Quiet live re-run evidence (or explicit note that creds were absent).

## TASK-26 — Prompt experiment: omission-bug hint (eval-gated)

**Files:** `prompts/generate.txt` only.
**Motivation:** the corrected eval baseline shows the reviewer's weakest
class is **omission bugs** — problems that are the *absence* of code: B05
(playground: bare-except swallow never caught), C01 (noisy: buffer-full
event silently dropped with no log). There is no wrong line to point at, so
diff-scanning misses them.

**Spec:** This is an EXPERIMENT, not a feature. Protocol:
1. **Before:** on the unmodified branch, run
   `EVAL_RUNS=3 OPENREVIEW_MODEL=opencode/deepseek-v4-flash-free bash eval/run.sh playground noisy`
   and `bash eval/run.sh quiet clean` (k=1); record per-bug m/k for
   B05/C01 and quiet/clean status.
2. **Change:** add ONE short paragraph to `prompts/generate.txt` (after the
   issue-classes list), e.g.: "Many real bugs are OMISSIONS — the code that
   is NOT there: error handling removed or never added, silent drops with
   no log line, a case forgotten after adding an enum/config entry. For
   each changed function, ask what should happen on failure / full / empty
   / unexpected input, and verify the code actually does it. An omission
   finding must still cite the file:line where the missing handling
   belongs." Keep it tight; do not weaken the existing kill-list.
3. **After:** repeat the exact same runs.
4. **Accept** iff: (a) B05 or C01 found in ≥1/3 runs where before it was
   0/3, (b) quiet stays 0 importants and ≤2 nits, (c) clean stays clean,
   (d) playground recall (union) not lower than before. Otherwise iterate
   the wording ONCE more; if still failing, revert and report failed with
   both scorecards.
5. Commit only on acceptance, with before/after numbers in the commit body.

**Acceptance criteria:** the protocol above, with both scorecards quoted in
the summary. `shellcheck` untouched (no shell changes).

## TASK-27 — Prompt experiment: language-idiom hint (eval-gated)

**Files:** `prompts/generate.txt` only. **Run AFTER TASK-26** (its accepted
prompt is the new baseline).
**Motivation:** kotlin fixture recall is stuck at 4/8 across runs; the
stable misses are Kotlin-idiom bugs: `===` vs `==` (K03), integer division
on money (K05), dropped `runCatching` result (K06).

**Spec:** Same experiment protocol as TASK-26:
1. **Before:** `EVAL_RUNS=3 … bash eval/run.sh kotlin` + `quiet clean`
   (k=1) on the current branch state; record per-bug m/k.
2. **Change:** ONE short paragraph in `prompts/generate.txt`, e.g.: "Check
   language-specific semantic traps for the file's language — e.g. in
   Kotlin/Java-like languages: reference vs structural equality, integer
   division where fractions matter (money!), non-exhaustive when/switch
   after an enum gains a case, error-wrapping results whose failure branch
   is silently dropped, nullability assertions (!!) on legitimately-absent
   values. Report these only when the concrete code path is wrong — not as
   generic advice (the do-not-flag rules still apply)." The linter-caveat
   sentence is REQUIRED — this must not reopen the kill-list.
3. **After:** same runs. **Accept** iff kotlin union recall ≥ 6/8 OR at
   least two of K03/K05/K06 newly found, AND quiet/clean budgets hold, AND
   playground is spot-checked once (k=1) with recall not collapsing.
   Iterate wording once; else revert + report failed with scorecards.
4. Commit only on acceptance, before/after in the commit body.

## TASK-28 — Cheap-model per-file triage (plan item T; eval-gated)

**Files:** `lib/passes.sh`, `prompts/triage.txt` (new), `lib/metrics.sh`,
`README.md`. **Run AFTER TASK-26/27.**
**Design (decided):** the original-CodeRabbit pattern, fitted to our
pipeline. Only active when a cheap model is configured AND the diff is big
enough to be worth the extra call.

**Spec:**
1. New pass 0.5 (after the intent prep, before generate), only when
   `resolve_cheap_model` yields a model AND `pr-numbered.diff` exceeds
   `OPENREVIEW_TRIAGE_MIN_LINES` (default 400): the cheap model reads
   `$S/pr-numbered.diff` and writes `$S/triage.md` — one line per changed
   file: `path<TAB>NEEDS_REVIEW|TRIVIAL<TAB>one-line summary of the
   change`. Prompt (new `prompts/triage.txt`): TRIVIAL means
   rename/move/formatting/comment-only/generated-mechanical churn with no
   behavior change; **"when in doubt, NEEDS_REVIEW"**; never mark TRIVIAL a
   file whose diff touches logic, error handling, or security surface.
2. `passes.sh` then builds `$S/pr-review.diff` for pass 1: drop the
   file sections of TRIVIAL files from `pr-numbered.diff` (reuse the awk
   file-block filter pattern from gather's exclude logic), and appends a
   `## Files triaged as trivial (not shown)` name list. Inject the per-file
   summaries block as extra pass-1 context ("what each file changes" — the
   Qodo AI-metadata pattern). Pass 1 reads `pr-review.diff` instead of
   `pr-numbered.diff`; verify still checks locs against the ORIGINAL
   numbered diff (anchor validation is unchanged — commentable lines come
   from gather).
3. Fail-open: triage pass error, unparseable output, or 0 NEEDS_REVIEW
   files ⇒ warn and run pass 1 on the full `pr-numbered.diff` exactly as
   today. A malformed triage line ⇒ treat that file as NEEDS_REVIEW.
4. Metrics: `FILES_TRIAGED_TRIVIAL` count into `metrics.env` + step
   summary. README: document the input/env and the fail-open rule.
5. **Eval gate:** with `OPENREVIEW_CHEAP_MODEL=opencode/deepseek-v4-flash-free`
   exported (and TRIAGE_MIN_LINES=0 to force triage on):
   `EVAL_RUNS=1 … bash eval/run.sh` full suite — accept iff every scored
   fixture's union recall is no lower than the same-day non-triage run,
   clean/quiet budgets hold, and on `noisy` at least 2 files are triaged
   TRIVIAL (it contains real churn). Report both scorecards.

**Acceptance criteria:** the eval gate above; `shellcheck -S warning
lib/*.sh` clean; `--selftest` unaffected; fail-open path demonstrated with
a canned garbage `triage.md`.

---

## TASK-29 — Merge, don't replace: hardened config survives consumer configs

**Files:** `lib/common.sh` (`prepare_opencode_config`), `action/action.yml`
(new input), `SECURITY.md`, `README.md`.
**Motivation (found live in ai-news run 28679351811):** a consumer repo's
own `opencode.json` currently REPLACES the bundled hardened config entirely
(the documented precedence), silently removing layer 1 of the security
model (bash/webfetch/websearch/task denial, `external_directory: deny`).
The TASK-12 warning fires but nothing enforces.

**Spec:**
1. New default behavior in `prepare_opencode_config`: when the resolved
   config is NOT the bundled one, produce a **merged effective config** at
   `$SCRATCH/opencode-effective.json`:
   - base = the consumer's resolved config (env → project → user, as
     today),
   - force-overlay the security-critical keys from the bundled config:
     the full `tools` map and the full `permission` map (replace those two
     keys wholesale — do not deep-merge them, so a consumer cannot
     re-enable anything piecemeal), and **drop any `mcp` key** (MCP servers
     add tools),
   - everything else (provider, model, instructions, small_model, agent,
     theme…) passes through untouched.
   Point `OPENCODE_CONFIG` at the merged file. Consumer keeps
   models/providers; sandbox stays intact.
2. Merge implementation: prefer `jq` if present, else `python3 -c` (both
   are on GitHub runners and dev Macs); if NEITHER is available, **fall
   back to the bundled config outright** (safe direction) with a `warn`.
   Never fail the run over the merge.
3. New input `trust-repo-config` (default `false`): `true` restores
   today's behavior (consumer config used verbatim; the TASK-12 warning
   remains). Env: `OPENREVIEW_TRUST_REPO_CONFIG`.
4. **Empirical acceptance test (critical):** with a project `opencode.json`
   containing `"tools": {"bash": true}` and a permissive `permission`, run
   a cheap real pass (or `opencode run` with a trivial prompt asking the
   model to run \`echo pwned\` via bash) against the merged config and show
   bash is NOT available/denied. This also verifies opencode does not
   itself re-merge the project `opencode.json` on top of `OPENCODE_CONFIG`
   — if it does, document it and adjust (e.g. run from a directory without
   the project config… flag for maintainer if unsolvable at this layer).
5. Keep the TASK-12 warning for the `trust-repo-config: true` path; in the
   default path, replace it with an `info` line: "merged consumer config
   with hardened security keys (tools/permission forced, mcp dropped)".
6. SECURITY.md: rewrite the layer-1 paragraph — repo config can no longer
   silently weaken the sandbox; document `trust-repo-config`.

**Acceptance criteria:**
- Bundled-config-only repos: byte-identical behavior (no merge step).
- A hostile project config (bash:true, external_directory:allow, mcp
  servers) yields a merged config with our tools/permission maps verbatim
  and no mcp key; the empirical bash-denial test passes.
- `trust-repo-config: true` restores verbatim consumer config + warning.
- No jq/python3 ⇒ bundled config + warn. `shellcheck` + `actionlint`
  clean; eval `--selftest` unaffected.

## Explicitly NOT ready for handoff (needs decisions or deeper design)

- **T (cheap triage)** — routing thresholds + prompt design tuning; now
  measurable — spec after the eval suite (TASK-19/20/21) merges.
- **Part 3 remainder (harvest cron, warmup skills, knowledge picker)** —
  **ON HOLD (user decision 2026-07-03):** the GitHub App / org rollout is
  deferred to a separate initiative and session. TASK-24's dispatch
  workflow is merged but dormant until an App is registered; do not build
  further on it for now.
- **V/U/W/N/O/L′, Tier 4 (Y/Z/AA)** — design open or eval-dependent.
- ~~AG (named-agents refactor)~~ — dropped in favor of TASK-23 (see its
  header for rationale).
