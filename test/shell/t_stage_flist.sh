#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# t_stage_flist.sh - flow/vivado/1_flist.tcl: THE FIRST STAGE SCRIPT UNDER TEST
#
# DEFECT CLASS: A STAGE THAT WRITES A GREEN VERDICT ABOUT A DESIGN IT DID NOT
#               READ - OR A COUNT NOBODY TOOK - AND EVERY GRADER DOWNSTREAM
#               BELIEVES THE ARTEFACT.
#
# KNOWN_DEFECTS "no stage script is unit-tested": 5,200 lines of flow/vivado/
# *.tcl rest on ONE integration result, a bitstream that matched a known-good
# one for one design on one part. The entry's own remedy is "the parts of each
# stage that do not call a tool, factored out and driven under tclsh". This is
# the first suite to do it, and 1_flist.tcl is where to start because ALMOST
# NONE OF IT CALLS A TOOL: its own header says everything below flow_boot could
# run under a bare tclsh, and read_flist.tcl already does.
#
# WHY THIS STAGE MATTERS OUT OF PROPORTION TO ITS SIZE. CONTRACT.md section 9.1:
# there is no `ifdef FPGA and no `ifdef ASIC anywhere in this codebase, so WHICH
# FILES THE FLIST NAMES IS THE CONFIGURATION. The KR260 shipping flow silently
# substituted a V1 PHY for a V2 one, and the only artefact that could have told
# anybody was this stage's manifest: file_count and incdir_count are the numbers
# that tell two wrapper families apart. A stage that writes those numbers wrong
# - or writes them for a flist it never opened - is a stage that certifies the
# wrong design with the right paperwork.
#
# WHAT IS ASSERTED, and each is what 1_flist.tcl ADDS on top of read_flist.tcl
# (the reader itself is t_flist.sh's; nothing there is repeated here):
#
#   1. THE BOOT SEQUENCE REFUSES BEFORE IT CLAIMS ANYTHING. An unset, absent or
#      zero-byte RTL_FLIST is exit 2, names the variable or the path, and comes
#      BEFORE the "read the filelist" step banner - the stage's own comment says
#      that ordering is the reason the guard is here and not left to the
#      reader. And a refused flist leaves NO manifest: a file_count invented for
#      a flist nobody opened would be graded green by ci/assert-stage.sh.
#   2. THE MANIFEST'S BLOCK 8 IS WHAT THE CONSUMER READS. `file_count` is a
#      top-level key readable with assert-stage's own awk, and against a
#      fixture the suite built the numbers are KNOWN: 6 sources across a
#      3-deep -f chain with 3 +incdir+, 1 define, 1 -y, 1 ignored option.
#   3. THE THREE ARTEFACTS AGREE WITH EACH OTHER - manifest count, sources.tcl
#      read commands, census rows - because they are written by three different
#      loops and a fault in one leaves the other two describing a different run.
#   4. THE CENSUS IS EVIDENCE: every row a real sha256 (matched against
#      sha256sum), a site path a digest and never in clear, batches that hash
#      EVERY file past the 200-file boundary, and "hashing off" written as
#      `unmeasured` and never as 0.
#   5. THE GATE HAS CONTRACT.md SECTION 5's FOUR CLASSES, every delegation
#      carries `owner=`, and a hard failure is counted, listed, written to disk
#      BEFORE the exit 1, and reflected in the manifest.
#   6. TOP: declared in the flist, declared ONLY in TOP_HDL with the append knob
#      OFF (the false-hard-failure defect the stage's own comment records),
#      declared nowhere (hard), a missing TOP_HDL refused whatever the knob
#      says, and SV_FILES forcing -sv on a .v in both the flist and TOP_HDL.
#   7. DEFINES: RTL_DEFINES_NEVER caught in the flist AND in RTL_DEFINES_INBODY
#      - the second is the set synth_setup.tcl can never see.
#   8. THE SEAM: a post_flist hook's read commands land in sources.tcl and are
#      counted by the gate, and a hook that leaves sources.tcl with no read
#      command is a HARD failure - the artefact check is on CONTENT, not -s.
#   9. FLIST_APPLY: off by default reads NOTHING into the session; on, it
#      applies exactly file_count reads with the include union ONCE before the
#      first of them.
#
# THE TECHNIQUE, AND WHAT THE STUBS DO NOT PROVE. The stage is `source`d under
# bare tclsh from a driver that first defines RECORDING STUBS for the Vivado
# commands it can reach - read_verilog, read_vhdl, set_property, get_property,
# current_fileset - each of which appends to a list and does nothing else. What
# was recorded is then asserted. THAT PROVES THE STAGE ISSUED THE CALLS. IT
# PROVES NOTHING ABOUT WHETHER VIVADO WOULD ACCEPT THEM: a read_verilog that
# Vivado would reject, an include_dirs property that the tool ignores, a fileset
# that does not exist - all pass here. Nor does any of this parse RTL; the
# stage's own header says it does not, and neither does this suite. What the
# real tool does with these calls is what the integration result covers, and
# that is the half these two forms of evidence still need each other for.
#
# THE ENVIRONMENT COMES FROM make. Every FPGA_* variable the stage reads is
# exported by mk/flow.mk, so the driver asks make to dump the environment a
# stage would run under (`--eval='p: ; @env' p` against a throwaway project)
# and passes it through unchanged. No path in this file is composed; a suite
# that spelled WORK_DIR itself would be testing its own spelling.
#
# `die` AND `flow_refuse` EXIT. No catch can trap them, so a driver that
# caught around the stage would report success on an exit it never observed.
# The stage's exit status is therefore graded FROM THE SHELL, on every run, and
# the artefacts are read from disk afterwards.
#
# Every assertion is PAIRED WITH A MUTATION PROOF - one planted fault, one fresh
# copy of the toolkit, the same predicate must go red - applied through
# t_replace_line / t_mutate, which fail loudly when the edit changed nothing. A
# fault that could not be planted is a SKIP naming the line, never a pass.
#
# TWO t_known_defect MARKERS at the end record what reading the artefacts found
# in 1_flist.tcl; both go RED the day they are fixed.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/lib/harness.sh
. "$HERE/../lib/harness.sh"

t_sandbox; SB="$T_SANDBOX"

#-----------------------------------------------------------------------------
# PRECONDITIONS. Each is a SKIP WITH THE REASON, never a pass.
#-----------------------------------------------------------------------------
ST_REL="flow/vivado/1_flist.tcl"
RF_REL="flow/common/read_flist.tcl"
if [ ! -f "$FLOW_DIR/$ST_REL" ]; then
    t_skip fstage.all "no $ST_REL at $FLOW_DIR - nothing to test, and an absent stage is not a passing one"
    t_summary; exit $?
fi
if ! command -v tclsh >/dev/null 2>&1; then
    t_skip fstage.all "no tclsh on PATH - the stage is driven under bare tclsh and that is the only tool-free way to drive it"
    t_summary; exit $?
fi
if ! command -v sha256sum >/dev/null 2>&1; then
    t_skip fstage.all "no sha256sum on PATH - the stage execs it for every census row and every hash field under test would be UNVERIFIED"
    t_summary; exit $?
fi
if ! command -v make >/dev/null 2>&1; then
    t_skip fstage.all "no make on PATH - the stage's environment is asked of mk/flow.mk, not composed here"
    t_summary; exit $?
fi
# read_flist.tcl emits `read_verilog [list $path]`, and Tcl's `list` BRACES a
# path containing a space. The read-command counts below match the unbraced
# spelling, so a sandbox with a space in it would go red for a reason that has
# nothing to do with the stage. Say so rather than report that.
case "$SB" in
    *" "*)
        t_skip fstage.all "the sandbox path '$SB' contains a space, so Tcl's list would brace every emitted path while these assertions count the unbraced spelling"
        t_summary; exit $? ;;
esac

#=============================================================================
# THE FIXTURE
#
# THREE TREES, and the geometry carries one of the assertions:
#
#   $SB/p/proj   the project (FPGA_DIR). mk/flow.mk derives PROJECT_ROOT as
#                its parent, $SB/p, so anything under $SB/p is "<project>".
#   $SB/site     OUTSIDE the project root, the toolkit and the run tree - a
#                stand-in for a vendor mount, shaped like one. Its path may
#                appear in no artefact except as a sha256: digest.
#   the toolkit  $FLOW_DIR, or a mutant copy of it. The part pack comes from
#                whichever one is under test; the BOARD pack is the project's
#                (CONTRACT.md section 1) and is written here. It names nothing
#                real: this repository may not name a board, and a fixture is
#                part of this repository.
#
# THE FLIST CHAIN is shaped like the reference defect's, scaled down: three
# levels of -f, one +incdir+ contributed by each level, all three dialects, a
# .v that SV_FILES forces to SystemVerilog, a -y directory holding one
# compilation unit and one `include fragment, one site-path source, and one
# two-token simulator-only option. THE NUMBERS THE SUITE KNOWS:
#
#   sources 6   a.v b.sv f.v c.vhd lib/lib_unit.v site/vendor_x.v
#   chain   3   top.f -> sub.f -> subsub.f
#   incdirs 3   inc1 inc2 inc3, one per level
#   defines 1   +define+FLIST_D1
#   -y      1   lib/, which contributes 1 unit and skips 1 fragment
#   ignored 1   -timescale 1ns/1ps
#=============================================================================
P="$SB/p"; PROJ="$P/proj"
mkdir -p "$PROJ/rtl" "$PROJ/inc1" "$PROJ/inc2" "$PROJ/inc3" "$PROJ/lib" \
         "$PROJ/board/testbench-board" "$SB/site/vendor_ip/rel_1.2"

printf 'module a_top; endmodule\n'                  > "$PROJ/rtl/a.v"
printf 'module b_sv; logic x; endmodule\n'          > "$PROJ/rtl/b.sv"
printf 'module forced_sv; endmodule\n'              > "$PROJ/rtl/f.v"
printf 'entity c_vhd is end entity;\n'              > "$PROJ/rtl/c.vhd"
printf 'module brd_top; endmodule\n'                > "$PROJ/rtl/board_top.v"
printf 'module brd_top_sv; endmodule\n'             > "$PROJ/rtl/board_top_sv.v"
printf '%s\n' '`define H1 1'                        > "$PROJ/inc1/h1.vh"
printf '%s\n' '`define H2 1'                        > "$PROJ/inc2/h2.vh"
printf '%s\n' '`define H3 1'                        > "$PROJ/inc3/h3.vh"
printf 'module lib_unit; endmodule\n'               > "$PROJ/lib/lib_unit.v"
printf '%s\n' '`define LIB_FRAGMENT 1' '`undef LIB_FRAGMENT' > "$PROJ/lib/frag_defs.v"
printf 'module vendor_x; endmodule\n'               > "$SB/site/vendor_ip/rel_1.2/vendor_x.v"
SITE_SRC="$SB/site/vendor_ip/rel_1.2/vendor_x.v"
: > "$PROJ/rtl/empty.f"

