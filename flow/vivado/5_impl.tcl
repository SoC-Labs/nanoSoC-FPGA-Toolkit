################################################################################
# flow/vivado/5_impl.tcl - a synthesised checkpoint in, a routed one out
#
# Stage 5 of the graph in CONTRACT.md section 4, and THE ONE STAGE THE CONTRACT
# REQUIRES A VERDICT ARTEFACT FROM. It produces, and is graded on:
#
#   $OUT_DIR/$BLOCK_routed.dcp      what the bitstream stage opens
#   $REPORT_DIR/timing_summary.rpt  an implementation with no timing report has
#                                   not been timed - that is UNVERIFIED, not met
#   $REPORT_DIR/impl_gate.txt       THE verdict. `HARD FAILURES: none` is the
#                                   exact string mk/flow.mk greps for, anchored,
#                                   so it is load-bearing punctuation
#   $REPORT_DIR/impl_manifest.txt   written last, so its absence says the stage
#                                   did not reach its final section
#
#
# WHY NOTHING HERE TRUSTS A RETURN CODE
# ===========================================================================
# `route_design` RETURNS 0 ON A DESIGN WITH UNROUTED NETS. `opt_design` returns 0
# on a constraint set that matched nothing. `report_timing_summary` reports a
# CLEAN SHEET for a design whose XDC never resolved, because an unconstrained
# path has no requirement, therefore no slack, therefore no line in the summary.
# Every one of those failures makes the run look better, not worse.
#
# So this stage runs the tool, writes the reports, and then reads the reports
# back OFF DISK to decide anything. The three numbers it decides on - WNS, WHS
# and unrouted nets - are parsed from files, and a number that could not be
# parsed is `unmeasured`, which the gate treats as a HARD FAILURE. A design whose
# timing was never measured has not met timing.
#
#
# THE SEAM ORDER, WHICH IS FORCED RATHER THAN CHOSEN
# ===========================================================================
# CONTRACT.md section 6.1.3: post_impl fires BEFORE the routed checkpoint is
# written, and the gate is computed after the seam. The reference ASIC toolkit
# gets this wrong in the one place it matters and documents the cost - its
# post_route fires after stream-out, a project added pads there, and it streamed
# a GDS with no pad ring while every gate passed. Here the same mistake would
# lose the hook's work instead: the checkpoint on disk would predate the edit,
# the bitstream stage would open that checkpoint, and the hook would appear in
# `hooks_run` having changed nothing that ships.
#
# The reports are on the same side of the seam as the checkpoint, because a gate
# computed after the seam from evidence gathered before it grades a design that
# no longer exists.
#
# pre_impl fires with the synthesis checkpoint OPEN and the implementation
# constraints READ, and before opt_design - so a hook can inspect the netlist it
# is about to have implemented, and can still change it. That is one line later
# than the literal skeleton in CONTRACT.md section 12.1 draws it, for the same
# reason 4_synth.tcl states at length in its header.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
################################################################################

source [file join $env(FPGA_FLOW_DIR) flow common flow_utils.tcl]

flow_config prefix IMPL
flow_boot
flow_banner impl


################################################################################
# 1. KNOBS
#
# At the left margin, so `make help-knobs` and the manifest find them by reading
# the file. The strategy knobs - directives, phys_opt, incremental - belong to
# flow/steps/impl_setup.tcl and are NOT repeated here; a second declaration would
# be a second thing to be wrong, and the one that is wrong is always the one you
# are not reading.
################################################################################

opt IMPL_SYNTH_DCP        ""   ;# "" = $SYNTH_OUT_DIR/$BLOCK_synth.dcp from the synth stage
opt IMPL_WRITE_NETLIST     0   ;# 1 = also write a post-route structural netlist
opt IMPL_WRITE_SDF         0   ;# 1 = also write post-route SDF beside the netlist

opt EXPECT_WNS_MIN        [flow_env FPGA_EXPECT_WNS_MIN        -1]  ;# -1 = measure and report, do not gate
opt EXPECT_WHS_MIN        [flow_env FPGA_EXPECT_WHS_MIN        -1]
opt EXPECT_LUT_MAX        [flow_env FPGA_EXPECT_LUT_MAX        -1]
opt EXPECT_FF_MAX         [flow_env FPGA_EXPECT_FF_MAX         -1]
opt EXPECT_BRAM_MAX       [flow_env FPGA_EXPECT_BRAM_MAX       -1]
opt EXPECT_DSP_MAX        [flow_env FPGA_EXPECT_DSP_MAX        -1]
opt EXPECT_UNROUTED_MAX   [flow_env FPGA_EXPECT_UNROUTED_MAX    0]
opt ALLOW_CRITICAL_WARNINGS [flow_env FPGA_ALLOW_CRITICAL_WARNINGS 0]
opt MSG_GATE_ALLOWLIST    [flow_env FPGA_MSG_GATE_ALLOWLIST ""]     ;# a TCL LIST of message ids

