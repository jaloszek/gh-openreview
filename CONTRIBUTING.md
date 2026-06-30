# Contributing

Thanks for your interest in improving `gh-openreview`. Issues and pull requests
are welcome.

## What this is

A single GitHub Action that reviews pull requests with OpenCode. The engine is
plain Bash under `lib/`, wired together by `action/action.yml`. No build step.

```
action/action.yml   # the action entrypoint
lib/common.sh        # logging, model + config resolution, opencode invocation
lib/gather.sh        # token-scoped: collect PR context into the scratch dir
lib/passes.sh        # the LLM passes (generate -> verify)
lib/render.sh        # deterministic: build the final comment from verified findings
lib/post.sh          # token-scoped: post the comment + prune stale ones
```

## Running the engine locally

The library scripts read their inputs from environment variables (the same ones
the action sets). To exercise the engine against a real PR from a checkout:

```bash
export OR_REPO=owner/repo OR_PR=123
export OR_DIR="$PWD" SCRATCH="$PWD/.openreview-tmp" SCRATCH_REL=".openreview-tmp"
export OPENREVIEW_MODEL=opencode/deepseek-v4-flash-free
mkdir -p "$SCRATCH"
GH_TOKEN=$(gh auth token) lib/gather.sh
lib/passes.sh
lib/render.sh
cat "$SCRATCH/opencode-review.md"   # inspect; post.sh would publish it
```

## Before opening a pull request

- Keep it POSIX/Bash-portable (target Bash 3.2+ so the scripts run on stock
  macOS as well as Linux). Avoid `mapfile`, associative arrays, and other
  Bash 4-only features.
- Avoid adding hard dependencies (the engine deliberately uses `gh`'s built-in
  `--jq` instead of requiring `jq`).
- Lint:
  ```bash
  shellcheck -S warning lib/*.sh
  actionlint .github/workflows/*.yml
  ```
- Match the existing style: command results go to stdout, all logs/progress go
  to stderr.
- Update the README / examples if you change inputs or behavior.

## How PRs are reviewed

This repository reviews its own pull requests using the action
(`.github/workflows/self-test.yml`). The automated comment is advisory; a
maintainer makes the final call.
