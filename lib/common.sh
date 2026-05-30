#!/usr/bin/env bash
# Shared helpers for all gh-openreview subcommands. Sourced, not executed.
# Provides: logging, PR/repo resolution, opencode config + invocation, scratch
# directory management, and a confirm prompt. No GitHub token is required here;
# auth (gh + opencode) is inherited from the caller's environment.

# Self-resolve install paths so lib scripts work whether launched by the
# entrypoint (which exports these) or directly (e.g. the CI composite action).
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

# Ensure opencode is available; auto-install only when --bootstrap was passed.
need_opencode() {
  command -v opencode >/dev/null 2>&1 && return
  if [ "${OPENREVIEW_BOOTSTRAP:-0}" = "1" ]; then
    info "installing opencode…"
    curl -fsSL https://opencode.ai/install | bash 1>&2
    export PATH="$HOME/.opencode/bin:$PATH"
    command -v opencode >/dev/null 2>&1 || die "opencode install failed"
    ok "opencode installed"
  else
    die "opencode not found. Install: curl -fsSL https://opencode.ai/install | bash  (or re-run with --bootstrap)"
  fi
}

# --- common flags (--model / --auth-cmd) -------------------------------------
# Strips recognized common flags from "$@"; leaves the rest in OR_ARGS[].
OR_MODEL_FLAG=""
OR_ARGS=()
parse_common_flags() {
  OR_ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --model)    OR_MODEL_FLAG="${2:?--model needs a value}"; shift 2 ;;
      --model=*)  OR_MODEL_FLAG="${1#*=}"; shift ;;
      --auth-cmd) export OPENREVIEW_AUTH_CMD="${2:?--auth-cmd needs a value}"; shift 2 ;;
      --auth-cmd=*) export OPENREVIEW_AUTH_CMD="${1#*=}"; shift ;;
      --bootstrap) export OPENREVIEW_BOOTSTRAP=1; shift ;;
      *) OR_ARGS+=("$1"); shift ;;
    esac
  done
}

# --- model resolution --------------------------------------------------------
# Precedence: --model flag > OPENREVIEW_MODEL > OC_MODEL > bundled free model.
resolve_model() {
  OR_MODEL="${OR_MODEL_FLAG:-${OPENREVIEW_MODEL:-${OC_MODEL:-opencode/deepseek-v4-flash-free}}}"
  export OR_MODEL
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
# oc_run <dir> <prompt>: run an optional auth-cmd, then opencode in <dir>.
# opencode's chatter goes to stderr so command stdout stays clean; the model
# communicates results by writing files (the prompts instruct it to).
oc_run() {
  local dir="$1" prompt="$2"
  if [ -n "${OPENREVIEW_AUTH_CMD:-}" ]; then
    info "running auth-cmd…"; eval "$OPENREVIEW_AUTH_CMD" 1>&2 || warn "auth-cmd exited non-zero"
  fi
  ( cd "$dir" && opencode run -m "$OR_MODEL" "$prompt" ) 1>&2
}

# OR_DIR is the directory opencode runs in (repo root when available) so the
# model can read CLAUDE.md / conventions/. Scratch lives directly under it.
resolve_dir() {
  OR_DIR="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
  export OR_DIR
}

# --- scratch dir -------------------------------------------------------------
# A working subdir inside OR_DIR (so opencode's project-sandboxed read/write
# tools can reach it). Exposes SCRATCH (absolute) and SCRATCH_REL (relative to
# OR_DIR, for use in prompts). Cleaned on exit unless OPENREVIEW_KEEP_SCRATCH.
scratch_init() {
  : "${OR_DIR:?call resolve_dir first}"
  SCRATCH_REL="${OPENREVIEW_SCRATCH_NAME:-.openreview-tmp}"
  SCRATCH="$OR_DIR/$SCRATCH_REL"
  rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
  export SCRATCH SCRATCH_REL
  if [ -z "${OPENREVIEW_KEEP_SCRATCH:-}" ]; then
    # shellcheck disable=SC2064
    trap "rm -rf '$SCRATCH'" EXIT
  fi
}

# --- PR / repo resolution ----------------------------------------------------
# Sets OR_PR (number) and OR_REPO (owner/repo) from: a number (current repo),
# a PR URL (any repo), or nothing (PR of the current branch). Uses gh's built-in
# --jq, so no separate jq dependency is required.
resolve_pr_target() {
  need_cmd gh
  local sel="${1:-}" line url
  if [ -n "$sel" ]; then
    line="$(gh pr view "$sel" --json number,url --jq '"\(.number)\t\(.url)"' 2>/dev/null)" \
      || die "could not find a PR for '$sel' (pass a number, URL, or run inside the branch's repo)"
  else
    line="$(gh pr view --json number,url --jq '"\(.number)\t\(.url)"' 2>/dev/null)" \
      || die "no PR found for the current branch (pass a PR number or URL)"
  fi
  OR_PR="${line%%$'\t'*}"
  url="${line#*$'\t'}"
  # https://github.com/OWNER/REPO/pull/NN  ->  OWNER/REPO
  OR_REPO="$(printf '%s' "$url" | sed -E 's#^https?://[^/]+/([^/]+/[^/]+)/pull/.*#\1#')"
  [ -n "$OR_PR" ] && [ -n "$OR_REPO" ] || die "failed to resolve PR number/repo from gh"
  export OR_PR OR_REPO
}

# --- confirm -----------------------------------------------------------------
# confirm "<question>": returns 0 on yes. Auto-yes when OR_YES=1.
confirm() {
  [ "${OR_YES:-0}" = "1" ] && return 0
  local ans
  printf '%s [y/N] ' "$1" >&2
  read -r ans </dev/tty 2>/dev/null || return 1
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}
