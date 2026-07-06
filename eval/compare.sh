#!/usr/bin/env bash
# eval/compare.sh — live benchmark scorer: score the two live review-bot
# comments on a real PR against a hand-written answer key
# (eval/hard-src/BUGS.md, eval/live-src/BUGS.md).
#
# Usage:
#   eval/compare.sh <pr-number> <answer-key.md>
#   eval/compare.sh --selftest      # canned comments, no network
#
# Token-scoped like gather.sh: read-only `gh` calls only, ambient auth (no
# GH_TOKEN plumbing needed — `gh api`/`gh repo view` use whatever `gh auth`
# already has). Always exits 0 in live mode: this is a report, not a gate.
#
# Machine-readable output: eval/.work/compare-<pr>.tsv, rows of
# reviewer \t bug_id \t hit(0|1) for every id in the answer key (seeded +
# "known unseeded true positives" extras).
set -euo pipefail

EVAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$EVAL_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$ROOT/lib/common.sh"

WORK="$EVAL_DIR/.work"
TOL=5

# --- answer-key parsing --------------------------------------------------

# parse_answer_key <key.md> <main-out.tsv> <extras-out.tsv>
# Any markdown table row whose first cell matches ^[A-Z][0-9]+$ (backticks
# tolerated) yields id \t file \t line. Rows that fall under a "## ... Known
# unseeded true positives ..." heading go to <extras-out.tsv> instead; every
# other table (deep-diagnosis/adjacent/omissions/easy-control/live-seeded/...)
# goes to <main-out.tsv> regardless of its own column layout, since id is
# always column 1 and file/line are always columns 2/3.
parse_answer_key() {
  local key="$1" mainout="$2" extrasout="$3"
  : > "$mainout"
  : > "$extrasout"
  awk -v mainout="$mainout" -v extrasout="$extrasout" '
    /^##/ {
      in_extras = ($0 ~ /[Kk]nown unseeded true positives/) ? 1 : 0
      next
    }
    /^\|/ {
      line = $0
      gsub(/^\|/, "", line)
      gsub(/\|[ \t]*$/, "", line)
      n = split(line, cells, "|")
      if (n < 3) next
      id = cells[1]; gsub(/`/, "", id); gsub(/^[ \t]+|[ \t]+$/, "", id)
      if (id !~ /^[A-Z][0-9]+$/) next
      file = cells[2]; gsub(/`/, "", file); gsub(/^[ \t]+|[ \t]+$/, "", file)
      ln = cells[3]; gsub(/`/, "", ln); gsub(/^[ \t]+|[ \t]+$/, "", ln)
      if (match(ln, /[0-9]+/) > 0) ln = substr(ln, RSTART, RLENGTH); else ln = "0"
      out = in_extras ? extrasout : mainout
      printf "%s\t%s\t%s\n", id, file, ln >> out
    }
  ' "$key"
}

# --- comment parsing -------------------------------------------------------

# extract_tsv_block <comment.md> <out.tsv> — writes the content of the first
# ```tsv fenced block (header + rows); empty file if none exists.
extract_tsv_block() {
  awk '
    /^```tsv[ \t]*$/ { f = 1; next }
    f && /^```/ { f = 0; next }
    f { print }
  ' "$1" > "$2"
}

# parse_tsv_findings <block.tsv> <out.tsv>
# Detects the 7-column openreview schema (sev conf path line anchored title
# body) vs. the 6-column schema (sev conf path line title body) from the
# header row's field count, and outputs a canonical
# sev \t path \t line \t title \t body per finding.
#
# Tolerant of: a path cell carrying an embedded ":line" or ":line-line"
# suffix with the line cell left blank (opencode does this for unanchored
# findings), and a line cell that is itself a range.
parse_tsv_findings() {
  awk -F'\t' -v OFS='\t' '
    NR == 1 { ncol = NF; next }
    NF < 4 { next }
    {
      sev = tolower($1); path = $3; loc = $4
      if (ncol >= 7) { title = $6; body = $7 } else { title = $5; body = $6 }
      if (match(path, /:[0-9]+(-[0-9]+)?$/) > 0) {
        loc = substr(path, RSTART + 1)
        path = substr(path, 1, RSTART - 1)
      }
      if (match(loc, /[0-9]+/) > 0) { line = substr(loc, RSTART, RLENGTH) } else { line = 0 }
      gsub(/\t/, " ", title); gsub(/\t/, " ", body)
      print sev, path, line + 0, title, body
    }
  ' "$1" > "$2"
}

# --- matching ---------------------------------------------------------------

# match_key <key.tsv> <findings.tsv> <perbug-out.tsv> <matched-idx-out>
# perbug-out: id \t hit(0|1) \t file \t line, in key order.
# matched-idx-out: 1-based line numbers (into <findings.tsv>) that hit
# something in this key — used to compute unmatched findings across both
# the main and extras keys.
match_key() {
  local key="$1" findings="$2" perbug="$3" idxout="$4"
  : > "$idxout"
  awk -F'\t' -v OFS='\t' -v tol="$TOL" -v idxout="$idxout" '
    NR == FNR { nk++; kid[nk] = $1; kfile[nk] = $2; kline[nk] = $3 + 0; next }
    { nf++; ffile[nf] = $2; fline[nf] = $3 + 0 }
    END {
      for (g = 1; g <= nk; g++) {
        hit = 0
        for (i = 1; i <= nf; i++) {
          d = fline[i] - kline[g]; if (d < 0) d = -d
          if (ffile[i] == kfile[g] && d <= tol) { hit = 1; used[i] = 1 }
        }
        print kid[g], hit, kfile[g], kline[g]
      }
      for (i = 1; i <= nf; i++) if (i in used) print i >> idxout
    }
  ' "$key" "$findings" > "$perbug"
}

# unmatched_findings <findings.tsv> <idx1> <idx2> <out.tsv>
# Findings whose 1-based line number is absent from both index files —
# potential FPs or new unseeded bugs, never auto-labeled as false positives.
unmatched_findings() {
  awk -F'\t' -v OFS='\t' -v idx1="$2" -v idx2="$3" '
    BEGIN {
      while ((getline l < idx1) > 0) used[l] = 1
      close(idx1)
      while ((getline l < idx2) > 0) used[l] = 1
      close(idx2)
    }
    !(FNR in used) { print $2, $3, $4 }
  ' "$1" > "$4"
}

# score_golden <golden.tsv> <findings.tsv> <adjacent-out.tsv> <deep-out.tsv>
# Mechanism-aware scoring (TASK-46) driven by the scope/mechanism columns
# `eval/golden/*.tsv` carries (see `eval/run.sh`'s TASK-35 rule, which this
# mirrors with one deliberate difference explained below).
#
# scope=adjacent rows (mechanism required): the answer key's file/line is
# the unchanged-code crash site, but a reviewer plausibly anchors at the
# causing diff line in a DIFFERENT file — so a candidate finding qualifies
# ONLY on a mechanism-ERE match against its title+body. Same-file alone is
# NOT enough: it would credit an unrelated finding that merely shares the
# file (observed live: A02 falsely credited by the D04 finding). Among
# qualifying candidates, same-file wins first, then smallest |line delta|
# (both are tiebreakers for the reported anchor, never part of the hit
# test).
# <adjacent-out.tsv> rows: id \t hit(0|1) \t anchor("file:line" or "-").
#
# scope=diff rows with a non-empty mechanism: hit as the normal file+line
# (+-tol) rule already used elsewhere; among matches, a deep hit is one
# whose finding text also satisfies the mechanism ERE, otherwise shallow.
# <deep-out.tsv> rows: id \t hit(0|1) \t deep(0|1).
# Rows with scope=diff and no mechanism are ignored here (already scored by
# match_key).
score_golden() {
  local golden="$1" findings="$2" adjout="$3" deepout="$4"
  : > "$adjout"
  : > "$deepout"
  awk -F'\t' -v OFS='\t' -v tol="$TOL" -v adjout="$adjout" -v deepout="$deepout" '
    NR == FNR {
      if ($0 ~ /^#/ || NF < 3) next
      ng++; gid[ng] = $1; gfile[ng] = $2; gline[ng] = $3 + 0
      gscope[ng] = (NF >= 7 && $7 != "") ? $7 : "diff"
      gmech[ng]  = (NF >= 8) ? tolower($8) : ""
      next
    }
    NF >= 4 {
      nf++; ffile[nf] = $2; fline[nf] = $3 + 0
      ftext[nf] = tolower($4 (NF >= 5 ? " " $5 : ""))
    }
    END {
      for (g = 1; g <= ng; g++) {
        if (gscope[g] == "adjacent") {
          best = 0; bestd = -1; bestf = 0
          for (i = 1; i <= nf; i++) {
            if (gmech[g] == "" || ftext[i] !~ gmech[g]) continue
            d = fline[i] - gline[g]; if (d < 0) d = -d
            samef = (ffile[i] == gfile[g]) ? 1 : 0
            if (best == 0 || samef > bestf || (samef == bestf && d < bestd)) {
              best = i; bestd = d; bestf = samef
            }
          }
          if (best > 0) print gid[g], 1, ffile[best] ":" fline[best] >> adjout
          else print gid[g], 0, "-" >> adjout
        } else if (gmech[g] != "") {
          hit = 0; deep = 0
          for (i = 1; i <= nf; i++) {
            d = fline[i] - gline[g]; if (d < 0) d = -d
            if (ffile[i] == gfile[g] && d <= tol) {
              hit = 1
              if (ftext[i] ~ gmech[g]) deep = 1
            }
          }
          print gid[g], hit, deep >> deepout
        }
      }
    }
  ' "$golden" "$findings"
}

# --- per-reviewer report ----------------------------------------------------

# score_reviewer <label> <comment.md> <mainkey.tsv> <extraskey.tsv> <outtsv>
#               [<golden.tsv>]
# Prints the report to stdout; appends label \t id \t hit rows to <outtsv>.
# Returns 0 always — a missing/unparseable comment is a warning, not a
# failure. <golden.tsv> is optional (TASK-46): when given, adds a
# deep/shallow tag to scope=diff+mechanism hits and a separate "adjacent"
# block for scope=adjacent rows — never folded into the seeded m/k count.
# Omitting it reproduces pre-TASK-46 output byte-for-byte.
score_reviewer() {
  local label="$1" commentfile="$2" mainkey="$3" extraskey="$4" outtsv="$5"
  local goldenfile="${6:-}"
  local tsvblock="$WORK/tsv-$label.tsv" findings="$WORK/findings-$label.tsv"
  local mainperbug="$WORK/perbug-main-$label.tsv" extrasperbug="$WORK/perbug-extras-$label.tsv"
  local mainidx="$WORK/idx-main-$label.tsv" extrasidx="$WORK/idx-extras-$label.tsv"
  local unmatched="$WORK/unmatched-$label.tsv"
  local nmain nhit nextras nextrashit

  printf '\n== %s ==\n' "$label"

  extract_tsv_block "$commentfile" "$tsvblock"
  if [ ! -s "$tsvblock" ]; then
    warn "no machine-readable block — skipping $label"
    printf 'no machine-readable TSV block — skipped (comment predates the requirement?)\n'
    return 0
  fi

  parse_tsv_findings "$tsvblock" "$findings"
  match_key "$mainkey" "$findings" "$mainperbug" "$mainidx"
  match_key "$extraskey" "$findings" "$extrasperbug" "$extrasidx"
  unmatched_findings "$findings" "$mainidx" "$extrasidx" "$unmatched"

  local golddeep="" goldadj=""
  if [ -n "$goldenfile" ]; then
    golddeep="$WORK/golden-deep-$label.tsv"
    goldadj="$WORK/golden-adj-$label.tsv"
    score_golden "$goldenfile" "$findings" "$goldadj" "$golddeep"
  fi

  nmain=$(wc -l < "$mainperbug" | tr -d ' ')
  nhit=$(awk -F'\t' '$2 == 1 { c++ } END { print c + 0 }' "$mainperbug")
  printf 'seeded found %s/%s\n' "$nhit" "$nmain"
  if [ -n "$golddeep" ]; then
    awk -F'\t' -v deepf="$golddeep" '
      BEGIN {
        while ((getline l < deepf) > 0) {
          n = split(l, a, "\t")
          if (n >= 3) tag[a[1]] = a[3] == 1 ? " (deep)" : " (shallow)"
        }
        close(deepf)
      }
      { printf "  %-4s %s:%s  %s%s\n", $1, $3, $4, ($2 == 1 ? "HIT" : "miss"), ($1 in tag ? tag[$1] : "") }
    ' "$mainperbug"
  else
    awk -F'\t' '{ printf "  %-4s %s:%s  %s\n", $1, $3, $4, ($2 == 1 ? "HIT" : "miss") }' "$mainperbug"
  fi

  nextras=$(wc -l < "$extrasperbug" | tr -d ' ')
  if [ "$nextras" -gt 0 ]; then
    nextrashit=$(awk -F'\t' '$2 == 1 { c++ } END { print c + 0 }' "$extrasperbug")
    printf 'extras matched %s/%s: %s\n' "$nextrashit" "$nextras" \
      "$(awk -F'\t' '$2 == 1 { printf "%s ", $1 }' "$extrasperbug")"
  fi

  if [ -s "$unmatched" ]; then
    printf 'unmatched findings (potential FP or new unseeded bug — human triage):\n'
    awk -F'\t' '{ printf "  %s:%s  %s\n", $1, $2, $3 }' "$unmatched"
  else
    printf 'unmatched findings: none\n'
  fi

  if [ -n "$goldadj" ] && [ -s "$goldadj" ]; then
    local nadj nadjhit
    nadj=$(wc -l < "$goldadj" | tr -d ' ')
    nadjhit=$(awk -F'\t' '$2 == 1 { c++ } END { print c + 0 }' "$goldadj")
    printf 'adjacent found %s/%s (mechanism-aware, not folded into seeded m/k)\n' "$nadjhit" "$nadj"
    awk -F'\t' '{ printf "  %-4s %s%s\n", $1, ($2 == 1 ? "HIT" : "miss"), ($2 == 1 ? " via " $3 : "") }' "$goldadj"
  fi

  awk -F'\t' -v OFS='\t' -v label="$label" '{ print label, $1, $2 }' "$mainperbug" >> "$outtsv"
  awk -F'\t' -v OFS='\t' -v label="$label" '{ print label, $1, $2 }' "$extrasperbug" >> "$outtsv"
}

# --- live PR fetch -----------------------------------------------------------

# fetch_review_comments <repo> <pr> <or-body-out> <claude-body-out>
# Writes the newest openreview comment body to <or-body-out> and the newest
# Claude comment body to <claude-body-out> (empty file, and a warning, when a
# reviewer never commented).
fetch_review_comments() {
  local repo="$1" pr="$2" orout="$3" clout="$4"
  local metaf="$WORK/comments-$pr.tsv"
  local best_or_ts="" best_cl_ts=""
  local cid cts bodyf firstline reviewer_type

  : > "$orout"
  : > "$clout"

  gh api "repos/$repo/issues/$pr/comments" --paginate \
    --jq '.[] | select(.user.login == "github-actions[bot]") | [.id, .created_at] | @tsv' \
    > "$metaf"

  while IFS="$(printf '\t')" read -r cid cts; do
    [ -n "$cid" ] || continue
    bodyf="$WORK/comment-$cid.md"
    gh api "repos/$repo/issues/comments/$cid" --jq .body > "$bodyf"
    firstline=$(head -n1 "$bodyf")
    case "$firstline" in
      "## 🤖 OpenCode Review"*) reviewer_type=openreview ;;
      "## 🔍 Code Review"*) reviewer_type=claude ;;
      *)
        if grep -qF -- '<!-- claude-review -->' "$bodyf"; then
          reviewer_type=claude
        else
          reviewer_type=unknown
        fi
        ;;
    esac
    if [ "$reviewer_type" = openreview ] && { [ -z "$best_or_ts" ] || [[ "$cts" > "$best_or_ts" ]]; }; then
      best_or_ts="$cts"
      cp "$bodyf" "$orout"
    elif [ "$reviewer_type" = claude ] && { [ -z "$best_cl_ts" ] || [[ "$cts" > "$best_cl_ts" ]]; }; then
      best_cl_ts="$cts"
      cp "$bodyf" "$clout"
    fi
  done < "$metaf"

  [ -s "$orout" ] || warn "no openreview comment found on $repo#$pr — scoring the other reviewer alone"
  [ -s "$clout" ] || warn "no Claude comment found on $repo#$pr — scoring the other reviewer alone"
}

