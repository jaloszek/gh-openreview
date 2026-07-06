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

# --- per-reviewer report ----------------------------------------------------

# score_reviewer <label> <comment.md> <mainkey.tsv> <extraskey.tsv> <outtsv>
# Prints the report to stdout; appends label \t id \t hit rows to <outtsv>.
# Returns 0 always — a missing/unparseable comment is a warning, not a
# failure.
score_reviewer() {
  local label="$1" commentfile="$2" mainkey="$3" extraskey="$4" outtsv="$5"
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

  nmain=$(wc -l < "$mainperbug" | tr -d ' ')
  nhit=$(awk -F'\t' '$2 == 1 { c++ } END { print c + 0 }' "$mainperbug")
  printf 'seeded found %s/%s\n' "$nhit" "$nmain"
  awk -F'\t' '{ printf "  %-4s %s:%s  %s\n", $1, $3, $4, ($2 == 1 ? "HIT" : "miss") }' "$mainperbug"

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

  [ "$fails" -eq 0 ] || die "selftest: $fails check(s) failed"
  ok "selftest: PASS (answer-key parsing, 7-col + 6-col TSV schemas, extras matching, missing-block path, no network)"
}

# --- main --------------------------------------------------------------------

mkdir -p "$WORK"

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit 0
fi

[ "$#" -ge 2 ] || die "usage: eval/compare.sh <pr-number> <answer-key.md>  (or: eval/compare.sh --selftest)"
need_cmd gh

PR="$1"
KEYFILE="$2"
[ -f "$KEYFILE" ] || die "answer key not found: $KEYFILE"

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
  score_reviewer openreview "$ORBODY" "$MAINKEY" "$EXTRASKEY" "$OUTTSV"
fi
if [ -s "$CLBODY" ]; then
  score_reviewer claude "$CLBODY" "$MAINKEY" "$EXTRASKEY" "$OUTTSV"
fi

printf '\nmachine-readable output: %s\n' "$OUTTSV"
exit 0
