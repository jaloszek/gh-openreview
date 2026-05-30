# Changelog

All notable changes to this project are documented here.

## Unreleased

- Added an eval harness (`evals/`) that runs fixture PRs through the review
  engine and scores the output, guarding review quality against regressions.
- Added a `lint` CI workflow enforcing `shellcheck -S warning` and `actionlint`
  on every PR; added `.shellcheckrc` and `# shellcheck source=` directives so
  sourced files resolve cleanly.
- Documented the supported environment variables in the README and added a
  `CLAUDE.md` for Claude Code.

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
