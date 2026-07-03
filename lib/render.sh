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
#   rating: good | could-be-improved | poor
#   reason: one short line (omitted when rating is good)
#
# Selection policy:
#   - 🔴 important: render ALL.
#   - 🟡 nit: render at most NIT_CAP (default 3), highest-confidence first;
#     if more remain, add a trailing "… +N more nits" row.
#   - pre-existing: never emitted (the passes don't write them).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${SCRATCH:?}"
[ -f "$SCRATCH/skip-review" ] && { info "skipped (diff unchanged since last review)"; exit 0; }
MARKER="${MARKER:-## 🤖 OpenCode Review}"
NIT_CAP="${OPENREVIEW_NIT_CAP:-3}"
MIN_CONF="${OPENREVIEW_MIN_CONF:-low}"
case "$MIN_CONF" in
  low|med|high) ;;
  *) MIN_CONF="low" ;;
esac
IN="$SCRATCH/review-verified.md"
OUT="$SCRATCH/opencode-review.md"
COMMENTABLE="$SCRATCH/commentable-lines.tsv"
[ -f "$IN" ] || printf '@@PRDESC\n' > "$IN"
[ -f "$COMMENTABLE" ] || : > "$COMMENTABLE"

# Egress sanitization: defang model-authored text before it reaches the
# posted comment (CamoLeak-style exfil via images, mention/ref spam). Only
# ever applied to files holding model-sourced content (the findings TSV and
# the PRDESC block), never to our own fixed template text.
defang_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  command -v perl >/dev/null 2>&1 || { warn "perl not found; skipping egress defang for $f"; return 0; }
  perl -0777 -i -pe '
    # 1) strip inline HTML that could exfiltrate or execute.
    s{<(img|picture|script|iframe)\b[^>]*>(?:.*?</\1\s*>)?}{}gis;
    s{<!--.*?-->}{}gs;
    # 2) wrap issue/PR refs and mentions in backticks (no notification, no link).
    s{(?<!`)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+|#[0-9]+)(?!`)}{`$1`}g;
    s{(?<!`)(@[A-Za-z0-9-]+(?:/[A-Za-z0-9._-]+)?)(?!`)}{`$1`}g;
    # 3) markdown images -> removed; markdown links -> text + code-span url.
    s{!\[([^\]]*)\]\([^)]*\)}{[image removed: $1]}g;
    s{\[([^\]]*)\]\(([^)]*)\)}{$1 (`$2`)}g;
  ' "$f"
  sanitize_text "$f"
}

