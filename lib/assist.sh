#!/usr/bin/env bash
# `gh openreview assist <pr> [--summary] [--yes]` — help review SOMEONE ELSE's
# PR. Proposes NOVEL, human-voice inline comments grounded in the diff, deduped
# against everything people and bots have already said. Propose-then-confirm:
# nothing is posted until you approve (--yes to skip). Posts as YOU.
set -euo pipefail
# shellcheck source=common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

parse_common_flags "$@"
if [ "${#OR_ARGS[@]}" -gt 0 ]; then set -- "${OR_ARGS[@]}"; else set --; fi
need_cmd gh; need_opencode

OR_YES=0; SEL=""; MODE="inline"
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) OR_YES=1; shift ;;
    --summary) MODE="summary"; shift ;;
    --inline) MODE="inline"; shift ;;
    -h|--help) log "usage: gh openreview assist <pr> [--inline|--summary] [--yes]"; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) SEL="$1"; shift ;;
  esac
done

export OR_YES   # consumed by confirm() in common.sh
resolve_pr_target "$SEL"
resolve_dir; scratch_init; resolve_model
export OR_PR OR_REPO

# diff + meta
gh pr diff "$OR_PR" --repo "$OR_REPO" > "$SCRATCH/pr.diff" 2>/dev/null || die "could not fetch diff"
gh pr view "$OR_PR" --repo "$OR_REPO" --json title,body,files > "$SCRATCH/pr-meta.json" 2>/dev/null || true

# every existing comment (issue + inline + review bodies), human AND bot, so the
# model can avoid repeating anything already said.
{
  gh api "repos/$OR_REPO/issues/$OR_PR/comments" --paginate \
    --jq '.[] | "[\(.user.login)] \(.body)"' 2>/dev/null || true
  gh api "repos/$OR_REPO/pulls/$OR_PR/comments" --paginate \
    --jq '.[] | "[\(.user.login) @ \(.path):\(.line // .original_line // 0)] \(.body)"' 2>/dev/null || true
  gh api "repos/$OR_REPO/pulls/$OR_PR/reviews" --paginate \
    --jq '.[] | select((.body // "")!="") | "[\(.user.login) review] \(.body)"' 2>/dev/null || true
} > "$SCRATCH/existing-comments.md"
[ -s "$SCRATCH/existing-comments.md" ] || echo "(no existing comments)" > "$SCRATCH/existing-comments.md"

S="$SCRATCH_REL"
info "drafting human-voice suggestions for $OR_REPO#$OR_PR (model: $OR_MODEL)…"
oc_run "$OR_DIR" "You are helping a developer review a colleague's GitHub pull request. Propose thoughtful, NOVEL review comments in a natural, collegial human voice — the kind a senior teammate leaves: clarifying questions, concrete suggestions, edge cases worth checking, and genuine praise where due. NOT a terse severity audit.

Read with your read tool (relative paths): $S/pr.diff (the diff — comment ONLY on lines in it), $S/pr-meta.json (title/body/files), and $S/existing-comments.md (everything people and bots have ALREADY said).

Hard rules:
- NOVELTY: do NOT propose anything already raised in $S/existing-comments.md (by a human or a bot). If a point is already made, skip it.
- GROUNDING: every comment must target a real file and a line that appears in $S/pr.diff (prefer added/context lines on the new side of the diff).
- VOICE: write like a person, first person, conversational, concise. No severity emojis, no robotic templates.
- Be selective: only genuinely useful comments. Quality over quantity. A handful is fine; zero is fine.

Write your suggestions to $S/suggestions.txt with your write tool. For EACH suggestion output EXACTLY one block, nothing else:
@@ <n>
file: <path as in the diff>
line: <a line number on the NEW side of the diff>
comment: <your comment, on a SINGLE line>

If you have NO novel comments worth making, write exactly the single token NO_SUGGESTIONS.
Do not edit or commit tracked files." || warn "suggestion pass returned non-zero"

if [ ! -s "$SCRATCH/suggestions.txt" ] || grep -qxF 'NO_SUGGESTIONS' "$SCRATCH/suggestions.txt"; then
  ok "no novel comments to add — the existing discussion already covers it"
  exit 0
fi

# parse blocks into parallel arrays
SF=(); SL=(); SC=()
while IFS=$'\t' read -r f ln cm; do
  [ -n "$f" ] || continue
  SF+=("$f"); SL+=("$ln"); SC+=("$cm")
done < <(awk '
  /^@@ /      { if (f!="") print f"\t"ln"\t"cm; f="";ln="";cm=""; next }
  /^file:/    { f=$0;  sub(/^file:[ ]*/,"",f);     next }
  /^line:/    { ln=$0; sub(/^line:[ ]*/,"",ln);    next }
  /^comment:/ { cm=$0; sub(/^comment:[ ]*/,"",cm); next }
  END         { if (f!="") print f"\t"ln"\t"cm }
' "$SCRATCH/suggestions.txt")

M="${#SF[@]}"
[ "$M" -gt 0 ] || { ok "no parseable suggestions produced"; exit 0; }

# propose
log ""; log "Proposed comments for $OR_REPO#$OR_PR ($M):"; log ""
for ((i = 0; i < M; i++)); do
  printf '  %d. %s:%s\n     %s\n' "$((i+1))" "${SF[$i]}" "${SL[$i]}" "${SC[$i]}" >&2
done
log ""
confirm "Post these as a review on the PR (as you)?" || { warn "aborted — nothing posted"; exit 0; }

# apply
if [ "$MODE" = "summary" ]; then
  {
    echo "## Review notes"
    echo
    for ((i = 0; i < M; i++)); do
      printf -- '- **%s:%s** — %s\n' "${SF[$i]}" "${SL[$i]}" "${SC[$i]}"
    done
  } > "$SCRATCH/summary.md"
  gh pr comment "$OR_PR" --repo "$OR_REPO" --body-file "$SCRATCH/summary.md"
  ok "posted summary comment to $OR_REPO#$OR_PR"
  exit 0
fi

# inline: one review comment per suggestion (gh -f handles body escaping). Any
# that the API rejects (e.g. line not in diff) fall back into a summary comment.
head_sha="$(gh pr view "$OR_PR" --repo "$OR_REPO" --json headRefOid --jq .headRefOid)"
fallback=()
for ((i = 0; i < M; i++)); do
  if gh api "repos/$OR_REPO/pulls/$OR_PR/comments" \
       -f body="${SC[$i]}" -f commit_id="$head_sha" -f path="${SF[$i]}" \
       -F line="${SL[$i]}" -f side=RIGHT >/dev/null 2>&1; then
    ok "commented on ${SF[$i]}:${SL[$i]}"
  else
    warn "could not anchor on ${SF[$i]}:${SL[$i]} — moving to summary"
    fallback+=("$i")
  fi
done

if [ "${#fallback[@]}" -gt 0 ]; then
  {
    echo "## Additional review notes"
    echo
    for i in "${fallback[@]}"; do
      printf -- '- **%s:%s** — %s\n' "${SF[$i]}" "${SL[$i]}" "${SC[$i]}"
    done
  } > "$SCRATCH/summary.md"
  gh pr comment "$OR_PR" --repo "$OR_REPO" --body-file "$SCRATCH/summary.md"
  info "posted ${#fallback[@]} un-anchorable note(s) as a summary comment"
fi
