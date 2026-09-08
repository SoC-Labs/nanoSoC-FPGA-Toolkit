################################################################################
# flow/vivado/4_synth.tcl - RTL in, a synthesised checkpoint out
#
# Stage 4 of the graph in CONTRACT.md section 4. Invoked by mk/flow.mk through
# the `vivado_stage` macro, which cd's to $(WORK_DIR), runs Vivado in batch with
# its log and journal in $(LOG_DIR), and exports FPGA_STAGE, FPGA_STAGE_T0,
# FPGA_LOG_FILE and FPGA_TOOL_HINT on top of the standing FPGA_* set.
#
# It produces, and is graded on:
#
#   $OUT_DIR/$BLOCK_synth.dcp           the checkpoint implementation reads
#   $REPORT_DIR/utilization_synth.rpt   the first place an almost-empty design shows
#   $REPORT_DIR/synth_manifest.txt      what was built, from what, with which knobs
#   $REPORT_DIR/synth_gate.txt          the verdict, in the section structure of
#                                       CONTRACT.md section 5
#
#
# THE RULE THIS FILE EXISTS TO ENFORCE
# ===========================================================================
# ASSERT ON ARTEFACTS, NEVER ON EXIT STATUS. `synth_design` returns 0 on a
# design that elaborated to almost nothing, on a constraint file that matched
# nothing (CONTRACT.md section 9.3), and on a module that became a BLACK BOX
# because its source was never read. Every one of those makes the run look
# BETTER by every number the flow prints: a black box costs no LUTs, an
# unmatched constraint removes paths from the timing summary, and both are
# reported as warnings in a log with hundreds of them.
#
# So nothing here concludes anything from a return code. The stage runs the
# tool, writes the reports, then READS THE REPORTS BACK OFF DISK and grades
# those. Where a number could not be read the answer is the literal token
# `unmeasured` and the gate treats it as a failure, never as a zero.
#
#
# WHY THE SEAMS ARE WHERE THEY ARE
# ===========================================================================
# `flow_hook post_synth` fires BEFORE the reports and BEFORE the checkpoint are
# written, and the gate is computed after it. CONTRACT.md section 6.1.3 settled
# that, and the reasoning is forced rather than chosen: a stage hands off through
# a FILE, so a hook that fired after write_checkpoint would change a design that
# nothing downstream ever sees - it would appear to run, be recorded in
# `hooks_run`, and have no effect. Firing before the write gives the opposite
# property: the checkpoint RECORDS what the hook did and every later stage
# inherits it. The reports are on the same side of that line, because a gate
# computed after the seam from evidence gathered before it grades a design that
# no longer exists.
#
# `flow_hook pre_synth` fires AFTER the sources, the constraints and the generics
# are applied and BEFORE synth_design. THIS DEVIATES FROM THE LITERAL ORDER OF
# THE SKELETON IN CONTRACT.md SECTION 12.1, which draws the pre_ seam
# immediately after the knob block, and the deviation is deliberate: the
# toolkit's own scaffolded hook (templates/hooks/pre_synth.tcl) documents its
# position as "the sources are READ ... so the fileset carries whatever generics
# and defines the flow applied to it", and its whole job - proving a declared
# parameter reached the tool, because ipx::package_project drops fileset defines
# silently (CONTRACT.md section 9.2) - is impossible before the sources are read.
# The skeleton's "... the work ..." line is a sketch; the hook template is a
# specification with a measured defect behind it. Two toolkit files disagree,
# this comment says which one the code follows and why, and the disagreement is
# reported rather than silently picked. CONTRACT.md, first paragraph.
#
#
# WHAT THIS FILE DOES NOT DO
# ===========================================================================
# It does not implement FLOW_MODE=project's `launch_runs synth_1` path. Every
# mode runs the same in-memory synthesis and writes the same checkpoint, because
# the checkpoint is the artefact CONTRACT.md section 4 grades in every mode. When
# FLOW_MODE is anything but `direct` the difference is announced, recorded in the
# manifest and listed in the gate's NOT-covered section - never silently ignored.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
################################################################################

source [file join $env(FPGA_FLOW_DIR) flow common flow_utils.tcl]

flow_config prefix SYNTH
flow_boot
flow_banner synth


################################################################################
# 1. KNOBS
#
# Every one at the LEFT MARGIN, so `make help-knobs` and the manifest both find
# it by reading the file, and so `opt` registers it by the act of reading it.
# There is no second list to keep in step (CONTRACT.md section 5, block 7).
#
# THE BUDGETS ARE DECLARED HERE AND DEFAULTED FROM THE MAKE EXPORT. mk/flow.mk
# exports EXPECT_LUT_MAX as FPGA_EXPECT_LUT_MAX, and `opt` reads the BARE name
# from the environment - so the default expression is what carries the project's
# value, and a hand-set EXPECT_LUT_MAX still wins for a stage run by hand.
# Either way the RESOLVED value lands in the manifest, which is the point: a
# gate whose budget nobody recorded is a verdict nobody can reproduce.
################################################################################

opt SYNTH_SOURCES_TCL   ""   ;# "" = $IN_WORK_DIR/sources.tcl, written by the flist stage
opt SYNTH_READ_BD        1   ;# 1 = read $IN_WORK_DIR/$DESIGN_NAME.bd when the bd stage wrote one
opt SYNTH_IP_REPO_PATHS ""   ;# "" = IP_REPOS plus $SYNTH_OUT_DIR/ip from the package-ip stage
opt SYNTH_WRITE_NETLIST  0   ;# 1 = also write a structural Verilog netlist beside the checkpoint

