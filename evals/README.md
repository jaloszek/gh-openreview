# Evals

A small regression harness for the **review engine** itself. The core value of
this toolkit is review *quality*, so these evals guard against silent
regressions when a prompt, the default model, or an opencode version changes.

Each fixture is a self-contained PR (a diff plus metadata) with a declarative
`expected.json` describing what a good review must — and must not — say. The
runner feeds the diff through the real 3-pass pipeline (`lib/passes.sh`) and
scores the rendered comment.

It makes **real model calls** (so it needs opencode + credentials, exactly like
`gh openreview doctor`), but needs **no GitHub token** — the engine only ever
reads the local scratch files the harness prepares.

## Running

```bash
evals/run.sh                 # run every fixture
evals/run.sh sql-injection   # run one fixture by directory name
evals/run.sh --model <id>    # override the model (default: bundled free model)
```

Exit status is non-zero if any fixture fails, so `run.sh` doubles as a gate.
The bundled `opencode.json` (deny bash/web) is pinned for reproducibility unless
you export your own `OPENCODE_CONFIG`.

## Adding a fixture

Create a directory under `fixtures/<name>/` with:

| File | Required | Purpose |
|---|---|---|
| `pr.diff` | yes | The diff to review (unified diff, as `gh pr diff` emits). |
| `pr-meta.json` | no | `{ "title", "body", "files" }`, as `gh pr view --json title,body,files`. A stub is used if absent. |
| `expected.json` | no | The assertions (below). With none, only the format contract is checked. |

### `expected.json` assertions

| Key | Type | Meaning |
|---|---|---|
| `description` | string | Human note; ignored by the scorer. |
| `expect_no_findings` | bool | The review must render the ✅ "no blocking issues" line (i.e. *zero* findings, nits included — strict; small models may emit a stray nit). |
| `must_match` | string[] | Each regex (case-insensitive, ERE) must appear in the rendered review. |
| `must_not_match` | string[] | Each regex must be absent. |
| `min_important` | number | At least N rendered important findings (counted by the 🔴 glyph — approximate). |

Two invariants are always checked, regardless of `expected.json`: the first line
carries the marker header, and no pre-existing (🟣) finding is ever rendered.

## Design notes

- **The most valuable fixture is a clean diff** (`clean-diff/`) — it directly
  guards the project's goal of cutting false positives. Assert `must_not_match:
  ["🔴"]` so a correct change never produces a blocking finding.
- Scoring is intentionally deterministic (grep/jq over the rendered Markdown), so
  results are explainable and the harness has no extra dependencies beyond `jq`.
  A future enhancement could add an LLM-judge mode for grading prose quality.
- Because runs hit a live model, output varies slightly between runs. Keep
  assertions about *substance* (a regex like `inject|parameteri`) rather than
  exact wording.
