#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# t_bd.sh - THE BLOCK-DESIGN PATH: a .bd IS NOT A SYNTHESISABLE ARTEFACT
#
# DEFECT CLASS: A STAGE THAT HANDS ON A FILE THE NEXT STAGE CANNOT USE, AND
#               EVERY ASSERTION IN BETWEEN PASSING.
#
# All four assertions here come from one measured failure, on the first real
# block-design design this toolkit was pointed at (KR260 eth-chiplet, Vivado
# 2024.1, 2026-09-08). The bd stage went green, wrote its .bd at the contract
# path, wrote its manifest and its gate - and synthesis died at the BOARD TOP:
#
#     ERROR: [Synth 8-439] module 'tidelink_design' not found
#            [.../tidelink_design_wrapper.v:90]
#
# Three independent causes, and none of them could be reached by any setting of
# any contract variable:
#
#   1. `generate_target` appeared NOWHERE in the toolkit. A .bd is a
#      DESCRIPTION of a design; the HDL that the board top instantiates is
#      GENERATED from it, and nothing asked for it. The reference flow calls it
#      (build_design.tcl:455) and its project therefore carries
#      .gen/sources_1/bd/<name>/synth/<name>.v.
#
#   2. The handoff was a byte COPY of the .bd at the contract path. A .bd names
#      its IP by VLNV and its output products by location inside the project
#      that owns them, so the copy describes a design whose every part is
#      somewhere else - and read_bd does not fail on that.
#
#   3. The part was not on the in-memory design when the BD was read. Vivado
#      defaulted to xc7vx485tffg1157-1, a Virtex-7, and every IP in a Zynq
#      UltraScale+ design failed to resolve. `-part` on the synth_design command
#      line is 3880 log lines too late.
#
# WHAT THIS SUITE CAN AND CANNOT MEASURE. It runs with no EDA tool, so it cannot
# build a block design; every proof about a Vivado stage script here is
# STRUCTURAL - the call is present, the ORDER is right, the two ends of the
# handoff name the same file. That is weaker than running the stage and it is
# not nothing: all three defects above are visible in the file, and one of them
# (#1) was literally the absence of a string.
#
# THE ONE FUNCTIONAL SECTION IS SECTION 4: `make check`'s BD_TCL contract test,
# which is python and needs no licence. It is driven with both polarities - a
# BD_TCL that creates a block design and one that does not - because the file
# that started all this reported `ok BD_TCL` while defining a proc and building
# nothing.
#
# COMMENTS ARE STRIPPED BEFORE EVERY GREP. This file's assertions are about what
# the code DOES, and every one of the strings below also appears in the prose
# that explains it. A grep that counted the explanation would report the call
# present in a file that had lost it - which is exactly how a check comes to
# measure its own documentation.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/lib/harness.sh
. "$HERE/../lib/harness.sh"

t_sandbox; SB="$T_SANDBOX"

BD_REL="flow/vivado/3_bd.tcl"
SY_REL="flow/vivado/4_synth.tcl"
CHECK_REL="scripts/fpga-flow-check"

# Tcl code with whole-line comments removed. NOT a parser: a `#` inside a string
# survives, which is the safe direction - it can only make this stricter.
code_of() { sed 's/^[[:space:]]*#.*$//' "$1"; }

# COUNT, NEVER `grep -q`, AND THAT IS NOT A STYLE PREFERENCE. The harness runs
# under `set -o pipefail`; `grep -q` exits on the FIRST match and the producer
# ahead of it dies of SIGPIPE with status 141, which pipefail then reports as the
# pipeline's. The result is a check that goes red exactly when its assertion
# HOLDS, and non-deterministically - a short file can finish before grep exits
# and pass. Two assertions in the first draft of this suite did that.
# `grep -c` reads to end of input, so there is no signal to race with.
n_matching() { code_of "$1" | grep -cE -- "$2"; }

if [ ! -f "$FLOW_DIR/$BD_REL" ] || [ ! -f "$FLOW_DIR/$SY_REL" ]; then
    t_skip bd.all "no $BD_REL or $SY_REL in this checkout - the stage scripts are absent, and an absent file is not a passing one"
    t_summary; exit $?
