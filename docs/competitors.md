# Automated PR-review tools — field research

Status: research archive · Last updated: 2026-07-03

Per-project notes on how automated (LLM-based) PR reviewers in the field are
built. **Deliberately agnostic**: this file describes what each project does and
how, without comparing to this repo — the solution here may change, but the
field research stays useful as a reference baseline. Confidence markers:
**[V]** verified from source/docs, **[VC]** vendor self-claim, **[S]**
secondary/speculative.

Companion docs: `improvement-plan.md` (what we take from this and in what
order).

---

## 1. Qodo Merge / PR-Agent

Repo: <https://github.com/qodo-ai/pr-agent> (community continuation:
`The-PR-Agent/pr-agent`). Python, ~100%. Docs (bundled): `docs/docs/` —
formerly qodo-merge-docs.qodo.ai.

### Architecture [V]

- **No agent/tool loop.** Every tool is a single-shot (or few-shot) prompt →
  structured YAML response, validated against a Pydantic schema embedded in the
  prompt itself. LLM access via litellm (any provider); git access via a
  provider abstraction (GitHub, GitLab, Bitbucket, Azure DevOps, Gerrit, Gitea,
  CodeCommit, `local`).
- Tools = classes in `pr_agent/tools/`, each paired with a Jinja2 prompt file in
  `pr_agent/settings/*.toml`: `/review`, `/improve`, `/describe`, `/ask` (+
  line-scoped ask), `/update_changelog`, `/add_docs`, `/generate_labels`,
  `/similar_issue` (vector DB: pinecone/lancedb/qdrant), `/config`.
- Run modes sharing one core: CLI, Docker-based GitHub Action
  (`servers/github_action_runner.py` reads the event payload), hosted
  GitHub-App/GitLab/Bitbucket FastAPI webhook servers, AWS Lambda, polling
  server.
- Layered dynaconf config: built-in defaults < external config URL < org
  `pr-agent-settings` repo < repo `.pr_agent.toml` < wiki `.pr_agent.toml` <
  env vars < per-comment `--section.key=value` args.

### Context gathering [V]

- Inputs: PR title + branch name, description (author's original kept separate
  from AI-generated), commit messages (clipped to `max_commits_tokens=500`),
  the diff, and full before/after file blobs (used server-side for context
  extension and validation, not dumped wholesale into the prompt).
- **Diff re-encoding** (`algo/git_patch_processing.py`,
  `decouple_and_convert_to_hunks_with_lines_numbers`): each hunk becomes a
  `__new hunk__` section — new-side code **with absolute line numbers prefixed
  to every line** — plus a `__old hunk__` section (removed lines, unnumbered),
  under a `## File: 'path'` header. Stated rationale: raw `+/-` interleaving
  confuses models, and in-prompt authoritative line numbers let the model
  *copy* exact `start_line`/`end_line` for anchoring instead of computing them.
- **Hunk extension** (`extend_patch()`): rewrites `@@` headers with extra
  context read from the file blobs. Asymmetric — `patch_extra_lines_before=5`,
  `patch_extra_lines_after=1`, hard cap 10; skipped for `.md`/`.txt`. With
  `allow_dynamic_context=true` it scans up to 10 lines upward for the enclosing
  function/class header and extends exactly to it. The extension is
  **validated**: extra lines must be identical in base and head (else it backs
  off), and the hunk's first context line must actually match the file —
  guards against bogus hunks.
- **Ticket context**: auto-detects GitHub/GitLab issues from the PR description
  (`#123`, URLs, `org/repo#123`) **and from branch names**
  (`123-fix-bug`, configurable regex), plus Jira (cloud + server). Fetches
  title, description, acceptance-criteria custom fields, subtasks, labels,
  images. `/review` emits a per-ticket **compliance check** (requirements
  restated; fulfilled / not fulfilled / needs-human-verification) and can label
  the PR `Fully compliant`/`Partially compliant`/`Not compliant`.
- **AI metadata chaining**: `/describe` runs first; its per-file "changes
  walkthrough" summaries are injected under each file header in later
  `/review`/`/improve` prompts (`enable_ai_metadata`) — cheap staged
  chain-of-thought with no extra calls at review time.
