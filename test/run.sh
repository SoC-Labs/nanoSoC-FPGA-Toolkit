#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# test/run.sh - run the toolkit's own tests
#
#   test/run.sh                every test/shell/t_*.sh
#   test/run.sh t_seams        the ones whose name starts with that
#   test/run.sh --list         name them and run nothing
#
# WHY THIS EXISTS: CONTRACT.md section 11.7 makes this file the phase-1
# acceptance gate - "test/run.sh passes, and every assertion in it is paired
# with a mutation proof that the assertion goes red on a planted fault". It
# launches no EDA tool, takes no licence, needs no PDK and no board, and runs in
# a few seconds on a laptop.
#
# THE SUITE LIST IS A GLOB, NEVER A LIST IN THIS FILE. That is CONTRACT.md rule
# three - never hardcode a list a directory already knows - applied to the
# runner itself, and it is not a stylistic point: the reference toolkit's
# five-entry step whitelist against a seven-file directory is the measured
# defect that rule exists for, and a test runner carrying a hardcoded suite list
# would fail SILENTLY in exactly the same shape. A new t_*.sh would simply never
# run, the summary would say every suite passed, and nothing anywhere would
# mention the file that was skipped.
#
# AN EMPTY RUN IS A FAILURE. Zero suites executed is not zero failures; it is no
# measurement at all, which CONTRACT.md section 0 refuses to call a pass. A
# filter that matches nothing, a test directory that lost its files and a
# mistyped path all land here, and all three report red.
#
# Exit status:
#   0   every suite passed
#   1   at least one suite failed, or none ran
#   2   refused: no test/shell directory, or unusable arguments
#   130 interrupted
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOW_DIR="${FLOW_DIR:-$(cd "$HERE/.." && pwd)}"
export FLOW_DIR

usage() { sed -n '3,33p' "$0" | sed 's/^# \{0,1\}//'; }

trap 'echo; echo "test/run.sh: interrupted"; exit 130' INT

LIST_ONLY=0
FILTER=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --list)    LIST_ONLY=1; shift ;;
        -*)        echo "test/run.sh: unknown option '$1'" >&2; usage >&2; exit 2 ;;
        *)         FILTER="$1"; shift ;;
    esac
done

SHELL_DIR="$HERE/shell"
[ -d "$SHELL_DIR" ] || { echo "test/run.sh: no $SHELL_DIR" >&2; exit 2; }

# The glob. `nullglob` so a directory with no suites yields an empty list and
# lands on the empty-run failure below, rather than executing a file called
# literally `t_*.sh`.
shopt -s nullglob
SUITES=("$SHELL_DIR"/t_*.sh)
shopt -u nullglob

if [ "$LIST_ONLY" = 1 ]; then
    printf 'test/shell, discovered by glob (%d):\n' "${#SUITES[@]}"
    for t in "${SUITES[@]}"; do printf '  %s\n' "$(basename "$t" .sh)"; done
    exit 0
fi

printf 'FLOW_DIR %s\n' "$FLOW_DIR"
printf 'suites   %d discovered by glob in %s\n' "${#SUITES[@]}" "$SHELL_DIR"

pass=0; fail=0; failed=""
A_PASS=0; A_FAIL=0; A_XFAIL=0; A_SKIP=0
holes=""; nosummary=""; MUT_RAN=""; MUT_HOLE=""
start=$SECONDS

# Each suite's own summary line is the only place its assertion counts exist, so
# capture the output rather than streaming it straight through. The file is read
# back immediately and the suite's output is printed unchanged.
CAP="$(mktemp -d "${TMPDIR:-/tmp}/fpga-flow-run.XXXXXXXX")"
trap 'rm -rf "$CAP"' EXIT

