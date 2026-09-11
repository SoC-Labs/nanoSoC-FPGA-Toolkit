#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# t_contract.sh - mk/flow.mk's parse-time guards must refuse what they claim to
#
# DEFECT CLASS: A GUARD THAT NEVER FIRES.
#
# The guards in mk/flow.mk section 1 and 2 protect a `rm -rf` and a build that
# would otherwise succeed while producing the wrong design. CONTRACT.md section
# 3.5 lists them: RUN_TAG empty, containing a separator, or '.'/'..'; BUILD_DIR
# empty, relative or '/'; and section 2 adds the refusal to build from inside
# the toolkit's own examples/. Every one of them is a make conditional wrapping
# an $(error), and a make conditional that stops matching - because a variable
# was renamed, because somebody reformatted the line, because `strip` was
# dropped - fails OPEN. It does not warn. The build simply proceeds.
#
# So each assertion here is paired with a MUTATION PROOF: the guard's own
# conditional line is replaced, in a throwaway copy of the toolkit, with one
# that can never be true, and the same command must then be ACCEPTED. That is
# what shows the assertion was measuring the guard and not some unrelated
# failure further down the parse - which matters more than usual here, because
# `make` on a project with three things wrong reports the FIRST one, and a test
# that only looked at the exit status would pass on every one of them.
#
# ONE GUARD HERE IS NOT ABOUT `rm -rf` AND IS THE SAME DEFECT CLASS. FLOW_MODE
# used to accept four values and default to `project`, and three of the four
# named a path no stage implements - so every build this toolkit produced
# declared one flow and executed another, recorded only as a not-covered bullet
# in a gate file. The guard that refuses them is a make conditional like the
# rest and fails open like the rest, so it is tested here with the rest.
#
# The mode surface has a SECOND copy, in scripts/fpga-flow-check's FLOW_MODES,
# and that second copy is what waved the substitution through for the whole of
# the toolkit's life: an enum can check a value against a list and cannot check
# the list against the code. Testing the make guard and not the checker's list
# would leave the two free to drift apart again, so both are asserted below.
#
# NOTHING HERE LAUNCHES A TOOL. Every case is a `make env` that dies during
# parsing, one that completes and prints variables, or `fpga-flow-check`, which
# is Python and reads no design.
#
# THE FIXTURE PROJECT NAMES NOTHING REAL. CONTRACT.md section 11.8: nothing in
# this repository names a board, a pin or a project path, and a test fixture is
# part of this repository. BLOCK and BOARD are placeholders.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/lib/harness.sh
. "$HERE/../lib/harness.sh"

t_sandbox; SB="$T_SANDBOX"

if [ ! -f "$FLOW_DIR/mk/flow.mk" ]; then
    t_skip contract.all "mk/flow.mk is not in this checkout - nothing to test, and an absent file is not a passing one"
    t_summary; exit $?
fi

# A conditional that is false whatever the project says. `ifeq` and `ifneq` both
# close with `endif`, so replacing either with this leaves the file parseable
# and the guarded $(error) unreachable.
GUARD_OFF='ifeq (guard-disabled-by-mutation-proof,never-equal)'

#-----------------------------------------------------------------------------
# `guard_fires <project> <regex> [make args...]`
#
# make must FAIL, and it must fail with THAT message. Both halves are needed: a
# project with a missing checks.mk also exits non-zero, and a test that accepted
# any non-zero status would report a guard as working on a checkout where the
# guard had been deleted and something else was broken instead.
#-----------------------------------------------------------------------------
guard_fires() {
    local proj="$1" re="$2"; shift 2
    local out rc=0
    out="$(make -C "$proj" --no-print-directory env "$@" 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ]; then
        printf 'make SUCCEEDED where the guard should have stopped it.\n%s\n' "$out"
        return 1
    fi
    if ! printf '%s\n' "$out" | grep -qE -- "$re"; then
        printf 'make failed, but NOT with the guard message /%s/ - so this test was\n' "$re"
        printf 'about to pass on an unrelated failure:\n%s\n' "$out"
        return 1
    fi
    return 0
}