# 1) Extract findings to a TSV with a sort key, and the PR-description block to a
#    separate file. awk is portable (no jq dependency, Bash 3.2 friendly).
TSV="$SCRATCH/.findings.tsv"
PRDESC="$SCRATCH/.prdesc.md"
awk -v prdesc="$PRDESC" '
  function flush() {
    if (have) {
      # Defensive: unknown/missing conf is treated as low.
      if (conf != "high" && conf != "med" && conf != "low") conf = "low"
      orig_sev = sev
      # Hard rule: a low-confidence finding is never rendered as Important —
      # demote it to nit for rendering purposes (original sev kept for detail).
      if (conf == "low" && sev == "important") sev = "nit"
      # severity rank then confidence rank -> stable, deterministic ordering
      sk = (sev=="important"?0:1) (conf=="high"?0:(conf=="med"?1:2))
      gsub(/\t/, " ", title); gsub(/\t/, " ", body)
      # NR is the input-order tie-breaker so same sev+conf findings sort stably.
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\n", sk, sev, loc, conf, title, body, NR, orig_sev
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
    # Defensive: if the model spills the body across lines despite the
    # single-line contract, fold continuations in rather than dropping them.
    else if (body != "")     { body = body " " $0 }
  }
  END { flush() }
' "$IN" | LC_ALL=C sort -t$'\t' -k1,1 -k7,7n > "$TSV.all"
[ -f "$PRDESC" ] || : > "$PRDESC"

# Confidence gate: drop findings below OPENREVIEW_MIN_CONF entirely (default
# "low" = keep everything). Suppressed count is reported separately.
n_suppressed=$(awk -F'\t' -v min="$MIN_CONF" '
  function rank(c) { return (c=="high"?2:(c=="med"?1:0)) }
  BEGIN { minr=rank(min) }
  { if (rank($4) < minr) c++ }
  END { print c+0 }
' "$TSV.all")
awk -F'\t' -v OFS='\t' -v min="$MIN_CONF" '
  function rank(c) { return (c=="high"?2:(c=="med"?1:0)) }
  BEGIN { minr=rank(min) }
  { if (rank($4) >= minr) print }
' "$TSV.all" > "$TSV"
awk -F'\t' -v OFS='\t' -v min="$MIN_CONF" '
  function rank(c) { return (c=="high"?2:(c=="med"?1:0)) }
  BEGIN { minr=rank(min) }
  { if (rank($4) < minr) print }
' "$TSV.all" > "$TSV.suppressed"
rm -f "$TSV.all"

# Anchor validation: exact path:line in commentable-lines.tsv -> kept as-is;
# within +-3 lines of a commentable line on the same path -> snap to it (note
# the adjustment); otherwise mark [unanchored] rather than dropping it. Adds a
# 9th column (anchor note) consumed by the detail-block renderer below.
awk -F'\t' -v OFS='\t' -v cf="$COMMENTABLE" '
  BEGIN {
    while ((getline line < cf) > 0) {
      n = split(line, a, "\t")
      if (n >= 2) commentable[a[1] SUBSEP (a[2]+0)] = 1
    }
    close(cf)
  }
  {
    loc = $3; path = loc; hasline = 0
    idx = match(loc, /:[0-9]+$/)
    if (idx > 0) { path = substr(loc, 1, idx-1); ln = substr(loc, idx+1) + 0; hasline = 1 }
    note = ""
    if (hasline && ((path SUBSEP ln) in commentable)) {
      note = ""
    } else if (hasline) {
      found = 0
      for (d = 1; d <= 3 && !found; d++) {
        if ((path SUBSEP (ln+d)) in commentable) { newln = ln+d; found = 1 }
        else if ((path SUBSEP (ln-d)) in commentable) { newln = ln-d; found = 1 }
      }
      if (found) {
        note = sprintf("snapped from %s:%d to nearest commentable line", path, ln)
        $3 = path ":" newln
      } else {
        note = "[unanchored]"
        unanchored++
      }
    } else {
      note = "[unanchored]"
      unanchored++
    }
    print $0, note
  }
  END { print unanchored+0 > "/dev/stderr" }
' "$TSV" 2> "$TSV.unanchored" > "$TSV.annot"
mv "$TSV.annot" "$TSV"
n_unanchored=$(cat "$TSV.unanchored" 2>/dev/null || echo 0)
rm -f "$TSV.unanchored"

# Same anchor annotation for suppressed findings, so the agent block can
# still show them with an anchored flag. Doesn't affect n_unanchored metrics.
awk -F'\t' -v OFS='\t' -v cf="$COMMENTABLE" '
  BEGIN {
    while ((getline line < cf) > 0) {
      n = split(line, a, "\t")
      if (n >= 2) commentable[a[1] SUBSEP (a[2]+0)] = 1
    }
    close(cf)
  }
  {
    loc = $3; path = loc; hasline = 0
    idx = match(loc, /:[0-9]+$/)
    if (idx > 0) { path = substr(loc, 1, idx-1); ln = substr(loc, idx+1) + 0; hasline = 1 }
    note = ""
    if (hasline && ((path SUBSEP ln) in commentable)) {
      note = ""
    } else if (hasline) {
      found = 0
      for (d = 1; d <= 3 && !found; d++) {
        if ((path SUBSEP (ln+d)) in commentable) { newln = ln+d; found = 1 }
        else if ((path SUBSEP (ln-d)) in commentable) { newln = ln-d; found = 1 }
      }
      if (found) { note = "snapped"; $3 = path ":" newln } else { note = "[unanchored]" }
    } else {
      note = "[unanchored]"
    }
    print $0, note
  }
' "$TSV.suppressed" > "$TSV.suppressed.annot" 2>/dev/null
mv "$TSV.suppressed.annot" "$TSV.suppressed"

defang_file "$TSV"
defang_file "$TSV.suppressed"
defang_file "$PRDESC"

# Parse the rating/reason trailer defensively: unknown/missing rating -> "good"
# (render nothing). Only the first "rating:"/"reason:" lines are honored.
PRDESC_RATING=$(awk -F': *' 'tolower($0) ~ /^rating:/ { print tolower($2); exit }' "$PRDESC" | tr -d '[:space:]')
PRDESC_REASON=$(awk -F': *' 'tolower($0) ~ /^reason:/ { sub(/^[^:]*: */, ""); print; exit }' "$PRDESC")
case "$PRDESC_RATING" in
  poor|could-be-improved) ;;
  *) PRDESC_RATING="good" ;;
