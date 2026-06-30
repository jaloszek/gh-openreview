#!/usr/bin/env bash
# Pre-fetch PR context into $SCRATCH so the opencode passes never need a token.
# Writes: pr.diff, pr-meta.json, prev-review.md. Uses inherited gh auth (local)
# or step-scoped GH_TOKEN (CI).
# Env: OR_REPO, OR_PR, SCRATCH, MARKER_MATCH,
#      OPENREVIEW_DIFF_EXCLUDE (ERE matched against each file's path; matching
#        files are dropped from the diff — lockfiles, generated, vendored, …),
#      OPENREVIEW_DIFF_MAX_LINES (truncate the diff to this many lines; 0 = off).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${OR_REPO:?OR_REPO required}"
: "${OR_PR:?OR_PR required}"
: "${SCRATCH:?SCRATCH required}"
# Exported so jq can read it via env.MARKER_MATCH — never string-interpolate a
# possibly-quote-bearing value into the jq filter.
export MARKER_MATCH="${MARKER_MATCH:-OpenCode Review}"

# Default path excludes: machine-generated / vendored / lockfile noise that
# inflates token cost without being meaningfully reviewable.
DEFAULT_EXCLUDE='(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|go\.sum|Cargo\.lock|composer\.lock|Gemfile\.lock|poetry\.lock|Pipfile\.lock)$|\.min\.(js|css)$|\.(snap|map)$|(^|/)(dist|build|vendor|node_modules|\.openreview-tmp)/|\.pb\.go$|_pb2\.py$|(^|/)generated/|\.generated\.'
DIFF_EXCLUDE="${OPENREVIEW_DIFF_EXCLUDE-$DEFAULT_EXCLUDE}"
DIFF_MAX_LINES="${OPENREVIEW_DIFF_MAX_LINES:-4000}"
# Guard against a non-numeric input crashing the `-gt` test under set -e.
case "$DIFF_MAX_LINES" in ""|*[!0-9]*) DIFF_MAX_LINES=4000 ;; esac

gh pr view "$OR_PR" --repo "$OR_REPO" --json title,body,files > "$SCRATCH/pr-meta.json"

