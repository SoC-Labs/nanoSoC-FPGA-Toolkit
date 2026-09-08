################################################################################
# steps/ila.tcl - integrated logic analyser and debug-hub insertion
#
# Sourced by flow/vivado/5_impl.tcl via `flow_step ila`, on the SYNTHESISED
# netlist and BEFORE opt_design. A project replaces it wholesale with
# $(OVERRIDES_DIR)/ila.tcl - and for this step, unlike the others, overriding is
# the NORMAL case: which nets are worth probing is a fact about a design, and
# nothing in this repository is allowed to know it.
#
# DEFAULT: DISABLED. A debug core is not an observation of the design, it is a
# modification of it. See section 1.
#
#
# IF YOU OVERRIDE THIS FILE
# ===========================================================================
# An override MUST still do all four of these:
#
#   1. LEAVE THE BITSTREAM ABLE TO PRODUCE A .ltx. Section 3. A bitstream with
#      debug cores and no probe file is a bitstream whose cores cannot be used at
#      all, and nothing about the .bit says so.
#
#   2. GIVE THE DEBUG HUB A CLOCK, AND SAY WHAT ITS FREQUENCY IS. Section 4. This
#      is the one that produces a board that programs and then will not talk.
#
#   3. INSERT BEFORE opt_design. A core connected after optimisation probes nets
#      that may no longer exist, and `connect_debug_port` on a net that was
#      optimised away is an error at the end of a long stage.
#
#   4. LEAVE ::ILA_ENABLED SET (0 or 1) and end with `set ::ILA_STEP_DONE 1`.
#      The stage records which, and the manifest carries it - because a timing
#      number from a run with probes in it is not comparable with one from a run
#      without, and the manifest is where that gets noticed.
#
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
################################################################################

################################################################################
# 1. WHY THIS IS OFF BY DEFAULT
#
# An ILA is LUTs, flops and block RAM wired into the design, plus a debug hub,
# plus routing to every probed net. Inserting one:
#
#   * changes utilisation, so a LUT/BRAM budget measured with probes in is not
#     the budget for what ships;
#   * changes placement and routing, so WNS and WHS from a probed run do not
#     carry to an unprobed one - and the direction is not predictable, because
#     the hub also constrains where things can go;
#   * pins the probed nets, so the optimiser can no longer merge or retime them.
#     That is the point of MARK_DEBUG, and it means the netlist being measured is
#     genuinely a different netlist.
#
# None of that is a reason not to use an ILA. It is a reason the flow must never
# insert one that nobody asked for, and must record it in the manifest when it
# does - so that a comparison between a probed run and an unprobed one is
# REFUSED rather than reported.
################################################################################

opt ILA_ENABLE  0   ;# 1 = insert a debug core. Changes utilisation, placement AND timing

set ILA_ENABLED $ILA_ENABLE
set ILA_CORES   {}

if {!$ILA_ENABLE} {
    say "ILA: disabled (ILA_ENABLE=0). No debug core is inserted."
    say "  This is the shipping configuration: a debug core is a modification"
    say "  of the design, not an observation of it, so the flow never adds one"
    say "  nobody asked for."
    set ::ILA_ENABLED 0
    set ::ILA_STEP_DONE 1
    return
}


################################################################################
# 2. THE PROBES, AND THE NAMES THAT STOP EXISTING
#
# A net is probeable after synthesis only if synthesis kept it, and synthesis
# keeps a net either because it had to or because it was told to. `MARK_DEBUG` in
# the RTL or in an XDC is the "told to" form and is the reliable one.
#
# TWO SETTINGS IN synth_setup.tcl DESTROY PROBE NAMES, and both are silent:
#
#   -flatten_hierarchy full   every hierarchical net name ceases to exist, so
#                             ILA_PROBE_NETS entries stop matching. The failure
#                             is `get_nets` returning empty, which is an EMPTY
#                             PROBE, not an error - a core that captures a
#                             constant zero and looks like a working capture of
#                             a signal that never toggles.
#   -retiming                 registers move across logic, so the net either side
#                             of a moved register is a different net with a
#                             different name.
#
# So every probe is resolved HERE, before anything is created, and a probe that
# matched nothing is fatal. A debug session that starts by discovering the
# capture was empty costs a board booking and a bench slot.
################################################################################

opt ILA_PROBE_NETS  ""    ;# a LIST of net names or get_nets patterns
opt ILA_DEPTH       1024  ;# samples per probe. Costs block RAM
opt ILA_CAPTURE_CONTROL 1 ;# 1 = capture control (storage qualification)
opt ILA_ADV_TRIGGER     0 ;# 1 = advanced trigger. Costs logic
opt ILA_TRIGIN          0 ;# 1 = enable the trigger-in port (cross-triggering)
opt ILA_CORE_NAME   u_ila_0

if {[string trim $ILA_PROBE_NETS] eq ""} {
    die "ILA_ENABLE=1 and ILA_PROBE_NETS is empty." \
        "  An ILA with no probes is block RAM and a debug hub wired into the" \
        "  design for nothing: it changes utilisation, placement and timing," \
        "  and captures no signal. Name the nets, or set ILA_ENABLE=0."
}

