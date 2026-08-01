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
#   summary: one short line (riskiest area + what was verified there)
#   rating: good | could-be-improved | poor
#   reason: one short line (omitted when rating is good)
#
# Selection policy:
#   - 🔴 important: render ALL.
#   - 🟡 nit: render at most NIT_CAP (default 3), highest-confidence first;
#     if more remain, add a trailing "… +N more nits" row.
#   - pre-existing: never emitted (the passes don't write them).
#   - PRDESC rating != good: one finding-style bullet at the end of the list
#     (🟠 for poor, 🟡 for could-be-improved); the summary renders only inside
#     the collapsed agent section.
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
      # Defensive: models sometimes emit non-canonical labels; coerce known
      # aliases so a "critical" is not silently down-ranked to nit and a
      # "medium" confidence is not treated as low (TASK-53).
      if (sev=="critical" || sev=="blocker" || sev=="major" || sev=="high" || sev=="error") sev = "important"
      if (sev != "important") sev = "nit"
      if (conf == "medium") conf = "med"
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

  # Blast-radius escalated rows (TASK-55) sit in the touched feed for
  # RE-VERIFICATION only — their own lines did not change, so a re-check the
  # model dropped must not be presented as "resolved". Move any escalated row
  # that landed in RESOLVED back to CARRIED: a dropped re-verification
  # degrades to the plain carry-forward instead of fabricating a fix.
  ESC_TSV="$SCRATCH/prev-findings-escalated.tsv"
  if [ -s "$ESC_TSV" ] && [ -s "$RESOLVED" ]; then
    NORM_ESC="$SCRATCH/.prev-findings-escalated.norm.tsv"
    tr -d '\r' < "$ESC_TSV" | awk -F'\t' 'NF>=7 && tolower($1)!="sev"' > "$NORM_ESC"
    rm -f "$RESOLVED.esc"
    awk -F'\t' -v OFS='\t' -v ef="$NORM_ESC" -v cf="$RESOLVED.esc" '
      BEGIN {
        while ((getline line < ef) > 0) {
          n = split(line, a, "\t")
          if (n >= 6) esc[a[3] "\t" a[4] "\t" a[6]] = 1
        }
        close(ef)
      }
      {
        if (($3 "\t" $4 "\t" $6) in esc) print > cf
        else print
      }
    ' "$RESOLVED" > "$RESOLVED.split"
    mv "$RESOLVED.split" "$RESOLVED"
    if [ -s "$RESOLVED.esc" ]; then
      cat "$RESOLVED.esc" >> "$CARRIED"
    fi
    rm -f "$RESOLVED.esc" "$NORM_ESC"
  fi

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
    #
    # TASK-47: before converting, re-anchor each carried finding's line
    # number across hunk offsets from pr-incremental.diff. A carried
    # finding's line L (as of last_sha, the diff's OLD side) shifts by the
    # cumulative (new_len - old_len) of every hunk whose OLD range ends
    # before L. A finding whose line falls INSIDE a hunk's old range would
    # mean it should have been TOUCHED (never carried) — treat that as a
    # data inconsistency: warn and keep the original line rather than guess.
    awk -F'\t' -v OFS='\t' -v diff="$SCRATCH/pr-incremental.diff" '
      BEGIN {
        path = ""
        while ((getline dline < diff) > 0) {
          if (dline ~ /^diff --git /) {
            path = dline
            sub(/^diff --git a\/.* b\//, "", path)
            continue
          }
          if (dline ~ /^@@/) {
            if (path == "") continue
            if (!match(dline, /-[0-9]+(,[0-9]+)?/)) continue
            oldpart = substr(dline, RSTART + 1, RLENGTH - 1)
            if (!match(dline, /\+[0-9]+(,[0-9]+)?/)) continue
            newpart = substr(dline, RSTART + 1, RLENGTH - 1)
            n1 = split(oldpart, oa, ",")
            old_start = oa[1] + 0
            old_len = (n1 >= 2 ? oa[2] + 0 : 1)
            n2 = split(newpart, na, ",")
            new_len = (n2 >= 2 ? na[2] + 0 : 1)
            if (old_len > 0) { os = old_start; oe = old_start + old_len - 1 }
            else { os = old_start + 1; oe = old_start }
            off = new_len - old_len
            hunks[path] = hunks[path] " " os "," oe "," off
          }
        }
        close(diff)
      }
      function remap(p, l,    n, i, parts, os, oe, off, cum) {
        cum = 0
        n = split(hunks[p], parts, " ")
        for (i = 1; i <= n; i++) {
          if (parts[i] == "") continue
          split(parts[i], t, ",")
          os = t[1] + 0; oe = t[2] + 0; off = t[3] + 0
          if (l >= os && l <= oe) return -1
          if (l > oe) cum += off
        }
        return l + cum
      }
      {
        sev=tolower($1); conf=tolower($2); path=$3; line=$4; title=$6; body=$7
        if (sev!="important") sev="nit"
        if (conf=="medium") conf="med"
        if (conf!="high" && conf!="med" && conf!="low") conf="low"
        orig_sev=sev
        if (conf=="low" && sev=="important") sev="nit"
        sk = (sev=="important"?0:1) (conf=="high"?0:(conf=="med"?1:2))
        gsub(/\t/," ",title); gsub(/\t/," ",body)
        if (line != "" && (path in hunks)) {
          mapped = remap(path, line + 0)
          if (mapped == -1) {
            print "TASK-47: carried finding " path ":" line " falls inside a changed hunk range; keeping original line" > "/dev/stderr"
          } else {
            line = mapped
          }
        }
        loc = (line=="" ? path : path ":" line)
        nr = 1000000 + NR
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\n", sk, sev, loc, conf, title, body, nr, orig_sev
      }
    ' "$CARRIED" 2> "$TSV.hunkwarn" >> "$TSV.all"
    if [ -s "$TSV.hunkwarn" ]; then
      while IFS= read -r wline; do warn "$wline"; done < "$TSV.hunkwarn"
    fi
    rm -f "$TSV.hunkwarn"
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

# Docs-quality notes (advisory pass, passes.sh): parse @@DOCNOTE records into
# a loc/title/body TSV. File absent (pass disabled, skipped, or failed) or
# empty -> n_docs=0 and the section simply isn't rendered. Cap at 5 defensively
# even though the prompt already asks for at most 5.
DOCSTSV="$SCRATCH/.docsnotes.tsv"
: > "$DOCSTSV"
if [ -s "$SCRATCH/docs-notes.md" ]; then
  awk '
    function flush() {
      if (have && title != "" && body != "") {
        gsub(/\t/, " ", loc); gsub(/\t/, " ", title); gsub(/\t/, " ", body)
        # Hard display cap: the prompt asks for one-two sentences, but models
        # sometimes paste a full replacement paragraph — cut, never render it.
        if (length(body) > 300) body = substr(body, 1, 297) "…"
        printf "%s\t%s\t%s\n", loc, title, body
      }
      have=0; loc=""; title=""; body=""
    }
    /^@@DOCNOTE[[:space:]]*$/ { flush(); have=1; next }
    have {
      if      ($0 ~ /^loc:/)   { sub(/^loc:[[:space:]]*/,"");   loc=$0 }
      else if ($0 ~ /^title:/) { sub(/^title:[[:space:]]*/,""); title=$0 }
      else if ($0 ~ /^body:/)  { sub(/^body:[[:space:]]*/,"");  body=$0 }
      else if (body != "")     { body = body " " $0 }
    }
    END { flush() }
  ' "$SCRATCH/docs-notes.md" | head -5 > "$DOCSTSV"
fi
defang_file "$DOCSTSV"
n_docs=$(wc -l < "$DOCSTSV" | tr -d ' ')

# Parse the rating/reason trailer defensively: unknown/missing rating -> "good"
# (render nothing). Only the first "summary:"/"rating:"/"reason:" lines are
# honored. The summary is the reviewer's one-line what-was-checked note — it
# renders inside the collapsed agent section only, never as visible prose.
PRDESC_SUMMARY=$(awk 'tolower($0) ~ /^summary:/ { sub(/^[^:]*: */, ""); print; exit }' "$PRDESC")
PRDESC_RATING=$(awk -F': *' 'tolower($0) ~ /^rating:/ { print tolower($2); exit }' "$PRDESC" | tr -d '[:space:]')
PRDESC_REASON=$(awk -F': *' 'tolower($0) ~ /^reason:/ { sub(/^[^:]*: */, ""); print; exit }' "$PRDESC")
case "$PRDESC_RATING" in
  poor|could-be-improved) ;;
  *) PRDESC_RATING="good" ;;
