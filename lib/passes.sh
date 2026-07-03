#!/usr/bin/env bash
# The opencode review engine: two LLM passes (generate -> verify). The final
# comment is built deterministically by render.sh (no third LLM pass). Reads
# only the scratch files prepared by gather.sh — it NEVER needs a GitHub token.
# Writes $SCRATCH/review-verified.md in the strict record format render.sh parses.
# Env: OR_DIR, SCRATCH, SCRATCH_REL, OPENREVIEW_MODEL, [OPENREVIEW_VERIFY_MODEL].
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${OR_DIR:?}"; : "${SCRATCH:?}"; : "${SCRATCH_REL:?}"
resolve_model
resolve_cheap_model
resolve_verify_model
prepare_opencode_config "$OR_DIR"
S="$SCRATCH_REL"   # scratch path as the model sees it (relative to OR_DIR)

# Telemetry accumulator (read by metrics.sh -> step summary + action outputs).
# gather.sh created it (DIFF_LINES); append so we don't clobber that.
METRICS="$SCRATCH/metrics.env"
{
  echo "OR_MODEL=$OR_MODEL"
  echo "OR_VERIFY_MODEL=$OR_VERIFY_MODEL"
  echo "OR_CHEAP_MODEL=$OR_CHEAP_MODEL"
  echo "PREP_SECS=0"
  echo "PASS2_SECS=0"
} >> "$METRICS"

# --- PREP (cheap tier): intent compression ----------------------------------
# When a cheap model is configured, distil the requirement context (linked
# issues + PR body + commits) into a short brief so the strong generate pass
# reads ~8 lines instead of the raw issue/commit text. Skipped (and the strong
# pass reads the raw files) when no cheap model is set, preserving prior cost.
# Clear any stale brief first: on a persistent scratch dir (self-hosted runner,
# local dev) a prior run's intent.md must not survive a prep failure and feed
# outdated requirements to the generate pass.
rm -f "$SCRATCH/intent.md"
if [ -n "$OR_CHEAP_MODEL" ]; then
  info "prep — intent compression (model: $OR_CHEAP_MODEL)"
  _tp=$SECONDS
  oc_run "$OR_DIR" "$OR_CHEAP_MODEL" "You are preparing context for a code reviewer. Your read/write tools are sandboxed to the project directory — use relative paths under $S/ only, never /tmp.

Read $S/linked-issues.md (the issue(s) this PR closes, may say '(no linked issues)'), $S/pr-meta.json (PR title + body), and $S/pr-commits.md (commit messages).

Write a SHORT brief (at most ~8 lines) to $S/intent.md capturing:
1. What this PR is supposed to accomplish.
2. Any explicit acceptance criteria or constraints stated in the issue/PR.
3. What a reviewer should check the diff against.
Be strictly factual — do NOT invent requirements. If there is no linked issue, infer intent from the title/body/commits. Output ONLY the brief to $S/intent.md. Do not review code, do not post anything." "prep" \
    || { warn "prep (intent compression) failed — falling back to raw context"; rm -f "$SCRATCH/intent.md"; }
  echo "PREP_SECS=$((SECONDS - _tp))" >> "$METRICS"
  oc_extract_metrics "$SCRATCH/oc-prep.jsonl" "PREP"
fi

# Pass-1 requirement context: the distilled brief when cheap routing produced
# one, otherwise the raw issue/commit files (unchanged behavior).
if [ -n "$OR_CHEAP_MODEL" ] && [ -s "$SCRATCH/intent.md" ]; then
  INTENT_CONTEXT="- $S/intent.md — a distilled brief of the PR's intent (pre-compressed from the linked issues, PR body, and commits). Treat this as THE REQUIREMENT; judge whether the diff does what it describes. You need not re-read the raw issue/commit files."
else
  INTENT_CONTEXT="- $S/linked-issues.md — the issue(s) this PR closes. Treat this as THE REQUIREMENT: judge whether the diff actually does what was asked, and flag gaps against it.
