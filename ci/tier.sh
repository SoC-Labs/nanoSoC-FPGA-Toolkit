#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# ci/tier.sh - climb the CI tiers, in order, stopping at the first one that breaks
#
#   ci/tier.sh <tier> [--only] [--fpga-dir <project>/fpga]
#
#   tiers, cheapest first:
#     static     shell and Tcl parse, the seam list is the only seam list, the
#                toolkit is internally consistent. No tool, no licence, no
#                board, no project. Runs anywhere, takes seconds.
#     host       does THIS machine have what the expensive tiers need?
#     contract   is THIS project's contract complete? (make check / env /
#                part-probe / board-probe). No tool.
#     flist      does every source the project names actually exist?
#     synth      package-ip, bd, synth. First Vivado licence. Tens of minutes.
#     impl       implementation. The long one - tens of minutes to hours.
#     bitstream  write_bitstream, .bin, .xsa. Minutes.
#     verify     judge the artefacts: xdc-lint, msg-gate, the censuses and the
#                EXPECT_* budgets. Licence-free, reads what impl and bitstream
#                wrote.
#     deploy     put it on a board. The only tier that needs HARDWARE.
#
#   `ci/tier.sh impl` runs static..impl. `--only` runs the named tier alone,
#   which is what a resumed job wants.
#
# WHY ONE SCRIPT AND NOT ONE CI JOB PER TIER.
#
# Because the stages hand a checkpoint to each other through one work directory.
# CI jobs do not share a workspace, so a job-per-tier layout re-clones the tree
# per tier and, worse, cannot see the synthesis the previous job produced - it
# would have to re-synthesise every time. Steps in one job it is, on every
# platform, and this script is the part that is the same on all of them. Wiring
# it into a workflow is the caller's job; see ci/README.md.
#
# WHY THIS LADDER, IN THIS ORDER.
#
# Two rules set the order, and one exception breaks it.
#
#   1. CHEAPEST FIRST. Everything a text file can answer must be answered
#      before a Vivado licence is taken. `static`, `host` and `contract` launch
#      no tool at all and together take seconds; `flist` is the first tier that
#      reads the project's own sources and it still takes no licence. A wrong
#      RTL path found by `flist` costs two seconds. The same wrong path found
#      by synthesis costs forty minutes and arrives as an elaboration error
#      about a module nobody has heard of.
#
#   2. A FAILED TIER MAKES EVERY LATER TIER'S VERDICT MEANINGLESS. Implementing
#      a netlist synthesis never wrote is not an implementation failure; it is
#      the same synthesis failure reported an hour later and much less clearly.
#      So the ladder STOPS, and every later tier is recorded as a SKIP naming
#      the tier that broke - never left silently absent, because a run that
#      reports nine passes and nothing else looks exactly like a run that
#      passed nine tiers.
#
#   package-ip AND bd RIDE WITH synth rather than being tiers of their own.
#   They are one Vivado session's worth of work between them, they take the
#   same licence, and splitting them would triple the licence checkouts to buy
#   discrimination the GATE IDS already provide: `synth.bd.manifest` and
#   `synth.netlist` are different red lines whether or not they are different
#   tiers. Tiers exist to decide what NOT to run; gate ids exist to say what
#   went wrong.
#
#   THE EXCEPTION: verify runs AFTER bitstream, not between impl and bitstream.
#   write_bitstream costs minutes against implementation's hours, and a design
#   that misses timing by 40 ps is precisely the one an engineer wants on a
#   board in order to find out why. Gating the bitstream on the budget would
#   withhold the artefact needed to diagnose the budget. `deploy` is after
#   `verify`, so an automated deploy still never reaches hardware with a design
#   that failed its gates.
#
#   deploy IS LAST AND IS DIFFERENT IN KIND. It is the only tier whose
#   dependency is a physical object: a board, a cable, an fpgahub lease. It can
#   fail for reasons that have nothing whatever to do with the design - a board
#   held by somebody else, a cable somebody unplugged - so it is the last thing
#   attempted and the first thing to look past when reading a red run. The ASIC
#   toolkit this is modelled on has no analogue: nothing in an ASIC flow needs
#   hardware to be present while it runs.
#
# Env:
#   FPGA_DIR          the project's fpga/ directory (default: $PWD)
#   RUN_TAG           the run namespace. Defaulted below to something
#                     collision-proof, because a CI run that reuses a tag can
#                     pick up the last run's artefacts and pass an assertion it
#                     should have failed.
#   CI_LABEL          capability label the expensive tiers require (see
#                     ci/capability.sh). Default: none, and the host tier then
#                     falls back to scripts/fpga-flow-doctor.
#   CI_MAKE_ARGS      extra arguments passed to every make invocation
#   CI_DEPLOY_TARGET  the make target the deploy tier runs. Unset in phase 1,
#                     where deploy is declared and not yet wired.
#   CI_VERDICT_DIR    where the verdicts land. Default $RUN_DIR/ci.
#
# Exit status: 0 every tier passed · 1 a tier failed · 2 unusable arguments
#              75 another tier driver holds this run tag (EX_TEMPFAIL: retry)
#              130 interrupted
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOW_DIR="$(cd "$HERE/.." && pwd)"
# shellcheck source=ci/lib.sh
. "$HERE/lib.sh"

