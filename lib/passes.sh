#!/usr/bin/env bash
# The 3-pass opencode review engine (generate -> verify -> format), ported from
# the proven daily-pipeline workflow. Reads only the scratch files prepared by
# gather.sh — it NEVER needs a GitHub token. Writes $SCRATCH/opencode-review.md.
# Env: OR_DIR, SCRATCH, SCRATCH_REL, OR_MODEL, MARKER.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${OR_DIR:?}"; : "${SCRATCH:?}"; : "${SCRATCH_REL:?}"
resolve_model
prepare_opencode_config "$OR_DIR"
MARKER="${MARKER:-## 🤖 OpenCode Review}"
S="$SCRATCH_REL"   # scratch path as the model sees it (relative to OR_DIR)

# --- PASS 1: GENERATE --------------------------------------------------------
info "pass 1/3 — generate (model: $OR_MODEL)"
oc_run "$OR_DIR" "You are a senior engineer reviewing a GitHub pull request. Find real problems INTRODUCED by this PR.

IMPORTANT: your read and write tools are sandboxed to the project directory. ALL scratch files must use relative paths under $S/ (e.g. $S/pr.diff) — NEVER /tmp or any absolute path, those are rejected.

Read the context with your read tool:
- $S/pr.diff — the diff to review (review ONLY changes in this diff).
- $S/pr-meta.json — the PR title, body, and changed files.
- $S/prev-review.md — your previous review of an EARLIER version of this PR (may say '(no previous review)').
- CLAUDE.md and anything under conventions/ if present (project root).

Using the previous review: it exists ONLY so you stop repeating yourself. If a problem it raised has since been fixed in the current pr.diff, do NOT mention it — drop it silently, with no acknowledgement. NEVER re-raise a past finding unless you independently confirm it is STILL present in the current diff. Do not treat prev-review.md as a checklist to reproduce.

Hunt across issue classes: correctness bugs, security, error handling and edge cases, performance, race conditions, test gaps, project-convention violations.

Severity — calibrate to CORRECTNESS, not taste:
- 🔴 Important — a bug introduced by this PR that would break production, leak/lose data, or open a security hole. Fix before merge.
- 🟡 Nit — minor, non-blocking (style, naming, small cleanup).
- 🟣 Pre-existing — NOT introduced by this PR. Do NOT report these; they are out of scope. Use this only to keep yourself from mis-flagging old code as Important.

Rules that cut noise:
- Every finding MUST cite a concrete file:line that appears in pr.diff. If you cannot, do not report it.
- Prefer correctness bugs. Do NOT report formatting preferences or 'missing tests' as Important.
- Report only 🔴 Important and 🟡 Nit findings (never 🟣 Pre-existing).
- Tag each finding with a confidence: high, med, or low.

Write candidates to $S/review-candidates.md with your write tool, one finding per block:
SEVERITY | file:line | confidence
short title
1-3 sentence reason grounded in the diff.

If you find NO real issues, the file's first line must be exactly the single token NO_FINDINGS on its own line (and nothing else on that line).
Then ALWAYS append a section headed '### PR description suggestion' with a concise improved title and body.
Do not post anything. Do not edit or commit tracked files." || warn "pass 1 returned non-zero"

# --- GATE: any candidates? ---------------------------------------------------
if [ -s "$SCRATCH/review-candidates.md" ] && ! grep -qxF 'NO_FINDINGS' "$SCRATCH/review-candidates.md"; then
  HAS_CANDIDATES=1
else
  HAS_CANDIDATES=0
  cp "$SCRATCH/review-candidates.md" "$SCRATCH/review-verified.md" 2>/dev/null \
    || printf 'NO_FINDINGS\n' > "$SCRATCH/review-verified.md"
fi

# --- PASS 2: VERIFY (only when there are candidates) -------------------------
if [ "$HAS_CANDIDATES" = "1" ]; then
  info "pass 2/3 — verify"
  oc_run "$OR_DIR" "Verification pass. Do NOT look for new issues — that only adds noise.

IMPORTANT: your read/write tools are sandboxed to the project directory — use relative paths only, never /tmp.
Read the files $S/pr.diff and $S/review-candidates.md with your read tool.

For EACH candidate, KEEP it only if ALL hold:
1. its file:line refers to a line actually present in pr.diff,
2. the claim is factually correct about that code (verify it, do not infer from names),
3. you would genuinely raise it in a serious review (not speculative, not pure style).
DROP everything else. Recalibrate severity conservatively — when unsure, 🟡 Nit rather than 🔴 Important.

Write the survivors to $S/review-verified.md with your write tool, same per-finding block format, and keep the '### PR description suggestion' section.
If none survive, write exactly the single token NO_FINDINGS (still keep the PR description suggestion section below it).
Do not post anything. Do not edit or commit tracked files." || warn "pass 2 returned non-zero"
else
  info "pass 2/3 — skipped (no candidates)"
fi

# --- PASS 3: FORMAT ----------------------------------------------------------
info "pass 3/3 — format"
oc_run "$OR_DIR" "Formatting pass. Read $S/review-verified.md with your read tool, then render the FINAL pull-request comment to $S/opencode-review.md with your write tool. Output EXACTLY this structure and nothing outside it.

The FIRST line must be exactly:
$MARKER

Keep the output MINIMAL. Selection policy for what to render:
- 🔴 Important: include ALL of them.
- 🟡 Nit: include at most the 3 MOST USEFUL (highest-confidence and most actionable first); if more remain, drop them and add a single trailing table row '… +N more nits'.
- 🟣 Pre-existing: never render — drop entirely.

Next, a one-line bold tally of the RENDERED findings, e.g. **2 important · 3 nits** (count only what you render; do not count dropped/pre-existing). If the input is NO_FINDINGS or nothing survives the policy, make this line instead: ✅ No blocking issues found in this diff. — and skip the table and finding sections, going straight to the PR description suggestion.

Then, only when there are findings, a summary table (Important first, then Nits ordered most-useful-first):
| # | Severity | Finding | Location |
|---|----------|---------|----------|
Wrap each location as file:line in backticks. Render at most 3 nit rows; if there are more nits, add a final row reading '… +N more nits'.

Then one section per table row:
### N. <title>
<one-line summary>
<details><summary>Details</summary>

<explanation plus a concrete suggested fix>
</details>

ALWAYS finish with the PR description suggestion, collapsed:
<details><summary>📝 Suggested PR description</summary>

<the suggested title and body>
</details>

Keep code identifiers and paths in backticks. Do not add any text outside this structure. Do not edit or commit tracked files." || warn "pass 3 returned non-zero"

if [ -s "$SCRATCH/opencode-review.md" ]; then
  ok "review rendered ($(wc -l < "$SCRATCH/opencode-review.md" | tr -d ' ') lines)"
else
  warn "format pass produced no output"
fi
