#!/usr/bin/env bash
# Deterministic post step — never trusts the model output. Guarantees the marker
# header, posts one PR comment, then keeps only the latest comment that matches
# the marker AND was authored by the posting identity (the local user, or the
# bot in CI). Env: OR_REPO, OR_PR, SCRATCH, MARKER, MARKER_MATCH, [BOT_LOGIN].
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${OR_REPO:?}"; : "${OR_PR:?}"; : "${SCRATCH:?}"
MARKER="${MARKER:-## 🤖 OpenCode Review}"
MARKER_MATCH="${MARKER_MATCH:-OpenCode Review}"
REVIEW_FILE="$SCRATCH/opencode-review.md"

# Identity whose old comments we prune: explicit BOT_LOGIN (CI) or the auth'd user.
AUTHOR_LOGIN="${BOT_LOGIN:-$(gh api user --jq .login 2>/dev/null || echo '')}"

# Fall back to a minimal comment and guarantee the marker header is line 1.
if [ ! -s "$REVIEW_FILE" ]; then
  printf '%s\n\n_Automated review could not be generated this run._\n' "$MARKER" > "$REVIEW_FILE"
fi
if ! head -1 "$REVIEW_FILE" | grep -qF "$MARKER_MATCH"; then
  { printf '%s\n\n' "$MARKER"; cat "$REVIEW_FILE"; } > "$REVIEW_FILE.posted"
  mv "$REVIEW_FILE.posted" "$REVIEW_FILE"
fi

gh pr comment "$OR_PR" --repo "$OR_REPO" --body-file "$REVIEW_FILE"
ok "posted review to $OR_REPO#$OR_PR"

# Keep only the latest matching comment by this author (no notification noise:
# you/the bot are deleting your own comments).
if [ -n "$AUTHOR_LOGIN" ]; then
  IDS=()
  while IFS= read -r _id; do [ -n "$_id" ] && IDS+=("$_id"); done < <(
    gh api "repos/$OR_REPO/issues/$OR_PR/comments" --paginate \
      --jq ".[] | select(.user.login == \"$AUTHOR_LOGIN\") | select(.body | contains(\"$MARKER_MATCH\")) | .id")
  delete_count=$(( ${#IDS[@]} - 1 ))
  if [ "$delete_count" -gt 0 ]; then
    for ((i = 0; i < delete_count; i++)); do
      gh api "repos/$OR_REPO/issues/comments/${IDS[$i]}" -X DELETE >/dev/null 2>&1 \
        && info "removed stale review comment ${IDS[$i]}" \
        || warn "could not delete comment ${IDS[$i]}"
    done
  fi
fi