usage() { sed -n '2,/^# Copyright/p' "$0" | sed 's/^#\{1,\} \{0,1\}//;s/^#$//'; }

trap 'exit 130' INT

TIERS="static host contract flist synth impl bitstream verify deploy"

#-----------------------------------------------------------------------------
# THE ARGUMENT LOOP, AND THE TWO WAYS IT USED TO END BADLY.
#
# 1. AN OPTION WITH NO OPERAND NEVER TERMINATED. `--fpga-dir` ended in
#    `shift 2`, and a `shift 2` with one argument left FAILS - it shifts
#    NOTHING. The loop then sees the same `--fpga-dir` next time round, and the
#    time after that, forever: no verdict, no output, no exit status, and a
#    runner held until somebody's external timeout kills it. Measured, both
#    here and in ci/capability.sh's --require/--conf. The check has to happen
#    BEFORE the shift, which is what need_operand is.
#
# 2. A SECOND TIER NAME WAS SILENTLY DISCARDED. `WANT="$1"` inside the loop
#    means the LAST name wins, so `ci/tier.sh static deploy` climbed to DEPLOY
#    - the one tier that needs hardware - for a caller who asked for the cheap
#    text-only one, and nothing anywhere said a name had been dropped. Two
#    names select two different sets of checks; a script that picks one of them
#    for you is reporting on a run nobody asked for.
#
# Both refuse with exit 2 and neither reaches ci_init, so a refused invocation
# writes no verdict file at all. ci/README.md reserves 2 for "refused: unusable
# input", and the distinction from 1 is the whole point: 1 sends a reader
# looking for a broken design, 2 tells them the job was never asked for
# anything real.
#-----------------------------------------------------------------------------

## need_operand <arguments remaining> <option> <what it takes>
## Called with "$#" from inside the loop, BEFORE the `shift 2` that would
## otherwise fail silently and spin.
need_operand() {
    [ "$1" -ge 2 ] && return 0
    echo "tier: $2 takes $3 after it, and nothing followed it." >&2
    echo "  Nothing was measured. Exit 2 is 'unusable arguments', not a failing gate." >&2
    exit 2
}

## refuse_second_name <the name already held> <the name just seen>
## NAMES BOTH. The caller cannot otherwise tell which of the two this script
## would have kept, and the two answers differ by hours of licence time.
refuse_second_name() {
    echo "tier: two tier names were given: '$1' and '$2'. This script climbs ONE ladder." >&2
    echo "  They select different sets of checks, and one of them was about to be" >&2
    echo "  discarded without a word. Name one; add --only to run just that tier." >&2
    exit 2
}