proj_for() {   # <flow dir> <name> -> prints the project directory
    local flow="$1" d="$SB/proj-$2"
    t_project "$d" "$flow" >&2 || return 2
    printf '%s' "$d"
}

#-----------------------------------------------------------------------------
# `argguard` - a guard on a value passed on the make command line.
# `dropguard` - a guard on a value the project's design.mk failed to set.
#
# Each runs the assertion against the real toolkit, then plants the fault in a
# copy and requires the same command to be accepted.
#-----------------------------------------------------------------------------
argguard() {   # <id> <description> <error regex> <exact conditional line> [make args...]
    local id="$1" desc="$2" re="$3" line="$4"; shift 4
    local P M PM
    P="$(proj_for "$FLOW_DIR" "$id")" || { t_fail "contract.$id" "could not scaffold the fixture"; return 1; }
    t_check "contract.$id" "$desc" guard_fires "$P" "$re" "$@"
    M="$(t_mutant "$SB" "$id")"
    if t_replace_line "$M" mk/flow.mk "$line" "$GUARD_OFF"; then
        PM="$(proj_for "$M" "$id-mut")"
        t_check_fail "contract.$id.mutation" \
            "with that conditional disabled in a copy, the same command is accepted" \
            guard_fires "$PM" "$re" "$@"
    else
        t_skip "contract.$id.mutation" "could not plant the fault: mk/flow.mk has no line exactly '$line' - the guard has been reformatted or removed, and this proof is measuring nothing until it is re-aimed"
    fi
}

dropguard() {  # <id> <description> <error regex> <exact conditional line> <variable>
    local id="$1" desc="$2" re="$3" line="$4" var="$5"
    local P M PM
    P="$(proj_for "$FLOW_DIR" "$id")" || { t_fail "contract.$id" "could not scaffold the fixture"; return 1; }
    t_project_drop "$P" "$var" || { t_fail "contract.$id" "could not remove $var from the fixture"; return 1; }
    t_check "contract.$id" "$desc" guard_fires "$P" "$re"
    M="$(t_mutant "$SB" "$id")"
    if t_replace_line "$M" mk/flow.mk "$line" "$GUARD_OFF"; then
        PM="$(proj_for "$M" "$id-mut")"
        t_project_drop "$PM" "$var"
        t_check_fail "contract.$id.mutation" \
            "with that conditional disabled in a copy, the same project is accepted" \
            guard_fires "$PM" "$re"
    else
        t_skip "contract.$id.mutation" "could not plant the fault: mk/flow.mk has no line exactly '$line' - the guard has been reformatted or removed, and this proof is measuring nothing until it is re-aimed"
    fi
}

#=============================================================================
# 1. THE THREE REQUIRED VARIABLES (CONTRACT.md section 3.1)
#=============================================================================
t_head "the three required variables each hard-error at parse time"

dropguard flow_dir "FPGA_FLOW_DIR unset is a named error, not a 'no such file'" \
    'FPGA_FLOW_DIR is not set' 'ifeq ($(strip $(FPGA_FLOW_DIR)),)' FPGA_FLOW_DIR

dropguard block "BLOCK unset is a named error - nothing can name an artefact without it" \
    'BLOCK is not set' 'ifeq ($(strip $(BLOCK)),)' BLOCK

dropguard board "BOARD unset is a named error - nothing selects a board pack without it" \
    'BOARD is not set' 'ifeq ($(strip $(BOARD)),)' BOARD

#=============================================================================
# 2. RUN_TAG - THE VALUE `rm -rf` IS COMPOSED FROM
#=============================================================================
t_head "RUN_TAG: empty, with a separator, and '..'"

