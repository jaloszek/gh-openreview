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

# --- Incremental v2 (TASK-45): carry-forward + resolved tracking ------------
# Previous findings (schema: sev conf path line anchored title body — see
# gather.sh's prev-findings.tsv extraction) are absent when there's no usable
# previous state, on restart, or when the dynamic scope gate rejected
# incremental mode — in every one of those cases this whole block is a no-op
# and $TSV.all is untouched (today's full-review behavior, byte-for-byte).
PREV_TSV="$SCRATCH/prev-findings.tsv"
PREV_TOUCHED_TSV="$SCRATCH/prev-findings-touched.tsv"
CARRIED="$SCRATCH/.carried.tsv"
RESOLVED="$SCRATCH/.resolved.tsv"
n_carried=0
n_resolved=0
: > "$CARRIED"
: > "$RESOLVED"

if [ -s "$PREV_TSV" ]; then
  # Tolerant re-validation (defensive even though gather.sh already validates
  # on extraction — canned test fixtures feed this file directly): CRLF-
  # normalize, skip a header row, skip rows with fewer than 7 tab fields.
  NORM_PREV="$SCRATCH/.prev-findings.norm.tsv"
  NORM_TOUCHED="$SCRATCH/.prev-findings-touched.norm.tsv"
  tr -d '\r' < "$PREV_TSV" | awk -F'\t' 'NF>=7 && tolower($1)!="sev"' > "$NORM_PREV"
  [ -f "$PREV_TOUCHED_TSV" ] || : > "$PREV_TOUCHED_TSV"
  tr -d '\r' < "$PREV_TOUCHED_TSV" | awk -F'\t' 'NF>=7 && tolower($1)!="sev"' > "$NORM_TOUCHED"

  # UNTOUCHED = previous findings minus the touched ones (key: path+line+title).
  # Built with a BEGIN{getline} lookup rather than the two-file NR==FNR idiom:
  # NR==FNR breaks when the first file is empty (the no-touched-rows case,
  # e.g. acceptance test (a)) — NR and FNR both restart at 1 on the second
  # file's first record too, so it gets silently swallowed as "file 1" data.
  UNTOUCHED="$SCRATCH/.prev-findings-untouched.tsv"
  awk -F'\t' -v OFS='\t' -v tf="$NORM_TOUCHED" '
    BEGIN {
      while ((getline line < tf) > 0) {
        n = split(line, a, "\t")
        if (n >= 6) touched[a[3] "\t" a[4] "\t" a[6]] = 1
      }
      close(tf)
    }
    !(($3 "\t" $4 "\t" $6) in touched)
  ' "$NORM_PREV" > "$UNTOUCHED"

  # Fresh (this run's verified) finding locations, captured BEFORE carried
  # rows are merged in, for proximity matching below.
  FRESH_LOCS="$SCRATCH/.fresh-locs.tsv"
  awk -F'\t' '
    {
      loc=$3; path=loc; line="-1"
      idx = match(loc, /:[0-9]+$/)
      if (idx > 0) { path = substr(loc, 1, idx-1); line = substr(loc, idx+1) + 0 }
      print path "\t" line
    }
  ' "$TSV.all" > "$FRESH_LOCS"

  # Dedup rule (item 6): a fresh finding within +-5 lines, same path, of an
  # UNTOUCHED carried finding replaces it (prefer the fresh version) — drop
  # it from carry-forward. The same proximity rule decides whether a TOUCHED
  # finding was re-emitted by the fresh pass (re-emitted -> not resolved).
  # Same BEGIN{getline} lookup as above — FRESH_LOCS is legitimately empty
  # whenever this run's verified pass found nothing (test (a)'s exact shape).
  awk -F'\t' -v OFS='\t' -v win=5 -v lf="$FRESH_LOCS" '
    BEGIN {
      while ((getline line < lf) > 0) {
        n = split(line, a, "\t")
        if (n >= 2) locs[a[1]] = locs[a[1]] " " (a[2]+0)
      }
      close(lf)
    }
    {
      path=$3; line=$4+0; matched=0
      n=split(locs[path], arr, " ")
      for (i=1;i<=n;i++) { if (arr[i]!="") { d=arr[i]-line; if (d<0) d=-d; if (d<=win) { matched=1; break } } }
      if (!matched) print
    }
  ' "$UNTOUCHED" > "$CARRIED"

  awk -F'\t' -v OFS='\t' -v win=5 -v lf="$FRESH_LOCS" '
    BEGIN {
      while ((getline line < lf) > 0) {
        n = split(line, a, "\t")
        if (n >= 2) locs[a[1]] = locs[a[1]] " " (a[2]+0)
      }
      close(lf)
    }
    {
      path=$3; line=$4+0; matched=0
      n=split(locs[path], arr, " ")
      for (i=1;i<=n;i++) { if (arr[i]!="") { d=arr[i]-line; if (d<0) d=-d; if (d<=win) { matched=1; break } } }
      if (!matched) print
    }
  ' "$NORM_TOUCHED" > "$RESOLVED"

  # Carried/resolved items are model-authored text from an earlier run that
  # was already egress-sanitized once when first rendered — re-sanitize
  # anyway (must be idempotent; verified separately) rather than trust it.
  defang_file "$CARRIED"
  defang_file "$RESOLVED"

  n_carried=$(wc -l < "$CARRIED" | tr -d ' ')
  n_resolved=$(wc -l < "$RESOLVED" | tr -d ' ')

  if [ "$n_carried" -gt 0 ]; then
    # Convert carried rows (sev conf path line anchored title body) into the
    # same sk/sev/loc/conf/title/body/NR/orig_sev shape flush() emits above,
    # so carried findings flow through the SAME confidence gate, anchor
    # validation, and sort as fresh ones. NR is offset well past any fresh
    # NR so same-rank ties break fresh-first (arbitrary but stable).
    awk -F'\t' -v OFS='\t' '
      {
        sev=tolower($1); conf=tolower($2); path=$3; line=$4; title=$6; body=$7
        if (conf!="high" && conf!="med" && conf!="low") conf="low"
        orig_sev=sev
        if (conf=="low" && sev=="important") sev="nit"
        sk = (sev=="important"?0:1) (conf=="high"?0:(conf=="med"?1:2))
        gsub(/\t/," ",title); gsub(/\t/," ",body)
        loc = (line=="" ? path : path ":" line)
        nr = 1000000 + NR
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\n", sk, sev, loc, conf, title, body, nr, orig_sev
      }
    ' "$CARRIED" >> "$TSV.all"
    LC_ALL=C sort -t$'\t' -k1,1 -k7,7n "$TSV.all" > "$TSV.all.sorted"
    mv "$TSV.all.sorted" "$TSV.all"
  fi

  rm -f "$NORM_PREV" "$NORM_TOUCHED" "$UNTOUCHED" "$FRESH_LOCS"
