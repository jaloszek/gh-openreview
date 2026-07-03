#!/usr/bin/env bash
# Deterministic post step — never trusts the model output. Edits the existing
# marker comment in place when one exists (no notification noise, no lost
# thread/permalink); creates one on the first run. Any *extra* stale marker
# comments beyond the one edited/created are pruned. Env: OR_REPO, OR_PR,
# SCRATCH, MARKER, MARKER_MATCH, [BOT_LOGIN], [OPENREVIEW_UPDATE_PING].
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${OR_REPO:?}"; : "${OR_PR:?}"; : "${SCRATCH:?}"
[ -f "$SCRATCH/skip-review" ] && { info "skipped (diff unchanged since last review)"; exit 0; }
MARKER="${MARKER:-## 🤖 OpenCode Review}"
export MARKER_MATCH="${MARKER_MATCH:-OpenCode Review}"
REVIEW_FILE="$SCRATCH/opencode-review.md"
BODY_MAX=60000

# Identity whose old comments we manage: explicit BOT_LOGIN (CI) or the auth'd
# user. Exported so jq reads it via env.AUTHOR_LOGIN (no string interpolation).
export AUTHOR_LOGIN="${BOT_LOGIN:-$(gh api user --jq .login 2>/dev/null || echo '')}"

# Fall back to a minimal comment and guarantee the marker header is line 1.
if [ ! -s "$REVIEW_FILE" ]; then
  printf '%s\n\n_Automated review could not be generated this run._\n' "$MARKER" > "$REVIEW_FILE"
fi
if ! head -1 "$REVIEW_FILE" | grep -qF "$MARKER_MATCH"; then
  { printf '%s\n\n' "$MARKER"; cat "$REVIEW_FILE"; } > "$REVIEW_FILE.posted"
  mv "$REVIEW_FILE.posted" "$REVIEW_FILE"
fi

# Head SHA the review was run against, for the "updated for commit" footer.
HEAD_SHA=$(gh pr view "$OR_PR" --repo "$OR_REPO" --json headRefOid --jq .headRefOid 2>/dev/null || echo '')
TS=$(date -u +'%Y-%m-%d %H:%M UTC')
if [ -n "$HEAD_SHA" ]; then
  printf '\n_Updated for commit %s at %s_\n' "${HEAD_SHA:0:7}" "$TS" >> "$REVIEW_FILE"
fi

# Hidden state block (incremental review, item G): embed as the LAST line so
# gather.sh can read back what SHA/patch-id this comment reviewed. Base64
# avoids `-->` and quoting issues; the JSON schema is versioned.
PATCH_ID=""
[ -f "$SCRATCH/patch-id" ] && PATCH_ID=$(cat "$SCRATCH/patch-id" 2>/dev/null || echo '')
if [ -n "$HEAD_SHA" ]; then
  STATE_JSON=$(printf '{"v":1,"last_sha":"%s","patch_id":"%s"}' "$HEAD_SHA" "$PATCH_ID")
  STATE_B64=$(printf '%s' "$STATE_JSON" | base64 | tr -d '\n')
  printf '\n<!-- openreview:state %s -->\n' "$STATE_B64" >> "$REVIEW_FILE"
fi

# Truncate deterministically — the API 422s past 65,536 chars; budget 60k.
if [ "$(wc -c < "$REVIEW_FILE" | tr -d ' ')" -gt "$BODY_MAX" ]; then
  head -c "$BODY_MAX" "$REVIEW_FILE" > "$REVIEW_FILE.trunc"
  printf '\n\n_[comment truncated]_\n' >> "$REVIEW_FILE.trunc"
  mv "$REVIEW_FILE.trunc" "$REVIEW_FILE"
  warn "review body exceeded ${BODY_MAX} chars; truncated"
fi

# Find every existing marker comment by AUTHOR_LOGIN, oldest first.
IDS=()
if [ -n "$AUTHOR_LOGIN" ]; then
  while IFS= read -r _id; do [ -n "$_id" ] && IDS+=("$_id"); done < <(
    gh api "repos/$OR_REPO/issues/$OR_PR/comments" --paginate \
      --jq '.[] | select(.user.login == env.AUTHOR_LOGIN) | select(.body | contains(env.MARKER_MATCH)) | .id')
fi

edited=false
if [ "${#IDS[@]}" -gt 0 ]; then
  # Edit the newest existing marker comment in place — no notification noise.
  target_id="${IDS[${#IDS[@]}-1]}"
  gh api "repos/$OR_REPO/issues/comments/$target_id" -X PATCH -F "body=@$REVIEW_FILE" >/dev/null
  ok "updated review comment $target_id on $OR_REPO#$OR_PR"
  edited=true
else
  gh pr comment "$OR_PR" --repo "$OR_REPO" --body-file "$REVIEW_FILE"
  ok "posted review to $OR_REPO#$OR_PR"
fi

# Prune extra duplicates: any marker comment other than the one just
# edited/created (relevant if a prior crashed run left more than one).
if [ "${#IDS[@]}" -gt 1 ]; then
  delete_count=$(( ${#IDS[@]} - 1 ))
  for ((i = 0; i < delete_count; i++)); do
    gh api "repos/$OR_REPO/issues/comments/${IDS[$i]}" -X DELETE >/dev/null 2>&1 \
      && info "removed stale review comment ${IDS[$i]}" \
      || warn "could not delete comment ${IDS[$i]}"
  done
fi

# Optional ping on updates with important findings — never marker-tagged, so
# it's pruned by the next run's own stale-ping cleanup below.
UPDATE_PING="${OPENREVIEW_UPDATE_PING:-false}"
n_important=0
# shellcheck disable=SC1091
[ -f "$SCRATCH/metrics.env" ] && . "$SCRATCH/metrics.env" 2>/dev/null || true
n_important="${OR_FINDINGS_IMPORTANT:-0}"

# Prune any stale ping comments from previous runs before deciding whether to
# post a new one (pings are unmarked, so match on our fixed ping prefix).
export PING_PREFIX="🔔 Review updated"
if [ -n "$AUTHOR_LOGIN" ]; then
  while IFS= read -r _pid; do
    [ -n "$_pid" ] || continue
    gh api "repos/$OR_REPO/issues/comments/$_pid" -X DELETE >/dev/null 2>&1 \
      && info "removed stale update-ping comment $_pid" \
      || warn "could not delete update-ping comment $_pid"
  done < <(
    gh api "repos/$OR_REPO/issues/$OR_PR/comments" --paginate \
      --jq '.[] | select(.user.login == env.AUTHOR_LOGIN) | select(.body | startswith(env.PING_PREFIX)) | .id')
fi

case "$n_important" in ''|*[!0-9]*) n_important=0 ;; esac
if [ "$UPDATE_PING" = "true" ] && [ "$edited" = "true" ] && [ "$n_important" -gt 0 ]; then
  gh pr comment "$OR_PR" --repo "$OR_REPO" \
    --body "${PING_PREFIX} — ${n_important} important finding(s); see the review comment above."
  info "posted update ping ($n_important important finding(s))"
fi