set TOP      [flow_env FPGA_TOP]
set PART_STR [flow_env FPGA_PART]
if {$PART_STR eq ""} { set PART_STR [part part_name] }


################################################################################
# 2. THE MEASUREMENT BLOCK
#
# ci/assert-stage.sh reads this stage's numbers out of the manifest with
# `awk '$1 == key'`, so they are top-level keys. prov_manifest writes the seven
# blocks CONTRACT.md section 5 fixes and has no eighth; prov_set would put them
# in the `prov.` namespace, which `compare-runs` treats as design IDENTITY, and
# WNS is a RESULT. So block 8 is appended here. See 4_synth.tcl section 2 - the
# duplication is a fault to fix in provenance.tcl, not to paper over with a
# fourth file these stages do not own.
################################################################################

set ::MEAS {}
proc stage_meas {k v} {
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
# 3. THE INPUT CHECKPOINT
#
# A STAGE READS ONE RUN AND WRITES ANOTHER, AND THE TWO ARE SEPARATE VARIABLES
# (CONTRACT.md section 5). SYNTH_OUT_DIR is where the synthesis checkpoint is
# read from; OUT_DIR is where this stage writes. On a normal run they are the
# same directory, and when they are not, `make env` shows it - which is the
# difference between an A/B experiment and a design compared against itself.
################################################################################

step "inputs"

if {$IMPL_SYNTH_DCP eq ""} {
    set IMPL_SYNTH_DCP [file join $SYNTH_OUT_DIR ${block_name}_synth.dcp]
}
flow_assert_input $IMPL_SYNTH_DCP \
    "the synthesised checkpoint this stage implements. 'make synth' writes it;\
     Vivado exits 0 after a failed synth_design, so its absence here is the first\
     place that failure becomes visible" \
    SYNTH_RUN_TAG/IN_RUN_TAG

prov_pin synth_dcp $IMPL_SYNTH_DCP "impl-read"
set ::PROV_FILES [list synth_dcp $IMPL_SYNTH_DCP]

# THE IMPLEMENTATION-ONLY CONSTRAINTS, IN CONTRACT ORDER: timing, DRC, extra,
# then the conditional set. XDC IS ORDER-DEPENDENT in the same way SDC is - a
# later command silently overrides an earlier one on the same object - so the
# order is the order the project declared, and it is logged.
#
# XDC_PINS IS DELIBERATELY NOT RE-READ HERE. It was read at synthesis and the
# checkpoint carries it: measured on this host, PACKAGE_PIN survives
# open_checkpoint of a post-synthesis .dcp, and write_bitstream's UCIO-1 check
# passes at the end of the flow, which it could not if the pins had been lost.
# Re-reading would be worse than redundant: a second create_clock on the same
# port, or a second set of physical properties, is how a constraint set stops
# meaning what its author wrote.
set XDC_IMPL {}
foreach {var role} [list \
    FPGA_XDC_TIMING "timing (implementation only - USED_IN_SYNTHESIS false)" \
    FPGA_XDC_DRC    "DRC severities and configuration properties (implementation only)" \
    FPGA_XDC_EXTRA  "XDC_EXTRA, in declared order"] {
    foreach f [split [flow_env $var]] {
        set f [string trim $f]
        if {$f eq ""} { continue }
        flow_assert_input $f $role [string range $var 5 end]
        lappend XDC_IMPL [list [file normalize $f] $role]
    }
}

# XDC_OPTIONAL is a LIST of "COND:path", included iff $(COND) is 1.
#
# THE CONDITION HAS TO BE READABLE FROM HERE, AND mk/flow.mk DOES NOT EXPORT IT.
# It exports the FPGA_* set it defines; a project's own USE_<FEATURE> variable is
# not in it. So the condition is looked up in the environment under its own name
# and under an FPGA_ prefix, and A CONDITION THIS STAGE CANNOT READ IS A REFUSAL,
# not a skip: silently dropping a constraint file is the exact defect
# CONTRACT.md section 9.3 is about, and silently including it is worse.
foreach entry [split [flow_env FPGA_XDC_OPTIONAL]] {
    set entry [string trim $entry]
    if {$entry eq ""} { continue }
    set colon [string first ":" $entry]
    if {$colon < 1} {
        flow_refuse "XDC_OPTIONAL entry '$entry' is not COND:path." \
            "  Each entry names a make variable and a file, separated by a colon," \
            "  and the file is read iff the variable is 1."
    }
    set cond [string range $entry 0 [expr {$colon - 1}]]
    set path [string range $entry [expr {$colon + 1}] end]
    set val [flow_env $cond [flow_env FPGA_$cond "<unset>"]]
    if {$val eq "<unset>"} {
        flow_refuse "XDC_OPTIONAL names condition '$cond', which is not in this stage's environment." \
            "  file: $path" \
            "  mk/flow.mk exports the FPGA_* set it defines; a project's own" \
            "  variable is not in it, so this stage cannot tell whether the file" \
            "  should be read. Including it or skipping it would both be a guess," \
            "  and a constraint file that silently did not load leaves a design" \
            "  constrained differently from the one anybody reviewed." \
            "  Either add 'export $cond' to the project's design.mk, or move the" \
            "  file to XDC_EXTRA and make the variant a different target."
    }
    if {$val eq "1"} {
        flow_assert_input $path "a conditional constraint file, included because $cond=1" XDC_OPTIONAL
        lappend XDC_IMPL [list [file normalize $path] "XDC_OPTIONAL, included ($cond=1)"]
    } else {
        say "XDC_OPTIONAL: NOT reading $path ($cond=$val, not 1)"
    }
}

set __i 0
foreach e $XDC_IMPL {
    incr __i
    prov_pin xdc_impl.$__i [lindex $e 0] "impl-read"
    lappend ::PROV_FILES xdc_impl.$__i [lindex $e 0]
}
unset __i


################################################################################
# 4. OPEN THE DESIGN AND READ THE CONSTRAINTS
################################################################################

step "open the synthesis checkpoint"
open_checkpoint $IMPL_SYNTH_DCP

if {[catch {current_design} __d] || $__d eq ""} {
    die "open_checkpoint returned and there is no design in memory: $IMPL_SYNTH_DCP" \
        "  A checkpoint that opens to nothing is a checkpoint from a synthesis" \
        "  that did not finish, and Vivado exits 0 on both."
}
unset -nocomplain __d

step "constraints (implementation window)"
if {![llength $XDC_IMPL]} {
    warn "no implementation constraints: XDC_TIMING, XDC_DRC, XDC_EXTRA and"
    warn "  XDC_OPTIONAL are all empty. Timing will be reported against whatever"
    warn "  the synthesis checkpoint carried - and an unconstrained path has no"
    warn "  slack, so it has no line in the timing summary at all. This run's"
    warn "  timing numbers will not distinguish 'met' from 'never checked'; the"
    warn "  gate below refuses an unmeasurable WNS for that reason."
}
foreach e $XDC_IMPL {
    foreach {f role} $e break
    read_xdc $f
    # The project-mode half of the same decision (CONTRACT.md section 3.3): the
    # engine sets the read window from the variable that named the file. In a
    # checkpoint flow there is no constraints fileset, which is not an error.
    catch {
        set __o [get_files -quiet [file tail $f]]
        if {[llength $__o]} {
            set_property USED_IN_SYNTHESIS      false $__o
            set_property USED_IN_IMPLEMENTATION true  $__o
        }
    }
    say "read_xdc ($role): $f"
}


################################################################################
# 5. DEBUG CORES, THE SEAM, AND THE STRATEGY
#
# flow/steps/ila.tcl runs on the SYNTHESISED netlist and BEFORE opt_design: a
# core connected after optimisation probes nets that may no longer exist, and
# connect_debug_port on a net that was optimised away is an error at the end of a
# long stage. Its default is disabled, deliberately - a debug core is a
# modification of the design, not an observation of it.
#
# pre_impl FIRES BEFORE THE ILA STEP, not after, and the order is not arbitrary:
# the natural thing for a project hook to do here is mark nets for debug, and a
# MARK_DEBUG set after ila.tcl has already chosen its probes reaches nothing.
################################################################################

flow_hook pre_impl

flow_step ila

if {![info exists ::ILA_STEP_DONE] || !$::ILA_STEP_DONE} {
    die "the ila step did not finish: ::ILA_STEP_DONE is not set." \
        "  flow/steps/ila.tcl sets it on its last line and every override must" \
        "  too. Without the sentinel this stage cannot tell a run with debug" \
        "  cores from one without - and their utilisation, placement and timing" \
        "  numbers are not comparable in either direction."
}
set ILA_ON [expr {[info exists ::ILA_ENABLED] ? $::ILA_ENABLED : 0}]

flow_step impl_setup

if {![info exists ::IMPL_SETUP_DONE] || !$::IMPL_SETUP_DONE} {
    die "impl_setup did not finish: ::IMPL_SETUP_DONE is not set." \
        "  flow/steps/impl_setup.tcl sets it on its last line and every project" \
        "  override must too - its header says so. Without the sentinel this" \
        "  stage would run opt, place and route at Vivado's defaults and record" \
        "  a strategy nobody used."
}
foreach v {IMPL_OPT_ARGS IMPL_PLACE_ARGS IMPL_PHYS_ARGS IMPL_ROUTE_ARGS IMPL_POSTROUTE_ARGS} {
    if {![info exists $v]} {
        die "impl_setup left no $v." \
            "  The stage splices each list into its command. A missing list runs" \
            "  that command at Vivado's defaults and records nothing."
    }
}


################################################################################
# 6. IMPLEMENTATION
#
# INCREMENTAL IS READ HERE OR IT DOES NOTHING. `read_checkpoint -incremental`
# must be issued on the open design BEFORE opt_design; issued after place_design
# it is ACCEPTED AND HAS NO EFFECT, and the run is a full implementation that
# took the full time and says "incremental" in every log line. That is the whole
# reason impl_setup only RESOLVES the reference and this stage reads it.
#
# Nothing below is wrapped in try_step. try_step catches and carries on, which is
# right for optional work and wrong for anything the result depends on: a catch
# around route_design converts a real failure into a passing run with a missing
# artefact, which is the failure mode this toolkit exists to stamp out.
################################################################################

if {[info exists ::IMPL_INCREMENTAL_REF] && $::IMPL_INCREMENTAL_REF ne ""} {
    step "incremental reference"
    if {$IMPL_INCREMENTAL_DIRECTIVE ne ""} {
        read_checkpoint -incremental $::IMPL_INCREMENTAL_REF -directive $IMPL_INCREMENTAL_DIRECTIVE
    } else {
        read_checkpoint -incremental $::IMPL_INCREMENTAL_REF
    }
    say "read BEFORE opt_design: $::IMPL_INCREMENTAL_REF"
    warn "report_incremental_reuse is the ONLY evidence that anything was reused."
    warn "  When the reference has diverged Vivado falls back to a FULL run, says"
    warn "  so once as an informational message, and then produces the same"
    warn "  commands, artefacts and wall clock as a normal run."
}

step "opt_design"
opt_design {*}$IMPL_OPT_ARGS

if {$IMPL_PRE_PLACE_PHYS_OPT} {
    step "phys_opt_design (pre-place)"
    phys_opt_design {*}$IMPL_PHYS_ARGS
}

step "place_design"
place_design {*}$IMPL_PLACE_ARGS

if {$IMPL_PHYS_OPT} {
    step "phys_opt_design (post-place)"
    phys_opt_design {*}$IMPL_PHYS_ARGS
}

step "route_design"
route_design {*}$IMPL_ROUTE_ARGS

if {$IMPL_POST_ROUTE_PHYS_OPT} {
    step "phys_opt_design (post-route)"
    # This pass can leave nets it modified UNROUTED. The route status measured
    # before it does not describe the design after it, and route_design returned
    # 0 either way - which is why report_route_status is run below, after
    # everything, and never cached from an earlier point in the stage.
    phys_opt_design {*}$IMPL_POSTROUTE_ARGS
}


################################################################################
# 7. POST-ROUTE PROJECT TCL - SOURCED, NEVER read_xdc'd
#
# CONTRACT.md section 9.4, measured: VIVADO REJECTS PROCEDURAL TCL IN AN XDC. A
# DRC waiver is procedural Tcl (`create_waiver`), so a waiver file fed to
# read_xdc produces an error inside constraint parsing that names a line rather
# than the mechanism - and the usual next move is to delete the waiver. Hence
# XDC_POST_ROUTE, and hence this block: impl_setup asserted the paths, and the
# stage sources them at the one moment it works.
################################################################################

if {[info exists IMPL_POST_ROUTE_TCL] && [llength $IMPL_POST_ROUTE_TCL]} {
    step "XDC_POST_ROUTE"
    foreach f $IMPL_POST_ROUTE_TCL {
        say "source (NOT read_xdc): $f"
        prov_pin xdc_post_route.[file tail $f] $f "impl-source"
        lappend ::PROV_FILES xdc_post_route.[file tail $f] $f
        # At global scope: a waiver file that defined a proc or set a variable
        # for a later one would otherwise lose it, and `source` inside a proc is
        # a scope surprise nobody debugs twice.
        uplevel #0 [list source $f]
    }
}


################################################################################
# 8. EVIDENCE, THEN THE SEAM, THEN THE WRITES
#
# The plan is built before the seam so a hook can read or extend it; the reports
# run after the seam so they describe the design that is about to be written; the
# checkpoint is written after that. CONTRACT.md section 6.1.3.
#
# THE PLAN'S FILES ARE DELETED FIRST. flow/steps/report_setup.tcl names
# `timing_summary.rpt` at BOTH synthesis and implementation, so an implementation
# that dies before reporting leaves the SYNTHESIS stage's timing summary in the
# file mk/flow.mk and ci/assert-stage.sh grade as this stage's - a report about
# an unplaced netlist, read as the routed design's timing. A report this stage
# did not write must be ABSENT.
################################################################################

set ::env(REPORT_STAGE) impl
flow_step report_setup

if {![info exists ::REPORT_SETUP_DONE] || !$::REPORT_SETUP_DONE} {
    die "report_setup did not finish: ::REPORT_SETUP_DONE is not set." \
        "  Every gate below reads a file that step writes."
}

flow_hook post_impl

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
        warn "  A gate reads it, and absent evidence is UNVERIFIED - a failure."
    } else {
        say [format "  %-28s %s" $__name "(not written)"]
    }
}
unset -nocomplain __e __name __req __cmd __f __err

