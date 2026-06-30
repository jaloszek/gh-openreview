#!/usr/bin/env bash
# Shared helpers for the OpenCode PR-review action. Sourced, not executed.
# Provides: logging, model + opencode-config resolution, and opencode
# invocation. No GitHub token is required here — the token-scoped steps
# (gather/post) own that; the model passes never see it.

# Self-resolve install paths so lib scripts work regardless of how they're
# launched (the composite action invokes them directly by path).
OPENREVIEW_LIB="${OPENREVIEW_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
OPENREVIEW_ROOT="${OPENREVIEW_ROOT:-$(cd "$OPENREVIEW_LIB/.." && pwd)}"
export OPENREVIEW_LIB OPENREVIEW_ROOT

# --- logging (everything to stderr; stdout is reserved for command output) ----
if [ -t 2 ]; then
  _c_red=$'\033[31m'; _c_yel=$'\033[33m'; _c_grn=$'\033[32m'; _c_dim=$'\033[2m'; _c_off=$'\033[0m'
else
  _c_red=''; _c_yel=''; _c_grn=''; _c_dim=''; _c_off=''
fi
log()  { printf '%s\n' "$*" >&2; }
info() { printf '%s%s%s\n' "$_c_dim" "$*" "$_c_off" >&2; }
warn() { printf '%s! %s%s\n' "$_c_yel" "$*" "$_c_off" >&2; }
ok()   { printf '%s✓ %s%s\n' "$_c_grn" "$*" "$_c_off" >&2; }
die()  { printf '%serror:%s %s\n' "$_c_red" "$_c_off" "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# --- model resolution --------------------------------------------------------
# Precedence: OPENREVIEW_MODEL > OC_MODEL > a pre-exported OR_MODEL > bundled
# free model. The action feeds the `model` input through OPENREVIEW_MODEL.
resolve_model() {
  OR_MODEL="${OPENREVIEW_MODEL:-${OC_MODEL:-${OR_MODEL:-opencode/deepseek-v4-flash-free}}}"
  export OR_MODEL
}

# Verify-pass model: cheaper tier for the verification pass. Falls back to the
# main model, then to the bundled free model if neither is set.
resolve_verify_model() {
  OR_VERIFY_MODEL="${OPENREVIEW_VERIFY_MODEL:-${OR_MODEL:-}}"
  [ -n "$OR_VERIFY_MODEL" ] || OR_VERIFY_MODEL="opencode/deepseek-v4-flash-free"
  export OR_VERIFY_MODEL
}

# --- opencode config precedence ----------------------------------------------
# Respect a user's config; only fall back to the bundled one when none exists.
#   OPENCODE_CONFIG env > project ./opencode.json(c) > ~/.config/opencode > bundled
prepare_opencode_config() {
  local dir="${1:-$PWD}"
  if [ -n "${OPENCODE_CONFIG:-}" ]; then return; fi
  if [ -f "$dir/opencode.json" ] || [ -f "$dir/opencode.jsonc" ]; then return; fi
  local g
  for g in "$HOME/.config/opencode/opencode.json" "$HOME/.config/opencode/opencode.jsonc"; do
    [ -f "$g" ] && return
  done
  export OPENCODE_CONFIG="$OPENREVIEW_ROOT/opencode.json"
}

# --- opencode invocation -----------------------------------------------------
# oc_run <dir> <model> <prompt>: run opencode in <dir> with a per-pass timeout
# and one retry. opencode's chatter goes to stderr so command stdout stays
# clean; the model communicates results by writing files (the prompts say so).
# Env: OPENREVIEW_PASS_TIMEOUT (seconds, default 600), OPENREVIEW_AUTH_CMD.
oc_run() {
  local dir="$1" model="$2" prompt="$3"
  local to="${OPENREVIEW_PASS_TIMEOUT:-600}"
  if [ -n "${OPENREVIEW_AUTH_CMD:-}" ]; then
    info "running auth-cmd…"; eval "$OPENREVIEW_AUTH_CMD" 1>&2 || warn "auth-cmd exited non-zero"
  fi
  local attempt rc
  for attempt in 1 2; do
    # Capture the real exit status: `|| rc=$?` both suppresses set -e and grabs
    # the failure code. (A bare `if (cmd); then…; fi` leaves $?=0 on a false
    # condition, so reading $? after the block would always see success.)
    rc=0
    ( cd "$dir" && timeout "$to" opencode run -m "$model" "$prompt" ) 1>&2 || rc=$?
    [ "$rc" -eq 0 ] && return 0
    if [ "$rc" -eq 124 ]; then
      warn "opencode timed out after ${to}s (attempt $attempt/2)"
    else
      warn "opencode exited $rc (attempt $attempt/2)"
    fi
  done
  return "$rc"
}
