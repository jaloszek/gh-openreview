# Org-wide setup (central dispatch)

This is the one-time, ~10-minute setup for running this reviewer against
**any PR in any repo in your org**, from a single fork, without adding a
workflow to every target repo. It uses a webhook-less GitHub App purely as a
token-minting identity — see `docs/improvement-plan.md` §3.1 for the
rationale.

## 1. Fork this repo into the org

Import/fork `gh-openreview` into your org (e.g. `your-org/gh-openreview`).
`review-dispatch.yml` already ships in `.github/workflows/`.

## 2. Register a GitHub App

Org settings → Developer settings → GitHub Apps → New GitHub App.

- **Webhook: uncheck "Active"** — no webhook URL needed. This App is used
  purely for minting installation tokens, per GitHub's own documented
  pattern for auth-only Apps.
- **Repository permissions:**
  - Metadata: Read-only
  - Contents: Read-only
  - Pull requests: Read and write
  - Issues: Read and write
- Generate a private key (downloads a `.pem`) and note the **App ID** (or
  **Client ID** — `actions/create-github-app-token` accepts either) shown on
  the App's settings page.

## 3. Install the App org-wide

App settings → Install App → select the org → **All repositories** (so newly
created repos are covered automatically without reinstalling).

## 4. Store credentials on the fork

On `your-org/gh-openreview`, add:

- **Repository variable** `REVIEWER_APP_CLIENT_ID` — the App's Client ID.
- **Repository secret** `REVIEWER_APP_PRIVATE_KEY` — the full contents of
  the downloaded `.pem`.
- **Repository secret** `OPENCODE_API_KEY` (or whatever your `model` input
  needs) — the LLM credential.
- Optionally, repository variables `OPENREVIEW_MODEL` / `OPENREVIEW_CHEAP_MODEL`
  to set org-wide defaults without editing the workflow.

## 5. Invoke a review

From the CLI:

```bash
gh workflow run review-dispatch.yml -R your-org/gh-openreview \
  -f repo=your-org/target-repo -f pr=123
```

Force a full fresh review (ignore incremental/skip-guard state):

```bash
gh workflow run review-dispatch.yml -R your-org/gh-openreview \
  -f repo=your-org/target-repo -f pr=123 -f restart=true
```

Or from the Actions tab: `gh-openreview` repo → Actions → "Review dispatch" →
Run workflow → fill in `repo` and `pr`.

The bot comment appears on the target PR authored by the App's bot identity
(`your-app-name[bot]`); re-running updates the same comment in place (marker
dedup, same as the normal in-repo trigger).

## Security trade-offs

- **Who can dispatch = who can trigger workflows on the fork.** Anyone with
  write access to `your-org/gh-openreview` can run `review-dispatch.yml`
  against any repo the App is installed on. Treat write access to the fork
  as equivalent to "can comment/review on any org repo as the bot."
- **Per-run scoping helps but isn't a full sandbox.** The minted token is
  scoped to only the `repo` input's repository via `repositories:`, and to
  `contents:read` / `pull-requests:write` / `issues:write` — it cannot touch
  other repos or write code, but it can post/edit PR comments and reviews on
  the target repo.
- **Recommended mitigations:**
  - Enable branch protection on the fork's default branch and require
    `CODEOWNERS` review on changes to `.github/workflows/review-dispatch.yml`
    and `action/`, so a malicious workflow edit can't be merged unreviewed.
  - Consider putting the token-minting step behind a GitHub Actions
    **environment** with required reviewers, so each dispatch run needs an
    explicit approval.
  - Keep the App's permissions at the minimum listed above — do not add
    `contents:write` (or anything else) unless a specific feature needs it.