set TIMING_RPT [file join $REPORT_DIR timing_summary.rpt]
set ROUTE_RPT  [file join $REPORT_DIR route_status.rpt]
set UTIL_RPT   [file join $REPORT_DIR utilization_impl.rpt]
set DRC_RPT    [file join $REPORT_DIR drc.rpt]

step "write the routed checkpoint"
set DCP [file join $OUT_DIR ${block_name}_routed.dcp]
write_checkpoint -force $DCP
say "checkpoint: $DCP"
if {$IMPL_WRITE_NETLIST} {
    write_verilog -force -mode timesim [file join $OUT_DIR ${block_name}_routed.v]
    say "netlist: [file join $OUT_DIR ${block_name}_routed.v]"
}
if {$IMPL_WRITE_SDF} {
    write_sdf -force [file join $OUT_DIR ${block_name}_routed.sdf]
    say "sdf: [file join $OUT_DIR ${block_name}_routed.sdf]"
}


################################################################################
# 9. MEASUREMENT - OUT OF THE REPORT FILES, NOT OUT OF THE TOOL
#
# Every number below is parsed from a file this stage wrote. Nothing is taken
# from a Tcl query of the live design, for the reason report_setup.tcl states in
# its header: the step produces the evidence, the gate produces the verdict, and
# a check that also produced its own input could never be shown to fail.
################################################################################