fi

#=============================================================================
# 1. THE BD STAGE GENERATES THE BLOCK DESIGN'S OUTPUT PRODUCTS
#=============================================================================
t_head "the bd stage asks Vivado to generate the BD's output products"

## bd_generates <root> - the stage calls generate_target, in code, not in prose.
bd_generates() {
    local root="$1"
    # A COMMAND POSITION: line-initial, or opening a script/catch body. The bare
    # word also appears in the knob name, in the manifest field and in the gate
    # text, and a check that counted those would report the call present in a
    # file that had lost it.
    if [ "$(n_matching "$root/$BD_REL" '(^|\{)[[:space:]]*generate_target[[:space:]]')" -gt 0 ]; then
        return 0
    fi
    echo "no generate_target call in $BD_REL (comments stripped)."
    echo "A .bd is not HDL. Without this the board-level top instantiates a module"
    echo "that was never written, and the error arrives in the NEXT stage."
    return 1
}

t_check bd.generate_target \
    "flow/vivado/3_bd.tcl calls generate_target" \
    bd_generates "$FLOW_DIR"

M="$(t_mutant "$SB" bd-no-generate)"
if t_mutate "$M" "$BD_REL" 's/^\([[:space:]]*\)\(if {\[catch {generate_target\)/\1# \2/'; then
    t_check_fail bd.generate_target.mutation \
        "with the generate_target call commented out, the check goes red" \
        bd_generates "$M"
else
    t_skip bd.generate_target.mutation "could not plant the fault: the generate_target call in $BD_REL has changed shape"
fi

## The stage must also ASSERT on the generated file, not on the call. A command
## that reported an error and let the script continue is the normal case here -
## Vivado exits 0 after a failed generate_target.
bd_asserts_hdl() {
    local root="$1"
    [ "$(n_matching "$root/$BD_REL" 'bd_synth_hdl')" -gt 0 ] && return 0
    echo "$BD_REL does not track the generated synthesisable HDL."
    echo "generate_target exits 0 on a design whose IP did not resolve, so the"
    echo "call is not the evidence - the file on disk is."
    return 1
}

t_check bd.generate_target.asserted \
    "the generated synthesisable HDL is looked for on disk, not inferred from the call" \
    bd_asserts_hdl "$FLOW_DIR"

M="$(t_mutant "$SB" bd-no-hdl-assert)"
if t_mutate "$M" "$BD_REL" 's/bd_synth_hdl/bd_unchecked_hdl/g'; then
    t_check_fail bd.generate_target.asserted.mutation \
        "with the generated-HDL check renamed away, the assertion goes red" \
        bd_asserts_hdl "$M"
else
    t_skip bd.generate_target.asserted.mutation "could not plant the fault: bd_synth_hdl is not in $BD_REL"
fi

#=============================================================================
# 2. THE PART IS ON THE DESIGN BEFORE THE DESIGN IS READ
#
# An IP resolves against the part that is set WHEN IT IS READ. This is an ORDER
# assertion and it is written as one: the presence of `create_project -in_memory
# -part` proves nothing if it happens after the block design has been read.
#=============================================================================
t_head "the synth stage sets the part before it reads anything"

## part_before_read <root>
part_before_read() {
    local root="$1" body part_ln read_ln
    body="$(code_of "$root/$SY_REL")"
    # `sed -n 1p` rather than `head -1`: head exits after the first line and the
    # grep ahead of it dies of SIGPIPE, which pipefail reports as the pipeline's
    # status. See n_matching above - same trap, different command.
    part_ln="$(printf '%s\n' "$body" | grep -nE 'create_project[[:space:]]+-in_memory[[:space:]]+-part' | sed -n 1p | cut -d: -f1)"
    read_ln="$(printf '%s\n' "$body" | grep -nE '(^|[[:space:]])(read_bd|read_verilog|read_vhdl)[[:space:]]|source \$BD_HANDOFF_TCL|source \$SYNTH_SOURCES_TCL' | sed -n 1p | cut -d: -f1)"
    if [ -z "$part_ln" ]; then
        echo "$SY_REL never creates an in-memory project with -part."
        echo "Vivado then defaults to xc7vx485tffg1157-1 and every IP in a design"
        echo "for another family fails to resolve, with -part on the synth_design"
        echo "command line thousands of log lines too late."
        return 1
    fi
    if [ -z "$read_ln" ]; then
        echo "$SY_REL reads no design at all - nothing to order the part against."
        return 1
    fi
    if [ "$part_ln" -lt "$read_ln" ]; then
        return 0
    fi
    echo "the part is set at line $part_ln and the first source/BD read is at line $read_ln."
    echo "An IP resolves against the part that is set when it is READ."
    return 1
}

