# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`gh-openreview` is a single, provider-agnostic **GitHub Action that reviews pull
requests** with an LLM. It is plain Bash (no build step). The LLM work is
delegated to the [opencode](https://opencode.ai) harness
(`opencode run -m <model> <prompt>`); GitHub access is delegated to `gh`. The
action implements neither auth.

> History: this repo used to also ship a `gh` CLI extension with
> `review`/`resolve`/`inbox`/`assist`/`doctor` subcommands. That surface was
> removed — the repo is now exclusively the action. Don't reintroduce it.

## Commands

```bash
# Lint before any PR (required)
shellcheck -S warning lib/*.sh
actionlint .github/workflows/*.yml

# Run the engine locally against a real PR (reads env vars the action sets)
export OR_REPO=owner/repo OR_PR=123
export OR_DIR="$PWD" SCRATCH="$PWD/.openreview-tmp" SCRATCH_REL=".openreview-tmp"
export OPENREVIEW_MODEL=opencode/deepseek-v4-flash-free
mkdir -p "$SCRATCH"
GH_TOKEN=$(gh auth token) lib/gather.sh   # token-scoped
lib/passes.sh                              # LLM passes, no token
lib/render.sh                              # deterministic
cat "$SCRATCH/opencode-review.md"          # inspect; post.sh would publish it
```

There is no unit-test suite yet. The repo dogfoods: it reviews its own PRs via
`.github/workflows/self-test.yml`.

## Architecture

`action/action.yml` is the only entrypoint — a composite action that wires the
`lib/` scripts as steps. Every lib script sources `lib/common.sh` first. The
steps run in this order, and the **GitHub token is step-scoped**:

1. **`lib/gather.sh`** (token) — pre-fetch PR context into `$SCRATCH`: `pr.diff`
   (with generated/vendored paths excluded + a size cap), `pr-meta.json`, linked
   issues, commit messages, prior review threads (`pr-comments.md`), and the last
   bot review (`prev-review.md`).
2. **`lib/passes.sh`** (no token) — the two LLM passes.
3. **`lib/render.sh`** (no token) — deterministic comment builder.
4. **`lib/metrics.sh`** (no token) — telemetry to step summary + action outputs.
5. **`lib/post.sh`** (token) — post the comment + prune stale ones.

`render`/`metrics`/`post` run only when the prior step succeeded, so an engine
failure never posts a misleading comment.

- **`lib/common.sh`** — shared helpers, sourced not executed. Owns: logging
  (`log`/`info`/`warn`/`ok`/`die`), `resolve_model`, `resolve_verify_model`,
  `prepare_opencode_config`, and `oc_run` (the opencode invocation, with a
  per-pass `timeout` + one retry; captures the real exit status via `|| rc=$?`).

### The model pipeline (passes.sh)

Two opencode passes writing intermediate files into `$SCRATCH`:

1. **generate** → `review-candidates.md`
2. **verify** (skipped when pass 1 found nothing) → `review-verified.md`

There is **no LLM format pass** — `render.sh` parses the verified findings and
builds `opencode-review.md` deterministically (free, fixed output shape).

The static prompt text (persona/rules/DROP-criteria blocks, the shared
FORMAT_SPEC) lives in versioned files under `prompts/`, cat'd and concatenated
by `passes.sh`; only the dynamic parts (context file lists, incremental note,
anything embedding `$S`) stay assembled inline. `engine_fingerprint` hashes
`prompts/*.txt` alongside `passes.sh`, so a prompt edit invalidates the skip
guard exactly like a code change.

Both passes emit a strict record format that `render.sh` parses:

```
@@FINDING
sev: important|nit
loc: file:line
conf: high|med|low
title: one short line
body: one-to-three sentences on a single line
@@PRDESC
<freeform suggested PR title/body to end of file>
```

No `@@FINDING` blocks ⇒ no findings (render emits "✅ No blocking issues").
`render.sh` selects all important findings + the top `OPENREVIEW_NIT_CAP` (3)
nits, sorted by severity then confidence with an `NR` tie-breaker for stable
ordering.

### Conventions that matter

- **stdout is reserved for command output; everything else (logs, progress) goes
  to stderr.** Use the `common.sh` logging helpers, never bare `echo` for status.
- **Bash 3.2+ only** (stock macOS). No `mapfile`, no associative arrays, no
  Bash-4 features.
- **No hard `jq` dependency** — use `gh`'s built-in `--jq`. When a value must go
  into a jq filter, pass it via the environment and reference `env.VAR` inside
  the filter rather than string-interpolating it (avoids breakage on quotes).
- **Config precedence is never overwritten** (`prepare_opencode_config`):
  `OPENCODE_CONFIG` env → project `./opencode.json(c)` → `~/.config/opencode/` →
  the bundled `opencode.json` (fallback only). The bundled config denies
  `bash`/`webfetch`/`websearch` to the model.
- **Model precedence** (`resolve_model`): `OPENREVIEW_MODEL` → `OC_MODEL` →
  a pre-exported `OR_MODEL` → bundled free model. The verify pass uses a
  (typically cheaper) tier via `resolve_verify_model` (`verify-model` input →
  main model).

### Scratch directory contract

opencode's read/write tools are **sandboxed to the project directory** —
absolute paths and `/tmp` are rejected. So scratch lives at
`$OR_DIR/.openreview-tmp` (relative `$SCRATCH_REL`), and prompts reference files
by their `$S/...` relative path. `OR_DIR` is the git toplevel so the model can
also read `CLAUDE.md`/`conventions/`.

### Security in CI (action/action.yml)

The GitHub token is **step-scoped**: only `gather.sh` and `post.sh` receive
`GH_TOKEN`; the model passes run without it. The `@openreview` comment trigger is
gated to trusted authors (`OWNER`/`MEMBER`/`COLLABORATOR`) so an arbitrary
commenter on a public repo cannot start a secret-bearing run. Read `SECURITY.md`
before touching trigger logic.

## Key environment variables

`OR_REPO`, `OR_PR`, `OR_DIR`, `SCRATCH`/`SCRATCH_REL`, `OPENREVIEW_MODEL`
/`OPENREVIEW_VERIFY_MODEL`, `MARKER`/`MARKER_MATCH` (comment dedup header/token),
`BOT_LOGIN` (whose stale comments `post.sh` prunes), `OPENREVIEW_DIFF_EXCLUDE`
/`OPENREVIEW_DIFF_MAX_LINES` (diff trimming), `OPENREVIEW_PASS_TIMEOUT`
(per-pass seconds), `OPENREVIEW_AUTH_CMD` (runs before opencode to mint creds).
