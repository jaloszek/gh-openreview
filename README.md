# gh-openreview

A reusable, provider-agnostic **GitHub Action that reviews pull requests** with
an LLM, built on the [OpenCode](https://opencode.ai) harness. Drop it into a
workflow, point it at an OpenCode-compatible model, and it posts a focused review
comment on every PR.

Free by default (bundled free model), works with any OpenCode provider (OpenCode
Zen, OpenAI-compatible gateways, AWS Bedrock via OIDC), and built so the **LLM
pass never sees a GitHub token**.

## Quick start

Add `.github/workflows/opencode-review.yml`:

```yaml
name: OpenCode PR Review
on:
  pull_request:
    types: [opened, synchronize, ready_for_review, reopened, labeled]
  issue_comment:
    types: [created]

concurrency:
  group: opencode-review-${{ github.event.pull_request.number || github.event.issue.number }}
  cancel-in-progress: true

jobs:
  review:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: jaloszek/gh-openreview/action@v1
        with:
          opencode-api-key: ${{ secrets.OPENCODE_API_KEY }}
          # Optional — defaults to the bundled free model.
          # model: opencode-go/glm-5.2
```

See [`examples/`](examples/) for Bedrock-via-OIDC and self-hosted-runner variants.

## Triggers

| Trigger | Behavior |
|---|---|
| `pull_request` (opened / synchronize / reopened / ready_for_review) | Reviews the PR. |
| `issue_comment` containing `@openreview` | On-demand review — **gated to trusted authors** (OWNER/MEMBER/COLLABORATOR). |
| `pull_request` / `pull_request_target` `labeled` with `opencode-review` | Review opted in by someone with write access. |

## Inputs

| Input | Default | Purpose |
|---|---|---|
| `opencode-api-key` | `""` | OpenCode Zen API key. Omit when supplying provider creds another way (e.g. AWS env/OIDC for Bedrock). |
| `opencode-config` | `""` | Path to an `opencode.json`. Falls back to the consumer repo's config, then the bundled free-model config. |
| `model` | `opencode/deepseek-v4-flash-free` | Model id for the analysis pass. |
| `github-token` | `${{ github.token }}` | Used only by the gather + post steps. |
| `trigger-phrase` | `@openreview` | Comment body that triggers an on-demand review. |
| `trigger-label` | `opencode-review` | Label whose addition triggers a review. |
| `marker-header` | `## 🤖 OpenCode Review` | First line of the posted comment; used for dedup. |
| `bot-login` | `github-actions[bot]` | Comment author whose stale reviews are pruned. |

## How the review works

Two LLM passes plus a deterministic render:

1. **Generate** — hunt for issues by class; every finding must cite a `file:line`
   that appears in the diff.
2. **Verify** — ground each candidate against the diff and drop the inferential
   ones (skipped when the first pass found nothing).
3. **Render** — a deterministic step builds the final comment (🔴 important /
   🟡 nit; pre-existing issues are never shown), guarantees the marker header,
   posts one summary comment, and prunes stale ones so only the latest remains.

Before the passes run, a token-scoped step gathers the PR context (diff, title/
body, changed files, prior review comments) into a scratch directory. **The LLM
passes read only those files — they never receive a GitHub token.**

## Authentication & models

The action delegates credential resolution to opencode. All of these work:

- **API key** — set `opencode-api-key` (exported as `OPENCODE_API_KEY`).
- **Custom gateway / OpenAI-compatible / AWS Bedrock** — configure a `provider`
  block in an `opencode.json` and pass it via `opencode-config`. Bedrock uses the
  standard AWS credential chain (`AWS_*`, OIDC) with no extra setup here.

**Config precedence** (your own config is never overwritten): `opencode-config`
input → consumer repo `./opencode.json` → `~/.config/opencode/` → the bundled
default (used only when none of the above exist).

## Security

The LLM step runs **without** a GitHub token, and the bundled configuration
denies shell and network tools to the model. The `@openreview` comment trigger is
gated to trusted authors so an arbitrary commenter on a public repo cannot start
a secret-bearing run. Please read [SECURITY.md](SECURITY.md) before enabling
comment/label triggers on a public repository.

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Pull requests
to this repository are reviewed by the action itself (see
[`.github/workflows/self-test.yml`](.github/workflows/self-test.yml)).

## License

[MIT](LICENSE).