WANT=""
ONLY=0
FPGA_PROJECT="${FPGA_DIR:-$PWD}"
while [ $# -gt 0 ]; do
    case "$1" in
        --only)     ONLY=1; shift ;;
        --fpga-dir) need_operand "$#" --fpga-dir "the fpga/ directory to act on"; FPGA_PROJECT="$2"; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        -*)         echo "tier: unknown argument '$1'" >&2; exit 2 ;;
        *)          [ -z "$WANT" ] || refuse_second_name "$WANT" "$1"; WANT="$1"; shift ;;
    esac
done

#-----------------------------------------------------------------------------
# ACCEPTANCE IS STRING EQUALITY - THE SAME TEST THE SELECTION USES.
#
# It was a REGULAR EXPRESSION: `printf '%s' " $TIERS " | grep -q " $WANT "`,
# while should_run selects with `[ "$t" = "$WANT" ]`. A name that matched as a
# regex and equalled no tier therefore passed the gate and then matched no
# rung, and the two ways that came out were both silent. MEASURED:
#
#   ci/tier.sh 'stati.' --only   exit 0, nine "not requested" rows, no gate
#                                run, and "All recorded gates passed."
#   ci/tier.sh 'stati.'          every tier INCLUDING deploy, because the
#                                prefix walk never found its stopping point.
#
# A typo'd tier name in a workflow file reaches both, and the first one is a CI
# job going green having run nothing - the exact failure this whole verdict
# layer exists to prevent. Two tests of membership on one name is one test too
# many: this one is the test the selection then performs, so a name that is
# accepted here is a name that selects a rung.
#-----------------------------------------------------------------------------

## is_declared_tier <name>
is_declared_tier() {
    local t
    for t in $TIERS; do [ "$t" = "$1" ] && return 0; done
    return 1
}

if [ -z "$WANT" ] || ! is_declared_tier "$WANT"; then
    echo "tier: name one of: $TIERS" >&2
    exit 2
fi

#-----------------------------------------------------------------------------
# THE RUN TAG.
#
# A FRESH TAG PER CI RUN IS NOT A CONVENIENCE, IT IS THE ASSERTION MODEL.
#
# Every stage assertion tests for artefacts BY NAME. Re-using a run tag means
# yesterday's timing_summary.rpt and yesterday's .bit are still on disk when
# today's implementation dies in its first minute - and the assertion, and
# `make status`, and any report built from the directory, all say the stage
# passed. A run namespace makes that structurally impossible, and it costs one
# variable.
#
# THE DEFAULT MUST BE COLLISION-PROOF EVEN OFF A CI SYSTEM. Deriving it only
# from $GITHUB_RUN_NUMBER gives every laptop run the same tag `ci-0`, which is
# the reused-tag failure with extra steps: the second developer to run the
# ladder on a shared host inherits the first one's outputs and passes on them.
# So when no CI system is exporting a run number, the tag carries a UTC
# timestamp and this process's pid instead.
#
# No '/' and no '.' appears in either form: mk/flow.mk refuses a tag containing
# a path separator or equal to `.`/`..`, and a default the guard would reject
# is a default nobody can use.
#-----------------------------------------------------------------------------
if [ -z "${RUN_TAG:-}" ]; then
    _n="${GITHUB_RUN_NUMBER:-${CI_PIPELINE_IID:-${BUILD_NUMBER:-}}}"
    _s="${GITHUB_SHA:-${CI_COMMIT_SHA:-}}"
    if [ -n "$_n" ]; then
        RUN_TAG="ci-${_n}${_s:+-${_s:0:8}}"
    else
        RUN_TAG="ci-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    fi