t_check bd.part_before_read \
    "flow/vivado/4_synth.tcl sets the part before the first read" \
    part_before_read "$FLOW_DIR"

M="$(t_mutant "$SB" synth-no-part)"
if t_mutate "$M" "$SY_REL" 's/^\([[:space:]]*\)create_project -in_memory -part/\1# create_project -in_memory -part/'; then
    t_check_fail bd.part_before_read.absent \
        "with the in-memory create_project commented out, the check goes red" \
        part_before_read "$M"
else
    t_skip bd.part_before_read.absent "could not plant the fault: the create_project call in $SY_REL has changed shape"
fi

# THE ORDER MUTATION, which is the one that matters: the call is still there and
# a read happens before it. A check that only tested for PRESENCE would stay
# green on this, and the design would still be read against the wrong part.
M="$(t_mutant "$SB" synth-read-first)"
if t_mutate "$M" "$SY_REL" '0,/^step "read the design"$/s//read_verilog \/dev\/null\nstep "read the design"/'; then
    t_check_fail bd.part_before_read.order \
        "with a read moved ahead of the part, the check goes red even though the call is present" \
        part_before_read "$M"
else
    t_skip bd.part_before_read.order "could not plant the fault: no 'step \"read the design\"' line in $SY_REL"
fi

#=============================================================================
# 3. THE TWO ENDS OF THE HANDOFF NAME THE SAME ARTEFACT
#
# CONTRACT.md section 5: handoff is by artefact NAME inside work/. The name is
# therefore a shared constant between two files that never see each other, and
# a rename in one of them is a stage that silently falls back to the lossy path.
#=============================================================================
t_head "the bd stage writes the handoff the synth stage reads"

handoff_agrees() {
    local root="$1" w r
    w="$(n_matching "$root/$BD_REL" 'bd_handoff\.tcl')"
    r="$(n_matching "$root/$SY_REL" 'bd_handoff\.tcl')"
    if [ "$w" -gt 0 ] && [ "$r" -gt 0 ]; then return 0; fi
    echo "bd_handoff.tcl is named $w time(s) in $BD_REL and $r time(s) in $SY_REL."
    echo "Both ends have to name it: the writer produces the artefact and the"
    echo "reader looks for it, and a reader that does not find one falls back to"
    echo "the bare .bd copy - which reads as a design with its IP missing."
    return 1
}

t_check bd.handoff.name \
    "3_bd.tcl and 4_synth.tcl name the same handoff artefact" \
    handoff_agrees "$FLOW_DIR"

M="$(t_mutant "$SB" handoff-renamed)"
if t_mutate "$M" "$SY_REL" 's/bd_handoff\.tcl/bd_handover.tcl/g'; then
    t_check_fail bd.handoff.name.mutation \
        "with the reader renaming the artefact, the check goes red" \
        handoff_agrees "$M"
else
    t_skip bd.handoff.name.mutation "could not plant the fault: $SY_REL does not name bd_handoff.tcl"
fi

