################################################################################
# steps/synth_setup.tcl - synthesis strategy
#
# Sourced by flow/vivado/4_synth.tcl via `flow_step synth_setup`, AFTER the
# sources and the pin constraints are read and BEFORE synth_design. A project
# replaces it wholesale with $(OVERRIDES_DIR)/synth_setup.tcl.
#
#
# IF YOU OVERRIDE THIS FILE
# ===========================================================================
# An override MUST still do all four of these, and the stage checks the first:
#
#   1. LEAVE ::SYNTH_ARGS SET, and end with `set ::SYNTH_SETUP_DONE 1`. The stage
#      calls `synth_design -top <top> -part <part> {*}$SYNTH_ARGS`, so a file
#      that sets tool properties and forgets the list synthesises the design at
#      Vivado's defaults and says nothing. The sentinel is checked in
#      milliseconds rather than after a forty-minute elaboration.
#
#   2. NOT PUT -top OR -part IN ::SYNTH_ARGS. The stage owns those: TOP is the
#      BOARD-LEVEL top and getting it wrong is quiet (CONTRACT.md section 3.2),
#      and PART comes from the board pack unless the project overrode it - which
#      flow_boot announces. A second -part on the command line wins over both,
#      silently, and the failure is a bitstream that will not load.
#
#   3. KEEP -flatten_hierarchy OUT OF `full`, OR FIX THE XDC IN THE SAME CHANGE.
#      See section 2. This is the one that costs a day.
#
#   4. DECLARE EVERY KNOB IT READS WITH `opt`, at the left margin. The stage
#      manifest enumerates the `opt` declarations rather than a hand-written
#      list, so a knob read with `$::env(...)` is a setting that shaped the run
#      and left no record - which is the defect the registration mechanism exists
#      to prevent.
#
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
################################################################################

################################################################################
# 1. THE DIRECTIVE
#
# `-directive` is the whole synthesis strategy in one word, and OMITTING IT IS
# NOT NEUTRAL. Vivado runs `default` when it is absent - the same behaviour, but
# with nothing in the run's artefacts that says so. Two runs, one at the implicit
# default and one at an explicit `AreaOptimized_high`, then differ in every QoR
# number and agree in every manifest field, which is exactly the comparison this
# toolkit refuses to let anyone make.
#
# So the directive is always passed, always registered, and always lands in the
# manifest. The value below is `default` because the effect of moving it has not
# been measured ON THIS DESIGN; turning it up starts an experiment.
#
# -directive is mutually exclusive with the individual strategy switches in the
# tool's own documentation, and Vivado does not always say so: when both are
# given the run can end up at neither setting. The switches this file sets below
# (-flatten_hierarchy, -gated_clock_conversion, -bufg, -fsm_extraction) are the
# ones that coexist with a directive; anything more aggressive belongs in
# SYNTH_EXTRA_ARGS, where the reader can see it fighting the directive.
################################################################################

opt SYNTH_DIRECTIVE   default   ;# default | RuntimeOptimized | AreaOptimized_high | PerformanceOptimized | ...
opt SYNTH_EXTRA_ARGS  ""        ;# appended verbatim. Anything here may fight -directive

set SYNTH_ARGS [list -directive $SYNTH_DIRECTIVE]
say "synth directive: $SYNTH_DIRECTIVE"


