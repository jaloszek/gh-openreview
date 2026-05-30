# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`gh-openreview` is a local-first, provider-agnostic PR-review toolkit. It is plain Bash (no build step) shipped two ways:

- A **`gh` CLI extension** (`gh openreview <sub>`) that inherits your `gh` auth and acts as you.
- A **composite GitHub Action** (`action/action.yml`) that runs the same review engine in CI.

The LLM work is delegated to the [opencode](https://opencode.ai) harness (`opencode run -m <model> <prompt>`); GitHub access is delegated to `gh`. The toolkit itself implements neither auth.

## Commands

```bash
# Run a subcommand directly from the checkout (no install)
./gh-openreview doctor

# Install the local checkout as the gh extension
gh extension install ./gh-openreview

# Lint before any PR (required)
shellcheck -S warning gh-openreview lib/*.sh
actionlint .github/workflows/*.yml
```

There is no test suite. The repo dogfoods: it reviews its own PRs via `.github/workflows/self-test.yml`.

## Architecture

`gh-openreview` (entrypoint) dispatches to `lib/<sub>.sh`. Every lib script sources `lib/common.sh` first.

- **`lib/common.sh`** — shared helpers, sourced not executed. Owns: logging (`log`/`info`/`warn`/`ok`/`die`), `parse_common_flags` (strips `--model`/`--auth-cmd`/`--bootstrap`, leaves rest in `OR_ARGS[]`), `resolve_model`, `prepare_opencode_config`, `oc_run` (the opencode invocation), `resolve_dir`, `scratch_init`, `resolve_pr_target`, and `confirm`.
- **`lib/gather.sh`** + **`lib/passes.sh`** + **`lib/post.sh`** — the reusable review engine, shared between the `review` subcommand and the CI action. `gather.sh` pre-fetches all GitHub context into scratch files; `passes.sh` runs the 3-pass model pipeline reading only those files; `post.sh` is the deterministic post/dedup step.
- **`lib/review.sh` / `resolve.sh` / `inbox.sh` / `assist.sh` / `doctor.sh`** — one per subcommand.

### Conventions that matter

- **stdout is reserved for command output; everything else (logs, progress, prompts) goes to stderr.** The logging helpers in `common.sh` already enforce this — use them, never bare `echo` for status.
- **Propose-then-confirm for anything that writes to a PR.** `resolve` and `assist` print the plan and post nothing until `confirm` returns true (`--yes`/`OR_YES=1` skips). Preserve this gating.
- **Bash 3.2+ only** (stock macOS). No `mapfile`, no associative arrays, no Bash-4 features. Existing code parses model output with `awk` into parallel indexed arrays (`SF[]`/`SL[]`/`SC[]`, `DEC[]`/`REP[]`) — follow that pattern.
- **Config precedence is never overwritten** (`prepare_opencode_config`): `OPENCODE_CONFIG` env → project `./opencode.json(c)` → `~/.config/opencode/` → the bundled `opencode.json` (fallback only). The bundled config denies `bash`/`webfetch`/`websearch` to the model and allows only `edit`.
- **Model precedence** (`resolve_model`): `--model` → `OPENREVIEW_MODEL` → `OC_MODEL` → bundled free model.

### The model pipeline (passes.sh)

Three opencode passes writing intermediate files into `$SCRATCH`:
1. **generate** → `review-candidates.md`
2. **verify** (skipped when pass 1 found nothing) → `review-verified.md`
3. **format** → `opencode-review.md`

`NO_FINDINGS` is the sentinel for "no issues". Each pass uses prompt-only control flow; `passes.sh` gates between them by inspecting the scratch files.

### Scratch directory contract

opencode's read/write tools are **sandboxed to the project directory** — absolute paths and `/tmp` are rejected. So scratch lives at `$OR_DIR/.openreview-tmp` (relative `$SCRATCH_REL`), and prompts must reference files by their `$S/...` relative path. `OR_DIR` is the git toplevel so the model can also read `CLAUDE.md`/`conventions/`. Auto-cleaned on exit unless `OPENREVIEW_KEEP_SCRATCH`.

### Sandbox / security in CI (action/action.yml)

The GitHub token is **step-scoped**: only `gather.sh` and `post.sh` receive `GH_TOKEN`; the model pass (`passes.sh`) runs without it. The `@openreview` comment trigger is gated to trusted authors (`OWNER`/`MEMBER`/`COLLABORATOR`) so an arbitrary commenter on a public repo cannot start a secret-bearing run. Read `SECURITY.md` before touching trigger logic.

## Key environment variables

`OR_REPO`, `OR_PR`, `OR_DIR`, `SCRATCH`/`SCRATCH_REL`, `OR_MODEL`, `MARKER`/`MARKER_MATCH` (comment dedup header), `BOT_LOGIN` (whose stale comments `post.sh` prunes in CI), `OPENREVIEW_AUTH_CMD` (runs before opencode to mint/refresh creds).