- Prior PR comments are *not* fed to `/review`/`/improve` by default; `/ask`
  keeps conversation history. `/improve` instead carries its own suggestion
  history inside its persistent comment.

### Token/cost management — "PR compression" [V]

Source: `algo/pr_processing.py` + `docs/core-abilities/compression_strategy.md`.

- Optimistic first: build the fully-extended diff; if
  `prompt + diff + 1500-token output buffer < model max`, send everything.
  Otherwise compress — and drop the extra context lines entirely.
- Compression ordering: files grouped by **repo language dominance** (main
  languages first; binaries/non-code excluded via a large deny-list), then
  within each language **sorted by patch token count descending**.
- Deletion pruning: fully-deleted files reduced to a name under
  `Deleted files:`; **deletion-only hunks are stripped** from surviving patches
  (`omit_deletion_hunks`) — additions are what get reviewed.
- Greedy fitting with soft (`max_tokens − 1500`) and hard (`− 1000`)
  thresholds; oversized individual patches token-clipped
  (`large_patch_policy="clip"`). Files that didn't fit are appended as bare
  filename lists (`Additional modified files (insufficient token budget)…`) —
  **the model is always told what it could not see.**
- `max_model_tokens=32000` caps the effective window regardless of model — a
  deliberate "less is more" stance.
- Large-PR chunking: `/improve` splits the remainder into multiple ≤32k
  prompts (≤3 parallel calls, N suggestions per chunk); `/describe` similar
  (`max_ai_calls=4`, async) with a final merge/summarization call.
- Model tiers: `config.model` + `fallback_models` (tried in order on failure),
  optional `model_weak` for non-review tools (describe/ask/changelog), optional
  `model_reasoning` for self-reflection. `temperature=0.2`, optional fixed
  seed.

### Output & posting [V]

- `/review` schema: `key_issues_to_review` (max `num_max_findings=3`:
  file, 1–2-word header, content **with a required trigger scenario**,
  `start_line`/`end_line`), plus toggleable fields — security concerns,
  estimated review effort 1–5, tests yes/no, ticket compliance, TODO scan,
  can-be-split, 0–100 score. Prompt bakes in calibration ("prefer not
  reporting over guessing", "no 'Great job' filler", empty list acceptable).
- `/improve` schema per suggestion: file, language, `existing_code` (verbatim
  from a `__new hunk__`), `improved_code`, content, ≤6-word summary, label.
  The before/after pair powers **committable GitHub `suggestion` blocks**.
- Posting modes: `/review` → one structured comment (+ labels). `/improve` →
  default single collapsible table grouped by label with score/impact columns;
  `commitable_code_suggestions=true` switches to inline review comments with
  suggestion blocks; **dual publishing** posts the table *and* inlines only
  suggestions ≥ a score threshold. Invalid inline anchors are verified and
  fixed or fall back to a regular comment
  (`publish_inline_comments_fallback_with_verification`).
- **Persistent comment**: finds its previous comment by a fixed header string
  and **edits it in place**, rewriting the header to "(Review updated until
  commit <sha-link>)", optionally dropping a tiny "review updated" ping comment
  so watchers still get a notification. `/improve` folds previous suggestion
  tables into a collapsed `#### Previous suggestions` history (≤4 generations)
  and ✓-marks suggestions whose flagged code has since changed.
- **Incremental review**: `/review -i` reviews only commits since the last
  PR-Agent review, with `minimal_commits_for_incremental_review` /
  `minimal_minutes_for_incremental_review` guards and a skip-comment when
  nothing new. Push-trigger auto-runs are debounced: bot/merge commits
  ignored, pending-task backlog with 300 s TTL so rapid pushes coalesce.

### Quality controls [V]

- **Self-reflection pass** (`pr_code_suggestions_reflect_prompts.toml`): all
  suggestions re-sent in one call; the model scores each 0–10 **in batch** (so
  it can compare) with rationale, and re-derives exact hunk line numbers.
  Score 0 ⇒ dropped; user threshold (`suggestions_score_threshold`, docs
  recommend ≤7–8) filters more; scores re-rank into impact tiers.