# --- selftest: canned comments, no network ----------------------------------

selftest() {
  local tdir="$WORK/selftest" fails=0
  local mainkey extraskey outtsv
  rm -rf "$tdir"
  mkdir -p "$tdir"

  mainkey="$tdir/key-main.tsv"
  extraskey="$tdir/key-extras.tsv"
  parse_answer_key "$EVAL_DIR/live-src/BUGS.md" "$mainkey" "$extraskey"

  if [ "$(wc -l < "$mainkey" | tr -d ' ')" != 8 ]; then
    warn "selftest: expected 8 seeded rows in live-src/BUGS.md, got $(wc -l < "$mainkey" | tr -d ' ')"
    fails=$((fails + 1))
  fi
  if [ "$(wc -l < "$extraskey" | tr -d ' ')" != 2 ]; then
    warn "selftest: expected 2 extras rows in live-src/BUGS.md, got $(wc -l < "$extraskey" | tr -d ' ')"
    fails=$((fails + 1))
  fi

  # Case 1: 7-column (opencode) schema, exercising extras matching too.
  # L03 (reports.py:13) and L04 (reports.py:18) are exactly 5 lines apart, so
  # a finding at either line legitimately hits both (same clustered-bug
  # behavior eval/run.sh's own selftest documents) — the canned fixture's
  # reports.py:13 finding is expected to hit L03 AND L04.
  outtsv="$tdir/compare-opencode.tsv"
  : > "$outtsv"
  score_reviewer opencode "$EVAL_DIR/selftest/compare-opencode-comment.md" "$mainkey" "$extraskey" "$outtsv" > "$tdir/report-opencode.txt"
  if [ "$(awk -F'\t' '$2 ~ /^L/ && $3 == 1' "$outtsv" | wc -l | tr -d ' ')" != 4 ]; then
    warn "selftest: opencode fixture — expected 4 seeded hits (L01/L03/L04/L07)"
    fails=$((fails + 1))
  fi
  if ! awk -F'\t' '$2 == "X02" && $3 == 1 { found = 1 } END { exit !found }' "$outtsv"; then
    warn "selftest: opencode fixture — expected X02 extra to be matched"
    fails=$((fails + 1))
  fi
  if ! grep -q 'notify.py:99' "$tdir/report-opencode.txt"; then
    warn "selftest: opencode fixture — expected an unmatched finding at notify.py:99"
    fails=$((fails + 1))
  fi

  # Case 2: 6-column (claude) schema. Its reports.py:18 finding hits L04
  # exactly and L03 via the same ±5 adjacency as case 1.
  outtsv="$tdir/compare-claude.tsv"
  : > "$outtsv"
  score_reviewer claude "$EVAL_DIR/selftest/compare-claude-comment.md" "$mainkey" "$extraskey" "$outtsv" > "$tdir/report-claude.txt"
  if [ "$(awk -F'\t' '$2 ~ /^L/ && $3 == 1' "$outtsv" | wc -l | tr -d ' ')" != 5 ]; then
    warn "selftest: claude fixture — expected 5 seeded hits (L01/L02/L03/L04/L05)"
    fails=$((fails + 1))
  fi
  if ! awk -F'\t' '$2 == "X01" && $3 == 1 { found = 1 } END { exit !found }' "$outtsv"; then
    warn "selftest: claude fixture — expected X01 extra to be matched"
    fails=$((fails + 1))
  fi
  if awk -F'\t' '$2 == "X02" && $3 == 1 { found = 1 } END { exit !found }' "$outtsv"; then
    warn "selftest: claude fixture — did not expect X02 extra to be matched"
    fails=$((fails + 1))
  fi

  # Case 3: missing machine-readable block — the fallback warning path.
  outtsv="$tdir/compare-nomachine.tsv"
  : > "$outtsv"
  score_reviewer claude-nomachine "$EVAL_DIR/selftest/compare-claude-nomachine.md" "$mainkey" "$extraskey" "$outtsv" \
    > "$tdir/report-nomachine.txt" 2> "$tdir/warn-nomachine.txt"
  if [ -s "$outtsv" ]; then
    warn "selftest: no-machine-block fixture unexpectedly produced scored rows"
    fails=$((fails + 1))
  fi
  if ! grep -q 'no machine-readable block' "$tdir/warn-nomachine.txt"; then
    warn "selftest: no-machine-block fixture did not warn as expected"
    fails=$((fails + 1))
  fi

  # Case 4 (TASK-46): mechanism-aware scoring against a golden.tsv third
  # arg — adjacent-hit-via-mechanism (G01, diff-side anchor in a different
  # file), adjacent-miss (G02, no file/mechanism candidate), and the
  # deep-vs-shallow split for scope=diff+mechanism rows (G03 deep, G04
  # shallow). The mainkey below mirrors the golden ids/files/lines directly
  # (no markdown table needed for this synthetic fixture).
  local mechgolden="$EVAL_DIR/selftest/compare-mech-golden.tsv"
  local mechmain="$tdir/mech-mainkey.tsv" mechextras="$tdir/mech-extraskey.tsv"
  printf 'G01\tpkg/queue.py\t66\nG02\tpkg/other.py\t10\nG03\tpkg/deep.py\t14\nG04\tpkg/deep2.py\t32\n' > "$mechmain"
  : > "$mechextras"

  outtsv="$tdir/compare-mech.tsv"
  : > "$outtsv"
  score_reviewer mech "$EVAL_DIR/selftest/compare-mech-comment.md" "$mechmain" "$mechextras" "$outtsv" "$mechgolden" \
    > "$tdir/report-mech.txt"

  # seeded (file+line) hits stay exactly G03/G04 — adjacent rows never fold in.
  if [ "$(awk -F'\t' '$3 == 1' "$outtsv" | wc -l | tr -d ' ')" != 2 ]; then
    warn "selftest: mech fixture — expected exactly 2 seeded hits (G03/G04), adjacent rows must not fold in"
    fails=$((fails + 1))
  fi
  if ! grep -q '^  G01  HIT via pkg/worker.py:40$' "$tdir/report-mech.txt"; then
    warn "selftest: mech fixture — expected G01 adjacent hit via pkg/worker.py:40 (mechanism match, different file)"
    fails=$((fails + 1))
  fi
  if ! grep -q '^  G02  miss$' "$tdir/report-mech.txt"; then
    warn "selftest: mech fixture — expected G02 adjacent miss (no file/mechanism candidate)"
    fails=$((fails + 1))
  fi
  if ! grep -q '^  G03  pkg/deep.py:14  HIT (deep)$' "$tdir/report-mech.txt"; then
    warn "selftest: mech fixture — expected G03 deep hit"
    fails=$((fails + 1))
  fi
  if ! grep -q '^  G04  pkg/deep2.py:32  HIT (shallow)$' "$tdir/report-mech.txt"; then
    warn "selftest: mech fixture — expected G04 shallow hit (right line, wrong mechanism)"
    fails=$((fails + 1))
  fi
  if ! grep -q '^adjacent found 1/2 (mechanism-aware, not folded into seeded m/k)$' "$tdir/report-mech.txt"; then
    warn "selftest: mech fixture — expected adjacent summary line 'adjacent found 1/2'"
    fails=$((fails + 1))
  fi

  # Case 5 (TASK-46): no-golden-arg regression — calling score_reviewer
  # without the 6th arg on the SAME comment/mainkey must reproduce the
  # pre-TASK-46 output exactly (no deep/shallow tags, no adjacent block).
  outtsv="$tdir/compare-mech-nogolden.tsv"
  : > "$outtsv"
  score_reviewer mech-nogolden "$EVAL_DIR/selftest/compare-mech-comment.md" "$mechmain" "$mechextras" "$outtsv" \
    > "$tdir/report-mech-nogolden.txt"
  if ! grep -q '^  G03  pkg/deep.py:14  HIT$' "$tdir/report-mech-nogolden.txt"; then
    warn "selftest: no-golden-arg regression — expected untagged 'G03  pkg/deep.py:14  HIT' line"
    fails=$((fails + 1))
  fi
  if grep -q 'adjacent found' "$tdir/report-mech-nogolden.txt"; then
    warn "selftest: no-golden-arg regression — did not expect an adjacent block"
    fails=$((fails + 1))
  fi
  if grep -Eq '\(deep\)|\(shallow\)' "$tdir/report-mech-nogolden.txt"; then
    warn "selftest: no-golden-arg regression — did not expect deep/shallow tags"
    fails=$((fails + 1))
  fi

  [ "$fails" -eq 0 ] || die "selftest: $fails check(s) failed"
  ok "selftest: PASS (answer-key parsing, 7-col + 6-col TSV schemas, extras matching, missing-block path, mechanism-aware adjacent/deep scoring, no-golden-arg regression, no network)"
}

