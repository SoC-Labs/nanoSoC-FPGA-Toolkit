#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# t_package_ip.sh - flow/vivado/2_package_ip.tcl: THE STAGE THAT PACKAGES IP
#
# DEFECT CLASS: A PACKAGED CORE THAT SILENTLY DESCRIBES A DIFFERENT DESIGN.
#
# CONTRACT.md section 9.2, measured on this codebase: `ipx::package_project`
# DROPS fileset defines by three separate routes, and PARAMETERS survive as
# CONFIG.*. It failed silently once already - an `ifdef TIDELINK_USE_IDELAY
# opt-in was false in EVERY FPGA build, and the only proof was a bitstream
# byte-identical to the "IDELAY-off" one. No error, no warning, no difference in
# any report. A packaged core is opaque: once component.xml exists, nothing
# downstream can tell an `ifdef that was taken from one that was not.
#
# So this stage is judged on ONE question above all others: when the design's
# configuration is about to be lost at the IP boundary, does the stage SAY SO?
# Everything else here - refusals, the VLNV, the manifest and gate shapes, the
# seams, the order of the ipx:: calls - is the machinery that question rests on.
#
# HOW A VIVADO STAGE IS DRIVEN WITHOUT VIVADO. The stage reaches the tool only
# through commands it calls by name, and every one of them is stubbed by a
# driver (pkg_drive.tcl, below) that RECORDS the call and models just enough of
# the tool for the stage to proceed: a fileset, a property store, and an ipx
# core that carries the fileset's files and the top's parameters into
# component.xml and NEVER carries a verilog_define - which is the measured fact,
# reproduced rather than assumed, and proved from the input side in section 1.
# Every stub appends its call to a record file THE MOMENT it is made, so the
# order on disk is the order the stage made the calls and it survives the stage
# exiting through die/flow_refuse, neither of which returns to the driver. This
# is t_provenance.sh's technique applied to a whole stage; nothing in the file
# under test is stubbed, edited or factored.
#
# WHAT THE STUBS CANNOT PROVE. That the real tool drops the define - the stub
# does, because the contract says the tool does. That a packaged core
# elaborates. That the bus-interface inference is right. Anything about the
# real component.xml schema beyond the four VLNV tags the stage itself reads.
# Those need Vivado, and the gate file says so in its NOT-covered section.
#
# EVERY PROOF GETS ITS OWN MUTANT COPY, and every fault is planted with
# t_replace_line / t_mutate, which fail loudly when the edit changes nothing. A
# mutation that silently did not apply turns its proof into a check that cannot
# fail. A fault that cannot be planted is a SKIP WITH THE REASON.
#
# A LINE ENDING IN `\` IS MUTATED WITH t_mutate, NEVER t_replace_line, AND THAT
# IS A MEASURED RULE RATHER THAN A PREFERENCE. t_replace_line plants through
# sed's `${n}c\<text>`, and sed reads a trailing backslash in that text as its
# own line-continuation marker and DROPS IT. Eight of the faults below are aimed
# at continuation lines inside `prov_stage_fields [list ... \` and at the
# `prov_gate` call, and every one of them originally planted a BROKEN TCL
# CONTINUATION instead of the intended change: the mutant died of a Tcl arity or
# parse error, the predicate went red, and t_check_fail reported `ok` on a proof
# that had never exercised the property it names. Caught by reading each proof's
# diagnostic rather than its status - the same discipline the assertions
# themselves follow, applied to the proofs. A substitution leaves the rest of
# the line, including the backslash, exactly where it was.
#
# EXIT STATUS IS GRADED FROM THE SHELL, NEVER FROM INSIDE TCL. `die` and
# `flow_refuse` EXIT the interpreter; a `catch` around them traps nothing. Every
# predicate below reads the exit code of the tclsh process and then the
# artefacts on disk - and never the exit code alone (CONTRACT.md section 0).
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/lib/harness.sh
. "$HERE/../lib/harness.sh"

# FD 3 IS THE SUITE'S OWN STDERR, AND IT EXISTS FOR ONE MESSAGE: the
# fixture-rebuild notice below. t_check runs its predicate as `out="$("$@" 2>&1)"`
# and PRINTS THAT ONLY WHEN THE PREDICATE FAILS, so a notice written to stderr
# from inside a predicate that then passes is swallowed - which is how the first
# version of the rebuild reported nothing at all on a run where it had fired.
# Interference that leaves no trace in the log is interference nobody reads.
exec 3>&2
T_REBUILDS=0

t_sandbox; SB="$T_SANDBOX"

STAGE_REL="flow/vivado/2_package_ip.tcl"

#-----------------------------------------------------------------------------
# PRECONDITIONS. Each is a SKIP WITH THE REASON, never a pass.
#-----------------------------------------------------------------------------
if [ ! -f "$FLOW_DIR/$STAGE_REL" ]; then
    t_skip pkg.all "no $STAGE_REL in this checkout - nothing to test, and an absent stage is not a passing one"
    t_summary; exit $?
fi
if ! command -v tclsh >/dev/null 2>&1; then
    t_skip pkg.all "no tclsh on PATH - the stage is driven under bare tclsh with recording stubs, and that is the only tool-free way to run it"
    t_summary; exit $?
fi
if ! command -v sha256sum >/dev/null 2>&1; then
    t_skip pkg.all "no sha256sum on PATH - provenance.tcl shells out to it for every digest, so every sha256 field this suite reads would be UNVERIFIED"
    t_summary; exit $?
fi
if [ ! -f "$FLOW_DIR/templates/board.tcl.in" ]; then
    t_skip pkg.all "no templates/board.tcl.in - the board-pack fixture is generated from the template so it cannot drift from what the scaffolder ships"
    t_summary; exit $?
fi
# THE PART PACK IS FOUND, NOT NAMED. `find`, never a literal: the packs are a
# directory, and a name written here would be a second copy of that directory.
# `sed -n 1p` rather than `head -1` - see t_bd.sh's note on SIGPIPE under
# pipefail.
PART_NAME="$(find "$FLOW_DIR/part" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | sed -n 1p)"
if [ -z "$PART_NAME" ] || [ ! -f "$FLOW_DIR/part/$PART_NAME/part.tcl" ]; then
    t_skip pkg.all "no part pack directory under $FLOW_DIR/part - flow_boot loads one and cannot run without it"
    t_summary; exit $?
fi

