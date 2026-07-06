#!/usr/bin/env bash
# Telemetry: read $SCRATCH/metrics.env (accumulated by gather/passes/render) and
# emit a run summary to $GITHUB_STEP_SUMMARY and key=value lines to $GITHUB_OUTPUT
# (mapped to the action's outputs). Best-effort — never fails the job.
# Env: SCRATCH, [GITHUB_STEP_SUMMARY], [GITHUB_OUTPUT].
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${SCRATCH:?}"
[ -f "$SCRATCH/skip-review" ] && { info "skipped (diff unchanged since last review)"; exit 0; }
METRICS="$SCRATCH/metrics.env"

# Defaults so a partial run still reports something sane.
DIFF_LINES=0 PREP_SECS=0 PASS1_SECS=0 PASS2_SECS=0
OR_MODEL="" OR_VERIFY_MODEL="" OR_CHEAP_MODEL=""
OR_FINDINGS_IMPORTANT=0 OR_FINDINGS_NIT=0 OR_FINDINGS_TOTAL=0 FINDINGS_SUPPRESSED=0
FINDINGS_CARRIED=0 FINDINGS_RESOLVED=0
PREP_COST="" PREP_TOKENS_IN="" PREP_TOKENS_OUT="" PREP_CACHE_READ=""
PASS1_COST="" PASS1_TOKENS_IN="" PASS1_TOKENS_OUT="" PASS1_CACHE_READ=""
PASS2_COST="" PASS2_TOKENS_IN="" PASS2_TOKENS_OUT="" PASS2_CACHE_READ=""
# shellcheck disable=SC1090
[ -f "$METRICS" ] && . "$METRICS"

total_secs=$(( PREP_SECS + PASS1_SECS + PASS2_SECS ))

# Sum whatever cost figures we have (missing ones just contribute 0); awk
# avoids a bc/bash-float dependency for the fractional-USD addition.
total_cost=$(awk -v a="${PREP_COST:-0}" -v b="${PASS1_COST:-0}" -v c="${PASS2_COST:-0}" \
  'BEGIN { printf "%.4f", (a==""?0:a) + (b==""?0:b) + (c==""?0:c) }')

# Action outputs (consumed via steps.<id>.outputs.* in action.yml).
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "findings-total=$OR_FINDINGS_TOTAL"
    echo "findings-important=$OR_FINDINGS_IMPORTANT"
    echo "findings-nit=$OR_FINDINGS_NIT"
    echo "diff-lines=$DIFF_LINES"
    echo "duration-seconds=$total_secs"
    echo "total-cost=$total_cost"
  } >> "$GITHUB_OUTPUT"
fi

# Human-readable run summary.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### 🤖 OpenCode Review — run metrics"
    echo ""
    echo "| Metric | Value |"
    echo "|---|---|"
    echo "| Findings | **$OR_FINDINGS_IMPORTANT** important · $OR_FINDINGS_NIT nits |"
    if [ "$FINDINGS_SUPPRESSED" -gt 0 ]; then
      echo "| Suppressed by confidence gate | $FINDINGS_SUPPRESSED |"
    fi
    if [ "$FINDINGS_CARRIED" -gt 0 ]; then
      echo "| Carried forward from last review | $FINDINGS_CARRIED |"
    fi
    if [ "$FINDINGS_RESOLVED" -gt 0 ]; then
      echo "| Resolved since last review | $FINDINGS_RESOLVED |"
    fi
    echo "| Diff size | $DIFF_LINES lines |"
    if [ -n "$OR_CHEAP_MODEL" ]; then
      echo "| Prep (intent) | ${PREP_SECS}s ($OR_CHEAP_MODEL) · \$${PREP_COST:-?} · ${PREP_TOKENS_IN:-?}in/${PREP_TOKENS_OUT:-?}out tok (${PREP_CACHE_READ:-0} cached) |"
    fi
    echo "| Generate pass | ${PASS1_SECS}s ($OR_MODEL) · \$${PASS1_COST:-?} · ${PASS1_TOKENS_IN:-?}in/${PASS1_TOKENS_OUT:-?}out tok (${PASS1_CACHE_READ:-0} cached) |"
    echo "| Verify pass | ${PASS2_SECS}s ($OR_VERIFY_MODEL) · \$${PASS2_COST:-?} · ${PASS2_TOKENS_IN:-?}in/${PASS2_TOKENS_OUT:-?}out tok (${PASS2_CACHE_READ:-0} cached) |"
    echo "| Total LLM time | ${total_secs}s |"
    echo "| Total cost | \$$total_cost |"
  } >> "$GITHUB_STEP_SUMMARY"
fi

info "metrics: ${OR_FINDINGS_IMPORTANT} important, ${OR_FINDINGS_NIT} nits, ${total_secs}s LLM, ${DIFF_LINES} diff lines"