- The reflect prompt **hard-codes score caps for known noise classes**:
  "verify/ensure that…" suggestions ≤7; error-handling/type-checking ≤8; and
  **automatic 0** for docstring/type-hint/comment suggestions, unused-import
  removal, adding imports, narrower exception types, anything questioning
  symbols possibly defined outside the diff, `improved_code` that doesn't
  actually differ, and suggestions contradicting the PR's purpose.
- `focus_only_on_problems=true` default biases away from style.
- Repo knowledge: `extra_instructions` free text per tool; `best_practices.md`
  at repo root (≤800 lines; org-global + hierarchical variants); **auto best
  practices** (learned patterns, `max_patterns=5`); **Agent Skills** — inlines
  text-only `SKILL.md` files from *host-configured* paths under an 8k-token
  budget (no progressive disclosure because there is no tool loop).
- Interactivity: comment checkboxes ("Apply this suggestion", "More",
  "Update"), author self-review acknowledgment.

### Security model [V]

- Self-hosted, BYO keys. Supply chain: pin action by release tag or Docker
  digest; images carry GitHub Artifact Attestations.
- **Comment-arg sanitization** (`algo/cli_args.py`): a (base64-obfuscated)
  deny-list blocks comment-supplied overrides of secrets/endpoints/approval
  settings (`openai.key`, `api_base`, `webhook_secret`, `enable_auto_approval`,
  the prompt fields `system`/`user`, …). Approval-adjacent settings cannot be
  set from comments at all — only from a committed config file.
- `skills.paths` is host-level only — a repo-supplied value is ignored (a
  malicious repo could otherwise exfiltrate host files into prompts). Docs warn
  never to read config from `${{ github.head_ref }}` (attacker-controlled
  `.pr_agent.toml` could redirect `api_base` or self-approve).
- **No author-association gating on comment triggers** in the OSS app/action —
  only `sender_type == "Bot"` is filtered (feedback-loop prevention). Anyone
  who can comment can invoke `/review`. No textual prompt-injection defenses;
  mitigation is structural (no tool loop, no shell, schema-constrained output,
  deny-listed config args).

---

## 2. CodeRabbit

### 2a. OSS predecessor: `coderabbitai/ai-pr-reviewer` [V]

Archived Nov 2023, original repo since **deleted**; mechanics verified from a
surviving fork (`Stuhlmuller/ai-pr-reviewer`, `src/prompts.ts`,
`src/review.ts`). Still the canonical design many actions copied.

- **Two-model split**: `openai_light_model` (cheap) for summarization/triage,
  `openai_heavy_model` for the review — cheap model does the *broad* work, the
  expensive model only reviews what triage flagged (~"$20/day for 20 devs").
- **Per-file triage**: the light-model per-file summary prompt also demands a
  machine-parseable verdict — `[TRIAGE]: <NEEDS_REVIEW|APPROVED>`. `APPROVED`
  (typo/format/rename-only) files **skip the expensive pass entirely**;
  "when in doubt, err on the side of caution and triage as NEEDS_REVIEW".
  `review_comment_lgtm: false` additionally suppresses "LGTM" comments —
  noise control by *not reviewing*, not just filtering output.
- **Incremental review, state-in-comment**: reviewed commit SHAs are stored in
  hidden HTML blocks inside its own sticky summary comment
  (`getReviewedCommitIdsBlock`/`addReviewedCommitId`); each run computes the
  highest reviewed commit and diffs only that..head. Review progress
  (files done/total) is also serialized into the comment so interrupted runs
  resume. **The PR comment is the state store — no database.**
- **Changeset dedup pass**: raw per-file summaries re-fed to the model to
  "deduplicate and group files with related changes", then compressed into a
  ≤500-word short summary used as shared context for every per-file review
  call (hierarchical summarization).
- **Review pass** (heavy model, per file): input is new hunks **annotated with
  line numbers** + old hunks + existing comment chains. Output format is
  strict `22-22:\n<comment>\n---` records; every hunk range must be answered
  (`LGTM!` for clean ranges). Fixes must be `diff`-fenced blocks whose range
  exactly matches the replace range — that's what makes them postable as
  GitHub suggested changes.
- **Chat**: on `pull_request_review_comment` events, a dedicated prompt gets
  the file diff + hunk + whole comment chain and replies in-thread.
