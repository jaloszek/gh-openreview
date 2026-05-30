# Examples

Caller workflows for the `gh-openreview` CI action. Copy one into your repo at
`.github/workflows/opencode-review.yml` and adjust.

| File | Use it when |
|---|---|
| [`pull-request.yml`](pull-request.yml) | Standard setup: PR events + `@openreview` comment + `opencode-review` label, on a GitHub-hosted runner with an `OPENCODE_API_KEY` secret. |
| [`bedrock-oidc.yml`](bedrock-oidc.yml) | You use AWS Bedrock and want short-lived OIDC credentials instead of a stored key. |
| [`self-hosted.yml`](self-hosted.yml) | You have a self-hosted runner and want to conserve hosted Actions minutes. |

Before enabling the comment/label triggers on a **public** repository, read
[../SECURITY.md](../SECURITY.md) — it explains how the action keeps your provider
key away from untrusted fork PRs and what the gating does.

For local, no-CI usage (`gh openreview review|resolve|inbox|assist`), see the
[top-level README](../README.md).