fi
export RUN_TAG
MAKE=(make -C "$FPGA_PROJECT" --no-print-directory RUN_TAG="$RUN_TAG")
# shellcheck disable=SC2206
[ -n "${CI_MAKE_ARGS:-}" ] && MAKE+=(${CI_MAKE_ARGS})

# Resolve the run directory once, FROM MAKE, so a project that overrode
# BUILD_DIR is followed rather than guessed at. Guessing `build/<tag>` when the
# project put its builds on scratch would assert against an empty directory and
# report every artefact missing.
RUN_DIR="$("${MAKE[@]}" env 2>/dev/null | awk '$1 == "RUN_DIR" { print $2; exit }')"
if [ -z "$RUN_DIR" ]; then
    # `make env` needs a valid design.mk. Before the contract tier that may not
    # exist yet, and the static tier does not need it.
    RUN_DIR="$FPGA_PROJECT/build/$RUN_TAG"
fi
export FPGA_RUN_DIR="$RUN_DIR"
CI_VERDICT_DIR="${CI_VERDICT_DIR:-$RUN_DIR/ci}"
BUILD_DIR="$(dirname "$RUN_DIR")"

#-----------------------------------------------------------------------------
# ONE LADDER PER RUN TAG.
#
# The tag is unique per run by default, so this lock is dormant almost always.
# It is here for the case where somebody SET the tag - re-running a named tier
# against an existing run, which is the normal way a long build is resumed. Two
# ladders in one work directory corrupt the checkpoints, and the corruption is
# discovered hours later as an implementation error nobody can reproduce.
#
# `mkdir` is the lock because it is atomic on every filesystem including NFS,
# which `[ -e ] && touch` is not. A lock held by a DEAD process is broken and
# taken, for the same reason ci_init tests liveness rather than existence: a
# guard that cries wolf after one crashed run gets deleted, and a deleted guard
# protects nothing.
#
# Contention exits 75 (EX_TEMPFAIL) and NOT 1. The difference matters to
# whoever reads the red job: 1 means this design failed a check, 75 means
# nothing was measured and the job should simply be run again.
#-----------------------------------------------------------------------------
mkdir -p "$CI_VERDICT_DIR" 2>/dev/null || true
LOCK="$CI_VERDICT_DIR/tier.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    IFS=$'\t' read -r l_lane l_pid l_host l_start _ < "$LOCK/holder" 2>/dev/null
    if _ci_owner_alive "${l_pid:-}" "${l_host:-}" "${l_start:-}"; then
        echo "tier: run tag '$RUN_TAG' is already being climbed by ${l_lane:-?} (pid ${l_pid:-?} on ${l_host:-?})." >&2
        echo "  Two ladders in one work directory corrupt each other's checkpoints." >&2
        echo "  Nothing was measured. Retry, or use a different RUN_TAG." >&2
        exit 75
    fi
    rm -rf "$LOCK" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null || { echo "tier: cannot take $LOCK" >&2; exit 75; }
fi
printf '%s\t%s\t%s\t%s\n' "tier($WANT)" "$$" "$(_ci_host)" "$(_ci_starttime $$)" \
    > "$LOCK/holder" 2>/dev/null || true
trap 'rm -rf "$LOCK" 2>/dev/null; exit 130' INT
trap 'rm -rf "$LOCK" 2>/dev/null' EXIT

ci_init
# ONE verdict file for the whole ladder. Exported so every script this driver
# calls appends to it instead of starting its own - otherwise the final summary
# lists the last tier's gates and silently drops the rest.
export CI_VERDICT_DIR CI_APPEND=1

ci_head "tier '$WANT'$([ "$ONLY" = 1 ] && echo ' (only)') - run tag '$RUN_TAG'"
ci_say "project  $FPGA_PROJECT"
ci_say "run dir  $RUN_DIR"

