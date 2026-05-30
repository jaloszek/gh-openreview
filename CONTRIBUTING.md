# Contributing

Thanks for your interest in improving `gh-openreview`. Issues and pull requests
are welcome.

## Development setup

The toolkit is plain Bash — no build step. To run a local checkout as the `gh`
extension:

```bash
git clone https://github.com/jaloszek/gh-openreview
gh extension install ./gh-openreview   # installs the local copy
gh openreview doctor
```

Run a subcommand directly from the checkout without installing:

```bash
./gh-openreview doctor
```

## Before opening a pull request

- Keep it POSIX/Bash-portable (the scripts target Bash 3.2+ so they run on a
  stock macOS as well as Linux). Avoid `mapfile`, associative arrays, and other
  Bash 4-only features.
- Lint:
  ```bash
  shellcheck -S warning gh-openreview lib/*.sh
  actionlint .github/workflows/*.yml
  ```
- Match the existing style: results go to stdout, all logs/progress go to
  stderr, and anything that writes to a PR is gated behind propose-then-confirm.
- Update the README / examples if you change flags or behavior.

## Code of conduct

Be respectful and constructive. Maintainers may close or lock threads that don't
follow this.

## How PRs are reviewed

This repository reviews its own pull requests using the action
(`.github/workflows/self-test.yml`). The automated comment is advisory; a
maintainer makes the final call.
