# shellcheck shell=bash
#-----------------------------------------------------------------------------
# test/lib/harness.sh - the assertion model the shell suites share
#
# Sourced, never executed. There is no `bats` on the sites this toolkit runs on,
# and a test harness that has to be installed before the tests can run is a test
# harness nobody runs. This is a few hundred lines of bash and needs nothing but
# bash, make and coreutils - the same three things the flow itself needs before
# a tool is launched.
#
# THE ONE RULE, inherited from ci/lib.sh and from CONTRACT.md section 7: A CHECK
# THAT CANNOT FAIL IS NOT A CHECK. So every assertion in these suites is PAIRED
# WITH A MUTATION PROOF - plant the fault in a throwaway copy of the toolkit,
# show the same assertion goes red, throw the copy away. The proof is a test in
# its own right and runs every time, rather than being a claim in a comment that
# was true once. An assertion with no proof beside it is measuring the suite's
# optimism.
#
# THE SECOND RULE, from CONTRACT.md section 3.5: THIS TOOLKIT COMPOSES `rm -rf`.
# `make distclean RUN_TAG=` collapses RUN_DIR to the whole build tree, and `?=`
# does not default an explicitly empty variable - which is why mk/flow.mk guards
# those values at parse time and why the tests for those guards must never run
# against a directory somebody cares about. Every filesystem mutation here
# happens inside a `t_sandbox` under $TMPDIR, `t_mutant` refuses to hand back a
# path that is not inside one, and `t_mutate` refuses to edit one.
#
# STATUSES
#   ok             the assertion held
#   FAIL           it did not - the suite goes red
#   SKIP           it did not apply here, WITH THE REASON RECORDED. A file that
#                  has not landed yet is a skip and never a pass: a suite that
#                  silently checks nothing is how a green run comes to prove
#                  nothing (CONTRACT.md section 7, the ci_skip row).
#   KNOWN-DEFECT   the assertion is CORRECT and the code does not satisfy it
#                  today. Recorded, not red. If it starts passing the suite goes
#                  RED, so the marker cannot outlive the bug it documents.
#
# Env:
#   T_KEEP=1     keep the sandboxes instead of removing them, and print them
#   T_COLOUR=0   suppress ANSI even on a tty
#   FLOW_DIR     the toolkit under test. Defaults to this file's own ../..
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------

[ -n "${_T_HARNESS_SOURCED:-}" ] && return 0
_T_HARNESS_SOURCED=1

# --- where the toolkit is ----------------------------------------------------
# Derived from this file's own location, per CONTRACT.md section 10, so a suite
# can be run from any working directory. That is not a nicety: every script in
# scripts/ resolves its own location for the same reason, and a suite that only
# worked from the repository root would be unable to catch the case where one of
# them does not.
_T_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOW_DIR="${FLOW_DIR:-$(cd "$_T_LIB/../.." && pwd)}"

for _f in mk/flow.mk ci/lib.sh flow/common/seams.txt; do
    if [ ! -f "$FLOW_DIR/$_f" ]; then
        echo "harness: $FLOW_DIR is not an FPGA-toolkit checkout (no $_f)" >&2
        exit 2
    fi
done
unset _f

T_PASS=0; T_FAIL=0; T_SKIP=0; T_XFAIL=0
T_FILE="$(basename "${0}")"

if [ -t 1 ] && [ "${T_COLOUR:-1}" = 1 ]; then
    _R=$'\033[31m'; _G=$'\033[32m'; _Y=$'\033[33m'; _O=$'\033[0m'
else
    _R=""; _G=""; _Y=""; _O=""
fi

t_head() { printf '\n-- %s --\n' "$*"; }
t_say()  { printf '     %s\n' "$*"; }

t_ok()   { T_PASS=$((T_PASS+1)); printf '%s  ok %s %-52s %s\n' "$_G" "$_O" "$1" "${*:2}"; }
t_fail() { T_FAIL=$((T_FAIL+1)); printf '%sFAIL%s  %-52s %s\n' "$_R" "$_O" "$1" "${*:2}" >&2; }