for t in "${SUITES[@]}"; do
    name="$(basename "$t" .sh)"
    if [ -n "$FILTER" ]; then
        case "$name" in "$FILTER"*) ;; *) continue ;; esac
    fi
    printf '\n===== %s =====\n' "$name"
    # bash "$t", not "$t": a suite that lost its execute bit in a copy, a
    # checkout on a noexec filesystem, or a missing shebang would otherwise be
    # reported as a failing test rather than as an environment problem - and
    # the difference matters at three in the morning.
    rc=0
    bash "$t" > "$CAP/$name.out" 2>&1 || rc=$?
    cat "$CAP/$name.out"
    if [ "$rc" -eq 0 ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1)); failed="$failed $name"
    fi

    # "<file>.sh: N passed, N failed, N known-defect, N skipped"
    sline="$(grep -E ': [0-9]+ passed, [0-9]+ failed,' "$CAP/$name.out" | tail -1)"
    if [ -z "$sline" ]; then
        nosummary="$nosummary $name"
        continue
    fi
    set -- $(printf '%s' "$sline" | sed -E 's/.*: ([0-9]+) passed, ([0-9]+) failed, ([0-9]+) known-defect, ([0-9]+) skipped.*/\1 \2 \3 \4/')
    A_PASS=$((A_PASS + $1)); A_FAIL=$((A_FAIL + $2))
    A_XFAIL=$((A_XFAIL + $3)); A_SKIP=$((A_SKIP + $4))
    # Planted faults this suite rejected, by assertion id. Counted at RUNTIME:
    # three suites plant their faults inside loops, so a grep of the source
    # would under-report them and the ledger would be wrong in the safe-looking
    # direction.
    # Rejections AND skipped proofs. A proof that skipped for a stated reason
    # (no tclsh, running as uid 0, a port that answers) is NOT a proof somebody
    # deleted, and reporting it as one would fail the same cause twice - run.sh
    # already grades skips through the hole and ratio gates. Counting both keeps
    # the ledger answering exactly one question: does this suite still CARRY the
    # proofs it claims?
    _mok=$(grep -cE '^  ok +[A-Za-z0-9_.]*\.mutation([. ]|$)' "$CAP/$name.out")
    _msk=$(grep -cE '^  -- +[A-Za-z0-9_.]*\.mutation([. ]|$)' "$CAP/$name.out")
    MUT_RAN="$MUT_RAN $name=$((_mok + _msk)):$_mok:$_msk"
    [ "$1" -eq 0 ] && [ "$4" -gt 0 ] && MUT_HOLE="$MUT_HOLE $name"
    # A SUITE THAT ASSERTED NOTHING AND SKIPPED INSTEAD IS A HOLE, and today it
    # reports as a file that passed. t_summary cannot catch this: a suite that
    # does `t_skip all "no tclsh"` HAS recorded something, so it is not the
    # empty suite t_summary refuses. But nothing in the toolkit was measured.
    if [ "$1" -eq 0 ] && [ "$4" -gt 0 ]; then holes="$holes $name"; fi
done

printf '\n===== suite: %d file(s) passed, %d failed, %ds =====\n' \
    "$pass" "$fail" "$((SECONDS - start))"
printf 'assertions: %d passed, %d failed, %d known-defect, %d skipped\n' \
    "$A_PASS" "$A_FAIL" "$A_XFAIL" "$A_SKIP"

if [ "$fail" -gt 0 ]; then
    printf 'failed:%s\n' "$failed"
    exit 1
fi
if [ "$pass" -eq 0 ]; then
    printf 'no test files ran%s - that is a failure, not a pass.\n' \
        "${FILTER:+ (filter '"'"$FILTER"'"')}"
    printf 'Zero suites executed measures nothing; it does not measure zero defects.\n'
    exit 1
fi

#-----------------------------------------------------------------------------
# COVERAGE IS HOST-DEPENDENT, AND A GREEN LINE MUST NOT HIDE THAT
#
# Every suite here skips rather than fails when a precondition is absent - no
# tclsh, no fixture, a sandbox path with a space in it - and a skip carries its
# reason, which is right. What was missing is the AGGREGATE: a CI box without
# tclsh skips five whole suites and still prints "0 failed", because the runner
# counted FILES. The numbers below make the difference visible, and these two
# gates make it fatal.
#
#   a HOLE          a suite that asserted nothing at all and skipped instead.
#                   Nothing in the area it covers was measured on this host.
#   the SKIP RATIO  more than SKIP_MAX_PCT of assertions skipped. Default 10.
#
# Both are overridable for the host that genuinely cannot run something, but the
# override has to be TYPED - which is the whole point. FPGA_TEST_ALLOW_HOLES=1
# says "I know five suites did not run"; it does not say it for you.
#-----------------------------------------------------------------------------
SKIP_MAX_PCT="${FPGA_TEST_SKIP_MAX_PCT:-10}"
rc=0

