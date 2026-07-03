#!/usr/bin/env bash
# eval/run.sh — score the review engine (lib/passes.sh + lib/render.sh)
# against frozen scratch fixtures with golden seeded bugs. No GitHub token
# is needed anywhere: fixtures replace the gather step entirely.
#
# Usage:
#   eval/run.sh [fixture ...]   # default: every dir under eval/fixtures/
#   eval/run.sh --selftest      # deterministic matcher self-test, no LLM call
#
# Env:
#   EVAL_RUNS                 repetitions per fixture (default 1) — the
#                             per-bug "found m/k" column needs k>1 to be useful
#   OPENREVIEW_MODEL          model for the generate pass (see lib/common.sh)
#   OPENREVIEW_VERIFY_MODEL / OPENREVIEW_CHEAP_MODEL / OPENREVIEW_PASS_TIMEOUT
#                             passed through to lib/passes.sh unchanged
#
# Scoring: a finding matches a golden bug when the file is identical AND the
# line is within +-5. A fixture WITHOUT a golden TSV (eval/golden/<name>.tsv)
# is a clean control: ANY important finding fails the run (exit non-zero).
# Machine-readable results: eval/.work/scorecard.tsv (fixture \t key \t value).
set -euo pipefail

EVAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$EVAL_DIR/.." && pwd)"
. "$ROOT/lib/common.sh"

WORK="$EVAL_DIR/.work"
SCORECARD="$WORK/scorecard.tsv"
EVAL_RUNS_SET="${EVAL_RUNS+1}"   # non-empty iff the env var was explicitly exported
RUNS="${EVAL_RUNS:-1}"
case "$RUNS" in ''|*[!0-9]*|0) RUNS=1 ;; esac
TOL=5

HARD_FAIL=0    # a fixture whose every run crashed the engine
CLEAN_FAIL=0   # a clean control produced an important finding
EXPECT_FAIL=0  # a fixture violated its .expect budget/must-catch

# --- parsing & matching (shared by real runs and --selftest) ------------------

