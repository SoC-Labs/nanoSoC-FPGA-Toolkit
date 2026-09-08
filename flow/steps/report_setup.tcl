################################################################################
# steps/report_setup.tcl - which reports get written, and with which switches
#
# Sourced by flow/vivado/4_synth.tcl and flow/vivado/5_impl.tcl via
# `flow_step report_setup`, at the point where the design is in the state each
# report is about. A project replaces it wholesale with
# $(OVERRIDES_DIR)/report_setup.tcl.
#
# THIS FILE PRODUCES THE EVIDENCE. IT DOES NOT PRODUCE THE VERDICT. Every gate in
# this toolkit reads an artefact written here; nothing here decides anything. The
# separation is the point - a check that also produced its own input could never
# be shown to fail.
#
#
# IF YOU OVERRIDE THIS FILE
# ===========================================================================
# An override MUST still do all four of these, and each one has a gate that
# becomes UNVERIFIED - which counts as a FAILURE, never as a pass - without it:
#
#   1. GIVE EVERY REPORT `-file`. Section 1. A report without it goes to the
#      console and the gate that was going to parse it has no input.
#
#   2. PASS `-report_unconstrained` TO report_timing_summary. Section 2. This is
#      the load-bearing switch in the file and the only place in the flow that
#      can see a constraint set that matched nothing.
#
#   3. WRITE report_route_status AND report_utilization. They are the inputs to
#      EXPECT_UNROUTED_MAX and to the LUT/FF/BRAM/DSP budgets. A budget with no
#      measurement is not a loose budget, it is an absent check.
#
#   4. LEAVE ::REPORT_PLAN SET, and end with `set ::REPORT_SETUP_DONE 1`. The
#      plan is a list of {name required command}; the stage runs each entry,
#      asserts the file is non-empty when `required` is 1, and records the rest.
#
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
################################################################################

set REPORT_PLAN {}

# File-local. Composes one plan entry and puts the report in $REPORT_DIR.
#
# A HARDCODED RELATIVE FILENAME HERE WOULD MEAN TWO CONCURRENT RUNS LAND ON EACH
# OTHER'S FILE. The tool's cwd is the run's work directory, so a bare
# "timing.rpt" is per-run by accident today and shared the moment anybody adds a
# `cd`. Composing from $REPORT_DIR makes it per-run by construction, which is
# what CONTRACT.md section 5 asks for.
proc _rpt {name required cmd} {
    global REPORT_DIR REPORT_PLAN
    set f [file join $REPORT_DIR $name]
    lappend REPORT_PLAN [list $name $required "$cmd -file [list $f]"]
    return $f
}


################################################################################
# 1. EVERY REPORT GETS -file
#
# A Vivado report command with no `-file` writes to the console. That is not a
# smaller version of writing a file, it is a different outcome: the text goes
# into the stage log mixed with everything else, the gate that was going to parse
# `$(REPORT_DIR)/timing_summary.rpt` finds nothing, and CONTRACT.md rule 2 says
# what happens next - the evidence is absent, so the answer is UNVERIFIED, and
# UNVERIFIED counts as a failure.
#
# It is worth being precise about why this is a trap rather than an oversight: a
# run with the -file dropped LOOKS BETTER. The stage still exits 0. The log is
# fuller. The only difference is that the gates downstream stop having anything
# to read, and a gate with no input is exactly what a green run that proves
# nothing is made of.
#
# So the plan carries the filename and _rpt appends the switch; no call site
# below writes `-file` itself, and none can forget it.
################################################################################

opt REPORT_TIMING_MAX_PATHS  10   ;# paths in the detailed timing report
opt REPORT_TIMING_NWORST      1   ;# worst N paths per endpoint/group
opt REPORT_UTIL_HIERARCHICAL  1   ;# 1 = also break utilisation down by module
opt REPORT_CDC                1   ;# 1 = report_cdc
opt REPORT_CLOCK_INTERACTION  1   ;# 1 = report_clock_interaction
opt REPORT_METHODOLOGY        1   ;# 1 = report_methodology
opt REPORT_DRC                1   ;# 1 = report_drc (implementation only)
opt REPORT_POWER              0   ;# 1 = report_power. Meaningless without switching activity
opt REPORT_HIGH_FANOUT        0   ;# 1 = report_high_fanout_nets
opt REPORT_INCREMENTAL_REUSE  1   ;# 1 = report_incremental_reuse when a reference was read
opt REPORT_STAGE          synth   ;# synth | impl. Which set the stage wants