if [ -n "$nosummary" ]; then
    printf 'suites that printed NO summary line:%s\n' "$nosummary"
    printf '  A suite that exits without a summary crashed, however green the line above.\n'
    rc=1
fi

if [ -n "$holes" ] && [ "${FPGA_TEST_ALLOW_HOLES:-0}" != 1 ]; then
    printf 'suites that measured NOTHING on this host:%s\n' "$holes"
    printf '  Each asserted zero times and skipped instead, so the area it covers is\n'
    printf '  untested here. That is a hole, not a pass. Read the SKIP reasons above -\n'
    printf '  usually a missing tclsh or an absent fixture - or set\n'
    printf '  FPGA_TEST_ALLOW_HOLES=1 to accept them deliberately.\n'
    rc=1
fi

if [ $((A_PASS + A_SKIP)) -gt 0 ]; then
    pct=$(( (A_SKIP * 100) / (A_PASS + A_SKIP) ))
    if [ "$pct" -gt "$SKIP_MAX_PCT" ]; then
        printf '%d%% of assertions were SKIPPED (limit %d%%).\n' "$pct" "$SKIP_MAX_PCT"
        printf '  A run that skipped most of what it was going to measure is not a\n'
        printf '  green run. Raise the limit with FPGA_TEST_SKIP_MAX_PCT= if this host\n'
        printf '  genuinely cannot run them.\n'
        rc=1
    fi
fi

#-----------------------------------------------------------------------------
# THE MUTATION LEDGER
#
# test/MUTATION_COVERAGE declares how many planted faults each suite must
# reject. Deleting a proof otherwise costs one `ok` line and nothing else - the
# suite still exits 0 - so a guard can lose its only evidence that it can fail
# and the run stays green. See that file's header for why the comparison is red
# in BOTH directions.
#
# Suites that did not run are not compared: run.sh's hole gate has already
# reported them, and failing the same cause twice teaches the reader to skim.
#-----------------------------------------------------------------------------
LEDGER="$HERE/MUTATION_COVERAGE"
if [ -z "$FILTER" ] && [ -f "$LEDGER" ]; then
    mut_bad=""; mut_total=0; mut_skipped=""
    for entry in $MUT_RAN; do
        mname="${entry%%=*}"; _rest="${entry#*=}"
        mgot="${_rest%%:*}"; _tail="${_rest#*:}"
        mrej="${_tail%%:*}"; mskp="${_tail##*:}"
        case " $MUT_HOLE " in *" $mname "*) continue ;; esac
        mwant="$(awk -v n="$mname" '$1==n {print $2; exit}' "$LEDGER")"
        mut_total=$((mut_total + mrej))
        [ "$mskp" -gt 0 ] && mut_skipped="$mut_skipped $mname($mskp)"
        if [ -z "$mwant" ]; then
            mut_bad="$mut_bad
  $mname is not in the ledger at all - it carries $mgot planted fault(s) that
    nothing has declared. Add the line."
        elif [ "$mgot" -lt "$mwant" ]; then
            mut_bad="$mut_bad
  $mname rejected $mgot planted fault(s); the ledger declares $mwant.
    A PROOF WAS DROPPED. Something that used to be proven able to fail is not."
        elif [ "$mgot" -gt "$mwant" ]; then
            mut_bad="$mut_bad
  $mname rejected $mgot planted fault(s); the ledger declares $mwant.
    A proof was added. Read the new case, then update test/MUTATION_COVERAGE."
        fi
    done
    printf 'mutation:   %d planted faults rejected\n' "$mut_total"
    [ -n "$mut_skipped" ] && printf '            proofs SKIPPED (precondition absent):%s\n' "$mut_skipped"
    if [ -n "$mut_bad" ]; then
        printf 'test/MUTATION_COVERAGE disagrees with what ran:%s\n' "$mut_bad"
        rc=1
    fi
elif [ -n "$FILTER" ]; then
    printf 'mutation:   ledger NOT checked - a filtered run measures a subset\n'
fi

exit $rc