# THE REGEX IS ANCHORED ON make's OWN `*** ` PREFIX AND ON THE VARIABLE NAME,
# and the first draft of this file was not. IN_RUN_TAG and SYNTH_RUN_TAG default
# to RUN_TAG and carry the same three guards (mk/flow.mk's
# fpga_run_tag_component_guard), so with the RUN_TAG guard disabled the parse
# still dies - on `IN_RUN_TAG is empty`, which an unanchored grep for
# `RUN_TAG is empty` MATCHES AS A SUBSTRING. The mutation proof then reported
# that a deleted guard was still working. Defence in depth is a good property of
# mk/flow.mk and a trap for a test that greps loosely.
argguard run_tag.empty "RUN_TAG= is refused - it would make RUN_DIR the whole build tree" \
    '\*\*\* RUN_TAG is empty' 'ifeq ($(strip $(RUN_TAG)),)' RUN_TAG=

argguard run_tag.slash "a RUN_TAG with a path separator is refused" \
    "\\*\\*\\* RUN_TAG '[^']*' contains a path separator" 'ifneq ($(findstring /,$(RUN_TAG)),)' RUN_TAG=nightly/two

argguard run_tag.dotdot "RUN_TAG=.. is refused - it escapes the run tree with no separator in it" \
    "\\*\\*\\* RUN_TAG '[^']*' is a relative-path element" 'ifneq ($(filter . ..,$(RUN_TAG)),)' RUN_TAG=..

#=============================================================================
# 3. BUILD_DIR - THE SAME rm, ONE LEVEL UP
#=============================================================================
t_head "BUILD_DIR: relative, '/' and empty"

argguard build_dir.relative "a relative BUILD_DIR is refused - it resolves to two different places" \
    "is a relative path" 'ifneq ($(BUILD_DIR),$(subst //,/,/$(BUILD_DIR)))' BUILD_DIR=relative/build

argguard build_dir.root "BUILD_DIR=/ is refused" \
    "resolves to '/'" 'ifeq ($(BUILD_DIR),/)' BUILD_DIR=/

argguard build_dir.empty "BUILD_DIR= is refused - ?= does not default an explicitly empty value" \
    "BUILD_DIR is empty" 'ifeq ($(strip $(BUILD_DIR)),)' BUILD_DIR=

#=============================================================================
# 4. THE EXAMPLES REFUSAL (CONTRACT.md section 2)
#
# The example sits at exactly the paths every `?=` defaults to, so a build from
# inside it succeeds and produces a different design without a word.
#
# THE FIXTURE IS A COPY OF THE TOOLKIT, not the toolkit: creating examples/ in
# the checkout under test would be this suite editing the thing it is measuring.
# The copy is unmodified, so the baseline assertion is still about the shipped
# guard - only the mutant has a fault planted in it.
#=============================================================================
t_head "a project inside the toolkit's own examples/ is refused"

EX="$(t_mutant "$SB" examples-baseline)"
mkdir -p "$EX/examples/demo"
if t_project "$EX/examples/demo" "$EX"; then
    t_check contract.examples "building from inside examples/ is refused by name" \
        guard_fires "$EX/examples/demo" 'points inside the toolkit'"'"'s own examples/'
    EXM="$(t_mutant "$SB" examples-mutation)"
    mkdir -p "$EXM/examples/demo"
    t_project "$EXM/examples/demo" "$EXM"
    if t_replace_line "$EXM" mk/flow.mk \
        'ifneq (,$(findstring $(FPGA_FLOW_DIR)/examples/,$(FPGA_DIR)/))' "$GUARD_OFF"; then
        t_check_fail contract.examples.mutation \
            "with the refusal disabled the example builds like a project, which is the whole hazard" \
            guard_fires "$EXM/examples/demo" 'points inside the toolkit'"'"'s own examples/'
    else
        t_skip contract.examples.mutation "could not plant the fault: the examples/ conditional in mk/flow.mk has been reformatted"
    fi