#=============================================================================
# THE FIXTURE
#
# A project whose configuration rides on exactly the three mechanisms
# CONTRACT.md section 9.2 names:
#
#   demo_block.v   the top. Two PARAMETERS (WIDTH, DEPTH) and one `ifdef
#                  SEL_FPGA - the FPGA/ASIC selection shape, riding on a macro.
#   other.v        a second source that reads nothing, so "the file that reads
#                  the name" and "a file in the fileset" are different sets.
#   inc/cfg.vh     a HEADER that reads SEL_FPGA. Headers are not sources; they
#                  are found on the include path, so this is the second scan.
#   sources.tcl    what the flist stage writes - spelled the way
#                  flist_write_sources spells it, with `+define+SEL_FPGA` ON THE
#                  FILESET. That is the fault the whole suite is about: a define
#                  declared to the tool the ordinary way, which packaging drops.
#
# The board pack is GENERATED FROM templates/board.tcl.in with its placeholders
# filled, so it is whatever the scaffolder would give a project. The part pack
# is one the toolkit ships.
#=============================================================================
# THE FIXTURE IS BUILT BY A FUNCTION, AND THE FUNCTION IS IDEMPOTENT, BECAUSE
# THIS SANDBOX HAS BEEN DELETED UNDER A RUNNING SUITE. MEASURED 2026-09-17: six
# other sessions were running this toolkit's suites on the same host, every
# sandbox is $TMPDIR/fpga-flow-test.*, and one of them took this suite's tree
# away mid-run - `cp: cannot stat .../sources_with_define.tcl`, then `cd:
# .../run/work: No such file or directory`, then four red assertions.
#
# The red assertions were not the problem. The problem was the line after each
# of them: every `.mutation` proof that followed reported `ok`, because
# t_check_fail asks only for a non-zero status and a predicate whose fixture has
# been deleted returns non-zero for free. That is a check that cannot fail,
# arrived at from the outside - the exact defect class this directory exists to
# catch, and it would have counted as five planted faults rejected.
#
# So the fixture is rebuilt whenever it is missing, and the rebuild SAYS SO on
# stderr rather than quietly papering over it. Every assertion then measures the
# thing it names, and the interference stays visible.
fixture_build() {
PROJ="$SB/proj"
RUN="$SB/run"
REC="$SB/record.txt"
mkdir -p "$PROJ/rtl" "$PROJ/inc" "$PROJ/board/demo_board" "$PROJ/hooks" \
         "$RUN/work" "$RUN/logs" "$RUN/reports" "$RUN/outputs" \
         "$SB/nohooks" "$SB/emptywork" "$SB/repo_a" "$SB/repo_b" "$SB/repo_empty"
printf 'a packaged core\n' > "$SB/repo_a/core_a.txt"
printf 'another\n'         > "$SB/repo_b/core_b.txt"

sed -e "s/@BOARD@/demo_board/" -e "s/@PART@/$PART_NAME/" \
    -e 's/"<<FILL IN: integer Hz, e.g. 50000000>>"/50000000/' \
    -e 's/"<<FILL IN: zynq7 or zynqmp>>"/zynq7/' \
    "$FLOW_DIR/templates/board.tcl.in" > "$PROJ/board/demo_board/board.tcl"
# THE MARKER CHECK IGNORES COMMENTS, and that distinction is the template's own.
# A `<<FILL IN>>` in a LIVE `board_set` is a value nobody chose and the pack would
# carry it into the run; one in a commented-out line is the template showing what
# an OPTIONAL key looks like, and board.tcl.in has seven of those. Skipping on a
# commented example would turn this whole suite off for a fixture that is fine.
if sed 's/^[[:space:]]*#.*$//' "$PROJ/board/demo_board/board.tcl" | grep -q '<<FILL IN'; then
    t_skip pkg.all "templates/board.tcl.in has a LIVE <<FILL IN>> this fixture does not know how to fill: $(sed 's/^[[:space:]]*#.*$//' "$PROJ/board/demo_board/board.tcl" | grep -o '<<FILL IN[^>]*>>' | sed -n 1p)"
    t_summary; exit $?
fi

# Quoted heredocs: the RTL is full of backticks, and in an UNQUOTED heredoc a
# backtick is command substitution.
cat > "$PROJ/rtl/demo_block.v" <<'EOF'
module demo_block #(parameter WIDTH = 8, parameter DEPTH = 4) (input clk, output [WIDTH-1:0] q);
`ifdef SEL_FPGA
  assign q = {WIDTH{1'b1}};
`else
  assign q = {WIDTH{1'b0}};
`endif
endmodule
EOF
cat > "$PROJ/rtl/other.v" <<'EOF'
module other (input a, output b);
  assign b = a;
endmodule
EOF
cat > "$PROJ/inc/cfg.vh" <<'EOF'
`ifdef SEL_FPGA
`define CFG_Q 1
`endif
EOF

## write_sources <path> <defines...> - a sources.tcl as flist_write_sources
## writes one: the union variables, the ONE guarded property assignment each,
## then the reads. Unquoted heredoc, so the sandbox paths expand; every Tcl
## dollar is escaped. No backticks in it.
write_sources() {
    local out="$1"; shift
    cat > "$out" <<EOF
# sources.tcl - a fixture in the shape flow/common/read_flist.tcl writes.
set flist_incdirs [list $PROJ/inc]
set flist_defines [list $*]
set flist_files   2

if {[llength [info commands current_fileset]] && ![catch {current_fileset} __fs]} {
    if {[llength \$flist_incdirs]} {
        set_property include_dirs \\
            [concat [get_property include_dirs \$__fs] \$flist_incdirs] \$__fs
    }
    if {[llength \$flist_defines]} {
        set_property verilog_define \\
            [concat [get_property verilog_define \$__fs] \$flist_defines] \$__fs
    }
    unset __fs
}

read_verilog [list $PROJ/rtl/demo_block.v]
read_verilog [list $PROJ/rtl/other.v]
EOF
}
SRC_DEF="$SB/sources_with_define.tcl"
SRC_NODEF="$SB/sources_without_define.tcl"
write_sources "$SRC_DEF" SEL_FPGA
write_sources "$SRC_NODEF"
cp "$SRC_DEF" "$RUN/work/sources.tcl"

# --- the project's packaging scripts --------------------------------------
# The stage publishes ::IP_* and the script makes the packaging DECISIONS from
# them. This one does what templates/design.mk.in tells a project to do: package
# at $IP_ROOT_DIR under the published vendor/library, then name and version the
# core from the published values.
cat > "$PROJ/package.tcl" <<'EOF'
ipx::package_project -root_dir $::IP_ROOT_DIR -vendor $::IP_VENDOR -library $::IP_LIBRARY \
    -taxonomy $::IP_TAXONOMY -import_files -set_current true
set_property name    $::IP_CORE_NAME [ipx::current_core]
set_property version $::IP_CORE_REV  [ipx::current_core]
EOF
# ...one that packages, SAVES, and then CLOSES the core, so the stage has no
# object to ask and must answer from the file on disk. The save is not optional
# padding: a script that unloads without saving loses its own edits, so the file
# would carry the version package_project wrote and this fixture would be
# measuring a broken packaging script rather than the stage's ability to answer
# from an artefact. save-then-unload is also the documented Vivado idiom.
cat > "$PROJ/package_unload.tcl" <<'EOF'
ipx::package_project -root_dir $::IP_ROOT_DIR -vendor $::IP_VENDOR -library $::IP_LIBRARY \
    -taxonomy $::IP_TAXONOMY -import_files -set_current true
set_property name    $::IP_CORE_NAME [ipx::current_core]
set_property version $::IP_CORE_REV  [ipx::current_core]
ipx::save_core   [ipx::current_core]
ipx::unload_core [ipx::current_core]
EOF
# ...one that writes the core into ITS OWN directory under work/, the common
# mistake the stage's relocation exists for...
cat > "$PROJ/package_elsewhere.tcl" <<'EOF'
ipx::package_project -root_dir [file join $WORK_DIR package_ip mycore] -vendor $::IP_VENDOR \
    -library $::IP_LIBRARY -taxonomy $::IP_TAXONOMY -import_files -set_current true
set_property name    $::IP_CORE_NAME [ipx::current_core]
set_property version $::IP_CORE_REV  [ipx::current_core]
EOF
# ...and one that packages NOTHING. Every existence check in the world passes on
# this file, and ipx::package_project's own refusals are warnings.
cat > "$PROJ/package_nothing.tcl" <<'EOF'
# a PACKAGE_TCL that defines a variable and packages nothing
set nothing_packaged 1
EOF

# --- the hooks ---------------------------------------------------------------
# Each records that it fired, through the driver's `rec`, so the seam order is
# in the same record as the tool calls. post_package_ip also EDITS the core -
# CONTRACT.md section 6.1.3: a post_* seam fires before the write, and the
# artefact must carry the hook's effect. 9.9 is a version no fixture sets any
# other way, so its presence in component.xml has exactly one explanation.
printf 'rec HOOK pre_package_ip\n' > "$PROJ/hooks/pre_package_ip.tcl"
cat > "$PROJ/hooks/post_package_ip.tcl" <<'EOF'
rec HOOK post_package_ip
set_property version 9.9 [ipx::current_core]
EOF
}


## fixture_intact - every file a run needs, INCLUDING THE DRIVER. Six stats.
## The driver is on this list because leaving it off is the mistake that was
## made: the first rebuild restored the project and not pkg_drive.tcl, so every
## run after a deletion failed on a missing driver instead - 18 red assertions
## where there had been 4.
fixture_intact() {
    [ -f "$SRC_DEF" ] && [ -f "$SRC_NODEF" ] && [ -f "$PROJ/package.tcl" ] \
        && [ -f "$PROJ/board/demo_board/board.tcl" ] && [ -d "$RUN/work" ] \
        && [ -s "$SB/pkg_drive.tcl" ]
}

#=============================================================================
# THE DRIVER
#
# Stubs, a record, and one `source`. It DECIDES NOTHING: the assertions below
# read the record and the artefacts. Every stub's state is `stub_`-prefixed,
# because the stage runs in the same global scope and owns `core`, `params`,
# `component`, `hard` and forty other short names - the first draft's `::core`
# was overwritten by the stage's own `set core ""` and every core-dependent
# assertion measured the wrong thing.
#=============================================================================
driver_build() {
cat > "$SB/pkg_drive.tcl" <<'TCL'
# pkg_drive.tcl <toolkit> <record file>
set stub_tk    [lindex $::argv 0]
set ::stub_rec [lindex $::argv 1]

# APPEND-ON-CALL. The stage exits through die/flow_refuse/exit without ever
# returning here, so a record kept in memory and written at the end would be
# empty on exactly the runs whose order matters most.
proc rec {args} {
    set fh [open $::stub_rec a]
    puts $fh [join $args " "]
    close $fh
}

# --- a project with one fileset and a property store -------------------------
set ::stub_files {}
array set ::stub_prop {}
proc create_project   {args} { rec create_project {*}$args }
proc current_project  {args} { return project0 }
proc current_fileset  {args} { return sources_1 }
proc get_files {args} {
    set pat ""
    foreach a $args { if {$a ne "-quiet"} { set pat $a } }
    if {$pat eq ""} { return $::stub_files }
    set out {}
    foreach f $::stub_files {
        if {[file normalize $f] eq [file normalize $pat]} { lappend out $f }
    }
    return $out
}
proc read_verilog {args} {
    set f [lindex $args end]
    rec read_verilog {*}$args
    lappend ::stub_files $f
    set ::stub_prop($f,FILE_TYPE) [expr {[lsearch -exact $args -sv] >= 0 ? "SystemVerilog" : "Verilog"}]
}
proc read_vhdl {args} {
    set f [lindex $args end]
    rec read_vhdl {*}$args
    lappend ::stub_files $f
    set ::stub_prop($f,FILE_TYPE) VHDL
}
proc add_files {args} { set f [lindex $args end]; rec add_files {*}$args; lappend ::stub_files $f }
proc remove_files {args} {
    rec remove_files {*}$args
    foreach f $args {
        set i [lsearch -exact $::stub_files $f]
        if {$i >= 0} { set ::stub_files [lreplace $::stub_files $i $i] }
    }
}
proc set_property {prop value obj} { rec set_property $prop $value $obj; set ::stub_prop($obj,$prop) $value }
proc get_property {prop obj} {
    if {$obj eq "core0" && $prop eq "vlnv"} { return [stub_core_vlnv] }
    if {[info exists ::stub_prop($obj,$prop)]} { return $::stub_prop($obj,$prop) }
    return {}
}
proc update_ip_catalog {args} { rec update_ip_catalog {*}$args }
proc config_ip_cache   {args} { rec config_ip_cache {*}$args }

# --- ipx ---------------------------------------------------------------------
# THE MEASURED FACT, MODELLED. package_project reads the fileset's FILES and the
# top's PARAMETERS into the core. It does not read verilog_define, and nothing
# below writes a define into component.xml by any route. save_core rewrites the
# file from the in-memory core, so an edit made after package_project reaches
# the disk only if a save follows it - which is what CONTRACT.md 6.1.3 is about.
namespace eval ipx {}
set ::stub_core ""
array set ::stub_core_state {}
set ::stub_core_params {}
proc stub_core_vlnv {} {
    return "$::stub_core_state(vendor):$::stub_core_state(library):$::stub_prop(core0,name):$::stub_prop(core0,version)"
}
proc stub_core_write {} {
    set dir $::stub_core_state(root)
    file mkdir $dir
    set fh [open [file join $dir component.xml] w]
    puts $fh {<?xml version="1.0" encoding="UTF-8"?>}
    puts $fh {<spirit:component>}
    puts $fh "  <spirit:vendor>$::stub_core_state(vendor)</spirit:vendor>"
    puts $fh "  <spirit:library>$::stub_core_state(library)</spirit:library>"
    puts $fh "  <spirit:name>$::stub_prop(core0,name)</spirit:name>"
    puts $fh "  <spirit:version>$::stub_prop(core0,version)</spirit:version>"
    puts $fh "  <spirit:fileSets>"
    foreach f $::stub_core_state(files) {
        puts $fh "    <spirit:file><spirit:name>$f</spirit:name></spirit:file>"
    }
    puts $fh "  </spirit:fileSets>"
    puts $fh "  <spirit:parameters>"
    foreach p $::stub_core_params {
        puts $fh "    <spirit:parameter><spirit:name>$p</spirit:name><spirit:value>$::stub_prop(param:$p,value)</spirit:value></spirit:parameter>"
    }
    puts $fh "  </spirit:parameters>"
    puts $fh {</spirit:component>}
    close $fh
}
proc ipx::package_project {args} {
    rec ipx::package_project {*}$args
    array set o {-root_dir "" -vendor "" -library "" -taxonomy ""}
    for {set i 0} {$i < [llength $args]} {incr i} {
        set a [lindex $args $i]
        if {[info exists o($a)]} { set o($a) [lindex $args [incr i]] }
    }
    set ::stub_core core0
    set ::stub_core_state(vendor)  $o(-vendor)
    set ::stub_core_state(library) $o(-library)
    set ::stub_core_state(root)    $o(-root_dir)
    set ::stub_core_state(files)   $::stub_files
    set top [expr {[info exists ::stub_prop(sources_1,top)] ? $::stub_prop(sources_1,top) : "unknown_top"}]
    set ::stub_prop(core0,name)    $top
    set ::stub_prop(core0,version) 1.0
    # HDL parameters: read off the top module's text, the way the tool does.
    set ::stub_core_params {}
    foreach f $::stub_files {
        if {[catch {open $f r} fh]} { continue }
        set body [read $fh]
        close $fh
        if {![regexp "module\[ \t\]+${top}\\M" $body]} { continue }
        foreach {m n v} [regexp -all -inline {parameter[ \t]+([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*([^,)\s]+)} $body] {
            lappend ::stub_core_params $n
            set ::stub_prop(param:$n,value) $v
        }
    }
    stub_core_write
}
proc ipx::current_core {} {
    rec ipx::current_core
    if {$::stub_core eq ""} { error "No current core" }
    return $::stub_core
}
proc ipx::get_user_parameters {name args} { rec ipx::get_user_parameters $name {*}$args; return {} }
proc ipx::get_hdl_parameters  {name args} {
    rec ipx::get_hdl_parameters $name {*}$args
    if {[lsearch -exact $::stub_core_params $name] >= 0} { return [list "param:$name"] }
    return {}
}
proc ipx::check_integrity {c} { rec ipx::check_integrity $c }
proc ipx::save_core       {c} { rec ipx::save_core $c; stub_core_write }
proc ipx::unload_core     {c} { rec ipx::unload_core $c; set ::stub_core "" }

# Two scenario switches. A tool with no create_project (the stage must refuse,
# not crash), and a tool that ALREADY HAS a command the stage wants to define
# (the stage's shadow guard must fire).
if {[info exists ::env(T_PKG_NO_CREATE_PROJECT)]} { rename create_project {} }
if {[info exists ::env(T_PKG_SHADOW)]} { proc find_component {args} { return "a-tool-builtin" } }

# A gate left by an EARLIER run of this run tag, planted from in here because
# pkg_run wipes reports/ before every run and a gate written from the shell
# would go with it. It is written before the stage is sourced, which is exactly
# where the real one would already be.
if {[info exists ::env(T_PKG_PLANT_STALE)]} {
    set __g [open [file join $::env(FPGA_REPORT_DIR) package_ip_gate.txt] w]
    puts $__g "PACKAGE-IP gate, from an EARLIER run of this tag"
    close $__g
}

source [file join $stub_tk flow vivado 2_package_ip.tcl]
rec STAGE-END
TCL
}

# Build both once now; pkg_run re-asserts them before every run.
fixture_build
driver_build

#=============================================================================
# DRIVING THE STAGE
#
# Every predicate takes the toolkit as its FIRST ARGUMENT, so the identical
# predicate can be pointed at $FLOW_DIR and at a mutant. Extra arguments are
# VAR=value environment overrides for the scenario; they come AFTER the
# defaults on the env line, so they win.
#
# The run tree is reset before every run - reports, outputs, the materialised
# copies, the record - and sources.tcl is left in place. `cd` into work/,
# because mk/flow.mk's vivado_stage does. `timeout`, because a suite that hangs
# is a suite that gets killed rather than read.
#=============================================================================
PKG_RC=0
PKG_OUT=""
MAN="$RUN/reports/package_ip_manifest.txt"
GATE="$RUN/reports/package_ip_gate.txt"
INBODY="$RUN/reports/package_ip_inbody.txt"

## pkg_run <toolkit> [VAR=value ...]
pkg_run() {
    local tk="$1"; shift
    # See fixture_build's header: another session on this host deletes sandboxes
    # matching the harness's own naming, and a predicate whose fixture has gone
    # returns non-zero for free - which a mutation proof would have counted as a
    # rejection. Rebuild, and say so.
    if ! fixture_intact; then
        T_REBUILDS=$((T_REBUILDS + 1))
        printf 'FIXTURE GONE - rebuilding %s. Something outside this suite removed it mid-run.\n' "$SB" >&3
        fixture_build
        driver_build
    fi
    rm -rf "$RUN/reports" "$RUN/outputs" "$RUN/work/inbody" "$RUN/work/package_ip" "$REC"
    mkdir -p "$RUN/reports" "$RUN/outputs" "$RUN/logs"
    PKG_RC=0
    PKG_OUT="$(cd "$RUN/work" && env \
        FPGA_FLOW_DIR="$tk" FPGA_DIR="$PROJ" FPGA_PROJECT_ROOT="$PROJ" \
        FPGA_BLOCK=demo_block FPGA_RUN_DIR="$RUN" FPGA_RUN_TAG=t1 \
        FPGA_WORK_DIR="$RUN/work" FPGA_REPORT_DIR="$RUN/reports" FPGA_OUT_DIR="$RUN/outputs" FPGA_LOG_DIR="$RUN/logs" \
        FPGA_PART_DIR="$tk/part/$PART_NAME" FPGA_BOARD_DIR="$PROJ/board/demo_board" \
        FPGA_HOOKS_DIR="" FPGA_PACKAGE_TCL="$PROJ/package.tcl" FPGA_TOP=demo_block \
        FPGA_IP_VENDOR=acme.example FPGA_IP_CORE_REV=3 FPGA_IP_REPOS="$SB/repo_a $SB/repo_b" \
        FPGA_RTL_PARAMS="WIDTH=16 DEPTH=2" FPGA_RTL_DEFINES_INBODY="" FPGA_RTL_DEFINES_NEVER="" \
        PACKAGE_IP_LIBRARY="" PACKAGE_IP_REQUIRE_PARAMS="" PACKAGE_IP_READ_SOURCES="" \
        "$@" \
        timeout 60 tclsh "$SB/pkg_drive.tcl" "$tk" "$REC" 2>&1)" || PKG_RC=$?
}

## use_sources <file> - swap which sources.tcl the next runs read.
## IT RETRIES AFTER A REBUILD RATHER THAN LETTING THE COPY FAIL, because
## fixture_build leaves the WITH-DEFINE list in place: a predicate that asked
## for the no-define control and lost the copy to a deleted sandbox would be
## handed the other fixture and would compare a run against itself.
use_sources() {
    cp "$1" "$RUN/work/sources.tcl" 2>/dev/null && return 0
    T_REBUILDS=$((T_REBUILDS + 1))
    printf 'FIXTURE GONE - rebuilding %s before selecting a source list.\n' "$SB" >&3
    fixture_build
    driver_build
    cp "$1" "$RUN/work/sources.tcl"
}

## mf_get <manifest> <key> - a block-8 value. `mf` pads the key to 28 columns.
mf_get() { grep -E "^$2[[:space:]]" "$1" 2>/dev/null | sed -n 1p | sed -E 's/^[^[:space:]]+[[:space:]]+//'; }

## rec_first <regex> / rec_last <regex> - line numbers in the record, or ""
rec_first() { grep -nE -- "$1" "$REC" 2>/dev/null | sed -n 1p | cut -d: -f1; }
rec_last()  { grep -nE -- "$1" "$REC" 2>/dev/null | tail -1  | cut -d: -f1; }

## gate_section <gate> <header regex> - the bullets of one section, until the
## next line that starts at column 0 with a capital (assert-stage's own rule).
gate_section() { awk -v h="$2" '$0 ~ h {on=1; next} on && /^[A-Z]/ {on=0} on {print}' "$1"; }

## packaged_file <component.xml> <basename> - the path component.xml lists for
## that file. The ARTEFACT says what was packaged; the log does not.
packaged_file() { grep -oE '<spirit:name>[^<]*'"$2"'</spirit:name>' "$1" | sed -E 's/<[^>]*>//g' | sed -n 1p; }

## component_under_out - the one component.xml under outputs/ip, or ""
component_under_out() { find "$RUN/outputs/ip" -name component.xml -type f 2>/dev/null | sed -n 1p; }

## show_run - the evidence a failing predicate prints FIRST. t_check prints the
## LAST 14 lines of a failing predicate's output, so the verdict goes last.
show_run() {
    printf 'exit %d; reports: %s\n' "$PKG_RC" "$(ls "$RUN/reports" 2>/dev/null | tr '\n' ' ')"
    printf '%s\n' "$PKG_OUT" | grep -E 'REFUSED|FAIL|WARN' | sed 's/^/  | /' | head -8
}


#=============================================================================
# 1. THE HEADLINE: A FILESET DEFINE THAT A PACKAGED FILE READS IS ABOUT TO BE
#    DROPPED. DOES THE STAGE SAY SO?
#
# The fixture puts `+define+SEL_FPGA` on the fileset exactly as the flist stage
# would, demo_block.v reads it with an `ifdef, and RTL_DEFINES_INBODY is empty -
# the project has used the ordinary mechanism, which is the one that does not
# survive. Three things are asserted, in order of what they prove:
#
#   1a  THE FIXTURE REPRODUCES THE FACT. The tool was told the define (the
#       record shows the verilog_define assignment), and the packaged core
#       carries the PARAMETERS with their RTL_PARAMS values and NOT the define -
#       component.xml does not name it, and the file component.xml lists as the
#       packaged demo_block does not define it. Proved from the input side: with
#       the same name in RTL_DEFINES_INBODY the toolkit bakes it into the
#       packaged copy, and the predicate goes red.
#   1b  THE STAGE NAMES IT. SEL_FPGA must appear in block 8 of the manifest or
#       in the gate's HARD FAILURES / DECLARED ELSEWHERE bullets. Nothing
#       weaker counts: the gate already carries an UNCONDITIONAL bullet saying
#       fileset defines are dropped, and a line that is emitted whether or not
#       the design has any defines cannot discriminate this design from one
#       that is safe - measured here, the define-related lines of the gate and
#       the manifest are byte-identical with and without the define.
#   1c  THE VERDICT IS NOT GREEN ON IT. A stage whose gate reads
#       `HARD FAILURES: none` and whose exit is 0 on a design whose selection
#       macro is about to vanish has let a silent substitution through.
#
# 1b and 1c are KNOWN-DEFECT today. The markers go RED the day the stage starts
# satisfying them, which is the day their planted-fault proofs get written.
#=============================================================================
t_head "1. a fileset define read by a packaged file: is the drop DETECTED and REPORTED?"

## fixture_drops_define <toolkit> [env...]
fixture_drops_define() {
    local tk="$1"; shift
    use_sources "$SRC_DEF"
    pkg_run "$tk" "$@"
    local c pf
    c="$(component_under_out)"
    show_run
    if [ "$PKG_RC" -ne 0 ] || [ -z "$c" ]; then
        printf 'the stage did not complete with a component.xml under outputs/ip\n'; return 1
    fi
    if ! grep -qF 'set_property verilog_define SEL_FPGA sources_1' "$REC"; then
        printf 'the fixture never declared SEL_FPGA to the tool - the record has no verilog_define assignment:\n'
        cat "$REC"; return 1
    fi
    if ! grep -qE '<spirit:name>WIDTH</spirit:name><spirit:value>16</spirit:value>' "$c"; then
        printf 'the packaged core does not carry WIDTH=16 as a parameter:\n'; cat "$c"; return 1
    fi
    pf="$(packaged_file "$c" demo_block.v)"
    if [ -z "$pf" ] || [ ! -f "$pf" ]; then
        printf 'component.xml does not list a demo_block.v this suite can open:\n'; cat "$c"; return 1
    fi
    printf 'packaged demo_block: %s\n' "$pf"
    if grep -qF 'SEL_FPGA' "$c" || grep -qE '^`define[[:space:]]+SEL_FPGA' "$pf"; then
        printf 'SEL_FPGA REACHED the packaged core - by component.xml or by the packaged file.\n'
        printf 'That is the in-body mechanism working, not the fileset define surviving.\n'
        return 1
    fi
    printf 'the tool was told +define+SEL_FPGA; the packaged core carries the parameters and not the define.\n'
    return 0
}

t_check pkg.fixture.definedrop \
    "the fixture reproduces CONTRACT 9.2: told the define, the packaged core carries the parameters and not the define" \
    fixture_drops_define "$FLOW_DIR"

# THE PROOF IS FROM THE INPUT SIDE, not a mutant of the toolkit: with the same
# name in RTL_DEFINES_INBODY the toolkit bakes it into the packaged copy, so
# "the define did not reach the core" must go red. A fixture that stayed green
# either way would be a fixture in which nothing ever reaches the core.
t_check_fail pkg.fixture.definedrop.mutation \
    "with SEL_FPGA in RTL_DEFINES_INBODY the toolkit bakes it into the packaged copy and the fixture check goes red" \
    fixture_drops_define "$FLOW_DIR" FPGA_RTL_DEFINES_INBODY=SEL_FPGA

## definedrop_named <toolkit>
definedrop_named() {
    local tk="$1"
    use_sources "$SRC_DEF"
    pkg_run "$tk"
    show_run
    local in_man in_gate
    in_man="$(sed -n '/^# 8\./,$p' "$MAN" 2>/dev/null | grep -c 'SEL_FPGA')"
    in_gate="$( { gate_section "$GATE" '^HARD FAILURES'; gate_section "$GATE" '^DECLARED ELSEWHERE'; } | grep -c 'SEL_FPGA')"
    printf 'SEL_FPGA named: %s time(s) in manifest block 8, %s in the gate HARD/DELEGATED bullets\n' "$in_man" "$in_gate"
    if [ "${in_man:-0}" -gt 0 ] || [ "${in_gate:-0}" -gt 0 ]; then return 0; fi
    # THE CONTROL RUN, and it is what turns "the stage did not name it" into "the
    # stage cannot tell the two designs apart". The same project with NO fileset
    # define at all is packaged, and the define-related lines of both artefacts
    # are compared. Identical output means the gate's delegated bullet is
    # unconditional prose: it is emitted on a design that is about to lose its
    # selection macro and on one that has nothing to lose, so no reader and no
    # consumer can distinguish them.
    local with_ev="$SB/definedrop_with.txt" without_ev="$SB/definedrop_without.txt"
    { grep -i 'define' "$MAN" "$GATE" 2>/dev/null | sed "s|$SB||g"; } > "$with_ev"
    use_sources "$SRC_NODEF"
    pkg_run "$tk"
    { grep -i 'define' "$MAN" "$GATE" 2>/dev/null | sed "s|$SB||g"; } > "$without_ev"
    use_sources "$SRC_DEF"
    printf 'The fileset carries +define+SEL_FPGA, demo_block.v reads it, RTL_DEFINES_INBODY is\n'
    printf 'empty, and nothing this stage wrote names SEL_FPGA.\n'
    if diff -q "$with_ev" "$without_ev" >/dev/null 2>&1; then
        printf 'CONTROL: every define-related line of the manifest and the gate is BYTE-IDENTICAL\n'
        printf 'to the same run with no fileset define at all, so the stage does not discriminate.\n'
    else
        printf 'CONTROL: the two runs differ, so something here does vary with the define:\n'
        diff "$with_ev" "$without_ev" | sed 's/^/  /' | head -6
    fi
    return 1
}
t_known_defect pkg.definedrop.detected \
    "the stage NAMES a fileset define that a packaged file reads and that in-body does not bake in (manifest block 8 or gate bullets)" \
    definedrop_named "$FLOW_DIR"
t_skip pkg.definedrop.detected.mutation \
    "the detection does not exist today, so there is no line to remove - the proof lands with the fix, and this marker goes red the day pkg.definedrop.detected starts passing"

## definedrop_not_green <toolkit>
definedrop_not_green() {
    local tk="$1"
    use_sources "$SRC_DEF"
    pkg_run "$tk"
    show_run
    local hf
    hf="$(grep -E '^HARD FAILURES:' "$GATE" 2>/dev/null)"
    printf 'gate: %s\n' "${hf:-<no gate>}"
    if [ "$PKG_RC" -ne 0 ] && [ -n "$hf" ] && [ "$hf" != "HARD FAILURES: none" ]; then return 0; fi
    printf 'a design whose selection macro will not survive packaging came out GREEN.\n'
    return 1
}
t_known_defect pkg.definedrop.verdict \
    "and the verdict is not green on it: HARD FAILURES is not 'none' and the exit is non-zero" \
    definedrop_not_green "$FLOW_DIR"
t_skip pkg.definedrop.verdict.mutation \
    "no verdict on the dropped define exists today, so no line can be planted against it - the proof lands with the fix"


#=============================================================================
# 2. RTL_DEFINES_INBODY - THE MECHANISM THAT DOES SURVIVE, AND ITS RECORD
#
# The stage's answer to section 1 is to write the define INTO a copy of every
# file that reads it and package the copy. Each step of that is a place where a
# silent no-op looks like success: a copy nobody swapped into the fileset, an
# `undef that stopped being written (the macro then leaks into every file read
# after), a header copy that went on the END of the include path (the original
# shadows it), a record with the wrong hash.
#=============================================================================
t_head "2. RTL_DEFINES_INBODY: materialised, swapped in, shadowed, recorded"

## inbody_run <toolkit> - the in-body scenario; 0 when the stage completed
inbody_run() {
    use_sources "$SRC_DEF"
    pkg_run "$1" FPGA_RTL_DEFINES_INBODY=SEL_FPGA
    show_run
    [ "$PKG_RC" -eq 0 ] && [ -s "$MAN" ]
}

## inbody_copy_has_define_and_undef <toolkit>
inbody_copy_has_define_and_undef() {
    inbody_run "$1" || return 1
    local copy="$RUN/work/inbody/demo_block.v" d u m
    [ -f "$copy" ] || { printf 'no materialised copy at %s\n' "$copy"; return 1; }
    d="$(grep -nE '^`define[[:space:]]+SEL_FPGA' "$copy" | sed -n 1p | cut -d: -f1)"
    m="$(grep -nE '^module[[:space:]]+demo_block' "$copy" | sed -n 1p | cut -d: -f1)"
    u="$(grep -nE '^`undef[[:space:]]+SEL_FPGA' "$copy" | tail -1 | cut -d: -f1)"
    printf 'copy: define at line %s, module at %s, undef at %s\n' "${d:-none}" "${m:-none}" "${u:-none}"
    if [ -n "$d" ] && [ -n "$m" ] && [ -n "$u" ] && [ "$d" -lt "$m" ] && [ "$m" -lt "$u" ]; then return 0; fi
    printf 'a source copy needs `define before the module and `undef after it - a macro left\n'
    printf 'standing leaks into every file read after this one, which is a different design.\n'
    return 1
}
t_check pkg.inbody.copy \
    "the source copy carries \`define before the module and \`undef after it" \
    inbody_copy_has_define_and_undef "$FLOW_DIR"

M="$(t_mutant "$SB" inbody-no-undef)"
if [ -n "$M" ] && t_replace_line "$M" "$STAGE_REL" \
        '            puts $out "\`undef $n"' \
        '            puts $out "// undef $n (mutation: the macro is left standing)"'; then
    t_check_fail pkg.inbody.copy.mutation \
        "with the \`undef no longer written, the macro leaks past the file and the check goes red" \
        inbody_copy_has_define_and_undef "$M"
else
    t_skip pkg.inbody.copy.mutation "could not plant the fault: the \`undef emission in inbody_materialise has changed shape"
fi

## inbody_swapped_into_fileset <toolkit>
## THE RECORD, NOT THE LOG: remove_files on the original, then add_files on the
## copy, in that order, after the original was read.
inbody_swapped_into_fileset() {
    inbody_run "$1" || return 1
    local rd rm ad
    rd="$(rec_first "^read_verilog .*/rtl/demo_block\.v$")"
    rm="$(rec_first "^remove_files .*/rtl/demo_block\.v$")"
    ad="$(rec_first "^add_files .* .*/inbody/demo_block\.v$")"
    printf 'record: read_verilog original at %s, remove_files at %s, add_files copy at %s\n' "${rd:-none}" "${rm:-none}" "${ad:-none}"
    if [ -n "$rd" ] && [ -n "$rm" ] && [ -n "$ad" ] && [ "$rd" -lt "$rm" ] && [ "$rm" -lt "$ad" ]; then return 0; fi
    printf 'the copy was written but the ORIGINAL is still what the fileset holds. That is a\n'
    printf 'directory full of correct files that nothing reads, and it looks like success.\n'
    return 1
}
t_check pkg.inbody.swap \
    "the original is removed from the fileset and the copy added, in that order" \
    inbody_swapped_into_fileset "$FLOW_DIR"

M="$(t_mutant "$SB" inbody-no-swap)"
if [ -n "$M" ] && t_replace_line "$M" "$STAGE_REL" \
        '                remove_files $orig' \
        '                # remove_files $orig   (mutation: the original stays in the fileset)'; then
    t_check_fail pkg.inbody.swap.mutation \
        "with remove_files gone the original stays in the fileset beside the copy and the check goes red" \
        inbody_swapped_into_fileset "$M"
else
    t_skip pkg.inbody.swap.mutation "could not plant the fault: the remove_files call in section 5.1 has changed shape"
fi

## inbody_header_shadow_first <toolkit>
inbody_header_shadow_first() {
    inbody_run "$1" || return 1
    local h="$RUN/work/inbody/include/cfg.vh" line first
    [ -f "$h" ] || { printf 'no materialised header at %s\n' "$h"; return 1; }
    if ! grep -qE '^`define[[:space:]]+SEL_FPGA' "$h"; then printf 'the header copy carries no `define SEL_FPGA\n'; return 1; fi
    if grep -qE '^`undef[[:space:]]+SEL_FPGA' "$h"; then
        printf 'the header copy carries an `undef - the includer would never see the macro\n'; return 1
    fi
    line="$(grep -E '^set_property include_dirs ' "$REC" | tail -1)"
    first="$(printf '%s\n' "$line" | awk '{print $3}')"
    printf 'last include_dirs assignment: %s\n' "$line"
    if [ "$first" = "$RUN/work/inbody/include" ]; then return 0; fi
    printf 'the shadow directory is not FIRST on the include path. The original header would\n'
    printf 'be found before the copy, and the copy would be a correct file nothing reads.\n'
    return 1
}
t_check pkg.inbody.header \
    "a header that reads the name is copied with \`define and no \`undef, and its directory goes FIRST on the include path" \
    inbody_header_shadow_first "$FLOW_DIR"

M="$(t_mutant "$SB" inbody-shadow-last)"
if [ -n "$M" ] && t_replace_line "$M" "$STAGE_REL" \
        '                [concat [list $shadow] [get_property include_dirs $fs]] $fs' \
        '                [concat [get_property include_dirs $fs] [list $shadow]] $fs'; then
    t_check_fail pkg.inbody.header.mutation \
        "with the shadow directory appended LAST instead of first, the check goes red" \
        inbody_header_shadow_first "$M"
else
    t_skip pkg.inbody.header.mutation "could not plant the fault: the shadow include_dirs assignment has changed shape"
fi

## inbody_record_is_true <toolkit>
## The record names both files, and each sha256 it prints is the sha256 of the
## file it names - checked against sha256sum, not against the stage's own say-so.
inbody_record_is_true() {
    inbody_run "$1" || return 1
    [ -s "$INBODY" ] || { printf 'no in-body record at %s\n' "$INBODY"; return 1; }
    local n want got f
    n="$(grep -cE '^  kind[[:space:]]' "$INBODY")"
    printf 'record: %s entr(ies); manifest inbody_files=%s inbody_headers=%s\n' "$n" "$(mf_get "$MAN" inbody_files)" "$(mf_get "$MAN" inbody_headers)"
    if [ "$n" -ne 2 ] || [ "$(mf_get "$MAN" inbody_files)" != 2 ] || [ "$(mf_get "$MAN" inbody_headers)" != 1 ]; then
        printf 'expected one source and one header materialised\n'; return 1
    fi
    # Every `materialised <path>` line is followed by a sha256 line; compare.
    for f in "$RUN/work/inbody/demo_block.v" "$RUN/work/inbody/include/cfg.vh"; do
        want="$(sha256sum "$f" | cut -d' ' -f1)"
        got="$(grep -A1 -F "materialised <run>/${f#$RUN/}" "$INBODY" | grep -E '^  sha256' | awk '{print $2}')"
        if [ "$got" != "$want" ]; then
            printf 'sha256 recorded for %s is %s; the file hashes to %s\n' "${f#$RUN/}" "${got:-<absent>}" "$want"
            return 1
        fi
    done
    if ! grep -qE '^  baked in[[:space:]]+SEL_FPGA' "$INBODY"; then printf 'the record does not say what was baked in\n'; return 1; fi
    return 0
}
t_check pkg.inbody.record \
    "package_ip_inbody.txt names both copies with sha256s that match the files, and the manifest counts agree" \
    inbody_record_is_true "$FLOW_DIR"

M="$(t_mutant "$SB" inbody-record-unhashed)"
if [ -n "$M" ] && t_replace_line "$M" "$STAGE_REL" \
        '        puts $fh "  sha256      [prov_sha256 [prov_resolve $dst]]"' \
        '        puts $fh "  sha256      unmeasured"'; then
    t_check_fail pkg.inbody.record.mutation \
        "with the copy's sha256 no longer taken, the record disagrees with the file and the check goes red" \
        inbody_record_is_true "$M"
else
    t_skip pkg.inbody.record.mutation "could not plant the fault: the record's sha256 line has changed shape"
fi

## inbody_unmatched_is_hard <toolkit>
## A define that matches nothing is THE defect class in one line - and the
## manifest and gate must be on disk before the die, or the run is lost rather
## than judged.
inbody_unmatched_is_hard() {
    use_sources "$SRC_DEF"
    pkg_run "$1" FPGA_RTL_DEFINES_INBODY=NOPE
    show_run
    printf 'gate: %s; manifest hard_failures: %s\n' "$(grep -E '^HARD FAILURES:' "$GATE" 2>/dev/null)" "$(mf_get "$MAN" hard_failures)"
    if [ "$PKG_RC" -ne 1 ]; then printf 'expected exit 1 (a check failed), got %d\n' "$PKG_RC"; return 1; fi
    grep -qE '^HARD FAILURES: 1' "$GATE" 2>/dev/null || { printf 'the gate does not carry the hard failure\n'; return 1; }
    gate_section "$GATE" '^HARD FAILURES' | grep -q "NOPE" || { printf 'the hard failure does not NAME the define\n'; return 1; }
    [ "$(mf_get "$MAN" hard_failures)" = 1 ] || { printf 'the manifest was not written with hard_failures 1 before the die\n'; return 1; }
    return 0
}
t_check pkg.inbody.unmatched \
    "an in-body define that no file mentions is a HARD failure, named in the gate, with the manifest written before the die" \
    inbody_unmatched_is_hard "$FLOW_DIR"

M="$(t_mutant "$SB" inbody-unmatched-ignored)"
if [ -n "$M" ] && t_replace_line "$M" "$STAGE_REL" \
        '        if {![info exists hit($n)]} {' \
        '        if {0} {'; then
    t_check_fail pkg.inbody.unmatched.mutation \
        "with the matched-nothing check disabled, a define nobody reads is accepted and the check goes red" \
        inbody_unmatched_is_hard "$M"
else
    t_skip pkg.inbody.unmatched.mutation "could not plant the fault: the hit(\$n) test in section 5.3 has changed shape"
fi

# THE OTHER HALF OF EVIDENCE-FIRST: the manifest on the hard-failure path. The
# fault redirects the final manifest write elsewhere, so the die fires with the
# gate written and the manifest not. The `set manifest` line appears twice in
# the stage - once indented in the not-configured block - so the edit is
# addressed to the range after the section-11 heading rather than by text alone.
M="$(t_mutant "$SB" inbody-manifest-after-die)"
if [ -n "$M" ] && t_mutate "$M" "$STAGE_REL" \
        '/^# THE STAGE NAME AND THE ARTEFACT STEM, PASSED SEPARATELY/,$ s/^set manifest \[prov_manifest \$STAGE_NAME \$STAGE_STEM\]$/set manifest [file join $REPORT_DIR never_written.txt]/'; then
    t_check_fail pkg.inbody.unmatched.evidence.mutation \
        "with the final manifest written somewhere else, the evidence is not on disk when the die fires and the check goes red" \
        inbody_unmatched_is_hard "$M"
else
    t_skip pkg.inbody.unmatched.evidence.mutation "could not plant the fault: the section-11 manifest write has changed shape"
fi

## inbody_never_is_hard <toolkit>
inbody_never_is_hard() {
    use_sources "$SRC_DEF"
    pkg_run "$1" FPGA_RTL_DEFINES_INBODY=SEL_FPGA FPGA_RTL_DEFINES_NEVER=SEL_FPGA
    show_run
    printf 'gate: %s\n' "$(grep -E '^HARD FAILURES:' "$GATE" 2>/dev/null)"
    [ "$PKG_RC" -eq 1 ] || { printf 'expected exit 1, got %d\n' "$PKG_RC"; return 1; }
    gate_section "$GATE" '^HARD FAILURES' | grep -q 'RTL_DEFINES_NEVER.*SEL_FPGA' || {
        printf 'the gate does not name SEL_FPGA as asserted-absent AND about to be baked in\n'; return 1; }
    return 0
}
t_check pkg.inbody.never \
    "a name in both RTL_DEFINES_NEVER and RTL_DEFINES_INBODY is a HARD failure - it would be baked where no other check can see it" \
    inbody_never_is_hard "$FLOW_DIR"

M="$(t_mutant "$SB" inbody-never-ignored)"
if [ -n "$M" ] && t_replace_line "$M" "$STAGE_REL" \
        '    if {[lsearch -exact $never $n] >= 0} {' \
        '    if {0} {'; then
    t_check_fail pkg.inbody.never.mutation \
        "with the NEVER intersection check disabled, the forbidden macro is baked in and the check goes red" \
        inbody_never_is_hard "$M"
else
    t_skip pkg.inbody.never.mutation "could not plant the fault: the RTL_DEFINES_NEVER lsearch has changed shape"
fi


#=============================================================================
# 3. RTL_PARAMS - THE MECHANISM THAT SURVIVES, MEASURED RATHER THAN ASSUMED
#=============================================================================
t_head "3. RTL_PARAMS: applied to the core, saved to disk, counted, and missing ones named"

## params_bare_refused <toolkit>
params_bare_refused() {
    use_sources "$SRC_DEF"
    pkg_run "$1" FPGA_RTL_PARAMS="WIDTH"
    show_run
    [ "$PKG_RC" -eq 2 ] || { printf 'expected exit 2 (refused), got %d\n' "$PKG_RC"; return 1; }
    [ ! -e "$MAN" ] && [ ! -e "$GATE" ] || { printf 'a refusal wrote a manifest or a gate\n'; return 1; }
    printf '%s' "$PKG_OUT" | grep -q "RTL_PARAMS entry 'WIDTH' has no '='" || { printf 'the refusal does not name the entry\n'; return 1; }
    return 0
}
t_check pkg.params.bare \
    "an RTL_PARAMS entry with no '=' is refused (exit 2) by name, and nothing is written" \
    params_bare_refused "$FLOW_DIR"

M="$(t_mutant "$SB" params-bare-accepted)"
if [ -n "$M" ] && t_replace_line "$M" "$STAGE_REL" \
        '    if {[string first "=" $p] < 0} {' \
        '    if {0} {'; then
    t_check_fail pkg.params.bare.mutation \
        "with the '=' check disabled, a bare name is carried forward and the check goes red" \
        params_bare_refused "$M"
else
    t_skip pkg.params.bare.mutation "could not plant the fault: the RTL_PARAMS '=' test has changed shape"
fi

## params_saved_to_disk <toolkit>
## The values in component.xml are the RTL_PARAMS values (16, 2), not the RTL
## defaults (8, 4) that package_project read. Only a save after the apply can
## put them there.
params_saved_to_disk() {
    use_sources "$SRC_DEF"
    pkg_run "$1"
    show_run
    local c; c="$(component_under_out)"
    [ "$PKG_RC" -eq 0 ] && [ -n "$c" ] || { printf 'the stage did not complete with a component.xml\n'; return 1; }
    grep -E 'WIDTH|DEPTH' "$c"
    grep -qE '<spirit:name>WIDTH</spirit:name><spirit:value>16</spirit:value>' "$c" \
        && grep -qE '<spirit:name>DEPTH</spirit:name><spirit:value>2</spirit:value>' "$c" && return 0
    printf 'component.xml on disk carries the RTL defaults, not the RTL_PARAMS values.\n'
    printf 'The values were applied to the in-memory core; the file predates the apply.\n'
    return 1
}
t_check pkg.params.saved \
    "component.xml on disk carries the RTL_PARAMS values, so the save happened after the apply" \
    params_saved_to_disk "$FLOW_DIR"

M="$(t_mutant "$SB" params-not-saved)"
if [ -n "$M" ] && t_replace_line "$M" "$STAGE_REL" \
        '    ipx::save_core $core' \
        '    # ipx::save_core $core   (mutation: the file on disk predates every edit)'; then
    t_check_fail pkg.params.saved.mutation \
        "with ipx::save_core gone the file keeps the values package_project wrote and the check goes red" \
        params_saved_to_disk "$M"
else
    t_skip pkg.params.saved.mutation "could not plant the fault: the ipx::save_core call has changed shape"
fi

## params_counted <toolkit>
params_counted() {
    use_sources "$SRC_DEF"
    pkg_run "$1"
    show_run
    printf 'params_requested=%s params_packaged=%s params_missing=%s\n' \
        "$(mf_get "$MAN" params_requested)" "$(mf_get "$MAN" params_packaged)" "$(mf_get "$MAN" params_missing)"
    [ "$PKG_RC" -eq 0 ] || return 1
    [ "$(mf_get "$MAN" params_requested)" = 2 ] && [ "$(mf_get "$MAN" params_packaged)" = 2 ] \
        && [ "$(mf_get "$MAN" params_missing)" = "(none)" ]
}
t_check pkg.params.count \
    "the manifest counts 2 requested, 2 packaged, none missing" \
    params_counted "$FLOW_DIR"

M="$(t_mutant "$SB" params-not-counted)"
if [ -n "$M" ] && t_replace_line "$M" "$STAGE_REL" \
        '            incr params_packaged' \
        '            # incr params_packaged'; then
    t_check_fail pkg.params.count.mutation \
        "with the counter no longer incremented the manifest says 0 of 2 and the check goes red" \
        params_counted "$M"
else
    t_skip pkg.params.count.mutation "could not plant the fault: the params_packaged increment has changed shape"
fi

## params_missing_hard <toolkit>
params_missing_hard() {
    use_sources "$SRC_DEF"
    pkg_run "$1" FPGA_RTL_PARAMS="FOO=1"
    show_run
    printf 'gate: %s; params_missing=%s\n' "$(grep -E '^HARD FAILURES:' "$GATE" 2>/dev/null)" "$(mf_get "$MAN" params_missing)"
    [ "$PKG_RC" -eq 1 ] || { printf 'expected exit 1, got %d\n' "$PKG_RC"; return 1; }
    gate_section "$GATE" '^HARD FAILURES' | grep -q "RTL_PARAMS names 'FOO'" || { printf 'the hard failure does not name FOO\n'; return 1; }
    [ "$(mf_get "$MAN" params_missing)" = FOO ]
}
t_check pkg.params.missing.hard \
    "a parameter the packaged core does not carry is a HARD failure naming it (PACKAGE_IP_REQUIRE_PARAMS=1)" \
    params_missing_hard "$FLOW_DIR"

M="$(t_mutant "$SB" params-missing-soft)"
if [ -n "$M" ] && t_mutate "$M" "$STAGE_REL" \
        's/lappend hard "RTL_PARAMS names/lappend __ignored "RTL_PARAMS names/'; then
    t_check_fail pkg.params.missing.hard.mutation \
        "with the hard failure no longer recorded, a value that reaches nothing passes and the check goes red" \
        params_missing_hard "$M"
else
    t_skip pkg.params.missing.hard.mutation "could not plant the fault: the missing-parameter lappend has changed shape"
fi

## params_missing_soft <toolkit>
## REQUIRE_PARAMS=0 is a choice a project may make; the manifest still has to
## NAME what was missing, and 0 packaged is a MEASURED zero, not unmeasured.
params_missing_soft() {
    use_sources "$SRC_DEF"
    pkg_run "$1" FPGA_RTL_PARAMS="FOO=1" PACKAGE_IP_REQUIRE_PARAMS=0
    show_run
    printf 'gate: %s; params_missing=%s packaged=%s\n' "$(grep -E '^HARD FAILURES:' "$GATE" 2>/dev/null)" \
        "$(mf_get "$MAN" params_missing)" "$(mf_get "$MAN" params_packaged)"
    [ "$PKG_RC" -eq 0 ] || return 1
    grep -qE '^HARD FAILURES: none' "$GATE" || return 1
    [ "$(mf_get "$MAN" params_missing)" = FOO ] && [ "$(mf_get "$MAN" params_packaged)" = 0 ]
}
t_check pkg.params.missing.soft \
    "with PACKAGE_IP_REQUIRE_PARAMS=0 the run is green and the manifest still NAMES the missing parameter" \
    params_missing_soft "$FLOW_DIR"

M="$(t_mutant "$SB" params-missing-unnamed)"
if [ -n "$M" ] && t_mutate "$M" "$STAGE_REL" \
        's/\[llength $params_missing\] ?/0 ?/'; then
    t_check_fail pkg.params.missing.soft.mutation \
        "with params_missing hardwired to (none), the name is lost and the check goes red" \
        params_missing_soft "$M"
else
    t_skip pkg.params.missing.soft.mutation "could not plant the fault: the params_missing field has changed shape"
fi

## params_unmeasured_without_core <toolkit>
## The packaging script closed the core. Whether the parameters reached it is
## UNKNOWN, and the manifest must say `unmeasured` - never 0, which is a
## measurement (CONTRACT.md section 0, rule 2).
params_unmeasured_without_core() {
    use_sources "$SRC_DEF"
    pkg_run "$1" FPGA_PACKAGE_TCL="$PROJ/package_unload.tcl"
    show_run
    printf 'params_packaged=%s\n' "$(mf_get "$MAN" params_packaged)"
    [ "$PKG_RC" -eq 0 ] || return 1
    [ "$(mf_get "$MAN" params_packaged)" = unmeasured ]
}
t_check pkg.params.unmeasured \
    "when PACKAGE_TCL closed the core, params_packaged is the token 'unmeasured', not 0" \
    params_unmeasured_without_core "$FLOW_DIR"

M="$(t_mutant "$SB" params-unmeasured-as-zero)"
if [ -n "$M" ] && t_mutate "$M" "$STAGE_REL" \
        's/\[llength $params\] \&\& $core eq "" ?/0 ?/'; then
    t_check_fail pkg.params.unmeasured.mutation \
        "with the unmeasured branch removed the manifest writes 0 for a count nobody took and the check goes red" \
        params_unmeasured_without_core "$M"
else
    t_skip pkg.params.unmeasured.mutation "could not plant the fault: the params_packaged field expression has changed shape"
fi


#=============================================================================
# 4. THE CORE: VLNV, ITS LOCATION, AND WHAT THE STAGE RECORDS ABOUT IT
#
# IP_VENDOR and IP_CORE_REV come from design.mk and are published to
# PACKAGE_TCL as ::IP_VENDOR and ::IP_CORE_REV. "Land in what it records" is
# asserted on the manifest's vlnv field and on the directory the core went
# into, both of which are built from the published values. The mutants replace
# the publication with the DEFAULT the stage would otherwise use - the exact
# shape of a stage that ignores its configuration and looks configured.
#=============================================================================
t_head "4. IP_VENDOR and IP_CORE_REV land in the record; a rev that does not parse"

## vlnv_carries <toolkit> <expected vlnv> <expected dir tail>
vlnv_carries() {
    local tk="$1" want="$2" dir="$3" c
    use_sources "$SRC_DEF"
    pkg_run "$tk"
    show_run
    c="$(component_under_out)"
    printf 'vlnv=%s component=%s\n' "$(mf_get "$MAN" vlnv)" "${c#$RUN/}"
    [ "$PKG_RC" -eq 0 ] || return 1
    [ "$(mf_get "$MAN" vlnv)" = "$want" ] || { printf 'expected vlnv %s\n' "$want"; return 1; }
    [ "$c" = "$RUN/outputs/ip/$dir/component.xml" ] || { printf 'expected the core under outputs/ip/%s\n' "$dir"; return 1; }
    grep -qE "<spirit:version>${want##*:}</spirit:version>" "$c"
}
t_check pkg.vlnv.vendor_rev \
    "IP_VENDOR=acme.example and IP_CORE_REV=3 reach the recorded vlnv, the core's directory and component.xml" \
    vlnv_carries "$FLOW_DIR" "acme.example:user:demo_block:3" "acme.example_user_demo_block_3"

M="$(t_mutant "$SB" vendor-defaulted)"
if [ -n "$M" ] && t_replace_line "$M" "$STAGE_REL" \
        'set ::IP_VENDOR        $IP_VENDOR' \
        'set ::IP_VENDOR        soclabs.org'; then
    t_check_fail pkg.vlnv.vendor.mutation \
        "with ::IP_VENDOR published as the default instead of the configured value, the check goes red" \
        vlnv_carries "$M" "acme.example:user:demo_block:3" "acme.example_user_demo_block_3"
else
    t_skip pkg.vlnv.vendor.mutation "could not plant the fault: the ::IP_VENDOR publication has changed shape"
fi

M="$(t_mutant "$SB" rev-defaulted)"
if [ -n "$M" ] && t_replace_line "$M" "$STAGE_REL" \
        'set ::IP_CORE_REV      $IP_CORE_REV' \
        'set ::IP_CORE_REV      1'; then
    t_check_fail pkg.vlnv.rev.mutation \
        "with ::IP_CORE_REV published as the default instead of the configured value, the check goes red" \
        vlnv_carries "$M" "acme.example:user:demo_block:3" "acme.example_user_demo_block_3"
else
    t_skip pkg.vlnv.rev.mutation "could not plant the fault: the ::IP_CORE_REV publication has changed shape"
fi

## rev_unparseable_refused <toolkit>
## `1/2` is not a version by any reading, and it contains a path separator: the
## stage composes IP_ROOT_DIR from it. MEASURED on this fixture: the stage
## accepts it, creates outputs/ip/<v>_<l>_<n>_1/2/, packages under it, and
## then prov_path_value - seeing a slash - rewrites the manifest's vlnv field
## into a `<run>/work/...` path label that names no file. Nothing refuses,
# nothing warns; the record is corrupted in the one field assert-stage reads.
rev_unparseable_refused() {
    use_sources "$SRC_DEF"
    pkg_run "$1" FPGA_IP_CORE_REV="1/2"
    show_run
    printf 'vlnv=%s; under outputs/ip: %s\n' "$(mf_get "$MAN" vlnv)" "$(find "$RUN/outputs/ip" -mindepth 1 -maxdepth 2 -type d 2>/dev/null | sed "s|$RUN/outputs/ip/||" | tr '\n' ' ')"
    [ "$PKG_RC" -eq 2 ] || { printf 'expected exit 2 (refused), got %d - the rev was accepted and used\n' "$PKG_RC"; return 1; }
    [ ! -e "$MAN" ] || { printf 'a refusal wrote a manifest\n'; return 1; }
    return 0
}
t_known_defect pkg.rev.unparseable \
    "an IP_CORE_REV that is not a version (here '1/2') is refused (exit 2) rather than composed into the output path and the vlnv" \
    rev_unparseable_refused "$FLOW_DIR"
t_skip pkg.rev.unparseable.mutation \
    "no rev validation exists today, so there is no line to remove - the proof lands with the fix, and this marker goes red the day pkg.rev.unparseable starts passing"

## vlnv_read_from_disk <toolkit>
## No core object after PACKAGE_TCL: the VLNV is a fact in the file and must be
## read from there, not reported UNVERIFIED.
vlnv_read_from_disk() {
    use_sources "$SRC_DEF"
    pkg_run "$1" FPGA_PACKAGE_TCL="$PROJ/package_unload.tcl"
    show_run
    printf 'vlnv=%s\n' "$(mf_get "$MAN" vlnv)"
    [ "$PKG_RC" -eq 0 ] && [ "$(mf_get "$MAN" vlnv)" = "acme.example:user:demo_block:3" ]
}
t_check pkg.vlnv.fromdisk \
    "with the core closed by PACKAGE_TCL, the vlnv is read out of component.xml rather than reported UNVERIFIED" \
    vlnv_read_from_disk "$FLOW_DIR"

M="$(t_mutant "$SB" vlnv-not-read)"
if [ -n "$M" ] && t_replace_line "$M" "$STAGE_REL" \
        '    if {[llength $parts] == 4} { set vlnv [join $parts ":"] }' \
        '    if {0} { set vlnv [join $parts ":"] }'; then
    t_check_fail pkg.vlnv.fromdisk.mutation \
        "with the four-tag digest no longer assembled, vlnv stays UNVERIFIED and the check goes red" \
        vlnv_read_from_disk "$M"
else
    t_skip pkg.vlnv.fromdisk.mutation "could not plant the fault: the vlnv digest line has changed shape"
fi

## core_relocated <toolkit>
core_relocated() {
    use_sources "$SRC_DEF"
    pkg_run "$1" FPGA_PACKAGE_TCL="$PROJ/package_elsewhere.tcl"
    show_run
    local c; c="$(component_under_out)"
    printf 'component_xml=%s relocated=%s\n' "$(mf_get "$MAN" component_xml)" "$(mf_get "$MAN" component_relocated)"
    [ "$PKG_RC" -eq 0 ] || return 1
    [ -n "$c" ] || { printf 'no component.xml under outputs/ip - make and assert-stage both look there\n'; return 1; }
    [ "$(mf_get "$MAN" component_relocated)" = yes ] || { printf 'the manifest does not record the copy\n'; return 1; }
    [ -f "$RUN/work/package_ip/mycore/component.xml" ] || { printf 'the original was not left alone\n'; return 1; }
    return 0
}
t_check pkg.relocate \
    "a core PACKAGE_TCL wrote outside \$(OUT_DIR)/ip is COPIED under it, the manifest says so, and the original is left alone" \
    core_relocated "$FLOW_DIR"

M="$(t_mutant "$SB" no-relocate)"
if [ -n "$M" ] && t_replace_line "$M" "$STAGE_REL" \
        '    if {!$under_out} {' \
        '    if {0} {'; then
    t_check_fail pkg.relocate.mutation \
        "with the relocation disabled the core stays where nothing looks and the check goes red" \
        core_relocated "$M"
else
    t_skip pkg.relocate.mutation "could not plant the fault: the under_out test has changed shape"
fi

## no_component_is_hard <toolkit>
no_component_is_hard() {
    use_sources "$SRC_DEF"
    pkg_run "$1" FPGA_PACKAGE_TCL="$PROJ/package_nothing.tcl"
    show_run
    printf 'gate: %s; component_xml=%s\n' "$(grep -E '^HARD FAILURES:' "$GATE" 2>/dev/null)" "$(mf_get "$MAN" component_xml)"
    [ "$PKG_RC" -eq 1 ] || { printf 'expected exit 1, got %d\n' "$PKG_RC"; return 1; }
    gate_section "$GATE" '^HARD FAILURES' | grep -q 'no component.xml exists' || return 1
    [ "$(mf_get "$MAN" component_xml)" = "UNVERIFIED:no-component.xml" ]
}
t_check pkg.nocomponent \
    "a PACKAGE_TCL that packages nothing is a HARD failure, and component_xml is UNVERIFIED rather than blank" \
    no_component_is_hard "$FLOW_DIR"

M="$(t_mutant "$SB" nocomponent-ignored)"
if [ -n "$M" ] && t_mutate "$M" "$STAGE_REL" \
        's/lappend hard "no component.xml exists/lappend __ignored "no component.xml exists/'; then
    t_check_fail pkg.nocomponent.mutation \
        "with the missing-core hard failure no longer recorded, a run that packaged nothing passes and the check goes red" \
        no_component_is_hard "$M"
else
    t_skip pkg.nocomponent.mutation "could not plant the fault: the no-component lappend has changed shape"
fi


#=============================================================================
# 5. REFUSALS - EXIT 2, NOTHING WRITTEN
#
# `1` and `2` are "we looked and found something" and "we could not look"
# (CONTRACT.md section 10), and a refusal leaves no artefact a later reader
# could mistake for a verdict. Each is graded from the SHELL's view of the
# exit code and then from the disk.
#=============================================================================
t_head "5. refusals: exit 2 and nothing written"

## refused_clean - after pkg_run: exit 2, no manifest, gate, record or core
refused_clean() {
    show_run
    [ "$PKG_RC" -eq 2 ] || { printf 'expected exit 2 (refused), got %d\n' "$PKG_RC"; return 1; }
    if [ -e "$MAN" ] || [ -e "$GATE" ] || [ -e "$INBODY" ] || [ -n "$(component_under_out)" ]; then
        printf 'a refusal left a manifest, gate, in-body record or component.xml behind\n'; return 1
    fi
    return 0
}

## packagetcl_missing_refused <toolkit>
packagetcl_missing_refused() {
    use_sources "$SRC_DEF"
    pkg_run "$1" FPGA_PACKAGE_TCL="$PROJ/no_such_package.tcl"
    refused_clean || return 1
    printf '%s' "$PKG_OUT" | grep -q 'no file at .*no_such_package.tcl' || { printf 'the refusal does not name the missing file\n'; return 1; }
    return 0
}
t_check pkg.refuse.packagetcl \
    "PACKAGE_TCL naming a file that does not exist is refused by name, exit 2, nothing written" \
    packagetcl_missing_refused "$FLOW_DIR"

M="$(t_mutant "$SB" packagetcl-unchecked)"
if [ -n "$M" ] && t_mutate "$M" "$STAGE_REL" \
        's/flow_assert_input $PACKAGE_TCL/flow_assert_input [info script]/'; then
    t_check_fail pkg.refuse.packagetcl.mutation \
        "with the input assertion pointed at a file that exists, the missing script is discovered by source at exit 1 and the check goes red" \
        packagetcl_missing_refused "$M"
else
    t_skip pkg.refuse.packagetcl.mutation "could not plant the fault: the PACKAGE_TCL flow_assert_input has changed shape"
fi

## sources_missing_refused <toolkit> - READ_SOURCES=1 and no sources.tcl
sources_missing_refused() {
    pkg_run "$1" FPGA_WORK_DIR="$SB/emptywork"
    refused_clean || return 1
    printf '%s' "$PKG_OUT" | grep -q 'no source list at' || { printf 'the refusal does not say what is missing\n'; return 1; }
    return 0
}
t_check pkg.refuse.sources \
    "no sources.tcl from the flist stage is refused, exit 2, nothing written" \
    sources_missing_refused "$FLOW_DIR"

M="$(t_mutant "$SB" sources-unchecked)"
if [ -n "$M" ] && t_replace_line "$M" "$STAGE_REL" \
        'if {$PACKAGE_IP_READ_SOURCES && (![file exists $SOURCES_TCL] || ![file size $SOURCES_TCL])} {' \
        'if {0} {'; then
    t_check_fail pkg.refuse.sources.mutation \
        "with the sources.tcl check disabled, the missing file is discovered by source at exit 1 and the check goes red" \
        sources_missing_refused "$M"
else
    t_skip pkg.refuse.sources.mutation "could not plant the fault: the sources.tcl existence test has changed shape"
fi

## no_create_project_refused <toolkit>
no_create_project_refused() {
    use_sources "$SRC_DEF"
    pkg_run "$1" T_PKG_NO_CREATE_PROJECT=1
    refused_clean || return 1
    printf '%s' "$PKG_OUT" | grep -q 'this tool has no create_project' || { printf 'the refusal does not say why\n'; return 1; }
    return 0
}
t_check pkg.refuse.nocreateproject \
    "a tool with no create_project is refused (exit 2) rather than crashed into" \
    no_create_project_refused "$FLOW_DIR"

M="$(t_mutant "$SB" createproject-unchecked)"
if [ -n "$M" ] && t_replace_line "$M" "$STAGE_REL" \
        '    if {![flow_have create_project]} {' \
        '    if {0} {'; then
    t_check_fail pkg.refuse.nocreateproject.mutation \
        "with the flow_have guard disabled, the stage crashes on the missing command at exit 1 and the check goes red" \
        no_create_project_refused "$M"
else
    t_skip pkg.refuse.nocreateproject.mutation "could not plant the fault: the create_project flow_have test has changed shape"
fi

## iprepos_missing_refused <toolkit>
iprepos_missing_refused() {
    use_sources "$SRC_DEF"
    pkg_run "$1" FPGA_IP_REPOS="$SB/repo_a $SB/no_such_repo"
    refused_clean || return 1
    printf '%s' "$PKG_OUT" | grep -q 'no file at .*no_such_repo' || { printf 'the refusal does not name the repository\n'; return 1; }
    return 0
}
t_check pkg.refuse.iprepos \
    "an IP_REPOS entry that does not exist is refused by name, exit 2, no manifest, gate or core" \
    iprepos_missing_refused "$FLOW_DIR"

M="$(t_mutant "$SB" iprepos-unchecked)"
if [ -n "$M" ] && t_replace_line "$M" "$STAGE_REL" \
        '        flow_assert_input [string trim $r] "an IP repository named by IP_REPOS" IP_REPOS' \
        '        # (mutation) IP_REPOS entries are not checked'; then
    t_check_fail pkg.refuse.iprepos.mutation \
        "with the IP_REPOS assertion removed, a repository that does not exist is handed to the tool and the check goes red" \
        iprepos_missing_refused "$M"
else
    t_skip pkg.refuse.iprepos.mutation "could not plant the fault: the IP_REPOS flow_assert_input has changed shape"
fi

## iprepos_refusal_leaves_nothing <toolkit>
## The refusal above is real, but it comes AFTER create_project and after
## IP_ROOT_DIR is made. MEASURED: outputs/ip/<vendor>_<lib>_<name>_<rev>/ exists,
## empty, after the exit 2 - and under Vivado, create_project has written a
## project tree into work/ first. flow_utils.tcl section 5 asserts every
## required path "before a licence-hour is spent on it"; this one is asserted
## after the tool has started writing.
iprepos_refusal_leaves_nothing() {
    use_sources "$SRC_DEF"
    pkg_run "$1" FPGA_IP_REPOS="$SB/no_such_repo"
    show_run
    local left; left="$(find "$RUN/outputs/ip" -mindepth 1 2>/dev/null | sed "s|$RUN/||" | tr '\n' ' ')"
    printf 'left under outputs/ip: %s; create_project recorded: %s\n' "${left:-(nothing)}" "$(grep -c '^create_project' "$REC" 2>/dev/null || echo 0)"
    [ "$PKG_RC" -eq 2 ] || return 1
    [ -z "$left" ] || { printf 'the refusal left a directory under outputs/ip\n'; return 1; }
    [ "$(grep -c '^create_project' "$REC" 2>/dev/null || echo 0)" = 0 ] || { printf 'the tool was asked to create a project before the input was checked\n'; return 1; }
    return 0
}
t_known_defect pkg.refuse.iprepos.clean \
    "the IP_REPOS refusal happens BEFORE create_project and before outputs/ip/<root> is made, so exit 2 leaves nothing" \
    iprepos_refusal_leaves_nothing "$FLOW_DIR"
t_skip pkg.refuse.iprepos.clean.mutation \
    "the IP_REPOS check sits after create_project today; there is no early check to remove - the proof lands with the fix"


#=============================================================================
# 6. NOT CONFIGURED - A FACT ON DISK, NOT AN ABSENCE (CONTRACT.md 12.2 rule 7)
#
# From disk alone, a stage that was switched off and a stage that died before
# writing anything look identical. So the not-configured path writes a manifest
# saying so, exits 0, and DELETES a gate an earlier run of the same tag may
# have left - a verdict about a stage that did not run is worse than none.
#=============================================================================
t_head "6. not configured: manifest says so, exit 0, and a stale gate is removed"

## not_configured_manifest <toolkit>
not_configured_manifest() {
    pkg_run "$1" FPGA_PACKAGE_TCL=""
    show_run
    printf 'stage_configured=%s package_tcl=%s stage=%s\n' "$(mf_get "$MAN" stage_configured)" "$(mf_get "$MAN" package_tcl)" "$(mf_get "$MAN" stage)"
    [ "$PKG_RC" -eq 0 ] || { printf 'expected exit 0, got %d\n' "$PKG_RC"; return 1; }
    [ -s "$MAN" ] || { printf 'no manifest - switched off is indistinguishable from died\n'; return 1; }
    [ "$(mf_get "$MAN" stage_configured)" = no ] || return 1
    [ "$(mf_get "$MAN" package_tcl)" = "(none)" ] || return 1
    [ "$(mf_get "$MAN" stage)" = package-ip ] || return 1
    [ ! -e "$GATE" ] || { printf 'a gate was written for a stage that did not run\n'; return 1; }
    return 0
}
t_check pkg.notconfigured \
    "with PACKAGE_TCL empty: exit 0, a manifest with stage_configured no and package_tcl (none), and no gate" \
    not_configured_manifest "$FLOW_DIR"

M="$(t_mutant "$SB" notconfigured-says-yes)"
if [ -n "$M" ] && t_mutate "$M" "$STAGE_REL" \
        's/stage_configured   no /stage_configured   yes /'; then
    t_check_fail pkg.notconfigured.mutation \
        "with the manifest claiming the stage was configured, the check goes red" \
        not_configured_manifest "$M"
else
    t_skip pkg.notconfigured.mutation "could not plant the fault: the stage_configured field in the not-configured block has changed shape"
fi

M="$(t_mutant "$SB" notconfigured-exit-2)"
if [ -n "$M" ] && t_replace_line "$M" "$STAGE_REL" \
        '    exit 0' \
        '    exit 2'; then
    t_check_fail pkg.notconfigured.exit.mutation \
        "with the not-configured path exiting 2 instead of 0, a design with no IP to package fails the build and the check goes red" \
        not_configured_manifest "$M"
else
    t_skip pkg.notconfigured.exit.mutation "could not plant the fault: the not-configured 'exit 0' has changed shape"
fi

## stale_gate_removed <toolkit>
stale_gate_removed() {
    pkg_run "$1" FPGA_PACKAGE_TCL="" T_PKG_PLANT_STALE=1
    show_run
    printf 'stale_gate_removed=%s gate exists: %s\n' "$(mf_get "$MAN" stale_gate_removed)" "$([ -e "$GATE" ] && echo yes || echo no)"
    [ "$PKG_RC" -eq 0 ] || return 1
    [ ! -e "$GATE" ] || { printf 'the stale gate from the earlier run is still there, and assert-stage would read it as this run'"'"'s verdict\n'; return 1; }
    [ "$(mf_get "$MAN" stale_gate_removed)" = yes ]
}
# The stale gate is planted by the driver itself - see the T_PKG_PLANT_STALE
# block in pkg_drive.tcl, which writes it just before the stage is sourced.
t_check pkg.notconfigured.stalegate \
    "a package_ip_gate.txt left by an earlier run of this tag is deleted and the manifest records the deletion" \
    stale_gate_removed "$FLOW_DIR"

M="$(t_mutant "$SB" stalegate-kept)"
if [ -n "$M" ] && t_replace_line "$M" "$STAGE_REL" \
        '        file delete -force $stale' \
        '        # file delete -force $stale'; then
    t_check_fail pkg.notconfigured.stalegate.mutation \
        "with the deletion gone, the earlier run's verdict survives into this run and the check goes red" \
        stale_gate_removed "$M"
else
    t_skip pkg.notconfigured.stalegate.mutation "could not plant the fault: the stale-gate file delete has changed shape"
fi


#=============================================================================
# 7. THE MANIFEST AND THE GATE - CONTRACT.md SECTION 5 SHAPE, TWO NAMES
#
# The stage has two names and both are load-bearing (CONTRACT.md 12.5): the
# `stage` FIELD says `package-ip` because that is what assert-stage checks, and
# the FILENAME is `package_ip_manifest.txt` because that is what section 4 fixes
# and mk/flow.mk asserts. One string cannot do both, and each mutant below
# passes one string for both - which was the stage's own measured defect on
# 2026-09-08.
#=============================================================================
t_head "7. the manifest and the gate: named, shaped, and carrying what assert-stage reads"

## manifest_named_and_shaped <toolkit>
manifest_named_and_shaped() {
    use_sources "$SRC_DEF"
    pkg_run "$1"
    show_run
    ls "$RUN/reports"
    [ "$PKG_RC" -eq 0 ] || return 1
    [ -s "$MAN" ] || { printf 'no package_ip_manifest.txt - the stem is what section 4 fixes\n'; return 1; }
    [ "$(mf_get "$MAN" stage)" = package-ip ] || { printf 'the stage field says %s, not package-ip - assert-stage rejects it\n' "$(mf_get "$MAN" stage)"; return 1; }
    grep -q '^# 8\. what this stage MEASURED' "$MAN" || { printf 'no block 8\n'; return 1; }
    local k v c
    for k in vlnv params_packaged stage_configured hard_failures component_sha256 component_bytes; do
        v="$(mf_get "$MAN" "$k")"
        case "$v" in ""|UNVERIFIED*|unmeasured) printf 'block 8 field %s is %s\n' "$k" "${v:-<absent>}"; return 1 ;; esac
    done
    c="$(component_under_out)"
    [ "$(mf_get "$MAN" component_bytes)" = "$(stat -c %s "$c")" ] || { printf 'component_bytes disagrees with the file\n'; return 1; }
    [ "$(mf_get "$MAN" component_sha256)" = "$(sha256sum "$c" | cut -d' ' -f1)" ] || { printf 'component_sha256 disagrees with the file\n'; return 1; }
    return 0
}
t_check pkg.manifest \
    "package_ip_manifest.txt exists, its stage field is package-ip, and block 8 carries measured vlnv/params_packaged/sha256/bytes that match the file" \
    manifest_named_and_shaped "$FLOW_DIR"

M="$(t_mutant "$SB" manifest-stem-is-stage)"
if [ -n "$M" ] && t_replace_line "$M" "$STAGE_REL" \
        'set STAGE_STEM package_ip     ;# the artefact stem, fixed by CONTRACT.md section 4' \
        'set STAGE_STEM package-ip     ;# (mutation) one string for both names'; then
    t_check_fail pkg.manifest.stem.mutation \
        "with the stem spelled as the stage name, the manifest lands at package-ip_manifest.txt where nothing looks and the check goes red" \
        manifest_named_and_shaped "$M"
else
    t_skip pkg.manifest.stem.mutation "could not plant the fault: the STAGE_STEM line has changed shape"
fi

M="$(t_mutant "$SB" manifest-stage-is-stem)"
if [ -n "$M" ] && t_replace_line "$M" "$STAGE_REL" \
        'set STAGE_NAME package-ip     ;# the stage: FPGA_STAGE, the make target, assert-stage' \
        'set STAGE_NAME package_ip     ;# (mutation) one string for both names'; then
    t_check_fail pkg.manifest.stage.mutation \
        "with the stage field spelled as the stem, assert-stage would call it another stage's manifest and the check goes red" \
        manifest_named_and_shaped "$M"
else
    t_skip pkg.manifest.stage.mutation "could not plant the fault: the STAGE_NAME line has changed shape"
fi

M="$(t_mutant "$SB" manifest-no-vlnv)"
if [ -n "$M" ] && t_mutate "$M" "$STAGE_REL" \
        's/    vlnv               $vlnv/    vlnv_renamed       $vlnv/'; then
    t_check_fail pkg.manifest.block8.mutation \
        "with the vlnv field renamed, the key assert-stage reads is absent and the check goes red" \
        manifest_named_and_shaped "$M"
else
    t_skip pkg.manifest.block8.mutation "could not plant the fault: the vlnv field line has changed shape"
fi

## gate_named_and_shaped <toolkit>
gate_named_and_shaped() {
    use_sources "$SRC_DEF"
    pkg_run "$1"
    show_run
    ls "$RUN/reports"
    [ "$PKG_RC" -eq 0 ] || return 1
    [ -s "$GATE" ] || { printf 'no package_ip_gate.txt\n'; return 1; }
    sed -n 1p "$GATE" | grep -q '^PACKAGE-IP gate, ' || { printf 'the first line does not name the stage: %s\n' "$(sed -n 1p "$GATE")"; return 1; }
    sed -n 2p "$GATE" | grep -q '^design demo_block, run tag t1, board demo_board, part ' || { printf 'line 2 is not the identity line\n'; return 1; }
    grep -qx 'HARD FAILURES: none' "$GATE" || { printf 'no exact "HARD FAILURES: none" - the string mk/flow.mk greps for\n'; return 1; }
    local h
    for h in '^BUDGETS EXCEEDED$' '^DECLARED ELSEWHERE - MEASURED HERE, OWNED BY SOMEBODY ELSE$' '^NOT covered by ANY run of this flow, at any setting:$'; do
        grep -qE "$h" "$GATE" || { printf 'section header missing: %s\n' "$h"; return 1; }
    done
    [ "$(gate_section "$GATE" '^DECLARED ELSEWHERE' | grep -c '^  - ')" -gt 0 ] || { printf 'the delegated section is empty\n'; return 1; }
    [ "$(gate_section "$GATE" '^NOT covered' | grep -c '^  - ')" -gt 0 ] || { printf 'the not-covered section is empty\n'; return 1; }
    return 0
}
t_check pkg.gate \
    "package_ip_gate.txt has the section-5 shape: stage line, identity line, exact HARD FAILURES: none, and populated delegated/not-covered sections" \
    gate_named_and_shaped "$FLOW_DIR"

M="$(t_mutant "$SB" gate-stem-is-stage)"
if [ -n "$M" ] && t_mutate "$M" "$STAGE_REL" \
        's/prov_gate $STAGE_NAME $STAGE_STEM/prov_gate $STAGE_NAME $STAGE_NAME/'; then
    t_check_fail pkg.gate.mutation \
        "with the gate written under the stage name, it lands at package-ip_gate.txt and the check goes red" \
        gate_named_and_shaped "$M"
else
    t_skip pkg.gate.mutation "could not plant the fault: the prov_gate call has changed shape"
fi

## knob_registered <toolkit>
## PACKAGE_IP_LIBRARY is an `opt`: read from the environment, registered by the
## act of reading, and therefore in block 7 with its resolved value - and it
## is the L of the VLNV, so it must reach the core too.
knob_registered() {
    use_sources "$SRC_DEF"
    pkg_run "$1" PACKAGE_IP_LIBRARY=mylib
    show_run
    printf 'knob.PACKAGE_IP_LIBRARY=%s vlnv=%s\n' "$(mf_get "$MAN" knob.PACKAGE_IP_LIBRARY)" "$(mf_get "$MAN" vlnv)"
    [ "$PKG_RC" -eq 0 ] || return 1
    [ "$(mf_get "$MAN" knob.PACKAGE_IP_LIBRARY)" = mylib ] && [ "$(mf_get "$MAN" vlnv)" = "acme.example:mylib:demo_block:3" ]
}
t_check pkg.knob.library \
    "PACKAGE_IP_LIBRARY from the environment is registered in block 7 and reaches the vlnv" \
    knob_registered "$FLOW_DIR"

M="$(t_mutant "$SB" knob-not-opt)"
if [ -n "$M" ] && t_replace_line "$M" "$STAGE_REL" \
        'opt PACKAGE_IP_LIBRARY       user      ;# the L of the V:L:N:V. IP_VENDOR supplies the V' \
        'set PACKAGE_IP_LIBRARY       user      ;# (mutation) a plain set: not registered, not overridable'; then
    t_check_fail pkg.knob.library.mutation \
        "with the knob declared by a plain set, the environment is ignored and the manifest does not carry it, so the check goes red" \
        knob_registered "$M"
else
    t_skip pkg.knob.library.mutation "could not plant the fault: the PACKAGE_IP_LIBRARY opt line has changed shape"
fi


#=============================================================================
# 8. IP_REPOS: ONE ASSIGNMENT, THEN THE CATALOGUE REBUILD
#
# set_property REPLACES ip_repo_paths. One call per repository leaves exactly
# the last one standing - the +incdir+ defect of the reference toolkit (41
# lines, one surviving directory), one layer up. The record must show ONE
# assignment carrying both repositories, followed by the rebuild.
#=============================================================================
t_head "8. IP_REPOS: one ip_repo_paths assignment carrying every repository, then update_ip_catalog"

## iprepos_one_assignment <toolkit>
iprepos_one_assignment() {
    use_sources "$SRC_DEF"
    pkg_run "$1"
    show_run
    local n line
    n="$(grep -c '^set_property ip_repo_paths ' "$REC")"
    line="$(grep '^set_property ip_repo_paths ' "$REC" | tail -1)"
    printf '%s ip_repo_paths assignment(s); last: %s\n' "$n" "$line"
    [ "$PKG_RC" -eq 0 ] || return 1
    [ "$n" -eq 1 ] || { printf 'more than one assignment: each REPLACES the last, so only the final repository is on the path\n'; return 1; }
    printf '%s' "$line" | grep -qF "$SB/repo_a" && printf '%s' "$line" | grep -qF "$SB/repo_b" && return 0
    printf 'the one assignment does not carry both repositories\n'
    return 1
}
t_check pkg.iprepos.one \
    "two repositories arrive in ONE set_property ip_repo_paths call" \
    iprepos_one_assignment "$FLOW_DIR"

M="$(t_mutant "$SB" iprepos-one-per-call)"
if [ -n "$M" ] && t_replace_line "$M" "$STAGE_REL" \
        '        set_property ip_repo_paths $repos [current_project]' \
        '        foreach __r $repos { set_property ip_repo_paths $__r [current_project] }'; then
    t_check_fail pkg.iprepos.one.mutation \
        "with one call per repository - the reference toolkit's +incdir+ defect - only the last survives and the check goes red" \
        iprepos_one_assignment "$M"
else
    t_skip pkg.iprepos.one.mutation "could not plant the fault: the ip_repo_paths assignment has changed shape"
fi

## iprepos_then_rebuild <toolkit>
iprepos_then_rebuild() {
    use_sources "$SRC_DEF"
    pkg_run "$1"
    show_run
    local a u
    a="$(rec_last '^set_property ip_repo_paths ')"
    u="$(rec_first '^update_ip_catalog -rebuild')"
    printf 'record: ip_repo_paths at %s, update_ip_catalog -rebuild at %s\n' "${a:-none}" "${u:-none}"
    [ "$PKG_RC" -eq 0 ] && [ -n "$a" ] && [ -n "$u" ] && [ "$a" -lt "$u" ]
}
t_check pkg.iprepos.rebuild \
    "and update_ip_catalog -rebuild follows it, or the new paths hold IP the catalogue has never seen" \
    iprepos_then_rebuild "$FLOW_DIR"

M="$(t_mutant "$SB" iprepos-no-rebuild)"
if [ -n "$M" ] && t_replace_line "$M" "$STAGE_REL" \
        '        update_ip_catalog -rebuild' \
        '        # update_ip_catalog -rebuild'; then
    t_check_fail pkg.iprepos.rebuild.mutation \
        "with the rebuild gone the repositories are set and never scanned, and the check goes red" \
        iprepos_then_rebuild "$M"
else
    t_skip pkg.iprepos.rebuild.mutation "could not plant the fault: the update_ip_catalog call has changed shape"
fi


#=============================================================================
# 9. THE SEAMS, AND THE ORDER OF THE ipx:: CALLS
#
# CONTRACT.md 6.1.3: post_package_ip fires AFTER the core exists and BEFORE it
# is saved, so a hook's edit reaches component.xml. The hook here sets version
# 9.9; the file on disk must say 9.9 - proved by moving the seam to after the
# save, which leaves the hook running, recorded in hooks_run, and changing
# nothing that survives. That is exactly the failure 6.1.3 describes.
#
# The seam names come from the stage's own call sites and match
# flow/common/seams.txt by construction (flow_seam_assert dies otherwise);
# t_seams.sh owns the list and nothing here copies it.
#=============================================================================
t_head "9. the seams fire in order, the post seam's edit survives, and the ipx:: calls are ordered"

## seams_run <toolkit> [env...] - the hook scenario; 0 when the stage completed
seams_run() {
    local tk="$1"; shift
    use_sources "$SRC_DEF"
    pkg_run "$tk" FPGA_HOOKS_DIR="$PROJ/hooks" "$@"
    show_run
    [ "$PKG_RC" -eq 0 ] && [ -s "$MAN" ]
}

## seams_in_order <toolkit>
seams_in_order() {
    seams_run "$1" || return 1
    local pre post
    pre="$(rec_first '^HOOK pre_package_ip$')"
    post="$(rec_first '^HOOK post_package_ip$')"
    printf 'record: pre at %s, post at %s; hooks_run=%s\n' "${pre:-none}" "${post:-none}" "$(mf_get "$MAN" hooks_run)"
    [ -n "$pre" ] && [ -n "$post" ] && [ "$pre" -lt "$post" ] || { printf 'the seams did not both fire, in that order\n'; return 1; }
    mf_get "$MAN" hooks_run | grep -qE '^pre_package_ip\([0-9]+s\) post_package_ip\([0-9]+s\)$' || {
        printf 'hooks_run does not list both seams in order\n'; return 1; }
    return 0
}
t_check pkg.seam.order \
    "pre_package_ip fires before post_package_ip, and hooks_run records both in that order" \
    seams_in_order "$FLOW_DIR"

M="$(t_mutant "$SB" seam-no-pre)"
if [ -n "$M" ] && t_replace_line "$M" "$STAGE_REL" \
        'flow_hook pre_package_ip' \
        '# flow_hook pre_package_ip   (mutation: the seam is gone)'; then
    t_check_fail pkg.seam.order.mutation \
        "with the pre seam removed, a project's pre_package_ip.tcl never runs and the check goes red" \
        seams_in_order "$M"
else
    t_skip pkg.seam.order.mutation "could not plant the fault: the flow_hook pre_package_ip call has changed shape"
fi

## post_before_save <toolkit>
post_before_save() {
    seams_run "$1" || return 1
    local post save params
    post="$(rec_first '^HOOK post_package_ip$')"
    save="$(rec_first '^ipx::save_core ')"
    params="$(rec_last '^ipx::get_hdl_parameters ')"
    printf 'record: last get_hdl_parameters at %s, post hook at %s, save_core at %s\n' "${params:-none}" "${post:-none}" "${save:-none}"
    [ -n "$post" ] && [ -n "$save" ] && [ -n "$params" ] && [ "$params" -lt "$post" ] && [ "$post" -lt "$save" ] && return 0
    printf 'post_package_ip must fire after the parameters are applied and BEFORE ipx::save_core (CONTRACT.md 6.1.3)\n'
    return 1
}
t_check pkg.seam.post.before_save \
    "post_package_ip fires after the parameters are applied and before ipx::save_core" \
    post_before_save "$FLOW_DIR"

## plant_post_after_save <mutant> - the seam MOVED to after the save: two
## edits, one fault. The hook still runs and is still recorded.
plant_post_after_save() {
    t_replace_line "$1" "$STAGE_REL" 'flow_hook post_package_ip' 'set __post_seam_moved 1' \
    && t_replace_line "$1" "$STAGE_REL" '    ipx::save_core $core' '    ipx::save_core $core ; flow_hook post_package_ip'
}
M="$(t_mutant "$SB" seam-post-after-save)"
if [ -n "$M" ] && plant_post_after_save "$M"; then
    t_check_fail pkg.seam.post.before_save.mutation \
        "with the seam moved to after the save, the hook still runs and the order check goes red" \
        post_before_save "$M"
else
    t_skip pkg.seam.post.before_save.mutation "could not plant the fault: the post seam or the save_core call has changed shape"
fi

## post_edit_survives <toolkit>
## THE ARTEFACT half of 6.1.3: the hook set version 9.9 on the in-memory core,
## and the unconditional save after the seam is what puts it in the file every
## consumer reads.
post_edit_survives() {
    seams_run "$1" || return 1
    local c; c="$(component_under_out)"
    printf 'component.xml version: %s\n' "$(grep -o '<spirit:version>[^<]*' "$c" | sed 's/<[^>]*>//')"
    grep -q '<spirit:version>9.9</spirit:version>' "$c" && return 0
    printf 'the hook ran, was recorded in hooks_run, and changed nothing that survived - 6.1.3 in as many words\n'
    return 1
}
t_check pkg.seam.post.survives \
    "the post hook's edit (version 9.9) reaches component.xml on disk" \
    post_edit_survives "$FLOW_DIR"

M="$(t_mutant "$SB" seam-post-edit-lost)"
if [ -n "$M" ] && plant_post_after_save "$M"; then
    t_check_fail pkg.seam.post.survives.mutation \
        "with the seam after the save, the file predates the edit and the check goes red while hooks_run still lists the hook" \
        post_edit_survives "$M"
else
    t_skip pkg.seam.post.survives.mutation "could not plant the fault: the post seam or the save_core call has changed shape"
fi

## post_edit_recorded <toolkit>
## THE RECORD half, and it is a SEPARATE assertion because the two halves
## disagree today. MEASURED on this fixture: component.xml says version 9.9 and
## the manifest says vlnv ...:3.
##
## Section 8.1 measures $vlnv from the core BEFORE the seam fires, section 9
## fires post_package_ip and saves, and nothing recomputes it - so the one field
## ci/assert-stage.sh reads out of this manifest describes a core that no longer
## exists, while component_sha256 beside it describes the one that does. That is
## the artefact-and-record disagreement CONTRACT.md 6.1.3 exists to prevent,
## reached from the other side: there the hook's effect vanishes, here the
## RECORD of it does. The same pre-seam $vlnv also names the relocation
## directory, so a hook that changes the VLNV files the core under the old one.
##
## The assertion is written against the ARTEFACT rather than against the literal
## 9.9: whatever the four tags in component.xml say, the manifest must say the
## same thing.
post_edit_recorded() {
    seams_run "$1" || return 1
    local c want got t
    c="$(component_under_out)"
    want=""
    for t in vendor library name version; do
        want="${want}${want:+:}$(grep -o "<spirit:$t>[^<]*" "$c" | sed 's/<[^>]*>//' | sed -n 1p)"
    done
    got="$(mf_get "$MAN" vlnv)"
    printf 'component.xml says %s; the manifest records %s\n' "$want" "$got"
    [ -n "$want" ] && [ "$want" = "$got" ] && return 0
    printf 'the vlnv was measured before post_package_ip and never recomputed, so the manifest\n'
    printf 'names a core no component.xml carries - and that field is the one assert-stage reads.\n'
    return 1
}
t_known_defect pkg.seam.post.recorded \
    "the recorded vlnv is the vlnv component.xml carries - measured AFTER post_package_ip, like the gate (CONTRACT.md 6.1.3)" \
    post_edit_recorded "$FLOW_DIR"
t_skip pkg.seam.post.recorded.mutation \
    "there is no post-seam vlnv measurement to remove: section 8.1 takes it before the seam and nothing recomputes it. The proof lands with the fix, and this marker goes red the day pkg.seam.post.recorded starts passing"

## ipx_calls_ordered <toolkit>
## package_project (inside PACKAGE_TCL) -> the stage's current_core -> the
## parameter lookups -> check_integrity -> ONE save_core, in that order. The
## save is what writes the file everything downstream reads, so it comes last
## and it comes once.
ipx_calls_ordered() {
    use_sources "$SRC_DEF"
    pkg_run "$1"
    show_run
    local pp cc gp ci sv nsv
    pp="$(rec_first '^ipx::package_project ')"
    cc="$(rec_last '^ipx::current_core$')"
    gp="$(rec_last '^ipx::get_hdl_parameters ')"
    ci="$(rec_first '^ipx::check_integrity ')"
    sv="$(rec_first '^ipx::save_core ')"
    nsv="$(grep -c '^ipx::save_core ' "$REC")"
    printf 'record: package_project %s, last current_core %s, last get_hdl_parameters %s, check_integrity %s, save_core %s (%s save(s))\n' \
        "${pp:-none}" "${cc:-none}" "${gp:-none}" "${ci:-none}" "${sv:-none}" "$nsv"
    [ "$PKG_RC" -eq 0 ] || return 1
    [ -n "$pp" ] && [ -n "$cc" ] && [ -n "$gp" ] && [ -n "$ci" ] && [ -n "$sv" ] || { printf 'a call is missing from the record\n'; return 1; }
    [ "$pp" -lt "$cc" ] && [ "$cc" -lt "$gp" ] && [ "$gp" -lt "$ci" ] && [ "$ci" -lt "$sv" ] && [ "$nsv" -eq 1 ] && return 0
    printf 'the ipx:: calls are out of order, or the core was saved more than once\n'
    return 1
}
t_check pkg.ipx.order \
    "ipx::package_project, then current_core, then the parameter lookups, then check_integrity, then ONE save_core" \
    ipx_calls_ordered "$FLOW_DIR"

# An EARLY save, inserted before the parameters are applied. Every call is
# still present, so a presence check would stay green; the order check must not.
# The `set component` line appears twice in the stage, so the edit is addressed
# to the first occurrence.
M="$(t_mutant "$SB" ipx-early-save)"
if [ -n "$M" ] && t_mutate "$M" "$STAGE_REL" \
        '0,/^set component \[find_component \[list \$IP_OUT_DIR \$WORK_DIR\]\]$/s//ipx::save_core [ipx::current_core]\n&/'; then
    t_check_fail pkg.ipx.order.mutation \
        "with a save_core inserted before the parameters are applied, every call is present but the order check goes red" \
        ipx_calls_ordered "$M"
else
    t_skip pkg.ipx.order.mutation "could not plant the fault: the first find_component call site has changed shape"
fi

## pre_after_inputs <toolkit>
## CONTRACT.md 12.1: "pre_<stage> fires AFTER the stage has prepared its inputs
## and immediately before the tool command it exists to run - late enough to
## inspect what the tool is about to be given, early enough to stop it." For
## this stage the tool command is the packaging (source PACKAGE_TCL ->
## ipx::package_project), and the inputs are the sources, the materialised
## copies and ::RTL_PARAMS_LIST. MEASURED: the seam fires at record line 1,
## before create_project and before a single read_verilog - a pre_package_ip
## hook can see none of what the core is about to be built from.
##
## THE CONTRACT AND THE CODE DISAGREE HERE, and this suite records the
## disagreement rather than deciding it: one of them is a bug, and the marker
## goes red the day the code moves.
pre_after_inputs() {
    seams_run "$1" || return 1
    local pre rd pp
    pre="$(rec_first '^HOOK pre_package_ip$')"
    rd="$(rec_last '^read_verilog ')"
    pp="$(rec_first '^ipx::package_project ')"
    printf 'record: pre hook at %s, last read_verilog at %s, package_project at %s\n' "${pre:-none}" "${rd:-none}" "${pp:-none}"
    [ -n "$pre" ] && [ -n "$rd" ] && [ -n "$pp" ] && [ "$rd" -lt "$pre" ] && [ "$pre" -lt "$pp" ] && return 0
    printf 'pre_package_ip fires before the sources are read - it cannot inspect what the core will be built from (12.1)\n'
    return 1
}
t_known_defect pkg.seam.pre.after_inputs \
    "pre_package_ip fires after the sources are read and before the packaging command (CONTRACT.md 12.1), not before anything is prepared" \
    pre_after_inputs "$FLOW_DIR"
t_skip pkg.seam.pre.after_inputs.mutation \
    "the seam is at the wrong place today, so there is no correct placement to move it away from - the proof lands with the move, or with the contract change that says it belongs where it is"


#=============================================================================
# 10. THE SHADOW GUARD
#
# `proc` silently REPLACES a command. The stage defines three helpers into a
# tool with several thousand commands, and the equivalent guard in flow_utils
# has fired in anger on the reference toolkit - a helper that shadowed a builtin
# aborted a route stage 2.5 hours in. The driver plants a tool that already has
# `find_component`; the stage must refuse to define its own over it.
#=============================================================================
t_head "10. the shadow guard: a helper name the tool already has is refused"

## shadow_refused <toolkit>
shadow_refused() {
    use_sources "$SRC_DEF"
    pkg_run "$1" T_PKG_SHADOW=1
    show_run
    [ "$PKG_RC" -ne 0 ] || { printf 'the stage defined find_component over the tool'"'"'s own and ran to completion\n'; return 1; }
    printf '%s' "$PKG_OUT" | grep -q "'find_component' is already a command" || { printf 'the refusal does not name the helper\n'; return 1; }
    [ ! -e "$MAN" ] || { printf 'a manifest was written by a stage that had just shadowed a builtin\n'; return 1; }
    return 0
}
t_check pkg.shadow \
    "a tool that already has find_component makes the stage stop, naming the helper, before it writes anything" \
    shadow_refused "$FLOW_DIR"

# THE NAME IS DROPPED FROM THE LIST, NOT THE LIST EMPTIED. An empty list leaves
# `unset __c` below it unsetting a variable the loop never created, which is a
# Tcl error - the mutant would die at line 149 and the predicate would go red
# having never reached the shadowing at all. Measured: that first version failed
# with "the refusal does not name the helper", which is the proof reporting its
# own broken fault as a rejection.
M="$(t_mutant "$SB" shadow-unguarded)"
if [ -n "$M" ] && t_replace_line "$M" "$STAGE_REL" \
        'foreach __c {inbody_mentions inbody_materialise find_component} {' \
        'foreach __c {inbody_mentions inbody_materialise} {'; then
    t_check_fail pkg.shadow.mutation \
        "with the guard checking no names, the tool's find_component is silently replaced and the check goes red" \
        shadow_refused "$M"
else
    t_skip pkg.shadow.mutation "could not plant the fault: the shadow-guard foreach has changed shape"
fi

# Said once, at the end, where a reader looking at a green run still sees it.
if [ "$T_REBUILDS" -gt 0 ]; then
    printf '\nNOTE: the fixture was rebuilt %d time(s) - something outside this suite deleted\n' "$T_REBUILDS"
    printf '      %s mid-run. Every assertion above still measured what it names,\n' "$SB"
    printf '      but this host had another session writing to the same $TMPDIR.\n'
fi

t_summary