set ILA_RESOLVED {}
foreach __p [split $ILA_PROBE_NETS] {
    set __p [string trim $__p]
    if {$__p eq ""} { continue }
    if {![flow_have get_nets]} {
        # Under the knob census / a bare tclsh there is no design to ask. Record
        # the request; the resolution happens in the tool.
        lappend ILA_RESOLVED $__p
        continue
    }
    set __n {}
    catch { set __n [get_nets -quiet $__p] }
    if {![llength $__n]} {
        die "ILA probe '$__p' matches no net in the synthesised design." \
            "  A probe that matches nothing is not an error in Vivado's own" \
            "  debug flow - it is an EMPTY PROBE, and an empty probe captures a" \
            "  constant. On the bench that is indistinguishable from a signal" \
            "  that never toggled, and it costs a board booking to find out." \
            "  If the name is right in the RTL, synthesis removed it: check" \
            "  SYNTH_FLATTEN_HIERARCHY (full destroys hierarchical names) and" \
            "  SYNTH_RETIMING (moves registers, so the nets either side of one" \
            "  are renamed), and mark the net with MARK_DEBUG so synthesis" \
            "  keeps it."
    }
    foreach __x $__n { lappend ILA_RESOLVED $__x }
}
unset -nocomplain __p __n __x
say "ILA probes: [llength $ILA_RESOLVED] net(s), depth $ILA_DEPTH"


################################################################################
# 3. THE .ltx IS NOT OPTIONAL
#
# The bitstream carries the debug cores. It does NOT carry the map from a probe
# index to the net name it was attached to - that lives in the probes file, the
# `.ltx`, written beside the `.bit`. Without it the hardware manager sees a
# device with debug cores it cannot label, cannot trigger meaningfully and
# cannot decode.
#
# The failure has a particular shape worth knowing: the board programs fine. The
# ILA appears. The waveform is unnamed and the trigger conditions cannot be
# expressed. It reads as a tool problem, and it is a missing 200 KB file that the
# build was always going to write and did not.
#
# So the requirement is declared here and satisfied in the bitstream stage: the
# .ltx goes into OUT_DIR beside the .bit, with the same stem, and the stage
# asserts on it exactly as it asserts on the .bit. A .bit shipped without its
# .ltx is not a debuggable image, whatever the log said.
################################################################################

set ::ILA_LTX_REQUIRED 1
say "ILA: the bitstream stage MUST write the .ltx probe file beside the .bit."
say "  Without it the cores in the image cannot be labelled, triggered or"
say "  decoded - the board programs, the ILA appears, and the waveform is"
say "  anonymous. It is not recoverable after the fact from the .bit."


################################################################################
# 4. THE DEBUG HUB CLOCK - THE OTHER WAY TO SHIP A BOARD THAT WILL NOT TALK
#
# The debug hub is clocked, and its clock is NOT the JTAG clock. Two things have
# to be true about it and neither is checked by anything that runs before the
# board:
#
#   * IT HAS TO BE CONNECTED. Vivado infers the hub's clock from the debug cores
#     when it can. When it cannot - a design with several clocks, or cores that
#     were connected by hand - it emits a message and connects nothing, and the
#     hub ends up on a clock that is not free-running. A hub on a gated or
#     derived clock that stops is a hub the JTAG chain cannot reach: the device
#     programs and then does not enumerate a debug core at all.
#
#   * ITS FREQUENCY HAS TO BE DECLARED, AND IF IT IS SLOW, THE DIVIDER HAS TO BE
#     ON. The hub crosses between the JTAG clock and the design clock. When the
#     design clock is slow relative to the JTAG clock, that crossing needs the
#     hub's clock divider enabled or readback is unreliable - which presents as
#     intermittent, corrupt captures rather than as a failure, and gets blamed on
#     the probe.
#
# The frequency is a fact about the board's oscillator and its clocking, so it
# comes from SYS_CLK_FREQ_HZ or from the board pack rather than from a literal
# here. If neither states it, this stops: the alternative is a value the flow
# guessed, on a board the flow is not allowed to know about.
################################################################################

opt ILA_CLK_NET             ""   ;# the free-running net that clocks the debug hub
opt ILA_DBG_HUB_CLK_FREQ_HZ ""   ;# "" = take it from SYS_CLK_FREQ_HZ / the board pack
opt ILA_DBG_HUB_DIVIDER     0    ;# 1 = enable the hub's clock divider (slow debug clocks)

if {[string trim $ILA_CLK_NET] eq ""} {
    die "ILA_ENABLE=1 and ILA_CLK_NET is empty." \
        "  The debug hub's clock is not the JTAG clock and Vivado can only" \
        "  infer it sometimes. When it cannot, it connects nothing and the hub" \
        "  ends up on whatever it was given - and a hub on a clock that stops" \
        "  is a hub the JTAG chain never reaches: the device programs and then" \
        "  enumerates no debug core, with nothing in the build saying why." \
        "  Name a FREE-RUNNING net."
}

