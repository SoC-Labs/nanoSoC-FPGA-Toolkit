#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# t_flow_mk.sh - mk/flow.mk beyond its guards: the stage graph, the variable
#                surface, the export set, and the recipes that run with no tool
#
# DEFECT CLASS: EXPANSION-ORDER DRIFT IN A MAKEFILE TOO LONG TO HOLD IN ONE HEAD.
#
# t_contract.sh proves the `$(error)` guards can fire. Nothing proved the rest:
# 1771 lines in which every value is the end of a `?=` chain, every export is
# a choice between `=` and `:=`, and every rule target is expanded at the
# moment make reads it. Three defects in the file's first fortnight were
# exactly that class, and each one was found by a run, not by a test:
#
#   - `export FPGA_X := $(X)` snapshotted BEFORE the sibling fragments were
#     read, so `make env` printed the project's MSG_GATE_ALLOWLIST while the
#     run manifest for the same invocation recorded (none). 2026-09-08.
#   - a rule whose target was composed from $(BUILD_DIR) expanded at parse
#     time, before the variable had a value, and resolved to /gen/ at the
#     filesystem root.
#   - `$(if $(strip $(2)),<run them>,:)` in post_stage_targets, with a comma
#     in the prose of the then-part: make split the sentence at the comma and
#     every stage ended with `/bin/sh: unexpected EOF`, empty list or not.
#
# None of those is visible in a diff. A `:=` and an `=` look alike, a target
# path looks like every other path, and a comma in a sentence is a comma. So
# this file plants each of them, in a copy, and requires the assertion beside
# it to go red - which is also what makes splitting mk/flow.mk into fragments
# safe to attempt: every line that moves passes these same hazards again.
#
# HOW THE PROPERTIES ARE READ, and the two rules every assertion follows:
#
#   ASK MAKE FOR EVERY PATH. `make --eval='p: ; @echo $(VAR)' p` is how a value
#   is read here, never a path this file composed for itself: a test that
#   built $(RUN_DIR) from its own idea of the layout would agree with a
#   mk/flow.mk that had the same idea, and prove nothing when both were wrong.
#
#   NEVER THE EXIT STATUS ALONE. The stage graph is driven with `make -n` and
#   judged on the recipe it PRINTS and the order it prints it in. `make -p` is
#   the rule database, read for prerequisites and for target names. The few
#   recipes that run for real - dirs, status, clean, distclean and the
#   post-stage macro - are judged on the artefacts they leave and the lines
#   they print.
#
# THE LISTS COME FROM THE FILES THAT OWN THEM. The stage chain is CONTRACT.md
# section 4's arrow line; the variable surface is section 3.3's fenced blocks;
# the derived seven are section 3.5's; the artefacts are section 4's table;
# the export pairs are grepped out of mk/flow.mk itself. A list spelled in
# this file would go stale silently, which is rule three, and the whole reason
# the toolkit exists.
#
# NOTHING HERE LAUNCHES A TOOL. `make -n` prints the Vivado invocation and
# does not run it; the completing fixture is needed only so that `check-quiet`
# - a prerequisite of every stage - lets `dirs` run for real.
#
# THE FIXTURE PROJECT NAMES NOTHING REAL. CONTRACT.md section 11.8: BLOCK and
# BOARD are placeholders, and the part pack is whatever part/ holds first.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/lib/harness.sh
. "$HERE/../lib/harness.sh"

t_sandbox; SB="$T_SANDBOX"
T=$'\t'

# A conditional that is false whatever the project says (t_contract.sh's form).
GUARD_OFF='ifeq (guard-disabled-by-mutation-proof,never-equal)'

# A REPLACEMENT THAT ENDS IN A LINE CONTINUATION IS WRITTEN `\\`, AND EVERY ONE
# OF THEM BELOW DOES.
#
# t_replace_line plants its text with sed's `c\`, which EATS a trailing
# backslash - so a replacement written `@false && \` lands in the makefile as
# `@false && ` and the continuation to the next line is gone. That is a SECOND
# fault, in the same copy, and it is the one that fires: the recipe becomes a
# shell syntax error, the assertion goes red for that rather than for the
# property it names, and the proof reads as green while measuring nothing it
# claims to.
#
# Measured here, not reasoned about. Ten proofs in the first draft of this file
# were written that way, and the verification pass caught three of them red-
# handed: the distclean proof went red because the run SURVIVED (a broken
# recipe never reached the `rm`) rather than because the bitstream went
# unannounced; the status proof reported all six rows wrong rather than the one
# row it re-aimed; and the vivado_stage proof reported a missing `cd` rather
# than the missing `-mode batch`. Doubling the backslash leaves sed emitting
# exactly one, and each mutant is one coherent fault again.
#
# AND THE RULE IS A CHECK, NOT A COMMENT. `t_plant` below refuses a replacement
# that drops a continuation the original line had, so the next proof written
# the wrong way fails LOUDLY when it is planted instead of passing quietly
# while measuring nothing. A comment would have been a claim that was true on
# the day somebody read it; this file's whole subject is the difference.

## t_plant <mutant> <relative path> <exact line> <replacement>
##
## t_replace_line, with one extra rule: if the line being replaced ends in a
## line continuation, the replacement must keep one - written `\\`, because
## sed's `c\` turns two backslashes into one and eats a lone one.
t_plant() {
    local mut="$1" rel="$2" want="$3" repl="$4"
    case "$want" in
        *\\)
            case "$repl" in
                *\\\\) ;;
                *) printf 't_plant: %s ends in a line continuation and the replacement does not keep one.\n' "$rel" >&2
                   printf '         Write the replacement ending in TWO backslashes - sed emits one.\n' >&2
                   printf '         replacement was: %s\n' "$repl" >&2
                   return 2 ;;
            esac ;;
    esac
    t_replace_line "$mut" "$rel" "$want" "$repl"
}

#=============================================================================
# 0. PRECONDITIONS, AND WHAT IS SKIPPED WHEN ONE IS ABSENT
#
# The file under test includes three siblings and refuses by name when one is
# missing; a checkout without them can parse no project at all, so every
# assertion here would fail for a reason that has nothing to do with the
# property it names. That is a SKIP carrying the reason, never a pass, and
# never a red that sends a reader to the wrong file.
#=============================================================================
MISSING=""
for f in mk/checks.mk mk/help.mk mk/hooks.mk flow/common/seams.txt; do
    [ -e "$FLOW_DIR/$f" ] || MISSING="$MISSING $f"
done
if [ -n "$MISSING" ]; then
    t_skip flow_mk.all "mk/flow.mk includes$MISSING, which is/are not in this checkout, so no project can complete a parse here - nothing below ran"
    t_summary; exit $?
fi

# The part pack is WHATEVER part/ HOLDS, never a name spelled here (CONTRACT.md
# section 6.2: the directory is the list).
PACK="$(find "$FLOW_DIR/part" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
        | sed 's|.*/||' | LC_ALL=C sort | head -1)"

# The completing fixture needs the checker and python3; the parse-only
# fixtures need neither. Each section that runs `dirs` for real says which.
CHECKER_REASON=""
if [ ! -x "$FLOW_DIR/scripts/fpga-flow-check" ]; then
    CHECKER_REASON="scripts/fpga-flow-check is not in this checkout or not executable, and check-quiet - a prerequisite of every stage - runs it"
elif ! command -v python3 >/dev/null 2>&1; then
    CHECKER_REASON="no python3 on this host, and check-quiet runs a Python checker before any stage"
elif [ -z "$PACK" ]; then
    CHECKER_REASON="no part pack under part/, so no contract can complete and check-quiet refuses every stage"
fi

#=============================================================================
# THE FIXTURES AND THE PROBES
#=============================================================================

## proj_for <flow dir> <name> [extra design.mk lines] -> the project directory
##
## t_project's three-line contract, with the extra lines inserted BEFORE the
## include - which is where CONTRACT.md section 2 puts everything a project
## says about itself. The late-assignment fixture below is the one exception,
## and it appends to the Makefile on purpose.
proj_for() {
    local flow="$1" name="$2" extra="${3:-}" d
    d="$SB/proj-$name"
    t_project "$d" "$flow" >&2 || return 2
    if [ -n "$extra" ]; then
        { grep -v '^include ' "$d/design.mk"; printf '%s\n' "$extra"; grep '^include ' "$d/design.mk"; } \
            > "$d/design.mk.new" && mv "$d/design.mk.new" "$d/design.mk"
    fi
    printf '%s' "$d"
}

## full_for <flow dir> <name> [extra design.mk lines] -> a contract that COMPLETES
##
## Everything `make check` requires, so check-quiet prints nothing and `dirs`
## can run. PACKAGE_TCL and BD_TCL are set so that the two conditional stages
## are LIVE - under `make -n` a skipped stage prints a SKIP line and no launch,
## and the graph assertions want all six launches. BD_TCL has to contain
## create_bd_design or the checker refuses it as a script that builds nothing.
full_for() {
    local flow="$1" name="$2" extra="${3:-}" d
    d="$SB/full-$name"
    t_in_sandbox "$d" || { echo "full_for: refusing to scaffold outside a sandbox" >&2; return 2; }
    mkdir -p "$d/board" "$d/rtl" "$d/targets/demo_board" || return 2
    printf 'FPGA_DIR := $(CURDIR)\ninclude $(FPGA_DIR)/design.mk\n' > "$d/Makefile"
    {
        printf 'FPGA_FLOW_DIR := %s\n' "$flow"
        printf 'BLOCK := demo_block\nBOARD := demo_board\n'
        printf 'BOARD_DIR := $(FPGA_DIR)/board\n'
        printf 'PART := %s\n' "$PACK"
        printf 'TOP := demo_block\n'
        printf 'RTL_FLIST := $(FPGA_DIR)/rtl/demo.flist\n'
        printf 'XDC_PINS := $(FPGA_DIR)/pins.xdc\n'
        printf 'PACKAGE_TCL := $(FPGA_DIR)/pkg.tcl\n'
        printf 'BD_TCL := $(FPGA_DIR)/bd.tcl\n'
        [ -n "$extra" ] && printf '%s\n' "$extra"
        printf 'include %s/mk/flow.mk\n' "$flow"
    } > "$d/design.mk"
    printf '# a board pack that names nothing real\n' > "$d/board/board.tcl"
    printf 'module demo_block;\nendmodule\n' > "$d/rtl/demo.v"
    printf '%s\n' "$d/rtl/demo.v" > "$d/rtl/demo.flist"
    printf 'set_property PACKAGE_PIN A1 [get_ports sys_clk]\n' > "$d/pins.xdc"
    printf '# a packaging script; make -n never runs it\n' > "$d/pkg.tcl"
    printf 'create_bd_design demo_block\n' > "$d/bd.tcl"
    printf '%s' "$d"
}

## late_lines <project> <lines> - assignments AFTER `include design.mk`.
##
## The shape of the 2026-09-08 defect: a value that reaches make after
## mk/flow.mk has been read. A fragment appending to a post-target list does
## exactly this, and so does a project Makefile with a line under its include.
late_lines() { printf '%s\n' "$2" >> "$1/Makefile"; }

## mk_probe <project> <recipe line>... [-- <make args>...]
##
## Defines a throwaway target in THAT project's make and runs it. The recipe
## lines are make syntax: $(VAR) is what make resolved, $$VAR is what the
## recipe's environment carries. Those are the two halves of the export
## property, and they are read in the same process for that reason.
mk_probe() {
    local proj="$1"; shift
    local body='__t_probe:'
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do body="$body"$'\n\t'"$1"; shift; done
    [ "${1:-}" = "--" ] && shift
    make -C "$proj" --no-print-directory --eval="$body" __t_probe "$@" 2>&1
}

## mk_expand <project> <make expression> [make args...] -> its value, one line
mk_expand() {
    local proj="$1" e="$2"; shift 2
    mk_probe "$proj" "@printf '%s\\n' \"$e\"" -- "$@"
}

## mk_dryrun <project> <target> [make args...] -> what `make -n` PRINTS
mk_dryrun() {
    local proj="$1" tgt="$2"; shift 2
    make -C "$proj" --no-print-directory -n "$tgt" "$@" 2>&1
}

## mk_database <project> -> the rule database. `env` has no $(MAKE) line, so
## -p prints exactly one database rather than one per sub-make.
mk_database() { make -C "$1" --no-print-directory -np env 2>/dev/null; }

## contract_chain <flow dir> -> the stages of CONTRACT.md section 4's arrow line
contract_chain() {
    awk '/^## 4\./{on=1} /^## 5\./{on=0} on && /→/ && /dirs/ { print; exit }' "$1/CONTRACT.md" \
        | sed 's/→/ /g' | tr -s ' ' | sed 's/^ *//; s/ *$//'
}

## stage_script <flow dir> <stage> -> the flow/vivado/N_<stage>.tcl that stage runs.
## The directory is the list: the number is the order and the name is the stage.
stage_script() {
    local s; s="$(printf '%s' "$2" | tr - _)"
    find "$1/flow/vivado" -maxdepth 1 -name "[0-9]_$s.tcl" 2>/dev/null | head -1
}

## post_var <stage> -> the <STAGE>_POST_TARGETS name (upper-case, '-' to '_')
post_var() { printf '%s_POST_TARGETS' "$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"; }

CHAIN="$(contract_chain "$FLOW_DIR")"
if [ -z "$CHAIN" ]; then
    t_skip flow_mk.chain "CONTRACT.md section 4 has no 'dirs → ...' arrow line in this checkout, so the stage order this suite compares against could not be read"
    t_summary; exit $?
fi
STAGES="$(printf '%s\n' "$CHAIN" | tr ' ' '\n' | grep -v '^dirs$' | tr '\n' ' ')"

#=============================================================================
# 1. THE STAGE GRAPH
#
#     dirs -> flist -> package-ip -> bd -> synth -> impl -> bitstream
#
# Read three ways. The rule database (`make -p`) for what each target's
# prerequisites ARE; `make -n` for what each target would DO and in what order;
# and `make -n all` for whether the recipe-line form of `all` really descends
# into all seven.
#=============================================================================
t_head "the stage graph: all is recipe lines, in the contract's order"

## all_recipe_order <project> - `all`'s recipe is `$(MAKE) <stage>` per line,
## in exactly the chain's order. Read from the database, where the recipe is
## stored UNEXPANDED - which is what shows it is $(MAKE) and not a literal.
all_recipe_order() {
    local got
    got="$(mk_database "$1" | awk '/^all:/{on=1; next} on && /^$/{exit} on && /^\t@\$\(MAKE\) /{sub(/^\t@\$\(MAKE\) /,""); printf "%s ", $0}')"
    [ "${got% }" = "${CHAIN% }" ] && return 0
    printf 'all runs:   %s\nCONTRACT.md section 4 says: %s\n' "$got" "$CHAIN"
    return 1
}

## all_has_no_prereqs <project> - ordering lives in the recipe, not in a
## prerequisite list. `all: dirs flist ...` looks identical under a serial make
## and is unordered under -j, which is the whole reason for the shape.
all_has_no_prereqs() {
    local line; line="$(mk_database "$1" | grep -E '^all:' | head -1)"
    [ "$line" = "all:" ] && return 0
    printf 'the database shows: %s\n' "$line"
    printf 'prerequisites carry no ordering under -j, and synth and impl cannot overlap.\n'
    return 1
}