opt EXPECT_LUT_MAX      [flow_env FPGA_EXPECT_LUT_MAX      -1]  ;# -1 = measure and report, do not gate
opt EXPECT_FF_MAX       [flow_env FPGA_EXPECT_FF_MAX       -1]
opt EXPECT_BRAM_MAX     [flow_env FPGA_EXPECT_BRAM_MAX     -1]
opt EXPECT_DSP_MAX      [flow_env FPGA_EXPECT_DSP_MAX      -1]
opt EXPECT_BLACKBOX_MAX [flow_env FPGA_EXPECT_BLACKBOX_MAX  0]  ;# a black box costs no LUTs and raises no error
opt ALLOW_CRITICAL_WARNINGS [flow_env FPGA_ALLOW_CRITICAL_WARNINGS 0]
opt MSG_GATE_ALLOWLIST  [flow_env FPGA_MSG_GATE_ALLOWLIST ""]   ;# a TCL LIST of message ids, e.g. {Synth 8-3331}

# Engine plumbing, read through flow_env and NOT registered: these are values
# mk/flow.mk always supplies, and registering one would put the same string in
# the manifest twice, once as configuration and once as plumbing.
set TOP         [flow_env FPGA_TOP]
set DESIGN_NAME [flow_env FPGA_DESIGN_NAME $block_name]
set PART_STR    [flow_env FPGA_PART]
if {$PART_STR eq ""} { set PART_STR [part part_name] }


################################################################################
# 2. THE MEASUREMENT BLOCK, AND WHY THIS STAGE APPENDS ONE
#
# ci/assert-stage.sh grades a finished stage by READING THE MANIFEST, with
# `awk '$1 == key'` - so a measurement has to be a top-level key in the first
# column. prov_manifest (flow/common/provenance.tcl) writes the seven blocks
# CONTRACT.md section 5 fixes and has no eighth for a stage's own numbers, and
# prov_set would prefix them `prov.`, which is the namespace `compare-runs`
# treats as design IDENTITY - a utilisation figure is a RESULT. So the stage
# appends block 8 itself, immediately after prov_manifest returns.
#
# That these four procs are duplicated in the three stage scripts is a fault to
# fix in provenance.tcl, which owns manifest emission. It is recorded in the
# handover rather than papered over with a fourth file these stages do not own.
################################################################################

set ::MEAS {}
proc stage_meas {k v} {
    # "" is not a measurement. CONTRACT.md rule 2: the token is `unmeasured`,
    # never 0 and never blank - a blank field reads as one the writer forgot.
    if {[string trim $v] eq ""} { set v "unmeasured" }
    lappend ::MEAS $k $v
}
proc stage_meas_get {k} {
    foreach {kk vv} $::MEAS { if {$kk eq $k} { return $vv } }
    return "unmeasured"
}
proc stage_meas_measured {k} {
    set v [stage_meas_get $k]
    return [expr {$v ne "unmeasured" && ![string match "UNVERIFIED*" $v]}]
}
proc stage_meas_append {path} {
    set fh [open $path a]
    puts $fh ""
    puts $fh "# 8. measurements - what this stage measured, read back out of the"
    puts $fh "#    reports it wrote. 'unmeasured' is a count nobody took, not 0."
    foreach {k v} $::MEAS { mf $fh $k $v }
    close $fh
    return $path
}



# THE VERDICT WRITER, defined here because the refusal path below needs it too.
# Every section is present even when empty: a reader cannot tell "no budget was
# exceeded" from "budgets were never checked" if the heading is missing, and
# ci/assert-stage.sh calls the second one UNVERIFIED for exactly that reason.
# Bullets are `  - ` and nothing else inside a section starts a line with a
# capital, because that is what the awk in ci/assert-stage.sh keys on.
proc write_gate {path stage hard budgets owned notcov paragraph} {
    global block_name RUN_TAG board_name part_name
    set fh [open $path w]
    puts $fh "[string toupper $stage] gate, [clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%S%z}]"
    puts $fh "design $block_name, run tag $RUN_TAG, board $board_name, part $part_name"
    puts $fh ""
    foreach l $paragraph { puts $fh $l }
    puts $fh ""
    if {[llength $hard]} {
        puts $fh "HARD FAILURES: [llength $hard]"
        foreach h $hard { puts $fh "  - [regsub -all {\s+} $h { }]" }
    } else {
        puts $fh "HARD FAILURES: none"
    }
    puts $fh ""
    puts $fh "BUDGETS EXCEEDED"
    foreach b $budgets { puts $fh "  - [regsub -all {\s+} $b { }]" }
    puts $fh ""
    puts $fh "DECLARED ELSEWHERE - MEASURED HERE, OWNED BY SOMEBODY ELSE"
    foreach o $owned { puts $fh "  - [regsub -all {\s+} $o { }]" }
    puts $fh ""
    puts $fh "NOT covered by ANY run of this flow, at any setting:"
    foreach n $notcov { puts $fh "  - [regsub -all {\s+} $n { }]" }
    puts $fh ""
    close $fh
    return $path
}

# A REFUSAL THAT LEAVES A RECORD.
#
# CONTRACT.md section 12.2.7 asks a stage that writes nothing to leave one, so
# that ci/assert-stage.sh can tell "switched off" from "died before writing
# anything" without inferring it from an absence. These three stages have no
# switched-off state - the contract gives one only to package-ip and bd, and a
# design with no sources, no checkpoint or no routed database is not a stage
# somebody turned off, it is a stage whose input is missing. So the record is
# written and the exit code is 2, NOT 0: nothing was measured, and exit 0 would
# be the other half of a distinction this record exists to make.
proc stage_stop {stage reason lines} {
    global REPORT_DIR
    stage_meas stage_status "REFUSED: $reason"
    catch {
        write_gate [file join $REPORT_DIR ${stage}_gate.txt] $stage [list $reason] {} {} \
            [list "everything. This stage refused before it ran, so nothing about\
                   this design was measured at any setting"] \
            [list \
                "THIS STAGE REFUSED. It did not run, so every number it would have" \
                "produced is absent rather than good. The hard failure below is the" \
                "input it could not read; the run directory holds no artefact from" \
                "this stage and no later stage can be graded against one."]
    }
    catch {
        set m [prov_manifest $stage]
        stage_meas_append $m
        say "record of the refusal: $m"
    }
    flow_refuse {*}$lines
}