fi

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
  if [ "$n_total" -eq 0 ]; then
    printf '%s\n\n' "$MARKER"
    if [ "$n_resolved" -gt 0 ]; then
      printf '✅ No blocking issues found in this diff · %d resolved since last review.\n\n' "$n_resolved"
      printf '<details><summary>✅ Resolved since last review (%d)</summary>\n\n' "$n_resolved"
      awk -F'\t' '{ printf "- ~~%s~~ · `%s:%s`\n", $6, $3, $4 }' "$RESOLVED"
      printf '\n</details>\n\n'
    else
      printf '✅ No blocking issues found in this diff.\n\n'
    fi
  else
    # Tally lives IN the header line — one-glance verdict (the field's
    # most-praised element). Safe for dedup: MARKER_MATCH is a substring
    # check, and post.sh only requires the marker token to be present.
    parts=""
    [ "$n_important" -gt 0 ] && parts="$n_important important"
    if [ "$n_nit" -gt 0 ]; then
      nit_word=$([ "$n_nit" -eq 1 ] && echo nit || echo nits)
      [ -n "$parts" ] && parts="$parts · $n_nit $nit_word" || parts="$n_nit $nit_word"
    fi
    if [ "$n_resolved" -gt 0 ]; then
      parts="$parts · $n_resolved resolved since last review"
    fi
    printf '%s — %s\n\n' "$MARKER" "$parts"

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

    if [ "$n_resolved" -gt 0 ]; then
      printf '<details><summary>✅ Resolved since last review (%d)</summary>\n\n' "$n_resolved"
      awk -F'\t' '{ printf "- ~~%s~~ · `%s:%s`\n", $6, $3, $4 }' "$RESOLVED"
      printf '\n</details>\n\n'
    fi

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

rm -f "$CARRIED" "$RESOLVED"

ok "review rendered ($(wc -l < "$OUT" | tr -d ' ') lines; ${n_important} important, ${n_nit} nits, ${n_suppressed} suppressed, ${n_carried} carried, ${n_resolved} resolved)"

# Record finding counts for telemetry (metrics.sh -> step summary + outputs).
{
  echo "OR_FINDINGS_IMPORTANT=$n_important"
  echo "OR_FINDINGS_NIT=$n_nit"
  echo "OR_FINDINGS_TOTAL=$n_total"
  echo "FINDINGS_SUPPRESSED=$n_suppressed"
  echo "FINDINGS_UNANCHORED=${n_unanchored:-0}"
  echo "FINDINGS_CARRIED=$n_carried"
  echo "FINDINGS_RESOLVED=$n_resolved"
} >> "$SCRATCH/metrics.env" 2>/dev/null || true