## all_descends <project> - `make -n all` prints six launches, in chain order.
## Only a recipe line containing $(MAKE) is EXECUTED under -n; a line that
## merely names a stage is printed and never entered.
all_descends() {
    local out got s
    out="$(mk_dryrun "$1" all)"
    got="$(printf '%s\n' "$out" | grep -oE -- '-source "[^"]*/[0-9]_[a-z_]+\.tcl"' \
           | sed -E 's/.*\/[0-9]_([a-z_]+)\.tcl"/\1/; s/_/-/g' | tr '\n' ' ')"
    [ "${got% }" = "${STAGES% }" ] && return 0
    printf 'launches printed by make -n all: %s\nCONTRACT.md section 4 chain:     %s\n' "$got" "$STAGES"
    return 1
}

P_FULL="$(full_for "$FLOW_DIR" graph)"

t_check flow_mk.graph.all.recipe_order \
    "all's recipe is one \$(MAKE) line per stage, in CONTRACT.md section 4's order" \
    all_recipe_order "$P_FULL"
M="$(t_mutant "$SB" all-order)"
if t_plant "$M" mk/flow.mk "$T"'@$(MAKE) synth' "$T"'@$(MAKE) impl'; then
    PM="$(full_for "$M" all-order)"
    t_check_fail flow_mk.graph.all.recipe_order.mutation \
        "with synth's line made a second impl, the order assertion goes red" \
        all_recipe_order "$PM"
else
    t_skip flow_mk.graph.all.recipe_order.mutation "could not plant the fault: mk/flow.mk has no line exactly '<tab>@\$(MAKE) synth' - all's recipe has changed shape and this proof is measuring nothing until it is re-aimed"
fi

t_check flow_mk.graph.all.no_prereqs \
    "all has NO prerequisites - the order is in the recipe, where -j cannot reorder it" \
    all_has_no_prereqs "$P_FULL"
M="$(t_mutant "$SB" all-prereqs)"
if t_plant "$M" mk/flow.mk 'all:' "all: $CHAIN"; then
    PM="$(full_for "$M" all-prereqs)"
    t_check_fail flow_mk.graph.all.no_prereqs.mutation \
        "with the seven stages made prerequisites of all, the assertion goes red" \
        all_has_no_prereqs "$PM"
else
    t_skip flow_mk.graph.all.no_prereqs.mutation "could not plant the fault: mk/flow.mk has no line exactly 'all:' - the target has changed shape and this proof is measuring nothing until it is re-aimed"
fi

t_check flow_mk.graph.all.descends \
    "make -n all enters all seven sub-makes and prints the six launches in order" \
    all_descends "$P_FULL"
M="$(t_mutant "$SB" all-descends)"
if t_plant "$M" mk/flow.mk "$T"'@$(MAKE) bitstream' "$T"'@echo bitstream'; then
    PM="$(full_for "$M" all-descends)"
    t_check_fail flow_mk.graph.all.descends.mutation \
        "with the last line no longer a \$(MAKE), -n prints it and never enters it, and the assertion goes red" \
        all_descends "$PM"
else
    t_skip flow_mk.graph.all.descends.mutation "could not plant the fault: mk/flow.mk has no line exactly '<tab>@\$(MAKE) bitstream' - all's recipe has changed shape and this proof is measuring nothing until it is re-aimed"
fi

#-----------------------------------------------------------------------------
# 1.2 EVERY STAGE'S PREREQUISITES, DIRECT, FROM THE DATABASE
#
# check-quiet is a prerequisite of EVERY stage target (CONTRACT.md section 4),
# and it is asserted DIRECT rather than transitive on purpose: dirs also
# depends on check-quiet, so a stage that lost its own edge would still run
# the check through dirs today - and would stop the day dirs changed, with no
# assertion anywhere going red. A `make -n` reading would call that fine.
#-----------------------------------------------------------------------------
t_head "every stage names check-quiet and dirs as direct prerequisites"

## stage_prereqs <project> <stage> -> the prerequisite list from the database
stage_prereqs() { mk_database "$1" | grep -E "^$2:" | head -1 | sed "s/^$2: *//"; }

## stages_depend_on <project> <prerequisite> <stages...>
stages_depend_on() {
    local proj="$1" want="$2"; shift 2
    local s pre bad=""
    for s in "$@"; do
        pre="$(stage_prereqs "$proj" "$s")"
        case " $pre " in *" $want "*) ;; *) bad="$bad $s($pre)" ;; esac
    done
    [ -z "$bad" ] && return 0
    printf 'stages without %s as a DIRECT prerequisite:%s\n' "$want" "$bad"
    return 1
}

t_check flow_mk.graph.stage.check_quiet \
    "check-quiet is a direct prerequisite of every stage in the chain, dirs included" \
    stages_depend_on "$P_FULL" check-quiet $CHAIN
M="$(t_mutant "$SB" stage-check)"
if t_plant "$M" mk/flow.mk 'synth: dirs check-quiet' 'synth: dirs'; then
    PM="$(full_for "$M" stage-check)"
    t_check_fail flow_mk.graph.stage.check_quiet.mutation \
        "with synth's own check-quiet edge dropped (dirs still carries one), the assertion goes red" \
        stages_depend_on "$PM" check-quiet $CHAIN
else
    t_skip flow_mk.graph.stage.check_quiet.mutation "could not plant the fault: mk/flow.mk has no line exactly 'synth: dirs check-quiet' - the rule has changed shape and this proof is measuring nothing until it is re-aimed"
fi

t_check flow_mk.graph.stage.dirs \
    "dirs is a direct prerequisite of every stage after it" \
    stages_depend_on "$P_FULL" dirs $STAGES
M="$(t_mutant "$SB" stage-dirs)"
if t_plant "$M" mk/flow.mk 'impl: dirs check-quiet' 'impl: check-quiet'; then
    PM="$(full_for "$M" stage-dirs)"
    t_check_fail flow_mk.graph.stage.dirs.mutation \
        "with impl's dirs edge dropped, the assertion goes red" \
        stages_depend_on "$PM" dirs $STAGES
else
    t_skip flow_mk.graph.stage.dirs.mutation "could not plant the fault: mk/flow.mk has no line exactly 'impl: dirs check-quiet' - the rule has changed shape and this proof is measuring nothing until it is re-aimed"
fi

#-----------------------------------------------------------------------------
# 1.3 WHAT `make -n <stage>` PRINTS, AND IN WHAT ORDER
#
# The check runs, then the run tree is made, then the tool is launched - and
# the launch carries every part of the invocation mk/flow.mk section 9 argues
# for, each of which was put there by a measured failure: -mode batch (the
# default is the GUI), -log/-journal into LOG_DIR (the default is the working
# directory), < /dev/null (a tool at an unexpected prompt holds a licence
# forever), and the three per-stage exports flow_utils.tcl declares it reads.
#-----------------------------------------------------------------------------
t_head "make -n <stage>: check, then dirs, then a launch of the right shape"

## stage_launch_order <project> <flow dir> <stages...>
## check-quiet's command precedes dirs' mkdir precedes the -source line.
stage_launch_order() {
    local proj="$1" flow="$2"; shift 2
    local s out script wd c d l bad=""
    wd="$(mk_expand "$proj" '$(WORK_DIR)')"
    for s in "$@"; do
        script="$(stage_script "$flow" "$s")"
        out="$(mk_dryrun "$proj" "$s")"
        c="$(printf '%s\n' "$out" | grep -n -- 'fpga-flow-check --quiet' | head -1 | cut -d: -f1)"
        d="$(printf '%s\n' "$out" | grep -nF -- "mkdir -p \"$wd\"" | head -1 | cut -d: -f1)"
        l="$(printf '%s\n' "$out" | grep -nF -- "-source \"$script\"" | head -1 | cut -d: -f1)"
        if [ -z "$c" ] || [ -z "$d" ] || [ -z "$l" ] || [ "$c" -ge "$d" ] || [ "$d" -ge "$l" ]; then
            bad="$bad $s(check@${c:-none} dirs@${d:-none} launch@${l:-none})"
        fi
    done
    [ -z "$bad" ] && return 0
    printf 'stages whose dry run does not print check, then dirs, then the launch:%s\n' "$bad"
    return 1
}

## stage_launch_shape <project> <flow dir> <stages...>
## Every part of the invocation, on the printed launch line, with the paths
## make itself resolves for this project.
stage_launch_shape() {
    local proj="$1" flow="$2"; shift 2
    local s line script wd ld part bad=""
    wd="$(mk_expand "$proj" '$(WORK_DIR)')"
    ld="$(mk_expand "$proj" '$(LOG_DIR)')"
    for s in "$@"; do
        script="$(stage_script "$flow" "$s")"
        line="$(mk_dryrun "$proj" "$s" | grep -F -- "-source \"$script\"" | head -1)"
        [ -n "$line" ] || { bad="$bad $s(no launch line)"; continue; }
        for part in "cd \"$wd\" && " "FPGA_STAGE=$s " "FPGA_STAGE_T0=" \
                    "FPGA_LOG_FILE=\"$ld/$s.log\"" "FPGA_TOOL_HINT=" " -mode batch" \
                    "-log \"$ld/$s.log\"" "-journal \"$ld/$s.jou\"" "< /dev/null"; do
            t_contains "$line" "$part" || bad="$bad $s(missing: $part)"
        done
    done
    [ -z "$bad" ] && return 0
    printf 'launch lines missing a part of the invocation:%s\n' "$bad"
    return 1
}

t_check flow_mk.graph.stage.order \
    "for every stage, -n prints check-quiet, then dirs' mkdir, then the launch" \
    stage_launch_order "$P_FULL" "$FLOW_DIR" $STAGES
# The fault is in the SIBLING, because the prerequisite is only worth its
# place if the target it names does something: a check-quiet whose recipe
# was neutered still satisfies the database assertion above.
M="$(t_mutant "$SB" stage-order)"
if t_plant "$M" mk/checks.mk "$T"'@$(CHECK_SCRIPT) --quiet $(CHECK_ARGS)' "$T"'@true'; then
    PM="$(full_for "$M" stage-order)"
    t_check_fail flow_mk.graph.stage.order.mutation \
        "with check-quiet's recipe neutered in a copy, no check precedes any launch and the assertion goes red" \
        stage_launch_order "$PM" "$M" $STAGES
else
    t_skip flow_mk.graph.stage.order.mutation "could not plant the fault: mk/checks.mk has no line exactly '<tab>@\$(CHECK_SCRIPT) --quiet \$(CHECK_ARGS)' - check-quiet's recipe has changed shape and this proof is measuring nothing until it is re-aimed"
fi

t_check flow_mk.graph.stage.launch \
    "every launch has cd WORK_DIR, the three per-stage exports, -mode batch, -log, -journal, -source and </dev/null" \
    stage_launch_shape "$P_FULL" "$FLOW_DIR" $STAGES
M="$(t_mutant "$SB" launch-batch)"
if t_plant "$M" mk/flow.mk '$(VIVADO) -mode batch \' '$(VIVADO) \\'; then
    PM="$(full_for "$M" launch-batch)"
    t_check_fail flow_mk.graph.stage.launch.mutation \
        "with -mode batch dropped from the one macro, every stage would open the GUI and the assertion goes red" \
        stage_launch_shape "$PM" "$M" $STAGES
else
    t_skip flow_mk.graph.stage.launch.mutation "could not plant the fault: mk/flow.mk has no line exactly '\$(VIVADO) -mode batch \\' - vivado_stage has changed shape and this proof is measuring nothing until it is re-aimed"
fi
M="$(t_mutant "$SB" launch-stdin)"
if t_plant "$M" mk/flow.mk '    -source "$(2)" < /dev/null' '    -source "$(2)"'; then
    PM="$(full_for "$M" launch-stdin)"
    t_check_fail flow_mk.graph.stage.launch.stdin.mutation \
        "with </dev/null dropped, a tool at a prompt would hold a licence forever, and the assertion goes red" \
        stage_launch_shape "$PM" "$M" $STAGES
else
    t_skip flow_mk.graph.stage.launch.stdin.mutation "could not plant the fault: mk/flow.mk has no line exactly '    -source \"\$(2)\" < /dev/null' - vivado_stage has changed shape and this proof is measuring nothing until it is re-aimed"
fi

#-----------------------------------------------------------------------------
# 1.4 THE ARTEFACTS EACH STAGE ASSERTS ON, AGAINST CONTRACT.md SECTION 4'S TABLE
#
# "Produces (asserted on)" is the contract's phrase, and it is the rule the
# whole file is built on: a stage passed when the artefact is on disk, never
# when the tool returned 0. So the printed recipe of every stage must `test`
# for each artefact the table lists for it, at a path make resolves under this
# run's RUN_DIR - and a `test -s` that stopped being there is a stage that
# passes on a tool that wrote nothing.
#
# The table is parsed as it is written: `$(...)` items are expanded by make,
# a `<vlnv>` segment is a directory the stage cannot know (it finds the file
# under the prefix instead), and a bare name is a suffix.
#-----------------------------------------------------------------------------
t_head "each stage's recipe asserts every artefact CONTRACT.md section 4 lists"

## contract_artefacts <flow dir> <stage> -> that row's backticked items
contract_artefacts() {
    awk -v s="$2" '/^## 4\./{on=1} /^## 5\./{on=0} on && index($0, "| `" s "` |") == 1 { print; exit }' "$1/CONTRACT.md" \
        | sed 's/^| `[^`]*` | //; s/ |$//' | grep -oE '`[^`]+`' | tr -d '`'
}

## stage_asserts_artefacts <project> <flow dir> <stage>
stage_asserts_artefacts() {
    local proj="$1" flow="$2" s="$3"
    local items out paths run p item want prefix base bad="" n=0
    items="$(contract_artefacts "$flow" "$s")"
    [ -n "$items" ] || { printf 'CONTRACT.md section 4 lists no artefact for %s\n' "$s"; return 2; }
    out="$(mk_dryrun "$proj" "$s")"
    paths="$(printf '%s\n' "$out" | grep -oE '(test -s|find) "[^"]+"' | sed 's/^[^"]*"//; s/"$//')"
    run="$(mk_expand "$proj" '$(RUN_DIR)')"
    while IFS= read -r p; do
        case "$p" in "$run"/*) ;; *) bad="$bad [outside RUN_DIR: $p]" ;; esac
    done <<< "$paths"
    while IFS= read -r item; do
        n=$((n+1))
        case "$item" in
            *'<'*)
                prefix="$(mk_expand "$proj" "${item%%/<*}")"; base="${item##*/}"
                printf '%s\n' "$out" | grep -qF -- "\"$prefix\"" && printf '%s\n' "$out" | grep -qF -- "$base" \
                    || bad="$bad [$item: nothing looks for $base under $prefix]" ;;
            *'$('*)
                want="$(mk_expand "$proj" "$item")"
                printf '%s\n' "$paths" | grep -qFx -- "$want" || bad="$bad [$item -> $want: not tested]" ;;
            *)
                printf '%s\n' "$paths" | grep -qE -- "$(printf '%s' "$item" | sed 's/[.]/\\./g')\$" \
                    || bad="$bad [$item: no test -s path ends with it]" ;;
        esac
    done <<< "$items"
    [ "$n" -gt 0 ] && [ -z "$bad" ] && return 0
    printf '%s: recipe under make -n does not assert what the contract lists:%s\n' "$s" "$bad"
    return 1
}

for s in $STAGES; do
    t_check "flow_mk.graph.artefacts.$s" \
        "$s's recipe tests for every artefact the section 4 table lists, under RUN_DIR" \
        stage_asserts_artefacts "$P_FULL" "$FLOW_DIR" "$s"