# Paths inside the chain are FLIST-RELATIVE (the reader's contract, proved by
# t_flist.sh), so the stage's cwd does not matter here - which is also true of
# the real flow, where mk/flow.mk cd's the stage into a work directory that
# holds nothing.
cat > "$PROJ/rtl/top.f" <<EOF
# the top-level filelist of the fixture
+incdir+../inc1
+define+FLIST_D1
a.v
-f sub.f
EOF
cat > "$PROJ/rtl/sub.f" <<EOF
+incdir+../inc2
b.sv
f.v
-f subsub.f
EOF
cat > "$PROJ/rtl/subsub.f" <<EOF
+incdir+../inc3
c.vhd
-y ../lib
$SITE_SRC
-timescale 1ns/1ps
EOF
FIX_SOURCES=6; FIX_CHAIN=3; FIX_INCDIRS=3

# A header listed as a SOURCE: the reader adds its directory to the include
# path and does not read it; the stage must delegate that with an owner.
printf 'a.v\n../inc1/h1.vh\n' > "$PROJ/rtl/hdr.f"

# 205 sources, so the census's 200-per-exec hashing crosses its batch boundary
# with a remainder. Absolute paths: the point is the count, not resolution.
mkdir -p "$PROJ/many"
: > "$PROJ/rtl/many.f"
for i in $(seq 1 205); do
    printf 'module m%03d; endmodule\n' "$i" > "$PROJ/many/m$i.v"
    printf '%s\n' "$PROJ/many/m$i.v" >> "$PROJ/rtl/many.f"
done
FIX_MANY=205

# THE BOARD PACK. The same shape t_packs.sh proves loads and validates.
cat > "$PROJ/board/testbench-board/board.tcl" <<'BOARD_FIXTURE'
# A BOARD PACK FIXTURE for t_stage_flist.sh. Lives in a scratch project, never
# in the toolkit: CONTRACT.md section 1 says a board pack ships with the project.
board_set board_name      testbench-board
board_set part            xck26-sfvc784-2LV-c
board_set platform        bare
board_set sys_clk_freq_hz 50000000
board_set bin_style       zynqmp
board_set oscillator_hz   25000000
board_set board_rev       revA
board_set io_voltage_by_bank {44 1.8 64 3.3}
board_set deploy_style    jtag
board_set board_part "vendor:testbench:part0:1.0"
board_defer board_repo_paths {
    set root [board_env TESTBENCH_BOARD_FILES "the vendor board files for testbench-board"]
    if {![file isdirectory $root]} { error "not a directory: $root" }
    return $root
}
board_note {fixture pack, used by the flist stage suite}
BOARD_FIXTURE
FIX_PART="xck26-sfvc784-2LV-c"

# Two hook directories, one per hook under test, so no run inherits another's
# hook. Both hooks run in the STAGE'S scope (flow_hook uplevels the source), so
# $SOURCES_TCL is the stage's own variable.
mkdir -p "$SB/hooks_extra" "$SB/hooks_truncate"
cat > "$SB/hooks_extra/post_flist.tcl" <<'HOOK'
# a post_flist hook contributing one read command, the documented interface
set ::FLIST_EXTRA_CMDS [list "read_verilog /contributed/by/the/hook.v"]
HOOK
cat > "$SB/hooks_truncate/post_flist.tcl" <<'HOOK'
# a post_flist hook that leaves sources.tcl non-empty and USELESS: a header and
# no read command. `test -s` is satisfied; synthesis would elaborate nothing.
set fh [open $SOURCES_TCL w]
puts $fh "# a sources.tcl with no read command in it"
close $fh
HOOK

#=============================================================================
# THE DRIVER
#
# fl_project writes the project that names the toolkit under test - the real
# one or a mutant - so mk/flow.mk resolves every path against THAT checkout.
# fl_run then asks make for the stage's environment and runs the stage under
# tclsh through flist_drive.tcl, which defines the recording stubs when
# T_STUBS=1 and otherwise nothing at all.
#
# The driver DECIDES NOTHING. It sources the stage and prints what was recorded;
# the predicates read the artefacts. A driver that graded itself would be a
# place for a mutant to pass by making the grader lenient.
#=============================================================================
cat > "$SB/flist_drive.tcl" <<'TCL'
set tk [lindex $::argv 0]
set ::rec {}
if {[info exists ::env(T_STUBS)] && $::env(T_STUBS) eq "1"} {
    # RECORDING STUBS. Each appends the call and does nothing. They prove the
    # stage ISSUED the call; they cannot prove Vivado would have accepted it.
    proc read_verilog    {args} { lappend ::rec "read_verilog $args" }
    proc read_vhdl       {args} { lappend ::rec "read_vhdl $args" }
    proc set_property    {args} { lappend ::rec "set_property $args" }
    proc get_property    {args} { return {} }
    proc current_fileset {args} { return sources_1 }
}
# `source`, not exec: `info script` inside the stage then names the stage file,
# which is how it finds flow_utils.tcl beside itself (its header says why it
# does not go through FPGA_FLOW_DIR). A die or a refuse inside EXITS THIS
# PROCESS; the lines below run only when the stage reached its end.
source [file join $tk flow vivado 1_flist.tcl]
puts "DRIVER: stage reached its end"
puts "RECORDED: [llength $::rec]"
foreach c $::rec { puts "RECORDED: $c" }
TCL

## fl_project <toolkit> - the throwaway project, pointed at <toolkit>.
## Written fresh for every run, because the toolkit changes between runs.
fl_project() {
    local tk="$1"
    t_project "$PROJ" "$tk" demo_block testbench-board || return 2
    # t_project wrote the three-line contract; this is the project's design.mk
    # with the inputs this stage reads. The include is the literal path for the
    # reason t_project's own comment gives.
    cat > "$PROJ/design.mk" <<EOF
FPGA_FLOW_DIR := $tk
BLOCK := demo_block
BOARD := testbench-board
PART := $FIX_PART
RTL_FLIST := \$(FPGA_DIR)/rtl/top.f
TOP := a_top
SV_FILES := \$(FPGA_DIR)/rtl/f.v
include $tk/mk/flow.mk
EOF
}

FL_ENV=(); FL_OUT=""; FL_RC=0
MAN=""; GATE=""; CENSUS=""; SRC=""; RUN_DIR=""
## fl_run <toolkit> <tag> [make VAR=value ...]
##
## Knobs (FLIST_*) and T_STUBS come from the CALLER'S environment and pass
## through `env` untouched, exactly as they reach a stage launched by make.
## Project-contract values (RTL_FLIST, TOP, TOP_HDL, SV_FILES, HOOKS_DIR,
## RTL_DEFINES_NEVER ...) are make overrides, so make resolves and exports them
## the way it would for a project that set them.
##
## Returns non-zero ONLY when make gave no environment. The stage's own exit
## status is in FL_RC and its output in FL_OUT - finding out what the stage did
## is the predicate's job, not the driver's.
fl_run() {
    local tk="$1" tag="$2"; shift 2
    fl_project "$tk" || return 2
    mapfile -t FL_ENV < <(make -C "$PROJ" --no-print-directory "$@" \
                              --eval='p: ; @env' p 2>/dev/null | grep '^FPGA_')
    if [ "${#FL_ENV[@]}" -eq 0 ]; then
        printf 'make -C %s gave no FPGA_ environment for toolkit %s:\n' "$PROJ" "$tk"
        make -C "$PROJ" --no-print-directory "$@" --eval='p: ; @env' p 2>&1 | tail -8
        return 2
    fi
    # The four paths, ASKED OF MAKE through the same dump. The artefact
    # basenames are CONTRACT.md section 4's and the stage's; they are what is
    # under test, so they are the one thing spelled here.
    RUN_DIR="$(printf '%s\n' "${FL_ENV[@]}" | sed -n 's/^FPGA_RUN_DIR=//p')"
    local work rep
    work="$(printf '%s\n' "${FL_ENV[@]}" | sed -n 's/^FPGA_WORK_DIR=//p')"
    rep="$(printf '%s\n' "${FL_ENV[@]}"  | sed -n 's/^FPGA_REPORT_DIR=//p')"
    MAN="$rep/flist_manifest.txt"; GATE="$rep/flist_gate.txt"
    CENSUS="$rep/flist_sources.txt"; SRC="$work/sources.tcl"
    # A fresh run tree every time. The rm is checked against the sandbox list
    # first: this suite tests a stage whose run directory is composed from
    # variables, and a composed path is exactly what must never be rm'd blind.
    if [ -n "$RUN_DIR" ] && t_in_sandbox "$RUN_DIR"; then rm -rf "$RUN_DIR"; fi
    FL_RC=0
    FL_OUT="$(cd "$SB" && env "${FL_ENV[@]}" FPGA_STAGE=flist \
                timeout 120 tclsh "$SB/flist_drive.tcl" "$tk" 2>&1)" || FL_RC=$?
    printf '%s\n' "$FL_OUT" > "$SB/out.$tag"
    return 0
}

## mfv <manifest> <key> - a manifest value read EXACTLY as ci/assert-stage.sh
## reads it (ci_mf in ci/lib.sh). A test that parses the artefact more
## forgivingly than its consumer passes on files the consumer rejects.
mfv() {
    [ -s "$1" ] || return 1
    awk -v k="$2" '$1 == k { $1 = ""; sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); print; exit }' "$1"
}
## gate_bullets <gate> <heading regex> - the section's bullets, with
## assert-stage's own awk: a section ends at the next capitalised line.
gate_bullets() {
    awk -v h="$2" '$0 ~ h { s=1; next } s && /^[A-Z]/ { exit } s && /^  - / { print }' "$1"
}
## src_reads <sources.tcl> - the read commands the next stage would execute
src_reads() { grep -cE '^(read_verilog|read_vhdl|add_files|import_files)\b' "$1"; }
## census_rows <census> - data rows: neither comment nor blank
census_rows() { grep -cvE '^(#|[[:space:]]*$)' "$1"; }
## claimed <what> - the stage said it reached its end
fl_reached_end() { printf '%s' "$FL_OUT" | grep -qF 'DRIVER: stage reached its end'; }
## fl_dump - the tail of the run, for a red line's evidence
fl_dump() { printf '%s\n' "$FL_OUT" | tail -12 | sed 's/^/  | /'; }

## y_mut <name> - a fresh copy of the toolkit, or die loudly
y_mut() {
    local m; m="$(t_mutant "$SB" "$1")"
    [ -n "$m" ] && [ -d "$m" ] || { echo "could not copy the toolkit for '$1'" >&2; return 2; }
    printf '%s' "$m"
}


#=============================================================================
# 1. THE STAGE IS TOOL-FREE, AND SAYS SO WHEN ASKED TO APPLY
#
# The whole premise of this suite. If the stage ever calls a Vivado command
# unguarded, every driver below stops sourcing, and the first assertion to say
# so should be this one rather than twenty red lines about manifests.
#
# Driven with FLIST_APPLY=1 and NO stubs on purpose: that is the one setting
# under which the stage WANTS a tool command, and the contract is that a tool
# without read_verilog gets a warning and a complete stage, not a death.
#=============================================================================
t_head "the stage completes under bare tclsh, and FLIST_APPLY=1 without a tool warns rather than dies"