else
    t_skip contract.examples "could not scaffold a project inside the copied toolkit's examples/"
fi

#=============================================================================
# 5. THE PARSE THAT MUST SUCCEED
#
# Everything above asserts a refusal, and a file that refused EVERYTHING would
# pass all of it. This is the positive control: a well-formed project parses.
#
# It is also where an incomplete checkout shows up. mk/flow.mk includes
# mk/checks.mk, mk/help.mk and mk/hooks.mk and refuses by name if one is
# missing; this repository is being written by several sessions at once, so the
# missing case is a SKIP CARRYING THE REASON and never a pass.
#=============================================================================
t_head "a well-formed project parses, and make env prints its blocks"

MISSING=""
for f in mk/checks.mk mk/help.mk mk/hooks.mk flow/common/seams.txt; do
    [ -e "$FLOW_DIR/$f" ] || MISSING="$MISSING $f"
done

P_OK="$(proj_for "$FLOW_DIR" "well-formed")"

env_ok() { make -C "$1" --no-print-directory env >/dev/null 2>&1; }

## env_has_blocks <project> - the three blocks CONTRACT.md section 11.2 requires
env_has_blocks() {
    local out; out="$(make -C "$1" --no-print-directory env 2>&1)" || {
        printf 'make env failed:\n%s\n' "$out"; return 1; }
    local b missing=""
    for b in '== engine ==' '== this run ==' '== project contract =='; do
        printf '%s\n' "$out" | grep -qF -- "$b" || missing="$missing '$b'"
    done
    [ -z "$missing" ] && return 0
    printf 'make env printed no%s block:\n%s\n' "$missing" "$out"
    return 1
}

## env_renders_none <project> - an unset optional prints (none), never a blank
## column. A blank and a value that happens to be blank are indistinguishable in
## a terminal, and one of them is a broken lookup.
env_renders_none() {
    local out; out="$(make -C "$1" --no-print-directory env 2>&1)" || return 1
    printf '%s\n' "$out" | grep -qE '^  PART +\(none\)$'
}

## derived_not_settable <project> - CONTRACT.md section 3.5. A command-line
## assignment to a DERIVED variable must NOT win: GNU make gives command-line
## variables precedence over every file assignment unless the file says
## `override`, so without it `make clean WORK_DIR=$HOME/scratch` composes an
## `rm -rf` on a path no guard in section 2 ever saw.
derived_not_settable() {
    local out; out="$(make -C "$1" --no-print-directory env \
        RUN_DIR=/hijacked/run WORK_DIR=/hijacked/work 2>&1)" || {
        printf 'make env failed:\n%s\n' "$out"; return 1; }
    if printf '%s\n' "$out" | grep -qE '^  (RUN_DIR|WORK_DIR) +/hijacked/'; then
        printf 'a DERIVED variable took its value from the command line:\n%s\n' \
            "$(printf '%s\n' "$out" | grep -E '^  (RUN_DIR|WORK_DIR) ')"
        return 1
    fi
    # And it must still be REPORTED, so the attempt does not vanish without
    # trace - a silent discard being the failure class this toolkit exists to end.
    printf '%s\n' "$out" | grep -qE '^  derived preset .*RUN_DIR\[command line\]' && return 0
    printf 'the attempt was discarded but not reported in the derived-preset line:\n%s\n' \
        "$(printf '%s\n' "$out" | grep -E 'derived preset')"
    return 1
}

if [ -n "$MISSING" ]; then
    for id in parses env.blocks env.none derived.override; do
        t_skip "contract.$id" "mk/flow.mk includes$MISSING, which is/are not in this checkout yet, so no project can complete a parse here. Not a pass: this check did not run"
    done