esac

# PR-description verdict renders as one finding-style bullet, never a footer
# paragraph and never replacement text: poor (missing/contradicts the diff)
# at medium prominence, could-be-improved as a low-prio nit.
PRDESC_LINE=""
if [ "$PRDESC_RATING" = "poor" ]; then
  PRDESC_LINE="- 🟠 **PR description is missing or does not match the diff** — ${PRDESC_REASON:-empty, or it contradicts what the diff actually does}"
elif [ "$PRDESC_RATING" = "could-be-improved" ]; then
  PRDESC_LINE="- 🟡 **PR description could be improved** — ${PRDESC_REASON:-minor gaps vs. what the diff actually does}"
fi

# 2) Tallies.
n_important=$(awk -F'\t' '$2=="important"{c++} END{print c+0}' "$TSV")
n_nit=$(awk -F'\t' '$2=="nit"{c++} END{print c+0}' "$TSV")
n_total=$(( n_important + n_nit ))
nits_hidden=$(( n_nit > NIT_CAP ? n_nit - NIT_CAP : 0 ))

# --- Run ledger --------------------------------------------------------------
# One compact TSV row per review run (sha7 mode important nit candidates secs
# cost), carried comment-to-comment: post.sh edits/prunes old comments, so the
# whole history must be re-embedded in every new body (hidden
# openreview:ledger block, read back by gather.sh as prev-ledger.tsv). Capped
# at the last 5 runs. Purpose: make cost/depth trends — a zero-findings
# streak, a rising verify kill rate — visible to the pipeline itself, as
# input for depth/persona narrowing. Never a skip authority.
LEDGER="$SCRATCH/ledger.tsv"
# shellcheck disable=SC1091
[ -f "$SCRATCH/metrics.env" ] && . "$SCRATCH/metrics.env" 2>/dev/null || true
run_sha=$(tr -cd '0-9a-f' < "$SCRATCH/head-sha" 2>/dev/null | cut -c1-7 || true)
if [ -s "$SCRATCH/incremental-note.md" ]; then run_mode="incr"; else run_mode="full"; fi
n_cand=$(grep -cE '^@@FINDING[[:space:]]*$' "$SCRATCH/review-candidates.md" 2>/dev/null || true)
case "$n_cand" in ''|*[!0-9]*) n_cand=0 ;; esac
run_secs=$(( ${PREP_SECS:-0} + ${PASS1_SECS:-0} + ${PASS2_SECS:-0} ))
run_cost=$(awk -v a="${PREP_COST:-}" -v b="${PASS1_COST:-}" -v c="${PASS2_COST:-}" -v d="${DOCS_COST:-}" '
  BEGIN { if (a b c d == "") { print "-"; exit } printf "%.4f", (a+0)+(b+0)+(c+0)+(d+0) }')
if [ "${#run_sha}" -eq 7 ]; then
  # Re-running on the same head (restart, engine change) replaces that sha's
  # row instead of duplicating it.
  {
    if [ -s "$SCRATCH/prev-ledger.tsv" ]; then
      awk -F'\t' -v sha="$run_sha" '$1 != sha' "$SCRATCH/prev-ledger.tsv"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$run_sha" "$run_mode" "$n_important" "$n_nit" "$n_cand" "$run_secs" "$run_cost"
  } | tail -5 > "$LEDGER"
else
  # No usable head sha (old gather output): carry the history unchanged.
  cp "$SCRATCH/prev-ledger.tsv" "$LEDGER" 2>/dev/null || : > "$LEDGER"
fi

# 3) Emit the comment. Layout contract: the visible part stays human-minimal
# (verdict + findings only); everything else — resolved log, docs notes, the
# machine-readable findings + reviewer summary — lives in collapsed sections,
# with the agent-dedicated one last.
{
  if [ "$n_total" -eq 0 ]; then
    printf '%s\n\n' "$MARKER"
    if [ "$n_resolved" -gt 0 ]; then
      printf '✅ Looks good — all earlier findings were addressed (%d resolved), no new issues in this diff.\n\n' "$n_resolved"
    else
      printf '✅ Looks good — no issues found in this diff.\n\n'
    fi
    if [ -n "$PRDESC_LINE" ]; then
      printf '%s\n\n' "$PRDESC_LINE"
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

    # Nits-only verdict: say upfront that nothing blocks the merge.
    if [ "$n_important" -eq 0 ]; then
      printf 'Looks good — no blocking issues. The notes below are nitpicks and improvement ideas; take what is useful, the rest is safe to ignore.\n\n'
    fi

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
    if [ -n "$PRDESC_LINE" ]; then
      printf '%s\n' "$PRDESC_LINE"
    fi
    printf '\n'
  fi

  if [ "$n_resolved" -gt 0 ]; then
    printf '<details><summary>✅ Resolved since last review (%d)</summary>\n\n' "$n_resolved"
    awk -F'\t' '{ printf "- ~~%s~~ · `%s:%s`\n", $6, $3, $4 }' "$RESOLVED"
    printf '\n</details>\n\n'
  fi

  # Comments-&-docs notes (advisory): collapsed so they never crowd findings.
  if [ "$n_docs" -gt 0 ]; then
    note_word=$([ "$n_docs" -eq 1 ] && echo note || echo notes)
    printf '<details><summary>📚 Comments & docs (%d %s)</summary>\n\n' "$n_docs" "$note_word"
    awk -F'\t' '{ printf "- **%s** · `%s` — %s\n", $2, $1, $3 }' "$DOCSTSV"
    printf '\n</details>\n\n'
  fi

} > "$OUT"

# Agent payload: post.sh embeds this file as a hidden
# `<!-- openreview:agent <base64> -->` block — invisible to readers, plainly
# decodable by any agent working the raw comment body — and gather.sh reads
# the findings back from it next run for carry-forward. Contents: reviewer
# summary + run history one-liners, then the findings TSV (rendered + capped
# nits + confidence-suppressed), capped at 30 rows with an explicit omitted-
# rows marker so neither agents nor carry-forward mistake a cut list for a
# complete one.
AGENT_PAYLOAD="$SCRATCH/agent-payload.md"
: > "$AGENT_PAYLOAD"
if [ -s "$TSV" ] || [ -s "$TSV.suppressed" ] || [ -s "$LEDGER" ]; then
  {
    if [ -n "$PRDESC_SUMMARY" ]; then
      printf 'Reviewer summary: %s\n' "$PRDESC_SUMMARY"
    fi
    if [ -s "$LEDGER" ]; then
      # One line, oldest run first: sha mode important/nit candidates secs cost.
      printf 'Run history (oldest first): %s\n' "$(awk -F'\t' '
        {
          e = $1 " " $2 " " $3 "i/" $4 "n " $5 "c " $6 "s"
          if ($7 != "-") e = e " $" $7
          s = s (NR > 1 ? " · " : "") e
        }
        END { print s }
      ' "$LEDGER")"
    fi
    if [ -s "$TSV" ] || [ -s "$TSV.suppressed" ]; then
      printf 'Findings TSV (incl. over-cap and confidence-suppressed): sev(important|nit) conf(high|med|low) path line anchored(1|0) title body\n'
      n_payload_rows=$(cat "$TSV" "$TSV.suppressed" 2>/dev/null | wc -l | tr -d ' ')
      cat "$TSV" "$TSV.suppressed" 2>/dev/null | head -30 | awk -F'\t' -v OFS='\t' '
        {
          sev=$2; conf=$4; loc=$3; title=$5; body=$6; note=$9
          path=loc; line=""
          idx = match(loc, /:[0-9]+$/)
          if (idx > 0) { path = substr(loc, 1, idx-1); line = substr(loc, idx+1) + 0 }
          anchored = (note == "[unanchored]") ? 0 : 1
          print sev, conf, path, line, anchored, title, body
        }
      '
      if [ "$n_payload_rows" -gt 30 ]; then
        printf '(%d more rows omitted — this list is NOT complete)\n' "$((n_payload_rows - 30))"
      fi
    fi
  } > "$AGENT_PAYLOAD"
fi
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

ok "review rendered ($(wc -l < "$OUT" | tr -d ' ') lines; ${n_important} important, ${n_nit} nits, ${n_docs} doc notes, ${n_suppressed} suppressed, ${n_carried} carried, ${n_resolved} resolved)"

# Record finding counts for telemetry (metrics.sh -> step summary + outputs).
{
  echo "OR_FINDINGS_IMPORTANT=$n_important"
  echo "OR_FINDINGS_NIT=$n_nit"
  echo "OR_FINDINGS_TOTAL=$n_total"
  echo "OR_DOCS_NOTES=$n_docs"
  echo "FINDINGS_SUPPRESSED=$n_suppressed"
  echo "FINDINGS_UNANCHORED=${n_unanchored:-0}"
  echo "FINDINGS_CARRIED=$n_carried"
  echo "FINDINGS_RESOLVED=$n_resolved"
} >> "$SCRATCH/metrics.env" 2>/dev/null || true