################################################################################
# 2. -report_unconstrained, THE SWITCH THAT SEES A CONSTRAINT SET THAT MATCHED
#    NOTHING
#
# THIS IS THE LOAD-BEARING SECTION OF THE FILE.
#
# CONTRACT.md section 9.3 is a measured fact about this tool: Vivado drops a
# constraint that matches nothing WITHOUT AN ERROR. A `create_clock` on a port
# whose name changed, a `set_input_delay` against a renamed pin, an XDC read into
# the wrong fileset - all of them leave the tool with a design that has fewer
# constrained paths than the author thinks, and no message that a gate can grep.
#
# Now consider what report_timing_summary says about that design. Timing is
# reported for CONSTRAINED paths. A path with no clock on it has no requirement,
# therefore no slack, therefore no violation, therefore no line in the summary.
# In the limit - an XDC that matched nothing at all - the report is a clean
# sheet: WNS is not negative, it is absent, and a gate looking for a negative
# number finds none and passes.
#
# `-report_unconstrained` is what makes that visible. It adds the unconstrained
# paths and the check_timing section, so "this design has 4,812 unconstrained
# endpoints" appears in the same file the timing gate already reads, instead of
# nowhere.
#
# THE OTHER TWO SWITCHES HERE MATTER FOR THE SAME REASON, ONE LEVEL DOWN:
#   -warn_on_violation  makes a violation ALSO emit a tool message, so the
#                       message gate sees it even if nobody parses the report.
#   -max_paths/-nworst  the default report shows the worst path per clock group.
#                       The second-worst group is invisible at the default, and
#                       on a multi-clock design that is where the real problem
#                       usually is.
################################################################################

opt REPORT_UNCONSTRAINED  1   ;# 1 = -report_unconstrained. See section 2 before turning this off

set __ts "report_timing_summary -delay_type min_max"
append __ts " -max_paths $REPORT_TIMING_MAX_PATHS -nworst $REPORT_TIMING_NWORST"
append __ts " -warn_on_violation"
if {$REPORT_UNCONSTRAINED} {
    append __ts " -report_unconstrained"
} else {
    warn "REPORT_UNCONSTRAINED=0. An unconstrained path has no requirement, so"
    warn "  it has no slack and no line in the timing summary - which means a"
    warn "  design whose XDC matched nothing reports CLEAN TIMING, and Vivado"
    warn "  drops a constraint that matches nothing without an error"
    warn "  (CONTRACT.md section 9.3). This run's timing numbers cannot"
    warn "  distinguish 'met' from 'never checked'."
}
_rpt timing_summary.rpt 1 $__ts
unset __ts


################################################################################
# 3. UTILISATION - AND WHY THE HIERARCHICAL FORM IS NOT A LUXURY
#
# The flat report answers "how full is the device", which is what the budgets
# gate on. It cannot answer "what got bigger", and that is the question anybody
# ratcheting EXPECT_LUT_MAX actually has: a total that moved by 4% is a fact
# about the run, and a total that moved by 4% because one module doubled is a
# fact about a change.
#
# -hierarchical costs a few seconds and turns every future utilisation
# regression from an investigation into a diff.
################################################################################

_rpt utilization_${REPORT_STAGE}.rpt 1 "report_utilization"
if {$REPORT_UTIL_HIERARCHICAL} {
    _rpt utilization_hier_${REPORT_STAGE}.rpt 0 "report_utilization -hierarchical"
}


