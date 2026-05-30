#!/usr/bin/env bash
# `gh openreview review [<pr>] [--post]` — local 3-pass audit of a PR.
# Default is read-only (prints the rendered review to stdout); --post comments
# on the PR as you. Acts via your inherited gh auth + opencode credentials.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

parse_common_flags "$@"
if [ "${#OR_ARGS[@]}" -gt 0 ]; then set -- "${OR_ARGS[@]}"; else set --; fi
need_cmd gh; need_opencode
POST=0; SEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --post) POST=1; shift ;;
    -h|--help) log "usage: gh openreview review [<pr>] [--post] [--model <id>]"; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) SEL="$1"; shift ;;
  esac
done

resolve_pr_target "$SEL"
resolve_dir
scratch_init
export OR_PR OR_REPO

info "reviewing $OR_REPO#$OR_PR"
"$OPENREVIEW_LIB/gather.sh"
"$OPENREVIEW_LIB/passes.sh"

if [ "$POST" = "1" ]; then
  "$OPENREVIEW_LIB/post.sh"
else
  log ""; log "─── review (not posted; pass --post to comment) ───"
  cat "$SCRATCH/opencode-review.md"
fi
