#!/usr/bin/env bash
# `gh openreview inbox [--org <o>] [--include authored,involves]` — list open PRs
# awaiting YOUR review (direct requests + requests to teams you belong to),
# oldest-first, with approvals / comments / CI / review-decision, flagging the
# highest-leverage candidates to go deeper on with `gh openreview assist`.
# Read-only — posts nothing. No opencode needed.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

parse_common_flags "$@"
if [ "${#OR_ARGS[@]}" -gt 0 ]; then set -- "${OR_ARGS[@]}"; else set --; fi
need_cmd gh

ORG=""; INCLUDE=""; LIMIT="${OPENREVIEW_INBOX_LIMIT:-60}"
while [ $# -gt 0 ]; do
  case "$1" in
    --org) ORG="${2:?}"; shift 2 ;;
    --org=*) ORG="${1#*=}"; shift ;;
    --include) INCLUDE="${2:?}"; shift 2 ;;
    --include=*) INCLUDE="${1#*=}"; shift ;;
    -h|--help) log "usage: gh openreview inbox [--org <o>] [--include authored,involves]"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

me="$(gh api user --jq .login)"
org_q=""; [ -n "$ORG" ] && org_q="org:$ORG"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT

# search emits TSV: createdAt \t url \t isDraft \t title
search() { gh search prs --state=open "$@" $org_q \
  --json createdAt,url,isDraft,title \
  --jq '.[] | [.createdAt, .url, (.isDraft|tostring), .title] | @tsv' 2>/dev/null || true; }

info "collecting PRs awaiting your review…"
search --review-requested=@me >> "$tmp"

# teams you belong to that may be requested as a reviewer
while IFS= read -r team; do
  [ -n "$team" ] || continue
  search "team-review-requested:$team" >> "$tmp"
done < <(gh api user/teams --paginate --jq '.[] | "\(.organization.login)/\(.slug)"' 2>/dev/null || true)

case ",$INCLUDE," in *,authored,*) search --author=@me >> "$tmp" ;; esac
case ",$INCLUDE," in *,involves,*) search "involves:$me" >> "$tmp" ;; esac

# dedupe (identical lines) and sort oldest-first by createdAt (col 1)
sort -u "$tmp" | sort -t$'\t' -k1,1 > "$tmp.sorted"
total="$(wc -l < "$tmp.sorted" | tr -d ' ')"
[ "$total" -gt 0 ] || { ok "inbox empty — no PRs awaiting your review"; exit 0; }

if [ "$total" -gt "$LIMIT" ]; then
  warn "showing the $LIMIT oldest of $total PRs (raise with OPENREVIEW_INBOX_LIMIT)"
  head -n "$LIMIT" "$tmp.sorted" > "$tmp.capped"; mv "$tmp.capped" "$tmp.sorted"
fi

printf '\n  %-22s  %-5s  %-4s  %-3s  %-16s  %s\n' "REPO#PR" "AGE" "✓apr" "💬" "DECISION" "TITLE" >&2
printf '  %s\n' "----------------------------------------------------------------------------" >&2

now_epoch="$(date +%s)"
while IFS=$'\t' read -r created url draft title; do
  [ -n "$url" ] || continue
  repo="$(printf '%s' "$url" | sed -E 's#^https?://[^/]+/([^/]+/[^/]+)/pull/.*#\1#')"
  num="${url##*/}"
  # age in days
  c_epoch="$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$created" +%s 2>/dev/null || date -d "$created" +%s 2>/dev/null || echo "$now_epoch")"
  age="$(( (now_epoch - c_epoch) / 86400 ))d"
  # per-PR enrichment: decision, approvals, comments, CI
  meta="$(gh pr view "$url" --json reviewDecision,reviews,comments,statusCheckRollup --jq '
    ([.reviews[]?|select(.state=="APPROVED")]|length) as $a
    | ([.statusCheckRollup[]?.conclusion]) as $c
    | [ (.reviewDecision // "—"),
        ($a|tostring),
        ((.comments|length)|tostring),
        (if ($c|length)==0 then "—" elif (($c|map(select(.=="FAILURE" or .=="ERROR" or .=="CANCELLED"))|length)>0) then "✗" else "✓" end) ] | @tsv' 2>/dev/null || printf '—\t0\t0\t—')"
  IFS=$'\t' read -r decision approvals comments ci <<EOF
$meta
EOF
  flag=""
  if [ "$draft" != "true" ] && [ "$ci" != "✗" ] && { [ "$decision" = "REVIEW_REQUIRED" ] || [ "$decision" = "—" ]; }; then
    flag="  ← good candidate"
  fi
  [ "$draft" = "true" ] && decision="DRAFT"
  ttl="$title"; [ "${#ttl}" -gt 50 ] && ttl="${ttl:0:47}…"
  printf '  %-22s  %-5s  %-4s  %-3s  %-16s  %s%s\n' \
    "$repo#$num" "$age" "$approvals" "$comments" "$decision" "$ttl" "$flag" >&2
done < "$tmp.sorted"

log ""
info "go deeper on a candidate:  gh openreview assist <pr-url>"