## toolfree_completes <toolkit>
toolfree_completes() {
    local tk="$1"
    FLIST_APPLY=1 T_STUBS=0 fl_run "$tk" toolfree || return 2
    if [ "$FL_RC" -ne 0 ]; then
        fl_dump
        printf 'exit %d under bare tclsh with FLIST_APPLY=1 and no read_verilog. The stage\n' "$FL_RC"
        printf 'is supposed to be tool-free below flow_boot; a tool that lacks read_verilog\n'
        printf 'must get a WARNING and a finished stage, not an exit.\n'
        return 1
    fi
    fl_reached_end || { fl_dump; printf 'exit 0 but the driver never saw the stage end.\n'; return 1; }
    [ -s "$MAN" ] || { printf 'exit 0 and no manifest at %s.\n' "$MAN"; return 1; }
    printf '%s' "$FL_OUT" | grep -qF 'FLIST_APPLY=1 but this tool has no read_verilog' && return 0
    fl_dump
    printf 'FLIST_APPLY=1 in a tool with no read_verilog completed WITHOUT saying nothing\n'
    printf 'was read. A knob that was set and had no effect must say so in the log.\n'
    return 1
}

t_check fstage.toolfree \
    "with FLIST_APPLY=1 and no read_verilog the stage warns, completes, and writes its manifest" \
    toolfree_completes "$FLOW_DIR"

# The guard removed: flist_apply's own die ("this tool has no read_verilog")
# then kills the stage. That is exit 1 from a helper, not the warning.
M="$(y_mut apply-unguarded)" || M=""
if [ -n "$M" ] && t_replace_line "$M" "$ST_REL" \
        '    if {[flow_have read_verilog]} {' \
        '    if {1} {'; then
    t_check_fail fstage.toolfree.mutation \
        "with the flow_have guard removed the stage dies inside flist_apply under bare tclsh, so the assertion goes red" \
        toolfree_completes "$M"
else
    t_skip fstage.toolfree.mutation \
        "could not plant the fault: the flow_have read_verilog test in section 4.3 has changed shape"
fi


#=============================================================================
# 2. THE BOOT SEQUENCE: REFUSE BEFORE CLAIMING ANYTHING, AND INVENT NOTHING
#
# read_flist.tcl refuses a missing flist too, with a good message - from inside
# a `source`, after the stage has printed "read the filelist". The stage's own
# comment at its flow_assert_input call says the point of asserting here is the
# refusal BEFORE the claim, and that there is deliberately NO "not configured"
# manifest for this stage: RTL_FLIST is required, and a design with no source
# list is no design at all.
#
# So the discriminators are ORDER and EXIT CODE, not the mere fact of refusal:
# an unset flist through the reader is flow_need_env's `die` (exit 1, a check
# failed) where the stage owes exit 2 (nothing was measured); a missing one
# through the reader arrives after the step banner.
#=============================================================================
t_head "an unset, absent or zero-byte RTL_FLIST is refused (exit 2) BEFORE the stage claims to read anything"

## no_artefacts - none of the four outputs exists. Evidence first, verdict last.
no_artefacts() {
    local f bad=""
    for f in "$MAN" "$GATE" "$CENSUS" "$SRC"; do [ -e "$f" ] && bad="$bad $f"; done
    [ -z "$bad" ] && return 0
    printf 'a refused run left artefacts behind:%s\n' "$bad"
    [ -s "$MAN" ] && printf '  file_count in that manifest: %s\n' "$(mfv "$MAN" file_count)"
    printf 'A refusal is "nothing was measured"; an artefact says something was.\n'
    return 1
}
## refused_before_claim - exit 2, and no step banner, and no flist pin
refused_before_claim() {
    if [ "$FL_RC" -ne 2 ]; then
        fl_dump
        printf 'exit %d, not 2. CONTRACT.md section 10: 1 is "a check failed", 2 is "the\n' "$FL_RC"
        printf 'input is unusable and nothing was measured". A missing source list is the second.\n'
        return 1
    fi
    if printf '%s' "$FL_OUT" | grep -qF '==== FLIST: read the filelist'; then
        fl_dump
        printf 'the stage CLAIMED to be reading the filelist before it refused. The refusal\n'
        printf 'came from the reader, inside a source, not from the stage'"'"'s own guard.\n'
        return 1
    fi
    if printf '%s' "$FL_OUT" | grep -qF 'prov: flist pinned'; then
        fl_dump
        printf 'the stage PINNED a provenance hash of a flist it then refused.\n'
        return 1
    fi
    return 0
}

## refuse_unset <toolkit>
refuse_unset() {
    local tk="$1"
    fl_run "$tk" unset RTL_FLIST= || return 2
    refused_before_claim || return 1
    printf '%s' "$FL_OUT" | grep -qF 'RTL_FLIST' || {
        fl_dump; printf 'the refusal does not name RTL_FLIST, the design.mk variable to set.\n'; return 1; }
    no_artefacts
}
## refuse_missing <toolkit>
refuse_missing() {
    local tk="$1"
    fl_run "$tk" missing RTL_FLIST="$PROJ/rtl/no_such_flist.f" || return 2
    refused_before_claim || return 1
    printf '%s' "$FL_OUT" | grep -qF 'no_such_flist.f' || {
        fl_dump; printf 'the refusal does not name the path that is missing.\n'; return 1; }
    no_artefacts
}
## refuse_zerobyte <toolkit>
refuse_zerobyte() {
    local tk="$1"
    fl_run "$tk" zerobyte RTL_FLIST="$PROJ/rtl/empty.f" || return 2
    refused_before_claim || return 1
    printf '%s' "$FL_OUT" | grep -qF 'ZERO BYTES' || {
        fl_dump; printf 'a zero-byte flist was not called ZERO BYTES - the shape a generator leaves\n'
        printf 'when it opened its output and died, and one every test -e accepts.\n'; return 1; }
    printf '%s' "$FL_OUT" | grep -qF 'no file at' && {
        fl_dump; printf 'a zero-byte flist was called ABSENT. Those are two different faults.\n'; return 1; }
    no_artefacts
}

t_check fstage.refuse.unset \
    "RTL_FLIST unset: exit 2 naming RTL_FLIST, before the read banner, and no artefact" \
    refuse_unset "$FLOW_DIR"
t_check fstage.refuse.missing \
    "RTL_FLIST absent: exit 2 naming the path, before the read banner, and no artefact" \
    refuse_missing "$FLOW_DIR"
t_check fstage.refuse.zerobyte \
    "RTL_FLIST zero bytes: exit 2 saying ZERO BYTES and not 'no file at', before the read banner" \
    refuse_zerobyte "$FLOW_DIR"

# -- the guard call deleted (six lines, one fault) ------------------------------
# The stage then falls through to read_flist.tcl, whose flow_need_env DIES on an
# unset flist (exit 1) and whose flist_scan refuses a missing one only after the
# "read the filelist" banner. Both halves of the boot property go red.
M="$(y_mut guard-deleted-unset)" || M=""
if [ -n "$M" ] && t_mutate "$M" "$ST_REL" \
        '/^flow_assert_input \$RTL_FLIST \\$/,/^    RTL_FLIST$/d'; then
    t_check_fail fstage.refuse.unset.mutation \
        "with the stage's flow_assert_input deleted an unset flist reaches the reader's die - exit 1, after the banner - so the assertion goes red" \
        refuse_unset "$M"
else
    t_skip fstage.refuse.unset.mutation \
        "could not plant the fault: the flow_assert_input \$RTL_FLIST call in section 1 has changed shape"
fi
M="$(y_mut guard-deleted-missing)" || M=""
if [ -n "$M" ] && t_mutate "$M" "$ST_REL" \
        '/^flow_assert_input \$RTL_FLIST \\$/,/^    RTL_FLIST$/d'; then
    t_check_fail fstage.refuse.missing.mutation \
        "with the guard deleted a missing flist is refused by the reader AFTER the stage claimed to be reading it, so the assertion goes red" \
        refuse_missing "$M"
else
    t_skip fstage.refuse.missing.mutation \
        "could not plant the fault: the flow_assert_input \$RTL_FLIST call in section 1 has changed shape"
fi
# The zero-byte shape has no proof of its own IN THIS FILE: the line that tells
# zero bytes from absent is flow_assert_input's `file size` test in
# flow_utils.tcl, and t_flow_utils.sh plants that fault (futils.input.zero.
# mutation). Planting the same deletion a third time here would prove the same
# thing a third time.

# -- THE INVENTED COUNT -------------------------------------------------------
# CONTRACT.md section 12.2 rule 7 says a stage that is NOT CONFIGURED writes a
# manifest saying so and exits 0. Applied to THIS stage - whose own comment
# explains why it must not be - that is a manifest with file_count 0 for a
# design nobody read, and ci/assert-stage.sh grades 0 as a measurement. The
# fault planted is exactly that branch, ahead of the guard.
## no_invented_count <toolkit>
no_invented_count() {
    local tk="$1"
    fl_run "$tk" invented RTL_FLIST="$PROJ/rtl/no_such_flist.f" || return 2
    if [ -s "$MAN" ]; then
        printf 'file_count %s\n' "$(mfv "$MAN" file_count)"
        printf 'A MANIFEST WAS WRITTEN FOR A FLIST THAT DOES NOT EXIST (exit %d). ci/assert-\n' "$FL_RC"
        printf 'stage.sh reads file_count with awk and grades a 0 as a measurement, so this run\n'
        printf 'would pass the flist gate having read nothing.\n'
        return 1
    fi
    [ "$FL_RC" -eq 2 ] && return 0
    fl_dump; printf 'no manifest, but exit %d where a refusal is 2.\n' "$FL_RC"; return 1
}

t_check fstage.refuse.no_invented_count \
    "a flist that could not be read leaves NO manifest - no file_count is invented for it" \
    no_invented_count "$FLOW_DIR"

M="$(y_mut rule7-not-configured)" || M=""
if [ -n "$M" ] && t_mutate "$M" "$ST_REL" \
        '/^flow_assert_input \$RTL_FLIST \\$/i\if {$RTL_FLIST eq "" || ![file exists $RTL_FLIST] || ![file size $RTL_FLIST]} { prov_stage_fields [prov_manifest flist] [list file_count 0] ; exit 0 }'; then
    t_check_fail fstage.refuse.no_invented_count.mutation \
        "with a rule-7 'not configured' branch planted ahead of the guard, a missing flist gets a manifest with file_count 0 and exit 0, so the assertion goes red" \
        no_invented_count "$M"
else
    t_skip fstage.refuse.no_invented_count.mutation \
        "could not plant the fault: the flow_assert_input \$RTL_FLIST line in section 1 has changed shape"
fi


#=============================================================================
# 3. BLOCK 8: THE KEY THE CONSUMER READS, AND THE NUMBERS THE FIXTURE KNOWS
#
# ci/assert-stage.sh grades the flist stage on ONE manifest key, file_count,
# read with `awk '$1 == key'`. A stage that spelled it differently would be
# graded UNVERIFIED on a number it took - assert-stage's own message names that
# case. And the numbers are the V1/V2 substitution tell: two wrapper families
# differ in file_count and incdir_count and in nothing a bitstream shows.
#=============================================================================
t_head "block 8: file_count is the consumer's key, and every count matches the fixture"

