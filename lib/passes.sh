#!/usr/bin/env bash
# The opencode review engine: two LLM passes (generate -> verify). The final
# comment is built deterministically by render.sh (no third LLM pass). Reads
# only the scratch files prepared by gather.sh — it NEVER needs a GitHub token.
# Writes $SCRATCH/review-verified.md in the strict record format render.sh parses.
# Env: OR_DIR, SCRATCH, SCRATCH_REL, OPENREVIEW_MODEL, [OPENREVIEW_VERIFY_MODEL].
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${OR_DIR:?}"; : "${SCRATCH:?}"; : "${SCRATCH_REL:?}"
[ -f "$SCRATCH/skip-review" ] && { info "skipped (diff unchanged since last review)"; exit 0; }
resolve_model
resolve_cheap_model
resolve_verify_model
prepare_opencode_config "$OR_DIR"
S="$SCRATCH_REL"   # scratch path as the model sees it (relative to OR_DIR)

# Static prompt text lives in versioned files under prompts/ (reviewable,
# diffable independent of this script). Only the dynamic parts — context file
# lists, the incremental note, and anything embedding $S — stay assembled
# here. engine_fingerprint (common.sh) hashes these files too, so an edit
# here invalidates the skip guard exactly like a passes.sh edit.
PROMPTS_DIR="${OPENREVIEW_PROMPTS_DIR:-$OPENREVIEW_ROOT/prompts}"
load_prompt() {
  local f="$PROMPTS_DIR/$1"
  [ -f "$f" ] || die "missing prompt file: $f"
  cat "$f"
}
PREP_PROMPT="$(load_prompt prep.txt)"
GENERATE_PROMPT="$(load_prompt generate.txt)"
VERIFY_PROMPT="$(load_prompt verify.txt)"
FORMAT_SPEC="$(load_prompt format-spec.txt)"

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
$PREP_PROMPT Output ONLY the brief to $S/intent.md. Do not review code, do not post anything." "prep" \
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

# Incremental review (item G): when gather.sh found a still-ancestor previous
# SHA, it wrote an additional focused diff — surface it as extra context
# without replacing the full diff (still needed for surrounding-context reads).
INCREMENTAL_CONTEXT=""
if [ -f "$SCRATCH/incremental-note.md" ] && [ -s "$SCRATCH/pr-incremental.diff" ]; then
  INCREMENTAL_CONTEXT="- $S/incremental-note.md — read this first: it explains how to use the incremental diff below.
- $S/pr-incremental.diff — the incremental diff (changes since the previous review); focus your review here."
fi

# Incremental v2 (TASK-45): previous findings whose code changed since the
# last review (gather.sh's touched split) — ask the model to re-verify each
# rather than silently dropping them. Untouched previous findings are NOT
# sent here; render.sh carries those forward verbatim without a re-check.
PREV_TOUCHED_CONTEXT=""
if [ -s "$SCRATCH/prev-findings-touched.tsv" ]; then
  PREV_TOUCHED_CONTEXT="- $S/prev-findings-touched.tsv — findings from your previous review that are in code that changed since then (schema: sev conf path line anchored title body). Re-verify each against the CURRENT code: still present -> re-emit it as a normal finding (with its current file:line); fixed -> do not emit it. Do not re-emit findings you cannot re-confirm."
fi

# Open-PR cross-context (TASK-30): other open PRs touching the same files,
# when gather.sh found any overlap.
OPEN_PRS_CONTEXT=""
if [ -s "$SCRATCH/open-prs.md" ]; then
  OPEN_PRS_CONTEXT="- $S/open-prs.md — other OPEN PRs touch the same files — consider conflicting or duplicated work, and whether this PR depends on or races them. Mention only when concretely relevant."
fi

# Regression radar (TASK-31): recent bug-fix history on this PR's changed
# files, when gather.sh found any.
REGRESSION_CONTEXT=""
if [ -s "$SCRATCH/regression-context.md" ]; then
  REGRESSION_CONTEXT="- $S/regression-context.md — these files were recently bug-fixed. Verify this PR does not undo or bypass those fixes — regressions of recent fixes are the most important finding class."
