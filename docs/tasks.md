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

Recommended execution order: 01 → 02 → 03 → 04 → 05 → 06 → 08 → 07 → 10 →
11 → 09 (09 is the largest; 12 is independent). Dependencies are noted per
task; tasks without a dependency note are independent.

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

---

## Explicitly NOT ready for handoff (needs decisions or deeper design)

- **G (incremental review)** — force-push edge cases + state schema design.
- **J (inline comments)** — posting UX decisions (default mode, verdicts).
- **S (edit-in-place)** — depends on a notification-behavior decision.
- **T (cheap triage)** — routing thresholds + prompt design tuning.
- **Part 3 (org dispatch, App, hub knowledge base)** — org setup is human
  work; harvest/warmup design still needs decisions.
- **V/U/W/N/O/L′, Tier 4 (Y/Z/AA)** — design open or eval-dependent.