done
# The six assertions above share one predicate, so two planted faults cover
# them: one manifest, one output file, in two different stages.
M="$(t_mutant "$SB" artefact-synth)"
if t_plant "$M" mk/flow.mk "$T"'@test -s "$(REPORT_DIR)/synth_manifest.txt" || { \' "$T"'@true || { \\'; then
    PM="$(full_for "$M" artefact-synth)"
    t_check_fail flow_mk.graph.artefacts.synth.mutation \
        "with synth's manifest test replaced by true, the assertion goes red" \
        stage_asserts_artefacts "$PM" "$M" synth
else
    t_skip flow_mk.graph.artefacts.synth.mutation "could not plant the fault: synth's manifest test in mk/flow.mk has changed shape, and this proof is measuring nothing until it is re-aimed"
fi
M="$(t_mutant "$SB" artefact-xsa)"
if t_plant "$M" mk/flow.mk "$T"'@test -s "$(OUT_DIR)/$(BLOCK).xsa" || { \' "$T"'@true || { \\'; then
    PM="$(full_for "$M" artefact-xsa)"
    t_check_fail flow_mk.graph.artefacts.bitstream.mutation \
        "with the .xsa test replaced by true, bitstream passes without a handoff and the assertion goes red" \
        stage_asserts_artefacts "$PM" "$M" bitstream
else
    t_skip flow_mk.graph.artefacts.bitstream.mutation "could not plant the fault: bitstream's .xsa test in mk/flow.mk has changed shape, and this proof is measuring nothing until it is re-aimed"
fi

#-----------------------------------------------------------------------------
# 1.5 THE TWO CONDITIONAL STAGES SKIP LOUDLY, AND ONLY WHEN OFF
#
# The condition is read at PARSE time so `make -n` shows the truth. A skipped
# stage prints a SKIP naming the variable that turns it on and launches
# nothing; a configured one launches and prints no SKIP. Both directions are
# asserted, because a conditional aimed at nothing satisfies either alone.
#-----------------------------------------------------------------------------
t_head "package-ip and bd: SKIP naming the variable when off, a launch when on"

## stage_skips <project> <flow dir> <stage> <variable>
stage_skips() {
    local out script
    script="$(stage_script "$2" "$3")"
    out="$(mk_dryrun "$1" "$3")"
    if printf '%s\n' "$out" | grep -qF -- "-source \"$script\""; then
        printf '%s launched with %s empty\n' "$3" "$4"; return 1
    fi
    printf '%s\n' "$out" | grep -qE -- "echo \"SKIP: $3 .*$4" && return 0
    printf '%s printed no SKIP line naming %s:\n%s\n' "$3" "$4" "$out"; return 1
}

## stage_runs <project> <flow dir> <stage>
stage_runs() {
    local out script
    script="$(stage_script "$2" "$3")"
    out="$(mk_dryrun "$1" "$3")"
    if printf '%s\n' "$out" | grep -qE -- "echo \"SKIP: $3 "; then
        printf '%s printed a SKIP although it is configured\n' "$3"; return 1
    fi
    printf '%s\n' "$out" | grep -qF -- "-source \"$script\"" && return 0
    printf '%s did not launch its script:\n%s\n' "$3" "$out"; return 1
}

P_BARE="$(proj_for "$FLOW_DIR" bare)"

t_check flow_mk.graph.package_ip.off \
    "with PACKAGE_TCL empty, package-ip prints SKIP naming PACKAGE_TCL and launches nothing" \
    stage_skips "$P_BARE" "$FLOW_DIR" package-ip PACKAGE_TCL
M="$(t_mutant "$SB" pkg-off)"
if t_plant "$M" mk/flow.mk 'ifeq ($(strip $(PACKAGE_TCL)),)' "$GUARD_OFF"; then
    PM="$(proj_for "$M" pkg-off)"
    t_check_fail flow_mk.graph.package_ip.off.mutation \
        "with the condition disabled, an unconfigured package-ip launches the tool and the assertion goes red" \
        stage_skips "$PM" "$M" package-ip PACKAGE_TCL
else
    t_skip flow_mk.graph.package_ip.off.mutation "could not plant the fault: mk/flow.mk has no line exactly 'ifeq (\$(strip \$(PACKAGE_TCL)),)' - the condition has changed shape and this proof is measuring nothing until it is re-aimed"
fi

t_check flow_mk.graph.package_ip.on \
    "with PACKAGE_TCL set, package-ip launches its script and prints no SKIP" \
    stage_runs "$P_FULL" "$FLOW_DIR" package-ip
M="$(t_mutant "$SB" pkg-on)"
if t_plant "$M" mk/flow.mk 'ifeq ($(strip $(PACKAGE_TCL)),)' 'ifeq (always-skip-by-mutation,always-skip-by-mutation)'; then
    PM="$(full_for "$M" pkg-on)"
    t_check_fail flow_mk.graph.package_ip.on.mutation \
        "with the condition always true, a configured package-ip skips itself and the assertion goes red" \
        stage_runs "$PM" "$M" package-ip
else
    t_skip flow_mk.graph.package_ip.on.mutation "could not plant the fault: mk/flow.mk has no line exactly 'ifeq (\$(strip \$(PACKAGE_TCL)),)' - the condition has changed shape and this proof is measuring nothing until it is re-aimed"
fi

t_check flow_mk.graph.bd.off \
    "with BD_TCL empty, bd prints SKIP naming BD_TCL and launches nothing" \
    stage_skips "$P_BARE" "$FLOW_DIR" bd BD_TCL
M="$(t_mutant "$SB" bd-off)"
if t_plant "$M" mk/flow.mk 'ifeq ($(strip $(BD_TCL)),)' "$GUARD_OFF"; then
    PM="$(proj_for "$M" bd-off)"
    t_check_fail flow_mk.graph.bd.off.mutation \
        "with the condition disabled, an unconfigured bd launches the tool and the assertion goes red" \
        stage_skips "$PM" "$M" bd BD_TCL
else
    t_skip flow_mk.graph.bd.off.mutation "could not plant the fault: mk/flow.mk has no line exactly 'ifeq (\$(strip \$(BD_TCL)),)' - the condition has changed shape and this proof is measuring nothing until it is re-aimed"
fi

t_check flow_mk.graph.bd.on \
    "with BD_TCL set, bd launches its script and prints no SKIP" \
    stage_runs "$P_FULL" "$FLOW_DIR" bd
M="$(t_mutant "$SB" bd-on)"
if t_plant "$M" mk/flow.mk 'ifeq ($(strip $(BD_TCL)),)' 'ifeq (always-skip-by-mutation,always-skip-by-mutation)'; then
    PM="$(full_for "$M" bd-on)"
    t_check_fail flow_mk.graph.bd.on.mutation \
        "with the condition always true, a configured bd skips itself and the assertion goes red" \
        stage_runs "$PM" "$M" bd
else
    t_skip flow_mk.graph.bd.on.mutation "could not plant the fault: mk/flow.mk has no line exactly 'ifeq (\$(strip \$(BD_TCL)),)' - the condition has changed shape and this proof is measuring nothing until it is re-aimed"
fi

#-----------------------------------------------------------------------------
# 1.6 A BARE `make` IS HELP, NEVER A BUILD; THE INCLUDE GUARD HOLDS; THE
#     SHELL IS BASH; AND NO RULE TARGET IS A PATH
#
# THE PATH-TARGET ONE IS THE SECOND OF THE THREE FOUNDING DEFECTS. A target is
# expanded when make reads the rule, so `$(BUILD_DIR)/gen/x:` written above
# the line that defaults BUILD_DIR is a rule for `/gen/x` at the filesystem
# root - and it parses, and it runs. There is no such rule in the file today,
# which makes this the one check here whose good case has nothing to look at;
# the planted fault is what shows it looks.
#-----------------------------------------------------------------------------
t_head "default goal, include guard, shell, and no path-shaped targets"

## bare_make_is_help <project>
bare_make_is_help() {
    local out; out="$(make -C "$1" --no-print-directory -n 2>&1)"
    if printf '%s\n' "$out" | grep -qE -- '-mode batch|-source "'; then
        printf 'a bare make would launch a tool:\n%s\n' "$(printf '%s\n' "$out" | grep -E -- '-source "' | head -3)"
        return 1
    fi
    printf '%s\n' "$out" | grep -qF 'FPGA image build' && return 0
    printf 'a bare make printed neither help nor a launch:\n%s\n' "$(printf '%s\n' "$out" | head -5)"
    return 1
}

## double_include_is_quiet <project> - the section 2 Makefile shape includes
## design.mk AND flow.mk; without the guard make redefines every rule and
## warns once per target, then silently runs the SECOND definition.
double_include_is_quiet() {
    local out; out="$(make -C "$1" --no-print-directory -n env 2>&1)"
    if printf '%s\n' "$out" | grep -qi 'overriding recipe'; then
        printf 'including flow.mk twice redefined rules:\n%s\n' "$(printf '%s\n' "$out" | grep -i overriding | head -3)"
        return 1
    fi
    printf '%s\n' "$out" | grep -qF '== engine ==' || { printf 'make -n env printed no env block:\n%s\n' "$out"; return 1; }
    return 0
}

## shell_is_bash <project>
shell_is_bash() {
    local got; got="$(mk_expand "$1" '$(SHELL)')"
    [ "$got" = /bin/bash ] && return 0
    printf 'SHELL is %s; the recipes use [[, PIPESTATUS and case fallthrough, and dash has none of them\n' "$got"
    return 1
}

## no_path_targets <project> - every real target in the database is a name.
## A path target is a rule that was expanded at parse time, which is the
## /gen/-at-the-root defect whatever its value happens to be today.
no_path_targets() {
    local got
    got="$(mk_database "$1" | awk '
        prev ~ /^# Not a target:/ { prev = $0; next }
        /^[^#\t ][^:=]*:([^=]|$)/ { name = $0; sub(/:.*/, "", name); if (name ~ /\//) print name }
        { prev = $0 }')"
    [ -z "$got" ] && return 0
    printf 'rule targets that are PATHS - expanded when make read the rule, not when it ran:\n%s\n' "$got"
    return 1
}

t_check flow_mk.graph.default_goal "a bare make prints help and would launch nothing" \
    bare_make_is_help "$P_FULL"
M="$(t_mutant "$SB" default-goal)"
if t_plant "$M" mk/flow.mk '.DEFAULT_GOAL := help' '.DEFAULT_GOAL := all'; then
    PM="$(full_for "$M" default-goal)"
    t_check_fail flow_mk.graph.default_goal.mutation \
        "with the default goal made all, a bare make starts a multi-hour build and the assertion goes red" \
        bare_make_is_help "$PM"
else
    t_skip flow_mk.graph.default_goal.mutation "could not plant the fault: mk/flow.mk has no line exactly '.DEFAULT_GOAL := help', and this proof is measuring nothing until it is re-aimed"
fi

P_TWICE="$(proj_for "$FLOW_DIR" twice)"
printf 'FPGA_DIR := $(CURDIR)\ninclude $(FPGA_DIR)/design.mk\ninclude $(FPGA_FLOW_DIR)/mk/flow.mk\n' > "$P_TWICE/Makefile"
t_check flow_mk.graph.include_guard \
    "the section 2 Makefile (design.mk and flow.mk both included) parses without redefining a rule" \
    double_include_is_quiet "$P_TWICE"
M="$(t_mutant "$SB" include-guard)"
if t_plant "$M" mk/flow.mk 'ifndef FPGA_FLOW_MK_INCLUDED' 'ifndef FPGA_FLOW_MK_INCLUDED_NEVER_SET_BY_THIS_MUTATION'; then
    PM="$(proj_for "$M" include-guard)"
    printf 'FPGA_DIR := $(CURDIR)\ninclude $(FPGA_DIR)/design.mk\ninclude $(FPGA_FLOW_DIR)/mk/flow.mk\n' > "$PM/Makefile"
    t_check_fail flow_mk.graph.include_guard.mutation \
        "with the guard testing a name nothing sets, the second include overrides every recipe and the assertion goes red" \
        double_include_is_quiet "$PM"
else
    t_skip flow_mk.graph.include_guard.mutation "could not plant the fault: mk/flow.mk has no line exactly 'ifndef FPGA_FLOW_MK_INCLUDED', and this proof is measuring nothing until it is re-aimed"
fi

t_check flow_mk.graph.shell "SHELL is /bin/bash - the recipes are written in it" shell_is_bash "$P_FULL"
M="$(t_mutant "$SB" shell)"
if t_plant "$M" mk/flow.mk 'SHELL := /bin/bash' 'SHELL := /bin/sh'; then
    PM="$(full_for "$M" shell)"
    t_check_fail flow_mk.graph.shell.mutation "with SHELL set to /bin/sh the assertion goes red" shell_is_bash "$PM"
else
    t_skip flow_mk.graph.shell.mutation "could not plant the fault: mk/flow.mk has no line exactly 'SHELL := /bin/bash', and this proof is measuring nothing until it is re-aimed"
fi

t_check flow_mk.graph.no_path_targets "no rule target in the engine is a path expanded at parse time" \
    no_path_targets "$P_FULL"
# The planted rule replaces a COMMENT line that sits above BUILD_DIR's
# default, so that at the moment make reads it BUILD_DIR is empty and the
# target is /gen/planted.tcl - the founding defect, at the same address.
M="$(t_mutant "$SB" path-target)"
if t_plant "$M" mk/flow.mk '# 2. THE RUN NAMESPACE, AND THE GUARDS ON THE PATHS THAT GET DELETED' '$(BUILD_DIR)/gen/planted.tcl: ; @true'; then
    PM="$(full_for "$M" path-target)"
    t_check_fail flow_mk.graph.no_path_targets.mutation \
        "with a \$(BUILD_DIR)/gen/ rule planted above BUILD_DIR's default, a target appears at /gen/ and the assertion goes red" \
        no_path_targets "$PM"
else
    t_skip flow_mk.graph.no_path_targets.mutation "could not plant the fault: the section-2 heading comment in mk/flow.mk has been reworded, so there is no line above BUILD_DIR's default to replace, and this proof is measuring nothing until it is re-aimed"
fi

#=============================================================================
# 2. THE VARIABLE SURFACE - CONTRACT.md SECTION 3.3, READ OUT OF THE CONTRACT
#
# Three things about every `NAME ?= VALUE` the contract declares: the engine
# DECLARES it with `?=`; its DEFAULT resolves to what the contract says; a
# project's value WINS over the default; and it REACHES the recipe environment
# under FPGA_NAME. The names are parsed from section 3.3's fenced blocks, so
# a variable added to the contract and not to the engine goes red here, and
# a list spelled in this file could not have said so.
#=============================================================================
t_head "CONTRACT.md section 3.3: declared, defaulted, overridable, exported"

## contract_defaults <flow dir> -> "NAME<tab>VALUE" per section 3.3 line
contract_defaults() {
    awk '/^### 3\.3/{s=1} /^### 3\.4/{s=0}
         s && /^```/ {f=!f; next}
         s && f && /^[A-Z_][A-Z0-9_]* *\?=/ {
             name=$0; sub(/ *\?=.*/, "", name)
             val=$0; sub(/^[A-Z_][A-Z0-9_]* *\?= */, "", val); sub(/ *#.*$/, "", val); sub(/ *$/, "", val)
             printf "%s\t%s\n", name, val }' "$1/CONTRACT.md"
}
N_CONTRACT="$(contract_defaults "$FLOW_DIR" | grep -c .)"

## env_name <NAME> -> the environment variable the Tcl layer reads it as.
## FPGA_<NAME>, unless the name already carries the prefix. TCLSH is the one
## exception the engine makes: it is exported bare, because its consumer is
## scripts/fpga-flow-part-probe (line 72, `TCLSH="${TCLSH:-tclsh}"`) and no
## Tcl stage reads it. Written here rather than derived, with that reason.
env_name() {
    case "$1" in FPGA_*|TCLSH) printf '%s' "$1" ;; *) printf 'FPGA_%s' "$1" ;; esac
}

## sentinel_for <NAME> -> a value no default could produce. BUILD_DIR must be
## absolute or the parse is refused (t_contract owns that guard), and
## FLOW_MODE accepts exactly one value (t_contract owns that one too).
sentinel_for() {
    case "$1" in
        BUILD_DIR) printf '/sentinel_%s' "$1" ;;
        FLOW_MODE) printf 'direct' ;;
        *)         printf 'sentinel_%s' "$1" ;;
    esac
}

## sentinel_lines -> a design.mk assignment per section 3.3 name
sentinel_lines() {
    contract_defaults "$FLOW_DIR" | cut -f1 | while IFS= read -r n; do
        printf '%s := %s\n' "$n" "$(sentinel_for "$n")"
    done
}

## contract_declared <flow dir> - every section 3.3 name is a `?=` in mk/flow.mk
contract_declared() {
    local n bad=""
    while IFS= read -r n; do
        grep -qE "^$n *\?=" "$1/mk/flow.mk" || bad="$bad $n"
    done < <(contract_defaults "$1" | cut -f1)
    [ -z "$bad" ] && return 0
    printf 'CONTRACT.md section 3.3 declares these and mk/flow.mk has no ?= for them:%s\n' "$bad"
    return 1
}

## contract_defaults_hold <project> <flow dir> - each default resolves to what
## the contract's expression resolves to IN THE SAME PROJECT. Paths compare
## resolved (PROJECT_ROOT is written $(FPGA_DIR)/.. in the contract and
## $(abspath ...) in the engine, and those are one place); scalars compare
## as written. PART is set in this fixture so PART_DIR is comparable - see
## flow_mk.vars.part_dir for the documented deviation when it is not.
contract_defaults_hold() {
    local proj="$1" flow="$2" lines=() n v out bad=""
    while IFS=$'\t' read -r n v; do
        case "$v" in
            */*) lines+=("@printf '%s|%s|%s\\n' '$n' \"\$(abspath $v)\" \"\$(abspath \$($n))\"") ;;
            *)   lines+=("@printf '%s|%s|%s\\n' '$n' \"$v\" \"\$($n)\"") ;;
        esac
    done < <(contract_defaults "$flow")
    out="$(mk_probe "$proj" "${lines[@]}")"
    while IFS='|' read -r n want got; do
        [ "$want" = "$got" ] || bad="$bad"$'\n'"  $n: contract says '$want', engine resolves '$got'"
    done <<< "$out"
    [ -z "$bad" ] && return 0
    printf 'defaults that do not resolve to what CONTRACT.md section 3.3 says:%s\n' "$bad"
    return 1
}

## surface_probe <project> <flow dir> -> "NAME|make value|env value" per name
surface_probe() {
    local lines=() n
    while IFS= read -r n; do
        lines+=("@printf '%s|%s|%s\\n' '$n' \"\$($n)\" \"\$\$$(env_name "$n")\"")
    done < <(contract_defaults "$2" | cut -f1)
    mk_probe "$1" "${lines[@]}"
}

## project_wins <project> <flow dir> - the design.mk sentinel is the make value
project_wins() {
    local n mk env bad="" seen=0
    while IFS='|' read -r n mk env; do
        seen=$((seen+1))
        [ "$mk" = "$(sentinel_for "$n")" ] || bad="$bad $n='$mk'"
    done < <(surface_probe "$1" "$2")
    [ "$seen" -gt 0 ] || { printf 'the probe printed nothing\n'; return 1; }
    [ -z "$bad" ] && return 0
    printf 'names whose engine default beat the project value:%s\n' "$bad"
    return 1
}

## reaches_env <project> <flow dir> - the sentinel is in the recipe environment
reaches_env() {
    local n mk env bad="" seen=0
    while IFS='|' read -r n mk env; do
        seen=$((seen+1))
        [ "$env" = "$(sentinel_for "$n")" ] || bad="$bad $(env_name "$n")='$env'"
    done < <(surface_probe "$1" "$2")
    [ "$seen" -gt 0 ] || { printf 'the probe printed nothing\n'; return 1; }
    [ -z "$bad" ] && return 0
    printf 'names the Tcl layer would not receive, or would receive wrong:%s\n' "$bad"
    return 1
}

if [ "$N_CONTRACT" -eq 0 ]; then
    for id in contract_declared contract_defaults project_wins reaches_env; do
        t_skip "flow_mk.vars.$id" "CONTRACT.md section 3.3 has no fenced '?=' lines in this checkout, so the variable surface could not be read from the specification - nothing here ran"
    done
else
    t_say "$N_CONTRACT names read from CONTRACT.md section 3.3"

    t_check flow_mk.vars.contract_declared \
        "every section 3.3 name is declared with ?= in mk/flow.mk" \
        contract_declared "$FLOW_DIR"
    M="$(t_mutant "$SB" undeclared)"
    if t_mutate "$M" mk/flow.mk '/^XDC_DRC  *?=/d'; then
        t_check_fail flow_mk.vars.contract_declared.mutation \
            "with XDC_DRC's ?= deleted from a copy, the assertion goes red" \
            contract_declared "$M"
    else
        t_skip flow_mk.vars.contract_declared.mutation "could not plant the fault: mk/flow.mk has no 'XDC_DRC ?=' line to delete, and this proof is measuring nothing until it is re-aimed"
    fi

    P_DEF="$(proj_for "$FLOW_DIR" defaults "PART := $PACK")"
    t_check flow_mk.vars.contract_defaults \
        "every section 3.3 default resolves to what the contract's expression resolves to" \
        contract_defaults_hold "$P_DEF" "$FLOW_DIR"
    M="$(t_mutant "$SB" default-scalar)"
    if t_plant "$M" mk/flow.mk 'IP_VENDOR       ?= soclabs.org' 'IP_VENDOR       ?= example.org'; then
        PM="$(proj_for "$M" default-scalar "PART := $PACK")"
        t_check_fail flow_mk.vars.contract_defaults.mutation \
            "with IP_VENDOR's default changed in a copy, the assertion goes red" \
            contract_defaults_hold "$PM" "$M"
    else
        t_skip flow_mk.vars.contract_defaults.mutation "could not plant the fault: mk/flow.mk has no line exactly 'IP_VENDOR       ?= soclabs.org', and this proof is measuring nothing until it is re-aimed"
    fi
    M="$(t_mutant "$SB" default-path)"
    if t_plant "$M" mk/flow.mk 'HOOKS_DIR       ?= $(FPGA_DIR)/hooks' 'HOOKS_DIR       ?= $(FPGA_DIR)/hook'; then
        PM="$(proj_for "$M" default-path "PART := $PACK")"
        t_check_fail flow_mk.vars.contract_defaults.path.mutation \
            "with HOOKS_DIR's path default changed by one letter, the resolved-path comparison goes red" \
            contract_defaults_hold "$PM" "$M"
    else
        t_skip flow_mk.vars.contract_defaults.path.mutation "could not plant the fault: mk/flow.mk has no line exactly 'HOOKS_DIR       ?= \$(FPGA_DIR)/hooks', and this proof is measuring nothing until it is re-aimed"
    fi

    P_SENT="$(proj_for "$FLOW_DIR" sentinel "$(sentinel_lines)")"
    t_check flow_mk.vars.project_wins \
        "a project value in design.mk wins over the engine default, for every section 3.3 name" \
        project_wins "$P_SENT" "$FLOW_DIR"
    M="$(t_mutant "$SB" clobber)"
    if t_plant "$M" mk/flow.mk 'IP_VENDOR       ?= soclabs.org' 'IP_VENDOR       := soclabs.org'; then
        PM="$(proj_for "$M" clobber "$(sentinel_lines)")"
        t_check_fail flow_mk.vars.project_wins.mutation \
            "with one ?= made :=, the engine clobbers the project's IP_VENDOR and the assertion goes red" \
            project_wins "$PM" "$M"
    else
        t_skip flow_mk.vars.project_wins.mutation "could not plant the fault: mk/flow.mk has no line exactly 'IP_VENDOR       ?= soclabs.org', and this proof is measuring nothing until it is re-aimed"
    fi
    M="$(t_mutant "$SB" override-default)"
    if t_plant "$M" mk/flow.mk 'PLATFORM        ?= bare' 'override PLATFORM := bare'; then
        PM="$(proj_for "$M" override-default "$(sentinel_lines)")"
        t_check_fail flow_mk.vars.project_wins.override.mutation \
            "with PLATFORM's default made an override, no project can set it and the assertion goes red" \
            project_wins "$PM" "$M"
    else
        t_skip flow_mk.vars.project_wins.override.mutation "could not plant the fault: mk/flow.mk has no line exactly 'PLATFORM        ?= bare', and this proof is measuring nothing until it is re-aimed"
    fi

    t_check flow_mk.vars.reaches_env \
        "every section 3.3 name reaches the recipe environment as FPGA_<name>, with the project's value" \
        reaches_env "$P_SENT" "$FLOW_DIR"
    M="$(t_mutant "$SB" export-deleted)"
    if t_mutate "$M" mk/flow.mk '/^export FPGA_XDC_DRC  *= \$(XDC_DRC)$/d'; then
        PM="$(proj_for "$M" export-deleted "$(sentinel_lines)")"
        t_check_fail flow_mk.vars.reaches_env.mutation \
            "with FPGA_XDC_DRC's export deleted, the stage never sees the DRC file and the assertion goes red" \
            reaches_env "$PM" "$M"
    else
        t_skip flow_mk.vars.reaches_env.mutation "could not plant the fault: mk/flow.mk has no 'export FPGA_XDC_DRC = \$(XDC_DRC)' line to delete, and this proof is measuring nothing until it is re-aimed"
    fi
    M="$(t_mutant "$SB" export-keyword)"
    if t_plant "$M" mk/flow.mk 'export FPGA_NUM_JOBS         = $(NUM_JOBS)' 'FPGA_NUM_JOBS         = $(NUM_JOBS)'; then
        PM="$(proj_for "$M" export-keyword "$(sentinel_lines)")"
        t_check_fail flow_mk.vars.reaches_env.keyword.mutation \
            "with the word export dropped from one line, the make variable exists and the environment lacks it, and the assertion goes red" \
            reaches_env "$PM" "$M"
    else
        t_skip flow_mk.vars.reaches_env.keyword.mutation "could not plant the fault: mk/flow.mk has no line exactly 'export FPGA_NUM_JOBS         = \$(NUM_JOBS)', and this proof is measuring nothing until it is re-aimed"
    fi
fi

#-----------------------------------------------------------------------------
# 2.2 THE EXPORT SET IS DEFERRED - THE FIRST OF THE THREE FOUNDING DEFECTS
#
# `export FPGA_X = $(X)` is expanded when make builds a recipe's environment,
# after every include has been read. `export FPGA_X := $(X)` is expanded where
# it stands, ~250 lines before the sibling fragments are included and before
# anything a project assigns after its own `include mk/flow.mk`. With `:=`,
# `make env` reads the MAKE variable and prints the project's value, while the
# Tcl layer reads the EXPORTED copy and gets the engine default. Measured
# 2026-09-08 on MSG_GATE_ALLOWLIST: {Project 1-1924} in the report, (none) in
# the manifest of the same run.
#
# The pairs are grepped out of mk/flow.mk - every `export FPGA_X = $(Y)` and
# every `export FPGA_X := $(Y)` alike, so a line that regressed to `:=` stays
# in the set instead of dropping out of it. Each Y is assigned AFTER the
# include, and the recipe environment must carry that value.
#-----------------------------------------------------------------------------
t_head "every export FPGA_X = \$(Y) is deferred: a value assigned after the include reaches the environment"

## export_pairs <flow dir> -> "X<tab>Y" per export line
export_pairs() {
    sed -nE 's/^export (FPGA_[A-Z0-9_]+) *:?= *\$\(([A-Z0-9_]+)\) *$/\1\t\2/p' "$1/mk/flow.mk"
}

## late_value <Y> - assigned after the include. BUILD_DIR must stay absolute.
late_value() { case "$1" in BUILD_DIR) printf '/late_%s' "$1" ;; *) printf 'late_%s' "$1" ;; esac; }

## exports_deferred <project> <flow dir>
exports_deferred() {
    local lines=() x y out mk env bad="" seen=0
    while IFS=$'\t' read -r x y; do
        lines+=("@printf '%s|%s|%s\\n' '$x' \"\$($y)\" \"\$\$$x\"")
    done < <(export_pairs "$2")
    [ "${#lines[@]}" -gt 0 ] || { printf 'no export FPGA_X = $(Y) lines found in mk/flow.mk\n'; return 1; }
    out="$(mk_probe "$1" "${lines[@]}")"
    while IFS='|' read -r x mk env; do
        seen=$((seen+1))
        [ "$mk" = "$env" ] || bad="$bad"$'\n'"  $x: make has '$mk', the environment has '$env'"
    done <<< "$out"
    [ "$seen" -gt 0 ] || { printf 'the probe printed nothing:\n%s\n' "$out"; return 1; }
    [ -z "$bad" ] && return 0
    printf 'exports that snapshotted before the project finished assigning:%s\n' "$bad"
    return 1
}

## late_project <flow dir> <name> -> a project assigning every Y after the include
late_project() {
    # `asgn`, not `lines`: every other helper here uses `lines` as an ARRAY of
    # recipe lines, and a same-named string in one function is how somebody
    # later copies the wrong idiom out of this file.
    local d asgn="" y
    d="$(proj_for "$1" "$2")" || return 2
    while IFS=$'\t' read -r _ y; do asgn="$asgn$y := $(late_value "$y")"$'\n'; done < <(export_pairs "$1")
    late_lines "$d" "$asgn"
    printf '%s' "$d"
}

N_PAIRS="$(export_pairs "$FLOW_DIR" | grep -c .)"
t_say "$N_PAIRS export pairs read from mk/flow.mk"
P_LATE="$(late_project "$FLOW_DIR" late)"
t_check flow_mk.vars.export_deferred \
    "for every export FPGA_X = \$(Y), a Y assigned after the include is what the environment carries" \
    exports_deferred "$P_LATE" "$FLOW_DIR"
M="$(t_mutant "$SB" export-snapshot)"
if t_plant "$M" mk/flow.mk 'export FPGA_MSG_GATE_ALLOWLIST  = $(MSG_GATE_ALLOWLIST)' 'export FPGA_MSG_GATE_ALLOWLIST  := $(MSG_GATE_ALLOWLIST)'; then
    PM="$(late_project "$M" export-snapshot)"
    t_check_fail flow_mk.vars.export_deferred.mutation \
        "with MSG_GATE_ALLOWLIST's export made := - the 2026-09-08 defect - make and the environment disagree and the assertion goes red" \
        exports_deferred "$PM" "$M"
else
    t_skip flow_mk.vars.export_deferred.mutation "could not plant the fault: mk/flow.mk has no line exactly 'export FPGA_MSG_GATE_ALLOWLIST  = \$(MSG_GATE_ALLOWLIST)', and this proof is measuring nothing until it is re-aimed"
fi
M="$(t_mutant "$SB" export-post-snapshot)"
if t_plant "$M" mk/flow.mk 'export FPGA_BITSTREAM_POST_TARGETS  = $(BITSTREAM_POST_TARGETS)' 'export FPGA_BITSTREAM_POST_TARGETS  := $(BITSTREAM_POST_TARGETS)'; then
    PM="$(late_project "$M" export-post-snapshot)"
    t_check_fail flow_mk.vars.export_deferred.post.mutation \
        "with the bitstream post-target export made := - the deploy tier's instance - a fragment's append never reaches the manifest and the assertion goes red" \
        exports_deferred "$PM" "$M"
else
    t_skip flow_mk.vars.export_deferred.post.mutation "could not plant the fault: mk/flow.mk has no line exactly 'export FPGA_BITSTREAM_POST_TARGETS  = \$(BITSTREAM_POST_TARGETS)', and this proof is measuring nothing until it is re-aimed"
fi

#-----------------------------------------------------------------------------
# 2.3 THE POST-TARGET CENSUS SEES A VARIABLE DEFINED AFTER THE INCLUDE
#
# FPGA_POST_TARGET_VARS is every *_POST_TARGETS in $(.VARIABLES), exported so
# that a MISSPELT one - BITSTREM_POST_TARGETS, ROUTE_POST_TARGETS carried over
# from the ASIC toolkit - is a name something can report, instead of a
# variable nothing reads and a deploy that never ran. Deferred for the same
# reason as the exports above: evaluated where it stands it could not contain
# a name a fragment defines.
#
# The second assertion is the CONSUMER, and it is a KNOWN DEFECT. mk/flow.mk
# section 6 says the census makes a seventh name "visible to `make check`",
# and section 7 says the six are declared "so that $(.VARIABLES) always shows
# exactly six". Neither is true today: scripts/fpga-flow-check never reads
# FPGA_POST_TARGET_VARS (grep finds no consumer outside `make env`'s last
# line), and the census also carries the six FPGA_*_POST_TARGETS exports, so
# it lists twelve names plus the typo. `make check` reports `Contract
# complete.` on a project whose deploy hook is spelled BITSTREM_. The marker
# goes red the day the checker starts naming it.
#-----------------------------------------------------------------------------
t_head "a misspelt *_POST_TARGETS defined after the include is in the census"

## census_has <project> <name> - in the recipe environment's census
census_has() {
    local got; got="$(mk_expand "$1" '$$FPGA_POST_TARGET_VARS')"
    case " $got " in *" $2 "*) return 0 ;; esac
    printf 'FPGA_POST_TARGET_VARS lacks %s: %s\n' "$2" "$got"
    return 1
}

## check_names <project> <name> - `make check` mentions the name
check_names() { make -C "$1" --no-print-directory check 2>&1 | grep -qF -- "$2"; }

P_TYPO="$(proj_for "$FLOW_DIR" typo)"
late_lines "$P_TYPO" 'BITSTREM_POST_TARGETS := deploy'
t_check flow_mk.vars.post_census \
    "BITSTREM_POST_TARGETS, defined after the include, is in FPGA_POST_TARGET_VARS" \
    census_has "$P_TYPO" BITSTREM_POST_TARGETS
M="$(t_mutant "$SB" census-snapshot)"
if t_plant "$M" mk/flow.mk 'export FPGA_POST_TARGET_VARS = $(sort $(filter %_POST_TARGETS,$(.VARIABLES)))' 'export FPGA_POST_TARGET_VARS := $(sort $(filter %_POST_TARGETS,$(.VARIABLES)))'; then
    PM="$(proj_for "$M" census-snapshot)"
    late_lines "$PM" 'BITSTREM_POST_TARGETS := deploy'
    t_check_fail flow_mk.vars.post_census.mutation \
        "with the census made :=, a name defined after it is invisible and the assertion goes red" \
        census_has "$PM" BITSTREM_POST_TARGETS
else
    t_skip flow_mk.vars.post_census.mutation "could not plant the fault: mk/flow.mk has no line exactly 'export FPGA_POST_TARGET_VARS = \$(sort ...)', and this proof is measuring nothing until it is re-aimed"
fi

if [ -n "$CHECKER_REASON" ]; then
    t_skip flow_mk.vars.post_census.checked "$CHECKER_REASON - so whether make check names a misspelt post-target variable was not measured"
else
    P_TYPO_FULL="$(full_for "$FLOW_DIR" typo)"
    late_lines "$P_TYPO_FULL" 'BITSTREM_POST_TARGETS := deploy'
    t_known_defect flow_mk.vars.post_census.checked \
        "make check names a misspelt *_POST_TARGETS variable - mk/flow.mk section 6 says the census exists for exactly this, and nothing reads it" \
        check_names "$P_TYPO_FULL" BITSTREM_POST_TARGETS
fi

#-----------------------------------------------------------------------------
# 2.4 THE TWO ALIASES, AND THAT THE CANONICAL NAME WINS
#-----------------------------------------------------------------------------
t_head "FLIST and TOP_LEVEL_HDL are absorbed, recorded, and lose to the canonical name"

## alias_absorbed <project> <canonical> <alias> <expected value>
alias_absorbed() {
    local got used env
    got="$(mk_expand "$1" "\$($2)")"
    used="$(mk_expand "$1" '$(FPGA_ALIASES_USED)')"
    env="$(mk_expand "$1" '$$FPGA_ALIASES_USED')"
    [ "$got" = "$4" ] || { printf '%s is %s, not the %s value %s\n' "$2" "$got" "$3" "$4"; return 1; }
    case " $used " in *" $2=$3 "*) ;; *) printf 'FPGA_ALIASES_USED does not record %s=%s: %s\n' "$2" "$3" "$used"; return 1 ;; esac
    [ "$env" = "$used" ] || { printf 'the exported FPGA_ALIASES_USED (%s) differs from the make one (%s)\n' "$env" "$used"; return 1; }
    return 0
}

## canonical_wins <project> <canonical> <alias> <canonical value>
canonical_wins() {
    local got used
    got="$(mk_expand "$1" "\$($2)")"
    used="$(mk_expand "$1" '$(FPGA_ALIASES_USED)')"
    [ "$got" = "$4" ] || { printf '%s is %s - the alias %s clobbered the canonical value %s\n' "$2" "$got" "$3" "$4"; return 1; }
    case " $used " in *" $2=$3 "*) printf 'FPGA_ALIASES_USED claims %s=%s although the canonical name was set\n' "$2" "$3"; return 1 ;; esac
    return 0
}