set ILA_CLK_FREQ $ILA_DBG_HUB_CLK_FREQ_HZ
if {$ILA_CLK_FREQ eq ""} { set ILA_CLK_FREQ [flow_env FPGA_SYS_CLK_FREQ_HZ] }
if {$ILA_CLK_FREQ eq "" && [board_have sys_clk_freq_hz]} {
    set ILA_CLK_FREQ [board sys_clk_freq_hz]
}
if {$ILA_CLK_FREQ eq ""} {
    die "no frequency for the debug hub clock." \
        "  Set ILA_DBG_HUB_CLK_FREQ_HZ, or SYS_CLK_FREQ_HZ, or sys_clk_freq_hz" \
        "  in the board pack. The hub crosses between the JTAG clock and this" \
        "  one, and a wrong or absent frequency shows up as intermittent," \
        "  corrupt captures that get blamed on the probe rather than on the" \
        "  hub. This repository is not allowed to guess it: it is a fact about" \
        "  a circuit board and it ships with the project."
}
say "debug hub clock: $ILA_CLK_NET at $ILA_CLK_FREQ Hz"


################################################################################
# 5. CREATE AND CONNECT
#
# Everything above ran without a tool. Everything below needs one, so it is
# guarded - the knob census and the phase-1 harness both load this file under a
# bare tclsh, and a step file that assumed a tool would take the whole suite with
# it (flow/common/flow_utils.tcl, header).
################################################################################

if {![flow_have create_debug_core]} {
    warn "no create_debug_core in this tool: the ILA was CONFIGURED and NOT"
    warn "  INSERTED. This is the knob census or a harness run, not a build."
    set ::ILA_ENABLED $ILA_ENABLE
    set ::ILA_STEP_DONE 1
    return
}

create_debug_core $ILA_CORE_NAME ila
set_property C_DATA_DEPTH        $ILA_DEPTH           [get_debug_cores $ILA_CORE_NAME]
set_property C_TRIGIN_EN         $ILA_TRIGIN          [get_debug_cores $ILA_CORE_NAME]
set_property C_ADV_TRIGGER       $ILA_ADV_TRIGGER     [get_debug_cores $ILA_CORE_NAME]
set_property C_EN_STRG_QUAL      $ILA_CAPTURE_CONTROL [get_debug_cores $ILA_CORE_NAME]
set_property C_INPUT_PIPE_STAGES 0                    [get_debug_cores $ILA_CORE_NAME]
set_property ALL_PROBE_SAME_MU        true            [get_debug_cores $ILA_CORE_NAME]
set_property ALL_PROBE_SAME_MU_CNT    1               [get_debug_cores $ILA_CORE_NAME]

# The core's own clock. Connected explicitly for the reason in section 4.
set_property port_width 1 [get_debug_ports ${ILA_CORE_NAME}/clk]
connect_debug_port ${ILA_CORE_NAME}/clk [get_nets $ILA_CLK_NET]

# One probe port per net, in the order the project named them - so a waveform
# read at the bench is in the order somebody wrote down, not in the order Tcl
# hashed.
set __i 0
foreach __net $ILA_RESOLVED {
    if {$__i > 0} { create_debug_port $ILA_CORE_NAME probe }
    set_property port_width 1 [get_debug_ports ${ILA_CORE_NAME}/probe$__i]
    set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports ${ILA_CORE_NAME}/probe$__i]
    connect_debug_port ${ILA_CORE_NAME}/probe$__i [get_nets $__net]
    incr __i
}
unset -nocomplain __i __net

# The hub. Its frequency is declared whether or not Vivado worked one out, and
# the divider is set when asked for - see section 4 for both.
if {[llength [get_debug_cores -quiet dbg_hub]]} {
    set_property C_CLK_INPUT_FREQ_HZ  $ILA_CLK_FREQ    [get_debug_cores dbg_hub]
    set_property C_ENABLE_CLK_DIVIDER $ILA_DBG_HUB_DIVIDER [get_debug_cores dbg_hub]
    connect_debug_port dbg_hub/clk [get_nets $ILA_CLK_NET]
    say "dbg_hub: clk=$ILA_CLK_NET freq=$ILA_CLK_FREQ divider=$ILA_DBG_HUB_DIVIDER"
} else {
    warn "no dbg_hub in the design yet - Vivado creates it during opt_design."
    warn "  Its clock and frequency must still be set, or the JTAG chain may"
    warn "  never reach the cores. If this stage inserts the ILA before"
    warn "  opt_design (which it should - see the header), set them again"
    warn "  afterwards."
}

lappend ILA_CORES $ILA_CORE_NAME
set ::ILA_ENABLED 1

warn "AN ILA IS IN THIS DESIGN. Its utilisation, placement and timing numbers"
warn "  are NOT the numbers for the image without it, in either direction. The"
warn "  manifest records ILA_ENABLE, so a comparison against an unprobed run"
warn "  can be refused rather than reported."

# THE LAST LINE. See the header.
set ::ILA_STEP_DONE 1

# Copyright (C) 2026, SoC Labs (www.soclabs.org)
