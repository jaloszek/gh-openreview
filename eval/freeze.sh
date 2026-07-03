#!/usr/bin/env bash
# eval/freeze.sh — regenerate a fixture's derived context files from its
# pr.diff: commentable-lines.tsv and pr-numbered.diff. The two awk transforms
# are copied VERBATIM from lib/gather.sh so fixtures always match the exact
# shapes the real gather step produces. Re-run this after editing any
# fixture's pr.diff (and re-check eval/golden/*.tsv line numbers afterwards).
#
# Usage: eval/freeze.sh <fixture-dir> [<fixture-dir> ...]
set -euo pipefail

EVAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$EVAL_DIR/../lib/common.sh"

[ "$#" -ge 1 ] || die "usage: eval/freeze.sh <fixture-dir> [...]"

for dir in "$@"; do
  [ -f "$dir/pr.diff" ] || die "no pr.diff in $dir"

  # --- copied verbatim from lib/gather.sh: commentable-lines.tsv ------------
  # every new-file line (added or context) present in any hunk of the diff.
  awk '
    /^diff --git / { path=$0; sub(/^diff --git a\//,"",path); sub(/ b\/.*$/,"",path); next }
    /^(---|\+\+\+)/ { next }
    /^@@/ { match($0, /\+[0-9]+/); newno = substr($0, RSTART+1, RLENGTH-1) + 0; next }
    /^\+/ { if (path != "") { print path "\t" newno }; newno++; next }
    /^-/  { next }
    /^ /  { if (path != "") { print path "\t" newno }; newno++; next }
  ' "$dir/pr.diff" > "$dir/commentable-lines.tsv"

  # --- copied verbatim from lib/gather.sh: pr-numbered.diff ----------------
  # same diff --git / @@ structure, every unchanged/added line prefixed with
  # its new-file line number in a fixed 6-char column followed by "| ".
  awk '
    /^diff --git / { print; next }
    /^(---|\+\+\+|index |new file mode|deleted file mode|similarity index|rename |old mode|new mode|Binary files)/ { print; next }
    /^@@/ { match($0, /\+[0-9]+/); newno = substr($0, RSTART+1, RLENGTH-1) + 0; print; next }
    /^\\/ { printf "      | %s\n", $0; next }
    /^\+/ { printf "%6d| %s\n", newno, $0; newno++; next }
    /^-/  { printf "      | %s\n", $0; next }
    /^ /  { printf "%6d| %s\n", newno, $0; newno++; next }
    { print }
  ' "$dir/pr.diff" > "$dir/pr-numbered.diff"

  ok "froze $(basename "$dir"): $(wc -l < "$dir/commentable-lines.tsv" | tr -d ' ') commentable lines"
done

# --- tree/ consistency check ------------------------------------------------
# For every hunk's new-side (added/context) lines, the tree/ copy of that file
# must have byte-identical content at the matching line offsets. Catches a
# tree/ file that has drifted from pr.diff (stale edit, wrong base, etc).
# Skips files with no tree/ (nothing to check) and deleted files (no new side).
check_tree_consistency() {
  local dir="$1" fails=0
  [ -d "$dir/tree" ] || { ok "check-tree $(basename "$dir"): no tree/, nothing to check"; return 0; }

  local path newfile newno actual content
  path=""
  newno=0
  while IFS= read -r line; do
    case "$line" in
      "diff --git "*)
        path="${line#diff --git a/}"
        path="${path%% b/*}"
        ;;
      "---"*|"+++"*) : ;;
      "@@"*)
        newno=$(printf '%s' "$line" | sed -n 's/.*+\([0-9][0-9]*\).*/\1/p')
        ;;
      "+"*)
        [ -n "$path" ] || continue
        newfile="$dir/tree/$path"
        content="${line#+}"
        if [ ! -f "$newfile" ]; then
          warn "✗ tree mismatch: $path — no tree/ copy (needed for hunk at line $newno)"
          fails=$((fails + 1))
        else
          actual=$(sed -n "${newno}p" "$newfile")
          if [ "$actual" != "$content" ]; then
            warn "✗ tree mismatch: $path:$newno"
            warn "    diff says: $content"
            warn "    tree has:  $actual"
            fails=$((fails + 1))
          fi
        fi
        newno=$((newno + 1))
        ;;
      "-"*) : ;;
      " "*)
        [ -n "$path" ] || continue
        newfile="$dir/tree/$path"
        content="${line# }"
        if [ ! -f "$newfile" ]; then
          warn "✗ tree mismatch: $path — no tree/ copy (needed for hunk at line $newno)"
          fails=$((fails + 1))
        else
          actual=$(sed -n "${newno}p" "$newfile")
          if [ "$actual" != "$content" ]; then
            warn "✗ tree mismatch: $path:$newno"
            warn "    diff says: $content"
            warn "    tree has:  $actual"
            fails=$((fails + 1))
          fi
        fi
        newno=$((newno + 1))
        ;;
    esac
  done < "$dir/pr.diff"

  if [ "$fails" -ne 0 ]; then
    die "check-tree $(basename "$dir"): $fails mismatch(es) between pr.diff and tree/"
  fi
  ok "check-tree $(basename "$dir"): tree/ matches pr.diff at every hunk"
}

for dir in "$@"; do
  check_tree_consistency "$dir"
done