P_ALIAS="$(proj_for "$FLOW_DIR" alias 'FLIST := /alias/design.flist
TOP_LEVEL_HDL := /alias/top.v')"
t_check flow_mk.vars.alias.flist "FLIST is absorbed as RTL_FLIST and recorded in FPGA_ALIASES_USED, in make and in the environment" \
    alias_absorbed "$P_ALIAS" RTL_FLIST FLIST /alias/design.flist
M="$(t_mutant "$SB" alias-flist)"
if t_plant "$M" mk/flow.mk 'RTL_FLIST := $(FLIST)' 'RTL_FLIST :='; then
    PM="$(proj_for "$M" alias-flist 'FLIST := /alias/design.flist
TOP_LEVEL_HDL := /alias/top.v')"
    t_check_fail flow_mk.vars.alias.flist.mutation "with the absorption emptied, RTL_FLIST stays empty and the assertion goes red" \
        alias_absorbed "$PM" RTL_FLIST FLIST /alias/design.flist
else
    t_skip flow_mk.vars.alias.flist.mutation "could not plant the fault: mk/flow.mk has no line exactly 'RTL_FLIST := \$(FLIST)', and this proof is measuring nothing until it is re-aimed"
fi

t_check flow_mk.vars.alias.top_hdl "TOP_LEVEL_HDL is absorbed as TOP_HDL and recorded" \
    alias_absorbed "$P_ALIAS" TOP_HDL TOP_LEVEL_HDL /alias/top.v
