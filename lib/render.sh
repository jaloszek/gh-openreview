#!/usr/bin/env bash
# Deterministic render pass — replaces the old LLM "format" pass. Reads the
# verified findings ($SCRATCH/review-verified.md) in the strict record format the
# verify pass emits and produces the final PR comment ($SCRATCH/opencode-review.md).
# No model call: output shape is 100% deterministic and free.
#
# Input record format (see passes.sh prompts):
#   @@FINDING
#   sev: important|nit
#   loc: file:line
#   conf: high|med|low
#   title: <single line>
#   body: <single line, includes the suggested fix>
#   ... (repeat) ...
#   @@PRDESC
#   <freeform markdown to EOF — the suggested PR title/body>
#
# Selection policy:
#   - 🔴 important: render ALL.
#   - 🟡 nit: render at most NIT_CAP (default 3), highest-confidence first;
#     if more remain, add a trailing "… +N more nits" row.
#   - pre-existing: never emitted (the passes don't write them).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${SCRATCH:?}"
MARKER="${MARKER:-## 🤖 OpenCode Review}"
NIT_CAP="${OPENREVIEW_NIT_CAP:-3}"
IN="$SCRATCH/review-verified.md"
OUT="$SCRATCH/opencode-review.md"
[ -f "$IN" ] || printf '@@PRDESC\n' > "$IN"

# 1) Extract findings to a TSV with a sort key, and the PR-description block to a
#    separate file. awk is portable (no jq dependency, Bash 3.2 friendly).
TSV="$SCRATCH/.findings.tsv"
PRDESC="$SCRATCH/.prdesc.md"
awk -v prdesc="$PRDESC" '
  function flush() {
    if (have) {
      # severity rank then confidence rank -> stable, deterministic ordering
      sk = (sev=="important"?0:1) (conf=="high"?0:(conf=="med"?1:2))
      gsub(/\t/, " ", title); gsub(/\t/, " ", body)
      printf "%s\t%s\t%s\t%s\t%s\t%s\n", sk, sev, loc, conf, title, body
    }
    have=0; sev=""; loc=""; conf=""; title=""; body=""
  }
  BEGIN { mode="" }
  /^@@PRDESC[[:space:]]*$/ { flush(); mode="prdesc"; next }
  /^@@FINDING[[:space:]]*$/ { flush(); mode="finding"; have=1; next }
  mode=="prdesc" { print > prdesc; next }
  mode=="finding" {
    if      ($0 ~ /^sev:/)   { sub(/^sev:[[:space:]]*/,"");   sev=tolower($0) }
    else if ($0 ~ /^loc:/)   { sub(/^loc:[[:space:]]*/,"");   loc=$0 }
    else if ($0 ~ /^conf:/)  { sub(/^conf:[[:space:]]*/,"");  conf=tolower($0) }
    else if ($0 ~ /^title:/) { sub(/^title:[[:space:]]*/,""); title=$0 }
    else if ($0 ~ /^body:/)  { sub(/^body:[[:space:]]*/,"");  body=$0 }
  }
  END { flush() }
' "$IN" | LC_ALL=C sort -t$'\t' -k1,1 > "$TSV"
[ -f "$PRDESC" ] || : > "$PRDESC"

# 2) Tallies.
n_important=$(awk -F'\t' '$2=="important"{c++} END{print c+0}' "$TSV")
n_nit=$(awk -F'\t' '$2=="nit"{c++} END{print c+0}' "$TSV")
n_total=$(( n_important + n_nit ))
nits_hidden=$(( n_nit > NIT_CAP ? n_nit - NIT_CAP : 0 ))

# 3) Emit the comment.
{
  printf '%s\n\n' "$MARKER"

  if [ "$n_total" -eq 0 ]; then
    printf '✅ No blocking issues found in this diff.\n\n'
  else
    # bold tally
    parts=""
    [ "$n_important" -gt 0 ] && parts="$n_important important"
    if [ "$n_nit" -gt 0 ]; then
      nit_word=$([ "$n_nit" -eq 1 ] && echo nit || echo nits)
      [ -n "$parts" ] && parts="$parts · $n_nit $nit_word" || parts="$n_nit $nit_word"
    fi
    printf '**%s**\n\n' "$parts"

    # summary table (important first, nits capped)
    printf '| # | Severity | Finding | Location |\n'
    printf '|---|----------|---------|----------|\n'
    awk -F'\t' -v cap="$NIT_CAP" -v hidden="$nits_hidden" '
      BEGIN { i=0; nit=0 }
      {
        sev=$2; loc=$3; title=$5
        if (sev=="nit") { nit++; if (nit>cap) next }
        i++
        badge=(sev=="important"?"🔴 Important":"🟡 Nit")
        printf "| %d | %s | %s | `%s` |\n", i, badge, title, loc
      }
      END {
        if (hidden>0)
          printf "| | | … +%d more %s | |\n", hidden, (hidden==1?"nit":"nits")
      }
    ' "$TSV"
    printf '\n'

    # one detail section per rendered row
    awk -F'\t' -v cap="$NIT_CAP" '
      BEGIN { i=0; nit=0 }
      {
        sev=$2; loc=$3; conf=$4; title=$5; body=$6
        if (sev=="nit") { nit++; if (nit>cap) next }
        i++
        printf "### %d. %s\n", i, title
        printf "%s\n\n", body
        printf "<details><summary>Details</summary>\n\n"
        printf "- **Location:** `%s`\n- **Confidence:** %s\n</details>\n\n", loc, conf
      }
    ' "$TSV"
  fi

  # always append the suggested PR description, collapsed
  if [ -s "$PRDESC" ]; then
    printf '<details><summary>📝 Suggested PR description</summary>\n\n'
    cat "$PRDESC"
    printf '\n</details>\n'
  fi
} > "$OUT"

ok "review rendered ($(wc -l < "$OUT" | tr -d ' ') lines; ${n_important} important, ${n_nit} nits)"

# Record finding counts for telemetry (metrics.sh -> step summary + outputs).
{
  echo "OR_FINDINGS_IMPORTANT=$n_important"
  echo "OR_FINDINGS_NIT=$n_nit"
  echo "OR_FINDINGS_TOTAL=$n_total"
} >> "$SCRATCH/metrics.env" 2>/dev/null || true