################################################################################
# 2. HIERARCHY - AND THE CONSTRAINT THAT SILENTLY MATCHES NOTHING
#
# THIS IS THE LOAD-BEARING SECTION OF THE FILE.
#
# `-flatten_hierarchy full` dissolves every module boundary. That is a legitimate
# QoR choice and it is also the single cheapest way to destroy a constraint set,
# because CONTRACT.md section 9.3 is a measured fact about this tool:
#
#     Vivado drops a constraint that matches nothing WITHOUT AN ERROR.
#
# A pin or timing constraint written against a hierarchical object -
# `get_cells u_sub/u_leaf/reg_r`, `get_pins u_sub/u_leaf/*/C`, a false path
# through a named instance - matches nothing once the hierarchy is gone. Vivado
# does not fail, does not return non-zero, and does not mark the run. It reports
# a design that is now UNCONSTRAINED on those paths, and an unconstrained path
# has no slack, so it does not appear in a timing summary at all. The run gets
# FASTER and CLEANER by every number the flow prints, and the design is worse.
#
# `rebuilt` is Vivado's default and the value here: the design is flattened for
# optimisation and the hierarchy is REBUILT afterwards, so cross-boundary
# optimisation still happens and hierarchical names still resolve. `none` keeps
# every boundary and gives up the optimisation.
#
# If a project genuinely needs `full`, it also needs to rewrite every
# hierarchical reference in its XDC in the same change, and `make xdc-lint` is
# what proves it did - which is why that target is not optional here.
################################################################################

opt SYNTH_FLATTEN_HIERARCHY  rebuilt   ;# rebuilt | none | full. `full` silently breaks hierarchical XDC

lappend SYNTH_ARGS -flatten_hierarchy $SYNTH_FLATTEN_HIERARCHY
if {$SYNTH_FLATTEN_HIERARCHY eq "full"} {
    warn "-flatten_hierarchy full: EVERY hierarchical reference in the XDC now"
    warn "  matches nothing, and Vivado drops a constraint that matches nothing"
    warn "  without an error (CONTRACT.md section 9.3). The paths those"
    warn "  constraints covered become UNCONSTRAINED, which removes them from"
    warn "  the timing summary entirely - so this run will report BETTER timing"
    warn "  than the design has. Run 'make xdc-lint' before believing any"
    warn "  number out of this stage."
}


################################################################################
# 3. GLOBAL BUFFERS - THE OTHER SILENT CEILING
#
# `-bufg <n>` caps how many global clock buffers synthesis will INFER. The tool
# default is 12. A design that needs more does not fail and is not warned about
# in any way a gate can see: the clocks past the cap are implemented on general
# interconnect, where skew is uncontrolled, and the symptom arrives at
# implementation as hold violations nobody can attribute.
#
# THE NUMBER THAT MATTERS IS NOT 12, IT IS THE DEVICE'S. A large part has far
# more than twelve global buffers and a small one has a hard limit per clock
# region that no synthesis switch can raise. Measured on a prototyping build of
# this codebase: 104 clock-gating cells were mapped onto BUFGCEs against 24 clock
# tracks per clock region, which is a placement problem that first appears as a
# timing failure four stages later.
#
# So the part pack states the buffer resource, and this file uses it when it is
# there rather than shipping a number that is right for one device.
################################################################################

opt SYNTH_BUFG  0   ;# 0 = ask the part pack. Any other value overrides it

if {$SYNTH_BUFG > 0} {
    lappend SYNTH_ARGS -bufg $SYNTH_BUFG
    say "-bufg $SYNTH_BUFG (explicit)"
} elseif {[part_have global_buffer_count]} {
    lappend SYNTH_ARGS -bufg [part global_buffer_count]
    say "-bufg [part global_buffer_count] (from the part pack)"
} else {
    warn "neither SYNTH_BUFG nor the part pack states a global-buffer count, so"
    warn "  Vivado's default of 12 applies. A design inferring more than twelve"
    warn "  global clocks gets the rest on general interconnect, silently, and"
    warn "  the symptom is uncontrolled skew reported as hold failures at"
    warn "  implementation. Add global_buffer_count to the part pack."
}


