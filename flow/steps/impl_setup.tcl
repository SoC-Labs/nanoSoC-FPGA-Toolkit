################################################################################
# steps/impl_setup.tcl - implementation strategy: opt, place, phys_opt, route
#
# Sourced by flow/vivado/5_impl.tcl via `flow_step impl_setup`, AFTER the
# synthesis checkpoint is opened and the timing/DRC constraints are read, and
# BEFORE opt_design. A project replaces it wholesale with
# $(OVERRIDES_DIR)/impl_setup.tcl.
#
#
# IF YOU OVERRIDE THIS FILE
# ===========================================================================
# An override MUST still do all five of these:
#
#   1. LEAVE THE FIVE ARGUMENT LISTS SET - ::IMPL_OPT_ARGS, ::IMPL_PLACE_ARGS,
#      ::IMPL_PHYS_ARGS, ::IMPL_ROUTE_ARGS, ::IMPL_POSTROUTE_ARGS - and end with
#      `set ::IMPL_SETUP_DONE 1`. The stage runs each command with its list
#      spliced in; a missing list runs the command at Vivado's defaults and
#      records nothing.
#
#   2. PASS -directive TO EVERY ONE OF THEM. See section 1. An omitted directive
#      is not a neutral choice, it is an unrecorded one.
#
#   3. ISSUE `read_checkpoint -incremental` BEFORE opt_design IF IT USES
#      INCREMENTAL AT ALL, and keep the reuse report. See section 4 - this is the
#      one that produces a run that claims to be incremental and is not.
#
#   4. NOT `read_xdc` A POST-ROUTE WAIVER FILE. Vivado rejects procedural Tcl in
#      an XDC, so XDC_POST_ROUTE is `source`d after route_design (CONTRACT.md
#      section 9.4). This file records the path; the stage sources it.
#
#   5. NOT GATE. Nothing in this file decides whether the run passed. route_design
#      returns 0 on a design with unrouted nets, on timing it did not meet, and
#      on a constraint file that matched nothing, so the verdict comes from
#      impl_gate.txt reading artefacts - never from this file and never from an
#      exit status (CONTRACT.md rule 0).
#
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
################################################################################

################################################################################
# 1. THE DIRECTIVES, AND WHY AN OMITTED ONE IS WORSE THAN A WRONG ONE
#
# Each of opt_design, place_design, phys_opt_design and route_design takes a
# `-directive`. Leaving it off runs `Default` - which is a real strategy, so
# nothing fails - and leaves NOTHING IN THE RUN'S ARTEFACTS SAYING WHICH
# STRATEGY RAN. Two implementations, one at the implicit default and one at
# `Explore`, then differ by hours of runtime and by every timing number, and
# their manifests agree in every field. That is the comparison this toolkit
# exists to refuse, and the only defence is that the directive is always passed
# and therefore always registered by `opt` and always in the manifest.
#
# THE DIRECTIVE AND THE FINE-GRAINED SWITCHES ARE MUTUALLY EXCLUSIVE in the
# tool's own documentation, and Vivado does not reliably say so when both are
# given. Anything beyond a directive goes in the EXTRA_ARGS knobs, where a reader
# can see it fighting.
#
# Every default below is Vivado's own, deliberately. A knob left at its default
# is at its default because the effect of moving it has not been measured ON THIS
# DESIGN; moving one starts an experiment, and the manifest records which
# experiment this run was.
################################################################################

opt IMPL_OPT_DIRECTIVE        Explore   ;# opt_design. Explore is the usual first escalation
opt IMPL_PLACE_DIRECTIVE      Default   ;# place_design
opt IMPL_PHYS_OPT_DIRECTIVE   Default   ;# phys_opt_design, pre-route
opt IMPL_ROUTE_DIRECTIVE      Default   ;# route_design
opt IMPL_OPT_EXTRA_ARGS       ""        ;# appended verbatim. May fight -directive
opt IMPL_PLACE_EXTRA_ARGS     ""
opt IMPL_ROUTE_EXTRA_ARGS     ""

set IMPL_OPT_ARGS       [list -directive $IMPL_OPT_DIRECTIVE]
set IMPL_PLACE_ARGS     [list -directive $IMPL_PLACE_DIRECTIVE]
set IMPL_PHYS_ARGS      [list -directive $IMPL_PHYS_OPT_DIRECTIVE]
set IMPL_ROUTE_ARGS     [list -directive $IMPL_ROUTE_DIRECTIVE]
set IMPL_POSTROUTE_ARGS {}