- Other: `path_filters`, `@coderabbitai: ignore` keyword in the PR description,
  token-budget packing of hunks per request, one sticky replaced summary
  comment.

### 2b. Commercial CodeRabbit [V]/[VC]

Sources: <https://docs.coderabbit.ai/overview/architecture>,
<https://www.coderabbit.ai/blog/how-coderabbits-agentic-code-validation-helps-with-code-reviews>,
Google Cloud Run case study, docs on review instructions/learnings.

- Pipeline: sandboxed cloud execution with the full repo cloned; **50+ static
  analyzers/linters/SAST**; specialized parallel agents — Review,
  **Verification**, Chat, Pre-Merge Checks, Finishing Touches; agentic
  codebase exploration. Context assembly gathers ~10–15 signals per change:
  diff, a code graph of how edited code connects to the repo, linked
  Jira/Linear tickets, CI failure logs, lint output, accumulated team
  preferences.
- Sandbox: throwaway microVM per review (reported 1 h timeout, 8 vCPU,
  32 GiB, repo in memory) with a second Jailkit confinement layer — PR code is
  treated as untrusted; the agent can build the project and run linters and
  scripts inside ("tools in jail").
- **Verification agent**: before posting, checks each finding "for accuracy,
  relevance, and usefulness — filtering out noise"; static-analyzer output
  (ast-grep etc.) grounds LLM findings; validation is incremental (only
  changed code).
- **Path-based instructions**: `.coderabbit.yaml` `path_instructions` map
  minimatch globs → natural-language guidance; ast-grep custom rules for
  syntax-aware checks; `path_filters` with `!` exclusions and large default
  exclusion lists.
- **Learnings**: replying to a CodeRabbit comment triggers evaluation of
  whether the reply expresses a systematic preference; if so it's stored as a
  "learning" (repo/org scoped) in an internal DB and injected into future
  reviews; manageable in a dashboard; bulk import via
  `@coderabbitai add a learning using docs/coding-standards.md`.

---

## 3. Greptile

Sources: <https://www.greptile.com/blog/make-llms-shut-up>,
<https://www.greptile.com/blog/greptile-v3-agentic-code-review>, docs, ZenML
case study.

- **Full-codebase graph index** [VC]: builds a language-agnostic graph of every
  file/function/class/dependency before reviewing; PRs are reviewed against
  whole-repo context.
- **v3 agentic loop** [V]: replaced a rigid fixed workflow with an iterative
  agent holding codebase-search and learned-rule tools; multi-hop investigation
  (call chains, git history). Published metrics: upvote/downvote ratio
  1.44 → 5.13, action rate 34.75% → 59.24%; 3× more context tokens but 75%
  lower inference cost via aggressive prompt caching.
- **The noise study ("How to Make LLMs Shut Up") — the most important
  empirical result in the field [V]:**
  - Self-audit baseline: ~19% of the bot's comments were valuable, ~2% flat
    wrong, **~79% technically-correct nits**.
  - **Prompting failed**: "even with all kinds of prompting tricks, we simply
    could not get the LLM to produce fewer nits without also producing fewer
    critical comments." Few-shot examples made it *worse*.
  - **LLM-as-judge failed**: having the model rate its own comments 1–10 and
    cutting below 7 was "nearly random", and slow.
  - **What worked**: embed every comment a team 👍/👎s (or
    addresses/ignores) into a per-team vector store; block a new candidate
    comment if cosine-similar to ≥3 unique downvoted comments, pass if similar
    to ≥3 upvoted, default-pass on ambiguity. Address rate 19% → 55%+ in two
    weeks. Insight: "nit" is **team-subjective** — learn it per team from
    feedback, not from the model.

---

## 4. Cursor BugBot

Sources: <https://cursor.com/blog/building-bugbot>,
<https://cursor.com/docs/bugbot>.

- **V1 pipeline** [V]: 8 parallel passes over the diff **with randomized diff
  order** (forcing diverse reasoning paths) → cluster similar findings →
  **majority voting** (findings seen in only one pass are dropped) → merge
  each cluster into one description → category filters (e.g. drop compiler
  warnings) → a **validator model** pass for false positives → **dedup against
  the previous run's findings**.
