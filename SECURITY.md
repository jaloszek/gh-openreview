# Security

## Reporting a vulnerability

Please report security issues privately via GitHub Security Advisories
("Report a vulnerability" on the repo's **Security** tab) rather than opening a
public issue. We aim to acknowledge reports within a few days.

## Threat model — protecting your provider key in CI

The reviewer needs an LLM credential (an OpenCode Zen key, or provider creds for
a gateway/Bedrock). On a **public repository**, the central risk is a malicious
pull request trying to exfiltrate that secret. The action is designed to make
that hard, in layers:

1. **The model has no exfiltration tools.** The bundled `opencode.json` denies
   `bash`, `webfetch`, and `websearch`. The model can only read/write files
   inside the sandboxed working directory, so it cannot read process
   environment variables (where the key lives) or make outbound network calls —
   even if a PR plants a prompt-injection payload in a tracked file.

2. **The LLM step holds no GitHub token.** PR context is pre-fetched by separate,
   token-scoped steps. The step that runs the model is given only the LLM
   credential, never `GITHUB_TOKEN`.

3. **Untrusted triggers are gated.** GitHub does not pass secrets to
   `pull_request` workflows from forks, so fork PRs cannot reach the key on that
   path. For the secret-bearing triggers:
   - `@openreview` comments (`issue_comment`) run **only** when the commenter's
     association is `OWNER`, `MEMBER`, or `COLLABORATOR`.
   - The `opencode-review` label can only be added by users with write access,
     so a maintainer must opt a fork PR in explicitly.

## Recommendations for consumers

- Prefer a repo/org **secret** named `OPENCODE_API_KEY`; never commit keys.
- Keep the bundled `opencode.json` permissions (or stricter) for the reviewer.
- If you enable `issue_comment` / `pull_request_target` triggers on a public
  repo, keep the trusted-author gating shown in
  [`examples/`](examples/) — do not loosen it without understanding the
  fork-PR secret-exposure risk.
- For Bedrock/gateway auth in CI, prefer short-lived credentials via OIDC
  (`aws-actions/configure-aws-credentials`) over long-lived keys.
