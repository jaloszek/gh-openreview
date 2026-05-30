#!/usr/bin/env bash
# `gh openreview resolve [<pr>] [--yes]` — reconcile YOUR PR's open review
# threads against recent commits. For each thread the model decides:
#   RESOLVE — a later commit addressed it (we reply citing it, then resolve)
#   REPLY   — won't address (we post a short rationale, leave it open)
#   SKIP    — unclear / needs a human (we do nothing)
# Propose-then-confirm: nothing is posted until you approve (--yes to skip).
set -euo pipefail
# shellcheck source=common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

parse_common_flags "$@"
if [ "${#OR_ARGS[@]}" -gt 0 ]; then set -- "${OR_ARGS[@]}"; else set --; fi
need_cmd gh; need_opencode

OR_YES=0; SEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) OR_YES=1; shift ;;
    -h|--help) log "usage: gh openreview resolve [<pr>] [--yes] [--model <id>]"; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) SEL="$1"; shift ;;
  esac
done

export OR_YES   # consumed by confirm() in common.sh
resolve_pr_target "$SEL"
OWNER="${OR_REPO%%/*}"; NAME="${OR_REPO#*/}"
resolve_dir; scratch_init
resolve_model

# --- fetch unresolved review threads as TSV (via gh's embedded jq) -----------
read -r -d '' QUERY <<'GQL' || true
query($owner:String!,$name:String!,$number:Int!){
  repository(owner:$owner,name:$name){
    pullRequest(number:$number){
      reviewThreads(first:100){
        nodes{
          id isResolved isOutdated path line
          comments(first:50){ nodes{ author{login} body } }
        }
      }
    }
  }
}
GQL