M="$(t_mutant "$SB" alias-top)"
if t_plant "$M" mk/flow.mk 'TOP_HDL := $(TOP_LEVEL_HDL)' 'TOP_HDL :='; then
    PM="$(proj_for "$M" alias-top 'FLIST := /alias/design.flist
TOP_LEVEL_HDL := /alias/top.v')"
    t_check_fail flow_mk.vars.alias.top_hdl.mutation "with the absorption emptied, TOP_HDL stays empty and the assertion goes red" \
        alias_absorbed "$PM" TOP_HDL TOP_LEVEL_HDL /alias/top.v
else
    t_skip flow_mk.vars.alias.top_hdl.mutation "could not plant the fault: mk/flow.mk has no line exactly 'TOP_HDL := \$(TOP_LEVEL_HDL)', and this proof is measuring nothing until it is re-aimed"
fi

P_BOTH="$(proj_for "$FLOW_DIR" alias-both 'RTL_FLIST := /canonical/design.flist
FLIST := /alias/design.flist')"
t_check flow_mk.vars.alias.canonical_wins "with both spelled, RTL_FLIST keeps the canonical value and no alias is recorded" \
    canonical_wins "$P_BOTH" RTL_FLIST FLIST /canonical/design.flist
M="$(t_mutant "$SB" alias-clobber)"
if t_plant "$M" mk/flow.mk 'ifeq ($(strip $(RTL_FLIST)),)' 'ifeq (alias-always-wins-by-mutation,alias-always-wins-by-mutation)'; then
    PM="$(proj_for "$M" alias-clobber 'RTL_FLIST := /canonical/design.flist
FLIST := /alias/design.flist')"
    t_check_fail flow_mk.vars.alias.canonical_wins.mutation "with the guard always true, the alias clobbers the canonical value and the assertion goes red" \
        canonical_wins "$PM" RTL_FLIST FLIST /canonical/design.flist
else
    t_skip flow_mk.vars.alias.canonical_wins.mutation "could not plant the fault: mk/flow.mk has no line exactly 'ifeq (\$(strip \$(RTL_FLIST)),)', and this proof is measuring nothing until it is re-aimed"
fi

#-----------------------------------------------------------------------------
# 2.5 TWO DEFAULTS THAT MUST NOT RESOLVE TO SOMETHING PLAUSIBLE
#
# PART_DIR: CONTRACT.md section 3.3 writes it `$(FPGA_FLOW_DIR)/part/$(PART)`
# unconditionally, and mk/flow.mk DEVIATES on purpose - with PART empty that
# expands to part/, a directory that exists, holds every pack, and is not one.
# The engine keeps PART_DIR empty until PART is known. The contract's own
# spelling is the planted fault, which is a statement about which of the two
# documents is stale.
#
# FPGAHUB_TOML: the section 3.3 corollary, binding on every future default. A
# conventional path is DISCOVERED with $(wildcard), never asserted, or an
# absent optional file becomes a required input.
#-----------------------------------------------------------------------------
t_head "PART_DIR is empty until PART is known; FPGAHUB_TOML discovers rather than asserts"

## part_dir_follows_part <project> <flow dir>
part_dir_follows_part() {
    local empty withpart want
    empty="$(mk_expand "$1" '$(PART_DIR)')"
    withpart="$(mk_expand "$1" '$(PART_DIR)' PART=demo_part)"
    want="$2/part/demo_part"
    [ -z "$empty" ] || { printf 'with PART empty, PART_DIR resolved to %s - a directory that exists and is not a pack\n' "$empty"; return 1; }
    [ "$withpart" = "$want" ] || { printf 'with PART=demo_part, PART_DIR is %s, not %s\n' "$withpart" "$want"; return 1; }
    return 0
}

## toml_discovered <project> - empty when absent, the path when present
toml_discovered() {
    local absent present
    rm -f "$1/fpgahub.toml"
    absent="$(mk_expand "$1" '$(FPGAHUB_TOML)')"
    printf '# a deploy config\n' > "$1/fpgahub.toml"
    present="$(mk_expand "$1" '$(FPGAHUB_TOML)')"
    rm -f "$1/fpgahub.toml"
    [ -z "$absent" ] || { printf 'with no fpgahub.toml on disk the default names one anyway: %s\n' "$absent"; return 1; }
    [ "$present" = "$1/fpgahub.toml" ] || { printf 'with fpgahub.toml present the default is %s\n' "$present"; return 1; }
    return 0
}

t_check flow_mk.vars.part_dir "PART_DIR is empty with PART unset, and \$(FPGA_FLOW_DIR)/part/\$(PART) once PART is known" \
    part_dir_follows_part "$P_BARE" "$FLOW_DIR"
M="$(t_mutant "$SB" part-dir)"
if t_plant "$M" mk/flow.mk 'PART_DIR        ?= $(if $(strip $(PART)),$(FPGA_FLOW_DIR)/part/$(strip $(PART)),)' 'PART_DIR        ?= $(FPGA_FLOW_DIR)/part/$(PART)'; then
    PM="$(proj_for "$M" part-dir)"
    t_check_fail flow_mk.vars.part_dir.mutation \
        "with the contract's own unconditional spelling planted, an empty PART resolves to part/ and the assertion goes red" \
        part_dir_follows_part "$PM" "$M"
else
    t_skip flow_mk.vars.part_dir.mutation "could not plant the fault: the PART_DIR default in mk/flow.mk has changed shape, and this proof is measuring nothing until it is re-aimed"
fi

t_check flow_mk.vars.fpgahub_toml "FPGAHUB_TOML is empty when the file is absent and the path when it is present" \
    toml_discovered "$P_BARE"
M="$(t_mutant "$SB" toml-asserted)"
if t_plant "$M" mk/flow.mk 'FPGAHUB_TOML    ?= $(wildcard $(FPGA_DIR)/fpgahub.toml)' 'FPGAHUB_TOML    ?= $(FPGA_DIR)/fpgahub.toml'; then
    PM="$(proj_for "$M" toml-asserted)"
    t_check_fail flow_mk.vars.fpgahub_toml.mutation \
        "with the \$(wildcard) dropped, an absent file is named as if the project asked for it, and the assertion goes red" \
        toml_discovered "$PM"
else
    t_skip flow_mk.vars.fpgahub_toml.mutation "could not plant the fault: the FPGAHUB_TOML default in mk/flow.mk has changed shape, and this proof is measuring nothing until it is re-aimed"
fi

#=============================================================================
# 3. THE RUN NAMESPACE - CONTRACT.md SECTION 3.5 AND THE RESUME TAGS
#
# Seven derived values, each a pure function of BUILD_DIR and one of three
# run tags. Everything a stage reads or writes is composed from them, `rm -rf`
# is composed from two of them, and the resume idiom
#
#     make impl RUN_TAG=experiment SYNTH_RUN_TAG=main
#
# is only safe because the read-side tags default to RUN_TAG and nothing else.
#=============================================================================
t_head "the derived seven follow BUILD_DIR and the run tags, as section 3.5 writes them"