# The Design Timing Summary table: a header row naming WNS(ns), a rule, then one
# data row. Returned as a dict; a field that is not a number - Vivado writes
# `NA` when nothing was constrained - stays absent, so the gate sees `unmeasured`
# rather than a zero it would read as "met".
proc timing_summary {file} {
    set out {}
    if {![file exists $file] || ![file size $file]} { return $out }
    set fh [open $file r] ; set data [read $fh] ; close $fh
    set lines [split $data "\n"]
    set n [llength $lines]
    for {set i 0} {$i < $n} {incr i} {
        if {![regexp {WNS\(ns\)} [lindex $lines $i]]} { continue }
        # The row after the dashes. Scan forward past blank and rule lines.
        for {set j [expr {$i + 1}]} {$j < $n && $j < $i + 6} {incr j} {
            set row [string trim [lindex $lines $j]]
            if {$row eq "" || [string match "---*" $row]} { continue }
            set f [regexp -all -inline {\S+} $row]
            if {[llength $f] < 4} { continue }
            foreach {k idx} {wns 0 tns 1 tns_failing 2 tns_total 3 whs 4 ths 5
                             ths_failing 6 ths_total 7 wpws 8 tpws 9} {
                if {$idx < [llength $f]} {
                    set v [lindex $f $idx]
                    if {[string is double -strict $v]} { dict set out $k $v }
                }
            }
            return $out
        }
    }
    return $out
}

