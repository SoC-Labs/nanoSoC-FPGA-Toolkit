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
start=$SECONDS

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
    if bash "$t"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1)); failed="$failed $name"
    fi
done

printf '\n===== suite: %d file(s) passed, %d failed, %ds =====\n' \
    "$pass" "$fail" "$((SECONDS - start))"

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
exit 0