# --- main --------------------------------------------------------------------

mkdir -p "$WORK"

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit 0
fi

[ "$#" -ge 2 ] || die "usage: eval/compare.sh <pr-number> <answer-key.md> [<golden.tsv>]  (or: eval/compare.sh --selftest)"
need_cmd gh

PR="$1"
KEYFILE="$2"
GOLDENFILE="${3:-}"
[ -f "$KEYFILE" ] || die "answer key not found: $KEYFILE"
[ -z "$GOLDENFILE" ] || [ -f "$GOLDENFILE" ] || die "golden tsv not found: $GOLDENFILE"

REPO="${OR_REPO:-}"
if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
fi

MAINKEY="$WORK/key-main-$PR.tsv"
EXTRASKEY="$WORK/key-extras-$PR.tsv"
parse_answer_key "$KEYFILE" "$MAINKEY" "$EXTRASKEY"

ORBODY="$WORK/or-body-$PR.md"
CLBODY="$WORK/claude-body-$PR.md"
fetch_review_comments "$REPO" "$PR" "$ORBODY" "$CLBODY"

OUTTSV="$WORK/compare-$PR.tsv"
: > "$OUTTSV"

printf 'comparing %s#%s against %s\n' "$REPO" "$PR" "$KEYFILE"

if [ -s "$ORBODY" ]; then
  score_reviewer openreview "$ORBODY" "$MAINKEY" "$EXTRASKEY" "$OUTTSV" "$GOLDENFILE"
fi
if [ -s "$CLBODY" ]; then
  score_reviewer claude "$CLBODY" "$MAINKEY" "$EXTRASKEY" "$OUTTSV" "$GOLDENFILE"
fi

printf '\nmachine-readable output: %s\n' "$OUTTSV"
exit 0