## contract_derived <flow dir> -> "NAME<tab>EXPR" per section 3.5 line
contract_derived() {
    awk '/^### 3\.5/{s=1} /^## 4\./{s=0}
         s && /^```/ {f=!f; next}
         s && f && /^[A-Z_]+ *:=/ {
             name=$0; sub(/ *:=.*/, "", name)
             val=$0; sub(/^[A-Z_]+ *:= */, "", val); sub(/ *#.*$/, "", val); sub(/ *$/, "", val)
             printf "%s\t%s\n", name, val }' "$1/CONTRACT.md"
}

## derived_as_written <project> <flow dir> [make args...] - each derived value
## equals its section 3.5 expression resolved in the same make. The expression
## references the engine's OWN inputs, so what this catches is a definition
## that stopped following them - a hardcoded root, a misspelt leaf.
derived_as_written() {
    local proj="$1" flow="$2"; shift 2
    local lines=() n v out want got bad="" seen=0
    while IFS=$'\t' read -r n v; do
        lines+=("@printf '%s|%s|%s\\n' '$n' \"$v\" \"\$($n)\"")
    done < <(contract_derived "$flow")
    [ "${#lines[@]}" -gt 0 ] || { printf 'CONTRACT.md section 3.5 has no fenced := block\n'; return 2; }
    out="$(mk_probe "$proj" "${lines[@]}" -- "$@")"
    while IFS='|' read -r n want got; do
        seen=$((seen+1))
        [ "$want" = "$got" ] || bad="$bad"$'\n'"  $n: section 3.5 resolves to '$want', the engine has '$got'"
    done <<< "$out"
    [ "$seen" -gt 0 ] || { printf 'the probe printed nothing:\n%s\n' "$out"; return 1; }
    [ -z "$bad" ] && return 0
    printf 'derived values that do not follow their inputs:%s\n' "$bad"
    return 1
}

## derived_is <project> <NAME> <expected> [make args...]
derived_is() {
    local proj="$1" n="$2" want="$3"; shift 3
    local got; got="$(mk_expand "$proj" "\$($n)" "$@")"
    [ "$got" = "$want" ] && return 0
    printf '%s is %s, expected %s\n' "$n" "$got" "$want"
    return 1
}

P_NS="$(proj_for "$FLOW_DIR" namespace "BUILD_DIR := $SB/elsewhere/builds
RUN_TAG := tagged")"
t_check flow_mk.run.derived "with BUILD_DIR and RUN_TAG from the project, all seven resolve as section 3.5 writes them" \
    derived_as_written "$P_NS" "$FLOW_DIR"
M="$(t_mutant "$SB" derived-root)"
if t_plant "$M" mk/flow.mk 'override RUN_DIR       := $(BUILD_DIR)/$(RUN_TAG)' 'override RUN_DIR       := $(FPGA_DIR)/build/$(RUN_TAG)'; then
    PM="$(proj_for "$M" derived-root "BUILD_DIR := $SB/elsewhere/builds
RUN_TAG := tagged")"
    t_check_fail flow_mk.run.derived.mutation \
        "with RUN_DIR hardcoded to the default build root, the project's BUILD_DIR is ignored and the assertion goes red" \
        derived_as_written "$PM" "$M"
else
    t_skip flow_mk.run.derived.mutation "could not plant the fault: mk/flow.mk has no line exactly 'override RUN_DIR       := \$(BUILD_DIR)/\$(RUN_TAG)', and this proof is measuring nothing until it is re-aimed"
fi
M="$(t_mutant "$SB" derived-leaf)"
if t_plant "$M" mk/flow.mk 'override OUT_DIR       := $(RUN_DIR)/outputs' 'override OUT_DIR       := $(RUN_DIR)/output'; then
    PM="$(proj_for "$M" derived-leaf "BUILD_DIR := $SB/elsewhere/builds
RUN_TAG := tagged")"
    t_check_fail flow_mk.run.derived.leaf.mutation \
        "with OUT_DIR's leaf misspelt, one of the seven diverges from the contract and the assertion goes red" \
        derived_as_written "$PM" "$M"
else
    t_skip flow_mk.run.derived.leaf.mutation "could not plant the fault: mk/flow.mk has no line exactly 'override OUT_DIR       := \$(RUN_DIR)/outputs', and this proof is measuring nothing until it is re-aimed"
fi

#-----------------------------------------------------------------------------
# 3.2 RESUME: SYNTH_RUN_TAG MOVES THE READ, IN_RUN_TAG STAYS WITH RUN_TAG
#-----------------------------------------------------------------------------
t_head "resume semantics: which run each tag addresses"

## resume_synth <project> <build dir> - RUN_TAG=experiment SYNTH_RUN_TAG=main
resume_synth() {
    local b="$2"
    derived_is "$1" SYNTH_OUT_DIR "$b/main/outputs"       RUN_TAG=experiment SYNTH_RUN_TAG=main || return 1
    derived_is "$1" OUT_DIR       "$b/experiment/outputs" RUN_TAG=experiment SYNTH_RUN_TAG=main || return 1
    derived_is "$1" IN_WORK_DIR   "$b/experiment/work"    RUN_TAG=experiment SYNTH_RUN_TAG=main || return 1
    # The value the impl stage reads (flow_utils.tcl: FPGA_SYNTH_OUT_DIR) is
    # the exported copy, so it is read from the environment as well.
    local env; env="$(mk_expand "$1" '$$FPGA_SYNTH_OUT_DIR' RUN_TAG=experiment SYNTH_RUN_TAG=main)"
    [ "$env" = "$b/main/outputs" ] && return 0
    printf 'FPGA_SYNTH_OUT_DIR in the environment is %s, not %s/main/outputs\n' "$env" "$b"
    return 1
}

## resume_in <project> <build dir> - RUN_TAG=trial IN_RUN_TAG=baseline
resume_in() {
    local b="$2"
    derived_is "$1" IN_WORK_DIR   "$b/baseline/work"  RUN_TAG=trial IN_RUN_TAG=baseline || return 1
    derived_is "$1" WORK_DIR      "$b/trial/work"     RUN_TAG=trial IN_RUN_TAG=baseline || return 1
    derived_is "$1" SYNTH_OUT_DIR "$b/trial/outputs"  RUN_TAG=trial IN_RUN_TAG=baseline || return 1
    local env; env="$(mk_expand "$1" '$$FPGA_IN_WORK_DIR' RUN_TAG=trial IN_RUN_TAG=baseline)"
    [ "$env" = "$b/baseline/work" ] && return 0
    printf 'FPGA_IN_WORK_DIR in the environment is %s, not %s/baseline/work\n' "$env" "$b"
    return 1
}

## resume_defaults <project> <build dir> - with only RUN_TAG, both read-side
## tags follow it: nothing defaults to 'default' behind a named run.
resume_defaults() {
    local b="$2"
    derived_is "$1" IN_RUN_TAG    only              RUN_TAG=only || return 1
    derived_is "$1" SYNTH_RUN_TAG only              RUN_TAG=only || return 1
    derived_is "$1" IN_WORK_DIR   "$b/only/work"    RUN_TAG=only || return 1
    derived_is "$1" SYNTH_OUT_DIR "$b/only/outputs" RUN_TAG=only
}

B_NS="$(mk_expand "$P_NS" '$(BUILD_DIR)')"
t_check flow_mk.run.resume.synth "RUN_TAG=experiment SYNTH_RUN_TAG=main reads main's outputs, writes experiment's, and IN_WORK_DIR stays with experiment" \
    resume_synth "$P_NS" "$B_NS"
M="$(t_mutant "$SB" resume-synth)"
if t_plant "$M" mk/flow.mk 'override SYNTH_OUT_DIR := $(BUILD_DIR)/$(SYNTH_RUN_TAG)/outputs' 'override SYNTH_OUT_DIR := $(RUN_DIR)/outputs'; then
    PM="$(proj_for "$M" resume-synth "BUILD_DIR := $SB/elsewhere/builds")"
    t_check_fail flow_mk.run.resume.synth.mutation \
        "with SYNTH_OUT_DIR composed from RUN_DIR, the tag is ignored and impl reads its own empty outputs - the assertion goes red" \
        resume_synth "$PM" "$B_NS"
else
    t_skip flow_mk.run.resume.synth.mutation "could not plant the fault: mk/flow.mk has no line exactly 'override SYNTH_OUT_DIR := \$(BUILD_DIR)/\$(SYNTH_RUN_TAG)/outputs', and this proof is measuring nothing until it is re-aimed"
fi
M="$(t_mutant "$SB" resume-in-follows-synth)"
if t_plant "$M" mk/flow.mk 'IN_RUN_TAG     ?= $(RUN_TAG)' 'IN_RUN_TAG     ?= $(SYNTH_RUN_TAG)'; then
    PM="$(proj_for "$M" resume-in-follows-synth "BUILD_DIR := $SB/elsewhere/builds")"
    t_check_fail flow_mk.run.resume.synth.in_tag.mutation \
        "with IN_RUN_TAG defaulting to SYNTH_RUN_TAG, a synth resume silently moves every other read too, and the assertion goes red" \
        resume_synth "$PM" "$B_NS"
else
    t_skip flow_mk.run.resume.synth.in_tag.mutation "could not plant the fault: mk/flow.mk has no line exactly 'IN_RUN_TAG     ?= \$(RUN_TAG)', and this proof is measuring nothing until it is re-aimed"
fi

t_check flow_mk.run.resume.in "RUN_TAG=trial IN_RUN_TAG=baseline reads baseline's work, writes trial's, and SYNTH_OUT_DIR stays with trial" \
    resume_in "$P_NS" "$B_NS"
M="$(t_mutant "$SB" resume-in)"
if t_plant "$M" mk/flow.mk 'override IN_WORK_DIR   := $(BUILD_DIR)/$(IN_RUN_TAG)/work' 'override IN_WORK_DIR   := $(WORK_DIR)'; then
    PM="$(proj_for "$M" resume-in "BUILD_DIR := $SB/elsewhere/builds")"
    t_check_fail flow_mk.run.resume.in.mutation \
        "with IN_WORK_DIR aliased to WORK_DIR, IN_RUN_TAG addresses nothing and the assertion goes red" \
        resume_in "$PM" "$B_NS"
else
    t_skip flow_mk.run.resume.in.mutation "could not plant the fault: mk/flow.mk has no line exactly 'override IN_WORK_DIR   := \$(BUILD_DIR)/\$(IN_RUN_TAG)/work', and this proof is measuring nothing until it is re-aimed"
fi
M="$(t_mutant "$SB" resume-synth-follows-in)"
if t_plant "$M" mk/flow.mk 'SYNTH_RUN_TAG  ?= $(RUN_TAG)' 'SYNTH_RUN_TAG  ?= $(IN_RUN_TAG)'; then
    PM="$(proj_for "$M" resume-synth-follows-in "BUILD_DIR := $SB/elsewhere/builds")"
    t_check_fail flow_mk.run.resume.in.synth_tag.mutation \
        "with SYNTH_RUN_TAG defaulting to IN_RUN_TAG, a work-dir resume silently reads another run's checkpoint, and the assertion goes red" \
        resume_in "$PM" "$B_NS"
else
    t_skip flow_mk.run.resume.in.synth_tag.mutation "could not plant the fault: mk/flow.mk has no line exactly 'SYNTH_RUN_TAG  ?= \$(RUN_TAG)', and this proof is measuring nothing until it is re-aimed"
fi

t_check flow_mk.run.resume.defaults "with only RUN_TAG set, both read-side tags follow it" \
    resume_defaults "$P_NS" "$B_NS"
M="$(t_mutant "$SB" resume-default-literal)"
if t_plant "$M" mk/flow.mk 'SYNTH_RUN_TAG  ?= $(RUN_TAG)' 'SYNTH_RUN_TAG  ?= default'; then
    PM="$(proj_for "$M" resume-default-literal "BUILD_DIR := $SB/elsewhere/builds")"
    t_check_fail flow_mk.run.resume.defaults.mutation \
        "with SYNTH_RUN_TAG defaulting to the literal 'default', every tagged run reads the default run's checkpoint and the assertion goes red" \
        resume_defaults "$PM" "$B_NS"
else
    t_skip flow_mk.run.resume.defaults.mutation "could not plant the fault: mk/flow.mk has no line exactly 'SYNTH_RUN_TAG  ?= \$(RUN_TAG)', and this proof is measuring nothing until it is re-aimed"
fi

#-----------------------------------------------------------------------------
# 3.3 THE SEVEN ARE NOT SETTABLE FROM THE COMMAND LINE, AND THE ATTEMPT IS
#     REPORTED - FOR ALL SEVEN, FROM THE LIST THE ENGINE OWNS
#
# t_contract.sh asserts this for RUN_DIR and WORK_DIR and plants the fault in
# RUN_DIR. The other five have the same `override` and no proof, and each one
# is an `rm -rf` or a stage output landing outside the run. The list is
# FPGA_DERIVED_VARS, asked of make, and it is cross-checked against section
# 3.5 first - a list that lost a name would otherwise shrink this assertion
# without a word.
#-----------------------------------------------------------------------------
t_head "all seven derived variables refuse the command line, and the census names the attempt"

## derived_list_agrees <project> <flow dir>
derived_list_agrees() {
    local a b
    a="$(mk_expand "$1" '$(FPGA_DERIVED_VARS)' | tr ' ' '\n' | grep . | sort)"
    b="$(contract_derived "$2" | cut -f1 | sort)"
    [ -n "$b" ] || { printf 'CONTRACT.md section 3.5 has no fenced := block\n'; return 2; }
    [ "$a" = "$b" ] && return 0
    printf 'FPGA_DERIVED_VARS and CONTRACT.md section 3.5 disagree:\n'
    diff <(printf '%s\n' "$b") <(printf '%s\n' "$a") | sed 's/^/  /'
    printf 'left = the contract, right = the engine list the census reads.\n'
    return 1
}

## derived_refuse_cli <project> - every name in FPGA_DERIVED_VARS, hijacked at
## once; none may take the value, and each must be named in the preset line.
derived_refuse_cli() {
    local names args=() n out bad=""
    names="$(mk_expand "$1" '$(FPGA_DERIVED_VARS)')"
    for n in $names; do args+=("$n=/hijacked/$n"); done
    out="$(make -C "$1" --no-print-directory env "${args[@]}" 2>&1)" || { printf 'make env failed:\n%s\n' "$out"; return 1; }
    for n in $names; do
        printf '%s\n' "$out" | grep -qE "^  $n +/hijacked/" && bad="$bad [$n took the command-line value]"
        printf '%s\n' "$out" | grep -qE "^  derived preset .*\b$n\[command line\]" || bad="$bad [$n not reported in the derived-preset line]"
    done
    [ -z "$bad" ] && return 0
    printf '%s\n%s\n' "$bad" "$(printf '%s\n' "$out" | grep -E '^  (derived preset|[A-Z_]+_DIR) ')"
    return 1
}

t_check flow_mk.run.derived.list "FPGA_DERIVED_VARS is exactly the seven names of CONTRACT.md section 3.5" \
    derived_list_agrees "$P_BARE" "$FLOW_DIR"
M="$(t_mutant "$SB" derived-list)"
if t_plant "$M" mk/flow.mk 'FPGA_DERIVED_VARS := RUN_DIR WORK_DIR LOG_DIR REPORT_DIR OUT_DIR IN_WORK_DIR SYNTH_OUT_DIR' 'FPGA_DERIVED_VARS := RUN_DIR WORK_DIR LOG_DIR REPORT_DIR OUT_DIR IN_WORK_DIR'; then
    PM="$(proj_for "$M" derived-list)"
    t_check_fail flow_mk.run.derived.list.mutation \
        "with SYNTH_OUT_DIR dropped from the list, the census can no longer name it and the assertion goes red" \
        derived_list_agrees "$PM" "$M"
else
    t_skip flow_mk.run.derived.list.mutation "could not plant the fault: mk/flow.mk has no line exactly 'FPGA_DERIVED_VARS := RUN_DIR ... SYNTH_OUT_DIR', and this proof is measuring nothing until it is re-aimed"
fi

t_check flow_mk.run.derived.not_settable "each of the seven, set on the command line, is discarded AND named in the derived-preset line" \
    derived_refuse_cli "$P_BARE"
# One `override` dropped per copy. RUN_DIR's proof is in t_contract.sh.
for v in WORK_DIR LOG_DIR REPORT_DIR OUT_DIR IN_WORK_DIR SYNTH_OUT_DIR; do
    line="$(grep -E "^override $v +:= " "$FLOW_DIR/mk/flow.mk" | head -1)"
    M="$(t_mutant "$SB" "settable-$v")"
    if [ -n "$line" ] && t_plant "$M" mk/flow.mk "$line" "${line#override }"; then
        PM="$(proj_for "$M" "settable-$v")"
        t_check_fail "flow_mk.run.derived.not_settable.$v.mutation" \
            "with 'override' dropped from $v, the command line wins and the assertion goes red" \
            derived_refuse_cli "$PM"
    else
        t_skip "flow_mk.run.derived.not_settable.$v.mutation" "could not plant the fault: mk/flow.mk has no 'override $v :=' line, and this proof is measuring nothing until it is re-aimed"
    fi
done

#=============================================================================
# 4. THE RECIPES THAT RUN WITHOUT A TOOL
#
# dirs, status, clean and distclean, and the post-stage macro. Each is judged
# on what it leaves on disk and what it prints; `rm -rf` is exercised only on
# paths inside this suite's own sandbox, on a BUILD_DIR make was told about.
#=============================================================================
t_head "dirs: exactly the four run directories, asserted rather than assumed"

## run_tree_is <project> <names...> - RUN_DIR holds exactly these entries
run_tree_is() {
    local proj="$1"; shift
    local run got want
    run="$(mk_expand "$proj" '$(RUN_DIR)')"
    got="$(ls -A "$run" 2>/dev/null | sort | tr '\n' ' ')"
    want="$(printf '%s\n' "$@" | sort | tr '\n' ' ')"
    [ "$got" = "$want" ] && return 0
    printf '%s holds: %s\nexpected exactly: %s\n' "$run" "${got:-(nothing)}" "$want"
    return 1
}

## dirs_makes_four <project>
dirs_makes_four() {
    local run; run="$(mk_expand "$1" '$(RUN_DIR)')"
    rm -rf "$run"
    make -C "$1" --no-print-directory dirs >/dev/null 2>&1
    run_tree_is "$1" work logs reports outputs
}

## dirs_refuses_a_file <project> - a FILE where work/ should be
dirs_refuses_a_file() {
    local run out rc=0
    run="$(mk_expand "$1" '$(RUN_DIR)')"
    rm -rf "$run"; mkdir -p "$run"; printf 'in the way\n' > "$run/work"
    out="$(make -C "$1" --no-print-directory dirs 2>&1)" || rc=$?
    rm -rf "$run"
    [ "$rc" -ne 0 ] || { printf 'make dirs exited 0 with a file at %s/work:\n%s\n' "$run" "$out"; return 1; }
    printf '%s\n' "$out" | grep -qiE 'File exists|could not create' && return 0
    printf 'make dirs failed, but not for the file in the way:\n%s\n' "$out"
    return 1
}

if [ -n "$CHECKER_REASON" ]; then
    for id in dirs.four dirs.four.mutation dirs.four.extra.mutation dirs.file_in_the_way; do
        t_skip "flow_mk.recipe.$id" "$CHECKER_REASON - dirs cannot run for real here, and a directory nobody made is not a passing one"
    done
else
    P_DIRS="$(full_for "$FLOW_DIR" dirs)"
    t_check flow_mk.recipe.dirs.four "make dirs leaves exactly work, logs, reports and outputs under RUN_DIR" \
        dirs_makes_four "$P_DIRS"
    M="$(t_mutant "$SB" dirs-three)"
    if t_plant "$M" mk/flow.mk "$T"'@mkdir -p "$(WORK_DIR)" "$(LOG_DIR)" "$(REPORT_DIR)" "$(OUT_DIR)"' "$T"'@mkdir -p "$(WORK_DIR)" "$(LOG_DIR)" "$(REPORT_DIR)"'; then
        PM="$(full_for "$M" dirs-three)"
        t_check_fail flow_mk.recipe.dirs.four.mutation \
            "with outputs/ dropped from the mkdir, the run tree is short one directory and the assertion goes red" \
            dirs_makes_four "$PM"
    else
        t_skip flow_mk.recipe.dirs.four.mutation "could not plant the fault: dirs' mkdir line in mk/flow.mk has changed shape, and this proof is measuring nothing until it is re-aimed"
    fi
    M="$(t_mutant "$SB" dirs-five)"
    if t_plant "$M" mk/flow.mk "$T"'@mkdir -p "$(WORK_DIR)" "$(LOG_DIR)" "$(REPORT_DIR)" "$(OUT_DIR)"' "$T"'@mkdir -p "$(WORK_DIR)" "$(LOG_DIR)" "$(REPORT_DIR)" "$(OUT_DIR)" "$(RUN_DIR)/scratch"'; then
        PM="$(full_for "$M" dirs-five)"
        t_check_fail flow_mk.recipe.dirs.four.extra.mutation \
            "with a fifth directory added, 'and only those four' stops being true and the assertion goes red" \
            dirs_makes_four "$PM"
    else
        t_skip flow_mk.recipe.dirs.four.extra.mutation "could not plant the fault: dirs' mkdir line in mk/flow.mk has changed shape, and this proof is measuring nothing until it is re-aimed"
    fi

    t_check flow_mk.recipe.dirs.file_in_the_way "a file where work/ should be makes dirs fail, and the failure names it" \
        dirs_refuses_a_file "$P_DIRS"
    # UNPLANTABLE WITH ONE FAULT, and the reason is worth recording rather
    # than faking. The refusal is defended twice: GNU mkdir -p itself exits 1
    # on a non-directory in the way ("File exists"), and the recipe's own
    # `test -d` loop stands behind it. Neutering the loop leaves mkdir's
    # refusal; ignoring mkdir's status leaves the loop. The loop's own case
    # is a read-only mount that swallows the request, which this suite cannot
    # plant. Note that mk/flow.mk's comment says mkdir -p "exits 0 when the
    # path already exists as a file" - measured here, it does not.
    t_skip flow_mk.recipe.dirs.file_in_the_way.mutation "the refusal is defended twice (mkdir -p exits 1 on a file in the way, and the recipe's test -d loop behind it), so no single planted fault makes dirs accept the file; the loop's own case is a read-only mount, which this suite cannot plant"
fi

#-----------------------------------------------------------------------------
# 4.2 status READS THE DISK, NOT WHAT THE FLOW REMEMBERS
#-----------------------------------------------------------------------------
t_head "status: rows from the artefacts on disk, OFF lines for the conditional stages"

## status_rows <project> - plant three artefacts, read the table
status_rows() {
    local run out bad=""
    run="$(mk_expand "$1" '$(RUN_DIR)')"
    rm -rf "$run"; mkdir -p "$run/work" "$run/outputs" "$run/reports"
    printf 'x\n' > "$run/outputs/demo_block_synth.dcp"
    printf 'x\n' > "$run/work/sources.tcl"
    printf 'HARD FAILURES: none\n' > "$run/reports/impl_gate.txt"
    out="$(make -C "$1" --no-print-directory status 2>&1)"
    printf '%s\n' "$out" | grep -qE "^  synth +yes +$run/outputs/demo_block_synth\.dcp\$" || bad="$bad [synth not yes]"
    printf '%s\n' "$out" | grep -qE "^  flist +yes +$run/work/sources\.tcl\$"            || bad="$bad [flist not yes]"
    printf '%s\n' "$out" | grep -qE "^  impl-gate +yes +$run/reports/impl_gate\.txt\$"    || bad="$bad [impl-gate not yes]"
    printf '%s\n' "$out" | grep -qE "^  impl +-- +$run/outputs/demo_block_routed\.dcp\$"  || bad="$bad [impl not --]"
    printf '%s\n' "$out" | grep -qE "^  bit +-- +$run/outputs/demo_block\.bit\$"          || bad="$bad [bit not --]"
    printf '%s\n' "$out" | grep -qF 'impl gate: HARD FAILURES: none'                       || bad="$bad [no impl gate line]"
    [ -z "$bad" ] && return 0
    printf 'status misread the disk:%s\n%s\n' "$bad" "$out"
    return 1
}

## status_off_lines <project> - the conditional stages say OFF when unconfigured
status_off_lines() {
    local out bad=""
    out="$(make -C "$1" --no-print-directory status 2>&1)"
    printf '%s\n' "$out" | grep -qF 'package-ip is OFF for this design (PACKAGE_TCL is empty)' || bad="$bad [no package-ip OFF line]"
    printf '%s\n' "$out" | grep -qF 'bd is OFF for this design (BD_TCL is empty)'             || bad="$bad [no bd OFF line]"
    [ -z "$bad" ] && return 0
    printf '%s\n%s\n' "$bad" "$out"
    return 1
}

P_ST="$(proj_for "$FLOW_DIR" status)"
t_check flow_mk.recipe.status.rows "status says yes for the artefacts present, -- for the rest, and quotes the impl gate verdict" \
    status_rows "$P_ST"
M="$(t_mutant "$SB" status-path)"
if t_plant "$M" mk/flow.mk "$T"'    "synth:$(OUT_DIR)/$(BLOCK)_synth.dcp" \' "$T"'    "synth:$(OUT_DIR)/$(BLOCK)_synth.dcpx" \\'; then
    PM="$(proj_for "$M" status-path)"
    t_check_fail flow_mk.recipe.status.rows.mutation \
        "with synth's spec pointing one letter off, a present checkpoint reads as absent and the assertion goes red" \
        status_rows "$PM"
else
    t_skip flow_mk.recipe.status.rows.mutation "could not plant the fault: status' synth spec line in mk/flow.mk has changed shape, and this proof is measuring nothing until it is re-aimed"
fi
M="$(t_mutant "$SB" status-gate)"
if t_plant "$M" mk/flow.mk "$T"'@if [ -s "$(REPORT_DIR)/impl_gate.txt" ]; then \' "$T"'@if false; then \\'; then
    PM="$(proj_for "$M" status-gate)"
    t_check_fail flow_mk.recipe.status.rows.gate.mutation \
        "with the gate quote disabled, a present verdict is not shown and the assertion goes red" \
        status_rows "$PM"
else
    t_skip flow_mk.recipe.status.rows.gate.mutation "could not plant the fault: status' impl_gate line in mk/flow.mk has changed shape, and this proof is measuring nothing until it is re-aimed"
fi

t_check flow_mk.recipe.status.off "status says which conditional stages are OFF, so '--' against them is not read as a failure" \
    status_off_lines "$P_ST"
M="$(t_mutant "$SB" status-off)"
if t_plant "$M" mk/flow.mk "$T"'@if [ -z "$(strip $(PACKAGE_TCL))" ]; then \' "$T"'@if false; then \\'; then
    PM="$(proj_for "$M" status-off)"
    t_check_fail flow_mk.recipe.status.off.mutation \
        "with the package-ip OFF line disabled, an unconfigured stage looks like a failed one and the assertion goes red" \
        status_off_lines "$PM"
else
    t_skip flow_mk.recipe.status.off.mutation "could not plant the fault: status' PACKAGE_TCL line in mk/flow.mk has changed shape, and this proof is measuring nothing until it is re-aimed"
fi

#-----------------------------------------------------------------------------
# 4.3 clean AND distclean - THE TWO rm -rf THE GUARDS EXIST FOR
#
# clean keeps outputs/ and reports/: a finished bitstream and the manifests
# that say how it was built survive. distclean takes the run and NOTHING ELSE
# - a sibling run under the same BUILD_DIR is untouched - and it announces
# the bitstream it is about to delete first, because a run tag is one word
# and the wrong one is one keystroke. Both quote every path, and BUILD_DIR
# with a space in it is supported on purpose, so it is exercised.
#-----------------------------------------------------------------------------
t_head "clean keeps outputs and reports; distclean takes one run and announces the .bit"

## seed_run <project> [make args...] - the four directories with a file in each
seed_run() {
    local proj="$1"; shift
    local run; run="$(mk_expand "$proj" '$(RUN_DIR)' "$@")"
    rm -rf "$run"; mkdir -p "$run/work" "$run/logs" "$run/reports" "$run/outputs"
    printf 'x\n' > "$run/work/w"; printf 'x\n' > "$run/logs/l"
    printf 'x\n' > "$run/reports/r"; printf 'x\n' > "$run/outputs/demo_block.bit"
}

## clean_keeps_outputs <project>
clean_keeps_outputs() {
    seed_run "$1"
    make -C "$1" --no-print-directory clean >/dev/null 2>&1
    run_tree_is "$1" reports outputs
}

## distclean_takes_one_run <project> - RUN_TAG=victim goes; RUN_TAG=neighbour stays
distclean_takes_one_run() {
    local out victim neighbour build
    seed_run "$1" RUN_TAG=victim; seed_run "$1" RUN_TAG=neighbour
    victim="$(mk_expand "$1" '$(RUN_DIR)' RUN_TAG=victim)"
    neighbour="$(mk_expand "$1" '$(RUN_DIR)' RUN_TAG=neighbour)"
    build="$(mk_expand "$1" '$(BUILD_DIR)')"
    out="$(make -C "$1" --no-print-directory distclean RUN_TAG=victim 2>&1)"
    [ ! -e "$victim" ] || { printf '%s survived distclean\n' "$victim"; return 1; }
    [ -s "$neighbour/outputs/demo_block.bit" ] || { printf 'distclean RUN_TAG=victim took the neighbour run %s as well - everything under %s\n' "$neighbour" "$build"; return 1; }
    printf '%s\n' "$out" | grep -qF -- "!! $victim/outputs/demo_block.bit" && return 0
    printf 'distclean did not announce the bitstream it deleted:\n%s\n' "$out"
    return 1
}

P_CL="$(proj_for "$FLOW_DIR" clean "BUILD_DIR := $SB/clean-builds")"
t_check flow_mk.recipe.clean "make clean removes work/ and logs/ and keeps outputs/ and reports/" \
    clean_keeps_outputs "$P_CL"
M="$(t_mutant "$SB" clean-outputs)"
if t_plant "$M" mk/flow.mk "$T"'rm -rf "$(WORK_DIR)" "$(LOG_DIR)"' "$T"'rm -rf "$(WORK_DIR)" "$(LOG_DIR)" "$(OUT_DIR)"'; then
    PM="$(proj_for "$M" clean-outputs "BUILD_DIR := $SB/clean-builds-mut")"
    t_check_fail flow_mk.recipe.clean.mutation \
        "with outputs/ added to clean's rm, the bitstream goes with the scratch and the assertion goes red" \
        clean_keeps_outputs "$PM"
else
    t_skip flow_mk.recipe.clean.mutation "could not plant the fault: clean's rm line in mk/flow.mk has changed shape, and this proof is measuring nothing until it is re-aimed"
fi

t_check flow_mk.recipe.distclean "make distclean RUN_TAG=victim removes that run, leaves the neighbour, and announces the .bit first" \
    distclean_takes_one_run "$P_CL"
M="$(t_mutant "$SB" distclean-build)"
if t_plant "$M" mk/flow.mk "$T"'rm -rf "$(RUN_DIR)"' "$T"'rm -rf "$(BUILD_DIR)"'; then
    PM="$(proj_for "$M" distclean-build "BUILD_DIR := $SB/distclean-builds-mut")"
    t_check_fail flow_mk.recipe.distclean.mutation \
        "with the rm aimed at BUILD_DIR, every run goes - the disaster the RUN_TAG guards describe - and the assertion goes red" \
        distclean_takes_one_run "$PM"
else
    t_skip flow_mk.recipe.distclean.mutation "could not plant the fault: distclean's rm line in mk/flow.mk has changed shape, and this proof is measuring nothing until it is re-aimed"
fi
M="$(t_mutant "$SB" distclean-quiet)"
if t_plant "$M" mk/flow.mk "$T"'@test -s "$(OUT_DIR)/$(BLOCK).bit" && \' "$T"'@false && \\'; then
    PM="$(proj_for "$M" distclean-quiet "BUILD_DIR := $SB/distclean-quiet-mut")"
    t_check_fail flow_mk.recipe.distclean.announce.mutation \
        "with the bitstream announcement disabled, a .bit is deleted without being named and the assertion goes red" \
        distclean_takes_one_run "$PM"
else
    t_skip flow_mk.recipe.distclean.announce.mutation "could not plant the fault: distclean's .bit line in mk/flow.mk has changed shape, and this proof is measuring nothing until it is re-aimed"
fi

P_SP="$(proj_for "$FLOW_DIR" spaces "BUILD_DIR := $SB/with space/builds")"
t_check flow_mk.recipe.clean.spaces "with a space in BUILD_DIR, clean still removes exactly work/ and logs/" \
    clean_keeps_outputs "$P_SP"
M="$(t_mutant "$SB" clean-unquoted)"
if t_plant "$M" mk/flow.mk "$T"'rm -rf "$(WORK_DIR)" "$(LOG_DIR)"' "$T"'rm -rf $(WORK_DIR) $(LOG_DIR)'; then
    PM="$(proj_for "$M" clean-unquoted "BUILD_DIR := $SB/with space/builds-mut")"
    t_check_fail flow_mk.recipe.clean.spaces.mutation \
        "with the quotes dropped, the path splits at the space, work/ survives and the assertion goes red" \
        clean_keeps_outputs "$PM"
else
    t_skip flow_mk.recipe.clean.spaces.mutation "could not plant the fault: clean's rm line in mk/flow.mk has changed shape, and this proof is measuring nothing until it is re-aimed"
fi

#-----------------------------------------------------------------------------
# 4.4 post_stage_targets - THE THIRD FOUNDING DEFECT, RUN FOR REAL
#
# The macro is driven through a throwaway target that calls it directly, so
# it EXECUTES with no tool in the way - `make -n` cannot do that, because the
# call site does not spell $(MAKE) and -n only enters lines that do. Three
# properties: an empty list is a no-op that prints nothing; a named target
# runs; and a failing one is NON-FATAL TO THE BUILD AND FATAL TO THE CLAIM -
# make exits 0 and the warning names the claim that was not earned. The exit
# status IS the property in that last case, and it is asserted beside the
# message rather than instead of it.
#
# The planted fault is the shipped form of 2026-09-08: the conditional as an
# $(if) whose then-part carries the sentence "been evidenced, published or
# deployed". make splits its arguments on the commas in that sentence, and
# every stage ends in a shell syntax error, empty list or not.
#-----------------------------------------------------------------------------
t_head "post_stage_targets: no-op when empty, runs the target, non-fatal and loud on failure"

## post_run <project> <targets> - sets POST_RC and POST_OUT.
##
## IT SETS TWO VARIABLES RATHER THAN PRINTING A PAIR, and that is not a style
## choice: an empty output is the PROPERTY here, and a "status<newline>output"
## string carrying an empty second half is indistinguishable, after command
## substitution has stripped the trailing newline, from one carrying none.
## The first draft did exactly that and reported the correct empty case as
## having printed "0" - a test failing on its own transport.
post_run() {
    POST_RC=0
    POST_OUT="$(make -C "$1" --no-print-directory --eval="__t_stage: ; @\$(call post_stage_targets,__t_stage,$2)" __t_stage 2>&1)" || POST_RC=$?
}

## post_empty_is_silent <project>
post_empty_is_silent() {
    post_run "$1" ''
    [ "$POST_RC" -eq 0 ] || { printf 'an EMPTY post-target list exited %s:\n%s\n' "$POST_RC" "$POST_OUT"; return 1; }
    [ -z "$POST_OUT" ] && return 0
    printf 'an empty list printed something - the shell was handed a fragment:\n%s\n' "$POST_OUT"
    return 1
}

## post_target_runs <project>
post_target_runs() {
    post_run "$1" demo-post
    t_contains "$POST_OUT" DEMO-POST-RAN || { printf 'demo-post did not run (rc %s):\n%s\n' "$POST_RC" "$POST_OUT"; return 1; }
    t_contains "$POST_OUT" WARNING && { printf 'a target that succeeded was warned about:\n%s\n' "$POST_OUT"; return 1; }
    [ "$POST_RC" -eq 0 ] && return 0
    printf 'a successful post target exited %s\n' "$POST_RC"; return 1
}

## post_failure_is_nonfatal_and_loud <project>
post_failure_is_nonfatal_and_loud() {
    post_run "$1" demo-fail
    [ "$POST_RC" -eq 0 ] || { printf 'a failing post target made the BUILD fail (rc %s) - a 90-minute implementation would be gone:\n%s\n' "$POST_RC" "$POST_OUT"; return 1; }
    t_contains "$POST_OUT" "WARNING: post-__t_stage target(s) 'demo-fail' FAILED" || { printf 'no warning naming the failed target:\n%s\n' "$POST_OUT"; return 1; }
    t_contains "$POST_OUT" "The CLAIM is not" && return 0
    printf 'the warning does not withdraw the claim:\n%s\n' "$POST_OUT"; return 1
}

## post_project <flow dir> <name> -> a project with demo-post and demo-fail
post_project() {
    local d; d="$(proj_for "$1" "$2")" || return 2
    late_lines "$d" 'demo-post: ; @echo DEMO-POST-RAN
demo-fail: ; @echo DEMO-FAIL; exit 3'
    printf '%s' "$d"
}

IF_TRAP='$(if $(strip $(2)),echo "been evidenced, published or deployed",:) ; \\'

P_POST="$(post_project "$FLOW_DIR" post)"
t_check flow_mk.recipe.post.empty "an empty post-target list is a shell no-op: exit 0 and nothing printed" \
    post_empty_is_silent "$P_POST"
M="$(t_mutant "$SB" post-if-comma)"
if t_plant "$M" mk/flow.mk "_pt='\$(strip \$(2))'; \\" "$IF_TRAP"; then
    PM="$(post_project "$M" post-if-comma)"
    t_check_fail flow_mk.recipe.post.empty.mutation \
        "with the conditional put back into an \$(if) whose prose has a comma, make splits the sentence, the shell gets a fragment, and the assertion goes red" \
        post_empty_is_silent "$PM"
else
    t_skip flow_mk.recipe.post.empty.mutation "could not plant the fault: post_stage_targets' first line in mk/flow.mk has changed shape, and this proof is measuring nothing until it is re-aimed"
fi

t_check flow_mk.recipe.post.runs "a named post-stage target runs, and a success is not warned about" \
    post_target_runs "$P_POST"
M="$(t_mutant "$SB" post-never)"
if t_plant "$M" mk/flow.mk '  $(MAKE) --no-print-directory $$_pt \' '  true \\'; then
    PM="$(post_project "$M" post-never)"
    t_check_fail flow_mk.recipe.post.runs.mutation \
        "with the sub-make replaced by true, the target never runs and the assertion goes red" \
        post_target_runs "$PM"
else
    t_skip flow_mk.recipe.post.runs.mutation "could not plant the fault: post_stage_targets' \$(MAKE) line in mk/flow.mk has changed shape, and this proof is measuring nothing until it is re-aimed"
fi

t_check flow_mk.recipe.post.nonfatal "a failing post-stage target leaves make at exit 0 and prints the WARNING that withdraws the claim" \
    post_failure_is_nonfatal_and_loud "$P_POST"
M="$(t_mutant "$SB" post-fatal)"
if t_plant "$M" mk/flow.mk '  $(MAKE) --no-print-directory $$_pt \' '  $(MAKE) --no-print-directory $$_pt || exit 1; true \\'; then
    PM="$(post_project "$M" post-fatal)"
    t_check_fail flow_mk.recipe.post.nonfatal.mutation \
        "with the failure made fatal and silent, the build dies with the claim and the assertion goes red" \
        post_failure_is_nonfatal_and_loud "$PM"
else
    t_skip flow_mk.recipe.post.nonfatal.mutation "could not plant the fault: post_stage_targets' \$(MAKE) line in mk/flow.mk has changed shape, and this proof is measuring nothing until it is re-aimed"
fi

#-----------------------------------------------------------------------------
# 4.5 THE POST CALL IS THE LAST THING IN EVERY STAGE, AND THE SIX ARE DECLARED
#
# "runs after the stage's own verdict artefact exists" (CONTRACT.md section
# 4) is a fact about POSITION in the recipe, and `make -n` prints the recipe
# in order: the post call must come after the launch and after the last
# artefact test. A call that moved above them would report a deploy of a
# bitstream that had not been checked.
#-----------------------------------------------------------------------------
t_head "the post-stage call is the last line of every stage; the six lists are declared"

## post_call_is_last <project> <flow dir> <stages...>
post_call_is_last() {
    local proj="$1" flow="$2"; shift 2
    local s out script first_pt last_test launch bad=""
    for s in "$@"; do
        script="$(stage_script "$flow" "$s")"
        out="$(mk_dryrun "$proj" "$s" "$(post_var "$s")=demo-post")"
        first_pt="$(printf '%s\n' "$out" | grep -n "^_pt='demo-post'" | head -1 | cut -d: -f1)"
        last_test="$(printf '%s\n' "$out" | grep -n '^test -s "' | tail -1 | cut -d: -f1)"
        launch="$(printf '%s\n' "$out" | grep -nF -- "-source \"$script\"" | head -1 | cut -d: -f1)"
        if [ -z "$first_pt" ] || [ -z "$last_test" ] || [ -z "$launch" ] \
           || [ "$first_pt" -le "$last_test" ] || [ "$first_pt" -le "$launch" ]; then
            bad="$bad $s(post@${first_pt:-none} last-test@${last_test:-none} launch@${launch:-none})"
        fi
    done
    [ -z "$bad" ] && return 0
    printf 'stages whose post-stage call is not after the launch and every artefact test:%s\n' "$bad"
    return 1
}

## six_declared <project> <stages...> - each <STAGE>_POST_TARGETS has origin
## 'file' (declared by the engine) and an exported FPGA_ twin.
six_declared() {
    local proj="$1"; shift
    local s v lines=() out name origin env bad=""
    for s in "$@"; do
        v="$(post_var "$s")"
        lines+=("@printf '%s|%s|%s\\n' '$v' \"\$(origin $v)\" \"\$(origin FPGA_$v)\"")
    done
    out="$(mk_probe "$proj" "${lines[@]}")"
    while IFS='|' read -r name origin env; do
        [ "$origin" = file ] || bad="$bad [$name origin '$origin']"
        [ "$env" = file ] || bad="$bad [FPGA_$name origin '$env']"
    done <<< "$out"
    [ -z "$bad" ] && return 0
    printf 'post-target lists the engine does not declare:%s\n' "$bad"
    return 1
}

t_check flow_mk.recipe.post.last "for every stage, the post-stage call comes after the launch and after the last artefact test" \
    post_call_is_last "$P_FULL" "$FLOW_DIR" $STAGES
M="$(t_mutant "$SB" post-first)"
if t_plant "$M" mk/flow.mk "$T"'$(call missing_stage_script,bitstream,$(FLOW_VIVADO_DIR)/6_bitstream.tcl)' "$T"'@$(call post_stage_targets,bitstream,$(BITSTREAM_POST_TARGETS))'; then
    PM="$(full_for "$M" post-first)"
    t_check_fail flow_mk.recipe.post.last.mutation \
        "with a post call planted as bitstream's first line, deploy would precede the verdict and the assertion goes red" \
        post_call_is_last "$PM" "$M" $STAGES
else
    t_skip flow_mk.recipe.post.last.mutation "could not plant the fault: bitstream's first recipe line in mk/flow.mk has changed shape, and this proof is measuring nothing until it is re-aimed"
fi

t_check flow_mk.recipe.post.declared "every <STAGE>_POST_TARGETS in the chain is declared by the engine, with its FPGA_ export" \
    six_declared "$P_BARE" $STAGES
M="$(t_mutant "$SB" post-undeclared)"
if t_plant "$M" mk/flow.mk 'IMPL_POST_TARGETS       ?=' '# IMPL_POST_TARGETS declaration removed by mutation'; then
    PM="$(proj_for "$M" post-undeclared)"
    t_check_fail flow_mk.recipe.post.declared.mutation \
        "with IMPL_POST_TARGETS undeclared, the census no longer shows six and the assertion goes red" \
        six_declared "$PM" $STAGES
else
    t_skip flow_mk.recipe.post.declared.mutation "could not plant the fault: mk/flow.mk has no line exactly 'IMPL_POST_TARGETS       ?=', and this proof is measuring nothing until it is re-aimed"
fi

#=============================================================================
# 5. THE INCLUDE MACHINERY - WHAT THE SPLIT WILL STAND ON
#
# Three hard includes with a named error in front of each (a missing fragment
# is an INCOMPLETE CHECKOUT, and `-include` would report "No rule to make
# target 'help'" instead), and the opt-out mechanism for optional fragments:
# included unconditionally, skipped only by a project that names the fragment
# in FPGA_FLOW_SKIP_MK, never read twice, and LOUD when the file is missing.
# No fragment uses fpga_flow_optional today; the split will, so it is driven
# here with a planted fragment in a copy of the toolkit.
#=============================================================================
t_head "hard includes refuse by name; fpga_flow_optional includes, skips, dedupes and refuses"

## missing_fragment_named <project> <fragment> - the copy lacks mk/<f>.mk and
## make says so in those words, not as a "No such file" from the include.
missing_fragment_named() {
    local out rc=0
    out="$(make -C "$1" --no-print-directory -n env 2>&1)" || rc=$?
    [ "$rc" -ne 0 ] || { printf 'make parsed a toolkit with no mk/%s.mk\n' "$2"; return 1; }
    printf '%s\n' "$out" | grep -qF -- "has no mk/$2.mk" && return 0
    printf 'make failed, but not with the named refusal:\n%s\n' "$out"
    return 1
}

FRAGMENTS="$(sed -nE 's|^include \$\(FPGA_FLOW_DIR\)/mk/([a-z_]+)\.mk$|\1|p' "$FLOW_DIR/mk/flow.mk")"
if [ -z "$FRAGMENTS" ]; then
    t_skip flow_mk.include.hard "mk/flow.mk has no 'include \$(FPGA_FLOW_DIR)/mk/<x>.mk' lines to read the fragment list from"
else
    for f in $FRAGMENTS; do
        # The baseline is an UNMODIFIED copy with the file removed - the
        # refusal under test is the shipped one.
        B="$(t_mutant "$SB" "nofrag-$f")"; rm -f "$B/mk/$f.mk"
        PB="$(proj_for "$B" "nofrag-$f")"
        t_check "flow_mk.include.hard.$f" "a checkout with no mk/$f.mk is refused BY NAME" \
            missing_fragment_named "$PB" "$f"
        M="$(t_mutant "$SB" "nofrag-$f-mut")"; rm -f "$M/mk/$f.mk"
        if t_plant "$M" mk/flow.mk "ifeq (\$(wildcard \$(FPGA_FLOW_DIR)/mk/$f.mk),)" "$GUARD_OFF"; then
            PM="$(proj_for "$M" "nofrag-$f-mut")"
            t_check_fail "flow_mk.include.hard.$f.mutation" \
                "with the guard disabled, the include itself fails with make's own message and the assertion goes red" \
                missing_fragment_named "$PM" "$f"
        else
            t_skip "flow_mk.include.hard.$f.mutation" "could not plant the fault: the mk/$f.mk guard in mk/flow.mk has changed shape, and this proof is measuring nothing until it is re-aimed"
        fi
    done
fi

## plant_fragment <toolkit copy> - mk/demo.mk with one target and no guard
plant_fragment() { printf 'demo-frag:\n\t@echo DEMO-FRAG\n' > "$1/mk/demo.mk"; }

## optional_project <toolkit copy> <name> <design.mk extra> <calls> -> project
## whose Makefile calls fpga_flow_optional after the includes, <calls> times.
optional_project() {
    local d i; d="$(proj_for "$1" "$2" "$3")" || return 2
    for ((i = 0; i < $4; i++)); do late_lines "$d" '$(call fpga_flow_optional,demo)'; done
    printf '%s' "$d"
}

## frag_included <project>   - demo-frag is a target and parses without warning
frag_included() {
    local out; out="$(make -C "$1" --no-print-directory -n demo-frag 2>&1)"
    printf '%s\n' "$out" | grep -qi 'overriding' && { printf 'the fragment was read twice:\n%s\n' "$out"; return 1; }
    printf '%s\n' "$out" | grep -qF 'echo DEMO-FRAG' && return 0
    printf 'demo-frag is not a target:\n%s\n' "$out"; return 1
}
## frag_skipped <project>    - demo-frag is NOT a target
frag_skipped() {
    local out; out="$(make -C "$1" --no-print-directory -n demo-frag 2>&1)"
    printf '%s\n' "$out" | grep -qF 'echo DEMO-FRAG' && { printf 'the fragment was included despite FPGA_FLOW_SKIP_MK:\n%s\n' "$out"; return 1; }
    printf '%s\n' "$out" | grep -qF 'No rule to make target' && return 0
    printf 'unexpected:\n%s\n' "$out"; return 1
}
## frag_missing_is_loud <project> - no mk/demo.mk: make refuses naming it
frag_missing_is_loud() {
    local out rc=0; out="$(make -C "$1" --no-print-directory -n env 2>&1)" || rc=$?
    [ "$rc" -ne 0 ] || { printf 'a missing optional fragment was skipped silently: make env parsed\n'; return 1; }
    printf '%s\n' "$out" | grep -qF 'demo.mk' && return 0
    printf 'make failed without naming the missing fragment:\n%s\n' "$out"; return 1
}

B="$(t_mutant "$SB" frag-base)"; plant_fragment "$B"
t_check flow_mk.include.optional.included "\$(call fpga_flow_optional,demo) includes mk/demo.mk" \
    frag_included "$(optional_project "$B" frag-in '' 1)"
M="$(t_mutant "$SB" frag-never)"; plant_fragment "$M"
if t_plant "$M" mk/flow.mk 'fpga_flow_optional = $(if $(call fpga_flow_skipped,$(1))$(call fpga_flow_read,$(1)),,$(eval include $(FPGA_FLOW_DIR)/mk/$(1).mk))' 'fpga_flow_optional ='; then
    t_check_fail flow_mk.include.optional.included.mutation \
        "with fpga_flow_optional emptied, the fragment is never read and the assertion goes red" \
        frag_included "$(optional_project "$M" frag-never '' 1)"
else
    t_skip flow_mk.include.optional.included.mutation "could not plant the fault: fpga_flow_optional in mk/flow.mk has changed shape, and this proof is measuring nothing until it is re-aimed"
fi

t_check flow_mk.include.optional.skipped "FPGA_FLOW_SKIP_MK := demo in design.mk keeps the fragment out" \
    frag_skipped "$(optional_project "$B" frag-skip 'FPGA_FLOW_SKIP_MK := demo' 1)"
M="$(t_mutant "$SB" frag-noskip)"; plant_fragment "$M"
if t_plant "$M" mk/flow.mk 'fpga_flow_skipped = $(filter $(1),$(FPGA_FLOW_SKIP_MK))' 'fpga_flow_skipped ='; then
    t_check_fail flow_mk.include.optional.skipped.mutation \
        "with the opt-out test emptied, a project that supplies its own copy gets the toolkit's too, and the assertion goes red" \
        frag_skipped "$(optional_project "$M" frag-noskip 'FPGA_FLOW_SKIP_MK := demo' 1)"
else
    t_skip flow_mk.include.optional.skipped.mutation "could not plant the fault: fpga_flow_skipped in mk/flow.mk has changed shape, and this proof is measuring nothing until it is re-aimed"
fi

t_check flow_mk.include.optional.once "a fragment called for twice is read once - no rule is overridden" \
    frag_included "$(optional_project "$B" frag-twice '' 2)"
M="$(t_mutant "$SB" frag-reread)"; plant_fragment "$M"
if t_plant "$M" mk/flow.mk 'fpga_flow_read = $(filter $(realpath $(FPGA_FLOW_DIR)/mk/$(1).mk),$(realpath $(MAKEFILE_LIST)))' 'fpga_flow_read ='; then
    t_check_fail flow_mk.include.optional.once.mutation \
        "with the already-read test emptied, the second call redefines demo-frag with a warning nobody reads, and the assertion goes red" \
        frag_included "$(optional_project "$M" frag-reread '' 2)"
else
    t_skip flow_mk.include.optional.once.mutation "could not plant the fault: fpga_flow_read in mk/flow.mk has changed shape, and this proof is measuring nothing until it is re-aimed"
fi

t_check flow_mk.include.optional.missing "a fragment that is called for and absent from disk is refused by name, never skipped" \
    frag_missing_is_loud "$(optional_project "$FLOW_DIR" frag-missing '' 1)"
M="$(t_mutant "$SB" frag-soft)"
if t_plant "$M" mk/flow.mk 'fpga_flow_optional = $(if $(call fpga_flow_skipped,$(1))$(call fpga_flow_read,$(1)),,$(eval include $(FPGA_FLOW_DIR)/mk/$(1).mk))' 'fpga_flow_optional = $(if $(call fpga_flow_skipped,$(1))$(call fpga_flow_read,$(1)),,$(eval -include $(FPGA_FLOW_DIR)/mk/$(1).mk))'; then
    t_check_fail flow_mk.include.optional.missing.mutation \
        "with the include softened to -include, a missing gate is a gate nobody runs and the assertion goes red" \
        frag_missing_is_loud "$(optional_project "$M" frag-soft '' 1)"
else
    t_skip flow_mk.include.optional.missing.mutation "could not plant the fault: fpga_flow_optional in mk/flow.mk has changed shape, and this proof is measuring nothing until it is re-aimed"
fi

t_summary