## t_skip <id> <reason...>   - THE REASON IS MANDATORY.
## A skip with no reason is indistinguishable from a pass in a log, and the
## thing it is hiding - a file that never landed, a tool that is not installed -
## is exactly what the reader needed to know. A reasonless skip is therefore a
## FAILURE of the suite, not a skip.
t_skip() {
    local id="$1"; shift
    if [ "$#" -eq 0 ] || [ -z "${*// /}" ]; then
        t_fail "$id" "SKIPPED WITH NO REASON - a silent skip is a hole in the suite that reads like a pass"
        return 1
    fi
    T_SKIP=$((T_SKIP+1))
    printf '  --  %-52s SKIP: %s\n' "$id" "$*"
}

# --- the four ways to assert -------------------------------------------------
# Each takes a gate id first, so a red line names itself and the name is the
# thing to grep for across an archive of runs - exactly as ci/lib.sh does for
# the flow's own gates (CONTRACT.md section 7).

## t_check <id> <description> <command...>   - the command must exit 0
t_check() {
    local id="$1" desc="$2"; shift 2
    local out rc=0
    out="$("$@" 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ]; then
        t_ok "$id" "$desc"
    else
        t_fail "$id" "$desc"
        printf '%s\n' "$out" | tail -14 | sed 's/^/        /' >&2
    fi
}

## t_check_fail <id> <description> <command...>  - the command must exit NON-zero
##
## THIS IS WHAT A MUTATION PROOF USES. The fault has been planted; the check
## under test must now reject it. If it exits 0 the check accepted a design
## defect, which means the assertion beside it was measuring nothing, and the
## suite says so in those words rather than reporting a quiet pass.
t_check_fail() {
    local id="$1" desc="$2"; shift 2
    local out rc=0
    out="$("$@" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        t_ok "$id" "$desc"
    else
        t_fail "$id" "$desc - THE CHECK ACCEPTED A PLANTED FAULT, so it cannot fail"
        printf '%s\n' "$out" | tail -14 | sed 's/^/        /' >&2
    fi
}

## t_known_defect <id> <description> <command...>
## The assertion is right and the toolkit does not satisfy it today. Recorded
## and NOT red - but if the command starts exiting 0 the suite goes RED, because
## a defect marker that outlives its defect is how a suite starts lying about
## what it covers.
t_known_defect() {
    local id="$1" desc="$2"; shift 2
    if "$@" >/dev/null 2>&1; then
        t_fail "$id" "KNOWN-DEFECT marker is STALE - this now PASSES. Delete the marker: $desc"
    else
        T_XFAIL=$((T_XFAIL+1))
        printf '%sDEFECT%s %-52s %s\n' "$_Y" "$_O" "$id" "$desc"
    fi
}

# --- small predicates, so the suites read as sentences -----------------------
t_contains()   { printf '%s' "$1" | grep -qF -- "$2"; }
t_matches()    { printf '%s' "$1" | grep -qE -- "$2"; }
t_file_has()   { [ -s "$1" ] && grep -qE -- "$2" "$1"; }
t_file_lacks() { [ -f "$1" ] && ! grep -qE -- "$2" "$1"; }

# --- sandboxes ---------------------------------------------------------------
# Every filesystem mutation in these suites happens inside one of these, and the
# EXIT trap removes them. Keep one with T_KEEP=1 when a failure needs reading.