# Full diff, then drop excluded files (whole `diff --git` blocks). Report what
# was dropped so coverage is never silently reduced.
RAW="$SCRATCH/.pr.diff.raw"
gh pr diff "$OR_PR" --repo "$OR_REPO" > "$RAW"
if [ -n "$DIFF_EXCLUDE" ]; then
  awk -v ex="$DIFF_EXCLUDE" '
    /^diff --git / {
      path=$0; sub(/^diff --git a\/.* b\//, "", path)
      emit = (path ~ ex) ? 0 : 1
      if (!emit) dropped[path]=1
    }
    emit { print }
    END { for (p in dropped) print p > "/dev/stderr" }
  ' "$RAW" > "$SCRATCH/pr.diff" 2> "$SCRATCH/.dropped"
  if [ -s "$SCRATCH/.dropped" ]; then
    ndrop=$(wc -l < "$SCRATCH/.dropped" | tr -d ' ')
    info "diff: excluded $ndrop generated/vendored file(s) from review"
    echo "::notice::openreview excluded $ndrop file(s) from the diff (generated/vendored/lockfiles)"
  fi
else
  cp "$RAW" "$SCRATCH/pr.diff"
fi
rm -f "$RAW" "$SCRATCH/.dropped"

# Truncate to a line budget so a huge PR can't produce an unbounded prompt.
if [ "$DIFF_MAX_LINES" -gt 0 ]; then
  total=$(wc -l < "$SCRATCH/pr.diff" | tr -d ' ')
  if [ "$total" -gt "$DIFF_MAX_LINES" ]; then
    head -n "$DIFF_MAX_LINES" "$SCRATCH/pr.diff" > "$SCRATCH/pr.diff.trunc"
    printf '\n[... diff truncated: %s of %s lines shown ...]\n' "$DIFF_MAX_LINES" "$total" >> "$SCRATCH/pr.diff.trunc"
    mv "$SCRATCH/pr.diff.trunc" "$SCRATCH/pr.diff"
    warn "diff truncated to $DIFF_MAX_LINES of $total lines"
    echo "::notice::openreview truncated the diff to $DIFF_MAX_LINES of $total lines"
  fi
fi

# Most recent prior review (matched by the marker substring, any author) so the
# reviewer can stay silent about findings since fixed. Empty on the first run.
gh api "repos/$OR_REPO/issues/$OR_PR/comments" --paginate \
  --jq '[.[] | select(.body | contains(env.MARKER_MATCH))] | (.[-1].body // "")' \
  > "$SCRATCH/prev-review.md" 2>/dev/null || true
[ -s "$SCRATCH/prev-review.md" ] || echo "(no previous review)" > "$SCRATCH/prev-review.md"

# --- Richer context: intent + existing discussion ----------------------------
# All of this is best-effort; a failure here must never abort the review.

# Commit messages on the branch — the author's stated intent per change.
gh pr view "$OR_PR" --repo "$OR_REPO" --json commits \
  --jq '.commits[] | "- \(.oid[0:7]) \(.messageHeadline)"' \
  > "$SCRATCH/pr-commits.md" 2>/dev/null || true
[ -s "$SCRATCH/pr-commits.md" ] || echo "(no commits found)" > "$SCRATCH/pr-commits.md"

# Linked issues this PR closes (the requirement). Parse close-keyword refs from
# the title+body, then fetch each issue's title+body (bounded to 5).
{
  gh pr view "$OR_PR" --repo "$OR_REPO" --json title,body --jq '.title, .body' 2>/dev/null \
    | grep -oiE '(clos(e|es|ed)|fix(es|ed)?|resolv(e|es|ed)) +#[0-9]+' \
    | grep -oE '[0-9]+' | sort -u | head -5 \
    | while IFS= read -r n; do
        [ -n "$n" ] || continue
        gh issue view "$n" --repo "$OR_REPO" --json number,title,body \
          --jq '"### #\(.number) \(.title)\n\(.body)\n"' 2>/dev/null || true
      done
} > "$SCRATCH/linked-issues.md" 2>/dev/null || true
[ -s "$SCRATCH/linked-issues.md" ] || echo "(no linked issues)" > "$SCRATCH/linked-issues.md"

# Existing discussion: inline review threads (with resolved state) + general
# comments. Lets the reviewer defer to humans, never repeat an open point, and
# never re-raise a thread a human already resolved.
OWNER="${OR_REPO%%/*}"; REPO="${OR_REPO##*/}"
{
  echo "## Inline review threads"
  gh api graphql -f query='
    query($owner:String!,$repo:String!,$pr:Int!){
      repository(owner:$owner,name:$repo){
        pullRequest(number:$pr){
          reviewThreads(first:100){ nodes{
            isResolved
            comments(first:1){ nodes{ author{login} path line body } }
          } }
        }
      }
    }' -F owner="$OWNER" -F repo="$REPO" -F pr="$OR_PR" \
    --jq '.data.repository.pullRequest.reviewThreads.nodes[]
          | "[\(if .isResolved then "RESOLVED" else "OPEN" end)] \(.comments.nodes[0].path // "?"):\(.comments.nodes[0].line // "?") — @\(.comments.nodes[0].author.login // "?"): \(.comments.nodes[0].body)"' \
    2>/dev/null || true
  echo ""
  echo "## General comments"
  gh api "repos/$OR_REPO/issues/$OR_PR/comments" --paginate \
    --jq '.[] | select(.body | contains(env.MARKER_MATCH) | not) | "@\(.user.login): \(.body)"' \
    2>/dev/null || true
} > "$SCRATCH/pr-comments.md" 2>/dev/null || true
[ -s "$SCRATCH/pr-comments.md" ] || echo "(no discussion yet)" > "$SCRATCH/pr-comments.md"

DIFF_LINES=$(wc -l < "$SCRATCH/pr.diff" | tr -d ' ')
echo "DIFF_LINES=$DIFF_LINES" >> "$SCRATCH/metrics.env"
info "context: $DIFF_LINES diff lines, $(wc -l < "$SCRATCH/prev-review.md" | tr -d ' ') prev-review lines"