- **V2 rewrite to fully agentic** (fall 2025) [V]: the agent reasons over the
  diff, calls tools, decides its own investigation depth. Counterintuitive
  finding: the agentic version was *too cautious*; they switched to aggressive
  prompts encouraging investigation of every suspicious pattern — precision was
  maintained by the agent's ability to **verify suspicions with tools**, not by
  restraint.
- **Resolution rate as the driving metric** [V]: an AI judge checks at merge
  time which flagged bugs the author actually fixed in the final code. Turned
  quality into a hill-climbable number: resolution rate 52% → 70%+, bugs
  flagged/run 0.4 → 0.7, resolved bugs/PR 0.2 → 0.5.
- Config/UX: nested `.cursor/BUGBOT.md` rules files (root + walk-up from
  changed files); rule merge order Team → repo (learned + manual) → BUGBOT.md →
  User; runs on each PR update (configurable once-per-PR); reads existing PR
  comments to avoid duplicates and build on prior feedback; "Fix in Cursor"
  deep links; CI check verdict (neutral vs failure). Stated philosophy: **the
  cost of a false positive vastly exceeds a false negative.**

---

## 5. OpenAI Codex review

Sources: <https://alignment.openai.com/scaling-code-verification/>,
<https://developers.openai.com/codex/integrations/github>, SDK cookbook.

- **Trained for precision over recall** [V]: accepted "modestly reduced recall
  in exchange for high signal quality and developer trust." A base model on
  diff-only finds high-impact issues but with many false alarms; the
  review-trained model is what cuts the noise.
- **Explicit comment utility model** [V]:
  benefit = P(correct) × cost_saved − human verification cost −
  P(incorrect) × false-alarm cost. Comments with negative expected utility
  (style nits, typos in notebooks) are suppressed.
- **Severity gate at posting**: GitHub integration "flags only P0 and P1
  issues." Repo customization via `AGENTS.md` review-guidelines sections.
- **Full repo + execution**: the reviewer has the whole codebase and a
  container where it can **run code to test its own hypothesis** about a bug
  before claiming it — cited as key both to catching diff-invisible bugs and
  to reducing false alarms.
- Deployment stats [VC]: 100k+ external PRs/day; authors act on 52.7% of
  comments; >80% positive reactions.
- **The SDK cookbook's reference GitHub-Actions architecture** [V]: a
  three-job split for fork-PR safety — (1) read-only *prepare* job (diff
  chunking, prompt assembly), (2) *review* job running the model with **no
  write token and sudo dropped so the agent can't read its own API key**,
  (3) a separate write-scoped *publish* job that parses results and posts.
  Findings schema: `title, body, confidence_score, priority,
  code_location{absolute_file_path, line_range}` + an `overall_correctness`
  verdict.

---

## 6. Anthropic — claude-code-action & the code-review plugin

Repos: <https://github.com/anthropics/claude-code-action>,
<https://github.com/anthropics/claude-code/tree/main/plugins/code-review>,
<https://github.com/anthropics/claude-code-security-review>.

- **Architecture** [V]: runs the full Claude Code agent in the runner; review
  is a prompt plus an allowlisted toolset — no fixed pipeline. Context is
  agentic: `gh pr diff`, `gh pr view`, free file reads of the checkout —
  repo-context review, not diff-only.
- **Inline comments** via a dedicated MCP tool
  (`mcp__github_inline_comment__create_inline_comment`); comments are
  **buffered and classified after the session** unless `confirmed: true` —
  probe/test comments from subagents get filtered. Top-level feedback via
  `gh pr comment`.
- `track_progress: true` posts a live-checkbox tracking comment.
- **The `/code-review` plugin prompt** [V] — the most instructive artifact:
  - Launches **4 parallel subagents** — 2 cheap-tier (Sonnet) agents auditing
    CLAUDE.md-convention compliance, 2 strong-tier (Opus) agents hunting bugs
    independently. Mixed tiers = cost routing inside one review.
  - Findings get a **0–100 confidence score; posting threshold 80**.
  - Explicit **do-not-flag list**: pre-existing issues, style, speculative
    problems, anything a linter would catch, generic security hand-waving,
    "pedantic nitpicks a senior engineer wouldn't flag." Literal instruction:
    *"If you are not certain an issue is real, do not flag it."*
  - A validation step re-confirms each finding before posting. Committable
    `suggestion` blocks only for self-contained fixes.
  - Re-review checks `gh pr view --comments` for a prior review first; "one
    comment per unique issue."
