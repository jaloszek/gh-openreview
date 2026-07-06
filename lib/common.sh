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
# (U+202A-202E, Trojan Source; U+2066-2069), and the variation-selector
# SUPPLEMENT (U+E0100-E01EF). The BMP variation selectors (U+FE00-FE0F) are
# deliberately NOT stripped: U+FE0F/U+FE0E are ubiquitous in legitimate emoji
# text (observed: 16 strips on a real news-content diff) and their smuggling
# value is negligible next to the ranges above — stripping them silently
# alters the content under review. Detects on codepoints, not glyphs.
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
    $c += s/[\x{E0000}-\x{E007F}\x{200B}-\x{200D}\x{FEFF}\x{202A}-\x{202E}\x{2066}-\x{2069}\x{E0100}-\x{E01EF}]//g;
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

# --- engine fingerprint (restart / skip-guard invalidation) ------------------
# engine_fingerprint: short stable hash over what actually changes review
# behavior without changing the diff — lib/passes.sh contents, every prompt
# file under prompts/ (versioned prompt text passes.sh cats in), plus the
# resolved main/verify model names. cksum-based (POSIX, Bash 3.2-safe, no
# external hash dependency beyond cksum which ships everywhere). Callers must
# resolve_model/resolve_verify_model first so OR_MODEL/OR_VERIFY_MODEL reflect
# the run's actual config.
engine_fingerprint() {
  local passes_file="$OPENREVIEW_LIB/passes.sh" content="" prompts_dir="$OPENREVIEW_ROOT/prompts" f
  [ -f "$passes_file" ] && content=$(cat "$passes_file")
  if [ -d "$prompts_dir" ]; then
    for f in $(find "$prompts_dir" -type f | LC_ALL=C sort); do
      content="$content
$(cat "$f")"
    done
  fi
  { printf '%s\n' "$content"; printf 'model:%s\n' "${OR_MODEL:-}"; printf 'verify:%s\n' "${OR_VERIFY_MODEL:-}"; } \
    | cksum | awk '{print $1}'
}

# --- opencode config precedence ----------------------------------------------
# Respect a user's config; only fall back to the bundled one when none exists.
#   OPENCODE_CONFIG env > project ./opencode.json(c) > ~/.config/opencode > bundled
# By default a consumer config found this way is not used verbatim: it is
# merged with the bundled hardened tools/permission maps forced wholesale (see
# _merge_effective_config below), so a consumer repo can no longer silently
# weaken the sandbox. Set OPENREVIEW_TRUST_REPO_CONFIG=true to restore the
# pre-merge behavior (consumer config used verbatim).
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


# --- merged effective config (TASK-29) ---------------------------------------
# _merge_effective_config <consumer_config_path>: build
# $SCRATCH/opencode-effective.json = consumer config with the bundled
# tools/permission maps forced wholesale (no deep-merge — a consumer cannot
# re-enable anything piecemeal) and any mcp key dropped. Everything else in
# the consumer config passes through untouched. Prefers jq, falls back to
# python3, and if neither is available falls back to the bundled config
# outright (safe direction) with a warn. Never fails the run over the merge.
# Sets OPENCODE_CONFIG to the resulting path on success.
_merge_effective_config() {
  local consumer="$1" bundled="$OPENREVIEW_ROOT/opencode.json" out
  if [ -z "${SCRATCH:-}" ]; then
    warn "SCRATCH not set; cannot write merged config — falling back to bundled config"
    export OPENCODE_CONFIG="$bundled"
    return
  fi
  out="$SCRATCH/opencode-effective.json"
  if command -v jq >/dev/null 2>&1; then
    if jq -s '.[0] as $c | .[1] as $b | ($c | del(.mcp)) * {tools: $b.tools, permission: $b.permission}' \
      "$consumer" "$bundled" >"$out" 2>/dev/null; then
      export OPENCODE_CONFIG="$out"
      info "merged consumer config with hardened security keys (tools/permission forced, mcp dropped)"
      return
    fi
    warn "jq merge of $consumer failed — falling back to bundled config"
    export OPENCODE_CONFIG="$bundled"
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    if CONSUMER="$consumer" BUNDLED="$bundled" OUT="$out" python3 -c '
import json, os
with open(os.environ["CONSUMER"]) as f:
    c = json.load(f)
with open(os.environ["BUNDLED"]) as f:
    b = json.load(f)
c.pop("mcp", None)
c["tools"] = b["tools"]
c["permission"] = b["permission"]
with open(os.environ["OUT"], "w") as f:
    json.dump(c, f, indent=2)
' 2>/dev/null; then
      export OPENCODE_CONFIG="$out"
      info "merged consumer config with hardened security keys (tools/permission forced, mcp dropped)"
      return
    fi
    warn "python3 merge of $consumer failed — falling back to bundled config"
    export OPENCODE_CONFIG="$bundled"
    return
  fi
  warn "neither jq nor python3 available — cannot merge $consumer safely; falling back to bundled config"
  export OPENCODE_CONFIG="$bundled"
}

