# gh-openreview

A local-first, provider-agnostic **pull-request review toolkit** built on the
[OpenCode](https://opencode.ai) harness. It runs as a
[GitHub CLI](https://cli.github.com) extension — so it inherits your existing
GitHub authentication and acts as you, in any repository you can access, with no
per-repo configuration. The same review engine also ships as a reusable GitHub
Action for CI.

## Features

| Command | Purpose | Posts to the PR? |
|---|---|---|
| `gh openreview review [<pr>] [--post]` | Multi-pass audit (generate → verify → format) of a PR. | No by default; one summary comment with `--post`. |
| `gh openreview resolve [<pr>] [--yes]` | Reconcile **your** PR's open review threads against recent commits: resolve the ones a commit addressed, reply with a rationale on the rest. | Yes, after you confirm. |
| `gh openreview inbox [--org <o>]` | List PRs awaiting **your** review (direct requests and via your teams), oldest-first, with approvals / comments / CI / decision. | No (read-only). |
| `gh openreview assist <pr> [--yes]` | Help review **someone else's** PR — proposes novel, human-voice inline comments, deduped against what people and bots already said. | Yes, after you confirm. |
| `gh openreview doctor` | Verify opencode is installed, authenticated, and the model responds. | No. |

`resolve` and `assist` are **propose-then-confirm**: they print the plan and
post nothing until you approve (pass `--yes` to skip the prompt).

## Requirements

- **GitHub CLI (`gh`)** — authenticated (`gh auth login`). It hosts the extension.
- **opencode** — install once and provide credentials (see *Authentication*):
  ```bash
  curl -fsSL https://opencode.ai/install | bash
  ```
  Or run any command with `--bootstrap` to install opencode automatically.
- **git**, plus a POSIX shell. macOS and Linux are supported; on Windows use WSL.

## Install

```bash
gh extension install jaloszek/gh-openreview
gh openreview doctor
```

Update or remove:

```bash
gh extension upgrade openreview
gh extension remove  openreview
```

## Authentication & models

The extension does not implement authentication of its own — it delegates to
opencode's credential resolution, just as it delegates GitHub access to `gh`.
The following all work without code changes:

- **API key** — set `OPENCODE_API_KEY`, or run `opencode auth login`.
- **Custom gateway / OpenAI-compatible / AWS Bedrock** — configure a `provider`
  block in your `opencode.json`. Bedrock uses the standard AWS credential chain
  (`AWS_*`, `AWS_PROFILE`, SSO, IMDS) with no extra setup here.
- **CLI auth helper / short-lived tokens** — pass `--auth-cmd '<command>'` (or
  set `OPENREVIEW_AUTH_CMD`); it runs before opencode to mint or refresh
  credentials, e.g. `--auth-cmd 'aws sso login'`.

Select a model with `--model <id>` (or `OPENREVIEW_MODEL`); it maps directly to
`opencode -m`.

**Configuration precedence** (your own config is never overwritten):
`OPENCODE_CONFIG` → project `./opencode.json` → `~/.config/opencode/` →
the bundled default config (used only when you have none of the above).

## Continuous integration

The review engine is also packaged as a composite Action. Copy
[`examples/pull-request.yml`](examples/pull-request.yml) into a repository at
`.github/workflows/opencode-review.yml` and add an `OPENCODE_API_KEY` secret:

```yaml
- uses: jaloszek/gh-openreview/action@v1
  with:
    opencode-api-key: ${{ secrets.OPENCODE_API_KEY }}
```

It can run on pull-request events, on an `@openreview` comment, and on an
`opencode-review` label. The runner is yours to choose via `runs-on:` (defaults
to `ubuntu-latest`). See [`examples/`](examples/) for Bedrock-via-OIDC and
self-hosted-runner variants.

The LLM step runs **without** a GitHub token, and the bundled configuration
denies shell and network tools to the model. Please read
[SECURITY.md](SECURITY.md) before enabling comment/label triggers on a public
repository.

## How the review works

Three passes:

1. **Generate** — hunt for issues by class; every finding cites a `file:line`.
2. **Verify** — ground each candidate against the diff and drop the inferential
   ones (skipped when the first pass found nothing).
3. **Format** — render a minimal, scannable comment (🔴 important / 🟡 nit;
   pre-existing issues are never shown).

A deterministic step validates the output and guarantees the comment's marker
header before posting, then prunes stale review comments so only the latest
remains.

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Pull requests
to this repository are reviewed by the action itself (see
[`.github/workflows/self-test.yml`](.github/workflows/self-test.yml)).

## License

[MIT](LICENSE).