## manifest_counts <toolkit>
manifest_counts() {
    local tk="$1" k want got bad=""
    fl_run "$tk" base || return 2
    [ "$FL_RC" -eq 0 ] || { fl_dump; printf 'the good-case run exited %d.\n' "$FL_RC"; return 1; }
    [ -s "$MAN" ] || { printf 'no manifest at %s.\n' "$MAN"; return 1; }
    [ "$(mfv "$MAN" stage)" = flist ] || {
        printf "stage field is '%s', not flist - assert-stage would call this a foreign manifest.\\n" "$(mfv "$MAN" stage)"; return 1; }
    got="$(mfv "$MAN" file_count)"
    if [ "$got" != "$FIX_SOURCES" ]; then
        awk '/# 8\./{p=1} p' "$MAN" | sed 's/^/  | /'
        printf "assert-stage reads file_count with awk '\$1 == \"file_count\"' and got '%s';\\n" "$got"
        printf 'the fixture has %d sources. Either the key moved or the count is wrong, and\n' "$FIX_SOURCES"
        printf 'either way the one number the gate reads describes a different design.\n'
        return 1
    fi
    grep -qE '^prov\.file_count' "$MAN" && {
        printf 'file_count is ALSO under the prov. identity prefix, where compare-runs refuses every A/B pair.\n'; return 1; }
    for k in flist_chain:$FIX_CHAIN incdir_count:$FIX_INCDIRS define_count:1 defines:FLIST_D1 \
             ydir_count:1 ydirs_expanded:yes header_count:0 ignored_options:1 \
             sources_cmds:$FIX_SOURCES sources_hashed:$FIX_SOURCES top_hdl_files:0 \
             top_hdl_in_sources:no hard_failures:0 'rtl_flist_gen:(none)'; do
        want="${k#*:}"; got="$(mfv "$MAN" "${k%%:*}")"
        [ "$got" = "$want" ] || bad="$bad
  ${k%%:*}: got '$got', fixture says '$want'"
    done
    [ -z "$bad" ] && return 0
    printf 'block 8 disagrees with the fixture this suite built:%s\n' "$bad"
    return 1
}

t_check fstage.manifest.counts \
    "file_count 6, flist_chain 3, incdir_count 3, define/ydir/ignored 1, headers 0 - as top-level keys" \
    manifest_counts "$FLOW_DIR"

# -- the consumer's key renamed --------------------------------------------------
# The exact drift assert-stage's message describes: "this file and the stage
# script disagree about the key name".
M="$(y_mut file-count-renamed)" || M=""
if [ -n "$M" ] && t_mutate "$M" "$ST_REL" \
        's/^    file_count      \$::flist_files \\$/    n_files         $::flist_files \\/'; then
    t_check_fail fstage.manifest.counts.mutation.key \
        "with file_count spelled n_files the consumer's awk finds nothing, so the assertion goes red" \
        manifest_counts "$M"
else
    t_skip fstage.manifest.counts.mutation.key \
        "could not plant the fault: the file_count line of the prov_stage_fields call has changed shape"
fi
# -- the -f nesting reported from the wrong global ------------------------------
# ::flist_stack is the include stack, EMPTY once the read is over; ::flist_chain
# is every flist read. Two globals with adjacent names and one letter of
# meaning between them: a stage that reads the wrong one reports 0 filelists
# for a 3-deep chain, which is how a generated sub-flist that stopped being
# included would go unnoticed.
M="$(y_mut chain-from-stack)" || M=""
if [ -n "$M" ] && t_mutate "$M" "$ST_REL" \
        's/^    flist_chain     \[llength \$::flist_chain\] \\$/    flist_chain     [llength $::flist_stack] \\/'; then
    t_check_fail fstage.manifest.counts.mutation.chain \
        "with flist_chain read from the (empty) include stack the 3-deep chain reports 0, so the assertion goes red" \
        manifest_counts "$M"
else
    t_skip fstage.manifest.counts.mutation.chain \
        "could not plant the fault: the flist_chain line of the prov_stage_fields call has changed shape"
fi
# -- the incdir count from the -y list -----------------------------------------
M="$(y_mut incdirs-from-ydirs)" || M=""
if [ -n "$M" ] && t_mutate "$M" "$ST_REL" \
        's/^    incdir_count    \[llength \$::flist_incdirs\] \\$/    incdir_count    [llength $::flist_ydirs] \\/'; then
    t_check_fail fstage.manifest.counts.mutation.incdir \
        "with incdir_count taken from the -y list the 3 include dirs report as 1, so the assertion goes red" \
        manifest_counts "$M"
else
    t_skip fstage.manifest.counts.mutation.incdir \
        "could not plant the fault: the incdir_count line of the prov_stage_fields call has changed shape"
fi


#=============================================================================
# 4. THE THREE ARTEFACTS AGREE
#
# file_count comes from the reader's counter, sources.tcl from the reader's
# emitter, the census from the stage's own loop over ::flist_files_read, and
# sources_cmds from the stage re-opening sources.tcl and counting. Four numbers,
# three loops. The suite counts two of them ITSELF - read commands in
# sources.tcl, data rows in the census - so a loop that dropped a file is caught
# by an artefact that did not.
#=============================================================================
t_head "manifest file_count, sources.tcl read commands and census rows all agree"

## artefacts_agree <toolkit>
artefacts_agree() {
    local tk="$1" fc reads rows cmds
    fl_run "$tk" agree || return 2
    [ "$FL_RC" -eq 0 ] || { fl_dump; printf 'the run exited %d.\n' "$FL_RC"; return 1; }
    fc="$(mfv "$MAN" file_count)"; cmds="$(mfv "$MAN" sources_cmds)"
    reads="$(src_reads "$SRC")"; rows="$(census_rows "$CENSUS")"
    printf 'file_count=%s sources_cmds=%s sources.tcl reads=%s census rows=%s (fixture %d)\n' \
        "$fc" "$cmds" "$reads" "$rows" "$FIX_SOURCES"
    [ "$fc" = "$FIX_SOURCES" ] && [ "$cmds" = "$fc" ] && [ "$reads" = "$fc" ] && [ "$rows" = "$fc" ] && return 0
    printf 'the artefacts DISAGREE about how many files this run read. Each is the whole\n'
    printf 'evidence to a different reader, and one of them describes a design this run\n'
    printf 'did not build.\n'
    return 1
}

t_check fstage.artefacts.agree \
    "file_count == sources_cmds == read commands in sources.tcl == data rows in flist_sources.txt" \
    artefacts_agree "$FLOW_DIR"

# The census loop skipping its first file. Manifest and sources.tcl still say 6.
M="$(y_mut census-drops-first)" || M=""
if [ -n "$M" ] && t_replace_line "$M" "$ST_REL" \
        'foreach f $::flist_files_read {' \
        'foreach f [lrange $::flist_files_read 1 end] {'; then
    t_check_fail fstage.artefacts.agree.mutation \
        "with the census loop starting at the second file, 5 rows stand against a file_count of 6 and the assertion goes red" \
        artefacts_agree "$M"
else
    t_skip fstage.artefacts.agree.mutation \
        "could not plant the fault: the census emission loop in section 5 has changed shape"
fi


#=============================================================================
# 5. THE CENSUS IS EVIDENCE
#
# One row per file: a real sha256, the byte count, and the path through the
# site-path rule. The hash is compared against sha256sum run BY THIS SUITE on
# the same file - not against the stage's idea of it. The batch boundary is
# crossed on purpose: 205 files against an exec-per-200 loop, because the
# remainder after the last full batch is the part such loops forget.
#=============================================================================
t_head "every census row is a real hash; a site path is a digest; hashing off is 'unmeasured'"

## census_hashes <toolkit>
census_hashes() {
    local tk="$1" h b
    fl_run "$tk" census || return 2
    [ "$FL_RC" -eq 0 ] || { fl_dump; printf 'the run exited %d.\n' "$FL_RC"; return 1; }
    [ -s "$CENSUS" ] || { printf 'no census at %s.\n' "$CENSUS"; return 1; }
    h="$(sha256sum "$PROJ/rtl/a.v" | cut -c1-64)"; b="$(wc -c < "$PROJ/rtl/a.v")"
    grep -qE "^${h}[[:space:]]+${b}[[:space:]]+<project>/rtl/a\.v\$" "$CENSUS" && {
        # ...and no row is a hash nobody took.
        if grep -qE 'UNVERIFIED' "$CENSUS"; then
            grep -nE 'UNVERIFIED' "$CENSUS" | sed 's/^/  | /'
            printf 'rows of a 6-file census are UNVERIFIED - sha256sum was run and its answer\n'
            printf 'was not matched back to the file it hashed.\n'; return 1
        fi
        return 0
    }
    grep -vE '^#' "$CENSUS" | sed 's/^/  | /'
    printf 'no census row is  <sha256sum of rtl/a.v>  <%s bytes>  <project>/rtl/a.v\n' "$b"
    printf 'expected hash %s\n' "$h"
    printf 'A census whose hashes do not match the files is not a census.\n'
    return 1
}

## census_site_digest <toolkit>
census_site_digest() {
    local tk="$1" f
    fl_run "$tk" site || return 2
    [ "$FL_RC" -eq 0 ] || { fl_dump; printf 'the run exited %d.\n' "$FL_RC"; return 1; }
    for f in "$CENSUS" "$MAN" "$GATE" ; do
        if grep -qF -- "$SB/site" "$f"; then
            grep -nF -- "$SB/site" "$f" | sed 's/^/  | /'
            printf 'A SITE PATH IS IN CLEAR in %s. A path outside the project, the toolkit\n' "$(basename "$f")"
            printf 'and the run tree is a vendor mount point, and a manifest gets pasted into\n'
            printf 'bug reports (CONTRACT.md section 5).\n'
            return 1
        fi
    done
    grep -qE '^[0-9a-f]{64}[[:space:]]+[0-9]+[[:space:]]+sha256:[0-9a-f]{64}$' "$CENSUS" && return 0
    grep -vE '^#' "$CENSUS" | sed 's/^/  | /'
    printf 'the site source has no row of the form <hash> <bytes> sha256:<digest>.\n'
    return 1
}

## census_batches <toolkit> - 205 files, all hashed, none UNVERIFIED
census_batches() {
    local tk="$1" hashed rows
    fl_run "$tk" many RTL_FLIST="$PROJ/rtl/many.f" TOP=m001 || return 2
    [ "$FL_RC" -eq 0 ] || { fl_dump; printf 'the 205-file run exited %d.\n' "$FL_RC"; return 1; }
    hashed="$(mfv "$MAN" sources_hashed)"
    rows="$(grep -cE '^[0-9a-f]{64}[[:space:]]' "$CENSUS")"
    printf 'file_count=%s sources_hashed=%s hashed rows=%s UNVERIFIED rows=%s\n' \
        "$(mfv "$MAN" file_count)" "$hashed" "$rows" "$(grep -c UNVERIFIED "$CENSUS")"
    [ "$hashed" = "$FIX_MANY" ] && [ "$rows" = "$FIX_MANY" ] && return 0
    printf 'not every file crossed the 200-per-exec batch boundary with a hash. The rows\n'
    printf 'after the last full batch are the ones a batching loop forgets.\n'
    return 1
}

## hash_off_unmeasured <toolkit>
hash_off_unmeasured() {
    local tk="$1" v
    FLIST_HASH_SOURCES=0 fl_run "$tk" nohash || return 2
    [ "$FL_RC" -eq 0 ] || { fl_dump; printf 'the run exited %d.\n' "$FL_RC"; return 1; }
    v="$(mfv "$MAN" sources_hashed)"
    if [ "$v" != "unmeasured" ]; then
        printf "sources_hashed is '%s' with FLIST_HASH_SOURCES=0. Nobody hashed anything, and\\n" "$v"
        printf 'CONTRACT.md rule 2 makes that the literal token unmeasured - a 0 is a\n'
        printf 'measurement, and ci_is_measured grades it as one.\n'
        return 1
    fi
    grep -qE '^unhashed\(FLIST_HASH_SOURCES=0\)' "$CENSUS" && return 0
    grep -vE '^#' "$CENSUS" | head -3 | sed 's/^/  | /'
    printf 'the census rows do not say the hash was not taken.\n'
    return 1
}

