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

opt EXPECT_WNS_MIN        [flow_env FPGA_EXPECT_WNS_MIN        -1]  ;# -1 = measure and report, do not gate. NOTE: -1 is the sentinel, so a budget of exactly -1 ns is inexpressible
opt EXPECT_WHS_MIN        [flow_env FPGA_EXPECT_WHS_MIN        -1]  ;# hold slack floor, ns
opt EXPECT_LUT_MAX        [flow_env FPGA_EXPECT_LUT_MAX        -1]  ;# graded POST-ROUTE here - the number that ships
opt EXPECT_FF_MAX         [flow_env FPGA_EXPECT_FF_MAX         -1]  ;# graded post-route
opt EXPECT_BRAM_MAX       [flow_env FPGA_EXPECT_BRAM_MAX       -1]  ;# graded post-route
opt EXPECT_DSP_MAX        [flow_env FPGA_EXPECT_DSP_MAX        -1]  ;# graded post-route
opt EXPECT_UNROUTED_MAX   [flow_env FPGA_EXPECT_UNROUTED_MAX    0]  ;# route_design returns 0 with unrouted nets, so this is armed by default
opt ALLOW_CRITICAL_WARNINGS [flow_env FPGA_ALLOW_CRITICAL_WARNINGS 0] ;# 1 = report critical warnings, do not gate
opt MSG_GATE_ALLOWLIST    [flow_env FPGA_MSG_GATE_ALLOWLIST ""]     ;# a TCL LIST of message ids

set TOP      [flow_env FPGA_TOP]
set PART_STR [flow_env FPGA_PART]
if {$PART_STR eq ""} { set PART_STR [part part_name] }


