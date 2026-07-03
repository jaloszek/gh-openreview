#!/usr/bin/env bash
# Pre-fetch PR context into $SCRATCH so the opencode passes never need a token.
# Writes: pr.diff, pr-numbered.diff, commentable-lines.tsv, pr-meta.json,
# prev-review.md. Uses inherited gh auth (local) or step-scoped GH_TOKEN (CI).
# Env: OR_REPO, OR_PR, SCRATCH, MARKER_MATCH,
#      OPENREVIEW_DIFF_EXCLUDE (ERE matched against each file's path; matching
#        files are dropped from the diff — lockfiles, generated, vendored, …),
#      OPENREVIEW_DIFF_MAX_LINES (truncate the diff to this many lines; 0 = off),
#      OPENREVIEW_RESTART (1/true forces a full review: ignores previous state,
#        never writes the skip sentinel, forces prev-review.md to the
#        placeholder, produces no incremental files).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

: "${OR_REPO:?OR_REPO required}"
: "${OR_PR:?OR_PR required}"
: "${SCRATCH:?SCRATCH required}"
OR_DIR="${OR_DIR:-$PWD}"
# Exported so jq can read it via env.MARKER_MATCH — never string-interpolate a
# possibly-quote-bearing value into the jq filter.
export MARKER_MATCH="${MARKER_MATCH:-OpenCode Review}"

case "${OPENREVIEW_RESTART:-}" in
  1|true|TRUE|True) RESTART=1 ;;
  *) RESTART=0 ;;
esac

# Engine fingerprint: hashes lib/passes.sh + the resolved main/verify models
# so a PROMPT/MODEL change invalidates the skip guard even when the diff
# didn't change. Written to $SCRATCH for post.sh to embed in the state block.
resolve_model
resolve_verify_model
CURRENT_FP=$(engine_fingerprint)
printf '%s' "$CURRENT_FP" > "$SCRATCH/engine-fp"

# Default path excludes: machine-generated / vendored / lockfile noise that
# inflates token cost without being meaningfully reviewable.
DEFAULT_EXCLUDE='(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|go\.sum|Cargo\.lock|composer\.lock|Gemfile\.lock|poetry\.lock|Pipfile\.lock)$|\.min\.(js|css)$|\.(snap|map)$|(^|/)(dist|build|vendor|node_modules|\.openreview-tmp)/|\.pb\.go$|_pb2\.py$|(^|/)generated/|\.generated\.'
DIFF_EXCLUDE="${OPENREVIEW_DIFF_EXCLUDE-$DEFAULT_EXCLUDE}"
DIFF_MAX_LINES="${OPENREVIEW_DIFF_MAX_LINES:-4000}"
# Guard against a non-numeric input crashing the `-gt` test under set -e.
case "$DIFF_MAX_LINES" in ""|*[!0-9]*) DIFF_MAX_LINES=4000 ;; esac

gh pr view "$OR_PR" --repo "$OR_REPO" --json title,body,files,baseRefOid,headRefOid > "$SCRATCH/pr-meta.json"

# --- Incremental review (item G): patch-id + previous-state read -------------
# Most recent prior review comment (matched by the marker substring, any
# author) — also fetched here (rather than only later for prev-review.md) so
# its hidden state block can gate the rest of this run.
BASE_SHA=$(gh pr view "$OR_PR" --repo "$OR_REPO" --json baseRefOid --jq .baseRefOid 2>/dev/null || echo '')
HEAD_SHA=$(git -C "$OR_DIR" rev-parse HEAD 2>/dev/null || echo '')

PREV_COMMENT_RAW="$SCRATCH/.prev-comment-raw.md"
gh api "repos/$OR_REPO/issues/$OR_PR/comments" --paginate \
  --jq '[.[] | select(.body | contains(env.MARKER_MATCH))] | (.[-1].body // "")' \
  > "$PREV_COMMENT_RAW" 2>/dev/null || true

# Parse the hidden state block: `<!-- openreview:state <base64> -->` encoding
# `{"v":1,"last_sha":"...","patch_id":"...","fp":"..."}`. Tolerate
# absence/garbage as "no state". Normalize CRLF first (human web edits
# introduce it). Restart mode skips this entirely — the run must not be
# gated by (or trust) anything from the previous review.
LAST_SHA=""
PREV_PATCH_ID=""
PREV_FP=""
if [ "$RESTART" -eq 1 ]; then
  info "restart requested — ignoring previous review state"