else
    t_check contract.parses      "a project setting only the three required variables parses" env_ok "$P_OK"
    t_check contract.env.blocks  "make env prints the engine, this-run and project-contract blocks" env_has_blocks "$P_OK"
    t_check contract.env.none    "an unset optional renders as (none), not as a blank column" env_renders_none "$P_OK"
    t_check contract.derived.override \
        "a DERIVED variable assigned on the command line is discarded AND reported" \
        derived_not_settable "$P_OK"

    # -- mutation proofs for the three positive assertions --------------------
    M="$(t_mutant "$SB" env-block)"
    if t_replace_line "$M" mk/flow.mk '	@echo "== this run =="' '	@true'; then
        PM="$(proj_for "$M" "env-block")"
        t_check_fail contract.env.blocks.mutation \
            "with one block heading removed, the blocks assertion goes red" \
            env_has_blocks "$PM"
    else
        t_skip contract.env.blocks.mutation "could not plant the fault: the '== this run ==' heading in mk/flow.mk has changed shape"
    fi

    M="$(t_mutant "$SB" env-none)"
    if t_replace_line "$M" mk/flow.mk \
        'fpga_or_none = $(if $(strip $(1)),$(strip $(1)),(none))' \
        'fpga_or_none = $(strip $(1))'; then
        PM="$(proj_for "$M" "env-none")"
        t_check_fail contract.env.none.mutation \
            "with (none) rendered as a blank, the assertion goes red" \
            env_renders_none "$PM"
    else
        t_skip contract.env.none.mutation "could not plant the fault: fpga_or_none in mk/flow.mk has changed shape"
    fi

    M="$(t_mutant "$SB" derived-settable)"
    if t_replace_line "$M" mk/flow.mk \
        'override RUN_DIR       := $(BUILD_DIR)/$(RUN_TAG)' \
        'RUN_DIR       := $(BUILD_DIR)/$(RUN_TAG)'; then
        PM="$(proj_for "$M" "derived-settable")"
        t_check_fail contract.derived.override.mutation \
            "with 'override' dropped from RUN_DIR, the command line wins and the assertion goes red" \
            derived_not_settable "$PM"
    else
        t_skip contract.derived.override.mutation "could not plant the fault: the RUN_DIR assignment in mk/flow.mk has changed shape"
    fi
fi

#=============================================================================
# 6. FLOW_MODE - A MODE NAME THAT NAMES NOTHING
#
# `FLOW_MODE ?= project` was the default, and `project` did not exist: it
# selected the same in-memory synthesis `direct` does, plus a NOT-covered
# bullet in the gate saying the declaration had been ignored. `protocompiler`
# was consumed by nothing at all, and `dfx` set exactly one synth_design
# argument - `-mode out_of_context` - with none of the partition, pblock or
# partial-bitstream handling that would make it a flow, which on a board-level
# top is a netlist with no IO buffer on any port.
#
# So the guard under test refuses all three BY NAME. The refusals are asserted
# one at a time rather than in a loop, because each is a different claim about
# a different sentence in the message: a reader who typed `dfx` needs to be
# told which knob still gives them out-of-context synthesis, and a reader who
# typed `project` does not.
#
# THE POSITIVE CONTROL AT THE END IS NOT OPTIONAL HERE. A guard written
# `ifneq ($(strip $(FLOW_MODE)),something-nobody-sets)` refuses all four values
# and passes every refusal assertion above it, which is precisely the shape a
# mis-aimed guard takes. The last case plants that fault and requires the
# accepted value to go red.
#=============================================================================
t_head "FLOW_MODE: 'direct' is the default, and the only value that parses"

FLOW_MODE_GUARD='ifneq ($(strip $(FLOW_MODE)),direct)'

argguard flow_mode.project \
    "FLOW_MODE=project is refused BY NAME - no stage implements launch_runs" \
    "\\*\\*\\* FLOW_MODE is 'project' and the only mode this toolkit implements" \
    "$FLOW_MODE_GUARD" FLOW_MODE=project

