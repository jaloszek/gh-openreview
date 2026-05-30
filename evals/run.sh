#!/usr/bin/env bash
# Eval harness for the review engine. Feeds each fixture diff through the real
# 3-pass pipeline (lib/passes.sh) and scores the rendered review against the
# fixture's expected.json. Requires opencode + credentials (it makes real model
# calls); it needs NO GitHub token — the engine reads only local scratch files.
#
# Usage:
#   evals/run.sh                 run every fixture
#   evals/run.sh sql-injection   run a single fixture by directory name
#   evals/run.sh --model <id>    override the model
#
# Exit status is non-zero if any fixture fails, so it doubles as a CI gate.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export OPENREVIEW_ROOT="$ROOT" OPENREVIEW_LIB="$ROOT/lib"
# shellcheck source=../lib/common.sh
. "$ROOT/lib/common.sh"

parse_common_flags "$@"
if [ "${#OR_ARGS[@]}" -gt 0 ]; then set -- "${OR_ARGS[@]}"; else set --; fi
need_opencode
need_cmd jq
resolve_model

# Pin the bundled config for reproducible, sandboxed runs unless the caller set
# their own. (prepare_opencode_config would otherwise pick up a project/global
# config and make eval results depend on the machine.)
export OPENCODE_CONFIG="${OPENCODE_CONFIG:-$ROOT/opencode.json}"
export MARKER="${MARKER:-## 🤖 OpenCode Review}"
MARKER_MATCH="OpenCode Review"

FIXTURES_DIR="$HERE/fixtures"
ONLY="${1:-}"

# score_fixture <expected.json> <review.md>: returns 0 if the rendered review
# satisfies the format contract and every assertion in expected.json.
score_fixture() {
  local exp="$1" review="$2" bad=0 pat cnt minimp

  # --- format contract (checked for every fixture) ---
  head -1 "$review" | grep -qF "$MARKER_MATCH" || { warn "  ✗ first line is missing the marker header"; bad=1; }
  grep -qF '🟣' "$review" && { warn "  ✗ a pre-existing (🟣) finding was rendered — must never appear"; bad=1; }

  [ -f "$exp" ] || { return "$bad"; }

  # --- expect_no_findings: the ✅ "no blocking issues" line must be present ---
  if [ "$(jq -r '.expect_no_findings // false' "$exp")" = "true" ]; then
    grep -qF '✅' "$review" || { warn "  ✗ expected no findings, but the review reported some"; bad=1; }
  fi

  # --- must_match: each regex (case-insensitive) must appear ---
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    grep -Eiq -- "$pat" "$review" || { warn "  ✗ expected the review to mention /$pat/"; bad=1; }
  done < <(jq -r '.must_match[]? // empty' "$exp")

  # --- must_not_match: each regex must be absent ---
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    grep -Eiq -- "$pat" "$review" && { warn "  ✗ the review should not mention /$pat/"; bad=1; }
  done < <(jq -r '.must_not_match[]? // empty' "$exp")

  # --- min_important: at least N rendered 🔴 findings (approx: counts the glyph) ---
  minimp="$(jq -r '.min_important // empty' "$exp")"
  if [ -n "$minimp" ]; then
    cnt="$(grep -cF '🔴' "$review" || true)"
    [ "$cnt" -ge "$minimp" ] || { warn "  ✗ expected at least $minimp important (🔴) finding(s), found $cnt"; bad=1; }
  fi

  return "$bad"
}

pass=0; fail=0; failed=""
for fx in "$FIXTURES_DIR"/*/; do
  name="$(basename "$fx")"
  [ -f "$fx/pr.diff" ] || continue
  if [ -n "$ONLY" ] && [ "$ONLY" != "$name" ]; then continue; fi

  info "── eval: $name (model: $OR_MODEL) ──"
  work="$(mktemp -d)"
  export OR_DIR="$work" SCRATCH="$work/.openreview-tmp" SCRATCH_REL=".openreview-tmp"
  mkdir -p "$SCRATCH"
  cp "$fx/pr.diff" "$SCRATCH/pr.diff"
  if [ -f "$fx/pr-meta.json" ]; then cp "$fx/pr-meta.json" "$SCRATCH/pr-meta.json"
  else printf '{"title":"","body":"","files":[]}\n' > "$SCRATCH/pr-meta.json"; fi
  printf '(no previous review)\n' > "$SCRATCH/prev-review.md"

  "$ROOT/lib/passes.sh" || warn "engine returned non-zero"

  review="$SCRATCH/opencode-review.md"
  if [ ! -s "$review" ]; then
    warn "FAIL $name — engine produced no review"
    fail=$((fail + 1)); failed="$failed $name"
  elif score_fixture "$fx/expected.json" "$review"; then
    ok "PASS $name"
    pass=$((pass + 1))
  else
    warn "FAIL $name"
    fail=$((fail + 1)); failed="$failed $name"
  fi
  rm -rf "$work"
done

log ""
if [ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]; then
  ok "all $pass eval(s) passed"
elif [ "$pass" -eq 0 ] && [ "$fail" -eq 0 ]; then
  die "no fixtures matched${ONLY:+ '$ONLY'}"
else
  die "$fail eval(s) failed:$failed ($pass passed)"
fi
