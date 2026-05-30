# gh-openreview

A local-first, provider-agnostic **PR review toolkit** built on the
[OpenCode](https://opencode.ai) harness. Runs as a [`gh`](https://cli.github.com)
extension, so it inherits your GitHub auth and **acts as you** — no per-repo
setup, works in any repo you can see. The same review engine also ships as a
**reusable GitHub Action** for CI.

It started life as the free PR reviewer in the `ai-news` daily pipeline and was
extracted so it's reusable everywhere.

## What it does

| Command | Purpose | Posts |
|---|---|---|
| `gh openreview review [<pr>] [--post]` | 3-pass bot-style audit (generate → verify → format) of a PR — yours or anyone's | nothing by default; one summary comment with `--post` |
| `gh openreview resolve [<pr>] [--yes]` | reconcile **your** PR's open review threads against recent commits: resolve the ones a commit addressed, reply with a rationale on the rest | thread resolves + replies (after you confirm) |
| `gh openreview inbox [--org O]` | list PRs awaiting **your** review (direct + via your teams), oldest-first, with approvals / comments / CI / decision | nothing (read-only) |
| `gh openreview assist <pr> [--yes]` | help review **someone else's** PR — proposes novel, human-voice inline comments, deduped against what people and bots already said | inline PR review as you (after you confirm) |
| `gh openreview doctor` | verify opencode is installed, authed, and the model answers | nothing |

`resolve` and `assist` are **propose-then-confirm**: they print the plan and post
nothing until you approve (`--yes` to skip the prompt).

## Install

```bash
gh extension install jaloszek/gh-openreview
gh openreview doctor          # check your environment
```

Prerequisites:
- **gh** and **git** — you already have these (gh runs the extension).
- **opencode** — the one external dependency. Install once and authenticate:
  ```bash
  curl -fsSL https://opencode.ai/install | bash
  opencode auth login          # or set OPENCODE_API_KEY, or configure a provider
  ```
  (Or run any command with `--bootstrap` to auto-install opencode.)
- macOS / Linux. (Windows: use WSL.)

## Authentication & models

The extension **never implements auth** — it delegates to opencode's own
credential resolution, exactly as it delegates GitHub auth to `gh`. So it works
unchanged across:

- **API key** — `OPENCODE_API_KEY` in the env, or `opencode auth login`.
- **Custom gateway / OpenAI-compatible / AWS Bedrock** — configure a `provider`
  block in your `opencode.json`. Bedrock reads the standard AWS credential chain
  (`AWS_*` env, `AWS_PROFILE`, SSO, IMDS) — nothing extra here.
- **CLI auth helper / short-lived tokens** — pass `--auth-cmd '<cmd>'` (or set
  `OPENREVIEW_AUTH_CMD`) and it runs before opencode to mint/refresh creds, e.g.
  `--auth-cmd 'aws sso login'`.

Pick the model with `--model <id>` (or `OPENREVIEW_MODEL`); it maps straight to
`opencode -m`, so a Bedrock `amazon-bedrock/anthropic.claude-*` id or a gateway
alias works the same as the default free model.

**Config precedence** (your config is never clobbered):
`OPENCODE_CONFIG` env → project `./opencode.json` → `~/.config/opencode/` →
the bundled free-model config (only when you have none).

## CI usage (reusable Action)

The review engine also runs in GitHub Actions. Copy
[`examples/opencode-review.yml`](examples/opencode-review.yml) into a consumer
repo at `.github/workflows/opencode-review.yml` and set the `OPENCODE_API_KEY`
secret. It fires on PR events, on an `@openreview` comment, and on the
`opencode-review` label.

```yaml
- uses: jaloszek/gh-openreview/action@v1
  with:
    opencode-api-key: ${{ secrets.OPENCODE_API_KEY }}
```

The runner is the one knob you choose (`runs-on:`); it defaults to
`ubuntu-latest`. The LLM step deliberately runs **without** a GitHub token —
context is pre-fetched and the comment posted by separate, token-scoped steps.

**Bedrock in CI:** omit `opencode-api-key` and obtain AWS creds before the
action with `aws-actions/configure-aws-credentials` (OIDC); opencode's Bedrock
provider picks them up.

> ⚠️ `issue_comment` / `pull_request_target` triggers run with repo write
> permissions. This action's model step holds no token, which mitigates the
> usual fork-PR risk, but review the standard guidance before enabling them on
> public repos.

## How the review works

Three passes, ported from the production daily pipeline:
1. **generate** — hunt issues by class; every finding cites a `file:line`.
2. **verify** — ground each candidate against the diff; drop the inferential
   ones (skipped when generate found nothing).
3. **format** — render a minimal, scannable comment (🔴 important / 🟡 nit;
   pre-existing issues are never shown).

A deterministic step validates the output and guarantees the marker header
before posting, and prunes stale review comments so only the latest remains.

## License

MIT
