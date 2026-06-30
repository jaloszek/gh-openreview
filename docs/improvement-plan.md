# gh-openreview — Improvement Plan

Status: **draft** · Branch: `refactor/action-only-reviewer` · Author: pawel

This plan has three parts:

1. **Refactor** — collapse the repo to a single thing: a GitHub Action OpenCode PR
   reviewer. Drop the local `gh` extension surface (`review`/`resolve`/`inbox`/
   `assist`/`doctor`).
2. **Improvements** — the findings from the two `ai-news` runs
   ([28447132192](https://github.com/jaloszek/ai-news/actions/runs/28447132192),
   [28446552220](https://github.com/jaloszek/ai-news/actions/runs/28446552220)),
   plus additional proposals.
3. **Competitive research** — how leading automated reviewers are built, and what
   to borrow. *(filled in from the deep-research pass — see bottom.)*

---

## Part 0 — Evidence from the two runs

Same PR (`ai-news#125`), two `synchronize` events 9 minutes apart.

| | Run `28446552220` | Run `28447132192` |
|---|---|---|
| Total | **6m55s** | **2m28s** |
| Pass 1 generate | ~2m24s → 1 nit | ~1m55s → `NO_FINDINGS` |
| Pass 2 verify | ~1m25s | skipped |
| Pass 3 format | **~2m50s** | ~17s |
| Outcome | posted the nit | posted "No blocking issues" |

Three hard facts:

- **Zero cost/telemetry.** No token counts, no cost, no per-pass timing in the logs.
- **Pass 3 (format) is the slowest pass** — 2m50s of LLM time to template one nit
  into markdown. Pure waste; formatting is deterministic.
- **2.8× runtime variance on the same PR**, and every push fires a full 3-pass
  review (cost scales linearly with push count).

---

## Part 1 — Refactor: action-only

### 1.1 Goal

The repo becomes exactly one product: **a reusable GitHub Action that reviews a
PR with OpenCode**. No `gh` extension, no interactive local subcommands. The
review engine and the PR-context gathering become clean, separately-testable
scripts that the action wires together.

### 1.2 Current surface (what exists today)

| File | Role | Keep? |
|---|---|---|
| `gh-openreview` (entrypoint) | `gh` extension dispatcher | **delete** |
| `lib/review.sh` | local `review` subcommand | **delete** (action replaces it) |
| `lib/resolve.sh` | reconcile your PR's threads | **delete** (separate concern) |
| `lib/inbox.sh` | list PRs awaiting review | **delete** (separate concern) |
| `lib/assist.sh` | human-voice inline review | **delete** (separate concern) |
| `lib/doctor.sh` | env check | **delete** (CI doesn't need it) |
| `lib/common.sh` | shared helpers | **slim** — drop `parse_common_flags`, `resolve_pr_target`, `confirm`, local scratch trap; keep logging, `oc_run`, `resolve_model`, config resolution |
| `lib/gather.sh` | pre-fetch PR context | **keep + expand** (see 2.x) |
| `lib/passes.sh` | 3-pass engine | **keep + rework** (see 2.x) |
| `lib/post.sh` | deterministic comment post | **keep + expand** (inline comments) |
| `lib/resolve.sh`/`inbox`/`assist`/`doctor` references in README/CHANGELOG/examples | docs | **rewrite** |
| `action/action.yml` | the Action | **keep — becomes the only entrypoint** |

> The deleted local commands (`resolve`/`assist`/`inbox`) are a genuinely
> separate product (a human's review assistant). If still wanted, they belong in
> their own repo/extension. They are **out of scope** here.

### 1.3 Target layout

```
action/action.yml          # the only entrypoint
lib/
  common.sh                # logging, oc_run, model + config resolution (slimmed)
  gather.sh                # collect ALL PR context (diff, meta, comments, threads, issues)
  passes.sh                # generate -> verify (LLM); format is now deterministic
  render.sh                # NEW: deterministic markdown renderer (replaces format pass)
  post.sh                  # post summary + inline comments, dedup, metrics
  metrics.sh               # NEW: token/cost/timing capture -> step summary + outputs
opencode.json              # bundled free-model config
README.md                  # action-only docs
examples/                  # action usage examples (keep)
docs/improvement-plan.md   # this file
```

### 1.4 Refactor steps

1. Delete `gh-openreview`, `lib/review.sh`, `lib/resolve.sh`, `lib/inbox.sh`,
   `lib/assist.sh`, `lib/doctor.sh`.
2. Slim `lib/common.sh` to what the action path uses.
3. Rewrite `README.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, `examples/` to be
   action-only (remove the "gh extension" framing and the command table).
4. Keep the security model intact (token-scoped steps; the LLM pass never sees a
   GitHub token — see `SECURITY.md`).

---

## Part 2 — Improvements

Ordered by ROI / obviousness. Each has a goal tag:
💸 cost · 🔮 predictability · 🛡️ robustness · 🎯 quality · 📊 observability.

### A. Deterministic formatting — replace pass 3 with `render.sh` 💸🔮🎯
**The single highest-value change.** Pass 2 already emits a structured block
format (`SEVERITY | file:line | confidence` + title + reason). Rendering it to
the final comment is pure templating — do it in bash/awk, not an LLM call.

- Make pass 2 emit a strict, parseable format (or JSON) instead of prose.
- `render.sh` reads it and emits the final markdown (marker header, tally,
  table, collapsible details, capped nits, PR-description suggestion).
- **Removes ~⅓ of every run's tokens, the slowest pass, and the
  "model ignored the template" failure mode.** Output shape becomes 100%
  deterministic.

### B. Per-pass timeout + retry 🛡️
`oc_run` has no timeout — a hung model burns the full 30-min job budget. Wrap
each `opencode run` in `timeout <N>` and retry once on non-zero/empty output.
(Ironic: the PR under review *added* a `timeout 150` preflight; the reviewer
itself lacks one.)

### C. Don't post on hard failure 🛡️
`continue-on-error: true` + `warn "pass N returned non-zero"` currently swallows
failures, so a failed pass 1 can still post an empty/garbage comment. Distinguish
"clean / no findings" from "engine failed"; on failure, skip posting (or post an
explicit "review failed, will retry" note) and surface a non-success status.

### D. Cost / token / timing telemetry 📊🔮
Capture, per pass: wall-clock, tokens in/out, cost (opencode can print usage).
Emit to:
- `$GITHUB_STEP_SUMMARY` (a table the maintainer sees on every run),
- `::notice::` lines,
- **action `outputs`** (`findings-count`, `important-count`, `tokens`, `cost`,
  `duration`) so callers can gate/alert.

You can't make cost "predictable" without measuring it first — this unblocks
every other cost lever.

### E. Model tiering 💸
Pass 1 (hunting) needs the strong model; pass 2 (verify) can run on the cheap/
free model; pass 3 (format) needs none (see A). Add `model` (strong) and
`verify-model` (cheap, defaults to the free model) inputs.

### F. Diff capping & path filtering 💸🔮
`gather.sh` runs `gh pr diff` unbounded — lockfiles / generated / vendored blobs
silently inflate pass-1 input. Add:
- pathspec excludes (`*.lock`, `*.min.*`, `dist/`, `vendor/`, `*.snap`,
  generated/`pb.go`, etc.), configurable via input,
- a max line/byte budget with truncation + a `::notice::` (and a step-summary
  note) so truncation is never silent.

### G. Incremental review on `synchronize` 💸🔮
Avoid re-reviewing the whole PR on every push. Options (pick per cost target):
- **Incremental diff** since the last reviewed commit (store last-reviewed SHA in
  the marker comment as an HTML comment; diff `LAST..HEAD`), feeding the prior
  full review as context.
- **Skip when unchanged**: if HEAD's diff == the diff at last review, skip.
- **Debounce**: drop `synchronize` from the default trigger set and rely on
  `ready_for_review` + label + `@openreview`; document the trade-off.

### H. Reviewer reads changed files, not just diff hunks 🎯
`OR_DIR` is the repo root and the tools are sandboxed there, but the prompt only
points the model at `pr.diff`. Diff-only review is the #1 false-positive source
(no surrounding context). Instruct the model to open changed files when unsure.
Synergy with F: you can trim the diff harder once the model can read full files.

### I. Richer PR context in `gather.sh` (the "important input" the user asked for) 🎯
Today gather collects: `pr.diff`, `pr-meta.json` (title/body/files), and the last
matching bot review. Expand to a real context bundle:
- **All prior review comments & review threads** (humans + bots), with
  resolved/unresolved state and the line they anchor to → so the reviewer
  defers to humans, never repeats a raised point, and silences fixed ones.
- **Linked issues** referenced in the PR body/title (`Closes #N`) → intent.
- **Commit messages** on the branch → author's stated intent per change.
- **CI / check status** → don't re-report what a linter already flagged.
- **Existing review verdicts** (approved/changes-requested) → tone/scope.

This is a standalone, token-free script (uses the scoped `GH_TOKEN`), and its
output is a first-class input to pass 1.

### J. Inline review comments anchored to diff lines 🎯
Today everything is one summary comment. Leading tools post findings as inline
review comments on the exact changed line (GitHub Reviews API: `line`/`side`/
`start_line`). Add an opt-in `comment-style: inline|summary|both`:
- inline comments for 🔴 Important findings (anchored, threaded, resolvable),
- a summary comment for the tally + nits + PR-description suggestion,
- dedup against prior bot inline comments (don't repeat across runs).

### K. Confidence gating & severity calibration 🎯🔮
Pass 1 already tags confidence (high/med/low). Make it actionable:
- drop `low`-confidence findings unless `--strict`,
- only `high`-confidence → 🔴 Important; `med` → 🟡 Nit by default,
- cap total rendered findings (already done for nits; extend to a global cap).

### L. Prompt-caching for static context 💸
The system/instruction blocks and CLAUDE.md/conventions are identical across the
3 passes and across pushes. Use opencode/provider prompt caching where supported
so repeated context isn't re-billed at full rate.

---

## Part 3 — Implementation order (most-obvious-first)

1. **Refactor to action-only** (Part 1) — clears the surface, no behavior risk.
2. **A. Deterministic `render.sh`** — biggest cost+predictability+quality win.
3. **B + C. Timeout/retry + don't-post-on-failure** — robustness, low risk.
4. **D. Telemetry → step summary + outputs** — makes everything measurable.
5. **F. Diff capping / path filtering** — cost, low risk.
6. **E. Model tiering** — cost.
7. **I. Richer gather context** — quality (the user-requested input expansion).
8. **G. Incremental review** — cost/predictability (needs SHA bookkeeping).
9. **H + K. Read-files + confidence gating** — quality.
10. **J. Inline comments** — quality (larger change; opt-in).
11. **L. Prompt caching** — cost (provider-dependent; verify support).

Each lands as its own commit on `refactor/action-only-reviewer`.

---

## Part 4 — Competitive landscape (deep research)

_Pending — being filled from the research pass. Will cover CodeRabbit, Greptile,
Qodo PR-Agent, Sourcery, Cursor BugBot, Copilot review, Claude Code Action, etc.:
context-gathering (RAG/AST vs diff), noise control, incremental review, inline
anchoring, cost/determinism patterns — and which patterns to copy here._