gh api graphql -f query="$QUERY" -f owner="$OWNER" -f name="$NAME" -F number="$OR_PR" \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[]
        | select(.isResolved==false)
        | [ .id, (.isOutdated|tostring), (.path // ""), ((.line // 0)|tostring),
            (.comments.nodes[0].author.login // "?"),
            ([.comments.nodes[].body]|join("  ▸  ")) ] | @tsv' \
  > "$SCRATCH/threads.tsv" 2>/dev/null || die "failed to fetch review threads"

TID=(); TOUT=(); TPATH=(); TLINE=(); TAUTHOR=(); TBODY=()
while IFS=$'\t' read -r id outdated path line author body; do
  [ -n "$id" ] || continue
  TID+=("$id"); TOUT+=("$outdated"); TPATH+=("$path"); TLINE+=("$line"); TAUTHOR+=("$author"); TBODY+=("$body")
done < "$SCRATCH/threads.tsv"

N="${#TID[@]}"
[ "$N" -gt 0 ] || { ok "no open review threads to reconcile on $OR_REPO#$OR_PR"; exit 0; }
info "$N open thread(s) on $OR_REPO#$OR_PR"

# --- evidence: current diff + recent commits ---------------------------------
gh pr diff "$OR_PR" --repo "$OR_REPO" > "$SCRATCH/pr.diff" 2>/dev/null || true
gh pr view "$OR_PR" --repo "$OR_REPO" --json commits \
  --jq '.commits[] | "\(.oid[0:9])  \(.messageHeadline)"' > "$SCRATCH/commits.txt" 2>/dev/null || true

# --- threads file the model reads (0-based INDEX is the join key) ------------
: > "$SCRATCH/threads.md"
for ((i = 0; i < N; i++)); do
  {
    printf '@@ %d\n' "$i"
    printf 'file: %s:%s   outdated_since_comment: %s   author: %s\n' \
      "${TPATH[$i]}" "${TLINE[$i]}" "${TOUT[$i]}" "${TAUTHOR[$i]}"
    printf 'comment(s): %s\n\n' "${TBODY[$i]}"
  } >> "$SCRATCH/threads.md"
done

S="$SCRATCH_REL"
info "judging threads against commit history (model: $OR_MODEL)…"
oc_run "$OR_DIR" "You are helping a developer reconcile open review threads on their own pull request after they pushed fixes.

Read with your read tool (relative paths): $S/threads.md (the open threads, each starting with '@@ INDEX'), $S/pr.diff (the CURRENT cumulative diff), and $S/commits.txt (commit headlines on the PR). 'outdated_since_comment: true' means the code under the comment changed after the comment was written — a strong hint it may be addressed.

For EACH thread decide one of:
- RESOLVE — the current diff/commits clearly ADDRESS the comment. Be conservative: only when you can see it was handled.
- REPLY — it will NOT be addressed; give a short, polite rationale a maintainer could post.
- SKIP — unclear or needs a human; do nothing.

Write your plan to $S/resolve-plan.txt with your write tool. For each thread output EXACTLY one block, in INDEX order, nothing else:
@@ <INDEX>
decision: RESOLVE
reply: <one single-line message — for RESOLVE cite what addressed it (e.g. 'Done in <commit/file>'); for REPLY the rationale; for SKIP leave empty>

Keep each reply on ONE line. Do not invent commits. Do not edit or commit tracked files." || warn "judgment pass returned non-zero"

[ -s "$SCRATCH/resolve-plan.txt" ] || die "model produced no plan"

# --- parse plan into DEC[index]/REP[index] -----------------------------------
DEC=(); REP=()
while IFS=$'\t' read -r idx dec rep; do
  [ -n "$idx" ] || continue
  dec="$(printf '%s' "$dec" | tr '[:lower:]' '[:upper:]' | tr -dc 'A-Z')"
  DEC[$idx]="$dec"; REP[$idx]="$rep"
done < <(awk '
  /^@@ /        { if (idx!="") print idx"\t"dec"\t"rep; idx=$2; dec=""; rep=""; next }
  /^decision:/  { dec=$0; sub(/^decision:[ ]*/,"",dec); next }
  /^reply:/     { rep=$0; sub(/^reply:[ ]*/,"",rep); next }
  END           { if (idx!="") print idx"\t"dec"\t"rep }
' "$SCRATCH/resolve-plan.txt")

# --- propose -----------------------------------------------------------------
log ""; log "Proposed reconciliation for $OR_REPO#$OR_PR:"; log ""
n_resolve=0; n_reply=0; n_skip=0
for ((i = 0; i < N; i++)); do
  d="${DEC[$i]:-SKIP}"; r="${REP[$i]:-}"
  case "$d" in
    RESOLVE) icon="✅ RESOLVE"; n_resolve=$((n_resolve+1)) ;;
    REPLY)   icon="💬 REPLY  "; n_reply=$((n_reply+1)) ;;
    *)       d="SKIP"; icon="·  SKIP   "; n_skip=$((n_skip+1)) ;;
  esac
  printf '  %s  %s:%s  (@%s)\n' "$icon" "${TPATH[$i]}" "${TLINE[$i]}" "${TAUTHOR[$i]}" >&2
  [ -n "$r" ] && printf '              ↳ %s\n' "$r" >&2
done
log ""
info "plan: $n_resolve resolve · $n_reply reply · $n_skip skip"

if [ $((n_resolve + n_reply)) -eq 0 ]; then ok "nothing to apply"; exit 0; fi
confirm "Apply this plan to the PR?" || { warn "aborted — nothing posted"; exit 0; }

# --- apply -------------------------------------------------------------------
reply_mut='mutation($tid:ID!,$body:String!){ addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$tid, body:$body}){ comment{ id } } }'
resolve_mut='mutation($tid:ID!){ resolveReviewThread(input:{threadId:$tid}){ thread{ id isResolved } } }'

for ((i = 0; i < N; i++)); do
  d="${DEC[$i]:-SKIP}"; r="${REP[$i]:-}"; tid="${TID[$i]}"
  case "$d" in
    RESOLVE)
      [ -n "$r" ] && gh api graphql -f query="$reply_mut" -f tid="$tid" -f body="$r" >/dev/null 2>&1 || true
      if gh api graphql -f query="$resolve_mut" -f tid="$tid" >/dev/null 2>&1; then
        ok "resolved ${TPATH[$i]}:${TLINE[$i]}"
      else warn "failed to resolve ${TPATH[$i]}:${TLINE[$i]}"; fi
      ;;
    REPLY)
      if [ -n "$r" ] && gh api graphql -f query="$reply_mut" -f tid="$tid" -f body="$r" >/dev/null 2>&1; then
        ok "replied on ${TPATH[$i]}:${TLINE[$i]}"
      else warn "failed to reply on ${TPATH[$i]}:${TLINE[$i]}"; fi
      ;;
  esac
done
