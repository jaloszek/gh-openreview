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

# --- ingress sanitization -----------------------------------------------------
# sanitize_text <file>: strip invisible-Unicode smuggling vectors in place —
# tag block (U+E0000-E007F), zero-width (U+200B-200D, U+FEFF), bidi controls
# (U+202A-202E, Trojan Source; U+2066-2069), variation selectors
# (U+FE00-FE0F, U+E0100-E01EF). Detects on codepoints, not rendered glyphs.
# Never silent: a non-zero strip count warns + emits a `::notice::`. Requires
# perl (present on ubuntu runners and macOS); missing perl warns and skips
# rather than failing the run.
sanitize_text() {
  local f="$1" count cf
  [ -f "$f" ] || return 0
  if ! command -v perl >/dev/null 2>&1; then
    warn "perl not found; skipping invisible-Unicode sanitization for $f"
    return 0
  fi
  cf=$(mktemp)
  perl -i -CSD -pe '
    $c += s/[\x{E0000}-\x{E007F}\x{200B}-\x{200D}\x{FEFF}\x{202A}-\x{202E}\x{2066}-\x{2069}\x{FE00}-\x{FE0F}\x{E0100}-\x{E01EF}]//g;
    END { print STDERR $c }
  ' "$f" 2>"$cf"
  count=$(cat "$cf" 2>/dev/null)
  rm -f "$cf"
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  if [ "$count" -gt 0 ]; then
    warn "sanitize: stripped $count invisible/control character(s) from $f"
    echo "::notice::openreview stripped $count invisible Unicode character(s) from $(basename "$f")"
  fi
}

# --- model resolution --------------------------------------------------------
# Precedence: OPENREVIEW_MODEL > OC_MODEL > a pre-exported OR_MODEL > bundled
# free model. The action feeds the `model` input through OPENREVIEW_MODEL.
resolve_model() {
  OR_MODEL="${OPENREVIEW_MODEL:-${OC_MODEL:-${OR_MODEL:-opencode/deepseek-v4-flash-free}}}"
  export OR_MODEL
}

# Cheap tier: a small/fast/free model the engine routes non-analysis prep work
# to (intent compression, verification) so the strong model only does the core
# review. Empty (the default) disables cheap routing entirely.
resolve_cheap_model() {
  OR_CHEAP_MODEL="${OPENREVIEW_CHEAP_MODEL:-}"
  export OR_CHEAP_MODEL
}

# Verify-pass model. Precedence: an explicit verify-model > the cheap tier >
# the main model > the bundled free model. So setting cheap-model alone moves
# verification onto the cheap tier automatically.
resolve_verify_model() {
  OR_VERIFY_MODEL="${OPENREVIEW_VERIFY_MODEL:-${OR_CHEAP_MODEL:-${OR_MODEL:-}}}"
  [ -n "$OR_VERIFY_MODEL" ] || OR_VERIFY_MODEL="opencode/deepseek-v4-flash-free"
  export OR_VERIFY_MODEL
}

# --- opencode config precedence ----------------------------------------------
# Respect a user's config; only fall back to the bundled one when none exists.
#   OPENCODE_CONFIG env > project ./opencode.json(c) > ~/.config/opencode > bundled
# Warn (log + ::notice::) that config resolution picked <path> instead of the
# bundled hardened config, and best-effort flag a missing bash deny/false.
_warn_config_replacement() {
  local path="$1"
  local msg="using $path instead of the bundled hardened config — ensure it denies bash/webfetch/websearch and sets external_directory: deny (see SECURITY.md)"
  warn "$msg"
  echo "::notice::$msg"
  if [ -f "$path" ] && command -v grep >/dev/null 2>&1; then
    if grep -q '"bash"' "$path" 2>/dev/null; then
      if ! grep -E '"bash"[[:space:]]*:[[:space:]]*(false|"deny")' "$path" >/dev/null 2>&1; then
        warn "$path mentions \"bash\" but no deny/false setting for it was detected — verify it does not grant bash access"
      fi
    else
      warn "$path has no detectable bash deny/false setting — verify it does not grant bash access"
    fi
  fi
}

prepare_opencode_config() {
  local dir="${1:-$PWD}"
  if [ -n "${OPENCODE_CONFIG:-}" ]; then
    _warn_config_replacement "$OPENCODE_CONFIG"
    return
  fi
  if [ -f "$dir/opencode.json" ]; then
    _warn_config_replacement "$dir/opencode.json"
    return
  fi
  if [ -f "$dir/opencode.jsonc" ]; then
    _warn_config_replacement "$dir/opencode.jsonc"
    return
  fi
  local g
  for g in "$HOME/.config/opencode/opencode.json" "$HOME/.config/opencode/opencode.jsonc"; do
    if [ -f "$g" ]; then
      _warn_config_replacement "$g"
      return
    fi
  done
  export OPENCODE_CONFIG="$OPENREVIEW_ROOT/opencode.json"
}