################################################################################
# 2. PHYSICAL OPTIMISATION, BEFORE AND AFTER THE ROUTER
#
# Two different passes with two different jobs, and they are not
# interchangeable:
#
#   PRE-ROUTE  phys_opt_design works on placement and estimated delays. Cheap,
#              and it is what fixes a high-fanout net before the router has to
#              live with it.
#   POST-ROUTE phys_opt_design works on real routed delays and is the only pass
#              that can close a path the router could not. It is also the one
#              that can LEAVE THE DESIGN WITH NETS IT MODIFIED AND DID NOT
#              FINISH REROUTING - so the route status has to be re-read
#              afterwards, not assumed to be the one measured before it ran.
#              The stage's gate reads report_route_status AFTER this pass for
#              exactly that reason.
#
# Post-route is OFF by default because it costs real time on a design that does
# not need it, and because a run that needs it is a run whose result should be
# read with the pre- and post- numbers side by side.
################################################################################

opt IMPL_PRE_PLACE_PHYS_OPT   0   ;# 1 = phys_opt_design before place_design (rare; for pathological fanout)
opt IMPL_PHYS_OPT             1   ;# 1 = phys_opt_design after place_design
opt IMPL_POST_ROUTE_PHYS_OPT  0   ;# 1 = phys_opt_design after route_design. Re-check route status after
opt IMPL_POST_ROUTE_PHYS_OPT_DIRECTIVE  Default

if {$IMPL_POST_ROUTE_PHYS_OPT} {
    set IMPL_POSTROUTE_ARGS [list -directive $IMPL_POST_ROUTE_PHYS_OPT_DIRECTIVE]
    say "post-route phys_opt: on ($IMPL_POST_ROUTE_PHYS_OPT_DIRECTIVE)"
    warn "post-route phys_opt can leave nets it modified unrouted. The route"
    warn "  status measured before this pass does NOT describe the design after"
    warn "  it, and route_design returns 0 either way. The stage's gate must"
    warn "  read report_route_status again after this pass - if you have"
    warn "  overridden the stage as well, make sure it still does."
}


################################################################################
# 3. THE ROUTER
#
# -tns_cleanup is the switch people leave off and then wonder about. Without it
# the router stops improving a path once the worst negative slack target is met,
# so a design with WNS = -0.010 and TNS = -4,000 ns routes to WNS = 0.000 and
# TNS = -4,000 ns, and the summary reports it as met. The total is what says
# whether the design is close or whether one path is lucky.
#
# route_design RETURNS 0 WITH UNROUTED NETS. That is not a caveat, it is the
# first rule in CONTRACT.md, and it is why nothing in this file decides anything:
# the verdict comes from report_route_status, parsed from a file, against
# EXPECT_UNROUTED_MAX.
################################################################################

opt IMPL_ROUTE_TNS_CLEANUP  1   ;# 1 = keep optimising total negative slack after WNS is met

if {$IMPL_ROUTE_TNS_CLEANUP} { lappend IMPL_ROUTE_ARGS -tns_cleanup }


################################################################################
# 4. INCREMENTAL IMPLEMENTATION - THE RUN THAT CLAIMS TO BE AND IS NOT
#
# THIS IS THE LOAD-BEARING SECTION OF THE FILE.
#
# Incremental implementation reuses a previous run's placement and routing. It is
# armed by `read_checkpoint -incremental <dcp>`, and there are three ways to get
# a run that says "incremental" in every log line and is not:
#
#   * THE CHECKPOINT IS READ TOO LATE. `read_checkpoint -incremental` must be
#     issued on the open design BEFORE opt_design. Issued after place_design it
#     is accepted and has no effect, and the run is a full implementation that
#     took the full time.
#
#   * THE REFERENCE HAS DIVERGED. When the reference netlist no longer matches
#     the current one closely enough, Vivado FALLS BACK TO A FULL RUN. It says so
#     once, as an informational message, in the middle of an implementation log,
#     and then behaves exactly like the successful case: same commands, same
#     artefacts, same wall clock as a normal run. A flow that does not read
#     report_incremental_reuse cannot tell the two apart, and "incremental was
#     enabled" is not evidence that anything was reused.
#
#   * THE CHECKPOINT IS THE ONE THIS RUN IS ABOUT TO OVERWRITE. Pointing the
#     reference at this run's own output directory reuses last time's answer to
#     produce this time's, which makes an A/B experiment compare a design against
#     itself. Hence IN_RUN_TAG and SYNTH_RUN_TAG: a stage READS one run's
#     databases and WRITES another's, and the two are separate variables so that
#     the difference is visible in `make env` rather than discovered afterwards.
#
# So this file only RESOLVES and ASSERTS the checkpoint; the stage reads it, at
# the one point where reading it works. And it requires the reuse report,
# because a percentage in a file is the only thing that distinguishes a reused
# run from a full one wearing its name.
################################################################################

opt IMPL_INCREMENTAL_DCP        ""   ;# reference .dcp. Read BEFORE opt_design or it does nothing
opt IMPL_INCREMENTAL_DIRECTIVE  ""   ;# "" | RuntimeOptimized | TimingClosure | Quick