_T_SANDBOXES=()
t_cleanup() {
    [ "${#_T_SANDBOXES[@]}" -eq 0 ] && return 0
    if [ "${T_KEEP:-0}" = 1 ]; then printf '   kept: %s\n' "${_T_SANDBOXES[@]}"; return 0; fi
    local d
    for d in "${_T_SANDBOXES[@]}"; do
        # The name is checked before the rm, not after. This suite exists partly
        # to test guards on a variable that prefixes `rm -rf`, so its own rm gets
        # the same treatment: an unrecognised path is reported, never removed.
        case "$d" in
            /tmp/fpga-flow-test.*|"${TMPDIR%/}"/fpga-flow-test.*) rm -rf "$d" ;;
            *) printf 'harness: refusing to remove %s - not a sandbox\n' "$d" >&2 ;;
        esac
    done
}
trap t_cleanup EXIT

## t_sandbox - sets T_SANDBOX to a fresh temporary directory, removed on exit.
##
## It SETS A VARIABLE rather than printing one, and that is not a style choice.
## `SB=$(t_sandbox)` runs the function in a SUBSHELL, so the registration is
## lost, the parent's list stays empty, and `t_in_sandbox` then answers about a
## list it does not have - which turns the one safety check in a suite full of
## `rm -rf` into a no-op. Call it as:  t_sandbox; SB="$T_SANDBOX"
t_sandbox() {
    T_SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/fpga-flow-test.XXXXXXXX")" || return 1
    _T_SANDBOXES+=("$T_SANDBOX")
    return 0
}