################################################################################
# 4. CLOCK GATING
#
# THE DEFAULT IS `auto`, SET DELIBERATELY 2026-09-09, because this toolkit's
# designs are built from Arm IP that was written for ASIC and therefore
# describes clock gating in RTL. Off is the wrong default for such a design:
# a gate written as `assign gclk = clk & en;` becomes exactly that on an FPGA -
# a LUT in the clock path, on local routing, with no global buffer and no skew
# control. Vivado infers no enable, warns about no such thing, and routes it.
#
# THE THREE SETTINGS, from UG901's GATED_CLOCK page - and the distinction
# between the last two is the one that matters here:
#
#   off   no conversion. The gate stays in the clock path.
#   on    convert, but ONLY where the RTL carries a `(* GATED_CLOCK = "TRUE" *)`
#         attribute on the gated signal.
#   auto  convert, detecting the gating pattern WITHOUT any attribute.
#
# `on` is the trap. ASIC-derived IP does not carry Xilinx synthesis attributes -
# there is no reason it would - so `on` looks like the strong setting and
# silently converts NOTHING, while reporting no error. `auto` is the setting
# that acts on IP you did not write. If you own the RTL and want per-signal
# control, annotate and use `on`; otherwise `auto` is the honest default.
#
# WHAT IT COSTS, AND WHY THIS IS STILL A KNOB. Conversion CHANGES THE NETLIST:
# the enable moves out of the clock and into the datapath, as a CE on the flops
# or onto a BUFGCE where that is better. That is not a small change at this
# codebase's scale - a prototyping build censused 3,007 clock-gating cells
# gating 86.6% of the flops. Two consequences a project should expect rather
# than discover:
#
#   - BUFGCE PRESSURE. A device has a bounded number of global buffers and a
#     bounded number of clock tracks per region. This lab has already lost time
#     to exactly this: a MegaSoC HAPS build put 104 ICGs onto BUFGCEs against 24
#     clock tracks per region, and the resulting failure was misread as a hold
#     problem for long enough to earn a waiver that hid a Removal check. If a
#     build starts failing placement or clock routing after this default
#     changed, look here first.
#   - EQUIVALENCE. The post-synthesis netlist no longer matches the ASIC one
#     structurally, which matters if anyone is comparing the two.
#
# Set `off` to get the old behaviour back, and record why in the manifest.
################################################################################

opt SYNTH_GATED_CLOCK_CONVERSION  auto   ;# auto | on | off. `on` needs a GATED_CLOCK attribute and does nothing without one

lappend SYNTH_ARGS -gated_clock_conversion $SYNTH_GATED_CLOCK_CONVERSION

################################################################################
# 4a. THE CONVERSION IS INERT WITHOUT CLOCKS, AND SAYS NOTHING ABOUT IT
#
# MEASURED 2026-09-09 on xc7z020, one RTL gate (`assign gclk = clk & en;`)
# feeding 16 flops, synthesised twice:
#
#   -gated_clock_conversion   create_clock?   BUFG   LUT in clock path   flop CE
#   off                       yes             0      1                   <const1>
#   auto                      yes             1      0                   en_IBUF
#   auto                      NO              0      1                   (no conversion)
#
# With the clock constrained, `auto` does exactly what it promises: the LUT
# leaves the clock path, a global buffer appears, and the enable lands on the
# flops. WITHOUT a `create_clock` reaching synthesis it does NOTHING - and it
# does nothing SILENTLY. No error, no warning, a byte-identical netlist. Vivado
# cannot recognise a gating pattern on a net it has not been told is a clock.
#
# That is a problem for THIS toolkit specifically, because CONTRACT section 3.3
# reads XDC_TIMING at IMPLEMENTATION ONLY - deliberately, since an exception
# read at synthesis changes what synthesis builds. Clock DEFINITIONS are not
# exceptions, but they live in the same file in every project shipped so far.
# The first real design measured: 1 of its 7 clock definitions in the
# synthesis-visible XDC, 6 in the implementation-only one. So the default this
# stage now sets would have converted almost nothing while reporting success.
#
# A silent no-op is the exact failure this repository exists to prevent, so the
# stage REFUSES rather than proceeding. It cannot make the conversion work - the
# fix is to give synthesis the clock definitions - but it can make the flow
# incapable of quietly not doing what its knob says.
################################################################################

