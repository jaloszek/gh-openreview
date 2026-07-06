# gh-openreview — Improvement Plan

Status: **living document** · Author: pawel · Last major revision: 2026-07-03
(field-research pass — per-project findings live in
[`competitors.md`](competitors.md); verified technical mechanics from the
pre-implementation research pass live in
[`implementation-notes.md`](implementation-notes.md))

## Direction

**Mission (pawel, 2026-07-04):** match the review quality of a frontier
model (Claude Fable via claude-code-action, one prompt, one agent) using
`deepseek-v4-flash` — a far weaker model — by exploiting the two advantages
the weak-model side has: **better curated context** (intent brief, numbered
diff, regression radar, co-change, open-PR overlap, team memory) and
**more structure** (multi-pass generate→verify, cheap-tier routing,
deterministic grounding and rendering). The label-gated Fable review in
`.github/workflows/claude-code-review.yml` is the standing benchmark: same
PRs, side by side, scored against the playground answer key.

The product stays what it is: an **OpenCode-agentic, plain-bash GitHub Action**
— no server, no database, no build step. The strategy is to absorb the best
ideas from the field (see `competitors.md`) while skipping as much
infrastructure as possible. Three principles:

1. **Agentic over pre-built context.** The model reads files in a full checkout
   instead of us building a RAG/graph index. This is the consensus winner
   ("repo context beats diff-only") at zero infra cost. We deliberately do NOT
   copy full-codebase indexing (Greptile/Kodus) — the heavyweight answer to a
   problem the agentic checkout already mostly solves.
2. **Deterministic for hard constraints, LLM for judgment** (Alibaba
   open-code-review's phrasing, and already our design: deterministic render,
   structured records, marker dedup). Anything that can be awk stays awk.
3. **Learning over time is the long-term moat.** The strongest empirical result
   in the field (Greptile) is that noise is fixed by *feedback memory*, not by
   prompting. We need a place to store per-repo state without infra — Part 3
   solves this (state-in-comment + a dedicated memory repo + a webhook-less
   GitHub App identity).

---

## Part 0 — Shipped (history)

The original refactor (action-only; drop the `gh` extension surface) and the
first improvement wave are done. Kept here as a record; details in git history.

| # | Item | Status |
|---|---|---|
| 1 | Refactor to action-only | ✅ done |
| 2 | A. Deterministic `render.sh` (drops the LLM format pass) | ✅ done |
| 3 | B + C. Per-pass timeout/retry + never-post-on-failure | ✅ done |
| 4 | D. Telemetry → step summary + outputs (timing/findings/diff size) | ✅ done |
| 5 | F. Diff capping / path filtering | ✅ done |
| 6 | E. Model tiering (`verify-model` input) | ✅ done |
| 7 | I/H. Richer gather context (threads, issues, commits) + read-files prompt | ✅ done |
| 8 | Q (partial). `cheap-model` input + intent-compression prep pass | ✅ done |

