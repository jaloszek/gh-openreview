# Changelog

All notable changes to this project are documented here.

## v1.0.1

- Open-source polish: rewritten README, added LICENSE (MIT), SECURITY.md, CONTRIBUTING.md.
- Split examples into `pull-request.yml`, `bedrock-oidc.yml`, `self-hosted.yml`.
- Hardened CI secret handling: bundled `opencode.json` denies `bash`/`webfetch`/`websearch`;
  the `@openreview` comment trigger is gated to trusted authors; fork PRs are
  skipped on the plain `pull_request` trigger.
- Fixed composite-action script resolution: reference `${{ github.action_path }}/../lib/`
  (the engine scripts live at the repo root `lib/`, not under `action/`).

## v1.0.0

- Initial release: `gh openreview` extension with `review`, `resolve`, `inbox`,
  `assist`, and `doctor` subcommands, plus a reusable composite Action for CI.