should_run() {  # should_run <tier>
    if [ "$ONLY" = 1 ]; then [ "$1" = "$WANT" ]; return; fi
    # Ordered prefix: run everything up to and including WANT.
    for t in $TIERS; do
        [ "$t" = "$1" ] && return 0
        [ "$t" = "$WANT" ] && return 1
    done
    return 1
}

FAILED_TIER=""

# run_tier <name> <command...>
run_tier() {
    local name="$1"; shift
    should_run "$name" || { ci_skip "tier.$name" "not requested - '$WANT' was asked for"; return 0; }
    # THE REASON IS THE POINT. "skipped" alone reads as "not applicable"; this
    # says which tier broke, so the reader stops looking at the wrong one.
    [ -n "$FAILED_TIER" ] && { ci_skip "tier.$name" "$FAILED_TIER failed - a later tier's verdict would not mean anything"; return 0; }
    ci_head "tier $name"
    if "$@"; then
        ci_pass "tier.$name" "passed"
    else
        ci_fail "tier.$name" "see the gates above"
        FAILED_TIER="$name"
    fi
}

#-----------------------------------------------------------------------------
# THE STAGE PATTERN, and the reason it is two commands rather than one.
#
#   1. run the stage under make, which asserts on its artefacts and stops
#   2. re-assert INDEPENDENTLY afterwards, with `always` semantics
#
# Step 2 runs even when step 1 failed. That is deliberate: a two-hour job that
# died in implementation must still publish what synthesis achieved, and the
# gate ids from a failed run are the ones worth having. It also covers the case
# where make never reached its own assertions at all - a killed job, a lost
# licence seat, a rebooted runner.
#-----------------------------------------------------------------------------
stage_tier() {  # stage_tier <make target> <assert-stage name> [--optional]
    local target="$1" stage="$2"; shift 2
    local rc=0
    "${MAKE[@]}" "$target" || rc=$?
    FPGA_RUN_DIR="$RUN_DIR" CI_VERDICT_DIR="$CI_VERDICT_DIR" \
        "$HERE/assert-stage.sh" "$stage" --fpga-dir "$FPGA_PROJECT" "$@" || rc=1
    return $rc
}