Original motivating evidence (two `ai-news` runs, PR #125): zero cost
telemetry, the LLM format pass was the slowest step (2m50s to template one
nit), 2.8× runtime variance, full re-review on every push. Items 2–4 fixed the
first two; incremental review (G) still addresses the last.

### Validated by the field research

Patterns we already ship that the research confirms as best practice:

- **Structured output → deterministic render** (Qodo renders from YAML schema;
  never lets the model format the final comment).
- **Generate → verify two-pass** (CodeRabbit Verification agent, BugBot
  validator, Anthropic plugin validation step, Ellipsis filter chain).
- **Step-scoped token / tokenless model step** — structurally identical to the
  OpenAI Codex cookbook's read-only-prepare → no-token-review → write-scoped-
  publish reference design. `pull_request_target`-with-secrets is the
  documented anti-pattern; we avoid it.
- **Comment-trigger author gating** — stricter than OSS PR-Agent (which lets
  anyone who can comment invoke it).
- **Intent context first** (linked issues + commits + cheap-model brief) —
  ContextCRBench: PR description alone +72% F1, issue+PR +78%, vs surrounding
  code +64%.
- **Dedup against existing threads and the previous review** (BugBot reads
  existing comments as a do-not-repeat list).
- **Aggressive default path exclusions with non-silent truncation notices.**

### De-prioritized by the field research

- ~~**M. Batched 0–10 self-reflection re-rank**~~ — **dropped as designed.**
  Greptile's verified negative result: LLM-as-judge numeric self-scoring of
  findings is "nearly random." Replaced by M′ (category kill-list — hard
  deterministic drops, which Qodo's reflect rubric also hard-codes as
  score-0 classes rather than trusting the model's number).
- **Full-codebase RAG/graph indexing** — explicitly out of scope (see
  Direction).
- **Prompting harder against nitpicks** — proven not to work (Greptile);
  invest in kill-lists, gates, and feedback memory instead.

---

## Decisions log (2026-07-03)

Ten roadmap questions decided (yes/no round with pawel):

1. **Default model stays free** (`opencode/deepseek-v4-flash-free`) — add a
   prominent README/SECURITY warning that free-tier traffic may be used for
   model training; recommend paid tiers for private code.
2. **Inline comments ship opt-in** (`comment-style: summary` default); flip
   the default only after anchor validation proves reliable on real PRs.
3. **COMMENT-only forever** — the bot never posts APPROVE/REQUEST_CHANGES.
4. **Sticky comment → edit-in-place** (item S approved), optional ping
   comment for notification-wanting teams.
5. **PRDESC redesigned into a rating** (see item PD below): instead of
   generating a suggested description, rate the existing one —
   `good` / `could-be-improved` / `poor` — and only render when not `good`.
   Criteria: `poor` = empty, extremely outdated, or contradicts the diff;
   `could-be-improved` = major gaps but mergeable; `good` = everything else.
   Kills most of the PRDESC injection-echo surface and its token cost.
6. **Auto-review on every push stays the default**, made cheap by
   incremental review (item G) once it lands.
7. **Engine refactors onto opencode named agents** (review-generate /
   review-verify in `opencode.json`, per-agent model/tools, prompts as
   files) — approved; land with/after Tier 0 since it touches the same
   config.
8. **Org epic keeps its wave-4 slot** — quality floor first, org rollout
   after.
9. **Eval: playground + clean control first**; replay fixtures added
   incrementally after the harness proves itself.
10. **Knowledge base lives in the hub fork itself** (§3.4 confirmed as the
    default; separate memory repo demoted to alternative).

## Status update — 2026-07-06 (benchmark re-verification + wave-4 planning)

Independent re-check of both live reviews (PR #19, PR #22) against the
answer keys confirmed the v1/v2 benchmark numbers; no scoring corrections
needed. Session output:

- **Answer keys gained "Known unseeded true positives" sections**
  (`eval/live-src/BUGS.md`, `eval/hard-src/BUGS.md`): 4 real-but-unplanted
  defects both/either reviewer found (cancel_job-doesn't-cancel, priority-0
  falsy coercion, score_delta div-by-zero, never-decremented pool counters)
  — each verified against source. Scorers no longer punish true positives.
- **`claude-code-review.yml` hardened**: the review body must now end with
  the same machine-readable TSV block openreview emits + a hidden
  `<!-- claude-review -->` marker; cleanup matches the marker (legacy
  patterns kept for old comments) instead of visible header text that was
  one emoji away from colliding with openreview's comments. Head-to-heads
  become scriptable.
- **Wave 4 specced in tasks.md (TASK-40…44)**, ordered by the "context
  beats prompting" insight: 40 live-benchmark scorer (`eval/compare.sh`,
  automates the manual head-to-head); 41 changed-symbol consumer feed in
  gather (the deterministic-context successor TASK-39's failure note
  prescribed — targets A02, the one bug both reviewers missed); 42 eval
  fidelity 2 (full-project fixture trees + re-baseline, insight #3); 43
  severity-anchoring prompt experiment (crashes are never nits — the L01/
  L08-as-nits miscalibration measured live); 44 voting v2 with
  verify-as-judge variant selection (the TASK-37 redesign).
- **Still pending, ready to pick up:** TASK-26's eval gate (never run) and
  TASK-28's gate (`wip/task-28-triage`); both protocols are fully written.

## Status update — 2026-07-04 (context/format/benchmark session)

Shipped on top of the 07-03 state:
- **Context wave** (PR #18): open-PR overlap, regression radar, co-change
  coupling — all absent-silent, all verified firing live on their own PR.
- **Live playground PR #19** (permanent, 8 seeded bugs, `eval/live-src/`):
  first report card 8/8 line-hits, 0 FPs; restart + fingerprint + skip all
  exercised live.
- **Minimal comment format** (PR #20 + header-tally tweak): flat priority
  list with 🔴/🟠/🟡 dots + collapsed machine-readable agent block, design
  validated against a raw-markdown study of 6 competitors' comments.
- **TASK-29 config merge** (PR #17): consumer opencode.json can no longer
  weaken the sandbox. **oc_run watchdog** (macOS had NO timeout — hung
  calls ran unbounded); **sanitizer VS-16 fix** (emoji selectors were being
  stripped from real diffs).
- **Fable benchmark harness**: `claude-code-review.yml` (Fable model,
  manual/`claude-review`-label only) + first head-to-head results (see the
  Benchmark section above). Mission statement added to Direction.
- **In flight (autonomous overnight run)**: tasks 35-39 — hard-eval wave
  (depth/adjacent scoring, hard fixture, voting, mechanism-verify,
  adjacent scan), then benchmark v2.

## Status update — 2026-07-03 (end of build session)

Shipped to main (PRs #9, #10, #12–#16 + direct task commits):
- **Tier 0 complete** (T0-1…T0-4: hardened+pinned opencode config, ingress/
  egress sanitization) + all security quick wins.
- **Tier 1 complete**: R (numbered hunks + anchor validation), M′
  (kill-lists), K (confidence gating), P (compression ladder), PD
  (PR-description rating).
- **Tier 2**: S (edit-in-place + state block), G (incremental review +
  patch-id skip — verified live: 14 s no-op reruns), J (inline comments,
  opt-in), TASK-22 (restart flag + engine fingerprint), TASK-23 (prompts as
  versioned files — **AG formally dropped**, see tasks.md).
- **Eval suite complete** (X + expectations + quiet/subtle/noisy/kotlin
  fixtures + source trees): 6 fixtures, budgets/must-catch, selftest.
  First eval-gated prompt win landed: language-idiom checklist — kotlin
  recall 5/8 → 6/8 (important-only 0.71 → 0.86), budgets held.
- TASK-24 (org dispatch workflow + org-setup.md) merged but **dormant**;
  the whole org/App initiative is **ON HOLD** (user decision) for a
  separate session.

Corrected eval baseline (free model, post-tree-fix): clean 0 findings;
playground ~10-11/12; subtle union 3/3 (S01 flaky 1/5); kotlin 6/8 (K03/K06
open); noisy criticals caught except C01 (omission class). Known weak
classes: omission bugs, run-to-run flakiness on moderates.

Pending: TASK-26 (omission-hint experiment — gate not yet run), TASK-28
(cheap triage — implemented, lint-clean, parked ungated on
`wip/task-28-triage` until its eval gate runs). Operational lesson: heavy
eval usage can throttle the free tier (hangs, 0-byte event streams) — use
`OPENREVIEW_PASS_TIMEOUT=180` for eval runs and prefer a paid cheap tier
for gate work.

## Benchmark v2: hard content, clean runs (live-hard PR #22, 2026-07-04/05)

Answer key: `eval/hard-src/BUGS.md` (10 engineered bugs: 4 deep-diagnosis
traps, 3 adjacent/interaction, 2 omission, 1 control). Both reviewers ran on
**decontaminated** branches (answer keys removed from the PR branches after
Fable's first run self-disclosed grepping into them — playground branches
must NEVER carry `eval/`; both playgrounds fixed).

| | Ours (deepseek-v4-flash, live) | Fable (claude-code-action, live) | Ours (offline fixture, k=3) |
|---|---|---|---|
| Seeded bugs | **9/10** (missed A02) | 8/10 (+A02-partial; missed O02) | 6/7 diff-scope, **0/3 adjacent** |
| Deep diagnoses | **4/4** (incl. D01, the L03-class trap) | 4/4 | 3/6, D01 0/3 |
| Adjacent class | 2/3 | 2/3 (different 3rd framing) | 0/3 |
| Omissions | 2/2 (incl. RetryingStore-never-wired cross-file check) | 1/2 | 0-1/2 |
| Out-of-key bonus findings | 1 (cancel_job doesn't cancel) | 2 (same + priority-0 falsy coercion) | 0 |
| Cost/run | ~$0.01 | ~$1.5 | ~$0.003 |

**Headline: on hard content with full live context, the deepseek pipeline
reached parity with Fable** (a nose ahead on the answer key, a nose behind
on novel-bonus discovery) at ~1/150 the cost. The offline fixture numbers
were the *instrument's* fault, not the engine's — the minimal fixture tree
starves the agentic file-reading that live runs enjoy.

Insights bank (all measured 2026-07-04):
1. **Context beats prompting** — three prompt-level interventions (mechanism
   -rewrite, adjacent-scan) measured inert-to-harmful offline, while the
   same engine WITH rich context caught the very classes those prompts
   targeted. The next quality lever is deterministic context feeds, not
   prompt nudges.
2. **Voting (TASK-37)**: stabilized the hardest bug (D01 1/3→2/2) but the
   longest-body merge heuristic traded away other correct diagnoses —
   redesign the variant selection (e.g. verify-pass judges) before retrying.
3. **Eval fidelity follow-up**: enrich offline fixture trees (full project,
   not just touched files) so offline scores track live behavior; re-baseline
   after.
4. Both reviewers were primed by the PR body mentioning seeded bugs (equal
   footing, but real-world PRs don't announce their bugs — absolute numbers
   are optimistic; deltas are what count).
5. Fable's self-disclosure of the answer-key leak mid-review is worth
   noting as model integrity behavior.

## Benchmark v1: Fable vs our deepseek pipeline (playground PR #19, 2026-07-04)

First head-to-head on the seeded 8-bug diff (answer key `eval/live-src/BUGS.md`):

| | Fable (claude-code-action, 1 prompt) | Ours (deepseek-v4-flash, 2-pass) |
|---|---|---|
| Seeded bugs found (per run) | **8/8** | 6/8 (union across runs 8/8) |
| Deep diagnosis (L03 denominator, L04 truncation) | both, every time | L03 1-in-3 runs; L04 shallow-adjacent |
| Bonus real findings | ~4 (missing decrement, stream-contract, zip truncate, pre-existing flagged AS pre-existing) | 0 |
| Severity calibration | stable, sensible 5-level ladder | flaky run-to-run (8-important vs 3+3) |
| False positives | 0 | 0 |
| Cost/run | ~$1.47 (+ a lost $1.47 run: posting died on a tool-permission subtlety) | ~$0.003 free / ~$0.01 paid |
| Output reliability | model posts ⇒ can silently fail | deterministic render+post, fail-closed |

Gap analysis vs the mission: recall gap is small (and union-recall zero);
the real gaps are **diagnosis depth stability** and **severity calibration**
— both targeted by existing backlog items (W self-consistency voting for
stability; a verify-pass "confirm the mechanism, not just the location"
criterion; severity anchoring). Structure already wins on cost (~150-500×)
and on output reliability. Fable's bonus-findings ability (cross-cutting
reasoning like "nothing ever decrements") is the hardest gap — candidate
lever: the co-change/blame context + a dedicated "what ELSE is wrong with
the functions this diff touches" instruction.

## Part 1 — Backlog, re-prioritized

Goal tags: 💸 cost · 🔮 predictability · 🛡️ robustness · 🎯 quality ·
📊 observability. Provenance for each idea is in `competitors.md`.

### Tier 0 — urgent fixes surfaced by pre-implementation research (2026-07)

Latent problems in the *current* code, found while de-risking the roadmap
(details + sources in `implementation-notes.md`):

- **T0-1. Re-validate + harden the bundled `opencode.json` 🛡️.** opencode's
  sandbox semantics changed: path containment is now the
  `external_directory` permission, **default `ask` — which hangs forever in
  headless CI** (opencode #14473). Set every permission to explicit
  allow/deny (`external_directory: deny`), AND use tool *removal*
  (`tools: {bash:false, webfetch:false, websearch:false, task:false}`) —
  permission denies alone have documented bypasses (subagents bypass deny
  rules, #32024). Disable the `task` tool. Set `small_model` to a free model
  so internal tasks (title generation) never bill the strong tier.
- **T0-2. Pin the opencode version 🛡️🔮.** The project moved to
  `anomalyco/opencode` with a 1–3-day release cadence. The install script
  accepts `--version X` (verified); npm `opencode-ai@X` is the most
  deterministic; releases ship SHA256 checksums. Pin exact, bump
  deliberately, re-test the JSONL event shape on bumps.
- **T0-3. Egress sanitization in render/post 🛡️ (real security gap).** Our
  comment echoes model text that can quote attacker-controlled PR content
  verbatim (`@@PRDESC` is a near-verbatim echo of the PR body). Defang
  `@mentions`/`#refs` (code-span them — notification-spam attack), strip
  markdown images/links/HTML in echoed text (CamoLeak, CVE-2025-59145,
  showed GitHub's Camo proxy is itself an exfil channel), strip invisible
  Unicode outbound, length-cap PRDESC, prefer paraphrase over quote.
- **T0-4. Ingress sanitization + spotlighting in gather/prompts 🛡️.** Strip
  invisible-Unicode ranges (tag block U+E0000–E007F, zero-width, bidi
  controls, variation selectors) from diff/PR body/issues/comments before
  the model sees them; delimiter-wrap untrusted blocks with a
  "data-not-instructions" preamble (Microsoft spotlighting: attack success
  >50% → <2%).

### Tier 1 — cheap, proven, fits the bash architecture

- **R. Line-numbered hunk re-encoding + deterministic anchor validation 🎯🛡️**
  (Qodo `__new hunk__`/`__old hunk__`; ai-pr-reviewer did the same).
  `gather.sh` (awk) rewrites `pr.diff` hunks with absolute new-side line
  numbers prefixed to every line, so the model *copies* `loc:` anchors instead
  of computing them. `render.sh` then validates every `loc:` against the set
  of changed lines extracted from the diff — findings with unanchorable locs
  are demoted (kept in the summary, flagged) rather than dropped silently or
  posted with a wrong anchor. Wrong anchors are the most-reported failure mode
  of diff-anchored reviewers; today our only defense is prompt-level.
  Prerequisite for J (inline comments).

- **M′. Do-not-flag category kill-list 🎯** (replaces M; Anthropic plugin +
  claude-code-security-review + Qodo reflect rubric). Two halves:
  1. Generate prompt gets an explicit do-not-flag list: pre-existing issues,
     style/formatting, speculative problems ("could potentially…"), anything a
     linter would catch, generic security hand-waving, docstring/comment/
     type-hint suggestions, "consider verifying…" advice, unused imports,
     claims about symbols defined outside the diff. Plus the literal
     Anthropic-plugin line: *"If you are not certain an issue is real, do not
     flag it."*
  2. Verify pass **hard-drops** those categories deterministically (they are
     named drop criteria, not judgment calls) — mirroring Qodo's automatic
     score-0 classes.

- **K. Confidence gating in render 🎯🔮** (validated: Anthropic 0–100 cut at
  80; Codex P0/P1-only; BugBot "false positive costs more than false
  negative"). Keep it a *categorical* gate on the existing `conf:` field —
  not a numeric re-scoring pass (see de-prioritized M):
  - `conf: low` findings never render as 🔴 Important (demote to nit or drop),
  - new input `min-confidence` (default `med`) below which findings are
    dropped from the comment (still counted in metrics),
  - global rendered-findings cap alongside the existing nit cap.

- **P. Diff compression ladder 💸🔮** (Qodo — copy whole-cloth; replaces the
  blunt `head -n 4000`). In `gather.sh`, when over budget:
  1. strip deletion-only hunks (`omit_deletion_hunks`) and reduce
     fully-deleted files to a `Deleted files:` name list,
  2. rank files: code files of the repo's dominant languages first, then by
     patch size descending; drop generated/vendored last-resort content first,
  3. greedily fit whole file-patches to the line budget (never cut mid-file),
  4. append the names of files that did NOT fit
     (`Files not shown (budget): …`) — **the model must always know what it
     could not see** (today the tail of the diff silently vanishes).

- **PD. PR-description rating (replaces the PRDESC suggestion) 🎯💸**
  *(decided 2026-07-03 — see Decisions log #5).* The `@@PRDESC` block becomes
  a two-line record: `rating: good|could-be-improved|poor` + `reason:` (one
  line, only for non-good). Prompt criteria: `poor` = empty/extremely
  outdated/contradicts the diff; `could-be-improved` = major gaps but
  mergeable; `good` = everything else. `render.sh` skips the section
  entirely on `good`, otherwise renders a small "📝 PR description: <rating>
  — <reason>" note. No description text is ever generated or echoed —
  removes most of the PRDESC injection surface and its output tokens.

- **AG. opencode named-agents engine refactor 🔮🛡️**
  *(decided 2026-07-03 — Decisions log #7).* Define `review-generate` and
  `review-verify` agents in the bundled `opencode.json` (per-agent `model`,
  `tools`, `permission`, `prompt: {file:./prompts/…}`); `passes.sh` invokes
  `opencode run --agent <name>` instead of assembling giant prompt strings.
  Prompts become versioned files; each pass gets its own tool lockdown.
  Land together with / right after T0-1 (same config file).

### Tier 2 — medium effort, high value

- **G. Incremental review + state-in-comment 💸🔮** (ai-pr-reviewer's
  state-store pattern; PR-Agent `/review -i`). Persist state as a hidden HTML
  block in our own sticky comment —
  `<!-- openreview:state {"last_sha":"…","patch_id":"…"} -->`:
  - on `synchronize`, diff `last_sha..head` and feed the previous review as
    context; fall back to full review when the base changed (force-push,
    rebase),
  - **patch-id skip**: hash the normalized patch; if already reviewed, skip
    the run entirely,
  - optional PR-Agent-style guards (min commits / min minutes between
    auto-runs).

- **S. Sticky comment: edit-in-place instead of delete-and-repost 🔮**
  (PR-Agent, Danger). `post.sh` currently deletes old comments and posts a new
  one. Switch to editing the marker comment in place with an
  "updated for commit `<sha>`" line (which also carries the G state block),
  plus an optional tiny ping comment for notification (PR-Agent's
  `final_update_message`) — configurable, since delete-and-repost's
  notification is sometimes wanted.

- **T. Cheap-model per-file triage 💸** (the original CodeRabbit trick;
  completes backlog item Q). Extend the existing cheap tier: before pass 1, a
  cheap-model pass summarizes each file's diff and emits
  `NEEDS_REVIEW | APPROVED` per file ("when in doubt, NEEDS_REVIEW").
  `APPROVED` files (renames, formatting, mechanical changes) are dropped from
  the strong pass's diff; the per-file summaries are injected as context
  (Qodo's "AI metadata" chaining). Biggest remaining cost lever; also routes
  `@@PRDESC` generation to the cheap tier (Q's leftover).

- **J. Inline review comments + suggestion blocks 🎯** (field-standard UX).
  Opt-in `comment-style: summary|inline|both`:
  - 🔴 Important findings → one review via
    `POST /repos/{o}/{r}/pulls/{n}/reviews` with a `comments[]` array (atomic);
    `line` must be a commentable diff line — **requires R's anchor
    validation**; unanchorable findings fall back to the summary comment
    (reviewdog's fallback pattern), never mis-anchored,
  - ` ```suggestion ` fences only for self-contained fixes with exact-range
    replacements (Anthropic/Qodo rule),
  - across runs: minimize the prior run's inline comments as `OUTDATED`
    (GraphQL `minimizeComment`); summary stays sticky per S.

### Tier 3 — differentiators & measurement

- **U. Resolution-rate telemetry 📊** (BugBot's driving metric). On PR close/
  merge (or a scheduled sweep), a cheap-model call per past finding: "was this
  addressed in the final diff?" → log resolution rate to the step summary /
  an output. Turns all future prompt tuning into hill-climbing on a real
  number instead of vibes. Cheap: `gh` + one call per finding.

- **V. Feedback harvesting → suppression context 🎯** (poor-man's Greptile;
  read-side of the memory story, Part 3 is the write-side). `gather.sh`
  additionally fetches 👍/👎 reactions and replies on our previous comments
  (`GET /issues/comments/{id}/reactions` — free with existing `issues` scope).
  Downvoted/dismissed findings are fed to generate+verify as explicit
  suppression context ("the team rejected findings like these — do not raise
  similar ones"). The only technique Greptile found that actually moved
  address rate (19% → 55%).

- **W. Thorough mode: self-consistency voting 🎯💸** (BugBot V1). Optional
  input `passes: N` — run pass 1 N times with shuffled file order, keep only
  findings that recur (majority vote by file+line proximity + title
  similarity), then verify. N× pass-1 cost, so off by default; for
  release-critical PRs.

- **N. Evidence-gated findings 🎯** (Ellipsis "Evidence", CodeRabbit
  receipts). Require each finding to quote the exact diff line it's about;
  verify (or render, deterministically) re-confirms the quote exists in
  `pr.diff` and drops findings whose evidence doesn't match. Kills the
  plausible-but-wrong class; pairs with R.

- **O. Linter/SAST grounding 🎯** (CodeRabbit runs 50+; Sourcery hybrid). Run
  deterministic tools first (`shellcheck`, `actionlint`, `semgrep`,
  `ast-grep` — whatever fits the repo), feed structured findings into pass 1
  so the LLM triages real line-anchored signal instead of inventing it, and
  suppress LLM findings a linter already covers.

- **L′. Prompt caching 💸.** Static rubric + conventions before the variable
  diff; provider-dependent through OpenCode (Anthropic: `cache_control`
  ephemeral, read = 0.1× input, min prefix 1024 tokens) — verify OpenCode
  support first. Greptile attributes a 75% inference-cost drop to aggressive
  caching.

- **Token/cost telemetry follow-up 📊.** OpenCode headless emits JSONL
  (`opencode run --format json`); the `step_finish` event carries cost +
  tokens. Capture for exact per-pass numbers (pin a recent OpenCode; older
  builds could exit before the final `step_finish`).

### Tier 4 — exploratory ideas (2026-07, not yet researched in depth)

All three below must respect the security model: the LLM step stays
network-denied (`webfetch`/`websearch` off) and token-free. Anything fetched
from outside lands as **files in `$SCRATCH`, produced by the token-scoped
gather side** — the model only ever reads pre-fetched context, so a
prompt-injected model still can't exfiltrate or phone home.

- **Y. External context connectors (Slack / Jira / Confluence / …) 🎯.**
  Surrounding-discussion context: search Slack for messages linking the PR (or
  its branch/ticket), pull the Jira ticket beyond what close-keywords catch
  (acceptance criteria, comments — Qodo's ticket-context precedent), fetch a
  linked Confluence design page. Rather than N built-in integrations, KISS
  shape: a **generic connector hook** — `OPENREVIEW_CONTEXT_CMD` (mirroring
  the existing `OPENREVIEW_AUTH_CMD` pattern): a consumer-supplied command run
  during gather (with whatever creds the workflow gives it) that writes extra
  markdown files into `$SCRATCH/context/`; gather lists them, the prep pass
  folds them into the intent brief. One hook covers Slack, Jira, Confluence,
  and anything we haven't thought of, with zero connector code in this repo;
  first-party example scripts can live in `examples/connectors/`. (Org
  deployment tie-in: connector creds become org secrets next to the App key.)

- **Z. Web intelligence: dependency freshness & topic practices 💡.**
  Two sub-ideas, different risk profiles:
  1. *Dependency checks — deterministic, no LLM, no model network*: when the
     diff touches manifests (`package.json`, `go.mod`, `requirements.txt`,
     `pom.xml`…), gather queries the public registries (curl, tokenless) for
     latest versions / yanked releases / known advisories
     (`npm view`, PyPI JSON, OSV.dev API) and writes a small
     `deps-report.md` the model reads like any other context file. Cheap,
     grounded, and the advisory angle overlaps item O (linter/SAST grounding).
  2. *"How is this usually done" web research*: genuinely useful but the
     risky half — it needs live search driven by PR content. If ever added,
     it must be an **explicit opt-in input** (`allow-web: true`) that runs as
     a *separate* opencode pass with search enabled but with the diff-derived
     prompt treated as untrusted, and documented as weakening layer 1 of the
     security model. Default stays off. Park until there's demand.

- **AA. Plan-vs-implementation gap analysis 🎯.** Extend the intent pipeline
  into a three-step compliance check:
  1. From the intent brief ONLY (issue/ticket/PR body — **before seeing the
     diff**), a pass writes a short independent implementation plan: expected
     touchpoints, edge cases, migrations, tests, rollout concerns.
  2. The generate pass receives plan + diff and emits a structured gap list:
     plan items with no counterpart in the diff (missed edge case, missing
     test, forgotten migration) — each becomes a normal `@@FINDING` (usually
     `nit`/`important` per impact), so render/verify need no new machinery.
  3. Render adds a collapsed "📋 Plan coverage" section (fulfilled / gaps /
     needs-human-verification — Qodo's ticket-compliance buckets are the
     precedent, but the *independent plan first, then compare* twist is
     stronger than checking requirements directly, because the plan surfaces
     implicit expectations the ticket never spelled out).
  Cost: one extra strong-or-cheap pass; gate behind an input
  (`plan-check: true`). Synergy: the plan artifact doubles as review context
  for humans, and item U (resolution rate) can measure whether gap findings
  get addressed. Risk to watch: hallucinated requirements — the prompt must
  mark gaps as "the plan expected X; verify whether it's needed," never as
  confirmed bugs.

### Testing & evals

- **X. Eval harness 📊🛡️** — run the pipeline end-to-end on demand, without
  CI or live PRs. *(Design updated after the eval-methodology research —
  details in `implementation-notes.md` §3.)* Key insight: gather and passes
  are already decoupled through `$SCRATCH`, so **fixtures are frozen scratch
  snapshots**, not a live PR:
  1. `eval/fixtures/playground/` — a frozen gathered scratch dir (pr.diff,
     pr-meta.json, pr-comments.md…) for a realistic multi-file diff with
     **~12 seeded bugs** covering the converged taxonomy (logic/off-by-one,
     null/edge case, error handling, resource leak, race, security,
     convention violation + 2–3 hard ones); LLM-assisted seeding,
     human-verified (Qodo's recipe). `eval/fixtures/clean/` — a known-clean
     diff as a **false-positive control** (hard-fail on any important
     finding; vendors skip this check — cheap and high-signal).
  2. `eval/golden/playground.tsv` — id, file, line, category, sev,
     description per seeded bug.
  3. `eval/run.sh` (~200 lines bash, no new deps): copy fixture → temp
     scratch → `passes.sh` + `render.sh` only (**no token needed**) → match
     findings deterministically (same file + line within the bug's hunk ±5)
     → print recall (overall/per-category/important-only), precision,
     nit count, per-bug found-in-m/k. `EVAL_RUNS=3` for prompt changes
     (temp 0 ≠ determinism on hosted APIs; a bug found 1/5 runs is not
     reliably caught). LLM-judge matching only if right-line-wrong-diagnosis
     false matches appear (judge model ≠ review model).
  4. A **playground PR** (draft, `do-not-merge`, excluded from workflows)
     stays useful only for exercising `post.sh`/inline posting — not the
     primary eval path.
  5. Growth: **historical bug replay** — freeze the pre-fix state of real
     fix commits as fixtures (the fix commit IS the golden finding; our own
     `1b3e315` is a ready-made seed). 5–10 replay fixtures make prompt A/B
     comparisons meaningful (single-fixture A/B is noise: a 4-tool field
     study found 93.4% of catches unique to one tool).

### Security / robustness quick wins

- **Pin the opencode installer** (currently unpinned `curl | bash`; PR-Agent
  pins by Docker digest with artifact attestations). At minimum pin a version;
  ideally verify a checksum.
- **Warn when a consumer repo's own `opencode.json` replaces the hardened
  bundled config** (the config-precedence rule silently swaps out the
  bash/webfetch/websearch denials — layer 1 of the security model).
- **Word-boundary trigger match**: `grep -qF "@openreview"` fires on the
  phrase quoted anywhere inside a trusted user's comment; tighten to a
  word-boundary regex.
- **Comment-arg hygiene (future)**: if we ever accept options in trigger
  comments, copy PR-Agent's deny-list approach (never allow comment-supplied
  model/endpoint/approval settings; config-file-only).

---

## Part 2 — Long-term epic: learning over time

The field's three maturity levels (see `competitors.md` §13):

1. **Static NL rules in repo files** — we have this in embryonic form
   (CLAUDE.md/`conventions/` prompt hints). Upgrade path: a first-class
   `.openreview.toml` (or `best_practices.md`) read from the *target* repo
   with `extra-instructions` and per-path guidance (CodeRabbit
   `path_instructions`, BUGBOT.md, AGENTS.md are the precedents). Read from
   the default branch, never from the PR head (PR-Agent's documented trust
   boundary).
2. **Feedback signals** — item V above (reactions/replies harvest).
3. **Persistent per-repo memory** — suppressed finding patterns, learned team
   preferences, feedback digests, accumulated across PRs. Requires a writable
   store; the infra-free answer is the hub-repo knowledge base (§3.4):
   scheduled harvest + weekly warmup skills + a review-time picker. A later
   iteration can add Greptile-style similarity matching (awk token-overlap
   prefilter, then a cheap-LLM same-issue check folded into verify;
   embeddings-via-curl with vectors as JSON in git if ever needed — no
   vector DB at our scale; see `implementation-notes.md` §4).

Order: 1 → 2 → 3. Each level works without the next.

---

## Part 3 — Org-wide deployment & persistent memory (researched 2026-07)

Target flow (verified feasible, **zero hosted infrastructure**): fork this
repo into an org → from the fork, manually invoke a review of ANY PR in ANY
org repo → the bot reads existing comments/threads, recalls per-repo memory,
posts ONE marker-identified comment as `yourapp[bot]`, and updates it on later
invocations.

### 3.1 The mechanism: central dispatch repo + webhook-less GitHub App

`GITHUB_TOKEN` is repo-scoped — it cannot touch sibling repos. The documented,
mainstream solution is a **GitHub App with the webhook turned OFF**, used
purely as a token-minting identity inside Actions
([`actions/create-github-app-token`](https://github.com/actions/create-github-app-token)).
GitHub's own docs bless the pattern ("apps used only for authentication should
uncheck Active; no webhook URL required").

One-time org setup (~10 minutes, no per-target-repo setup at all):

1. Fork/import this repo into the org; add `review-dispatch.yml` with
   `workflow_dispatch: inputs: {repo, pr}`.
2. Register a GitHub App under the org: webhook **disabled**; permissions
   `metadata:read`, `contents:read`, `pull-requests:write`, `issues:write`
   (+ `contents:write` granted only against the memory repo, §3.3).
3. Install the App org-wide ("All repositories" — future repos included).
4. Org secrets/vars: App client ID (var), App private key (secret), LLM creds.

Per run:

```yaml
- uses: actions/create-github-app-token@v2
  with:
    client-id: ${{ vars.REVIEWER_APP_CLIENT_ID }}
    private-key: ${{ secrets.REVIEWER_APP_PRIVATE_KEY }}
    owner: ${{ github.repository_owner }}
    repositories: ${{ inputs.repo }}     # scope down per run
    permission-contents: read
    permission-pull-requests: write
    permission-issues: write
```

then `actions/checkout` with `repository:`/`ref: refs/pull/N/head`/`token:`,
and the minted token feeds `gather.sh`/`post.sh` exactly like `GH_TOKEN` today
— **the step-scoped-token architecture carries over unchanged**. Invocation:
`gh workflow run review.yml -R org/reviewer -f repo=org/target -f pr=123` or
the Actions-tab button (requires write access to the reviewer repo — that's
the permission gate). Comments appear as `yourapp[bot]`; marker dedup makes
re-runs update in place. Bonus: App-tier rate limits (5k→12.5k req/hr vs
GITHUB_TOKEN's 1k).

Trade-off to document: the App key can act on every installed repo, and anyone
who can modify workflows in the reviewer repo can wield it. Mitigations:
per-run `repositories:` scoping, `permission-*` downscoping, branch protection
+ CODEOWNERS on the reviewer repo, optionally an Actions environment with
required reviewers on the token-minting job.

Evaluated and rejected for this goal:

- **Org rulesets "required workflows"** — Enterprise-only, `pull_request`-family
  triggers only (no `workflow_dispatch`/`issue_comment`), and becomes a
  merge-blocking required check — wrong shape for an on-demand advisory
  reviewer.
- **Reusable workflows alone** — still need a ~10-line caller stub in every
  repo; fine later as the opt-in path for per-repo `@openreview` comment
  triggers (comment events only fire workflows in the repo where the comment
  was made), but not needed for the central-dispatch flow.
- **Hosted webhook server (probot etc.)** — what a "real" GitHub App buys
  (org-wide comment triggers with zero stubs, sub-second latency) is exactly
  the infra we're avoiding. Revisit only if comment-trigger-everywhere becomes
  a hard requirement. Notably, nobody in the field ships the
  "central dispatch + webhook-less App" pattern as a product — PR-Agent's
  org-wide story is a self-hosted webhook server; CodeRabbit's is vendor SaaS.
  **This is a differentiation opportunity.**

### 3.2 Per-PR state

Hidden HTML block inside the existing marker comment
(`<!-- openreview:state {…} -->`): last-reviewed SHA, patch-id, finding IDs,
suppression acks. Zero new permissions, invisible when rendered, dies with the
PR, and the existing MARKER machinery is already 80% of it. (65k-char comment
cap — keep state small. Anyone with write access can edit it — treat as
advisory, never as a security boundary.) This is the same pattern
ai-pr-reviewer used to store reviewed-commit SHAs.

### 3.3 Per-repo learned memory

**A dedicated private `org/openreview-memory` repo**, one file per target repo
(`memory/<repo>.md`, `prefs/<repo>.toml`, `org.toml`). The App's
`contents:write` is granted **only here** (second scoped token mint against
just this repo); product repos never receive bot commits. Full git history,
human-correctable via PR, private by default. Concurrency: one file per target
repo + retry on non-fast-forward is plenty at review cadence.

Rejected alternatives (verified):

- **Committed file in the target repo** — needs `contents:write` org-wide
  (big escalation), fights branch protection, pollutes history. Its read-only
  cousin (human-maintained `.openreview.toml` in the target repo, bot reads
  with `contents:read`) IS the plan for per-repo config.
- **Repo wiki** (PR-Agent-style) — `GITHUB_TOKEN` can push only to its *own*
  repo's wiki, and only after manual initialization; there is **no wiki
  permission in the App/fine-grained model** — App-token cross-repo wiki write
  is unverified/likely broken. OK as an optional human-edited config source,
  wrong as the bot's write store.
- **Actions cache/artifacts** — 7-day eviction / branch scoping / run-scoped;
  not durable or addressable.
- **Gists** — App installation tokens and fine-grained PATs have no gist
  support at all; user-owned, not org-owned.
- **git notes / custom refs** — pushable but invisible in the GitHub UI since
  2014, needs `contents:write` on targets, hard to debug. Trivia only.
- **Issues/Discussions as KV** — workable but awkward; no better than the
  memory repo and needs more machinery.

### 3.4 Living knowledge base in the hub repo: scheduled harvest + picker

Extension of §3.3 (idea 2026-07): the org fork is not just the dispatch repo —
it doubles as the **knowledge base**, kept condensed and *living* (built from
recent work, regenerated rather than accumulated). This supersedes the
separate `org/openreview-memory` repo as the default: keeping knowledge in
the hub repo itself means the harvest workflow **commits to its own repo
with the plain `GITHUB_TOKEN`** — the GitHub App then needs `contents:write`
nowhere at all (read-only + PR/issue write everywhere else). A separate
memory repo remains an option when the hub fork should stay clean.

**Layout** — per-repo folders, optionally path-scoped subfolders mirroring
the target repo's tree (BugBot's walk-up rule files are the precedent):

```
knowledge/
  <repo>/
    memory.md            # condensed conventions/learnings (the distilled layer)
    findings-log.tsv     # raw harvest, append-only, pruned to a window
    src/api/…/memory.md  # optional path-scoped rules (picked up by walk-up match)
  org.md                 # org-wide conventions
```

**Scheduled harvest** (cron workflow in the hub repo): for each configured
repo, scan PRs reviewed by the action since the last run (marker comment
present) and collect outcome signals per finding — reactions (with logins,
maintainer-weighted), replies, resolved/outdated threads, and whether the
finding's target lines changed before merge (the resolution-rate signal,
item U). Append raw signals to `findings-log.tsv`; then a **cheap-model
distillation pass regenerates `memory.md` from a sliding window** (e.g. last
90 days) — Qodo's monthly auto-best-practices regeneration is the precedent,
including the cap (`max_patterns`-style, e.g. ≤15 rules per repo) that keeps
the file condensed. Regeneration-not-accumulation IS the freshness/decay
mechanism: stale conventions fall out when recent work stops confirming
them. Guardrails: learn only from *human* signals (never from the bot's own
text — feedback-loop risk); apply the ≥3-unique-signal quorum before any
suppression rule; every rule carries provenance (source PR/comment) so
humans can audit and revert via normal PRs to the hub repo.

**Picker at review time** (the "file-based RAG" half, kept deliberately
non-vector): `gather.sh` fetches `knowledge/<repo>/` and selects what enters
the prompt in two stages — (1) deterministic: walk-up path matching of the
PR's changed files against path-scoped subfolders + always `memory.md` +
`org.md`, under a hard token budget (~8k, PR-Agent's skills-inlining budget
is the precedent); (2) optional, folded into the existing cheap prep pass:
pick the top-K rules most relevant to this diff. The strong model then sees
a short, curated "team memory" section — never the raw log.

**Warmup scans / skills** (idea 2026-07): hub-repo Actions minutes are
effectively cheap, so the hub can *proactively build* knowledge instead of
only harvesting feedback. A weekly (or on-demand) **warmup workflow** runs
per configured repo — from the fork, never from the repo under review, so
target repos carry zero extra CI — checking the target out read-only and
running a set of **skills** (cheap-model agentic scan prompts, each writing
one distilled file into `knowledge/<repo>/`):

- *conventions extraction* — mine the codebase + recently merged PRs for
  de-facto conventions not written down anywhere (naming, error handling,
  test patterns) → `conventions.md`;
- *review-comment mining* — Ellipsis's trick: infer rules from what human
  reviewers actually said on recent PRs → candidate rules with provenance;
- *architecture/hotspot map* — a short "how this repo is organized, where
  the dangerous parts are" brief (churn × past-bug overlap) → `map.md`;
- *dependency inventory* — manifest → current-versions/advisories snapshot
  (ties into Tier 4 item Z.1) → `deps.md`.

Each skill is just a prompt file + output path, so orgs can drop custom
skills into their fork (`skills/*.md` — the same shape PR-Agent's Agent
Skills and our passes already use). The review action then starts "warm":
the picker serves pre-digested repo knowledge instead of the strong model
re-deriving it inside every review. Same guardrails as the harvest:
distilled output is capped and regenerated (not accumulated), lands via
commits to the hub repo (plain `GITHUB_TOKEN`), and is auditable/correctable
through normal PRs. Security note: warmup skills read *checked-in target
code* — untrusted content — so they run under the same hardened opencode
config as review passes (no bash/network/task), and their output files are
prompt *context*, never executed.

### 3.5 Summary table

| Need | Store | Extra permissions |
|---|---|---|
| Per-PR state (last SHA, finding IDs) | hidden HTML block in the marker comment | none |
| Per-repo learned memory + warmup knowledge | `knowledge/<repo>/` in the hub repo itself (§3.4); separate `org/openreview-memory` repo as the alternative (§3.3) | none — hub workflows commit with their own `GITHUB_TOKEN` (alt: App `contents:write` on the one memory repo) |
| Per-repo config | `.openreview.toml` in the target repo (default branch), human-maintained | none (`contents:read`) |
| Org-wide config | file in the hub repo | none |
| Feedback signal | reactions + replies on the bot comment (item V) + scheduled harvest (§3.4) | none |

### 3.6 Implementation sketch (when we get there)

1. `review-dispatch.yml` (workflow_dispatch repo/pr inputs + App token mint +
   cross-repo checkout) — pure workflow work, no engine changes.
2. `post.sh`: edit-in-place sticky comment (item S) + state block read/write
   (item G) — shared foundation.
3. `gather.sh`: knowledge picker (fetch `knowledge/<repo>/`, walk-up path
   match, token budget) + harvest reactions/replies for the current PR
   (item V); prompts gain a "team memory" context section.
4. Hub cron workflows: **harvest** (scan recently-reviewed PRs → signal log →
   cheap-model distillation regenerates `memory.md`) and **warmup skills**
   (weekly per-repo scans → `conventions.md`/`map.md`/`deps.md`), both
   committing to the hub repo with its own `GITHUB_TOKEN` (§3.4).
5. Optional later: per-repo stub workflow template for `@openreview` comment
   triggers in repos that want them; GitHub App manifest-flow setup helper.

---

## Part 4 — Suggested implementation order

| Wave | Items | Rationale |
|---|---|---|
| 0 | T0-1…T0-4, X | Urgent hardening (config, pinning, sanitization) + eval harness — every later wave gets measured against the same frozen fixtures |
| 1 | R, M′, K | Quality floor: anchors + kill-list + gating — all prompt/awk work |
| 2 | P, S, G | Cost + idempotent posting + incremental review (S and G share the comment-state foundation) |
| 3 | T, J | Cheap triage (biggest remaining cost lever), then inline comments (needs R) |
| 4 | Part 3 §3.6 steps 1–2 | Org dispatch + App identity — unlocks the fork-into-org story |
| 5 | V, U, Part 3 §3.6 steps 3–4 | Feedback loop + resolution metric + hub knowledge base (harvest + warmup skills + picker) — the learning epic |
| 6 | W, N, O, L′, telemetry | Thorough mode, evidence gating, linter grounding, caching |
| — | Y, Z, AA (Tier 4) | Exploratory — pick up on demand; Y (connector hook) and Z.1 (dep freshness) are small enough to slot into any wave; AA after the eval playground exists to measure it |

Security quick wins (installer pinning, config-replacement warning, trigger
word-boundary) can land any time as independent commits.
