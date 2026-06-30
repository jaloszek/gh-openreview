# Changelog

All notable changes to this project are documented here.

## v1.0.2

- Fixed the `model` input being silently ignored. The Action exported the
  chosen model as `OR_MODEL`, but `resolve_model()` recomputes `OR_MODEL` from
  `--model > OPENREVIEW_MODEL > OC_MODEL > default` and never read the
  pre-exported value — so every run fell back to the free default model
  regardless of the `model` input. The Action now feeds it through
  `OPENREVIEW_MODEL`, and `resolve_model()` additionally honors a pre-exported
  `OR_MODEL` as a last fallback (defensive against the same class of bug).

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