# trust_repo_config: OPENREVIEW_TRUST_REPO_CONFIG (env) / trust-repo-config
# (action input, fed through the same env var). true restores pre-TASK-29
# behavior (consumer config used verbatim, TASK-12 warning only).
_trust_repo_config() {
  case "${OPENREVIEW_TRUST_REPO_CONFIG:-false}" in
    1 | true | TRUE | True) return 0 ;;
    *) return 1 ;;
  esac
}

prepare_opencode_config() {
  local dir="${1:-$PWD}"
  local consumer=""
  if [ -n "${OPENCODE_CONFIG:-}" ]; then
    consumer="$OPENCODE_CONFIG"
  elif [ -f "$dir/opencode.json" ]; then
    consumer="$dir/opencode.json"
  elif [ -f "$dir/opencode.jsonc" ]; then
    consumer="$dir/opencode.jsonc"
  else
    local g
    for g in "$HOME/.config/opencode/opencode.json" "$HOME/.config/opencode/opencode.jsonc"; do
      if [ -f "$g" ]; then
        consumer="$g"
        break
      fi
    done
  fi
  if [ -z "$consumer" ]; then
    export OPENCODE_CONFIG="$OPENREVIEW_ROOT/opencode.json"
    return
  fi
  if _trust_repo_config; then
    _warn_config_replacement "$consumer"
    export OPENCODE_CONFIG="$consumer"
    return
  fi
  _merge_effective_config "$consumer"
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
    # `timeout` is absent on stock macOS (and `gtimeout` needs coreutils), so
    # fall back to a pure-bash watchdog there — a hung model call must NEVER
    # run unbounded (observed: free-tier stalls with 0-byte event streams).
    # stdout (the JSON event stream) is redirected to $jsonl, not inherited,
    # so it stays out of this function's own stdout; stderr passes through.
    rc=0
    if command -v timeout >/dev/null 2>&1; then
      ( cd "$dir" && timeout "$to" opencode run --format json -m "$model" "$prompt" ) >"$jsonl" || rc=$?
    elif command -v gtimeout >/dev/null 2>&1; then
      ( cd "$dir" && gtimeout "$to" opencode run --format json -m "$model" "$prompt" ) >"$jsonl" || rc=$?
    else
      local ocpid wpid
      ( cd "$dir" && exec opencode run --format json -m "$model" "$prompt" ) >"$jsonl" &
      ocpid=$!
      ( sleep "$to"; kill "$ocpid" 2>/dev/null ) &
      wpid=$!
      wait "$ocpid" || rc=$?
      kill "$wpid" 2>/dev/null
      wait "$wpid" 2>/dev/null || true
      # SIGTERM from the watchdog surfaces as 143; normalize to timeout's 124
      # so the retry/logging path below treats both alike.
      [ "$rc" -eq 143 ] && rc=124
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

# --- self-consistency voting: verify-as-judge variant merge (TASK-44) -------
# vote_merge <outfile> <in1> [<in2> ...]: merge >=2 diversified generate-pass
# candidate files into one candidates file. Groups @@FINDING records by same
# file AND line +-5 across passes (a greedy, order-of-appearance clustering —
# good enough at this tolerance; not a global optimum). votes = number of
# DISTINCT passes (input files) contributing to a group. A group is kept when
# votes >= 2, or it is a single-vote group whose finding is sev=important AND
# conf=high.
#
# Within a kept group, findings are clustered into "variants" by normalized
# body text (lowercased, whitespace-squeezed): two bodies are the SAME variant
# when they are equal, or one is a prefix/suffix of the other; anything else is
# a DISTINCT variant. A single surviving variant is emitted unchanged (using
# the longest raw body among its duplicates, for detail). Multiple variants
# mean the passes disagree about what's wrong at this location — TASK-37's
# post-mortem found that silently picking one (longest-body-wins) favored
# verbose-but-wrong diagnoses over terse-but-right ones. Instead, emit ONE
# record whose body concatenates up to 3 variants (shortest first) as
# "VARIANT 1: <body> || VARIANT 2: <body> ..." — prompts/verify.txt tells the
# verify pass to re-derive the mechanism and keep only the correct variant.
#
# @@PRDESC is carried verbatim from the FIRST input file (the earliest
# surviving pass) — voting never touches the PR-description rating.
vote_merge() {
  local out="$1"; shift
  awk -v pass_total="$#" '
    function norm(s) {
      s = tolower(s)
      gsub(/[ \t]+/, " ", s)
      gsub(/^ +| +$/, "", s)
      return s
    }
    function flush_finding() {
      if (have && loc != "") {
        nf++
        p = loc; ln = 0
        idx = match(loc, /:[0-9]+$/)
        if (idx > 0) { p = substr(loc, 1, idx - 1); ln = substr(loc, idx + 1) + 0 }
        ffile[nf] = p; fline[nf] = ln
        fsev[nf] = (sev == "important") ? "important" : "nit"
        fconf[nf] = (conf == "high" || conf == "med" || conf == "low") ? conf : "low"
        ftitle[nf] = title
        fbody[nf] = body
        fpass[nf] = passidx
      }
      have = 0; sev = ""; loc = ""; conf = ""; title = ""; body = ""
    }
    FNR == 1 {
      passidx++
      if (first_filename == "") first_filename = FILENAME
      in_prdesc = 0
    }
    /^@@FINDING[[:space:]]*$/ { flush_finding(); mode = "f"; have = 1; next }
    /^@@PRDESC[[:space:]]*$/ {
      flush_finding()
      mode = "p"
      in_prdesc = (FILENAME == first_filename)
      next
    }
    mode == "f" {
      line = $0
      if      (line ~ /^sev:/)   { sub(/^sev:[ \t]*/, "", line);   sev = tolower(line) }
      else if (line ~ /^loc:/)   { sub(/^loc:[ \t]*/, "", line);   loc = line }
      else if (line ~ /^conf:/)  { sub(/^conf:[ \t]*/, "", line);  conf = tolower(line) }
      else if (line ~ /^title:/) { sub(/^title:[ \t]*/, "", line); title = line }
      else if (line ~ /^body:/)  { sub(/^body:[ \t]*/, "", line);  body = line }
    }
    mode == "p" && in_prdesc { prdesc = prdesc $0 "\n" }
    END {
      flush_finding()

      # --- group by file + line +-5, greedy, in order of appearance ---------
      ng = 0
      for (i = 1; i <= nf; i++) {
        g = 0
        for (k = 1; k <= ng; k++) {
          if (gfile[k] == ffile[i]) {
            d = gline[k] - fline[i]; if (d < 0) d = -d
            if (d <= 5) { g = k; break }
          }
        }
        if (g == 0) { ng++; g = ng; gfile[g] = ffile[i]; gline[g] = fline[i] }
        gcount[g]++
        m = gcount[g]
        gm_sev[g SUBSEP m]   = fsev[i]
        gm_conf[g SUBSEP m]  = fconf[i]
        gm_title[g SUBSEP m] = ftitle[i]
        gm_body[g SUBSEP m]  = fbody[i]
        gm_pass[g SUBSEP m]  = fpass[i]
      }

      # --- votes = distinct passes per group ---------------------------------
      for (g = 1; g <= ng; g++) {
        delete seenpass
        v = 0
        for (m = 1; m <= gcount[g]; m++) {
          if (!((gm_pass[g SUBSEP m]) in seenpass)) { seenpass[gm_pass[g SUBSEP m]] = 1; v++ }
        }
        gvotes[g] = v
      }

      for (g = 1; g <= ng; g++) {
        keep = (gvotes[g] >= 2)
        if (!keep) {
          for (m = 1; m <= gcount[g]; m++) {
            if (gm_sev[g SUBSEP m] == "important" && gm_conf[g SUBSEP m] == "high") { keep = 1; break }
          }
        }
        if (!keep) continue
        ngroups_kept++

        # --- cluster members into variant equivalence classes ---------------
        delete var_body; delete var_title; delete var_sev; delete var_conf
        nv = 0
        for (m = 1; m <= gcount[g]; m++) {
          b = gm_body[g SUBSEP m]; nb = norm(b)
          placed = 0
          for (vv = 1; vv <= nv; vv++) {
            rn = norm(var_body[vv])
            if (nb == rn || index(rn, nb) == 1 || index(nb, rn) == 1) {
              if (length(b) > length(var_body[vv])) {
                var_body[vv] = b; var_title[vv] = gm_title[g SUBSEP m]
              }
              if (gm_sev[g SUBSEP m] == "important") var_sev[vv] = "important"
              if (gm_conf[g SUBSEP m] == "high") var_conf[vv] = "high"
              placed = 1; break
            }
          }
          if (!placed) {
            nv++
            var_body[nv] = b; var_title[nv] = gm_title[g SUBSEP m]
            var_sev[nv] = gm_sev[g SUBSEP m]; var_conf[nv] = gm_conf[g SUBSEP m]
          }
        }

        if (nv == 1) {
          osev = var_sev[1]; oconf = var_conf[1]
          if (gvotes[g] == pass_total) oconf = "high"
          printf "@@FINDING\n"       
          printf "sev: %s\n", osev   
          printf "loc: %s:%s\n", gfile[g], gline[g]
          printf "conf: %s\n", oconf 
          printf "title: %s\n", var_title[1]
          printf "body: %s\n", var_body[1]  
        } else {
          nmultivariant++
          # order variants by body length ascending (shortest first)
          for (a = 1; a <= nv; a++) order[a] = a
          for (a = 1; a <= nv; a++)
            for (b2 = a + 1; b2 <= nv; b2++)
              if (length(var_body[order[b2]]) < length(var_body[order[a]])) {
                t = order[a]; order[a] = order[b2]; order[b2] = t
              }
          cap = (nv > 3) ? 3 : nv
          merged_body = ""; osev = "nit"; oconf = "low"
          for (a = 1; a <= cap; a++) {
            vi = order[a]
            merged_body = merged_body (a > 1 ? " || " : "") "VARIANT " a ": " var_body[vi]
            if (var_sev[vi] == "important") osev = "important"
            if (var_conf[vi] == "high") oconf = "high"
            else if (var_conf[vi] == "med" && oconf != "high") oconf = "med"
          }
          printf "@@FINDING\n"       
          printf "sev: %s\n", osev   
          printf "loc: %s:%s\n", gfile[g], gline[g]
          printf "conf: %s\n", oconf 
          printf "title: %s\n", var_title[order[1]]
          printf "body: %s\n", merged_body
          delete order
        }
      }
      printf "@@PRDESC\n"
      printf "%s", prdesc
    }
  ' "$@" > "$out"
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