# --- opencode invocation -----------------------------------------------------
# oc_run <dir> <model> <prompt> [pass]: run opencode in <dir> with a per-pass
# timeout and one retry. Always runs with --format json so per-pass cost/token
# telemetry can be extracted (see oc_extract_metrics below); the JSONL event
# stream is captured to $SCRATCH/oc-<pass>.jsonl (or discarded when [pass] is
# omitted or SCRATCH is unset) so it never pollutes command stdout. opencode's
# human-readable chatter still goes to stderr; the model communicates results
# by writing files (the prompts say so).
# Env: OPENREVIEW_PASS_TIMEOUT (seconds, default 600), OPENREVIEW_AUTH_CMD.
oc_run() {
  local dir="$1" model="$2" prompt="$3" pass="${4:-}"
  local to="${OPENREVIEW_PASS_TIMEOUT:-600}"
  local jsonl="/dev/null"
  if [ -n "$pass" ] && [ -n "${SCRATCH:-}" ]; then
    jsonl="$SCRATCH/oc-$pass.jsonl"
  fi
  if [ -n "${OPENREVIEW_AUTH_CMD:-}" ]; then
    info "running auth-cmd…"; eval "$OPENREVIEW_AUTH_CMD" 1>&2 || warn "auth-cmd exited non-zero"
  fi
  local attempt rc
  for attempt in 1 2; do
    # Capture the real exit status: `|| rc=$?` both suppresses set -e and grabs
    # the failure code. (A bare `if (cmd); then…; fi` leaves $?=0 on a false
    # condition, so reading $? after the block would always see success.)
    # `timeout` is optional — absent on stock macOS and some runner images; run
    # without it there rather than failing every pass. stdout (the JSON event
    # stream) is redirected to $jsonl, not inherited, so it stays out of this
    # function's own stdout; stderr passes through unchanged.
    rc=0
    if command -v timeout >/dev/null 2>&1; then
      ( cd "$dir" && timeout "$to" opencode run --format json -m "$model" "$prompt" ) >"$jsonl" || rc=$?
    else
      ( cd "$dir" && opencode run --format json -m "$model" "$prompt" ) >"$jsonl" || rc=$?
    fi
    [ "$rc" -eq 0 ] && return 0
    if [ "$rc" -eq 124 ]; then
      warn "opencode timed out after ${to}s (attempt $attempt/2)"
    else
      warn "opencode exited $rc (attempt $attempt/2)"
    fi
  done
  return "$rc"
}

# --- per-pass cost/token telemetry --------------------------------------------
# oc_extract_metrics <jsonl> <prefix>: parse the LAST step_finish event out of
# an opencode --format json event stream (one JSON object per line) and append
# <prefix>_COST, <prefix>_TOKENS_IN, <prefix>_TOKENS_OUT, <prefix>_CACHE_READ to
# $SCRATCH/metrics.env. Tolerant regex extraction, not a JSON parser (no jq
# dependency). Degrades gracefully — a missing file or step_finish event just
# warns and leaves the values empty; never fails the pipeline.
oc_extract_metrics() {
  local jsonl="$1" prefix="$2" line cost tin tout cread metrics_file
  metrics_file="${SCRATCH:?}/metrics.env"
  if [ ! -s "$jsonl" ]; then
    warn "no telemetry captured for $prefix (opencode --format json stream empty/missing)"
    return 0
  fi
  line=$(grep '"type":"step_finish"' "$jsonl" 2>/dev/null | tail -n1)
  if [ -z "$line" ]; then
    warn "no step_finish event found for $prefix — cost/token telemetry unavailable"
    return 0
  fi
  cost=$(printf '%s\n' "$line" | grep -oE '"cost":[0-9.]+' | head -n1 | sed -E 's/^"cost":([0-9.]+)$/\1/')
  tin=$(printf '%s\n' "$line" | grep -oE '"input":[0-9]+' | head -n1 | sed -E 's/^"input":([0-9]+)$/\1/')
  tout=$(printf '%s\n' "$line" | grep -oE '"output":[0-9]+' | head -n1 | sed -E 's/^"output":([0-9]+)$/\1/')
  cread=$(printf '%s\n' "$line" | grep -oE '"cache":\{[^}]*"read":[0-9]+' | grep -oE '"read":[0-9]+' | sed -E 's/^"read":([0-9]+)$/\1/')
  {
    echo "${prefix}_COST=$cost"
    echo "${prefix}_TOKENS_IN=$tin"
    echo "${prefix}_TOKENS_OUT=$tout"
    echo "${prefix}_CACHE_READ=$cread"
  } >> "$metrics_file"
}