opt SYNTH_GATED_CLOCK_REQUIRE_CLOCKS  1   ;# 1 = refuse when conversion is on but clocks are invisible to synthesis

## _synth_clock_names <file-list>
## The `-name` of every create_clock / create_generated_clock, plus a count of
## any that carry no -name. A static file scan, deliberately: it needs no design
## open, so the stage can refuse BEFORE synth_design has spent a licence.
proc _synth_clock_names {files} {
    set names {} ; set unnamed 0
    foreach f $files {
        if {$f eq "" || ![file readable $f]} { continue }
        set fh [open $f r]; set txt [read $fh]; close $fh
        # Join continuations first: a definition's -name is regularly on the
        # next physical line, and a scan that missed those would under-report
        # exactly the multi-line definitions this design uses most.
        regsub -all {\\[ \t]*\n} $txt " " txt
        foreach line [split $txt "\n"] {
            set line [string trim $line]
            if {[string index $line 0] eq "#"} { continue }
            if {![regexp {^create_(generated_)?clock\M} $line]} { continue }
            # `--` because the pattern STARTS with a dash and regexp would
            # otherwise read `-name...` as one of its own options.
            if {[regexp -- {-name[ \t]+\{?([^ \t\}]+)} $line -> n]} {
                lappend names $n
            } else {
                incr unnamed
            }
        }
    }
    return [list [lsort -unique $names] $unnamed]
}

if {$SYNTH_GATED_CLOCK_CONVERSION ne "off"} {
    set _gc_synth_xdc [concat [split [flow_env FPGA_XDC_PINS] " "] \
                              [split [flow_env FPGA_XDC_CLOCKS] " "]]
    set _gc_impl_xdc  [concat [split [flow_env FPGA_XDC_TIMING] " "] \
                              [split [flow_env FPGA_XDC_EXTRA] " "]]
    foreach {_gc_seen_n   _gc_seen_u}   [_synth_clock_names $_gc_synth_xdc] break
    foreach {_gc_impl_n   _gc_impl_u}   [_synth_clock_names $_gc_impl_xdc]  break

    # THE COMPARISON IS BY NAME, NOT BY COUNT, and the difference is the whole
    # correctness of this check. XDC_TIMING keeps its definitions - XDC_CLOCKS
    # is EXTRACTED from it, so the same clocks are in both by construction. A
    # count test therefore refuses a project that has already done the right
    # thing, which is exactly what the first real run after XDC_CLOCKS landed
    # did: 6 supplied, 6 still reported missing.
    set _gc_missing {}
    foreach n $_gc_impl_n {
        if {[lsearch -exact $_gc_seen_n $n] < 0} { lappend _gc_missing $n }
    }

    say "gated-clock: conversion=$SYNTH_GATED_CLOCK_CONVERSION, clocks visible to\
         synthesis: [llength $_gc_seen_n] ([join $_gc_seen_n {, }]); defined only for\
         implementation: [llength $_gc_missing]"

    if {[llength $_gc_missing] || $_gc_impl_u > $_gc_seen_u} {
        set _what [expr {[llength $_gc_missing]
                         ? "[llength $_gc_missing] clock(s) - [join $_gc_missing {, }]"
                         : "[expr {$_gc_impl_u - $_gc_seen_u}] unnamed clock definition(s)"}]
        set _m "SYNTH_GATED_CLOCK_CONVERSION is '$SYNTH_GATED_CLOCK_CONVERSION' but $_what\
                are defined only in implementation-only constraints.\n"
        append _m "  Vivado converts a gated clock only on a net it knows is a clock, so\n"
        append _m "  those will NOT be converted - silently, with no warning and a netlist\n"
        append _m "  identical to conversion being off. Measured, see this file's section 4a.\n"
        append _m "  Three ways forward:\n"
        append _m "    1. Name a synthesis-visible clock file in XDC_CLOCKS. It is read at\n"
        append _m "       synthesis and marked USED_IN_IMPLEMENTATION false, so\n"
        append _m "       implementation still takes these from XDC_TIMING and no clock is\n"
        append _m "       defined twice. Definitions are not exceptions.\n"
        append _m "    2. Set SYNTH_GATED_CLOCK_CONVERSION=off and say so in the manifest,\n"
        append _m "       if leaving RTL gates as LUTs in the clock path is the intent.\n"
        append _m "    3. Set SYNTH_GATED_CLOCK_REQUIRE_CLOCKS=0 to proceed anyway - the\n"
        append _m "       conversion will still be partial, but the run will record that it\n"
        append _m "       was known to be."
        if {$SYNTH_GATED_CLOCK_REQUIRE_CLOCKS} { die $_m } else { warn $_m }
    }
}