# The check_timing table of contents: `N. checking <name> (<count>)`. This is
# where a constraint set that matched nothing becomes visible - 4,812
# unconstrained endpoints appear here and NOWHERE ELSE, because the timing
# summary only reports paths that have a requirement (CONTRACT.md section 9.3).
proc timing_checks {file} {
    set out {}
    if {![file exists $file] || ![file size $file]} { return $out }
    set fh [open $file r]
    while {[gets $fh line] >= 0} {
        if {[regexp {^[0-9]+\. checking ([a-z_]+) \(([0-9]+)\)} $line -> name count]} {
            if {![dict exists $out $name]} { dict set out $name $count }
        }
    }
    close $fh
    return $out
}

# report_route_status: `# of <label>.......... :   <n> :`. Read as a table rather
# than grepped for one line, because the labels present depend on whether
# anything failed - the "unrouted nets" line only appears when there ARE some,
# and a parser looking only for it reports `unmeasured` on the good case and
# nothing at all on the bad one.
proc route_status {file} {
    set out {}
    if {![file exists $file] || ![file size $file]} { return $out }
    set fh [open $file r]
    while {[gets $fh line] >= 0} {
        if {[regexp {^\s*#\s+of\s+(.+?)\.*\s*:\s*([0-9]+)\s*:} $line -> label n]} {
            set label [string trim [string map {"." " "} $label]]
            regsub -all {\s+} $label " " label
            dict set out [string tolower $label] $n
        }
    }
    close $fh
    return $out
}

proc util_row {file names} {
    if {![file exists $file] || ![file size $file]} { return "" }
    set fh [open $file r] ; set data [read $fh] ; close $fh
    foreach line [split $data "\n"] {
        if {![string match "|*" $line]} { continue }
        set cells [split $line "|"]
        if {[llength $cells] < 4} { continue }
        set name [string trim [lindex $cells 1]]
        set used [string trim [lindex $cells 2]]
        foreach want $names {
            if {[string equal -nocase $name $want] && [string is integer -strict $used]} { return $used }
        }
    }
    return ""
}

# report_drc: "Violations found: N" plus a per-rule table whose second column is
# the severity. The severities are summed separately because they mean different
# things: an Error will stop write_bitstream, a Warning will not, and a flow that
# reported one number for both would either block on nothing or miss everything.
proc drc_counts {file} {
    set out {}
    if {![file exists $file] || ![file size $file]} { return $out }
    set fh [open $file r] ; set data [read $fh] ; close $fh
    set errors 0 ; set criticals 0 ; set warnings 0 ; set advisories 0 ; set total ""
    foreach line [split $data "\n"] {
        if {[regexp {Violations found:\s*([0-9]+)} $line -> t]} { set total $t ; continue }
        if {![string match "|*" $line]} { continue }
        set cells [split $line "|"]
        if {[llength $cells] < 5} { continue }
        set sev [string trim [lindex $cells 2]]
        set n   [string trim [lindex $cells 4]]
        if {![string is integer -strict $n]} { continue }
        switch -nocase -- $sev {
            "error"            { incr errors $n }
            "critical warning" { incr criticals $n }
            "warning"          { incr warnings $n }
            "advisory"         { incr advisories $n }
        }
    }
    dict set out total    $total
    dict set out errors   $errors
    dict set out criticals $criticals
    dict set out warnings $warnings
    dict set out advisories $advisories
    return $out
}

# THE COUNT FROM THE TOOL, THE IDS FROM THE LOG. See 4_synth.tcl section 9: the
# counter is authoritative and carries no ids, MSG_GATE_ALLOWLIST is a list of
# ids, and an allowlist applied to a partial reading would exempt messages nobody
# saw - so when the two disagree, no exemption is granted.
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

set TS  [timing_summary $TIMING_RPT]
set TC  [timing_checks  $TIMING_RPT]
set RS  [route_status   $ROUTE_RPT]
set DRC [drc_counts     $DRC_RPT]

# `stage` and `part` are in manifest blocks 1 and 3 already, and ci_mf takes
# the FIRST match for a key - a second copy is a second thing to disagree.
stage_meas top       $TOP
stage_meas flow_mode $FLOW_MODE
stage_meas ila       [expr {$ILA_ON ? "inserted" : "none"}]

foreach {k key} {wns wns whs whs tns tns ths ths tns_failing tns_failing \
                 ths_failing ths_failing tns_total tns_total ths_total ths_total} {
    stage_meas $k [expr {[dict exists $TS $key] ? [dict get $TS $key] : ""}]
}

# UNROUTED NETS: the explicit line when it exists, and routable-minus-fully-routed
# when it does not. Both are stated so a reader can see which one was used - a
# derived zero and a reported zero are the same number from different evidence.
set __unrouted ""
set __how "no route status to read"
if {[dict exists $RS "unrouted nets"]} {
    set __unrouted [dict get $RS "unrouted nets"]
    set __how "reported directly by report_route_status"
} elseif {[dict exists $RS "routable nets"] && [dict exists $RS "fully routed nets"]} {
    set __unrouted [expr {[dict get $RS "routable nets"] - [dict get $RS "fully routed nets"]}]
    set __how "routable ([dict get $RS {routable nets}]) minus fully routed ([dict get $RS {fully routed nets}])"
}
stage_meas unrouted_nets  $__unrouted
stage_meas unrouted_basis $__how
stage_meas routing_errors [expr {[dict exists $RS "nets with routing errors"] ? [dict get $RS "nets with routing errors"] : ""}]
stage_meas logical_nets   [expr {[dict exists $RS "logical nets"] ? [dict get $RS "logical nets"] : ""}]

stage_meas lut  [util_row $UTIL_RPT {{Slice LUTs} {Slice LUTs*} {CLB LUTs} {CLB LUTs*}}]
stage_meas ff   [util_row $UTIL_RPT {{Slice Registers} {CLB Registers} {Register as Flip Flop}}]
stage_meas bram [util_row $UTIL_RPT {{Block RAM Tile}}]
stage_meas dsp  [util_row $UTIL_RPT {{DSPs} {DSP48E1} {DSP48E2}}]
stage_meas iob  [util_row $UTIL_RPT {{Bonded IOB}}]

stage_meas drc_violations [expr {[dict exists $DRC total]     ? [dict get $DRC total]     : ""}]
stage_meas drc_errors     [expr {[dict exists $DRC errors]    ? [dict get $DRC errors]    : ""}]
stage_meas drc_criticals  [expr {[dict exists $DRC criticals] ? [dict get $DRC criticals] : ""}]
stage_meas drc_warnings   [expr {[dict exists $DRC warnings]  ? [dict get $DRC warnings]  : ""}]

# The constraint-coverage numbers. `unconstrained_endpoints` is the one that
# turns "this design met timing" into "this design was not asked to".
stage_meas no_clock_pins [expr {[dict exists $TC no_clock] ? [dict get $TC no_clock] : ""}]
stage_meas unconstrained_endpoints \
    [expr {[dict exists $TC unconstrained_internal_endpoints] ? [dict get $TC unconstrained_internal_endpoints] : ""}]

foreach {__cw __ids __nfound} [msg_criticals] break
stage_meas critical_warnings    $__cw
stage_meas critical_warning_ids [expr {[llength $__ids] ? [join $__ids {,}] : "(none)"}]
set __er "" ; catch { set __er [get_msg_config -count -severity {ERROR}] }
stage_meas errors $__er
unset -nocomplain __er

# dcp_bytes IS CROSS-CHECKED BY ci/assert-stage.sh against the file on disk. The
# two are written seconds apart by the same script, so a disagreement means the
# checkpoint landed after the manifest or the manifest is left over from another
# run - the failure a run namespace exists to make impossible, and therefore
# worth proving rather than assuming.
stage_meas dcp_bytes [expr {[file exists $DCP] ? [file size $DCP] : ""}]

foreach {k v} $::MEAS { say [format "  %-24s %s" $k $v] }


################################################################################
# 10. THE VERDICT - THE ONE CONTRACT.md SECTION 4 REQUIRES
################################################################################

set HARD    {}
set BUDGETS {}
set OWNED   {}
set NOTCOV  {}

# --- hard failures ---------------------------------------------------------
if {![file exists $DCP]} {
    lappend HARD "no routed checkpoint at $DCP - route_design returns 0 on a route\
                  it did not finish, so this is the evidence and the exit status\
                  was not"
} elseif {![file size $DCP]} {
    lappend HARD "the routed checkpoint at $DCP is ZERO BYTES"
}
foreach r $REPORT_MISSING {
    lappend HARD "required report '$r' was not written - a gate reads it, and\
                  absent evidence is UNVERIFIED, which is a failure"
}
if {![stage_meas_measured wns]} {
    lappend HARD "WNS could not be read out of reports/[file tail $TIMING_RPT]. An\
                  implementation with no timing number has not been timed - that is\
                  UNVERIFIED, not a design that met timing. The usual cause is a\
                  constraint set that matched nothing, which Vivado drops without\
                  an error and which leaves a CLEAN timing summary behind it"
}
if {![stage_meas_measured whs]} {
    lappend HARD "WHS could not be read out of reports/[file tail $TIMING_RPT] - hold\
                  was not measured, and hold is the failure that survives a slower\
                  clock"
}
if {![stage_meas_measured unrouted_nets]} {
    lappend HARD "the unrouted-net count could not be read out of\
                  reports/[file tail $ROUTE_RPT] ($__how) - nothing measured whether\
                  the design is routed"
}
if {[stage_meas_measured drc_errors] && [stage_meas_get drc_errors] > 0} {
    lappend HARD "[stage_meas_get drc_errors] post-route DRC ERROR(s) in\
                  reports/[file tail $DRC_RPT] - write_bitstream will refuse this\
                  design, and it reports that refusal as a DRC rather than as an\
                  exit code"
}

# --- budgets ---------------------------------------------------------------
# -1 means MEASURE AND REPORT, DO NOT GATE. Note the consequence for slack: a
# project cannot express a WNS budget of exactly -1 ns, because that is the
# sentinel. Recorded rather than worked around.
proc budget_max {label value budget where} {
    global BUDGETS
    if {$budget eq "" || ![string is double -strict $budget] || $budget < 0} { return 0 }
    if {![string is double -strict $value]} { return 0 }
    if {$value <= $budget} { return 0 }
    lappend BUDGETS "$label $value > budget $budget ($where)"
    return 1
}
proc budget_min {label value budget where} {
    global BUDGETS
    if {$budget eq "" || ![string is double -strict $budget] || $budget == -1} { return 0 }
    if {![string is double -strict $value]} { return 0 }
    if {$value >= $budget} { return 0 }
    lappend BUDGETS "$label $value < budget $budget ($where)"
    return 1
}

budget_min wns [stage_meas_get wns] $EXPECT_WNS_MIN \
    "setup slack, ns, from reports/[file tail $TIMING_RPT]"
budget_min whs [stage_meas_get whs] $EXPECT_WHS_MIN \
    "hold slack, ns, from reports/[file tail $TIMING_RPT]"
budget_max unrouted_nets [stage_meas_get unrouted_nets] $EXPECT_UNROUTED_MAX \
    "from reports/[file tail $ROUTE_RPT]: $__how"

set __from "post-route, from reports/[file tail $UTIL_RPT] - this is the number that ships"
budget_max lut  [stage_meas_get lut]  $EXPECT_LUT_MAX  $__from
budget_max ff   [stage_meas_get ff]   $EXPECT_FF_MAX   $__from
budget_max bram [stage_meas_get bram] $EXPECT_BRAM_MAX $__from
budget_max dsp  [stage_meas_get dsp]  $EXPECT_DSP_MAX  $__from
unset __from

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
if {[stage_meas_measured unconstrained_endpoints] && [stage_meas_get unconstrained_endpoints] > 0} {
    lappend OWNED "[stage_meas_get unconstrained_endpoints] unconstrained internal\
                   endpoint(s) and [stage_meas_get no_clock_pins] pin(s) with no\
                   clock, owner=the project's XDC_TIMING: these paths have no\
                   requirement, so they have NO SLACK and NO LINE in the timing\
                   summary above. The WNS this gate graded describes only the\
                   paths that were constrained. reports/[file tail $TIMING_RPT],\
                   check_timing section"
}
if {[stage_meas_measured drc_violations] && [stage_meas_get drc_violations] > 0} {
    lappend OWNED "[stage_meas_get drc_violations] post-route DRC violation(s)\
                   ([stage_meas_get drc_errors] error, [stage_meas_get drc_criticals]\
                   critical, [stage_meas_get drc_warnings] warning),\
                   owner=the project: a waiver belongs in XDC_POST_ROUTE where it is\
                   a reviewable artefact. reports/[file tail $DRC_RPT]"
}
if {$ILA_ON} {
    lappend OWNED "a DEBUG CORE is in this design, owner=ILA_ENABLE in design.mk:\
                   its utilisation, placement and timing numbers are NOT the numbers\
                   for the image without it, in either direction, and the .ltx probe\
                   file is the bitstream stage's to write"
}
lappend OWNED "whether every constraint MATCHED something, owner=`make xdc-lint`\
               (CONTRACT.md section 4), which mk/flow.mk does not implement yet:\
               Vivado drops a constraint that matches nothing without an error, and\
               the check_timing counts above are the only symptom this stage sees"

# --- not covered -----------------------------------------------------------
lappend NOTCOV "power. report_power with no switching activity is a vectorless\
                estimate - a confident number in watts that is not a measurement -\
                and it is off by default (REPORT_POWER)"
lappend NOTCOV "signal integrity, IO timing against the board, and anything that\
                depends on the PCB. The flow knows the device, not the circuit it\
                is soldered to"
lappend NOTCOV "whether the design is FUNCTIONALLY correct. Nothing in this flow\
                simulates anything"
lappend NOTCOV "timing at any corner or mode the XDC does not describe. A missing\
                corner is not a passing corner"
if {!$ILA_ON} {
    lappend NOTCOV "on-chip observability: no debug core is in this image\
                    (ILA_ENABLE=0), so nothing in it can be probed at run time"
}
if {$FLOW_MODE ne "direct"} {
    lappend NOTCOV "FLOW_MODE is '$FLOW_MODE' and this stage ran the in-memory\
                    checkpoint flow. The project-mode launch_runs path, DFX\
                    partition handling and ProtoCompiler are NOT implemented here"
}


set GATE [file join $REPORT_DIR impl_gate.txt]
write_gate $GATE impl $HARD $BUDGETS $OWNED $NOTCOV [list \
    "This gate is about a ROUTED DESIGN: is every net routed, what is the worst" \
    "setup and hold slack on the paths that were constrained, and did the" \
    "post-route rule check find anything. It is NOT a statement that the design" \
    "works, NOT a statement about paths the XDC never constrained - those have no" \
    "slack and no line in the timing summary - and NOT a power or signal-integrity" \
    "result. Every number here was read back out of a report file on disk," \
    "because route_design returns 0 on a route it did not finish and" \
    "report_timing_summary reports a clean sheet for a design nobody constrained."]

say "verdict: $GATE"


################################################################################
# 11. THE MANIFEST, LAST
################################################################################

set MANIFEST [prov_manifest impl]
stage_meas_append $MANIFEST

if {![file exists $MANIFEST] || ![file size $MANIFEST]} {
    die "the manifest at $MANIFEST was not written." \
        "  It is written last, so its absence is what tells a later reader that" \
        "  the stage did not reach its final section."
}

step "impl summary"
say "routed     : $DCP"
say "timing     : $TIMING_RPT   wns=[stage_meas_get wns] whs=[stage_meas_get whs]"
say "route      : $ROUTE_RPT    unrouted=[stage_meas_get unrouted_nets]"
say "verdict    : $GATE"
say "manifest   : $MANIFEST"

if {[llength $HARD]} {
    foreach h $HARD { puts "IMPL-FAIL: $h" }
    die "[llength $HARD] hard failure(s) - see $GATE"
}
if {[llength $BUDGETS]} {
    foreach b $BUDGETS { puts "IMPL-FAIL: budget exceeded: $b" }
    die "[llength $BUDGETS] budget(s) exceeded - see $GATE" \
        "  Ratchet the EXPECT_* knob in design.mk WITH the measurement and the" \
        "  margin written beside it, or fix the design. Do not demote the gate" \
        "  in a CI configuration, where no run record ever reaches it."
}
say "impl OK"

# Copyright (C) 2026, SoC Labs (www.soclabs.org)