t_check fstage.census.hashes \
    "a census row is <sha256sum of the file> <bytes> <project>/rtl/a.v, and no row is UNVERIFIED" \
    census_hashes "$FLOW_DIR"
t_check fstage.census.site_digest \
    "a source outside project, toolkit and run tree is a sha256: digest in the census and in clear nowhere" \
    census_site_digest "$FLOW_DIR"
t_check fstage.census.batches \
    "205 sources: every one hashed across the 200-per-exec batch boundary, sources_hashed 205" \
    census_batches "$FLOW_DIR"
t_check fstage.census.hash_off \
    "FLIST_HASH_SOURCES=0 writes sources_hashed 'unmeasured' - not 0 - and marks every row unhashed" \
    hash_off_unmeasured "$FLOW_DIR"

# The remainder batch never hashed. On 6 files that is every file.
M="$(y_mut tail-batch-dead)" || M=""
if [ -n "$M" ] && t_replace_line "$M" "$ST_REL" \
        '    if {[llength $batch] && ![catch {exec sha256sum -- {*}$batch} out]} {' \
        '    if {0} {'; then
    t_check_fail fstage.census.hashes.mutation \
        "with the remainder batch never hashed every row of a 6-file census is UNVERIFIED, so the assertion goes red" \
        census_hashes "$M"
else
    t_skip fstage.census.hashes.mutation \
        "could not plant the fault: the remainder-batch sha256sum line in section 5 has changed shape"
fi
# The full-batch parse neutered: the first 200 of 205 go unaccounted.
M="$(y_mut full-batch-unparsed)" || M=""
if [ -n "$M" ] && t_replace_line "$M" "$ST_REL" \
        '                    if {[regexp {^([0-9a-f]{64})[ *]+(.*)$} [string trim $line] -> h p]} {' \
        '                    if {0} {'; then
    t_check_fail fstage.census.batches.mutation \
        "with the full-batch output no longer parsed the first 200 files are UNVERIFIED and the last 5 hashed, so the assertion goes red" \
        census_batches "$M"
else
    t_skip fstage.census.batches.mutation \
        "could not plant the fault: the full-batch regexp line in section 5 has changed shape"
fi
# The stage writing the path raw - bypassing the ONE place the disclosure
# decision is made. provenance.tcl's rule is proved in t_provenance.sh; this
# proves the stage goes THROUGH it.
M="$(y_mut census-raw-path)" || M=""
if [ -n "$M" ] && t_replace_line "$M" "$ST_REL" \
        '    puts $fh [format "%-64s %-12s %s" $h $b [prov_site_path $f]]' \
        '    puts $fh [format "%-64s %-12s %s" $h $b $f]'; then
    t_check_fail fstage.census.site_digest.mutation \
        "with the census writing paths raw the vendor mount point lands in clear, so the assertion goes red" \
        census_site_digest "$M"
else
    t_skip fstage.census.site_digest.mutation \
        "could not plant the fault: the census row format line in section 5 has changed shape"
fi
# A knob-off count written as 0. CONTRACT.md rule 2 from the stage's side.
M="$(y_mut hash-off-is-zero)" || M=""
if [ -n "$M" ] && t_mutate "$M" "$ST_REL" \
        's/^    sources_hashed  \[expr {\$FLIST_HASH_SOURCES ? \$n_hashed : "unmeasured"}\] \\$/    sources_hashed  $n_hashed \\/'; then
    t_check_fail fstage.census.hash_off.mutation \
        "with sources_hashed written as the counter regardless, hashing-off reads as a measured 0 and the assertion goes red" \
        hash_off_unmeasured "$M"
else
    t_skip fstage.census.hash_off.mutation \
        "could not plant the fault: the sources_hashed line of the prov_stage_fields call has changed shape"
fi


#=============================================================================
# 6. THE GATE: FOUR CLASSES, OWNED DELEGATIONS, AND A HARD FAILURE THAT COUNTS
#
# prov_gate's structure is t_provenance.sh's to prove. What the STAGE owns is
# what it puts in each class: that every delegation it writes carries an owner
# (assert-stage FAILS one without), and that a hard failure it finds is counted,
# listed, written to disk BEFORE the exit 1, and mirrored in the manifest.
#=============================================================================
t_head "the gate: title, identity, four sections, every delegation owned"

## gate_structure <toolkit>
gate_structure() {
    local tk="$1" d unowned n
    fl_run "$tk" gate || return 2
    [ "$FL_RC" -eq 0 ] || { fl_dump; printf 'the run exited %d.\n' "$FL_RC"; return 1; }
    [ -s "$GATE" ] || { printf 'no gate at %s.\n' "$GATE"; return 1; }
    head -1 "$GATE" | grep -qE '^FLIST gate, ' || {
        head -2 "$GATE" | sed 's/^/  | /'; printf 'the title does not name the stage.\n'; return 1; }
    sed -n 2p "$GATE" | grep -qF 'design demo_block, run tag default, board testbench-board, part '"$FIX_PART" || {
        sed -n 2p "$GATE" | sed 's/^/  | /'; printf 'the identity line does not carry design, run tag, board and part.\n'; return 1; }
    grep -qE '^HARD FAILURES: none$' "$GATE" || {
        grep -n 'HARD FAILURES' "$GATE" | sed 's/^/  | /'
        printf 'a clean run does not carry the exact string mk/flow.mk greps for.\n'; return 1; }
    for d in '^BUDGETS EXCEEDED' '^DECLARED ELSEWHERE - MEASURED HERE, OWNED BY SOMEBODY ELSE' \
             '^NOT covered by ANY run of this flow, at any setting:'; do
        grep -qE -- "$d" "$GATE" || { printf 'no section /%s/ - absent is not empty.\n' "$d"; return 1; }
    done
    n="$(gate_bullets "$GATE" '^NOT covered by ANY run' | grep -c .)"
    [ "$n" -ge 1 ] || { printf 'the NOT-covered section is empty; no flow covers everything.\n'; return 1; }
    # The fixture produces two delegations (an ignored option, a define). Each
    # must carry owner=, read with assert-stage's own awk.
    d="$(gate_bullets "$GATE" '^DECLARED ELSEWHERE')"
    n="$(printf '%s\n' "$d" | grep -c .)"
    [ "$n" -ge 2 ] || {
        printf '%s\n' "$d" | sed 's/^/  | /'
        printf '%s delegated bullet(s); the fixture has an ignored option AND a define, so 2.\n' "$n"; return 1; }
    unowned="$(printf '%s\n' "$d" | grep -v 'owner=')"
    [ -z "$unowned" ] && return 0
    printf '%s\n' "$unowned" | sed 's/^/  | /'
    printf 'a delegation WITHOUT owner=. "Somebody else measures this" with no somebody\n'
    printf 'is how a thing comes to be measured by nobody; assert-stage FAILS it.\n'
    return 1
}

t_check fstage.gate.structure \
    "FLIST gate title, identity line, 'HARD FAILURES: none', all four sections, and every delegation owner=" \
    gate_structure "$FLOW_DIR"

M="$(y_mut delegation-unowned)" || M=""
if [ -n "$M" ] && t_mutate "$M" "$ST_REL" \
        's/had NO effect, owner=the project that wrote the flist:/had NO effect, by the project that wrote the flist:/'; then
    t_check_fail fstage.gate.structure.mutation \
        "with owner= dropped from the ignored-option delegation the bullet names nobody, so the assertion goes red" \
        gate_structure "$M"
else
    t_skip fstage.gate.structure.mutation \
        "could not plant the fault: the ignored-options delegation text in section 7 has changed shape"
fi

t_head "a TOP nothing declares is a HARD failure: exit 1, counted, listed, on disk first"

## top_undeclared_hard <toolkit>
top_undeclared_hard() {
    local tk="$1" b
    fl_run "$tk" notop TOP=no_such_top || return 2
    if [ "$FL_RC" -ne 1 ]; then
        fl_dump
        printf 'exit %d, not 1, for a TOP that no file read declares. Vivado picks a top by\n' "$FL_RC"
        printf 'heuristic and warns, and the run then reports numbers about a different design.\n'
        return 1
    fi
    for b in "$MAN" "$GATE" "$CENSUS"; do
        [ -s "$b" ] || { printf 'no %s - the evidence was not on disk before the exit 1.\n' "$b"; return 1; }
    done
    grep -qE '^HARD FAILURES: 1$' "$GATE" || {
        grep -n 'HARD FAILURES' "$GATE" | sed 's/^/  | /'; printf 'the hard failure is not COUNTED.\n'; return 1; }
    gate_bullets "$GATE" '^HARD FAILURES' | grep -qF "TOP='no_such_top'" || {
        sed -n '/^HARD/,/^BUDGETS/p' "$GATE" | sed 's/^/  | /'; printf 'the bullet does not name the TOP.\n'; return 1; }
    [ "$(mfv "$MAN" hard_failures)" = 1 ] || {
        printf "manifest hard_failures is '%s', gate says 1.\\n" "$(mfv "$MAN" hard_failures)"; return 1; }
    [ "$(mfv "$MAN" top_declared_in)" = "UNVERIFIED:not-declared-by-any-file-read" ] && return 0
    printf "top_declared_in is '%s' for a TOP nothing declares.\\n" "$(mfv "$MAN" top_declared_in)"
    return 1
}

t_check fstage.gate.hard.top \
    "TOP=no_such_top: exit 1, 'HARD FAILURES: 1' naming it, manifest hard_failures 1, all three artefacts on disk" \
    top_undeclared_hard "$FLOW_DIR"

M="$(y_mut top-not-hard)" || M=""
if [ -n "$M" ] && t_mutate "$M" "$ST_REL" \
        's/^        lappend hard "TOP=/        set __mutation_swallowed "TOP=/'; then
    t_check_fail fstage.gate.hard.top.mutation \
        "with the finding no longer appended to the hard list the run exits 0 with 'HARD FAILURES: none', so the assertion goes red" \
        top_undeclared_hard "$M"
else
    t_skip fstage.gate.hard.top.mutation \
        "could not plant the fault: the lappend hard line in section 4.1 has changed shape"
fi


#=============================================================================
# 7. TOP_HDL: RESOLVED WHATEVER THE KNOB SAYS, AND APPENDED ONLY WHEN IT SAYS
#
# The stage's own comment records the defect its first version had: TOP_HDL was
# resolved only inside the append branch, so with FLIST_TOP_IN_SOURCES=0 - the
# default, and the commonest configuration there is - a board top living in
# TOP_HDL was reported as declared nowhere. A FALSE HARD FAILURE on the default
# path. Both halves are asserted: the file is checked and scanned with the knob
# OFF, and appended to sources.tcl only with it ON (4_synth.tcl reads TOP_HDL
# itself, so appending by default would read every board top TWICE).
#=============================================================================
t_head "TOP_HDL: checked and scanned with the knob off; appended, once, with it on"

