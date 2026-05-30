#!/usr/bin/env bash
# Pre-fetch PR context into $SCRATCH so the opencode passes never need a token.
# Writes: pr.diff, pr-meta.json, prev-review.md. Uses inherited gh auth (local)
# or step-scoped GH_TOKEN (CI). Env: OR_REPO, OR_PR, SCRATCH, MARKER_MATCH.
set -euo pipefail
# shellcheck source=common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${OR_REPO:?OR_REPO required}"
: "${OR_PR:?OR_PR required}"
: "${SCRATCH:?SCRATCH required}"
MARKER_MATCH="${MARKER_MATCH:-OpenCode Review}"

gh pr view "$OR_PR" --repo "$OR_REPO" --json title,body,files > "$SCRATCH/pr-meta.json"
gh pr diff "$OR_PR" --repo "$OR_REPO" > "$SCRATCH/pr.diff"

# Most recent prior review (matched by the marker substring, any author) so the
# reviewer can stay silent about findings since fixed. Empty on the first run.
gh api "repos/$OR_REPO/issues/$OR_PR/comments" --paginate \
  --jq "[.[] | select(.body | contains(\"$MARKER_MATCH\"))] | (.[-1].body // \"\")" \
  > "$SCRATCH/prev-review.md" 2>/dev/null || true
[ -s "$SCRATCH/prev-review.md" ] || echo "(no previous review)" > "$SCRATCH/prev-review.md"

info "context: $(wc -l < "$SCRATCH/pr.diff" | tr -d ' ') diff lines, $(wc -l < "$SCRATCH/prev-review.md" | tr -d ' ') prev-review lines"