elif [ -s "$PREV_COMMENT_RAW" ]; then
  STATE_B64=$(tr -d '\r' < "$PREV_COMMENT_RAW" \
    | grep -oE 'openreview:state [A-Za-z0-9+/=]+' | tail -1 \
    | sed -E 's/^openreview:state //' || true)
  if [ -n "$STATE_B64" ]; then
    STATE_JSON=$(printf '%s' "$STATE_B64" | base64 -d 2>/dev/null || true)
    if [ -n "$STATE_JSON" ]; then
      LAST_SHA=$(printf '%s' "$STATE_JSON" | sed -n 's/.*"last_sha"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      PREV_PATCH_ID=$(printf '%s' "$STATE_JSON" | sed -n 's/.*"patch_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      PREV_FP=$(printf '%s' "$STATE_JSON" | sed -n 's/.*"fp"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    fi
  fi
fi

# Current patch-id: stable across offset-shifting rebases, invariant to line
# numbers/whitespace. Computed from the merge-base so an already-merged base
# update doesn't spuriously change it.
if [ -n "$BASE_SHA" ] && git -C "$OR_DIR" cat-file -e "$BASE_SHA" 2>/dev/null; then
  MERGE_BASE=$(git -C "$OR_DIR" merge-base "$BASE_SHA" HEAD 2>/dev/null || echo '')
  if [ -n "$MERGE_BASE" ]; then
    git -C "$OR_DIR" diff "$MERGE_BASE" HEAD 2>/dev/null | git -C "$OR_DIR" patch-id --stable 2>/dev/null | awk '{print $1}' > "$SCRATCH/patch-id" || true
  fi
fi
[ -s "$SCRATCH/patch-id" ] || : > "$SCRATCH/patch-id"
CURRENT_PATCH_ID=$(cat "$SCRATCH/patch-id" 2>/dev/null || echo '')

# Skip-if-identical: fires only when BOTH the patch-id AND the engine
# fingerprint match the last reviewed run -> no-op the rest of the pipeline
# (passes/render/metrics/post all check for this sentinel). A missing fp in
# old state (pre-TASK-22 comments) counts as a mismatch, not a match. Restart
# bypasses this unconditionally, regardless of what would otherwise match.
if [ "$RESTART" -ne 1 ] && [ -n "$PREV_PATCH_ID" ] && [ -n "$CURRENT_PATCH_ID" ]; then
  if [ "$PREV_PATCH_ID" != "$CURRENT_PATCH_ID" ]; then
    info "skip guard bypassed: diff changed (patch-id $PREV_PATCH_ID -> $CURRENT_PATCH_ID)"
  elif [ -z "$PREV_FP" ] || [ "$PREV_FP" != "$CURRENT_FP" ]; then
    info "skip guard bypassed: engine changed (fp ${PREV_FP:-<none>} -> $CURRENT_FP)"
  else
    echo "SKIP_REVIEW=1" >> "$SCRATCH/metrics.env"
    echo "::notice::diff and engine unchanged since last review — skipping"
    : > "$SCRATCH/skip-review"
    ok "diff and engine unchanged since last review (patch-id $CURRENT_PATCH_ID, fp $CURRENT_FP) — skipping"
    exit 0
  fi
fi

# Incremental diff: only when the previous SHA is still a reachable ancestor
# of HEAD (ancestry failure = force-push/rebase -> fall back silently to a
# full review, no incremental files).
if [ -n "$LAST_SHA" ] && [ "$LAST_SHA" != "$HEAD_SHA" ] \
  && git -C "$OR_DIR" cat-file -e "$LAST_SHA" 2>/dev/null \
  && git -C "$OR_DIR" merge-base --is-ancestor "$LAST_SHA" HEAD 2>/dev/null; then
  git -C "$OR_DIR" diff "$LAST_SHA..HEAD" > "$SCRATCH/.pr-incremental.raw" 2>/dev/null || true
  if [ -n "$DIFF_EXCLUDE" ] && [ -s "$SCRATCH/.pr-incremental.raw" ]; then
    awk -v ex="$DIFF_EXCLUDE" '
      /^diff --git / {
        path=$0; sub(/^diff --git a\/.* b\//, "", path)
        emit = (path ~ ex) ? 0 : 1
      }
      emit { print }
    ' "$SCRATCH/.pr-incremental.raw" > "$SCRATCH/pr-incremental.diff"
  else
    cp "$SCRATCH/.pr-incremental.raw" "$SCRATCH/pr-incremental.diff" 2>/dev/null || : > "$SCRATCH/pr-incremental.diff"
  fi
  rm -f "$SCRATCH/.pr-incremental.raw"
  printf 'This PR was previously reviewed at %s. pr-incremental.diff contains only the changes since then — focus your review there; the full diff is still in pr-numbered.diff for context.\n' "$LAST_SHA" > "$SCRATCH/incremental-note.md"
  info "incremental review: diffing since $LAST_SHA"
else
  rm -f "$SCRATCH/pr-incremental.diff" "$SCRATCH/incremental-note.md"
fi

# Full diff, then drop excluded files (whole `diff --git` blocks). Report what
# was dropped so coverage is never silently reduced.
RAW="$SCRATCH/.pr.diff.raw"
gh pr diff "$OR_PR" --repo "$OR_REPO" > "$RAW"

# commentable-lines.tsv: every new-file line (added or context) present in any
# hunk of the UNTRIMMED diff — i.e. before exclude/max-lines trimming, so
# validation in render.sh isn't fooled by a line that got trimmed away.
awk '
  /^diff --git / { path=$0; sub(/^diff --git a\//,"",path); sub(/ b\/.*$/,"",path); next }
  /^(---|\+\+\+)/ { next }
  /^@@/ { match($0, /\+[0-9]+/); newno = substr($0, RSTART+1, RLENGTH-1) + 0; next }
  /^\+/ { if (path != "") { print path "\t" newno }; newno++; next }
  /^-/  { next }
  /^ /  { if (path != "") { print path "\t" newno }; newno++; next }
' "$RAW" > "$SCRATCH/commentable-lines.tsv"

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

# Compression ladder so a huge PR can't produce an unbounded prompt, but
# (unlike a blunt `head`) never cuts a file's patch mid-way:
#   1. strip deletion-only hunks; fully-deleted files become a name-only entry
#   2. rank remaining file-patches: source files first, then by size desc
#   3. greedily add whole file-patches until the line budget
#   4. list every file that didn't fit, with its +/- counts
if [ "$DIFF_MAX_LINES" -gt 0 ]; then
  total=$(wc -l < "$SCRATCH/pr.diff" | tr -d ' ')
  if [ "$total" -gt "$DIFF_MAX_LINES" ]; then
    CDIR="$SCRATCH/.diff-compress"
    rm -rf "$CDIR"; mkdir -p "$CDIR"

    # One file per `diff --git` block, in original order.
    awk -v dir="$CDIR" '
      /^diff --git / { n++; fname = sprintf("%s/%04d.patch", dir, n) }
      n>0 { print > fname }
    ' "$SCRATCH/pr.diff"

    NON_SOURCE_EXT='\.(md|markdown|txt|json|ya?ml|toml|csv|rst|adoc)$'
    manifest="$CDIR/manifest.tsv"
    : > "$manifest"
    ndeleted=0
    : > "$CDIR/deleted.list"

    for f in "$CDIR"/*.patch; do
      [ -e "$f" ] || continue
      path=$(head -1 "$f" | sed -E 's#^diff --git a/(.*) b/.*#\1#')

      if grep -q '^deleted file mode' "$f"; then
        echo "- $path" >> "$CDIR/deleted.list"
        ndeleted=$((ndeleted + 1))
        rm -f "$f"
        continue
      fi

      # Strip hunks that contain no added lines (deletion-only hunks); keep
      # the file header (diff/index/---/+++) as-is.
      awk '
        function flush() { if (!inhunk || nplus > 0) { for (i = 1; i <= nbuf; i++) print buf[i] }; nbuf = 0; nplus = 0 }
        /^@@/ { flush(); inhunk = 1 }
        !/^@@/ && !inhunk { print; next }
        { nbuf++; buf[nbuf] = $0; if ($0 ~ /^\+/ && $0 !~ /^\+\+\+/) nplus++ }
        END { flush() }
      ' "$f" > "$f.stripped"
      mv "$f.stripped" "$f"

      hunks=$(grep -c '^@@' "$f")
      if [ "$hunks" -eq 0 ]; then
        echo "- $path" >> "$CDIR/deleted.list"
        ndeleted=$((ndeleted + 1))
        rm -f "$f"
        continue
      fi

      lines=$(wc -l < "$f" | tr -d ' ')
      add=$(grep -c '^+[^+]' "$f" || true)
      del=$(grep -c '^-[^-]' "$f" || true)
      is_source=1
      echo "$path" | grep -Eq "$NON_SOURCE_EXT" && is_source=0
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$path" "$lines" "$is_source" "$add" "$del" "$f" >> "$manifest"
    done

    used=0
    ninc=0
    : > "$CDIR/selected.list"
    : > "$CDIR/omitted.list"
    while IFS="$(printf '\t')" read -r path lines is_source add del filepath; do
      [ -n "$path" ] || continue
      if [ $((used + lines)) -le "$DIFF_MAX_LINES" ]; then
        used=$((used + lines))
        ninc=$((ninc + 1))
        printf '%s\n' "$filepath" >> "$CDIR/selected.list"
      else
        printf -- '- %s (+%s/-%s)\n' "$path" "$add" "$del" >> "$CDIR/omitted.list"
      fi
    done < <(sort -t "$(printf '\t')" -k3,3rn -k2,2rn "$manifest")

    {
      for f in "$CDIR"/*.patch; do
        [ -e "$f" ] || continue
        grep -qxF "$f" "$CDIR/selected.list" 2>/dev/null && cat "$f"
      done
      if [ -s "$CDIR/deleted.list" ]; then
        printf '\n## Deleted files (not shown)\n'
        cat "$CDIR/deleted.list"
      fi
      if [ -s "$CDIR/omitted.list" ]; then
        printf '\n## Files not shown (over budget)\n'
        cat "$CDIR/omitted.list"
      fi
    } > "$SCRATCH/pr.diff.trunc"
    mv "$SCRATCH/pr.diff.trunc" "$SCRATCH/pr.diff"

    nomitted=$(wc -l < "$CDIR/omitted.list" | tr -d ' ')
    rm -rf "$CDIR"
    warn "diff compressed: $ninc file(s) included, $ndeleted deleted-only, $nomitted omitted over budget"
    echo "::notice::openreview compressed the diff: $ninc file(s) included, $ndeleted deleted-only, $nomitted omitted over budget"
  fi
fi

# pr-numbered.diff: same diff --git / @@ structure as pr.diff, but every
# unchanged/added line is prefixed with its new-file line number right-aligned
# in a fixed 6-char column followed by "| " (deleted lines get 6 spaces
# instead of a number). Lets the model copy loc: line numbers verbatim
# instead of computing them itself.
awk '
  /^diff --git / { print; next }
  /^(---|\+\+\+|index |new file mode|deleted file mode|similarity index|rename |old mode|new mode|Binary files)/ { print; next }
  /^@@/ { match($0, /\+[0-9]+/); newno = substr($0, RSTART+1, RLENGTH-1) + 0; print; next }
  /^\\/ { printf "      | %s\n", $0; next }
  /^\+/ { printf "%6d| %s\n", newno, $0; newno++; next }
  /^-/  { printf "      | %s\n", $0; next }
  /^ /  { printf "%6d| %s\n", newno, $0; newno++; next }
  { print }
' "$SCRATCH/pr.diff" > "$SCRATCH/pr-numbered.diff"

# Most recent prior review (matched by the marker substring, any author) so the
# reviewer can stay silent about findings since fixed. Empty on the first run,
# and forced to the placeholder on restart (the model must not defer to a
# review it's meant to redo from scratch).
if [ "$RESTART" -eq 1 ]; then
  echo "(no previous review)" > "$SCRATCH/prev-review.md"
else
  sed '/<!-- openreview:state /d' "$PREV_COMMENT_RAW" > "$SCRATCH/prev-review.md" 2>/dev/null \
    || : > "$SCRATCH/prev-review.md"
  [ -s "$SCRATCH/prev-review.md" ] || echo "(no previous review)" > "$SCRATCH/prev-review.md"
fi
rm -f "$PREV_COMMENT_RAW"

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

# Open-PR cross-context: other OPEN PRs in the repo that touch the same files
# as this PR — concurrent-change awareness. Best-effort; absent-silent (no
# file written) on API error, no other open PRs, or no file overlap.
rm -f "$SCRATCH/open-prs.md"
OWN_FILES_SORTED=$(gh pr view "$OR_PR" --repo "$OR_REPO" --json files --jq '.files[].path' 2>/dev/null | sort -u || true)
if [ -n "$OWN_FILES_SORTED" ]; then
  # One line per other open PR: number<TAB>title<TAB>comma-joined-file-paths.
  gh pr list --repo "$OR_REPO" --state open --json number,title,files --limit 30 \
    --jq --arg self "$OR_PR" '.[] | select((.number|tostring) != $self) | "\(.number)\t\(.title)\t\([.files[].path] | join(","))"' \
    2>/dev/null > "$SCRATCH/.open-prs-raw.tsv" || true
  if [ -s "$SCRATCH/.open-prs-raw.tsv" ]; then
    : > "$SCRATCH/.open-prs-overlap.tsv"
    while IFS="$(printf '\t')" read -r num title files; do
      [ -n "$num" ] || continue
      shared=$(comm -12 <(printf '%s\n' "$OWN_FILES_SORTED") <(printf '%s\n' "$files" | tr ',' '\n' | sort -u))
      [ -n "$shared" ] || continue
      nshared=$(printf '%s\n' "$shared" | grep -c .)
      shared4=$(printf '%s\n' "$shared" | head -4 | paste -sd, -)
      printf '%s\t%s\t%s\t%s\n' "$nshared" "$num" "$title" "$shared4" >> "$SCRATCH/.open-prs-overlap.tsv"
    done < "$SCRATCH/.open-prs-raw.tsv"
    if [ -s "$SCRATCH/.open-prs-overlap.tsv" ]; then
      {
        echo "## Other open PRs touching the same files"
        sort -t "$(printf '\t')" -k1,1rn "$SCRATCH/.open-prs-overlap.tsv" | head -5 \
          | while IFS="$(printf '\t')" read -r _n num title shared4; do
              printf '#%s "%s" also touches: %s\n' "$num" "$title" "$shared4"
            done
      } > "$SCRATCH/open-prs.md"
    fi
    rm -f "$SCRATCH/.open-prs-overlap.tsv"
  fi
  rm -f "$SCRATCH/.open-prs-raw.tsv"
fi
if [ -s "$SCRATCH/open-prs.md" ]; then
  info "open-PR overlap: $(($(wc -l < "$SCRATCH/open-prs.md" | tr -d ' ') - 1)) overlapping PR(s)"
fi

# Regression radar (TASK-31): for the PR's changed files, recent bug-fix commit
# history — surfaced so the reviewer can check this PR doesn't undo or bypass
# a recent fix. Requires full history; degrades silently on a shallow clone
# (partial `git log --since` results on a shallow repo would be misleading).
rm -f "$SCRATCH/regression-context.md"
if [ "$(git -C "$OR_DIR" rev-parse --is-shallow-repository 2>/dev/null || echo true)" = "false" ]; then
  CHANGED_FILES=$(gh pr view "$OR_PR" --repo "$OR_REPO" --json files --jq '.files[].path' 2>/dev/null | head -20 || true)
  if [ -n "$CHANGED_FILES" ]; then
    : > "$SCRATCH/.regression-raw.tsv"
    printf '%s\n' "$CHANGED_FILES" | while IFS= read -r f; do
      [ -n "$f" ] || continue
      git -C "$OR_DIR" log --since='120 days ago' -i -E --grep='fix|bug|regress' --format='%h %s' -n 3 -- "$f" 2>/dev/null \
        | while IFS= read -r line; do
            [ -n "$line" ] || continue
            printf '%s\t%s\n' "$f" "$line" >> "$SCRATCH/.regression-raw.tsv"
          done
    done
    if [ -s "$SCRATCH/.regression-raw.tsv" ]; then
      {
        echo "## Files touched by this PR with recent bug-fix commits (last 120 days)"
        awk -F'\t' '!seen[$2]++ { print $1 " — " $2 }' "$SCRATCH/.regression-raw.tsv"
      } > "$SCRATCH/regression-context.md"
    fi
    rm -f "$SCRATCH/.regression-raw.tsv"
  fi
fi
if [ -s "$SCRATCH/regression-context.md" ]; then
  sanitize_text "$SCRATCH/regression-context.md"
  info "regression radar: $(($(wc -l < "$SCRATCH/regression-context.md" | tr -d ' ') - 1)) recently-fixed file(s) touched"
fi

# Strip invisible-Unicode smuggling vectors from every fetched text context
# file before the model sees it (pr-meta.json values are left alone).
sanitize_text "$SCRATCH/pr.diff"
sanitize_text "$SCRATCH/pr-numbered.diff"
sanitize_text "$SCRATCH/commentable-lines.tsv"
sanitize_text "$SCRATCH/linked-issues.md"
sanitize_text "$SCRATCH/pr-commits.md"
sanitize_text "$SCRATCH/pr-comments.md"
sanitize_text "$SCRATCH/prev-review.md"
[ -f "$SCRATCH/open-prs.md" ] && sanitize_text "$SCRATCH/open-prs.md"

DIFF_LINES=$(wc -l < "$SCRATCH/pr.diff" | tr -d ' ')
echo "DIFF_LINES=$DIFF_LINES" >> "$SCRATCH/metrics.env"
info "context: $DIFF_LINES diff lines, $(wc -l < "$SCRATCH/prev-review.md" | tr -d ' ') prev-review lines"