argguard flow_mode.protocompiler \
    "FLOW_MODE=protocompiler is refused - it was consumed by nothing anywhere" \
    "\\*\\*\\* FLOW_MODE is 'protocompiler' and the only mode this toolkit implements" \
    "$FLOW_MODE_GUARD" FLOW_MODE=protocompiler

# The dfx regex reaches past the name to the REMEDY, because refusing dfx is
# only honest if the one thing it really did is still reachable. If that
# sentence is ever dropped from the message this assertion goes red, which is
# the point of asserting on the message instead of the exit status.
argguard flow_mode.dfx \
    "FLOW_MODE=dfx is refused, and the message names the knob that replaces it" \
    "\\*\\*\\* FLOW_MODE is 'dfx'.*SYNTH_MODE=out_of_context" \
    "$FLOW_MODE_GUARD" FLOW_MODE=dfx

## flow_mode_is <project> <expected> [make args...]
## `make env` must COMPLETE and report that value. Both halves matter: the
## guard and the default now agree by construction, so a fault in either one
## shows up as a refused parse rather than as a wrong value, and a test that
## only grepped the line would report "no match" for both causes alike.
flow_mode_is() {
    local proj="$1" want="$2"; shift 2
    local out rc=0
    out="$(make -C "$proj" --no-print-directory env "$@" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'make env was REFUSED where it should have parsed:\n%s\n' "$out"
        return 1
    fi
    printf '%s\n' "$out" | grep -qE "^  FLOW_MODE +$want\$" && return 0
    printf 'make env parsed but does not report FLOW_MODE as %s:\n%s\n' \
        "$want" "$(printf '%s\n' "$out" | grep -E '^  FLOW_MODE ' || echo '(no FLOW_MODE line)')"
    return 1
}

if [ -n "$MISSING" ]; then
    for id in flow_mode.default flow_mode.default.mutation \
              flow_mode.accepts flow_mode.accepts.mutation; do
        t_skip "contract.$id" "mk/flow.mk includes$MISSING, which is/are not in this checkout yet, so no project can complete a parse here. Not a pass: this check did not run"
    done
else
    P_FM="$(proj_for "$FLOW_DIR" "flow-mode")"

    t_check contract.flow_mode.default \
        "an unset FLOW_MODE resolves to 'direct' - the mode that actually runs" \
        flow_mode_is "$P_FM" direct

    # ONE FAULT: the default line goes back to what it used to say. The
    # assertion then goes red because the parse is refused - the guard catching
    # the toolkit's own default is exactly the property wanted, and it is why
    # this proof does not need to disable the guard to show the default is
    # load-bearing.
    M="$(t_mutant "$SB" flow-mode-default)"
    if t_replace_line "$M" mk/flow.mk \
        'FLOW_MODE       ?= direct' \
        'FLOW_MODE       ?= project'; then
        PM="$(proj_for "$M" "flow-mode-default")"
        t_check_fail contract.flow_mode.default.mutation \
            "with the default put back to 'project', the same project stops parsing" \
            flow_mode_is "$PM" direct
    else
        t_skip contract.flow_mode.default.mutation "could not plant the fault: mk/flow.mk has no line exactly 'FLOW_MODE       ?= direct' - the default has been reformatted or removed, and this proof is measuring nothing until it is re-aimed"
    fi

    t_check contract.flow_mode.accepts \
        "FLOW_MODE=direct is ACCEPTED - the guard refuses by name, not by reflex" \
        flow_mode_is "$P_FM" direct FLOW_MODE=direct

    # The mis-aimed guard, planted: it still refuses three of the four names, so
    # every refusal above stays green and only this one goes red. A suite
    # without this case would report a guard that accepts nothing as working.
    M="$(t_mutant "$SB" flow-mode-aimed)"
    if t_replace_line "$M" mk/flow.mk "$FLOW_MODE_GUARD" \
        'ifneq ($(strip $(FLOW_MODE)),a-mode-no-project-will-ever-set)'; then
        PM="$(proj_for "$M" "flow-mode-aimed")"
        t_check_fail contract.flow_mode.accepts.mutation \
            "with the guard aimed at a value nobody sets, 'direct' is refused too and the assertion goes red" \
            flow_mode_is "$PM" direct FLOW_MODE=direct
    else
        t_skip contract.flow_mode.accepts.mutation "could not plant the fault: mk/flow.mk has no line exactly '$FLOW_MODE_GUARD' - the guard has been reformatted or removed, and this proof is measuring nothing until it is re-aimed"
    fi