#-----------------------------------------------------------------------------
# THE TCL BALANCE GATE.
#
# In a function of its own because it has THREE outcomes, not two, and because
# the reason for that is worth more room than an inline comment.
#
# There is no parse-only mode - tclsh EXECUTES - so this checks only that
# braces, brackets and quotes balance, via `info complete`. The gate says so:
# a gate whose name promises more than it measured is how a green run comes to
# be believed about something it never looked at.
#
# THE READER IS A FILE, AND THE FILE UNDER TEST IS tclsh's FIRST ARGUMENT.
# It used to be `echo '<one-liner>' | tclsh - "$f"`, and a standard tclsh does
# not consume that `-`. Measured on tcl 8.6: `tclsh - <file>` reads the script
# from stdin and leaves argv as `{- <file>}`, so `[lindex $argv 0]` was the
# DASH. Every open failed, the one-liner exited 2 - its own "could not read"
# code - and the caller graded every non-zero as unbalanced. The static tier
# therefore reported all 21 .tcl files in this toolkit as having "unbalanced
# braces/brackets/quotes" on every host that HAS a tclsh, while an independent
# `info complete` over the same files found not one. It is a false RED rather
# than a false green, which is the better direction to fail in - but it is also
# a gate stating a specific finding about a file it never opened, and it meant
# this tier could not pass anywhere tclsh was installed.
#
# SO THE READER ANSWERS IN THREE STATES. "I could not open it" and "I opened it
# and it does not balance" are different facts, with different owners and
# different fixes, and collapsing them is precisely what produced the finding
# above. The gate keeps them apart all the way to the verdict: an unread file
# is UNVERIFIED (evidence missing, and ci/lib.sh counts that as a failure), an
# unbalanced one is FAIL (evidence read, and bad).
#-----------------------------------------------------------------------------
static_tcl_gate() {
    local f n=0 trc reader tbad="" tunread=""

    reader="$(mktemp "${TMPDIR:-/tmp}/fpga-flow-tcl-complete.XXXXXXXX" 2>/dev/null)" || reader=""
    if [ -z "$reader" ]; then
        ci_unverified static.tcl.complete \
            "could not write a reader script under ${TMPDIR:-/tmp}, so not one Tcl file was opened. This is a fact about this host, and NOT a finding about any file"
        return 1
    fi
    # A QUOTED heredoc. Every `$` below belongs to Tcl, and an unquoted one
    # would have the shell expand them to nothing before tclsh ever saw them.
    cat > "$reader" <<'TCL'
# ci/tier.sh's static tier: does one file's Tcl balance?
#   exit 0  it balances
#   exit 1  it was READ and does not balance
#   exit 3  it could not be read at all - the caller must not call this a
#           syntax finding, because nothing has looked at the syntax
set f [lindex $argv 0]
if {[catch {set c [open $f]}]} { exit 3 }
set d [read $c]
close $c
exit [expr {[info complete $d] ? 0 : 1}]
TCL

    while IFS= read -r f; do
        n=$((n + 1))
        trc=0
        tclsh "$reader" "$f" >/dev/null 2>&1 || trc=$?
        case "$trc" in
            0) ;;                            # read, and balances
            1) tbad="$tbad $f" ;;            # read, and does not balance
            *) tunread="$tunread $f" ;;      # never opened - NOT a finding about its contents
        esac
    done < <(find "$FLOW_DIR/flow" "$FLOW_DIR/part" "$FLOW_DIR/templates" \
                  -name '*.tcl' -type f 2>/dev/null)
    rm -f "$reader"

    if [ "$n" -eq 0 ]; then
        ci_skip static.tcl.complete "no .tcl under flow/, part/ or templates/ yet"
        return 0
    fi
    # UNREADABLE FIRST, and it is reported as missing evidence rather than as a
    # verdict about the file. A gate that cannot open its input has not passed
    # and has not found anything; it has not run.
    if [ -n "$tunread" ]; then
        ci_unverified static.tcl.complete \
            "could not READ, so nothing is claimed about what is in them:$tunread${tbad:+ (separately, these WERE read and do not balance:$tbad)}"
        return 1
    fi
    if [ -n "$tbad" ]; then
        ci_fail static.tcl.complete "unbalanced braces/brackets/quotes:$tbad"
        return 1
    fi
    ci_pass static.tcl.complete "$n file(s) balance (this proves BALANCE, not that they run)"
    return 0
}

#-----------------------------------------------------------------------------
t_static() {
    local rc=0 f

    # 1. Every shell script in the toolkit PARSES. `bash -n` is not a lint, and
    #    it is not trying to be: it is the check that catches the unbalanced
    #    quote which turns a gate into a syntax error, and a gate that is a
    #    syntax error is a gate that never fails.
    local bad=""
    while IFS= read -r f; do
        bash -n "$f" 2>/dev/null || bad="$bad $f"
    done < <(find "$FLOW_DIR/ci" "$FLOW_DIR/test" "$FLOW_DIR/scripts" \
                  -name '*.sh' -type f 2>/dev/null)
    if [ -n "$bad" ]; then
        ci_fail static.shell.parse "these do not parse:$bad"
        rc=1
    else
        ci_pass static.shell.parse "every ci/, test/ and scripts/ shell file parses"
    fi

    # 2. Tcl balance, via `info complete` - see static_tcl_gate above for what
    #    that does and does not prove, and for the three states it answers in.
    if command -v tclsh >/dev/null 2>&1; then
        static_tcl_gate || rc=1
    else
        ci_unverified static.tcl.complete "no tclsh on this host, so no Tcl file was checked at all"
        rc=1
    fi

    # 3. THE ANTI-DRIFT INVARIANT. flow/common/seams.txt is the single source of
    #    truth for the hook seams and `ls flow/steps/` for the step overrides.
    #    This is in the CHEAPEST tier on purpose: it is the check most likely to
    #    be broken by an ordinary edit and the one that costs nothing to run.
    if [ -x "$FLOW_DIR/test/shell/t_seams.sh" ]; then
        if "$FLOW_DIR/test/shell/t_seams.sh" >/dev/null 2>&1; then
            ci_pass static.seams "the seam list and the step list have exactly one copy each"
        else
            ci_fail static.seams "run test/shell/t_seams.sh - a second copy of a derived list has appeared"
            rc=1
        fi
    else
        ci_unverified static.seams "no test/shell/t_seams.sh - nothing checked that the seam list has one copy"
        rc=1
    fi

    # 4. Whatever else a later phase lands.
    if [ -x "$HERE/static-checks.sh" ]; then
        "$HERE/static-checks.sh" || rc=1
    else
        ci_skip static.checker "no ci/static-checks.sh yet - the checks above are all the static tier does"
    fi
    return $rc
}