## top_in_tophdl_only <toolkit>
top_in_tophdl_only() {
    local tk="$1"
    fl_run "$tk" tophdl TOP=brd_top TOP_HDL="$PROJ/rtl/board_top.v" || return 2
    if [ "$FL_RC" -ne 0 ]; then
        sed -n '/^HARD/,/^BUDGETS/p' "$GATE" 2>/dev/null | sed 's/^/  | /'
        printf 'exit %d with TOP declared in TOP_HDL and FLIST_TOP_IN_SOURCES=0. That is the\n' "$FL_RC"
        printf 'false hard failure on the default configuration that the stage records fixing.\n'
        return 1
    fi
    [ "$(mfv "$MAN" top_declared_in)" = "<project>/rtl/board_top.v" ] || {
        printf "top_declared_in is '%s', not <project>/rtl/board_top.v.\\n" "$(mfv "$MAN" top_declared_in)"; return 1; }
    [ "$(mfv "$MAN" top_hdl_files)" = 1 ] || {
        printf "top_hdl_files is '%s', not 1.\\n" "$(mfv "$MAN" top_hdl_files)"; return 1; }
    [ "$(mfv "$MAN" top_hdl_in_sources)" = no ] || {
        printf "top_hdl_in_sources is '%s' with the knob off.\\n" "$(mfv "$MAN" top_hdl_in_sources)"; return 1; }
    [ "$(src_reads "$SRC")" = "$FIX_SOURCES" ] && return 0
    tail -3 "$SRC" | sed 's/^/  | /'
    printf 'sources.tcl carries %s read commands for %d flist sources: TOP_HDL was APPENDED\n' "$(src_reads "$SRC")" "$FIX_SOURCES"
    printf 'with FLIST_TOP_IN_SOURCES=0. 4_synth.tcl reads TOP_HDL itself, so this board\n'
    printf 'top would be read twice - a duplicate module definition at elaboration.\n'
    return 1
}

## top_hdl_appended <toolkit>
top_hdl_appended() {
    local tk="$1" last
    FLIST_TOP_IN_SOURCES=1 fl_run "$tk" tophdl_in TOP=brd_top TOP_HDL="$PROJ/rtl/board_top.v" || return 2
    [ "$FL_RC" -eq 0 ] || { fl_dump; printf 'the run exited %d.\n' "$FL_RC"; return 1; }
    [ "$(mfv "$MAN" top_hdl_in_sources)" = yes ] || {
        printf "top_hdl_in_sources is '%s' with the knob on.\\n" "$(mfv "$MAN" top_hdl_in_sources)"; return 1; }
    # The read is the LAST one - after the flist's, which is what "read AFTER
    # the flist" (CONTRACT.md 3.3) means - and it is counted.
    last="$(grep -E '^(read_verilog|read_vhdl)\b' "$SRC" | tail -1)"
    [ "$last" = "read_verilog $PROJ/rtl/board_top.v" ] || {
        tail -4 "$SRC" | sed 's/^/  | /'; printf "the last read command is '%s', not the board top.\\n" "$last"; return 1; }
    [ "$(src_reads "$SRC")" = "$((FIX_SOURCES + 1))" ] || {
        printf 'sources.tcl carries %s reads, not %d.\n' "$(src_reads "$SRC")" "$((FIX_SOURCES + 1))"; return 1; }
    [ "$(mfv "$MAN" sources_cmds)" = "$((FIX_SOURCES + 1))" ] && return 0
    printf "sources_cmds is '%s', not %d - the manifest did not count the append.\\n" "$(mfv "$MAN" sources_cmds)" "$((FIX_SOURCES + 1))"
    return 1
}

## top_hdl_missing_refused <toolkit> - with the knob OFF
top_hdl_missing_refused() {
    local tk="$1"
    fl_run "$tk" tophdl_missing TOP_HDL="$PROJ/rtl/no_such_top.v" || return 2
    if [ "$FL_RC" -ne 2 ]; then
        fl_dump
        printf 'exit %d for a TOP_HDL that names a file which is not there, with the append\n' "$FL_RC"
        printf 'knob off. CONTRACT.md 3.3: you named it, so it must exist - and this is the\n'
        printf 'stage that exists to find a source-list problem in seconds, not in stage 4.\n'
        return 1
    fi
    printf '%s' "$FL_OUT" | grep -qF 'TOP_HDL' && return 0
    fl_dump; printf 'refused, but without naming TOP_HDL as the variable that pointed at it.\n'; return 1
}

t_check fstage.tophdl.scanned_knob_off \
    "TOP declared only in TOP_HDL with FLIST_TOP_IN_SOURCES=0: found, recorded, and NOT appended" \
    top_in_tophdl_only "$FLOW_DIR"
t_check fstage.tophdl.appended_knob_on \
    "with FLIST_TOP_IN_SOURCES=1 the board top is the LAST read in sources.tcl and sources_cmds counts it" \
    top_hdl_appended "$FLOW_DIR"
t_check fstage.tophdl.missing_refused \
    "a TOP_HDL naming an absent file is refused (exit 2) naming TOP_HDL, with the knob off" \
    top_hdl_missing_refused "$FLOW_DIR"

# THE RECORDED DEFECT, PUT BACK: TOP_HDL not a candidate for the TOP scan.
M="$(y_mut tophdl-not-scanned)" || M=""
if [ -n "$M" ] && t_replace_line "$M" "$ST_REL" \
        '    foreach t $tophdl_files { lappend top_candidates [lindex $t 1] }' \
        '    # mutation: TOP_HDL files are not candidates'; then
    t_check_fail fstage.tophdl.scanned_knob_off.mutation.scan \
        "with TOP_HDL files dropped from the TOP scan a board top in TOP_HDL is a false hard failure, so the assertion goes red" \
        top_in_tophdl_only "$M"
else
    t_skip fstage.tophdl.scanned_knob_off.mutation.scan \
        "could not plant the fault: the top_candidates line in section 4.1 has changed shape"
fi
# The append no longer gated by the knob: designs A and B both on.
M="$(y_mut append-ungated)" || M=""
if [ -n "$M" ] && t_replace_line "$M" "$ST_REL" \
        'if {$FLIST_TOP_IN_SOURCES && [llength $tophdl_files]} {' \
        'if {[llength $tophdl_files]} {'; then
    t_check_fail fstage.tophdl.scanned_knob_off.mutation.append \
        "with the append no longer gated by the knob the board top is appended by default - read twice - so the assertion goes red" \
        top_in_tophdl_only "$M"
else
    t_skip fstage.tophdl.scanned_knob_off.mutation.append \
        "could not plant the fault: the FLIST_TOP_IN_SOURCES test in section 3 has changed shape"
fi
# The append branch that says yes and writes nothing.
M="$(y_mut append-writes-nothing)" || M=""
if [ -n "$M" ] && t_replace_line "$M" "$ST_REL" \
        '        puts $fh $cmd' \
        '        set __mutation_dropped $cmd'; then
    t_check_fail fstage.tophdl.appended_knob_on.mutation \
        "with the append branch recording the file but writing no read command, sources.tcl lacks the board top and the assertion goes red" \
        top_hdl_appended "$M"
else
    t_skip fstage.tophdl.appended_knob_on.mutation \
        "could not plant the fault: the puts of the read command in section 3 has changed shape"
fi
# The resolve loop pulled back inside the knob: the first version's shape.
M="$(y_mut resolve-inside-knob)" || M=""
if [ -n "$M" ] && t_replace_line "$M" "$ST_REL" \
        'foreach {var val} [list TOP_HDL $TOP_HDL EXTRA_SRCS $EXTRA_SRCS] {' \
        'foreach {var val} [expr {$FLIST_TOP_IN_SOURCES ? [list TOP_HDL $TOP_HDL EXTRA_SRCS $EXTRA_SRCS] : {}}] {'; then
    t_check_fail fstage.tophdl.missing_refused.mutation \
        "with TOP_HDL resolved only when the append knob is on, a missing board top passes the default path, so the assertion goes red" \
        top_hdl_missing_refused "$M"
else
    t_skip fstage.tophdl.missing_refused.mutation \
        "could not plant the fault: the TOP_HDL/EXTRA_SRCS resolve loop in section 3 has changed shape"
fi

#=============================================================================
# SV_FILES: A .v FORCED TO SystemVerilog, IN THE FLIST AND IN TOP_HDL
#
# CONTRACT.md 3.3: "force file_type SystemVerilog per file". Two code paths
# implement it - flist_read_source for a flist entry, and the stage's own
# TOP_HDL/EXTRA_SRCS loop - and t_flist.sh covers neither, so both are here.
# `read_verilog -sv` on a Verilog-2001 file makes `logic`, `bit`, `do`, `ref`
# reserved words; the OTHER direction - a file that needs -sv read without it -
# is a parse error at elaboration with no mention of SV_FILES.
#=============================================================================
t_head "SV_FILES forces read_verilog -sv on a .v - in the flist, and in TOP_HDL"

## sv_forced_in_flist <toolkit> - rtl/f.v is in SV_FILES by design.mk
sv_forced_in_flist() {
    local tk="$1"
    fl_run "$tk" svflist || return 2
    [ "$FL_RC" -eq 0 ] || { fl_dump; printf 'the run exited %d.\n' "$FL_RC"; return 1; }
    grep -qxF -- "read_verilog -sv $PROJ/rtl/f.v" "$SRC" && return 0
    grep -F 'f.v' "$SRC" | sed 's/^/  | /'
    printf 'rtl/f.v is named in SV_FILES and was not read with -sv.\n'
    return 1
}
## sv_forced_in_tophdl <toolkit>
sv_forced_in_tophdl() {
    local tk="$1"
    FLIST_TOP_IN_SOURCES=1 fl_run "$tk" svtop TOP=brd_top_sv TOP_HDL="$PROJ/rtl/board_top_sv.v" \
        SV_FILES="$PROJ/rtl/f.v $PROJ/rtl/board_top_sv.v" || return 2
    [ "$FL_RC" -eq 0 ] || { fl_dump; printf 'the run exited %d.\n' "$FL_RC"; return 1; }
    grep -qxF -- "read_verilog -sv $PROJ/rtl/board_top_sv.v" "$SRC" && return 0
    grep -F 'board_top_sv' "$SRC" | sed 's/^/  | /'
    printf 'a .v TOP_HDL named in SV_FILES was appended without -sv.\n'
    return 1
}

t_check fstage.sv_files.flist \
    "a .v in the flist that SV_FILES names is emitted as read_verilog -sv" \
    sv_forced_in_flist "$FLOW_DIR"
t_check fstage.sv_files.tophdl \
    "a .v TOP_HDL that SV_FILES names is appended as read_verilog -sv" \
    sv_forced_in_tophdl "$FLOW_DIR"

M="$(y_mut sv-files-ignored-reader)" || M=""
if [ -n "$M" ] && t_replace_line "$M" "$RF_REL" \
        '                if {$s ne "" && [file normalize $s] eq $r} { set forced 1 ; break }' \
        '                if {0} { set forced 1 ; break }'; then
    t_check_fail fstage.sv_files.flist.mutation \
        "with the reader's SV_FILES comparison dead the forced .v is read as plain Verilog, so the assertion goes red" \
        sv_forced_in_flist "$M"
else
    t_skip fstage.sv_files.flist.mutation \
        "could not plant the fault: the SV_FILES comparison in flist_read_source() has changed shape"
