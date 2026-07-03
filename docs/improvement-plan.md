# gh-openreview — Improvement Plan

Status: **living document** · Author: pawel · Last major revision: 2026-07-03
(field-research pass — per-project findings live in [`competitors.md`](competitors.md))

## Direction

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

## Part 1 — Backlog, re-prioritized

Goal tags: 💸 cost · 🔮 predictability · 🛡️ robustness · 🎯 quality ·
📊 observability. Provenance for each idea is in `competitors.md`.

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

### Testing & evals

- **X. Eval playground 📊🛡️** — a way to run the whole pipeline end-to-end on
  demand, without pushing commits or burning CI on real PRs. Two halves:
  1. **A permanent playground PR in this repo**: branch `eval/playground` off
     `main`, containing a dedicated `eval/` folder with fixture code that
     carries **known, seeded bugs** (an off-by-one, a dropped error check, a
     race, a convention violation, a pure nit…), opened as a draft PR labeled
     `do-not-merge` + excluded from the self-test workflow triggers so it
     never runs CI. It hangs open indefinitely as a stable review target.
  2. **A local runner** (`eval/run.sh`): wraps the existing local flow from
     CLAUDE.md (`OR_REPO=… OR_PR=<playground-pr> gather.sh → passes.sh →
     render.sh`, no `post.sh` by default) so a full review runs from a laptop
     against the playground PR with any model combo, and prints
     `opencode-review.md` + timing. Optional `--post` to exercise post.sh
     against the playground PR only.
  3. Later: a `eval/expected.md` golden list of the seeded bugs → a crude
     recall/precision score per run (the field's lesson — Ellipsis runs heavy
     CI evals; BugBot hill-climbs on resolution rate — you can't tune what
     you don't measure). Prompt/model changes get compared on the same frozen
     PR instead of on live traffic.

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
   store; the infra-free answer is Part 3's memory repo. A later iteration
   can add Greptile-style similarity matching (even crude text similarity in
   bash, or a cheap-model "is this like a previously rejected finding?"
   check against the memory file — no vector DB needed at our scale).

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

### 3.4 Summary table

| Need | Store | Extra permissions |
|---|---|---|
| Per-PR state (last SHA, finding IDs) | hidden HTML block in the marker comment | none |
| Per-repo learned memory | `org/openreview-memory` repo, file per target repo | `contents:write` on that one repo |
| Per-repo config | `.openreview.toml` in the target repo (default branch), human-maintained | none (`contents:read`) |
| Org-wide config | file in the reviewer/memory repo | none |
| Feedback signal | reactions + replies on the bot comment (item V) | none |

### 3.5 Implementation sketch (when we get there)

1. `review-dispatch.yml` (workflow_dispatch repo/pr inputs + App token mint +
   cross-repo checkout) — pure workflow work, no engine changes.
2. `post.sh`: edit-in-place sticky comment (item S) + state block read/write
   (item G) — shared foundation.
3. `gather.sh`: read memory file (if the memory repo is configured) + harvest
   reactions/replies (item V); prompts gain a "team memory" context section.
4. A `memory-write` step (token-scoped like gather/post): after each run,
   append feedback digests / confirmed suppressions to the memory repo.
5. Optional later: per-repo stub workflow template for `@openreview` comment
   triggers in repos that want them; GitHub App manifest-flow setup helper.

---

## Part 4 — Suggested implementation order

| Wave | Items | Rationale |
|---|---|---|
| 0 | X | Eval playground first — every later wave gets measured against the same frozen PR |
| 1 | R, M′, K | Quality floor: anchors + kill-list + gating — all prompt/awk work |
| 2 | P, S, G | Cost + idempotent posting + incremental review (S and G share the comment-state foundation) |
| 3 | T, J | Cheap triage (biggest remaining cost lever), then inline comments (needs R) |
| 4 | Part 3 §3.5 steps 1–2 | Org dispatch + App identity — unlocks the fork-into-org story |
| 5 | V, U, Part 3 §3.5 steps 3–4 | Feedback loop + resolution metric + memory repo — the learning epic |
| 6 | W, N, O, L′, telemetry | Thorough mode, evidence gating, linter grounding, caching |

Security quick wins (installer pinning, config-replacement warning, trigger
word-boundary) can land any time as independent commits.