## t_in_sandbox <path> - true when <path> is inside a sandbox this run created.
## An empty sandbox list means NO, never yes.
t_in_sandbox() {
    local p="$1" d
    [ -n "$p" ] || return 1
    [ "${#_T_SANDBOXES[@]}" -eq 0 ] && return 1
    for d in "${_T_SANDBOXES[@]}"; do
        [ -n "$d" ] || continue
        case "$p" in "$d"/*|"$d") return 0 ;; esac
    done
    return 1
}

# --- mutant toolkits ---------------------------------------------------------
# A mutation proof needs a toolkit it may break. It gets a COPY - this
# repository is well under a megabyte of text - never the real one. The suite
# must be safe to run against a checkout somebody is working in, because it
# will be: this repository is being written by several sessions at once.

## t_mutant <sandbox> <name> -> prints the path of a fresh copy of the toolkit
t_mutant() {
    local sb="$1" dst="$1/mutant-$2"
    t_in_sandbox "$sb" || { echo "harness: $sb is not a sandbox" >&2; return 2; }
    rm -rf "$dst"; mkdir -p "$dst"
    # `.` so dotfiles come too.
    cp -a "$FLOW_DIR/." "$dst/" 2>/dev/null
    # .git is the one thing a mutant must NOT carry: a stray `git` call inside
    # the copy would read the real repository's index, and this suite runs while
    # other sessions are committing to it.
    rm -rf "$dst/.git"
    find "$dst" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null
    printf '%s' "$dst"
}

## t_mutate <mutant> <relative path> <sed expression...>
## Applies the expression and FAILS LOUDLY if it changed nothing. A mutation
## that silently did not apply turns its proof into a check that cannot fail,
## which is the exact defect class these suites exist to find - and it is the
## normal consequence of somebody reformatting the line the expression matched.
t_mutate() {
    local mut="$1" rel="$2"; shift 2
    local f="$mut/$rel"
    t_in_sandbox "$f" || { echo "harness: refusing to mutate $f - not in a sandbox" >&2; return 2; }
    [ -f "$f" ] || { echo "harness: no $rel in the mutant" >&2; return 2; }
    local before after
    before="$(cksum < "$f")"
    sed -i "$@" "$f" || return 2
    after="$(cksum < "$f")"
    if [ "$before" = "$after" ]; then
        echo "harness: mutation of $rel changed nothing - the expression no longer matches" >&2
        return 2
    fi
    return 0
}

## t_replace_line <mutant> <relative path> <exact line> <replacement>
##
## The mutation form for make conditionals, which are full of `$`, `(` and `,`
## and are therefore miserable to write as a sed regex - and a mis-escaped regex
## that matches nothing is the silent-no-op failure above, dressed as a typo.
## This matches the line WHOLE AND LITERALLY (grep -Fx), and refuses unless
## exactly one line matches: two matches means the fault would be planted in two
## places at once and the proof would no longer isolate one guard.
t_replace_line() {
    local mut="$1" rel="$2" want="$3" repl="$4"
    local f="$mut/$rel" n
    t_in_sandbox "$f" || { echo "harness: refusing to mutate $f - not in a sandbox" >&2; return 2; }
    [ -f "$f" ] || { echo "harness: no $rel in the mutant" >&2; return 2; }
    n="$(grep -Fxn -- "$want" "$f" | cut -d: -f1)"
    case "$(printf '%s' "$n" | grep -c .)" in
        1) ;;
        0) echo "harness: no line in $rel is exactly: $want" >&2; return 2 ;;
        *) echo "harness: $rel has more than one line exactly: $want" >&2; return 2 ;;
    esac
    # `c\` rather than `s`, so the replacement text is not a regex either.
    sed -i "${n}c\\${repl}" "$f" || return 2
    return 0
}

# --- a throwaway project -----------------------------------------------------

## t_project <dir> <flow dir> [block] [board]
##
## The three-line entry contract of CONTRACT.md section 2, written into a
## sandbox. BLOCK and BOARD are placeholders that name nothing real: section 1
## forbids this repository from naming a board, and a test fixture is part of
## this repository.
##
## THE INCLUDE IS SPELLED WITH THE LITERAL PATH, not `$(FPGA_FLOW_DIR)/mk/...`
## as section 2 shows it, and only for this reason: the FPGA_FLOW_DIR guard is
## one of the things under test, and a project that reaches flow.mk only THROUGH
## that variable cannot reach the guard at all - make fails on `include /mk/
## flow.mk` first, which tests the shell's error message and not the toolkit's.
## The two spellings are identical for every other purpose, because the value
## assigned is the same literal path.
t_project() {
    local dir="$1" flow="$2" block="${3:-demo_block}" board="${4:-demo_board}"
    t_in_sandbox "$dir" || { echo "harness: refusing to scaffold outside a sandbox" >&2; return 2; }
    mkdir -p "$dir" || return 2
    cat > "$dir/Makefile" <<EOF
FPGA_DIR := \$(CURDIR)
include \$(FPGA_DIR)/design.mk
EOF
    cat > "$dir/design.mk" <<EOF
FPGA_FLOW_DIR := $flow
BLOCK := $block
BOARD := $board
include $flow/mk/flow.mk
EOF
    return 0
}

## t_project_drop <project dir> <variable>  - remove one assignment from design.mk
t_project_drop() {
    local dir="$1" var="$2"
    t_in_sandbox "$dir" || { echo "harness: refusing to edit outside a sandbox" >&2; return 2; }
    grep -q "^$var :=" "$dir/design.mk" || { echo "harness: no '$var :=' in design.mk" >&2; return 2; }
    sed -i "/^$var :=/d" "$dir/design.mk"
}

# --- summary -----------------------------------------------------------------
## t_summary - final line and process status. Non-zero when ANY assertion failed.
##
## A file that asserted NOTHING AT ALL also fails. An empty suite is the shape a
## file takes when every branch in it decided it did not apply, and a green line
## under it would be a report that nothing was measured, which is the one result
## CONTRACT.md section 0 refuses to call a pass.
t_summary() {
    printf '\n%s: %d passed, %d failed, %d known-defect, %d skipped\n' \
        "$T_FILE" "$T_PASS" "$T_FAIL" "$T_XFAIL" "$T_SKIP"
    if [ $((T_PASS + T_FAIL + T_XFAIL + T_SKIP)) -eq 0 ]; then
        printf '%s: asserted nothing. That is a failure, not a pass.\n' "$T_FILE" >&2
        return 1
    fi
    [ "$T_FAIL" -eq 0 ]
}