fi
M="$(y_mut sv-files-ignored-stage)" || M=""
if [ -n "$M" ] && t_replace_line "$M" "$ST_REL" \
        '        } elseif {$ext eq ".sv" || $ext eq ".svh" || [lsearch -exact $sv $n] >= 0} {' \
        '        } elseif {$ext eq ".sv" || $ext eq ".svh"} {'; then
    t_check_fail fstage.sv_files.tophdl.mutation \
        "with the stage's SV_FILES clause dropped the forced board top is appended without -sv, so the assertion goes red" \
        sv_forced_in_tophdl "$M"
else
    t_skip fstage.sv_files.tophdl.mutation \
        "could not plant the fault: the dialect test in section 3's TOP_HDL loop has changed shape"
fi


#=============================================================================
# 8. DEFINES: RECORDED, AND RTL_DEFINES_NEVER ASSERTED OVER THE WIDER SET
#
# flow/steps/synth_setup.tcl makes the same assertion over the defines it is
# about to pass to synth_design. RTL_DEFINES_INBODY NEVER REACHES THAT LIST:
# those defines are baked into materialised copies of the RTL by stage 2
# (CONTRACT.md 9.2), so a name asserted absent and delivered in-body passes
# every check in the flow but this one.
#=============================================================================
t_head "defines are recorded; RTL_DEFINES_NEVER catches the flist AND RTL_DEFINES_INBODY"

## defines_recorded <toolkit>
defines_recorded() {
    local tk="$1"
    fl_run "$tk" defs RTL_DEFINES=EXTRA_D=2 || return 2
    [ "$FL_RC" -eq 0 ] || { fl_dump; printf 'the run exited %d.\n' "$FL_RC"; return 1; }
    [ "$(mfv "$MAN" define_count)" = 2 ] || {
        printf "define_count is '%s' for +define+FLIST_D1 plus RTL_DEFINES=EXTRA_D=2.\\n" "$(mfv "$MAN" define_count)"; return 1; }
    [ "$(mfv "$MAN" defines)" = "EXTRA_D=2 FLIST_D1" ] || {
        printf "defines is '%s', not 'EXTRA_D=2 FLIST_D1'.\\n" "$(mfv "$MAN" defines)"; return 1; }
    # ...and with none at all, the explicit token, not a blank.
    fl_run "$tk" nodefs RTL_FLIST="$PROJ/rtl/hdr.f" || return 2
    [ "$FL_RC" -eq 0 ] || { fl_dump; printf 'the no-define run exited %d.\n' "$FL_RC"; return 1; }
    [ "$(mfv "$MAN" defines)" = "(none)" ] && return 0
    printf "defines is '%s' with no define anywhere; (none) is the token for explicitly nothing.\\n" "$(mfv "$MAN" defines)"
    return 1
}
## never_in_flist <toolkit>
never_in_flist() {
    local tk="$1"
    fl_run "$tk" never RTL_DEFINES_NEVER=FLIST_D1 || return 2
    [ "$FL_RC" -eq 1 ] || { fl_dump; printf 'exit %d, not 1, for a define asserted ABSENT and present in the flist.\n' "$FL_RC"; return 1; }
    gate_bullets "$GATE" '^HARD FAILURES' | grep -F "'FLIST_D1'" | grep -qF 'the flist / RTL_DEFINES' && return 0
    sed -n '/^HARD/,/^BUDGETS/p' "$GATE" | sed 's/^/  | /'
    printf 'no hard failure names FLIST_D1 as present in the flist.\n'
    return 1
}
## never_in_inbody <toolkit>
never_in_inbody() {
    local tk="$1"
    fl_run "$tk" never_inbody RTL_DEFINES_NEVER=SECRET RTL_DEFINES_INBODY=SECRET=1 || return 2
    [ "$FL_RC" -eq 1 ] || {
        fl_dump
        printf 'exit %d, not 1, for a define asserted ABSENT and delivered by RTL_DEFINES_INBODY.\n' "$FL_RC"
        printf 'In-body defines never reach synth_setup.tcl'"'"'s list, so this is the ONLY check\n'
        printf 'in the flow that can see this one.\n'; return 1; }
    gate_bullets "$GATE" '^HARD FAILURES' | grep -F "'SECRET'" | grep -qF 'RTL_DEFINES_INBODY' && return 0
    sed -n '/^HARD/,/^BUDGETS/p' "$GATE" | sed 's/^/  | /'
    printf 'no hard failure names SECRET as present in RTL_DEFINES_INBODY.\n'
    return 1
}

t_check fstage.defines.recorded \
    "define_count and defines carry the flist's and RTL_DEFINES's defines; none at all is '(none)'" \
    defines_recorded "$FLOW_DIR"
t_check fstage.defines.never.flist \
    "RTL_DEFINES_NEVER naming a flist +define+ is a hard failure (exit 1) naming both" \
    never_in_flist "$FLOW_DIR"
t_check fstage.defines.never.inbody \
    "RTL_DEFINES_NEVER naming an RTL_DEFINES_INBODY define is a hard failure too - the set synth_setup cannot see" \
    never_in_inbody "$FLOW_DIR"

M="$(y_mut defines-always-none)" || M=""
if [ -n "$M" ] && t_mutate "$M" "$ST_REL" \
        's/^    defines         \[expr {\[llength \$::flist_defines\] ? \[join \$::flist_defines " "\] : "(none)"}\] \\$/    defines         "(none)" \\/'; then
    t_check_fail fstage.defines.recorded.mutation \
        "with the defines field written as (none) regardless, two defines read as explicitly nothing and the assertion goes red" \
        defines_recorded "$M"
else
    t_skip fstage.defines.recorded.mutation \
        "could not plant the fault: the defines line of the prov_stage_fields call has changed shape"
fi
M="$(y_mut never-skips-flist)" || M=""
if [ -n "$M" ] && t_mutate "$M" "$ST_REL" \
        's/^        "the flist \/ RTL_DEFINES" \$::flist_defines \\$/        "the flist \/ RTL_DEFINES" {} \\/'; then
    t_check_fail fstage.defines.never.flist.mutation \
        "with the flist's defines dropped from the NEVER check a forbidden +define+ passes, so the assertion goes red" \
        never_in_flist "$M"
else
    t_skip fstage.defines.never.flist.mutation \
        "could not plant the fault: the flist-defines source line in section 4.2 has changed shape"
fi
M="$(y_mut never-skips-inbody)" || M=""
if [ -n "$M" ] && t_mutate "$M" "$ST_REL" \
        's/^        "RTL_DEFINES_INBODY"      \[split \[flow_env FPGA_RTL_DEFINES_INBODY\]\] \\$/        "RTL_DEFINES_INBODY"      {} \\/'; then
    t_check_fail fstage.defines.never.inbody.mutation \
        "with RTL_DEFINES_INBODY dropped from the NEVER check - synth_setup's blind spot - a forbidden in-body define passes, so the assertion goes red" \
        never_in_inbody "$M"
else
    t_skip fstage.defines.never.inbody.mutation \
        "could not plant the fault: the RTL_DEFINES_INBODY source line in section 4.2 has changed shape"
fi


#=============================================================================
# 9. FLIST_APPLY, THROUGH THE STUBS
#
# The one place the stage reaches for a tool. Off by default, and the default
# has to mean NOTHING is read into the session: the artefact this stage is
# judged on is sources.tcl, and reading here proves nothing about the stage that
# will source it later. On, it applies exactly file_count reads with the include
# union ONCE, before the first of them.
#
# WHAT THE RECORDED LIST PROVES: that these calls were issued, in this order,
# with these arguments. WHAT IT DOES NOT: that Vivado accepts any of them.
#=============================================================================
t_head "FLIST_APPLY=0 issues no tool call; =1 issues file_count reads with the include union once, first"

## apply_off_reads_nothing <toolkit>
apply_off_reads_nothing() {
    local tk="$1" n
    T_STUBS=1 FLIST_APPLY=0 fl_run "$tk" apply0 || return 2
    [ "$FL_RC" -eq 0 ] || { fl_dump; printf 'the run exited %d.\n' "$FL_RC"; return 1; }
    fl_reached_end || { fl_dump; printf 'the driver never saw the stage end.\n'; return 1; }
    n="$(printf '%s\n' "$FL_OUT" | grep -c '^RECORDED: [a-z_]')"
    [ "$n" -eq 0 ] && return 0
    printf '%s\n' "$FL_OUT" | grep '^RECORDED: [a-z_]' | head -4 | sed 's/^/  | /'
    printf '%s tool call(s) were issued with FLIST_APPLY=0. The default is off because\n' "$n"
    printf 'the artefact is sources.tcl; a stage that reads the design anyway costs the\n'
    printf 'memory and proves nothing about the stage that will source that file.\n'
    return 1
}
## apply_on_reads_all <toolkit>
apply_on_reads_all() {
    local tk="$1" reads props inc first_read first_prop d n=0
    T_STUBS=1 FLIST_APPLY=1 fl_run "$tk" apply1 || return 2
    [ "$FL_RC" -eq 0 ] || { fl_dump; printf 'the run exited %d.\n' "$FL_RC"; return 1; }
    reads="$(printf '%s\n' "$FL_OUT" | grep -c '^RECORDED: read_')"
    [ "$reads" = "$FIX_SOURCES" ] || {
        printf '%s\n' "$FL_OUT" | grep '^RECORDED' | sed 's/^/  | /'
        printf '%s read command(s) issued for %d sources.\n' "$reads" "$FIX_SOURCES"; return 1; }
    props="$(printf '%s\n' "$FL_OUT" | grep -c '^RECORDED: set_property include_dirs ')"
    [ "$props" = 1 ] || {
        printf '%s\n' "$FL_OUT" | grep '^RECORDED: set_property' | sed 's/^/  | /'
        printf 'include_dirs was set %s times, not once. set_property REPLACES the property.\n' "$props"; return 1; }
    inc="$(printf '%s\n' "$FL_OUT" | grep '^RECORDED: set_property include_dirs ')"
    for d in inc1 inc2 inc3; do printf '%s' "$inc" | grep -qF -- "$PROJ/$d" && n=$((n + 1)); done
    [ "$n" -eq 3 ] || { printf '  | %s\n' "$inc"; printf 'only %d of 3 include dirs were applied.\n' "$n"; return 1; }
    first_prop="$(printf '%s\n' "$FL_OUT" | grep -n '^RECORDED: set_property' | head -1 | cut -d: -f1)"
    first_read="$(printf '%s\n' "$FL_OUT" | grep -n '^RECORDED: read_' | head -1 | cut -d: -f1)"
    [ "$first_prop" -lt "$first_read" ] && return 0
    printf 'the include union was applied at line %s, AFTER the first read at %s.\n' "$first_prop" "$first_read"
    return 1
}

t_check fstage.apply.off \
    "FLIST_APPLY=0 (the default): the stubs record NO tool call" \
    apply_off_reads_nothing "$FLOW_DIR"
t_check fstage.apply.on \
    "FLIST_APPLY=1: exactly file_count reads recorded, include_dirs set once with all three dirs, before the first read" \
    apply_on_reads_all "$FLOW_DIR"

M="$(y_mut apply-always)" || M=""
if [ -n "$M" ] && t_replace_line "$M" "$ST_REL" \
        'if {$FLIST_APPLY} {' \
        'if {1} {'; then
    t_check_fail fstage.apply.off.mutation \
        "with the knob test replaced by a constant the design is read into every session, so the assertion goes red" \
        apply_off_reads_nothing "$M"
else
    t_skip fstage.apply.off.mutation \
        "could not plant the fault: the FLIST_APPLY test in section 4.3 has changed shape"