fi

#=============================================================================
# 7. THE SECOND COPY OF THE MODE LIST
#
# scripts/fpga-flow-check carries FLOW_MODES, and it is the gate that accepted
# `project` for the whole life of this toolkit: an enum compares a value to a
# list and has no way to ask whether anything implements the entries. mk/flow.mk
# now refuses the dead names first, so nothing reaches this check through make -
# which is exactly why it needs its own assertion. A list nothing tests is a
# list that drifts back.
#
# ASSERT ON THE REPORT LINE, NEVER ON THE EXIT STATUS. The checker exits 1 for
# any incomplete contract and this fixture configures almost nothing, so an
# exit-status test would pass just as happily against a checker that had
# stopped looking at FLOW_MODE at all.
#=============================================================================
t_head "the accepted-mode list in scripts/fpga-flow-check agrees with the guard"

## flow_mode_checker_says <flow dir> <mode> <expected status: MISS|ok>
flow_mode_checker_says() {
    local flow="$1" mode="$2" want="$3" out
    out="$("$flow/scripts/fpga-flow-check" \
             --var "FLOW_MODE=$mode" --var "FPGA_DIR=$SB" \
             --var BLOCK=demo_block --var BOARD=demo_board 2>&1)"
    printf '%s\n' "$out" | grep -qE "^ *$want +FLOW_MODE +$mode\$" && return 0
    printf 'fpga-flow-check did not report FLOW_MODE=%s as %s:\n%s\n' "$mode" "$want" \
        "$(printf '%s\n' "$out" | grep -E 'FLOW_MODE' || echo '(no FLOW_MODE line at all)')"
    return 1
}

if [ ! -x "$FLOW_DIR/scripts/fpga-flow-check" ]; then
    t_skip contract.flow_mode.checker "scripts/fpga-flow-check is not in this checkout, or is not executable - the second copy of the mode list cannot be read here, and an unread list is not an agreeing one"
    t_skip contract.flow_mode.checker.mutation "the same: there is no checker to plant a fault in"
elif ! command -v python3 >/dev/null 2>&1; then
    t_skip contract.flow_mode.checker "no python3 on this host, and fpga-flow-check is Python - this assertion did not run"
    t_skip contract.flow_mode.checker.mutation "no python3 on this host: the planted fault could not be exercised"
else
    t_check contract.flow_mode.checker \
        "fpga-flow-check reports FLOW_MODE=project as a MISS, not as an accepted value" \
        flow_mode_checker_says "$FLOW_DIR" project MISS

    M="$(t_mutant "$SB" flow-mode-checker)"
    if t_replace_line "$M" scripts/fpga-flow-check \
        'FLOW_MODES = ("direct",)                                     # §3.3 Target' \
        'FLOW_MODES = ("project", "direct", "dfx", "protocompiler")   # the list as it stood before 2026-09-11'; then
        t_check_fail contract.flow_mode.checker.mutation \
            "with the old four-value list restored, the checker calls 'project' fine and the assertion goes red" \
            flow_mode_checker_says "$M" project MISS
    else
        t_skip contract.flow_mode.checker.mutation "could not plant the fault: the FLOW_MODES line in scripts/fpga-flow-check has been reformatted, and this proof is measuring nothing until it is re-aimed"
    fi
fi

t_summary