################################################################################
# 5. WHAT SYNTHESIS IS ALLOWED TO MERGE, MOVE OR THROW AWAY
#
# Three switches, all off by default, all of which change what a later stage can
# even NAME.
#
# -keep_equivalent_registers. Vivado merges registers it proves equivalent. That
# is right for area and WRONG for two things this codebase is full of: the first
# stage of a CDC synchroniser, which is deliberately replicated per destination,
# and a reset that was fanned out on purpose. Merging them puts the design back
# on the single flop the replication existed to avoid, and nothing reports it -
# the netlist is smaller and the CDC report still shows a two-flop synchroniser,
# because it still is one, just shared.
#
# -retiming. Moves registers across combinational logic. It also destroys the
# RTL-to-netlist name correspondence for every register it moves, so an XDC that
# names an internal register, a MARK_DEBUG probe, and every ILA net picked by
# name stop resolving - and see section 2 for what Vivado does about a constraint
# that stops resolving.
#
# -no_lc. Disables LUT combining. Costs area, and is the thing to reach for when
# a placement is congested rather than large.
################################################################################

opt SYNTH_KEEP_EQUIVALENT_REGISTERS  0   ;# 1 = do NOT merge equivalent flops (CDC/reset replication)
opt SYNTH_RETIMING                   0   ;# 1 = allow register retiming. Breaks hierarchical/probe names
opt SYNTH_NO_LC                      0   ;# 1 = disable LUT combining
opt SYNTH_FSM_EXTRACTION           auto  ;# auto | one_hot | sequential | johnson | gray | off
opt SYNTH_RESOURCE_SHARING         auto  ;# auto | on | off
opt SYNTH_SHREG_MIN_SIZE             3   ;# shift registers at or above this go to SRL

if {$SYNTH_KEEP_EQUIVALENT_REGISTERS} {
    lappend SYNTH_ARGS -keep_equivalent_registers
    say "-keep_equivalent_registers: equivalent flops are NOT merged"
}
if {$SYNTH_RETIMING} {
    lappend SYNTH_ARGS -retiming
    warn "-retiming is on. Registers move across logic, and the RTL name of every"
    warn "  register that moves stops existing in the netlist - so an XDC naming"
    warn "  one, a MARK_DEBUG attribute on one, and any ILA probe picked by name"
    warn "  silently stop matching. Vivado drops a constraint that matches"
    warn "  nothing without an error (CONTRACT.md section 9.3)."
}
if {$SYNTH_NO_LC} { lappend SYNTH_ARGS -no_lc }
lappend SYNTH_ARGS -fsm_extraction  $SYNTH_FSM_EXTRACTION
lappend SYNTH_ARGS -resource_sharing $SYNTH_RESOURCE_SHARING
lappend SYNTH_ARGS -shreg_min_size  $SYNTH_SHREG_MIN_SIZE