- **Security**: `@claude` mention triggers gated to write-access users; fork
  PRs are the documented risk case; the API key only reaches the model step.
- **claude-code-security-review** (security-only sibling) [V]: fixed Python
  pipeline (audit → prompts → JSON findings → filter). Notable: a
  **hard-coded false-positive filter that excludes whole vulnerability
  classes** (DoS, rate limiting, resource exhaustion, generic input
  validation without proven impact, open redirects) plus user-supplied
  filtering instructions — a category kill-list, not a score. Posts inline
  comments; caches findings between commits. Explicitly states it is **not
  hardened against prompt injection** and should only run on trusted PRs.

---

## 7. Ellipsis

Sources: <https://www.nsbradford.com/blog/how-we-built-ellipsis>, docs, ZenML
write-up.

- **Many small agents, not one mega-prompt** [V]: parallel "Comment
  Generators," each hunting one issue class (customer rule violations,
  duplicated code, …), each independently benchmarkable.
- **Multistage filtering pipeline** over raw comments: (1) dedup (generators
  overlap), (2) **confidence threshold** (float cutoff), (3) **hallucination
  detection** — every comment must carry "Evidence" (links to code snippets)
  that is checked for logical support, (4) **customer-feedback filter** —
  embedding search over similar past comments and their recorded reactions.
  They show users *what was filtered and why*.
- **Rules from natural language**: style-guide-as-code; rules added in UI,
  **inferred from historical human review comments**, or extracted from
  style-guide files in the repo.
- **Auto-fix executes code**: generated fixes are run/tested in a sandbox
  before being offered.
- Reviews on open + every new commit; skips re-review of an already-reviewed
  head SHA; "Quiet mode" suppresses posting.
- Infra notes: keyword + vector search over tree-sitter AST-chunked code; an
  LLM binary classifier instead of a reranker; an Lsproxy sidecar for
  go-to-definition/find-references; prompts kept in code; heavy CI evals with
  request caching for determinism.

## 8. Sourcery

Source: <https://docs.sourcery.ai/Code-Review/>.

- Blend of LLM + its own static-analysis rules engine; **multiple specialized
  reviewers** (general quality, security, complexity, docs, tests, custom
  instructions).
- Post-generation validation pass "to reduce false positives and unhelpful
  comments," then composes the summary/reviewer's guide.
- Custom review rules in a config file; output language configurable; posts
  summary + reviewer's guide + line comments.

---

## 9. Alibaba open-code-review

Repo: <https://github.com/alibaba/open-code-review> (~10k stars, active).

Hybrid **"deterministic engineering for hard constraints + LLM agent for
judgment"**:

- Deterministic layer does file selection, **smart file bundling** (related
  files reviewed together, each bundle as an isolated sub-agent — scales to
  huge changesets), and template-engine rule matching — rules are matched by
  an engine, not by asking the model ("eliminates noise at the source").
- An **external positioning module verifies comment locations before output**
  (their answer to wrong line anchors); a **reflection module** re-checks
  finding content; a dedup pass runs before posting.
- Fine-tuned built-in ruleset (NPE, thread-safety, XSS, SQLi); 4-layer config
  precedence (CLI → project → global → defaults).
- Claims [VC] ~1/9 the tokens of a general-purpose agent at higher precision;
  explicitly trades recall for precision.

## 10. Kodus (Kody)

Repo: <https://github.com/kodustech/kodus-ai> (AGPLv3, active).

- Self-hosted platform, not an action: NestJS API + Next.js dashboard + review
  worker + webhook ingestion + RabbitMQ + Postgres/pgvector + MongoDB.
  GitHub/GitLab/Bitbucket/Azure Repos.
- Context: RAG over the codebase (pgvector) + AST-aware analysis.
- "Kody Rules": plain-language per-repo review policies; severity levels on
  every finding; token-usage dashboards.