- $S/pr-commits.md — the branch's commit messages (the author's stated intent)."
fi

# The exact output contract shared by both passes and parsed by render.sh.
FORMAT_SPEC="Write findings in this EXACT record format and nothing else outside it. One record per finding:
@@FINDING
sev: important   (use 'important' for a bug introduced by this PR; 'nit' for minor/non-blocking)
loc: path/to/file.ext:123   (a file:line that appears in pr.diff)
conf: high   (high | med | low)
title: one short line
body: one to three sentences on a SINGLE line — the reason grounded in the diff, plus a concrete suggested fix.
Repeat @@FINDING blocks for each finding. If there are NO findings, write no @@FINDING blocks at all.
Then ALWAYS end the file with exactly:
@@PRDESC
rating: good | could-be-improved | poor
reason: one short line explaining the rating (omit this line when rating is good)

Rate the PR description (from pr-meta.json) against what the diff actually does. 'poor' = the PR description is empty, extremely outdated, or contradicts what the diff actually does. 'could-be-improved' = major gaps but acceptable to merge as-is. 'good' = everything else. Do NOT write a replacement description — rating + reason only."

GENERATE_FAILED=0

# --- PASS 1: GENERATE --------------------------------------------------------
info "pass 1/2 — generate (model: $OR_MODEL)"
_t0=$SECONDS
oc_run "$OR_DIR" "$OR_MODEL" "You are a senior engineer reviewing a GitHub pull request. Find real problems INTRODUCED by this PR.

IMPORTANT: your read and write tools are sandboxed to the project directory. ALL scratch files must use relative paths under $S/ (e.g. $S/pr.diff) — NEVER /tmp or any absolute path, those are rejected.

Read the context with your read tool:
- $S/pr-numbered.diff — the diff to review (review ONLY changes in this diff). Line numbers are printed at the start of each line — copy them exactly into loc:, never compute line numbers yourself.
- $S/pr-meta.json — the PR title, body, and changed files.
$INTENT_CONTEXT
- $S/pr-comments.md — existing human + bot discussion, including inline review threads tagged [OPEN]/[RESOLVED]. Defer to humans: do NOT repeat a point already raised in an [OPEN] thread, and NEVER re-raise anything in a [RESOLVED] thread.
- $S/prev-review.md — your previous review of an EARLIER version of this PR (may say '(no previous review)').
- The changed files themselves (open them in the project tree) when you need surrounding context to judge a finding — diff hunks alone hide context and cause false positives.
- CLAUDE.md and anything under conventions/ if present (project root).

Using the previous review: it exists ONLY so you stop repeating yourself. If a problem it raised has since been fixed in the current pr.diff, do NOT mention it — drop it silently. NEVER re-raise a past finding unless you independently confirm it is STILL present in the current diff. Do not treat prev-review.md as a checklist.

Hunt across issue classes: correctness bugs, security, error handling and edge cases, performance, race conditions, test gaps, project-convention violations.

Severity — calibrate to CORRECTNESS, not taste:
- important — a bug introduced by this PR that would break production, leak/lose data, or open a security hole.
- nit — minor, non-blocking (style, naming, small cleanup).
- Pre-existing problems NOT introduced by this PR are OUT OF SCOPE — do not report them.

Rules that cut noise:
- Every finding MUST cite a concrete file:line that appears in pr.diff. If you cannot, do not report it.
- Prefer correctness bugs. Do NOT report formatting preferences or 'missing tests' as important.
- NEVER report any of the following, regardless of severity: pre-existing issues not introduced by this diff; formatting/style preferences; purely speculative problems ('could potentially', 'might in theory') without a concrete failure path; anything a standard linter or compiler would catch; generic security advice not tied to a specific flaw in this diff; suggestions to add docstrings, comments, or type hints; suggestions to remove unused imports; advice to 'verify' or 'ensure' something without evidence it is wrong; claims about symbols defined outside this diff that you have not opened and read. If you are not certain an issue is real, do not flag it.

