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
| `model` | `opencode/deepseek-v4-flash-free` | Model id for the analysis (generate) pass. |
| `cheap-model` | `""` | Small/fast/free model the engine routes prep work to (intent compression) and uses as the default verify tier. Empty disables cheap routing. |
| `verify-model` | `""` | Model id for the verification pass. Empty falls back to `cheap-model`, then `model`. |
| `opencode-version` | `1.17.13` | Exact opencode version to install. opencode ships releases every 1-3 days, so pinning avoids an untested version silently landing mid-run. Empty installs latest — not recommended. |
| `github-token` | `${{ github.token }}` | Used only by the gather + post steps. |
| `trigger-phrase` | `@openreview` | Comment body that triggers an on-demand review. |
| `trigger-label` | `opencode-review` | Label whose addition triggers a review. |
| `marker-header` | `## 🤖 OpenCode Review` | First line of the posted comment; used for dedup. |
| `bot-login` | `github-actions[bot]` | Comment author whose stale reviews are pruned. |
| `min-confidence` | `low` | Minimum confidence (`low`/`med`/`high`) a finding must have to be rendered. Below-threshold findings are dropped and counted separately; low-confidence findings are always demoted from important to nit regardless of this setting. |
| `update-ping` | `false` | When `true`, editing an existing sticky comment with ≥1 important finding also posts a short unmarked ping comment; pruned on the next run. |

## Outputs

The action exposes per-run metrics (also written to the job's step summary):

| Output | Meaning |
|---|---|
| `findings-total` | Rendered findings (important + nits). |
| `findings-important` | 🔴 important findings. |
| `findings-nit` | 🟡 nit findings. |
| `diff-lines` | Reviewed diff size after exclude/truncation. |
| `duration-seconds` | Total LLM time across the passes. |

## How the review works

Two LLM passes plus a deterministic render:

1. **Generate** — hunt for issues by class; every finding must cite a `file:line`
   that appears in the diff.
2. **Verify** — ground each candidate against the diff and drop the inferential
   ones (skipped when the first pass found nothing).
3. **Render** — a deterministic step builds the final comment (🔴 important /
   🟡 nit; pre-existing issues are never shown), guarantees the marker header,
   posts one summary comment, and prunes stale ones so only the latest remains.

Before the passes run, a token-scoped step gathers the PR context into a scratch
directory: the diff (with generated/vendored files excluded and a size cap), the
title/body and changed files, the **linked issues** the PR closes (the
requirement), the branch's **commit messages**, and **existing discussion** —
inline review threads tagged `[OPEN]`/`[RESOLVED]` plus general comments — so the
reviewer defers to humans and never repeats or re-raises a point. **The LLM
passes read only those files — they never receive a GitHub token.**

## Authentication & models

The action delegates credential resolution to opencode. All of these work:

- **API key** — set `opencode-api-key` (exported as `OPENCODE_API_KEY`).
- **Custom gateway / OpenAI-compatible / AWS Bedrock** — configure a `provider`
  block in an `opencode.json` and pass it via `opencode-config`. Bedrock uses the
  standard AWS credential chain (`AWS_*`, OIDC) with no extra setup here.

### Cost routing with a cheap model

Set `cheap-model` to a small/fast/free model to keep the strong `model` focused
on the actual review. When provided, the engine:

- runs an **intent-compression** prep step on the cheap model that distils the
  linked issues, PR body, and commits into a short brief — so the strong generate
  pass reads ~8 lines of requirement context instead of the raw text, and
- runs the **verification pass** on the cheap model (unless `verify-model`
  overrides it).

The expensive reasoning still runs on `model`; only the prep/verify work moves to
the cheap tier. Leaving `cheap-model` empty preserves the original behaviour
(everything on `model`, no extra calls).

```yaml
with:
  model: opencode-go/glm-5.2            # strong: the review
  cheap-model: opencode-go/deepseek-v4-flash  # cheap: intent + verify
```

#### Picking a cheap model on OpenCode (free vs Go)

OpenCode serves the same model through two billing surfaces, and **the tier is
decided by the model-ID prefix, not your account**:

- `opencode/deepseek-v4-flash-free` — **free**, but with a hard, undisclosed
  usage cap (requests start failing with `Free usage exceeded, subscribe to Go`),
  "limited-time" availability, and data that **may be retained**. Fine for local
  or low-volume use; risky for CI, where a burst of PRs across the
  prep/generate/verify passes can trip the cap and fail the run.
- `opencode-go/deepseek-v4-flash` — the **same model** on the paid **Go** plan
  (~$10/mo): generous limits (~31k requests / 5h for flash), zero data retention,
  stable. The sweet spot for a CI reviewer's cheap tier.

> ⚠️ Even with an active Go subscription, a `…-free` model ID still draws from
> the **free** tier and hits the free cap. On a paid plan, use the
> `opencode-go/…` IDs for **both** `model` and `cheap-model`. The action's
> built-in default (`opencode/deepseek-v4-flash-free`) is free-tier — override it
> for anything beyond light/personal use.

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