################################################################################
# 4. WHAT ONLY EXISTS AFTER IMPLEMENTATION
#
# report_route_status IS THE UNROUTED-NET GATE'S ONLY INPUT. route_design returns
# 0 on a design with unrouted nets (CONTRACT.md rule 0), so the exit status
# carries no information and this file is where the information comes from.
#
# report_drc is the post-route rule check. It is separate from the bitstream
# DRC - a design can be DRC-clean here and still trip a write_bitstream check,
# which is why bitstream_opts.tcl carries its own section on CFGBVS.
#
# report_incremental_reuse is scheduled ONLY when a reference checkpoint was
# read, and when one was it is REQUIRED. See impl_setup.tcl section 4: when the
# reference has diverged Vivado silently falls back to a full implementation, and
# the reuse percentage in this file is the only thing that distinguishes a run
# that reused something from a run that claimed to.
################################################################################

if {$REPORT_STAGE eq "impl"} {
    _rpt route_status.rpt 1 "report_route_status"
    if {$REPORT_DRC} { _rpt drc.rpt 1 "report_drc" }
    if {$REPORT_INCREMENTAL_REUSE &&
        [info exists ::IMPL_INCREMENTAL_REF] && $::IMPL_INCREMENTAL_REF ne ""} {
        _rpt incremental_reuse.rpt 1 "report_incremental_reuse"
        say "incremental reuse report is REQUIRED this run: a reference checkpoint"
        say "  was read, and the reuse percentage is the only evidence that"
        say "  anything was actually reused."
    }
}


################################################################################
# 5. CLOCK-DOMAIN CROSSINGS
#
# Two reports, and they answer different questions:
#
#   report_clock_interaction  which clock pairs have paths between them, and how
#                             they are being TIMED. The value to look for is
#                             "Timed (unsafe)" - paths crossing between clocks
#                             with no declared relationship, which the tool times
#                             anyway, against a requirement nobody meant.
#   report_cdc                the structural view: which crossings have a
#                             recognised synchroniser and which do not.
#
# Neither is a gate here and neither should be: a design's CDC story is a design
# decision with an owner, and the stage's verdict artefact records it in the
# DECLARED ELSEWHERE section rather than pretending this flow adjudicated it.
# What this file guarantees is that the evidence exists, in a file, per run.
################################################################################

if {$REPORT_CLOCK_INTERACTION} { _rpt clock_interaction.rpt 0 "report_clock_interaction" }
if {$REPORT_CDC}               { _rpt cdc.rpt               0 "report_cdc" }
if {$REPORT_METHODOLOGY}       { _rpt methodology.rpt       0 "report_methodology" }
if {$REPORT_HIGH_FANOUT}       { _rpt high_fanout_nets.rpt  0 "report_high_fanout_nets" }


################################################################################
# 6. POWER, AND WHY IT IS OFF
#
# report_power with no switching activity is a vector-less estimate: the tool
# assumes a default toggle rate for every net in the design. It produces a
# confident-looking number in watts that is not a measurement of anything, and it
# is reliably quoted as one.
#
# So it is off by default, and the stage's verdict artefact lists power under
# "NOT covered by ANY run of this flow, at any setting" rather than letting an
# estimate stand in for a measurement. Turning it on is fine; believing the
# number without a SAIF is not.
################################################################################

if {$REPORT_POWER} {
    _rpt power.rpt 0 "report_power"
    warn "report_power with no switching activity is a VECTORLESS ESTIMATE: the"
    warn "  tool assumes a default toggle rate for every net. The number is in"
    warn "  watts and is not a measurement. Supply a SAIF before quoting it."
}

say "report plan: [llength $REPORT_PLAN] report(s) into $REPORT_DIR"
foreach __e $REPORT_PLAN {
    say [format "  %-28s %s" [lindex $__e 0] \
        [expr {[lindex $__e 1] ? {REQUIRED - a gate reads it} : {evidence}}]]
}
unset -nocomplain __e

# THE LAST LINE. See the header.
set ::REPORT_SETUP_DONE 1

# Copyright (C) 2026, SoC Labs (www.soclabs.org)