################################################################################
# 3. THE INPUTS
#
# Asserted before a licence-hour is spent on them. flow_assert_input refuses
# (exit 2 - nothing was measured) on a missing OR ZERO-BYTE file, and a
# zero-byte sources.tcl is the exact shape the flist stage leaves behind when it
# opened its output and then died.
#
# THE STAGE READS $IN_WORK_DIR AND WRITES $WORK_DIR (CONTRACT.md section 5).
# They are the same directory on a normal run and different ones when a stage is
# re-run against another run's databases, which is what IN_RUN_TAG is for.
################################################################################

step "inputs"

if {$SYNTH_SOURCES_TCL eq ""} {
    # Resolved, not left as "": prov_knobs prints the value this run RESOLVED,
    # so the manifest records the file that was read rather than the word that
    # meant "work it out".
    set SYNTH_SOURCES_TCL [file join $IN_WORK_DIR sources.tcl]
}
set BD_FILE [file join $IN_WORK_DIR ${DESIGN_NAME}.bd]

if {$TOP eq ""} {
    flow_refuse "TOP is not set." \
        "  It is the BOARD-LEVEL top module - the one that instantiates the SoC" \
        "  and wires it to the board. Naming the SoC top instead synthesises" \
        "  happily, and produces a design whose pin constraints matched nothing." \
        "  Set TOP in the project's design.mk; 'make check' reports it."
}

# THE DESIGN HAS TO COME FROM SOMEWHERE, AND THERE ARE TWO PLACES IT CAN COME
# FROM. Neither present is a refusal rather than a shrug: synthesis with an empty
# fileset elaborates a black box, reports a warning, costs no LUTs, and passes
# every budget in the contract.
set have_sources [expr {[file exists $SYNTH_SOURCES_TCL] && [file size $SYNTH_SOURCES_TCL] > 0}]
set have_bd      [expr {$SYNTH_READ_BD && [file exists $BD_FILE]}]

if {!$have_sources && !$have_bd} {
    flow_assert_input $SYNTH_SOURCES_TCL \
        "the materialised source list every stage after the flist stage sources\
         to get the design. 'make flist' writes it; without it synthesis reads an\
         empty fileset, elaborates a black box, and reports a design that met\
         every budget because it contains nothing" \
        RTL_FLIST
}
if {$have_sources} {
    flow_assert_input $SYNTH_SOURCES_TCL "the materialised source list from the flist stage" RTL_FLIST
}

# The pin constraints. Read HERE as well as carried into implementation:
# synthesis is where the IO buffers are inferred and configured, and the earliest
# possible discovery of a renamed port costs a synthesis instead of a
# ninety-minute implementation.
set XDC_PINS {}
foreach f [split [flow_env FPGA_XDC_PINS]] {
    if {[string trim $f] eq ""} { continue }
    flow_assert_input [string trim $f] \
        "pin and placement constraints - which port lands on which package pin,\
         at which IO standard. Read in synthesis AND implementation" \
        XDC_PINS
    lappend XDC_PINS [file normalize [string trim $f]]
}
if {![llength $XDC_PINS]} {
    warn "XDC_PINS names no file. Synthesis will infer IO buffers with no"
    warn "  standard and no location, implementation will place them wherever it"
    warn "  likes, and write_bitstream will refuse the design as a DRC (UCIO-1)"
    warn "  at the END of the flow rather than here."
}

# PROVENANCE IS PINNED AT THE READ, not at stage end: RTL_FLIST_GEN regenerates
# the flist from inside the build, hooks are project code in the critical path,
# and concurrent sessions editing one working tree is the normal condition here.
set ::PROV_FILES {}
if {$have_sources} {
    prov_pin sources_tcl $SYNTH_SOURCES_TCL "synth-read"
    lappend ::PROV_FILES sources_tcl $SYNTH_SOURCES_TCL
}
if {$have_bd} {
    prov_pin bd $BD_FILE "synth-read"
    lappend ::PROV_FILES bd $BD_FILE
}
set __i 0
foreach f $XDC_PINS {
    incr __i
    prov_pin xdc_pins.$__i $f "synth-read"
    lappend ::PROV_FILES xdc_pins.$__i $f
}
unset __i


################################################################################
# 4. READ THE DESIGN
#
# IP FIRST, THEN SOURCES, THEN THE BLOCK DESIGN. An IP repository that is not on
# the path when a source instantiating that IP is read leaves an unresolved
# module, and an unresolved module is a BLACK BOX - which Vivado reports as a
# warning and then synthesises, places, routes and writes a bitstream for.
#
# THE IP CATALOGUE FAILURE IS NOT SWALLOWED AND IS NOT FATAL EITHER. It is said
# at maximum volume and then CAUGHT BY A MEASUREMENT: the black-box census in
# section 8, whose budget EXPECT_BLACKBOX_MAX defaults to 0. That is the shape
# every check in this toolkit wants - a consequence measured in an artefact,
# rather than a `catch` that decides on its own what an error meant.
################################################################################

step "read the design"