# parse_findings <review-verified.md>
# stdout TSV, one row per @@FINDING record: sev \t path \t line \t title
parse_findings() {
  awk '
    function flush() {
      if (have && loc != "") {
        gsub(/`/, "", loc)
        path = loc; line = 0
        idx = match(loc, /:[0-9]+$/)
        if (idx > 0) { path = substr(loc, 1, idx - 1); line = substr(loc, idx + 1) + 0 }
        if (sev != "important") sev = "nit"
        gsub(/\t/, " ", title)
        printf "%s\t%s\t%s\t%s\n", sev, path, line, title
      }
      have = 0; sev = ""; loc = ""; title = ""
    }
    /^@@PRDESC[[:space:]]*$/ { flush(); mode = ""; next }
    /^@@FINDING[[:space:]]*$/ { flush(); mode = "f"; have = 1; next }
    mode == "f" {
      if      ($0 ~ /^sev:/)   { sub(/^sev:[[:space:]]*/, "");   sev = tolower($0) }
      else if ($0 ~ /^loc:/)   { sub(/^loc:[[:space:]]*/, "");   loc = $0 }
      else if ($0 ~ /^title:/) { sub(/^title:[[:space:]]*/, ""); title = $0 }
    }
    END { flush() }
  ' "$1"
}

# score_run <findings.tsv> <golden.tsv> <perbug-out>
# stdout: nfindings \t nmatched \t nimportant \t nnit
# perbug-out: <bug-id> \t <0|1 hit-any> \t <0|1 hit-as-important> for every
# golden bug, in golden order.
score_run() {
  awk -F'\t' -v OFS='\t' -v tol="$TOL" -v perbug="$3" '
    NR == FNR {
      if ($0 ~ /^#/ || NF < 3) next
      ng++; gid[ng] = $1; gfile[ng] = $2; gline[ng] = $3 + 0
      next
    }
    NF >= 3 { nf++; fsev[nf] = $1; ffile[nf] = $2; fline[nf] = $3 + 0 }
    END {
      for (i = 1; i <= nf; i++) {
        m = 0
        for (g = 1; g <= ng; g++) {
          d = fline[i] - gline[g]; if (d < 0) d = -d
          if (ffile[i] == gfile[g] && d <= tol) {
            m = 1; hit[g] = 1
            if (fsev[i] == "important") hitimp[g] = 1
          }
        }
        if (m) matched++
        if (fsev[i] == "important") nimp++; else nnit++
      }
      for (g = 1; g <= ng; g++) print gid[g], (g in hit ? 1 : 0), (g in hitimp ? 1 : 0) > perbug
      print nf + 0, matched + 0, nimp + 0, nnit + 0
    }
  ' "$2" "$1"
}

# clean_verdict <findings.tsv> — the clean-control gate: succeeds only when
# the run produced zero important findings.
clean_verdict() {
  local nimp
  nimp=$(awk -F'\t' '$1 == "important" { c++ } END { print c + 0 }' "$1")
  [ "$nimp" -eq 0 ]
}

# expect_get <expect-file> <KEY> — print the value of the last KEY=VALUE line
# (comments/blank lines ignored); empty stdout if absent or file missing.
expect_get() {
  [ -f "$1" ] || return 0
  grep -E "^[[:space:]]*$2=" "$1" 2>/dev/null | tail -n1 | cut -d= -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true
}

# check_expectations <name> <expect-file> <n-important> <n-nit> <n-total> <perbug-agg-or-empty>
# Grades MAX_IMPORTANTS/MAX_NITS/MAX_TOTAL/MUST_CATCH from the expect file
# against the totals for one fixture. Appends expect_<key> pass/fail rows to
# the scorecard, prints a "✗ expectation failed: ..." line per violation, and
# sets the global EXPECT_FAIL flag on any violation. A no-op when the fixture
# has no expect file.
check_expectations() {
  local name="$1" expect="$2" imp="$3" nit="$4" total="$5" perbug="$6"
  local val

  [ -f "$expect" ] || return 0

  val=$(expect_get "$expect" MAX_IMPORTANTS)
  if [ -n "$val" ]; then
    if [ "$imp" -gt "$val" ]; then
      warn "✗ expectation failed: $name MAX_IMPORTANTS=$val but got $imp important finding(s)"
      printf '%s\texpect_max_importants\tfail\n' "$name" >> "$SCORECARD"
      EXPECT_FAIL=1
    else
      printf '%s\texpect_max_importants\tpass\n' "$name" >> "$SCORECARD"
    fi
  fi

  val=$(expect_get "$expect" MAX_NITS)
  if [ -n "$val" ]; then
    if [ "$nit" -gt "$val" ]; then
      warn "✗ expectation failed: $name MAX_NITS=$val but got $nit nit(s)"
      printf '%s\texpect_max_nits\tfail\n' "$name" >> "$SCORECARD"
      EXPECT_FAIL=1
    else
      printf '%s\texpect_max_nits\tpass\n' "$name" >> "$SCORECARD"
    fi
  fi

  val=$(expect_get "$expect" MAX_TOTAL)
  if [ -n "$val" ]; then
    if [ "$total" -gt "$val" ]; then
      warn "✗ expectation failed: $name MAX_TOTAL=$val but got $total finding(s)"
      printf '%s\texpect_max_total\tfail\n' "$name" >> "$SCORECARD"
      EXPECT_FAIL=1
    else
      printf '%s\texpect_max_total\tpass\n' "$name" >> "$SCORECARD"
    fi
  fi

  val=$(expect_get "$expect" MUST_CATCH)
  if [ -n "$val" ]; then
    local id hitimp missed=""
    local oldifs="$IFS"; IFS=','
    for id in $val; do
      hitimp=""
      if [ -n "$perbug" ] && [ -f "$perbug" ]; then
        hitimp=$(awk -F'\t' -v id="$id" '$1 == id { print $5 }' "$perbug")
      fi
      if [ "${hitimp:-0}" -eq 0 ]; then
        missed="$missed $id"
      fi
    done
    IFS="$oldifs"
    if [ -n "$missed" ]; then
      warn "✗ expectation failed: $name MUST_CATCH missed:$missed"
      printf '%s\texpect_must_catch\tfail\n' "$name" >> "$SCORECARD"
      EXPECT_FAIL=1
    else
      printf '%s\texpect_must_catch\tpass\n' "$name" >> "$SCORECARD"
    fi
  fi
}

# warn_once_no_tree <fixture> — warn that a fixture has no tree/ (agentic file
# reads will see an empty project), but only once per fixture per run.py
# invocation, no matter how many repetitions (EVAL_RUNS) it has.
NO_TREE_WARNED=""
warn_once_no_tree() {
  case " $NO_TREE_WARNED " in
    *" $1 "*) return 0 ;;
  esac
  NO_TREE_WARNED="$NO_TREE_WARNED $1"
  warn "[$1] no tree/ — agentic file reads will see an empty project"
}

# --- one fixture --------------------------------------------------------------

run_fixture() {
  local name="$1"
  local fixdir="$EVAL_DIR/fixtures/$name"
  local golden="$EVAL_DIR/golden/$name.tsv"
  local expect="$EVAL_DIR/golden/$name.expect"
  local fdir="$WORK/$name"
  local run rdir scratch ok_runs=0
  local runs="$RUNS" runs_default

  [ -d "$fixdir" ] || die "unknown fixture: $name (no $fixdir)"
  [ -f "$fixdir/pr-numbered.diff" ] || die "fixture $name is missing pr-numbered.diff — run: eval/freeze.sh eval/fixtures/$name"

  # env EVAL_RUNS always wins; otherwise an expect file's RUNS_DEFAULT applies.
  if [ -z "$EVAL_RUNS_SET" ] && [ -f "$expect" ]; then
    runs_default=$(expect_get "$expect" RUNS_DEFAULT)
    case "$runs_default" in ''|*[!0-9]*|0) : ;; *) runs="$runs_default" ;; esac
  fi

  rm -rf "$fdir"
  mkdir -p "$fdir"
  : > "$fdir/stats.tsv"

  run=1
  while [ "$run" -le "$runs" ]; do
    rdir="$fdir/run$run"
    scratch="$rdir/.openreview-tmp"
    mkdir -p "$scratch"
    find "$fixdir" -maxdepth 1 -type f -exec cp {} "$scratch/" \;
    # tree/ is the post-PR checkout of the invented project: copy it into the
    # run dir ROOT (the project dir opencode sees) so the model's file reads
    # land on real source, not an empty project. Scratch context files above
    # still go to .openreview-tmp/ regardless.
    if [ -d "$fixdir/tree" ]; then
      cp -R "$fixdir/tree/." "$rdir/"
    else
      warn_once_no_tree "$name"
    fi
    # opencode scopes its read/write sandbox to the enclosing project (git)
    # root. Make each run dir its own root so the model's relative $S/ paths
    # resolve against the copied fixture, not this repository.
    if command -v git >/dev/null 2>&1 && [ ! -d "$rdir/.git" ]; then
      git init -q "$rdir" 2>/dev/null || true
    fi
    info "[$name $run/$runs] running passes.sh + render.sh"
    if OR_DIR="$rdir" SCRATCH="$scratch" SCRATCH_REL=".openreview-tmp" bash "$ROOT/lib/passes.sh" \
       && OR_DIR="$rdir" SCRATCH="$scratch" SCRATCH_REL=".openreview-tmp" bash "$ROOT/lib/render.sh"; then
      parse_findings "$scratch/review-verified.md" > "$rdir/findings.tsv"
      if [ -f "$golden" ]; then
        score_run "$rdir/findings.tsv" "$golden" "$rdir/perbug.tsv" >> "$fdir/stats.tsv"
      else
        awk -F'\t' -v OFS='\t' '
          NF >= 3 { n++; if ($1 == "important") i++; else t++ }
          END { print n + 0, 0, i + 0, t + 0 }
        ' "$rdir/findings.tsv" >> "$fdir/stats.tsv"
        # Only the neither-golden-nor-expect fixtures use the strict
        # zero-important clean-control gate; expect-only fixtures grade on
        # their own budgets instead (see check_expectations below).
        if [ ! -f "$expect" ] && ! clean_verdict "$rdir/findings.tsv"; then
          warn "[$name $run/$runs] clean control produced important finding(s)"
          CLEAN_FAIL=1
        fi
      fi
      ok_runs=$((ok_runs + 1))
    else
      warn "[$name $run/$runs] engine failed — run excluded from aggregates"
    fi
    run=$((run + 1))
  done

  if [ "$ok_runs" -eq 0 ]; then
    warn "$name: all $runs run(s) failed"
    printf '%s\tstatus\tengine-failed\n' "$name" >> "$SCORECARD"
    HARD_FAIL=1
    return 0
  fi

  # Totals across successful runs: findings, matched, important, nits.
  local t_nf t_match t_imp t_nit
  read -r t_nf t_match t_imp t_nit <<EOF
$(awk -F'\t' '{ a += $1; b += $2; c += $3; d += $4 } END { printf "%d %d %d %d", a, b, c, d }' "$fdir/stats.tsv")
EOF

  printf '\n== %s ==\n' "$name"
  printf 'runs: %d ok / %d requested   model: %s\n' "$ok_runs" "$runs" "${OPENREVIEW_MODEL:-<default>}"
  printf 'findings: %d total (%d important, %d nits) across %d run(s)\n' "$t_nf" "$t_imp" "$t_nit" "$ok_runs"
  {
    printf '%s\truns_ok\t%d\n' "$name" "$ok_runs"
    printf '%s\tfindings_total\t%d\n' "$name" "$t_nf"
    printf '%s\tfindings_important\t%d\n' "$name" "$t_imp"
    printf '%s\tfindings_nit\t%d\n' "$name" "$t_nit"
  } >> "$SCORECARD"

  if [ ! -f "$golden" ]; then
    if [ -f "$expect" ]; then
      printf 'budget-only fixture (no golden): skipping recall/precision\n'
      printf '%s\tstatus\tbudget-only\n' "$name" >> "$SCORECARD"
    elif [ "$t_imp" -gt 0 ]; then
      printf 'clean control: FAIL — %d important finding(s) on a clean diff\n' "$t_imp"
      printf '%s\tstatus\tclean-fail\n' "$name" >> "$SCORECARD"
    else
      printf 'clean control: PASS — no important findings\n'
      printf '%s\tstatus\tclean-pass\n' "$name" >> "$SCORECARD"
    fi
    check_expectations "$name" "$expect" "$t_imp" "$t_nit" "$t_nf" ""
    return 0
  fi

  # Per-bug aggregate over successful runs: id, category, sev, hit-any, hit-important, k.
  awk -F'\t' -v OFS='\t' -v k="$ok_runs" '
    NR == FNR {
      if ($0 ~ /^#/ || NF < 5) next
      n++; id[n] = $1; cat[n] = $4; sev[n] = $5
      next
    }
    { hits[$1] += $2; hitsimp[$1] += $3 }
    END { for (i = 1; i <= n; i++) print id[i], cat[i], sev[i], hits[id[i]] + 0, hitsimp[id[i]] + 0, k }
  ' "$golden" "$fdir"/run*/perbug.tsv > "$fdir/perbug-agg.tsv"

  # Recall: a bug counts as found when hit in >=1 run.
  local rec_all rec_imp precision
  rec_all=$(awk -F'\t' '{ n++; if ($4 > 0) f++ } END { printf "%d/%d = %.2f", f + 0, n, (n ? (f + 0) / n : 0) }' "$fdir/perbug-agg.tsv")
  rec_imp=$(awk -F'\t' '$3 == "important" { n++; if ($4 > 0) f++ } END { printf "%d/%d = %.2f", f + 0, n, (n ? (f + 0) / n : 0) }' "$fdir/perbug-agg.tsv")
  precision=$(awk -v m="$t_match" -v t="$t_nf" 'BEGIN { printf "%d/%d = %.2f", m, t, (t ? m / t : 0) }')

  printf 'precision (matched findings / all findings): %s\n' "$precision"
  printf 'recall overall:        %s\n' "$rec_all"
  printf 'recall important-only: %s\n' "$rec_imp"
  printf 'recall by category:\n'
  awk -F'\t' '
    { n[$2]++; if ($4 > 0) f[$2]++ }
    END { for (c in n) printf "  %-15s %d/%d\n", c, f[c] + 0, n[c] }
  ' "$fdir/perbug-agg.tsv" | LC_ALL=C sort
  printf 'per-bug (found m/k):\n'
  awk -F'\t' '{ printf "  %-4s %-15s %-10s found %d/%d\n", $1, $2, $3, $4, $6 }' "$fdir/perbug-agg.tsv"

  {
    printf '%s\tprecision\t%s\n' "$name" "$precision"
    printf '%s\trecall_overall\t%s\n' "$name" "$rec_all"
    printf '%s\trecall_important\t%s\n' "$name" "$rec_imp"
    awk -F'\t' -v fx="$name" -v OFS='\t' '
      { n[$2]++; if ($4 > 0) f[$2]++ }
      END { for (c in n) print fx, "recall_cat:" c, (f[c] + 0) "/" n[c] }
    ' "$fdir/perbug-agg.tsv" | LC_ALL=C sort
    awk -F'\t' -v fx="$name" -v OFS='\t' '{ print fx, "bug:" $1, $4 "/" $6 }' "$fdir/perbug-agg.tsv"
    printf '%s\tstatus\tscored\n' "$name"
  } >> "$SCORECARD"

  check_expectations "$name" "$expect" "$t_imp" "$t_nit" "$t_nf" "$fdir/perbug-agg.tsv"
}

# --- selftest: matcher logic against canned findings, no LLM ------------------

selftest() {
  local tdir="$WORK/selftest" golden="$EVAL_DIR/golden/playground.tsv"
  local stats fails=0 bug want got
  rm -rf "$tdir"
  mkdir -p "$tdir"

  parse_findings "$EVAL_DIR/selftest/review-verified.md" > "$tdir/findings.tsv"
  stats=$(score_run "$tdir/findings.tsv" "$golden" "$tdir/perbug.tsv")

  # 6 canned findings: 4 match (one of them hits two clustered bugs), 2 miss.
  want=$(printf '6\t4\t4\t2')
  if [ "$stats" != "$want" ]; then
    warn "selftest: stats mismatch — want [$want] got [$stats]"
    fails=$((fails + 1))
  fi

  # Expected per-bug hits: B01 exact, B03 -1, B06 +4, B07 via the B09-adjacent
  # storage.py:44 finding, B09 exact. Everything else must be a miss.
  for bug in B01:1 B02:0 B03:1 B04:0 B05:0 B06:1 B07:1 B08:0 B09:1 B10:0 B11:0 B12:0; do
    want="${bug#*:}"
    got=$(awk -F'\t' -v id="${bug%%:*}" '$1 == id { print $2 }' "$tdir/perbug.tsv")
    if [ "$got" != "$want" ]; then
      warn "selftest: ${bug%%:*} — want hit=$want got hit=${got:-<absent>}"
      fails=$((fails + 1))
    fi
  done

  # Clean-control path: a doctored important finding must fail the verdict,
  # a findings-free file must pass it.
  parse_findings "$EVAL_DIR/selftest/clean-important.md" > "$tdir/clean-important.tsv"
  if clean_verdict "$tdir/clean-important.tsv"; then
    warn "selftest: doctored important finding did NOT fail the clean verdict"
    fails=$((fails + 1))
  fi
  parse_findings "$EVAL_DIR/selftest/clean-ok.md" > "$tdir/clean-ok.tsv"
  if ! clean_verdict "$tdir/clean-ok.tsv"; then
    warn "selftest: clean findings file failed the clean verdict"
    fails=$((fails + 1))
  fi

  # --- expectation grading: budget pass/fail, must-catch hit/miss, expect-only

  # Per-bug aggregate (1 run) from the same 6 canned findings, needed for the
  # MUST_CATCH checks below: id, cat, sev, hit-any, hit-important, k.
  awk -F'\t' -v OFS='\t' -v k=1 '
    NR == FNR {
      if ($0 ~ /^#/ || NF < 5) next
      n++; id[n] = $1; cat[n] = $4; sev[n] = $5
      next
    }
    { hits[$1] += $2; hitsimp[$1] += $3 }
    END { for (i = 1; i <= n; i++) print id[i], cat[i], sev[i], hits[id[i]] + 0, hitsimp[id[i]] + 0, k }
  ' "$golden" "$tdir/perbug.tsv" > "$tdir/perbug-agg.tsv"

  # Case 1: budget pass — the canned run has 4 importants, 2 nits, 6 total.
  printf 'MAX_IMPORTANTS=4\nMAX_NITS=2\nMAX_TOTAL=6\n' > "$tdir/expect-budget-pass"
  EXPECT_FAIL=0
  check_expectations selftest-budget-pass "$tdir/expect-budget-pass" 4 2 6 "$tdir/perbug-agg.tsv"
  if [ "$EXPECT_FAIL" -ne 0 ]; then
    warn "selftest: budget-pass case unexpectedly failed"
    fails=$((fails + 1))
  fi

  # Case 2: budget fail — MAX_NITS=0 against a run that has a nit.
  printf 'MAX_NITS=0\n' > "$tdir/expect-budget-fail"
  EXPECT_FAIL=0
  check_expectations selftest-budget-fail "$tdir/expect-budget-fail" 4 2 6 "$tdir/perbug-agg.tsv"
  if [ "$EXPECT_FAIL" -eq 0 ]; then
    warn "selftest: budget-fail case (MAX_NITS=0 with a nit present) unexpectedly passed"
    fails=$((fails + 1))
  fi

  # Case 3: must-catch hit — B01 and B09 were both matched by important findings.
  printf 'MUST_CATCH=B01,B09\n' > "$tdir/expect-mustcatch-hit"
  EXPECT_FAIL=0
  check_expectations selftest-mustcatch-hit "$tdir/expect-mustcatch-hit" 4 2 6 "$tdir/perbug-agg.tsv"
  if [ "$EXPECT_FAIL" -ne 0 ]; then
    warn "selftest: must-catch-hit case unexpectedly failed"
    fails=$((fails + 1))
  fi

  # Case 4: must-catch miss — B02 was never matched by anything.
  printf 'MUST_CATCH=B02\n' > "$tdir/expect-mustcatch-miss"
  EXPECT_FAIL=0
  check_expectations selftest-mustcatch-miss "$tdir/expect-mustcatch-miss" 4 2 6 "$tdir/perbug-agg.tsv"
  if [ "$EXPECT_FAIL" -eq 0 ]; then
    warn "selftest: must-catch-miss case (B02 never matched) unexpectedly passed"
    fails=$((fails + 1))
  fi

  # Case 5: expect-only fixture (no golden) — budgets are enforced instead of
  # the strict zero-important clean verdict; 1 important finding is fine when
  # MAX_IMPORTANTS=1 allows it (clean_verdict would have failed this).
  printf 'MAX_IMPORTANTS=1\n' > "$tdir/expect-only"
  EXPECT_FAIL=0
  check_expectations selftest-expect-only "$tdir/expect-only" 1 0 1 ""
  if [ "$EXPECT_FAIL" -ne 0 ]; then
    warn "selftest: expect-only budget-pass case unexpectedly failed"
    fails=$((fails + 1))
  fi

  EXPECT_FAIL=0

  [ "$fails" -eq 0 ] || die "selftest: $fails check(s) failed"
  ok "selftest: PASS (parse + match + clean-verdict + expectations, no LLM call)"
}

# --- main ----------------------------------------------------------------------

mkdir -p "$WORK"

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit 0
fi

need_cmd opencode
printf '# fixture\tkey\tvalue\n' > "$SCORECARD"

if [ "$#" -ge 1 ]; then
  FIXTURES="$*"
else
  FIXTURES=""
  for d in "$EVAL_DIR"/fixtures/*/; do
    [ -d "$d" ] || continue
    FIXTURES="$FIXTURES $(basename "$d")"
  done
fi
[ -n "${FIXTURES// /}" ] || die "no fixtures found under eval/fixtures/"

for f in $FIXTURES; do
  run_fixture "$f"
done

printf '\nscorecard: %s\n' "$SCORECARD"
if [ "$CLEAN_FAIL" -ne 0 ]; then
  die "clean control failed: important finding(s) reported on a clean diff"
fi
if [ "$EXPECT_FAIL" -ne 0 ]; then
  die "one or more fixtures violated their .expect budget/must-catch"
fi
if [ "$HARD_FAIL" -ne 0 ]; then
  die "one or more fixtures had no successful engine run"
fi
ok "eval complete"
