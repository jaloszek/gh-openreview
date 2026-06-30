#!/usr/bin/env bash
# Telemetry: read $SCRATCH/metrics.env (accumulated by gather/passes/render) and
# emit a run summary to $GITHUB_STEP_SUMMARY and key=value lines to $GITHUB_OUTPUT
# (mapped to the action's outputs). Best-effort — never fails the job.
# Env: SCRATCH, [GITHUB_STEP_SUMMARY], [GITHUB_OUTPUT].
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${SCRATCH:?}"
METRICS="$SCRATCH/metrics.env"

# Defaults so a partial run still reports something sane.
DIFF_LINES=0 PASS1_SECS=0 PASS2_SECS=0
OR_MODEL="" OR_VERIFY_MODEL=""
OR_FINDINGS_IMPORTANT=0 OR_FINDINGS_NIT=0 OR_FINDINGS_TOTAL=0
# shellcheck disable=SC1090
[ -f "$METRICS" ] && . "$METRICS"

total_secs=$(( PASS1_SECS + PASS2_SECS ))

# Action outputs (consumed via steps.<id>.outputs.* in action.yml).
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "findings-total=$OR_FINDINGS_TOTAL"
    echo "findings-important=$OR_FINDINGS_IMPORTANT"
    echo "findings-nit=$OR_FINDINGS_NIT"
    echo "diff-lines=$DIFF_LINES"
    echo "duration-seconds=$total_secs"
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
    echo "| Diff size | $DIFF_LINES lines |"
    echo "| Generate pass | ${PASS1_SECS}s ($OR_MODEL) |"
    echo "| Verify pass | ${PASS2_SECS}s ($OR_VERIFY_MODEL) |"
    echo "| Total LLM time | ${total_secs}s |"
  } >> "$GITHUB_STEP_SUMMARY"
fi

info "metrics: ${OR_FINDINGS_IMPORTANT} important, ${OR_FINDINGS_NIT} nits, ${total_secs}s LLM, ${DIFF_LINES} diff lines"