set IP_REPOS $SYNTH_IP_REPO_PATHS
if {$IP_REPOS eq ""} {
    foreach d [split [flow_env FPGA_IP_REPOS]] {
        if {[string trim $d] ne ""} { lappend IP_REPOS [file normalize [string trim $d]] }
    }
    # What the package-ip stage wrote, if it ran. SYNTH_OUT_DIR is where this
    # stage READS a sibling run's outputs; on a normal run it is OUT_DIR.
    set __pkg [file join $SYNTH_OUT_DIR ip]
    if {[file isdirectory $__pkg]} { lappend IP_REPOS $__pkg }
    unset __pkg
}
if {[llength $IP_REPOS]} {
    say "ip repositories: [llength $IP_REPOS]"
    foreach d $IP_REPOS { say "  $d" }
    if {[catch {
        set_property ip_repo_paths $IP_REPOS [current_fileset]
        update_ip_catalog
    } __e]} {
        warn "the IP catalogue would not take these repositories: $__e"
        warn "  Anything they were supposed to supply is now an UNRESOLVED"
        warn "  MODULE, which Vivado turns into a black box, reports as a"
        warn "  warning, and synthesises without error. The black-box census"
        warn "  below is what catches that; EXPECT_BLACKBOX_MAX is its budget."
    }
    unset -nocomplain __e
}

if {$have_sources} {
    say "sources: $SYNTH_SOURCES_TCL"
    # AT GLOBAL SCOPE, DELIBERATELY. sources.tcl sets ::flist_defines and
    # ::flist_incdirs, and flow/steps/synth_setup.tcl reads ::flist_defines to
    # decide what reaches -verilog_define. Sourced inside a proc those would be
    # locals and the defines would vanish silently - the same class of loss as
    # the packaging defect in CONTRACT.md section 9.2.
    source $SYNTH_SOURCES_TCL
    if {[info exists flist_files]} { say "source files declared by the flist: $flist_files" }
}

if {$have_bd} {
    say "block design: $BD_FILE"
    if {[catch {read_bd $BD_FILE} __e]} {
        die "read_bd failed on $BD_FILE: $__e" \
            "  The bd stage wrote this file and this stage cannot read it back." \
            "  Continuing would synthesise the design WITHOUT the block design," \
            "  which produces a smaller, cleaner, wrong result."
    }
    unset -nocomplain __e
}

# TOP_HDL IS READ AFTER THE FLIST (CONTRACT.md section 3.3). It is the
# board-level wrapper, and reading it last means it sees every module the flist
# defined rather than the other way round.
foreach f [concat [split [flow_env FPGA_TOP_HDL]] [split [flow_env FPGA_EXTRA_SRCS]]] {
    set f [string trim $f]
    if {$f eq ""} { continue }
    flow_assert_input $f \
        "a source read after the flist - the board-level top, or an extra source" \
        TOP_HDL/EXTRA_SRCS
    set f [file normalize $f]
    prov_pin extra_src.[file tail $f] $f "synth-read"
    lappend ::PROV_FILES extra_src.[file tail $f] $f
    switch -- [string tolower [file extension $f]] {
        .vhd - .vhdl { read_vhdl $f }
        .sv          { read_verilog -sv $f }
        default      { read_verilog $f }
    }
    say "read: $f"
}

# SV_FILES forces the SystemVerilog dialect per file. The dialect is chosen when
# a file is READ, so this is a deliberate re-read of files the flist named: a
# `.v` file that is really SystemVerilog parses as neither without it.
foreach f [split [flow_env FPGA_SV_FILES]] {
    set f [string trim $f]
    if {$f eq ""} { continue }
    flow_assert_input $f "a file whose dialect is forced to SystemVerilog" SV_FILES
    read_verilog -sv [file normalize $f]
    say "re-read as SystemVerilog: $f"
}


################################################################################
# 5. CONSTRAINTS - AND THE READ WINDOW THE ENGINE OWNS
#
# CONTRACT.md section 3.3, settled 2026-09-08:
#
#     THE ENGINE SETS THE READ WINDOW, FROM THE VARIABLE THAT NAMED THE FILE.
#     XDC_PINS gets USED_IN_SYNTHESIS true and USED_IN_IMPLEMENTATION true;
#     XDC_TIMING and XDC_DRC get USED_IN_SYNTHESIS false. The project does not
#     set those properties and must not need to.
#
# THIS IS A CHECKPOINT FLOW, AND THAT IS HOW THE WINDOW IS IMPLEMENTED HERE.
# With no project open there is no constraints fileset to hang a property on, so
# THE STAGE THAT READS THE FILE IS THE READ WINDOW: this stage reads XDC_PINS
# and nothing else, and 5_impl.tcl reads the timing and DRC files. The pin
# constraints reach implementation through the CHECKPOINT, which carries the
# constraints synthesis was given - measured on this host: PACKAGE_PIN survives
# open_checkpoint of a post-synthesis .dcp, and write_bitstream's UCIO-1 check
# passes at the end of the flow, which it could not if they had been lost.
#
# When a fileset DOES exist - a project opened by an earlier stage - the
# properties are set as well, so both spellings of one decision agree.
#
# XDC_TIMING AND XDC_DRC ARE NOT READ HERE, AND THAT IS THE POINT. A create_clock
# read before synthesis constrains a netlist that does not exist yet, and reading
# the file here AND at implementation is how a design ends up with two clocks of
# the same name on one port.
################################################################################

step "constraints"

proc read_pin_xdc {path} {
    read_xdc $path
    # The project-mode half of the same decision. Guarded rather than assumed:
    # in a checkpoint flow there is no constraints fileset and `get_files` has
    # nothing to return, which is not an error - it is the other flow.
    catch {
        set __o [get_files -quiet [file tail $path]]
        if {[llength $__o]} {
            set_property USED_IN_SYNTHESIS      true $__o
            set_property USED_IN_IMPLEMENTATION true $__o
        }
    }
    say "read_xdc (synthesis + implementation): $path"
}

foreach f $XDC_PINS { read_pin_xdc $f }