################################################################################
# 6. RESOURCE CEILINGS
#
# -1 means "no limit", which is Vivado's own default and is what the flow ships.
# These are not budgets - EXPECT_BRAM_MAX and friends are the budgets, and they
# are checked against a MEASUREMENT after the fact. These switches make synthesis
# refuse to infer past a ceiling, which turns a BRAM into distributed RAM instead
# of failing, and that is a design decision rather than a gate.
################################################################################

opt SYNTH_MAX_BRAM  -1   ;# -1 = no limit. NOT a budget; EXPECT_BRAM_MAX is the budget
opt SYNTH_MAX_URAM  -1   ;# -1 = no limit
opt SYNTH_MAX_DSP   -1   ;# -1 = no limit

foreach {__k __v} [list -max_bram $SYNTH_MAX_BRAM -max_uram $SYNTH_MAX_URAM \
                        -max_dsp  $SYNTH_MAX_DSP] {
    if {$__v >= 0} { lappend SYNTH_ARGS $__k $__v }
}
unset -nocomplain __k __v


################################################################################
# 7. OUT-OF-CONTEXT MODE
#
# `-mode out_of_context` tells synthesis this is not a whole device: NO I/O
# BUFFERS ARE INSERTED. That is correct for a packaged IP or a DFX reconfigurable
# module and catastrophic for a board-level top, because the resulting design has
# no IBUF/OBUF on any port, implementation places it happily, and the bitstream
# configures a device whose pins are not connected to anything. Vivado does not
# warn: out-of-context is a legitimate thing to ask for.
#
# IT USED TO BE DERIVED FROM FLOW_MODE, and that was the whole of this toolkit's
# `dfx` support: `FLOW_MODE=dfx` set this one argument and nothing else - no
# partition definition, no pblock, no HD.RECONFIGURABLE, no partial bitstream.
# A mode name that flipped the most dangerous switch in DFX and implemented none
# of the machinery that makes it safe is worse than no support at all, so the
# name is now refused at both layers (mk/flow.mk, and flow_boot in
# flow/common/flow_utils.tcl) and this is a free knob again.
#
# THAT MAKES THIS KNOB THE ONLY ROUTE TO AN OUT-OF-CONTEXT SYNTHESIS, which is
# the point of refusing the mode rather than deleting the capability: somebody
# who genuinely wants one asks for it by name, it is recorded in the manifest as
# the deliberate choice it is, and the gate says what it costs. The warning
# below is now the only announcement there is, so it stays.
################################################################################

opt SYNTH_MODE  "default"   ;# default | out_of_context. See the warning below

lappend SYNTH_ARGS -mode $SYNTH_MODE
if {$SYNTH_MODE eq "out_of_context"} {
    warn "-mode out_of_context: NO I/O BUFFERS will be inserted. That is right"
    warn "  for a reconfigurable module or a packaged IP and wrong for a"
    warn "  board-level top - the bitstream would configure a device with no"
    warn "  buffer on any pin, and nothing in the flow after this point can"
    warn "  tell the two cases apart. It was asked for by SYNTH_MODE; nothing"
    warn "  else in this toolkit can turn it on."
}


################################################################################
# 8. DEFINES AND PARAMETERS
#
# READ THIS BEFORE ADDING A `define TO CONFIGURE ANYTHING.
#
# There is no `ifdef FPGA and no `ifdef ASIC anywhere in this codebase - zero
# hits across 13,524 RTL files, along with XILINX, VIVADO, SIMULATION and
# FPGA_ONLY (CONTRACT.md section 9.1). A flow that configures the build with
# `+define+FPGA` configures NOTHING, and does so silently. Selection here is by
# flist file-swap and by module parameter.
#
# AND DEFINES DO NOT SURVIVE IP PACKAGING. `ipx::package_project` drops fileset
# defines by three separate routes, and it has already failed silently in this
# tree: an `ifdef-guarded opt-in was false in EVERY FPGA build, proven by a
# byte-identical "feature-off" bitstream (CONTRACT.md section 9.2). Parameters
# survive packaging as CONFIG.*; defines do not.
#
# So: RTL_PARAMS is the mechanism for anything load-bearing. Defines are passed
# here because a flist may legitimately carry them, and they are passed ON THE
# synth_design COMMAND LINE rather than only as a fileset property, because the
# command line is the form that survives.
################################################################################

