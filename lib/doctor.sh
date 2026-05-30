#!/usr/bin/env bash
# `gh openreview doctor` — verify the environment: gh present+authed, opencode
# present, an opencode config/credentials resolvable, and the chosen model
# actually answers. Exits non-zero with an actionable hint when something fails.
set -euo pipefail
# shellcheck source=common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
parse_common_flags "$@"
resolve_model
fail=0

# gh
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then ok "gh installed and authenticated"
  else warn "gh is installed but not authenticated — run: gh auth login"; fail=1; fi
else
  warn "gh not found — install GitHub CLI: https://cli.github.com"; fail=1
fi

# opencode
if command -v opencode >/dev/null 2>&1; then
  ok "opencode installed ($(opencode --version 2>/dev/null))"
else
  warn "opencode not found — install it: curl -fsSL https://opencode.ai/install | bash"
  log ""; die "opencode is required (or run any subcommand with --bootstrap to auto-install)"
fi

# config resolution
resolve_dir 2>/dev/null || OR_DIR="$PWD"
prepare_opencode_config "$OR_DIR"
if [ -n "${OPENCODE_CONFIG:-}" ]; then info "opencode config: $OPENCODE_CONFIG (bundled fallback)"
else info "opencode config: project/global opencode.json (auto-discovered)"; fi

# credentials hint (non-fatal — a provider/env setup may not use auth.json)
if opencode auth list 2>/dev/null | grep -qiE 'opencode|api|bedrock|anthropic|openai'; then
  ok "opencode has stored credentials"
elif [ -n "${OPENCODE_API_KEY:-}" ]; then
  ok "OPENCODE_API_KEY present in environment"
else
  warn "no stored opencode credentials and OPENCODE_API_KEY unset — relying on provider config/env (e.g. AWS for Bedrock)"
fi

# live smoke test: does the model answer?
info "testing model '$OR_MODEL' …"
out="$(oc_run "$OR_DIR" "Reply with exactly the token OPENREVIEW_OK and nothing else." 2>&1 || true)"
if printf '%s' "$out" | grep -q 'OPENREVIEW_OK'; then
  ok "model '$OR_MODEL' responded"
else
  warn "model '$OR_MODEL' did not confirm — check auth/model/network"
  printf '%s\n' "$out" | tail -5 >&2
  fail=1
fi

[ "$fail" = "0" ] && { ok "all checks passed"; exit 0; } || die "doctor found problems (see above)"