# Say what was NOT read, and why. A file a project named and this stage silently
# skipped is indistinguishable, from the log, from one the engine forgot.
set __deferred {}
foreach {var why} [list \
    FPGA_XDC_TIMING   "implementation only - a clock constrains a netlist, and there is not one yet" \
    FPGA_XDC_DRC      "implementation only - a DRC severity applies to checks that run after routing" \
    FPGA_XDC_EXTRA    "implementation only - the variable declares no role, so the engine cannot know it is safe before synthesis" \
    FPGA_XDC_OPTIONAL "implementation only - see XDC_EXTRA"] {
    foreach f [split [flow_env $var]] {
        if {[string trim $f] ne ""} { lappend __deferred "[string trim $f]  ($why)" }
    }
}
if {[llength $__deferred]} {
    say "NOT read at synthesis, by design ([llength $__deferred] file(s)):"
    foreach d $__deferred { say "  $d" }
}
unset __deferred


################################################################################
# 6. GENERICS
#
# RTL_PARAMS IS THE PRIMARY CONFIGURATION MECHANISM IN THIS CODEBASE and this is
# where it lands. Both halves of that are measured (CONTRACT.md sections 9.1 and
# 9.2):
#
#   * there is no `ifdef FPGA and no `ifdef ASIC anywhere in the tree - zero hits
#     across 13,524 RTL files - so a flow that configures a build with a define
#     configures NOTHING, silently;
#   * ipx::package_project DROPS fileset defines by three separate routes, and it
#     has already failed here: an `ifdef-guarded opt-in was false in EVERY FPGA
#     build, proven by a byte-identical "feature-off" bitstream. Parameters
#     survive packaging as CONFIG.*; defines do not.
#
# flow/steps/synth_setup.tcl puts RTL_PARAMS on the synth_design command line as
# `-generic`, which is the form that survives. This block ALSO writes them onto
# the fileset when there is one, because that is where fpga/hooks/pre_synth.tcl
# looks to prove a parameter reached the tool - and the reason that hook exists
# is that nobody noticed for months when one did not.
################################################################################

set GENERICS {}
foreach p [split [flow_env FPGA_RTL_PARAMS]] {
    if {[string trim $p] ne ""} { lappend GENERICS [string trim $p] }
}
if {[llength $GENERICS]} {
    say "generics (RTL_PARAMS): [join $GENERICS { }]"
    catch { set_property generic $GENERICS [current_fileset] }
}


################################################################################
# 7. THE SEAM, THE STRATEGY, AND SYNTHESIS ITSELF
#
# THE SENTINEL IS CHECKED IN MILLISECONDS RATHER THAN AFTER A FORTY-MINUTE
# ELABORATION. flow/steps/synth_setup.tcl ends with `set ::SYNTH_SETUP_DONE 1`
# and its header requires every override to do the same. A file that set tool
# properties and forgot ::SYNTH_ARGS would synthesise at Vivado's defaults and
# say nothing, and two runs at different strategies would produce manifests that
# agree - the comparison this toolkit exists to refuse.
#
# -top AND -part ARE THE STAGE'S, NOT THE STEP FILE'S. A second -part on the
# command line wins over both, silently, and the failure is a bitstream that will
# not load.
################################################################################

flow_hook pre_synth

flow_step synth_setup

if {![info exists ::SYNTH_SETUP_DONE] || !$::SYNTH_SETUP_DONE} {
    die "synth_setup did not finish: ::SYNTH_SETUP_DONE is not set." \
        "  flow/steps/synth_setup.tcl sets it on its last line and every project" \
        "  override must too - its header says so. Without the sentinel this" \
        "  stage cannot tell a strategy file that ran from one that returned" \
        "  early, and the difference is a whole synthesis at Vivado's defaults" \
        "  with nothing in the manifest saying so."
}
if {![info exists SYNTH_ARGS]} {
    die "synth_setup left no SYNTH_ARGS." \
        "  The stage calls 'synth_design -top <top> -part <part> {*}\$SYNTH_ARGS'." \
        "  An empty list is a synthesis at Vivado's defaults, recorded nowhere."
}

step "synth_design"
say "top:  $TOP"
say "part: $PART_STR"
say "args: $SYNTH_ARGS"

synth_design -top $TOP -part $PART_STR {*}$SYNTH_ARGS

# THE FIRST ARTEFACT-LEVEL QUESTION, ASKED IMMEDIATELY. synth_design returns 0
# whether or not it left a design in memory, and `current_design` is the cheapest
# thing that disagrees with it.
if {[catch {current_design} __d] || $__d eq ""} {
    die "synth_design returned, and there is no design in memory." \
        "  Vivado exits 0 after a failed synthesis. Find the real error with:" \
        "    grep -nE '^ERROR|CRITICAL WARNING|Failed' \$LOG_DIR/synth.log"
}
unset -nocomplain __d


################################################################################
# 8. EVIDENCE, THEN THE SEAM, THEN THE WRITES
#
# The report PLAN is built before the seam so a hook can read or extend it; the
# reports are RUN after the seam so they describe the design that is about to be
# written. CONTRACT.md section 6.1.3 puts the seam before the writes and the gate
# after the seam - which is only true of the gate if it is also true of the
# gate's INPUTS.
#
# STALE REPORTS ARE DELETED FIRST, and that is not housekeeping. flow/steps/
# report_setup.tcl names `timing_summary.rpt` at BOTH synthesis and
# implementation, so a run whose implementation dies leaves THIS stage's timing
# summary sitting in the file mk/flow.mk and ci/assert-stage.sh grade as
# implementation's. A report this stage did not write must be ABSENT, so that
# "missing" reads as missing.
################################################################################

# Which report set report_setup builds. Not a knob of this stage - it is a fact
# about which stage is running - and report_setup registers REPORT_STAGE with
# `opt`, so the value still lands in the manifest.
set ::env(REPORT_STAGE) synth

flow_step report_setup