- **Cross-PR state**: unimplemented suggestions become tracked "Kody Issues"
  that **auto-resolve when a later PR fixes them** — dedup persisting beyond
  one PR.
- BYO keys, any OpenAI-compatible endpoint.

---

## 11. Posting infrastructure: Danger JS & reviewdog

Not LLM tools, but the reference designs for review *posting*.

- **Danger JS** (<https://danger.systems/js/>): runs a `dangerfile.js` in CI;
  four result buckets (`fail`/`warn`/`message`/`markdown`); posts **one PR
  comment updated in place, identified by a hidden HTML marker**
  (dedup-by-marker). Inline mode anchors results to file:line where possible,
  **falling back to the main comment when the line isn't in the diff**. LLM
  usage happens via plugins piping output into `markdown()`/`warn()` — Danger
  contributes idempotent posting, not intelligence.
- **reviewdog** (<https://github.com/reviewdog/reviewdog>): language-agnostic
  diagnostic router. Input: errorformat or **RDFormat (rdjson/rdjsonl)** — a
  rich schema with severity, rule code + URL, ranges, and **code
  suggestions**. Reporters: `github-pr-review` (Review API inline comments
  incl. suggestion blocks), `github-pr-check`/`github-annotations`. **Filter
  modes** are the key idea: `added` (only lines added in the diff),
  `diff_context`, `file`, `nofilter` — with graceful **fallback to check
  annotations/log output when a finding falls outside commentable diff lines**
  (exactly the wrong-anchor problem LLM tools hit). Fork PRs: the token lacks
  Review/Check write access, so it degrades to logging-command annotations.
  A tool that emits rdjson gets anchoring, filtering, suggestions, and
  fork-degradation for free.

---

## 12. Smaller / single-purpose actions (the "naive tier")

- **villesau/ai-codereviewer** (~1k stars, unmaintained since 2024):
  TypeScript action; per-file diff chunks → OpenAI with a prompt demanding
  `{"reviews": [{"lineNumber", "reviewComment"}]}` → inline comments via
  `pulls.createReview`. Diff-only, no repo context, no cross-push dedup — the
  archetype of the naive tier and its failure modes (duplicate comments on
  every push, misanchored lines).
- **anc95/ChatGPT-CodeReview** (~4.4k stars): Probot app or action; per-file
  patch chunks with a `MAX_PATCH_LENGTH` cap; include/ignore globs;
  re-reviews changed files on push. Simple per-file comments.
- **presubmit/ai-reviewer**: summary + inline comments + PR-title generation;
  multi-provider; **runs on `pull_request_target` with secrets available to
  fork PRs — the documented anti-pattern**; `@presubmit ignore` opt-out;
  replies to threads.
- **Nayjest/Gito**: "high-confidence, high-impact issues only" positioning;
  stateless client-side (code goes straight to the LLM provider); per-repo
  `.gito/config.toml` for prompts/criteria/thresholds;
  `collapse_previous_code_review_comments` for push-to-push cleanup.
- **mattzcarey/shippie** (ex code-review-gpt): full agent loop with real
  tools; requires `fetch-depth: 0`; extensible via MCP; PR events or
  `/shippie review` comments; local mode reviews `git diff --cached`.
- **codedog-ai/codedog**: LangChain-based; per-file summaries + review;
  email/webhook reporting.
- Status notes: Sweep AI pivoted away (dormant since Sep 2025); PR-Pilot dead
  (repo 404); most one-file actions are unmaintained — the maintained
  survivors are corporate (Anthropic, Alibaba) or platforms (Kodus).

---

## 13. Cross-cutting patterns

### Recurring failure modes (reported across sources)

1. **Nitpick dominance.** Greptile's self-audit: 19% valuable / 79% nits.
   Prompting "don't nitpick" fails; few-shot makes it worse; LLM self-scoring
   is near-random. The only proven fix is team-feedback memory (embedding
   similarity to past 👍/👎).
2. **False positives → trust collapse.** cubic.dev: small PRs "flooded with
   low-value comments"; their fixes — force explicit reasoning before the
   verdict, split one mega-prompt into specialized micro-agents, cut
   rarely-used tools — reduced FPs 51% and halved median comments/PR.
3. **Wrong line anchors** — endemic in diff-only JSON tools. Mitigations seen:
   number the diff lines in the prompt and validate returned lines against
   commentable hunk lines; deterministic post-hoc positioning/verification
   modules (Alibaba); echo the original source line back with each finding so
   the publisher can re-locate it; reviewdog-style fallback to non-inline
   output when the anchor is outside the diff.
4. **Re-review spam on every push.** Fixes: incremental review keyed to
   last-reviewed commit (state in the sticky comment), marker-based
   update-in-place (Danger), collapsing prior comments (Gito), cross-PR issue
   tracking with auto-resolve (Kodus).
5. **Abandonment** — the single-file action tier is largely unmaintained.

### Consensus best practices

- **Repo context beats diff-only.** Every well-ranked tool reads beyond the
  diff (agentic file reads in a checkout, RAG, or AST/type info); diff-only
  tools cluster at the bottom of independent comparisons.
- **Structured findings with confidence + severity, hard-gated before
  posting** (Anthropic 0–100 cut at 80; Codex P0/P1-only) — plus a dedicated
  validation/reflection pass over each finding (Anthropic plugin, Alibaba
  reflection module, CodeRabbit Verification agent, Ellipsis filter chain).
- **An explicit do-not-flag category list beats "be less nitpicky"** —
  spelled out per category (pre-existing code, linter territory, speculative
  issues, style, docstrings/type hints, unused imports…). Hard-coded category
  kill-lists appear in Anthropic's plugin, claude-code-security-review, and
  Qodo's reflect rubric.
- **Cheap/expensive model split by stage**: cheap summarize/triage before the
  expensive pass (ai-pr-reviewer), mixed-tier parallel subagents (Anthropic),
  weak-model tools (Qodo `model_weak`). Triage that *skips* trivial files
  entirely is the biggest cost lever.
- **Line-number-annotated diffs in the prompt** so the model copies anchors
  instead of computing them (Qodo `__new hunk__`, ai-pr-reviewer), plus
  deterministic anchor validation before posting, plus a fallback destination
  for unanchorable findings (reviewdog).
- **Idempotent posting**: one sticky comment found by a hidden marker,
  updated in place, optionally with a tiny ping comment for notifications;
  hidden HTML state blocks in the comment for cross-run state
  (last-reviewed SHA).
- **Token/step isolation for fork PRs**: read-only prepare → tokenless model →
  write-scoped publish (Codex cookbook three-job split; Anthropic's
  trusted-author gating). `pull_request_target` with secrets on fork code is
  the anti-pattern.
- **Suggestion blocks only for self-contained fixes**, with exact-range
  before/after code so they're committable.
- **Measure outcomes, not output**: BugBot's resolution rate (did the author
  fix it before merge, judged at merge time) and Codex's act-on rate are the
  field's quality metrics; comment count is a vanity/noise metric.
- **Learning over time — three maturity levels**: (1) static NL rules in repo
  files, path-scoped (`.coderabbit.yaml` path_instructions, `BUGBOT.md`,
  `AGENTS.md`, `best_practices.md`); (2) rules inferred from historical human
  review comments (Ellipsis); (3) live feedback loops — learnings from comment
  replies (CodeRabbit), embedding similarity to past 👍/👎 (Greptile).

### Key sources

- Qodo PR-Agent source: `pr_agent/algo/{pr_processing,git_patch_processing}.py`,
  `pr_agent/settings/*.toml`, `docs/docs/core-abilities/*`
- Greptile: make-llms-shut-up + greptile-v3-agentic-code-review blogs
- Cursor: building-bugbot blog · OpenAI: scaling-code-verification
- CodeRabbit: docs/overview/architecture + agentic-code-validation blog;
  fork of the deleted `coderabbitai/ai-pr-reviewer`
- Anthropic: claude-code-action repo, claude-code plugins/code-review,
  claude-code-security-review
- Ellipsis: nsbradford.com/blog/how-we-built-ellipsis + ZenML write-ups
- cubic.dev: learnings-from-building-ai-agents + false-positive-problem blogs
- reviewdog/Danger docs · alibaba/open-code-review · kodustech/kodus-ai