set IMPL_INCREMENTAL_REF ""
if {$IMPL_INCREMENTAL_DCP ne ""} {
    flow_assert_input $IMPL_INCREMENTAL_DCP \
        "the reference checkpoint incremental implementation reuses" \
        IMPL_INCREMENTAL_DCP
    set IMPL_INCREMENTAL_REF [file normalize $IMPL_INCREMENTAL_DCP]

    # Pointing the reference at THIS run's outputs compares the design against
    # itself. Refuse rather than warn: the result is a number that looks like a
    # measurement and is not one.
    if {[info exists OUT_DIR] &&
        [string first "[file normalize $OUT_DIR]/" "$IMPL_INCREMENTAL_REF/"] == 0} {
        flow_refuse "the incremental reference is inside THIS run's output directory." \
            "  reference: $IMPL_INCREMENTAL_REF" \
            "  out_dir:   [file normalize $OUT_DIR]" \
            "  That reuses this run's own previous answer to produce its next" \
            "  one, so an A/B experiment compares the design against itself and" \
            "  every difference it reports is zero for the wrong reason. Point" \
            "  IMPL_INCREMENTAL_DCP at another run - IN_RUN_TAG and" \
            "  SYNTH_RUN_TAG exist so that reading one run and writing another" \
            "  is visible in 'make env'."
    }
    say "incremental reference: $IMPL_INCREMENTAL_REF"
    say "  the STAGE must read it with 'read_checkpoint -incremental' BEFORE"
    say "  opt_design. Read later it is accepted and does nothing."
    if {$IMPL_INCREMENTAL_DIRECTIVE ne ""} {
        say "incremental directive: $IMPL_INCREMENTAL_DIRECTIVE"
    }
    warn "report_incremental_reuse is the ONLY evidence that anything was"
    warn "  reused. When the reference has diverged too far Vivado falls back to"
    warn "  a FULL implementation, says so once as an informational message, and"
    warn "  then produces the same commands, the same artefacts and the same"
    warn "  wall clock as a normal run. report_setup.tcl schedules that report;"
    warn "  do not remove it while incremental is enabled."
}


################################################################################
# 5. POST-ROUTE PROJECT CONSTRAINTS
#
# A DRC waiver cannot be an XDC. Vivado rejects procedural Tcl in a constraints
# file, and `create_waiver` is procedural, so a waiver file has to be `source`d
# after route_design (CONTRACT.md section 9.4). This file resolves and asserts
# the path; the stage sources it at the one moment it works.
#
# THE PATH IS ASSERTED, NOT PROBED. A configured-but-missing optional input is an
# error, not a shrug (CONTRACT.md section 3.3): a waiver file that silently did
# not load leaves a run reporting violations it was told to expect, or - worse -
# a run that would have reported them and now does not.
################################################################################

set IMPL_POST_ROUTE_TCL {}
foreach __f [split [flow_env FPGA_XDC_POST_ROUTE]] {
    if {[string trim $__f] eq ""} { continue }
    flow_assert_input [string trim $__f] \
        "procedural Tcl sourced AFTER route_design - a DRC waiver, or anything\
         else Vivado will not accept inside an XDC" \
        XDC_POST_ROUTE
    lappend IMPL_POST_ROUTE_TCL [file normalize [string trim $__f]]
}
unset -nocomplain __f
if {[llength $IMPL_POST_ROUTE_TCL]} {
    say "post-route Tcl ([llength $IMPL_POST_ROUTE_TCL] file(s)): sourced after route_design, NOT read_xdc'd"
}


# THE PROJECT-MODE MIRROR WAS HERE, AND IT IS GONE, for the reason written out
# at the end of synth_setup.tcl: it hand-delivered these directives to
# `get_runs impl_1` for a FLOW_MODE=project that no stage implements and that
# both layers now refuse. There is no run object in an in-memory flow, so it
# never fired; what it did do was read like evidence that project mode worked.

foreach {__var __extra} [list IMPL_OPT_ARGS   $IMPL_OPT_EXTRA_ARGS \
                              IMPL_PLACE_ARGS $IMPL_PLACE_EXTRA_ARGS \
                              IMPL_ROUTE_ARGS $IMPL_ROUTE_EXTRA_ARGS] {
    foreach __a [split $__extra] {
        if {[string trim $__a] ne ""} { lappend $__var [string trim $__a] }
    }
}
unset -nocomplain __var __extra __a

say "opt_design       $IMPL_OPT_ARGS"
say "place_design     $IMPL_PLACE_ARGS"
say "phys_opt_design  [expr {$IMPL_PHYS_OPT ? $IMPL_PHYS_ARGS : {(disabled)}}]"
say "route_design     $IMPL_ROUTE_ARGS"
say "post-route opt   [expr {$IMPL_POST_ROUTE_PHYS_OPT ? $IMPL_POSTROUTE_ARGS : {(disabled)}}]"

# THE LAST LINE. See the header.
set ::IMPL_SETUP_DONE 1

# Copyright (C) 2026, SoC Labs (www.soclabs.org)