esac

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

    # flat priority list: 🔴 high-conf important, 🟠 med/low-conf important
    # (rare — low-conf importants are demoted to nit above), 🟡 nit. Order is
    # the existing sev/conf/NR ranking — no numbering needed.
    awk -F'\t' -v cap="$NIT_CAP" '
      BEGIN { nit=0 }
      {
        sev=$2; loc=$3; conf=$4; title=$5; body=$6; note=$9
        if (sev=="nit") { nit++; if (nit>cap) next }
        dot=(sev=="important"?(conf=="high"?"🔴":"🟠"):"🟡")
        approx=(note=="[unanchored]") ? " _(location approximate)_" : ""
        printf "- %s **%s** · `%s`%s — %s\n", dot, title, loc, approx, body
      }
    ' "$TSV"
    if [ "$nits_hidden" -gt 0 ]; then
      printf -- '- 🟡 _+%d more %s over the cap_\n' "$nits_hidden" "$([ "$nits_hidden" -eq 1 ] && echo nit || echo nits)"
    fi
    printf '\n'

    # Agent details block: full machine-readable findings (rendered + capped
    # nits + confidence-suppressed), so agents asked to fix the review see
    # everything a human didn't.
    printf '<details><summary>🔍 Machine-readable findings (for agents)</summary>\n\n'
    printf '```tsv\n'
    printf 'sev\tconf\tpath\tline\tanchored\ttitle\tbody\n'
    {
      awk -F'\t' -v OFS='\t' '
        {
          sev=$2; conf=$4; loc=$3; title=$5; body=$6; note=$9
          path=loc; line=""
          idx = match(loc, /:[0-9]+$/)
          if (idx > 0) { path = substr(loc, 1, idx-1); line = substr(loc, idx+1) + 0 }
          anchored = (note == "[unanchored]") ? 0 : 1
          print sev, conf, path, line, anchored, title, body
        }
      ' "$TSV"
      awk -F'\t' -v OFS='\t' '
        {
          sev=$2; conf=$4; loc=$3; title=$5; body=$6; note=$9
          path=loc; line=""
          idx = match(loc, /:[0-9]+$/)
          if (idx > 0) { path = substr(loc, 1, idx-1); line = substr(loc, idx+1) + 0 }
          anchored = (note == "[unanchored]") ? 0 : 1
          print sev, conf, path, line, anchored, title, body
        }
      ' "$TSV.suppressed"
    }
    printf '```\n'
    printf 'Schema: sev(important|nit) conf(high|med|low) path line anchored(1|0) title body.\n'
    printf 'Includes ALL findings (even nits over the display cap and confidence-suppressed ones), so agents see what humans didn'"'"'t.\n'
    printf '</details>\n\n'
  fi

  # PR-description rating: render one line only when it's not "good".
  if [ "$PRDESC_RATING" != "good" ]; then
    printf '> 📝 PR description: **%s** — %s\n' "$PRDESC_RATING" "$PRDESC_REASON"
  fi
} > "$OUT"
rm -f "$TSV.suppressed"

# findings.tsv (comment-style "both" input for post.sh's inline review):
# one row per RENDERED finding (same important-all + nit-cap selection as the
# comment body above): sev, conf, path, line, anchored(0|1), title, body.
FINDINGS_TSV="$SCRATCH/findings.tsv"
awk -F'\t' -v OFS='\t' -v cap="$NIT_CAP" '
  BEGIN { nit=0 }
  {
    sev=$2; loc=$3; conf=$4; title=$5; body=$6; note=$9
    if (sev=="nit") { nit++; if (nit>cap) next }
    path=loc; line=""
    idx = match(loc, /:[0-9]+$/)
    if (idx > 0) { path = substr(loc, 1, idx-1); line = substr(loc, idx+1) + 0 }
    anchored = (note == "[unanchored]") ? 0 : 1
    print sev, conf, path, line, anchored, title, body
  }
' "$TSV" > "$FINDINGS_TSV"

ok "review rendered ($(wc -l < "$OUT" | tr -d ' ') lines; ${n_important} important, ${n_nit} nits, ${n_suppressed} suppressed)"

# Record finding counts for telemetry (metrics.sh -> step summary + outputs).
{
  echo "OR_FINDINGS_IMPORTANT=$n_important"
  echo "OR_FINDINGS_NIT=$n_nit"
  echo "OR_FINDINGS_TOTAL=$n_total"
  echo "FINDINGS_SUPPRESSED=$n_suppressed"
  echo "FINDINGS_UNANCHORED=${n_unanchored:-0}"
} >> "$SCRATCH/metrics.env" 2>/dev/null || true