################################################################################
# 2. THE MEASUREMENT BLOCK AND THE VERDICT WRITER LIVE IN provenance.tcl
#
# ci/assert-stage.sh reads this stage's numbers out of the manifest with
# `awk '$1 == key'`, so they are top-level keys. prov_manifest writes the seven
# blocks CONTRACT.md section 5 fixes and has no eighth; prov_set would put them
# in the `prov.` namespace, which `compare-runs` treats as design IDENTITY, and
# a QoR number is a RESULT. So block 8 is appended after prov_manifest returns.
#
# That was written out longhand in all six stage scripts - as `stage_meas`,
# `stage_meas_get`, `stage_meas_measured`, `stage_meas_append` and `write_gate`
# here, as `stage_fields` and `gate_write` in the front half - by two sessions
# that each found the hole independently. They are now, in provenance.tcl:
#
#   prov_stage_field <k> <v>       record one measurement
#   prov_stage_get <k>             read it back ("unmeasured" when absent)
#   prov_stage_measured <k>        true only for a REAL measurement
#   prov_stage_fields <manifest>   append block 8
#   prov_gate <stage> <stem> ...   the verdict artefact
#
# flow_boot sources provenance.tcl, so nothing here has to. `stage_stop` below
# is still local: it is this stage's REFUSAL path, not a manifest writer.
################################################################################

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
    prov_stage_field stage_status "REFUSED: $reason"
    catch {
        prov_gate $stage $stage \
            [list \
                "THIS STAGE REFUSED. It did not run, so every number it would have" \
                "produced is absent rather than good. The hard failure below is the" \
                "input it could not read; the run directory holds no artefact from" \
                "this stage and no later stage can be graded against one."] \
            [list $reason] \
            {} \
            {} \
            [list "everything. This stage refused before it ran, so nothing about\
                   this design was measured at any setting"]
    }
    catch {
        set m [prov_manifest $stage]
        prov_stage_fields $m
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
if {![file exists $IMPL_SYNTH_DCP] || ![file size $IMPL_SYNTH_DCP]} {
    stage_stop impl "no synthesised checkpoint to implement" [list \
        "there is no checkpoint to implement." \
        "  looked for: $IMPL_SYNTH_DCP" \
        "  'make synth' writes it. Vivado exits 0 after a failed synth_design, so" \
        "  a missing checkpoint here is often the first hard evidence of that:" \
        "    grep -nE '^ERROR|CRITICAL WARNING|Failed' \$LOG_DIR/synth.log" \
        "  SYNTH_RUN_TAG selects which run's outputs this stage reads." \
        "  A record of this refusal is in reports/impl_manifest.txt and" \
        "  reports/impl_gate.txt."]
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

# ONE ROW OF A UTILISATION TABLE IS READ BY prov_util_row, in provenance.tcl
# section 7. This file used to carry its own copy of that parser, as 4_synth.tcl
# did, and both copies tested the used column with `string is integer -strict` -
# false for `32.5`, which is how a 7-series report counts block RAM. BRAM came
# out `unmeasured` in the manifest of a design whose BRAM the tool had reported,
# and budget_max cannot compare a budget against a token, so EXPECT_BRAM_MAX
# could not fire either. The proc's header carries the measurement.

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

# THE CENSUS IS prov_msg_criticals, in provenance.tcl section 7. It grades the
# STAGE LOG and keeps the tool's counter as a cross-check, and THIS STAGE is the
# one that measured why: Vivado resets its message counters at opt_design,
# place_design and route_design as well as at open_checkpoint, so a counter read
# after route_design has forgotten every message this stage's own read_xdc
# raised. On the run that found it the counter said 0 and the log carried two
# `Constraints 18-611/18-612` from a bad set_bus_skew - and because the gate
# below is guarded by `> 0`, the whole message gate was SKIPPED and the run went
# green with two critical warnings nobody graded.

step "measurements"

set TS  [timing_summary $TIMING_RPT]
set TC  [timing_checks  $TIMING_RPT]
set RS  [route_status   $ROUTE_RPT]
set DRC [drc_counts     $DRC_RPT]

# `stage` and `part` are in manifest blocks 1 and 3 already, and ci_mf takes
# the FIRST match for a key - a second copy is a second thing to disagree.
prov_stage_field top       $TOP
prov_stage_field flow_mode $FLOW_MODE
prov_stage_field ila       [expr {$ILA_ON ? "inserted" : "none"}]

foreach {k key} {wns wns whs whs tns tns ths ths tns_failing tns_failing \
                 ths_failing ths_failing tns_total tns_total ths_total ths_total} {
    prov_stage_field $k [expr {[dict exists $TS $key] ? [dict get $TS $key] : ""}]
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
prov_stage_field unrouted_nets  $__unrouted
prov_stage_field unrouted_basis $__how
prov_stage_field routing_errors [expr {[dict exists $RS "nets with routing errors"] ? [dict get $RS "nets with routing errors"] : ""}]
prov_stage_field logical_nets   [expr {[dict exists $RS "logical nets"] ? [dict get $RS "logical nets"] : ""}]

prov_stage_field lut  [prov_util_row $UTIL_RPT {{Slice LUTs} {Slice LUTs*} {CLB LUTs} {CLB LUTs*}}]
prov_stage_field ff   [prov_util_row $UTIL_RPT {{Slice Registers} {CLB Registers} {Register as Flip Flop}}]
prov_stage_field bram [prov_util_row $UTIL_RPT {{Block RAM Tile}}]
prov_stage_field dsp  [prov_util_row $UTIL_RPT {{DSPs} {DSP48E1} {DSP48E2}}]
prov_stage_field iob  [prov_util_row $UTIL_RPT {{Bonded IOB}}]

prov_stage_field drc_violations [expr {[dict exists $DRC total]     ? [dict get $DRC total]     : ""}]
prov_stage_field drc_errors     [expr {[dict exists $DRC errors]    ? [dict get $DRC errors]    : ""}]
prov_stage_field drc_criticals  [expr {[dict exists $DRC criticals] ? [dict get $DRC criticals] : ""}]
prov_stage_field drc_warnings   [expr {[dict exists $DRC warnings]  ? [dict get $DRC warnings]  : ""}]

# The constraint-coverage numbers. `unconstrained_endpoints` is the one that
# turns "this design met timing" into "this design was not asked to".
prov_stage_field no_clock_pins [expr {[dict exists $TC no_clock] ? [dict get $TC no_clock] : ""}]
prov_stage_field unconstrained_endpoints \
    [expr {[dict exists $TC unconstrained_internal_endpoints] ? [dict get $TC unconstrained_internal_endpoints] : ""}]

# WHAT THE CENSUS FOUND, AND WHAT IT IS. `critical_warnings` is the number this
# stage EMITTED, read back out of its own log; `critical_warnings_basis` says
# which evidence produced it and what the tool's live counter said, because the
# two differ for a structural reason and a reader who sees only one of them
# cannot tell a quiet stage from a counter that was reset. `__complete` is the
# one that gates: an allowlist may only be applied to a list that accounts for
# every message.
set __msg      [prov_msg_criticals]
set __ids      [dict get $__msg ids]
set __complete [dict get $__msg complete]
prov_stage_field critical_warnings       [dict get $__msg total]
prov_stage_field critical_warnings_basis [dict get $__msg basis]
prov_stage_field critical_warning_ids    [expr {[llength $__ids] ? [join $__ids {,}] : "(none)"}]
set __cw [prov_stage_get critical_warnings]
set __er "" ; catch { set __er [get_msg_config -count -severity {ERROR}] }
prov_stage_field errors $__er
unset -nocomplain __er

# dcp_bytes IS CROSS-CHECKED BY ci/assert-stage.sh against the file on disk. The
# two are written seconds apart by the same script, so a disagreement means the
# checkpoint landed after the manifest or the manifest is left over from another
# run - the failure a run namespace exists to make impossible, and therefore
# worth proving rather than assuming.
prov_stage_field dcp_bytes [expr {[file exists $DCP] ? [file size $DCP] : ""}]

foreach k $::prov_stage_order { say [format "  %-24s %s" $k [prov_stage_get $k]] }


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
if {![prov_stage_measured wns]} {
    lappend HARD "WNS could not be read out of reports/[file tail $TIMING_RPT]. An\
                  implementation with no timing number has not been timed - that is\
                  UNVERIFIED, not a design that met timing. The usual cause is a\
                  constraint set that matched nothing, which Vivado drops without\
                  an error and which leaves a CLEAN timing summary behind it"
}
if {![prov_stage_measured whs]} {
    lappend HARD "WHS could not be read out of reports/[file tail $TIMING_RPT] - hold\
                  was not measured, and hold is the failure that survives a slower\
                  clock"
}
if {![prov_stage_measured unrouted_nets]} {
    lappend HARD "the unrouted-net count could not be read out of\
                  reports/[file tail $ROUTE_RPT] ($__how) - nothing measured whether\
                  the design is routed"
}
if {[prov_stage_measured drc_errors] && [prov_stage_get drc_errors] > 0} {
    lappend HARD "[prov_stage_get drc_errors] post-route DRC ERROR(s) in\
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

budget_min wns [prov_stage_get wns] $EXPECT_WNS_MIN \
    "setup slack, ns, from reports/[file tail $TIMING_RPT]"
budget_min whs [prov_stage_get whs] $EXPECT_WHS_MIN \
    "hold slack, ns, from reports/[file tail $TIMING_RPT]"
budget_max unrouted_nets [prov_stage_get unrouted_nets] $EXPECT_UNROUTED_MAX \
    "from reports/[file tail $ROUTE_RPT]: $__how"

set __from "post-route, from reports/[file tail $UTIL_RPT] - this is the number that ships"
budget_max lut  [prov_stage_get lut]  $EXPECT_LUT_MAX  $__from
budget_max ff   [prov_stage_get ff]   $EXPECT_FF_MAX   $__from
budget_max bram [prov_stage_get bram] $EXPECT_BRAM_MAX $__from
budget_max dsp  [prov_stage_get dsp]  $EXPECT_DSP_MAX  $__from
unset __from

# THE MESSAGE GATE. An exemption requires BOTH that every id seen is in
# MSG_GATE_ALLOWLIST and that the id list is COMPLETE - an allowlist applied to a
# partial reading of the log would exempt messages nobody saw.
# MSG_GATE_ALLOWLIST defaults EMPTY (CONTRACT.md section 7).
#
# COMPLETENESS IS NOT "THE TWO COUNTS ARE EQUAL", which is what this test used to
# be. The counter is reset by the very commands this stage is made of, so on any
# impl run that emitted a message before route_design the two counts disagree and
# the equality test refused the exemption - `Project 1-1924` from
# write_hw_platform fires for EVERY design with no block design, so with the
# default ALLOW_CRITICAL_WARNINGS=0 such a project was permanently red with no
# route to green, whatever it declared. `complete` is the property the equality
# test was reaching for: the log was read and carries at least what the tool
# still counts, so the ids account for every message.
if {[prov_stage_measured critical_warnings] && $__cw > 0} {
    set __v [prov_msg_verdict $ALLOW_CRITICAL_WARNINGS $__ids \
                              $MSG_GATE_ALLOWLIST $__complete]
    switch -exact -- [dict get $__v verdict] {
        allowed {
            lappend OWNED "$__cw critical warning(s), owner=ALLOW_CRITICAL_WARNINGS=1 in\
                           design.mk: reported, not gated. ids: [join $__ids {, }]"
        }
        exempt {
            lappend OWNED "$__cw critical warning(s), owner=MSG_GATE_ALLOWLIST: every id\
                           is allowlisted with a diagnosis in design.mk. ids: [join $__ids {, }]"
        }
        incomplete {
            lappend BUDGETS "critical_warnings $__cw > budget 0 (ALLOW_CRITICAL_WARNINGS=0,\
                             and NO exemption can be granted from this run, whatever\
                             MSG_GATE_ALLOWLIST declares, because the id list does not\
                             account for every message: [prov_stage_get critical_warnings_basis])"
        }
        default {
            # The guard on an EMPTY unexempt list is not dead code being polite:
            # `unlisted` with nothing unexempt would mean the census counted
            # messages and read no ids, and a bullet ending in a bare colon is
            # how that would reach a reader.
            set __ux [dict get $__v unexempt]
            lappend BUDGETS "critical_warnings $__cw > budget 0 (ALLOW_CRITICAL_WARNINGS=0;\
                             ids not allowlisted: [expr {[llength $__ux] ? [join $__ux {, }] : {none readable in the stage log}}])"
            unset __ux
        }
    }
    unset __v
}

# --- delegated -------------------------------------------------------------
if {[prov_stage_measured unconstrained_endpoints] && [prov_stage_get unconstrained_endpoints] > 0} {
    lappend OWNED "[prov_stage_get unconstrained_endpoints] unconstrained internal\
                   endpoint(s) and [prov_stage_get no_clock_pins] pin(s) with no\
                   clock, owner=the project's XDC_TIMING: these paths have no\
                   requirement, so they have NO SLACK and NO LINE in the timing\
                   summary above. The WNS this gate graded describes only the\
                   paths that were constrained. reports/[file tail $TIMING_RPT],\
                   check_timing section"
}
if {[prov_stage_measured drc_violations] && [prov_stage_get drc_violations] > 0} {
    lappend OWNED "[prov_stage_get drc_violations] post-route DRC violation(s)\
                   ([prov_stage_get drc_errors] error, [prov_stage_get drc_criticals]\
                   critical, [prov_stage_get drc_warnings] warning),\
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


set GATE [prov_gate impl impl [list \
    "This gate is about a ROUTED DESIGN: is every net routed, what is the worst" \
    "setup and hold slack on the paths that were constrained, and did the" \
    "post-route rule check find anything. It is NOT a statement that the design" \
    "works, NOT a statement about paths the XDC never constrained - those have no" \
    "slack and no line in the timing summary - and NOT a power or signal-integrity" \
    "result. Every number here was read back out of a report file on disk," \
    "because route_design returns 0 on a route it did not finish and" \
    "report_timing_summary reports a clean sheet for a design nobody constrained."] \
    $HARD $BUDGETS $OWNED $NOTCOV]

say "verdict: $GATE"


################################################################################
# 11. THE MANIFEST, LAST
################################################################################

set MANIFEST [prov_manifest impl]
prov_stage_fields $MANIFEST

if {![file exists $MANIFEST] || ![file size $MANIFEST]} {
    die "the manifest at $MANIFEST was not written." \
        "  It is written last, so its absence is what tells a later reader that" \
        "  the stage did not reach its final section."
}

step "impl summary"
say "routed     : $DCP"
say "timing     : $TIMING_RPT   wns=[prov_stage_get wns] whs=[prov_stage_get whs]"
say "route      : $ROUTE_RPT    unrouted=[prov_stage_get unrouted_nets]"
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