opt SYNTH_DEFINES  ""   ;# extra defines. See above: parameters survive packaging, defines do not
opt SYNTH_PARAMS   ""   ;# NAME=VALUE generics/parameters, applied to the top

set __defs {}
foreach __d [concat [split $SYNTH_DEFINES] [split [flow_env FPGA_RTL_DEFINES]]] {
    if {[string trim $__d] ne ""} { lappend __defs [string trim $__d] }
}
if {[info exists ::flist_defines]} {
    foreach __d $::flist_defines {
        if {[lsearch -exact $__defs $__d] < 0} { lappend __defs $__d }
    }
}
if {[llength $__defs]} {
    lappend SYNTH_ARGS -verilog_define $__defs
    say "verilog defines: [join $__defs { }]"
}

# ASSERTED ABSENT. RTL_DEFINES_NEVER names defines that must NOT reach this
# build - an ASIC-only technology macro is the case that motivated it, and the
# cost of getting it wrong is a bitstream built against cells that do not exist
# on a device. A define asserted absent and then present is a hard stop, because
# every number after it would be about the wrong design.
foreach __n [split [flow_env FPGA_RTL_DEFINES_NEVER]] {
    set __n [string trim $__n]
    if {$__n eq ""} { continue }
    foreach __d $__defs {
        if {[lindex [split $__d =] 0] eq $__n} {
            die "RTL_DEFINES_NEVER asserts '$__n' is absent, and it is being passed to synthesis." \
                "  full define: $__d" \
                "  It reached here from the flist, from RTL_DEFINES, or from" \
                "  SYNTH_DEFINES. Nothing downstream of this point can tell a" \
                "  design built with it from one built without."
        }
    }
}

set __params {}
foreach __p [concat [split $SYNTH_PARAMS] [split [flow_env FPGA_RTL_PARAMS]]] {
    if {[string trim $__p] ne ""} { lappend __params [string trim $__p] }
}
if {[llength $__params]} {
    lappend SYNTH_ARGS -generic $__params
    say "parameters: [join $__params { }] (these survive IP packaging; defines do not)"
}
unset -nocomplain __d __n __p __defs __params


# THE PROJECT-MODE MIRROR WAS HERE, AND IT IS GONE - not because it was wrong,
# but because it mirrored the knobs above onto `get_runs synth_1` for a
# FLOW_MODE=project that no stage implements and that both layers now refuse.
# Every stage opens `create_project -in_memory`, which has no runs, so the block
# could never fire; a reader finding it would reasonably conclude that project
# mode was partly supported, which is the same substitution in another form.
# If a launch_runs path is ever written, its strategy hand-over belongs in the
# stage that creates the run, next to the run.

if {[llength [split $SYNTH_EXTRA_ARGS]]} {
    foreach __a [split $SYNTH_EXTRA_ARGS] {
        if {[string trim $__a] ne ""} { lappend SYNTH_ARGS [string trim $__a] }
    }
    warn "SYNTH_EXTRA_ARGS appended verbatim: $SYNTH_EXTRA_ARGS"
    warn "  Nothing checks these against -directive. If they conflict, Vivado"
    warn "  may run at neither setting and will not say so."
    unset -nocomplain __a
}

say "synth_design args: $SYNTH_ARGS"

# THE LAST LINE. The stage refuses to call synth_design without it, so an
# override that returned early - or died halfway through a project's own logic
# and was caught somewhere - cannot silently hand over a default synthesis.
set ::SYNTH_SETUP_DONE 1

# Copyright (C) 2026, SoC Labs (www.soclabs.org)