fi

# Co-change coupling (TASK-32): historically coupled files this PR did not
# touch, when gather.sh found any.
CO_CHANGE_CONTEXT=""
if [ -s "$SCRATCH/co-change.md" ]; then
  CO_CHANGE_CONTEXT="- $S/co-change.md — historically coupled files were not updated — check whether this PR forgot a required companion change (migration, test, config, docs). Only flag when the omission is plausible from the diff."
fi

# Changed-symbol consumer feed (TASK-41): unchanged sites reading a symbol
# (constant/def/class/shell function) this PR's diff changed, when gather.sh
# found any.
SYMBOL_CONSUMERS_CONTEXT=""
if [ -s "$SCRATCH/symbol-consumers.md" ]; then
  SYMBOL_CONSUMERS_CONTEXT="- $S/symbol-consumers.md — symbol-consumers.md shows UNCHANGED code that reads symbols this PR changed. Check each consumer against the symbol's NEW semantics — a consumer that still assumes the old value, format, or contract is a real finding. Anchor it to the diff line that changed the symbol."
fi

GENERATE_FAILED=0

# --- PASS 1: GENERATE (self-consistency voting, TASK-44) --------------------
# vote-passes=1 (default) is the ONE generate run, writing straight to
# review-candidates.md, byte-identical to the pre-voting pipeline. vote-passes
# N>=2 runs N diversified generate calls to review-candidates-<i>.md (cheap
# diversification: pass 2 reads files in reverse order, pass 3 starts from the
# smallest file) and merges the survivors with vote_merge (common.sh) — group
# by file+line +-5, keep votes>=2 or important/high singletons, and emit
# multi-variant groups as one VARIANT-joined record for the verify pass to
# judge (prompts/verify.txt). Fail-open: a failed run is skipped; if only one
# survives, it is used directly (no merge).
VOTE_PASSES="${OPENREVIEW_VOTE_PASSES:-1}"
case "$VOTE_PASSES" in ''|*[!0-9]*|0) VOTE_PASSES=1 ;; esac

info "pass 1/2 — generate (model: $OR_MODEL${VOTE_PASSES:+, vote-passes: $VOTE_PASSES})"
_t0=$SECONDS
SURVIVORS=""
i=1
while [ "$i" -le "$VOTE_PASSES" ]; do
  if [ "$VOTE_PASSES" -eq 1 ]; then
    CAND_TARGET="review-candidates.md"
    PASS_LABEL="pass1"
    METRICS_PREFIX="PASS1"
    DIVERSIFY=""
  else
    CAND_TARGET="review-candidates-$i.md"
    PASS_LABEL="pass1-$i"
    METRICS_PREFIX="PASS1_$i"
    case "$i" in
      2) DIVERSIFY="

For this diversified pass: read the changed files in REVERSE order of the diff before writing your findings." ;;
      3) DIVERSIFY="

For this diversified pass: start from the SMALLEST changed file and work up to the largest." ;;
      *) DIVERSIFY="" ;;
    esac
  fi
  rm -f "$SCRATCH/$CAND_TARGET"
  if oc_run "$OR_DIR" "$OR_MODEL" "You are a senior engineer reviewing a GitHub pull request. Find real problems INTRODUCED by this PR.

IMPORTANT: your read and write tools are sandboxed to the project directory. ALL scratch files must use relative paths under $S/ (e.g. $S/pr.diff) — NEVER /tmp or any absolute path, those are rejected.