if {![info exists ::REPORT_SETUP_DONE] || !$::REPORT_SETUP_DONE} {
    die "report_setup did not finish: ::REPORT_SETUP_DONE is not set." \
        "  Every gate below reads a file that step writes. Without the plan there" \
        "  is no evidence, and a gate with no input is what a green run that" \
        "  proves nothing is made of."
}

flow_hook post_synth

step "reports"

foreach __e $REPORT_PLAN {
    foreach {__name __req __cmd} $__e break
    file delete -force [file join $REPORT_DIR $__name]
}
set REPORT_MISSING {}
foreach __e $REPORT_PLAN {
    foreach {__name __req __cmd} $__e break
    set __f [file join $REPORT_DIR $__name]
    if {[catch {uplevel #0 $__cmd} __err]} { warn "report '$__name' failed: $__err" }
    if {[file exists $__f] && [file size $__f] > 0} {
        say [format "  %-28s %s bytes" $__name [file size $__f]]
        continue
    }
    if {$__req} {
        lappend REPORT_MISSING $__name
        warn "REQUIRED report '$__name' is [expr {[file exists $__f] ? {ZERO BYTES} : {ABSENT}}]."
        warn "  A gate reads it. Absent evidence is UNVERIFIED, which counts as a"
        warn "  failure - it is not a design that passed."
    } else {
        say [format "  %-28s %s" $__name "(not written)"]
    }
}
unset -nocomplain __e __name __req __cmd __f __err

set UTIL_RPT [file join $REPORT_DIR utilization_synth.rpt]

# THE CHECKPOINT. Written after the seam, so it records what the hook did.
step "write the checkpoint"
set DCP [file join $OUT_DIR ${block_name}_synth.dcp]
write_checkpoint -force $DCP
say "checkpoint: $DCP"
if {$SYNTH_WRITE_NETLIST} {
    write_verilog -force -mode funcsim [file join $OUT_DIR ${block_name}_synth.v]
    say "netlist: [file join $OUT_DIR ${block_name}_synth.v]"
}


################################################################################
# 9. MEASUREMENT - READ BACK OFF DISK, NEVER OUT OF THE TOOL'S MEMORY
#
# The numbers below come from the REPORT FILES, not from a Tcl query of the live
# design. That is the separation flow/steps/report_setup.tcl states in its own
# header: the step produces the evidence, the gate produces the verdict, and a
# check that also produced its own input could never be shown to fail.
#
# A row the parser cannot find is `unmeasured`. Never 0 - a zero in a utilisation
# column is indistinguishable from an empty design, and both look like good news.
################################################################################

# One row of a Vivado utilisation table: `| <name> | <used> | ...`. The name is
# matched against a LIST of spellings because the tables are architecture
# dependent - 7-series says "Slice LUTs*", UltraScale says "CLB LUTs" - and a
# parser that knew only one of them would return `unmeasured` on every other
# device and call that a measurement. The trailing `*` is part of the name.
proc util_row {file names} {
    if {![file exists $file] || ![file size $file]} { return "" }
    set fh [open $file r]
    set data [read $fh]
    close $fh
    foreach line [split $data "\n"] {
        if {![string match "|*" $line]} { continue }
        set cells [split $line "|"]
        if {[llength $cells] < 4} { continue }
        set name [string trim [lindex $cells 1]]
        set used [string trim [lindex $cells 2]]
        foreach want $names {
            if {[string equal -nocase $name $want] && [string is integer -strict $used]} {
                return $used
            }
        }
    }
    return ""
}

# The "Black Boxes" section of the same report, summed. AN EMPTY TABLE IS A
# MEASUREMENT OF ZERO; AN ABSENT SECTION IS NOT A MEASUREMENT AT ALL, and the two
# must not read the same. CONTRACT.md section 9.1: selection in this codebase is
# by flist file-swap between wrapper families with identical module names, so a
# family that did not get read leaves a module unresolved - a black box that
# costs no LUTs, raises no error, and passes every utilisation budget there is.
proc util_blackboxes {file} {
    if {![file exists $file] || ![file size $file]} { return "" }
    set fh [open $file r]
    set data [read $fh]
    close $fh
    set in 0 ; set n 0 ; set seen 0
    foreach line [split $data "\n"] {
        if {[regexp {^[0-9]+\. Black Boxes} $line]} {
            # The table of contents carries the same heading, so the first hit is
            # the contents line and the second is the section. Both set the flag;
            # the contents line is followed by more contents lines, not by a
            # table, so nothing is counted from it.
            set in 1 ; set seen 1
            continue
        }
        if {!$in} { continue }
        if {[regexp {^[0-9]+\. } $line] && ![regexp {^[0-9]+\. Black Boxes} $line]} { set in 0 ; continue }
        if {![string match "|*" $line]} { continue }
        set cells [split $line "|"]
        if {[llength $cells] < 3} { continue }
        set used [string trim [lindex $cells 2]]
        if {[string is integer -strict $used]} { incr n $used }
    }
    if {!$seen} { return "" }
    return $n
}

# THE MESSAGE CENSUS. The COUNT comes from the tool's own counter, never from a
# grep - the reference project's stage reporter grepped case-sensitively and
# undercounted DRC by 7% for weeks with nothing to disagree with it. The IDS come
# from the stage log, because the counter does not carry them and
# MSG_GATE_ALLOWLIST is a list of ids. When the two disagree the ids are treated
# as INCOMPLETE and no exemption is granted: an allowlist applied to a partial
# reading would exempt messages nobody saw.
proc msg_criticals {} {
    set count "" ; catch { set count [get_msg_config -count -severity {CRITICAL WARNING}] }
    set log [flow_env FPGA_LOG_FILE]
    set ids {} ; set nfound 0
    if {$log ne "" && [file exists $log]} {
        set fh [open $log r]
        while {[gets $fh line] >= 0} {
            if {[regexp {^CRITICAL WARNING: \[([^\]]+)\]} $line -> id]} {
                incr nfound
                if {[lsearch -exact $ids $id] < 0} { lappend ids $id }
            }
        }
        close $fh
    }
    return [list $count $ids $nfound]
}

step "measurements"

# `stage` and `part` are NOT repeated here: blocks 1 and 3 of the manifest
# already carry them, and ci_mf returns the FIRST match for a key, so a second
# copy is a second thing that can disagree with the first.
stage_meas top        $TOP
stage_meas flow_mode  $FLOW_MODE
stage_meas lut        [util_row $UTIL_RPT {{Slice LUTs*} {Slice LUTs} {CLB LUTs*} {CLB LUTs}}]
stage_meas ff         [util_row $UTIL_RPT {{Slice Registers} {CLB Registers} {Register as Flip Flop}}]
stage_meas bram       [util_row $UTIL_RPT {{Block RAM Tile}}]
stage_meas dsp        [util_row $UTIL_RPT {{DSPs} {DSP48E1} {DSP48E2}}]
stage_meas uram       [util_row $UTIL_RPT {{URAM} {URAM288}}]
stage_meas bufg       [util_row $UTIL_RPT {{BUFGCTRL} {BUFGCE} {Global Clock Buffer}}]
stage_meas iob        [util_row $UTIL_RPT {{Bonded IOB}}]
stage_meas blackboxes [util_blackboxes $UTIL_RPT]

foreach {__cw __ids __nfound} [msg_criticals] break
stage_meas critical_warnings     $__cw
stage_meas critical_warning_ids  [expr {[llength $__ids] ? [join $__ids {,}] : "(none)"}]
set __er "" ; catch { set __er [get_msg_config -count -severity {ERROR}] }
stage_meas errors $__er
unset -nocomplain __er

stage_meas dcp_bytes       [expr {[file exists $DCP]      ? [file size $DCP]      : ""}]
stage_meas utilization_rpt [expr {[file exists $UTIL_RPT] ? [file size $UTIL_RPT] : ""}]
stage_meas source_files    [expr {[info exists flist_files] ? $flist_files : ""}]
stage_meas generics        [expr {[llength $GENERICS] ? [join $GENERICS {,}] : "(none)"}]

foreach {k v} $::MEAS { say [format "  %-22s %s" $k $v] }


################################################################################
# 10. THE VERDICT
#
# Four classes, the structure fixed by CONTRACT.md section 5 and read by both
# mk/flow.mk and ci/assert-stage.sh:
#
#   HARD FAILURES: none    the exact string, and load-bearing punctuation
#   BUDGETS EXCEEDED       a `  - ` bullet per breached EXPECT_*
#   DECLARED ELSEWHERE     measured here, owned by a NAMED somebody else
#   NOT covered            what no run of this flow measures, at any setting
#
# The last two are the honesty mechanism. A green run still enumerates what it
# did not measure, because that is the section people stop reading once a build
# goes green - which is exactly when it matters.
################################################################################

set HARD    {}
set BUDGETS {}
set OWNED   {}
set NOTCOV  {}

# --- hard failures ---------------------------------------------------------
if {![file exists $DCP]} {
    lappend HARD "no checkpoint at $DCP - implementation has no input, and Vivado\
                  exited 0 anyway"
} elseif {![file size $DCP]} {
    lappend HARD "the checkpoint at $DCP is ZERO BYTES - the shape a tool leaves\
                  when it opened its output and then died, and it satisfies every\
                  'test -e' in the world"
}
foreach r $REPORT_MISSING {
    lappend HARD "required report '$r' was not written - a gate reads it, and\
                  absent evidence is UNVERIFIED, which is a failure"
}
if {![stage_meas_measured lut] || ![stage_meas_measured ff]} {
    lappend HARD "utilisation could not be read out of [file tail $UTIL_RPT] - the\
                  budgets below are unarmed and this run's size is UNKNOWN, which\
                  is not the same as small"
}
if {![stage_meas_measured blackboxes]} {
    lappend HARD "the utilisation report has no Black Boxes section, so nothing\
                  measured whether a module went unresolved - and an unresolved\
                  module costs no LUTs and raises no error"
}

# --- budgets ---------------------------------------------------------------
# `-1` means MEASURE AND REPORT, DO NOT GATE (CONTRACT.md section 3.3). The
# comparison is numeric and guarded: a budget compared as a string passes
# everything, which is the defect ci/lib.sh's own budget primitive documents.
proc budget_max {label value budget where} {
    global BUDGETS
    if {$budget eq "" || ![string is double -strict $budget] || $budget < 0} { return 0 }
    if {![string is double -strict $value]} { return 0 }
    if {$value <= $budget} { return 0 }
    lappend BUDGETS "$label $value > budget $budget ($where)"
    return 1
}
set __from "post-synthesis, from reports/[file tail $UTIL_RPT]"
budget_max lut        [stage_meas_get lut]        $EXPECT_LUT_MAX      $__from
budget_max ff         [stage_meas_get ff]         $EXPECT_FF_MAX       $__from
budget_max bram       [stage_meas_get bram]       $EXPECT_BRAM_MAX     $__from
budget_max dsp        [stage_meas_get dsp]        $EXPECT_DSP_MAX      $__from
budget_max blackboxes [stage_meas_get blackboxes] $EXPECT_BLACKBOX_MAX \
    "unresolved modules, from the Black Boxes section of reports/[file tail $UTIL_RPT]"
unset __from

# The message gate. An exemption requires BOTH that every id seen is in
# MSG_GATE_ALLOWLIST and that the ids account for the tool's whole count - an
# allowlist applied to a partial reading of the log would exempt messages nobody
# saw. MSG_GATE_ALLOWLIST defaults EMPTY (CONTRACT.md section 7): a default that
# tolerated ids would hand every project someone else's undiagnosed exemptions.
if {[stage_meas_measured critical_warnings] && $__cw > 0} {
    set __unexempt {}
    foreach id $__ids {
        if {[lsearch -exact $MSG_GATE_ALLOWLIST $id] < 0} { lappend __unexempt $id }
    }
    if {$ALLOW_CRITICAL_WARNINGS} {
        lappend OWNED "$__cw critical warning(s), owner=ALLOW_CRITICAL_WARNINGS=1 in\
                       design.mk: reported, not gated. ids: [join $__ids {, }]"
    } elseif {$__nfound == $__cw && ![llength $__unexempt] && [llength $__ids]} {
        lappend OWNED "$__cw critical warning(s), owner=MSG_GATE_ALLOWLIST: every id\
                       is allowlisted with a diagnosis in design.mk. ids: [join $__ids {, }]"
    } else {
        lappend BUDGETS "critical_warnings $__cw > budget 0 (ALLOW_CRITICAL_WARNINGS=0;\
                         ids not allowlisted: [expr {[llength $__unexempt] ? [join $__unexempt {, }] : {none readable in the stage log}}])"
    }
    unset __unexempt
}

# --- delegated -------------------------------------------------------------
lappend OWNED "post-synthesis LUT count is an OVER-estimate, owner=the impl stage:\
               [stage_meas_get lut] here, and the tool's own footnote says the\
               final count after physical optimisation is typically lower.\
               reports/utilization_impl.rpt is the number that ships"
if {[llength $XDC_PINS]} {
    lappend OWNED "whether the pin constraints MATCHED anything, owner=`make\
                   xdc-lint` (CONTRACT.md section 4), which mk/flow.mk does not\
                   implement yet: Vivado drops a constraint that matches nothing\
                   without an error, and this stage read [llength $XDC_PINS] file(s)"
}
lappend OWNED "timing, owner=the impl stage: XDC_TIMING is implementation-only by\
               contract, so this stage synthesised with no clock definition and\
               any timing number from it would describe an unconstrained design.\
               reports/timing_summary.rpt at this stage says so in its check_timing\
               section"

# --- not covered -----------------------------------------------------------
lappend NOTCOV "simulation. Nothing in this flow shows the RTL does what it is\
                supposed to; synthesis shows only that it is synthesisable"
lappend NOTCOV "whether the design read is the design anyone asked for. Selection\
                in this codebase is by flist file-swap between wrapper families\
                with identical module names, so the flist manifest - not this\
                stage - is where a swap shows"
lappend NOTCOV "power. report_power with no switching activity is a vectorless\
                estimate and is off by default (REPORT_POWER)"
if {$FLOW_MODE ne "direct"} {
    lappend NOTCOV "FLOW_MODE is '$FLOW_MODE' and this stage ran the in-memory\
                    checkpoint flow. The project-mode launch_runs path, DFX\
                    partition handling and ProtoCompiler are NOT implemented by\
                    this stage; what it writes is what CONTRACT.md section 4\
                    grades in every mode"
}
if {[llength $GENERICS]} {
    lappend NOTCOV "whether each of the [llength $GENERICS] RTL_PARAMS generic(s)\
                    changed the netlist. fpga/hooks/pre_synth.tcl is that check and\
                    it is a PROJECT file - this stage only passes the values on"
}

# Written with every section present even when empty: a reader cannot tell "no
# budget was exceeded" from "budgets were never checked" if the heading is
# missing, and ci/assert-stage.sh calls the second one UNVERIFIED for exactly
# that reason. Bullets are `  - ` and nothing else in a section starts a line
# with a capital, because that is what the awk in ci/assert-stage.sh keys on.

set GATE [file join $REPORT_DIR synth_gate.txt]
write_gate $GATE synth $HARD $BUDGETS $OWNED $NOTCOV [list \
    "This gate is about SIZE and RESOLUTION: how much of the device the" \
    "synthesised netlist takes, and whether every module in it resolved to real" \
    "logic. It is NOT about timing (no clock is defined at synthesis - XDC_TIMING" \
    "is implementation-only by contract), NOT about routability, and NOT about" \
    "whether the design is correct. Every number below was read back out of a" \
    "report file on disk. None of it is inferred from an exit status, because" \
    "synth_design returns 0 on a design that elaborated to almost nothing."]

say "verdict: $GATE"


################################################################################
# 11. THE MANIFEST, LAST
################################################################################

set MANIFEST [prov_manifest synth]
stage_meas_append $MANIFEST

if {![file exists $MANIFEST] || ![file size $MANIFEST]} {
    die "the manifest at $MANIFEST was not written." \
        "  It is written last, so its absence is what tells a later reader that" \
        "  the stage did not reach its final section."
}

step "synth summary"
say "checkpoint : $DCP"
say "utilisation: $UTIL_RPT"
say "verdict    : $GATE"
say "manifest   : $MANIFEST"

# THE ARTEFACTS AND THE VERDICT ARE ON DISK BEFORE THIS POINT, AND THAT ORDER IS
# THE ONE THAT MATTERS. The exit status below is a convenience for make - which
# greps a gate file only for the impl stage - and it is not the evidence. A
# reader who wants to know what happened reads synth_gate.txt.
if {[llength $HARD]} {
    foreach h $HARD { puts "SYNTH-FAIL: $h" }
    die "[llength $HARD] hard failure(s) - see $GATE"
}
if {[llength $BUDGETS]} {
    foreach b $BUDGETS { puts "SYNTH-FAIL: budget exceeded: $b" }
    die "[llength $BUDGETS] budget(s) exceeded - see $GATE" \
        "  Ratchet the EXPECT_* knob in design.mk WITH the measurement and the" \
        "  margin written beside it, or fix the design. Do not demote the gate" \
        "  in a CI configuration, where no run record ever reaches it."
}
say "synth OK"

# Copyright (C) 2026, SoC Labs (www.soclabs.org)