#-----------------------------------------------------------------------------
t_host() {
    # Prefer the project's declared capability, which knows about its own
    # mounts, its board and its non-EDA tools. Fall back to the toolkit's own
    # host reporter, which knows about Vivado and the licence servers. Never
    # guess.
    local conf="${CI_CAPABILITY_CONF:-$FPGA_PROJECT/ci-capability.conf}"
    if [ -n "${CI_LABEL:-}" ] && [ -f "$conf" ]; then
        "$HERE/capability.sh" --conf "$conf" --require "$CI_LABEL"
    elif [ -f "$conf" ]; then
        ci_warn host.label "no CI_LABEL set - reporting capability, gating on nothing"
        "$HERE/capability.sh" --conf "$conf"
    elif [ -x "$FLOW_DIR/scripts/fpga-flow-doctor" ]; then
        ci_warn host.capability \
            "no $conf - only the toolkit's own host check runs, so nothing verifies this project's board, its cable or its non-EDA tools. Copy ci/capability.conf.example"
        "$FLOW_DIR/scripts/fpga-flow-doctor"
    else
        ci_unverified host.capability \
            "no $conf and no scripts/fpga-flow-doctor - NOTHING probed this host, so every later tier is about to run on unknown ground"
        return 1
    fi
}

#-----------------------------------------------------------------------------
# The contract tier is four make targets rather than one, so a red run names
# WHICH half of the contract is broken: an incomplete design.mk and an
# unloadable board pack are different problems with different owners.
t_contract() {
    local rc=0
    "${MAKE[@]}" check || { ci_fail contract.check \
        "make check is not satisfied - a configured-but-missing input is an error, not a shrug"; rc=1; }
    "${MAKE[@]}" env >/dev/null || { ci_fail contract.env \
        "make env did not render - the run's own variable surface cannot be reported"; rc=1; }
    "${MAKE[@]}" part-probe >/dev/null || { ci_fail contract.part \
        "make part-probe failed - the part pack did not load or did not validate"; rc=1; }
    "${MAKE[@]}" board-probe >/dev/null || { ci_fail contract.board \
        "make board-probe failed - the board pack did not load or did not validate"; rc=1; }
    return $rc
}

#-----------------------------------------------------------------------------
t_flist() { stage_tier flist flist; }

#-----------------------------------------------------------------------------
# package-ip and bd are OPTIONAL stages: a project with no PACKAGE_TCL and no
# BD_TCL never runs them, and from disk that is indistinguishable from a stage
# that ran and died before writing anything. --optional tells assert-stage to
# record a SKIP with that reason instead of a failure. See the note in
# assert-stage.sh: the durable fix is for every stage to write a manifest even
# when it does nothing, saying so.
t_synth() {
    local rc=0
    "${MAKE[@]}" package-ip || rc=$?
    "$HERE/assert-stage.sh" package-ip --fpga-dir "$FPGA_PROJECT" --optional || rc=1
    "${MAKE[@]}" bd || rc=$?
    "$HERE/assert-stage.sh" bd --fpga-dir "$FPGA_PROJECT" --optional || rc=1
    stage_tier synth synth || rc=1
    return $rc
}