Read the context with your read tool:
- $S/pr-numbered.diff — the diff to review (review ONLY changes in this diff). Line numbers are printed at the start of each line — copy them exactly into loc:, never compute line numbers yourself.
- $S/pr-meta.json — the PR title, body, and changed files.
$INTENT_CONTEXT
$INCREMENTAL_CONTEXT
$PREV_TOUCHED_CONTEXT
$OPEN_PRS_CONTEXT
$REGRESSION_CONTEXT
$CO_CHANGE_CONTEXT
$SYMBOL_CONSUMERS_CONTEXT
- $S/pr-comments.md — existing human + bot discussion, including inline review threads tagged [OPEN]/[RESOLVED]. Defer to humans: do NOT repeat a point already raised in an [OPEN] thread, and NEVER re-raise anything in a [RESOLVED] thread.
- $S/prev-review.md — your previous review of an EARLIER version of this PR (may say '(no previous review)').
- The changed files themselves (open them in the project tree) when you need surrounding context to judge a finding — diff hunks alone hide context and cause false positives.
- CLAUDE.md and anything under conventions/ if present (project root).

$GENERATE_PROMPT$DIVERSIFY

$FORMAT_SPEC

Write the records to $S/$CAND_TARGET with your write tool. Do not post anything. Do not edit or commit tracked files." "$PASS_LABEL"; then
    # vote-passes=1: a successful run is a survivor regardless of file content
    # (matches pre-voting behavior — an empty/missing candidates file is a
    # downstream no-findings case, not a generate failure). vote-passes>=2:
    # require actual content so vote_merge never has to reason about an empty
    # input file from a run that silently wrote nothing.
    if [ "$VOTE_PASSES" -eq 1 ] || [ -s "$SCRATCH/$CAND_TARGET" ]; then
      SURVIVORS="$SURVIVORS $SCRATCH/$CAND_TARGET"
    fi
  else
    warn "pass 1 (generate) run $i/$VOTE_PASSES failed"
  fi
  oc_extract_metrics "$SCRATCH/oc-$PASS_LABEL.jsonl" "$METRICS_PREFIX"
  i=$((i + 1))
done
echo "PASS1_SECS=$((SECONDS - _t0))" >> "$METRICS"

VOTE_GROUPS_KEPT=0
VOTE_MULTIVARIANT_GROUPS=0
VOTE_SPLIT_GROUPS=0
if [ -z "$SURVIVORS" ]; then
  GENERATE_FAILED=1
  warn "pass 1 (generate) failed: all $VOTE_PASSES run(s) failed"
else
  # shellcheck disable=SC2086 # intentional word-splitting of the survivor path list
  set -- $SURVIVORS
  if [ "$#" -eq 1 ]; then
    [ "$1" = "$SCRATCH/review-candidates.md" ] || cp "$1" "$SCRATCH/review-candidates.md"
  else
    # vote_merge (TASK-48) reports its split-group count on stderr as
    # VOTE_SPLIT_GROUPS=<n>; capture it while the real output still lands in
    # review-candidates.md (vote_merge redirects its own stdout internally).
    VOTE_MERGE_STDERR=$(vote_merge "$SCRATCH/review-candidates.md" "$@" 2>&1 1>/dev/null)
    VOTE_GROUPS_KEPT=$(grep -c '^@@FINDING[[:space:]]*$' "$SCRATCH/review-candidates.md" 2>/dev/null || true)
    VOTE_MULTIVARIANT_GROUPS=$(grep -c 'VARIANT 2:' "$SCRATCH/review-candidates.md" 2>/dev/null || true)
    VOTE_SPLIT_GROUPS=$(printf '%s\n' "$VOTE_MERGE_STDERR" | grep -oE 'VOTE_SPLIT_GROUPS=[0-9]+' | cut -d= -f2)
    case "$VOTE_SPLIT_GROUPS" in ''|*[!0-9]*) VOTE_SPLIT_GROUPS=0 ;; esac
  fi
fi
{
  echo "VOTE_PASSES=$VOTE_PASSES"
  echo "VOTE_GROUPS_KEPT=${VOTE_GROUPS_KEPT:-0}"
  echo "VOTE_MULTIVARIANT_GROUPS=${VOTE_MULTIVARIANT_GROUPS:-0}"
  echo "VOTE_SPLIT_GROUPS=${VOTE_SPLIT_GROUPS:-0}"
} >> "$METRICS"

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

$VERIFY_PROMPT

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
