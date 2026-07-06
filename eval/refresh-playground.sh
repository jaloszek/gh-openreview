#!/usr/bin/env bash
# Refresh the live-playground base/head branches so the head branch's review
# engine matches main, while eval/ and docs/ (answer-key material) never
# survive into either branch's tree. Replaces the manual recipe documented
# in eval/README.md ("Live playground PR" section).
#
# Operates on the repo of the CURRENT WORKING DIRECTORY, not the directory
# this script lives in — run it with cwd inside the repo/clone to refresh.
# That is what lets tests point it at a throwaway file:// clone: cd into
# the clone, then invoke this script (by absolute path or PATH lookup).

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$script_dir/../lib/common.sh"

usage() {
  cat <<'EOF' >&2
Usage: eval/refresh-playground.sh <base-branch> <head-branch>

Run with cwd inside the repo/clone to refresh. Fetches origin, merges main
into <base-branch>, strips eval/ + docs/ + PROVENANCE.md (answer-key
material) whether the merge was clean or conflicted, then merges
<base-branch> into <head-branch> the same way. Pushes both branches
(never force), never touches main, and always restores the branch that
was checked out when the script started.

Example: eval/refresh-playground.sh eval/live-hard-base eval/live-hard
EOF
  exit 1
}

[ "$#" -eq 2 ] || usage
base_branch="$1"
head_branch="$2"

need_cmd git

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
cd "$repo_root" || die "could not cd to repo root: $repo_root"

[ -z "$(git status --porcelain)" ] || die "working tree is dirty — commit or stash before refreshing"

start_branch="$(git rev-parse --abbrev-ref HEAD)"
restore_start_branch() {
  local rc=$?
  git checkout -q "$start_branch" >/dev/null 2>&1 || warn "could not restore starting branch: $start_branch"
  exit "$rc"
}
trap restore_start_branch EXIT

info "fetching origin…"
git fetch --quiet origin

for b in "$base_branch" "$head_branch" main; do
  git show-ref --verify --quiet "refs/remotes/origin/$b" || die "branch missing on origin: $b"
done

strip_answer_key_material() {
  git rm -rf --ignore-unmatch eval docs PROVENANCE.md >/dev/null
}

verify_no_answer_key_material() {
  if [ -e eval ] || [ -e docs ] || [ -e PROVENANCE.md ]; then
    die "eval/, docs/ or PROVENANCE.md would remain in the tree — aborting before push"
  fi
}

# refresh_branch <branch> <merge-ref>: checkout -B <branch> origin/<branch>,
# merge <merge-ref>, strip eval/docs/PROVENANCE.md whether the merge landed
# clean or conflicted, verify no unmerged paths and no answer-key material
# remain (abort the merge and die otherwise), commit if the strip left
# anything to commit, push (never force). Prints the pushed SHA on stdout —
# the only stdout this function produces.
refresh_branch() {
  local branch="$1" merge_ref="$2" merge_rc=0 git_dir

  info "checking out $branch from origin/${branch}…"
  git checkout -q -B "$branch" "origin/$branch"

  info "merging $merge_ref into ${branch}…"
  git merge --no-edit "$merge_ref" >/dev/null 2>&1 || merge_rc=$?
  if [ "$merge_rc" -ne 0 ]; then
    warn "merge of $merge_ref into $branch hit conflicts — stripping eval/docs and re-checking"
  fi

  info "stripping eval/docs/PROVENANCE.md…"
  strip_answer_key_material

  if [ -n "$(git ls-files -u)" ]; then
    git merge --abort 2>/dev/null || true
    die "$branch has unresolved conflicts outside eval/docs/PROVENANCE.md — resolve manually and re-run"
  fi

  verify_no_answer_key_material

  git_dir="$(git rev-parse --git-dir)"
  if [ -f "$git_dir/MERGE_HEAD" ]; then
    git commit --no-edit -q
  elif [ -n "$(git status --porcelain)" ]; then
    git commit -q -m "chore: strip eval/docs from $branch"
  fi

  info "pushing ${branch}…"
  git push --no-force origin "HEAD:refs/heads/$branch" >/dev/null

  git rev-parse HEAD
}

base_sha="$(refresh_branch "$base_branch" "origin/main")"
head_sha="$(refresh_branch "$head_branch" "$base_branch")"

ok "playground refreshed"
printf '%s %s\n' "$base_branch" "$base_sha"
printf '%s %s\n' "$head_branch" "$head_sha"