t_impl()      { stage_tier impl impl; }
t_bitstream() { stage_tier bitstream bitstream; }

#-----------------------------------------------------------------------------
# The judging tier. Every target here reads what impl and bitstream already
# wrote; none of them takes a licence, and none of them can change the design.
# They are a separate tier from `impl` because they are the checks a reviewer
# reads, and burying them inside a two-hour tier means they are only ever seen
# after that tier has already gone green.
t_verify() {
    local rc=0 tgt
    for tgt in xdc-lint msg-gate util-census timing-census; do
        if "${MAKE[@]}" "$tgt"; then
            ci_pass "verify.$tgt" "passed"
        else
            ci_fail "verify.$tgt" "make $tgt - see its report under \$REPORT_DIR"
            rc=1
        fi
    done
    return $rc
}

#-----------------------------------------------------------------------------
# THE HARDWARE TIER.
#
# Phase 1 declares the deploy variables and wires nothing (CONTRACT.md §3.3),
# so this tier runs nothing and SAYS SO rather than passing. A tier that
# silently checks nothing is how a green run comes to prove nothing, and
# "deployed" is the single claim in this ladder that somebody will repeat in a
# meeting.
t_deploy() {
    if [ -z "${CI_DEPLOY_TARGET:-}" ]; then
        ci_skip deploy.wiring \
            "CI_DEPLOY_TARGET is unset. CONTRACT.md §3.3 declares FPGAHUB_* and states phase 4 wires deploy; this tier is where that call will go. NOTHING was put on a board by this run"
        return 0
    fi
    if "${MAKE[@]}" "$CI_DEPLOY_TARGET"; then
        ci_pass deploy.target "make $CI_DEPLOY_TARGET"
        return 0
    fi
    # A board held by somebody else is not a design failure, and reading it as
    # one wastes the next hour. The gate detail has to say which it might be.
    ci_fail deploy.target \
        "make $CI_DEPLOY_TARGET failed. Distinguish before debugging the design: a busy or unleased board, an unplugged cable and a bad bitstream all land here"
    return 1
}

run_tier static    t_static
run_tier host      t_host
run_tier contract  t_contract
run_tier flist     t_flist
run_tier synth     t_synth
run_tier impl      t_impl
run_tier bitstream t_bitstream
run_tier verify    t_verify
run_tier deploy    t_deploy

#-----------------------------------------------------------------------------
# THE RUN POINTERS.
#
# A run namespace gives isolation but nothing then points at "the last run that
# actually worked". That gap has real teeth: a pointer updated on recency alone
# spends an evening aimed at a run with a non-zero exit, an empty reports
# directory and no bitstream - and then somebody cites it as the source of what
# is on the board.
#
# So `latest` FOLLOWS SUCCESS and `last` follows recency, and they are
# different words on purpose.
#-----------------------------------------------------------------------------
if [ -d "$RUN_DIR" ]; then
    printf '%s\n' "$CI_FAIL" > "$CI_VERDICT_DIR/fail_count" 2>/dev/null || true
    ln -sfn "$RUN_DIR" "$BUILD_DIR/last" 2>/dev/null || true
    if [ "$CI_FAIL" -eq 0 ]; then
        ln -sfn "$RUN_DIR" "$BUILD_DIR/latest" 2>/dev/null || true
    else
        ci_say "NOT moving $BUILD_DIR/latest - this run has failing gates (see $BUILD_DIR/last)"
    fi
fi

ci_summary_table "CI tier: $WANT (run tag \`$RUN_TAG\`)"
ci_exit "tier($WANT)"