## AND THE READER MUST REFUSE WITHOUT IT. A stage that shrugged and read the
## bare copy would produce a smaller, cleaner, wrong netlist and pass every
## budget in the flow.
handoff_refuses() {
    local root="$1"
    [ "$(n_matching "$root/$SY_REL" 'stage_stop synth "a block design with no handoff record')" -gt 0 ] && return 0
    echo "$SY_REL does not refuse a block design with no handoff record."
    echo "The bare .bd at the contract path is separated from its output products;"
    echo "reading it gives a design with the IP missing and no error anywhere."
    return 1
}

t_check bd.handoff.refusal \
    "a BD with no handoff record is refused, not read anyway" \
    handoff_refuses "$FLOW_DIR"

#=============================================================================
# 4. `make check` READS BD_TCL RATHER THAN STAT()ING IT - BOTH POLARITIES
#
# The file that started this reported `ok BD_TCL`. Its only top-level construct
# was `proc create_root_design { parentCell }`: it defined a proc, built
# nothing, and the first thing that noticed was the bd stage's own artefact
# assertion - after a tool launch and a licence.
#=============================================================================
t_head "make check reads BD_TCL and can tell a library from a builder"

if ! command -v python3 >/dev/null 2>&1; then
    t_skip bd.check.contract "python3 is not on this host, and $CHECK_REL is python"
elif [ ! -f "$FLOW_DIR/$CHECK_REL" ]; then
    t_skip bd.check.contract "$CHECK_REL is not in this checkout"
else
    GOOD="$SB/bd_builds.tcl"
    BAD="$SB/bd_library.tcl"
    cat > "$GOOD" <<'EOF'
# a BD_TCL that meets the contract: sourcing it creates the block design.
create_bd_design $DESIGN_NAME
EOF
    cat > "$BAD" <<'EOF'
# a BD_TCL that does NOT meet the contract: it defines a proc and builds
# nothing. Every existence check in the world passes on this file.
proc create_root_design { parentCell } {
    return
}
EOF

    ## check_bd <bd_tcl> - the contract checker's REPORT for a project whose only
    ## interesting variable is BD_TCL.
    ##
    ## THE VERDICT IS READ OUT OF THE REPORT, NOT OUT OF THE EXIT STATUS, and
    ## that is forced rather than chosen: this fixture declares no TOP, no
    ## RTL_FLIST, no XDC_PINS and no PART, so the checker exits non-zero either
    ## way. An exit-status test here would go green on a checker that had never
    ## looked at BD_TCL at all - which is the exact defect this section exists
    ## to catch, one layer up.
    check_bd() {
        python3 "$FLOW_DIR/$CHECK_REL" \
            --var FPGA_FLOW_DIR="$FLOW_DIR" \
            --var BLOCK=demo_block --var BOARD=demo_board \
            --var BD_TCL="$1" 2>&1
    }

    accepts_builder() {
        local out; out="$(check_bd "$GOOD")"
        printf '%s\n' "$out" | grep -cE '^  ok +BD_TCL calls +create_bd_design' >/dev/null && return 0
        echo "the checker did not report that BD_TCL calls create_bd_design:"
        printf '%s\n' "$out" | grep -i 'BD_TCL' | sed 's/^/  /'
        return 1
    }
    t_check bd.check.contract.accepts \
        "a BD_TCL that calls create_bd_design is reported ok" \
        accepts_builder

    # THIS IS THE PROOF, not a mutation of the toolkit: the fault is in the
    # INPUT, which is where this class of defect actually lives.
    refuses_library() {
        local out; out="$(check_bd "$BAD")"
        printf '%s\n' "$out" | grep -cF 'BD_TCL creates no block design' >/dev/null && return 0
        echo "the checker did not refuse a BD_TCL that builds nothing:"
        printf '%s\n' "$out" | grep -i 'BD_TCL' | sed 's/^/  /'
        return 1
    }
    t_check bd.check.contract.refuses \
        "a BD_TCL that only defines create_root_design is refused" \
        refuses_library

    ## and the refusal has to SAY the thing that is wrong. A message that only
    ## said "BD_TCL" would send the reader to check a path that is correct.
    ##
    ## CAPTURED FIRST, THEN GREPPED. `check_bd | grep` reports the CHECKER's
    ## non-zero exit under pipefail, not the grep's, so the assertion would go
    ## red on a refusal that said exactly the right thing. Third instance of the
    ## same class in this one file - see n_matching.
    names_the_defect() {
        local out; out="$(check_bd "$BAD")"
        printf '%s\n' "$out" | grep -cF 'DEFINES `proc create_root_design` and never calls it' >/dev/null
    }
    t_check bd.check.contract.diagnosis \
        "the refusal names the library-versus-builder defect, not just the variable" \
        names_the_defect
fi

t_summary