$FORMAT_SPEC

Write the records to $S/review-candidates.md with your write tool. Do not post anything. Do not edit or commit tracked files." "pass1" \
  || { GENERATE_FAILED=1; warn "pass 1 (generate) failed"; }
echo "PASS1_SECS=$((SECONDS - _t0))" >> "$METRICS"
oc_extract_metrics "$SCRATCH/oc-pass1.jsonl" "PASS1"

# --- GATE: any candidate findings? -------------------------------------------
if grep -qE '^@@FINDING[[:space:]]*$' "$SCRATCH/review-candidates.md" 2>/dev/null; then
  HAS_CANDIDATES=1
else
  HAS_CANDIDATES=0
  # No findings: carry the candidates file (its @@PRDESC) straight to verified.
  cp "$SCRATCH/review-candidates.md" "$SCRATCH/review-verified.md" 2>/dev/null \
    || printf '@@PRDESC\n' > "$SCRATCH/review-verified.md"
fi

# --- PASS 2: VERIFY (only when there are candidates) -------------------------
if [ "$HAS_CANDIDATES" = "1" ]; then
  info "pass 2/2 — verify (model: $OR_VERIFY_MODEL)"
  _t1=$SECONDS
  oc_run "$OR_DIR" "$OR_VERIFY_MODEL" "Verification pass. Do NOT look for new issues — that only adds noise.

IMPORTANT: your read/write tools are sandboxed to the project directory — use relative paths only, never /tmp.
Read $S/pr-numbered.diff and $S/review-candidates.md with your read tool. Open changed files for context when a claim needs it. Line numbers are printed at the start of each line — copy them exactly into loc:, never compute line numbers yourself.

For EACH @@FINDING, KEEP it only if ALL hold:
1. its loc file:line refers to a line actually present in pr.diff,
2. the claim is factually correct about that code (verify it, do not infer from names),
3. you would genuinely raise it in a serious review (not speculative, not pure style).
DROP everything else. Recalibrate severity conservatively — when unsure, 'nit' rather than 'important'.
4. DROP any finding that falls into these categories even if it seems valid: docstring/comment/type-hint suggestions; unused-import removal; 'verify/ensure that…' advice without demonstrated incorrectness; pure style/formatting; findings about code outside pr.diff; findings whose suggested fix does not change behavior.

$FORMAT_SPEC

Write the survivors to $S/review-verified.md with your write tool, preserving the @@PRDESC section from the candidates. If none survive, write no @@FINDING blocks (still keep @@PRDESC). Do not post anything. Do not edit or commit tracked files." "pass2" \
    || { VERIFY_FAILED=1; warn "pass 2 (verify) failed — falling back to unverified candidates"; }
  oc_extract_metrics "$SCRATCH/oc-pass2.jsonl" "PASS2"
  # Fall back to the candidates if verify produced nothing usable OR failed — a
  # crash mid-write can leave a partial review-verified.md that -s alone passes.
  if [ ! -s "$SCRATCH/review-verified.md" ] || [ "${VERIFY_FAILED:-0}" = "1" ]; then
    cp "$SCRATCH/review-candidates.md" "$SCRATCH/review-verified.md" 2>/dev/null || true
  fi
  echo "PASS2_SECS=$((SECONDS - _t1))" >> "$METRICS"
else
  info "pass 2/2 — skipped (no candidates)"
fi

# A hard generate failure must abort so the action never posts a comment built
# from a failed run. The gate above always leaves a non-empty review-verified.md
# (at least the @@PRDESC line), so an emptiness check would NOT catch this —
# fail purely on the generate exit status. Verify failures fall back gracefully.
if [ "$GENERATE_FAILED" = "1" ]; then
  die "review engine failed: generate pass returned non-zero"
fi