fi
M="$(y_mut apply-claims-without-applying)" || M=""
if [ -n "$M" ] && t_replace_line "$M" "$ST_REL" \
        '        say "applied [flist_apply] read command(s)"' \
        '        say "applied 0 read command(s)"'; then
    t_check_fail fstage.apply.on.mutation \
        "with the apply call gone from behind the say, FLIST_APPLY=1 records nothing and the assertion goes red" \
        apply_on_reads_all "$M"
else
    t_skip fstage.apply.on.mutation \
        "could not plant the fault: the flist_apply say line in section 4.3 has changed shape"
fi


#=============================================================================
# 10. THE post_flist SEAM, AND THE ARTEFACT CHECK ON CONTENT
#
# CONTRACT.md 6.1.3: the seam fires BEFORE the writes and the gate is computed
# AFTER the seam. Here the artefact already exists when the seam fires (the
# stage's own honest qualification), so what is asserted is the property the
# rule exists for: a hook CAN change what the next stage reads, and the gate
# counts what it changed. The second hook is the other edge: a sources.tcl that
# satisfies `test -s` and holds no read command must be a HARD failure, because
# every later stage sources it to get the design and would elaborate nothing.
#=============================================================================
t_head "a post_flist hook's read commands reach sources.tcl and the count; a gutted sources.tcl is a hard failure"

## hook_contributes <toolkit>
hook_contributes() {
    local tk="$1"
    fl_run "$tk" hook HOOKS_DIR="$SB/hooks_extra" || return 2
    [ "$FL_RC" -eq 0 ] || { fl_dump; printf 'the run exited %d.\n' "$FL_RC"; return 1; }
    mfv "$MAN" hooks_run | grep -qE '(^| )post_flist\([0-9]+s\)' || {
        printf "hooks_run is '%s' - the hook that ran is not recorded.\\n" "$(mfv "$MAN" hooks_run)"; return 1; }
    grep -qxF 'read_verilog /contributed/by/the/hook.v' "$SRC" || {
        tail -4 "$SRC" | sed 's/^/  | /'
        printf 'the hook set ::FLIST_EXTRA_CMDS and its command is not in sources.tcl. A hook\n'
        printf 'at this seam that cannot change what the next stage reads ran, was recorded,\n'
        printf 'and had no effect.\n'; return 1; }
    [ "$(mfv "$MAN" sources_cmds)" = "$((FIX_SOURCES + 1))" ] && return 0
    printf "sources_cmds is '%s', not %d: the gate was computed before the seam.\\n" "$(mfv "$MAN" sources_cmds)" "$((FIX_SOURCES + 1))"
    return 1
}
## gutted_sources_hard <toolkit>
gutted_sources_hard() {
    local tk="$1"
    fl_run "$tk" gutted HOOKS_DIR="$SB/hooks_truncate" || return 2
    [ -s "$SRC" ] || { printf 'the fixture hook did not leave a non-empty sources.tcl; nothing to measure.\n'; return 1; }
    if [ "$FL_RC" -ne 1 ]; then
        fl_dump
        printf 'exit %d for a sources.tcl that is non-empty and carries NO read command. It\n' "$FL_RC"
        printf 'satisfies test -s, and every later stage sources it to get the design.\n'
        return 1
    fi
    gate_bullets "$GATE" '^HARD FAILURES' | grep -qF 'NO read command' && return 0
    sed -n '/^HARD/,/^BUDGETS/p' "$GATE" | sed 's/^/  | /'
    printf 'exit 1, but the gate does not name the empty source list as the hard failure.\n'
    return 1
}

t_check fstage.hook.post_flist \
    "a post_flist hook's ::FLIST_EXTRA_CMDS lands in sources.tcl, is counted by sources_cmds, and the hook is in hooks_run" \
    hook_contributes "$FLOW_DIR"
t_check fstage.artefact.content \
    "a sources.tcl with no read command is 'HARD FAILURES: 1' and exit 1, however non-empty it is" \
    gutted_sources_hard "$FLOW_DIR"

M="$(y_mut hook-cmds-ignored)" || M=""
if [ -n "$M" ] && t_replace_line "$M" "$ST_REL" \
        'if {[info exists ::FLIST_EXTRA_CMDS] && [llength $::FLIST_EXTRA_CMDS]} {' \
        'if {0} {'; then
    t_check_fail fstage.hook.post_flist.mutation \
        "with the hook's commands never written the hook runs, is recorded, and has no effect - so the assertion goes red" \
        hook_contributes "$M"
else
    t_skip fstage.hook.post_flist.mutation \
        "could not plant the fault: the FLIST_EXTRA_CMDS test in section 6 has changed shape"
fi
M="$(y_mut no-read-command-tolerated)" || M=""
if [ -n "$M" ] && t_replace_line "$M" "$ST_REL" \
        '    if {$n_cmds == 0} {' \
        '    if {0} {'; then
    t_check_fail fstage.artefact.content.mutation \
        "with the zero-read-command test dead a gutted sources.tcl passes on test -s alone, so the assertion goes red" \
        gutted_sources_hard "$M"
else
    t_skip fstage.artefact.content.mutation \
        "could not plant the fault: the n_cmds == 0 test in section 6 has changed shape"
fi


#=============================================================================
# 11. -y NOT EXPANDED IS DELEGATED, WITH AN OWNER
#
# read_verilog has no -y (CONTRACT.md section 9), so FLIST_Y_EXPAND=0 makes
# every module in those directories a black box that Vivado warns about and
# builds. The stage cannot count black boxes - synthesis can, under
# EXPECT_BLACKBOX_MAX - so it must say WHO does, or the finding is nobody's.
#=============================================================================
t_head "FLIST_Y_EXPAND=0: the unread -y is delegated to synth by name"

## ydirs_delegated <toolkit>
ydirs_delegated() {
    local tk="$1" d
    FLIST_Y_EXPAND=0 fl_run "$tk" noy || return 2
    [ "$FL_RC" -eq 0 ] || { fl_dump; printf 'the run exited %d.\n' "$FL_RC"; return 1; }
    [ "$(mfv "$MAN" file_count)" = "$((FIX_SOURCES - 1))" ] || {
        printf "file_count is '%s' with the -y directory unread; the fixture has %d without it.\\n" \
            "$(mfv "$MAN" file_count)" "$((FIX_SOURCES - 1))"; return 1; }
    [ "$(mfv "$MAN" ydirs_expanded)" = no ] || {
        printf "ydirs_expanded is '%s' with FLIST_Y_EXPAND=0.\\n" "$(mfv "$MAN" ydirs_expanded)"; return 1; }
    d="$(gate_bullets "$GATE" '^DECLARED ELSEWHERE' | grep -F "'-y'")"
    [ -n "$d" ] || {
        gate_bullets "$GATE" '^DECLARED ELSEWHERE' | sed 's/^/  | /'
        printf 'no delegation names the unread -y directory. Every module in it is a black\n'
        printf 'box, and nothing in this run says whose job the count is.\n'; return 1; }
    printf '%s' "$d" | grep -qF 'owner=synth' && printf '%s' "$d" | grep -qF 'EXPECT_BLACKBOX_MAX' && return 0
    printf '  | %s\n' "$d"
    printf 'the -y delegation does not name owner=synth and EXPECT_BLACKBOX_MAX.\n'
    return 1
}

t_check fstage.ydirs.delegated \
    "FLIST_Y_EXPAND=0: file_count drops by the -y unit, ydirs_expanded no, and the gate delegates to owner=synth / EXPECT_BLACKBOX_MAX" \
    ydirs_delegated "$FLOW_DIR"

M="$(y_mut y-delegation-dropped)" || M=""
if [ -n "$M" ] && t_replace_line "$M" "$ST_REL" \
        'if {[llength $::flist_ydirs] && !$::FLIST_Y_EXPAND} {' \
        'if {0} {'; then
    t_check_fail fstage.ydirs.delegated.mutation \
        "with the -y delegation never written the black boxes belong to nobody, so the assertion goes red" \
        ydirs_delegated "$M"
else
    t_skip fstage.ydirs.delegated.mutation \
        "could not plant the fault: the -y delegation test in section 7 has changed shape"
fi


#=============================================================================
# 12. KNOWN DEFECTS - found by reading the artefacts this suite produces
#
# Both are recorded rather than fixed: this suite does not own 1_flist.tcl. The
# marker is NOT red today and goes RED the day the command starts passing, at
# which point it is deleted and the assertion promoted.
#=============================================================================
t_head "known defects in 1_flist.tcl"

# 12a. The ignored-option delegation sends the reader to a file that does not
# carry the finding. The bullet reads "They are listed in the log and in
# <run>/reports/flist_sources.txt" - but the census is written from
# ::flist_files_read and nothing else; ::flist_ignored reaches only the log.
# A gate that names a file as evidence must name one that holds it.
# FIX: either write the ignored options into the census (a commented block at
# the end would do) or make the bullet say "in the log" and stop there.
#
# THE PREDICATE IS THE CORRECT ASSERTION, NOT THE DEFECT, and it is satisfied by
# EITHER fix - the census gaining the options, or the bullet no longer claiming
# it. A predicate that only accepted the first would keep this marker green
# after the second, which is a defect marker outliving its defect: the thing the
# harness makes red, quietly defeated by the way the check was written.
## census_lists_ignored_options <toolkit>
census_lists_ignored_options() {
    local tk="$1"
    fl_run "$tk" ign || return 2
    [ "$FL_RC" -eq 0 ] || return 1
    gate_bullets "$GATE" '^DECLARED ELSEWHERE' | grep -F 'not recognised' | grep -qF 'flist_sources.txt' || return 0
    grep -qF -- '-timescale' "$CENSUS"
}
t_known_defect fstage.defect.gate_names_census_for_ignored \
    "the ignored-option delegation names flist_sources.txt as where the options are listed, and the census does not list them" \
    census_lists_ignored_options "$FLOW_DIR"

# 12b. With TOP unset the TOP scan never runs (the `if {$FLIST_ASSERT_TOP &&
# $TOP ne ""}` guard), yet top_declared_in is written from $top_in alone and
# comes out UNVERIFIED:not-declared-by-any-file-read - the reason string for a
# scan that came back negative, not for a scan that was never made. `top` one
# line up says UNVERIFIED:TOP-unset, so a reader who checks both has the truth;
# the field itself misstates it. CONTRACT.md section 12.4: a count nobody took
# is `unmeasured`. FIX: derive the field from whether the step ran, not from
# $top_in - the FLIST_ASSERT_TOP=0 branch already writes unmeasured for the
# same situation reached by the other knob.
## top_unset_is_unmeasured <toolkit>
top_unset_is_unmeasured() {
    local tk="$1" v
    fl_run "$tk" topunset TOP= || return 2
    [ "$FL_RC" -eq 0 ] || return 1
    v="$(mfv "$MAN" top_declared_in)"
    case "$v" in unmeasured|UNVERIFIED:TOP-unset*) return 0 ;; esac
    printf "top_declared_in is '%s' with TOP unset and no scan made.\\n" "$v"
    return 1
}
t_known_defect fstage.defect.top_unset_reason \
    "with TOP unset top_declared_in claims 'not-declared-by-any-file-read' for a scan that never ran; it should be unmeasured" \
    top_unset_is_unmeasured "$FLOW_DIR"


t_summary
