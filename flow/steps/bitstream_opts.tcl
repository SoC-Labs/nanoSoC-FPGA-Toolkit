################################################################################
# steps/bitstream_opts.tcl - device configuration properties for write_bitstream
#
# Sourced by flow/vivado/6_bitstream.tcl via `flow_step bitstream_opts`, on the
# ROUTED design and BEFORE write_bitstream. A project replaces it wholesale with
# $(OVERRIDES_DIR)/bitstream_opts.tcl.
#
#
# IF YOU OVERRIDE THIS FILE, KEEP SECTION 1.
# ===========================================================================
# An override MUST still do all four of these:
#
#   1. SET CFGBVS AND CONFIG_VOLTAGE. Section 1 is the whole reason this file is
#      a step of its own. Omitting them produces a bitstream that Vivado writes
#      without complaint and that a device may refuse to configure from.
#
#   2. STATE THE .bin CONVERSION STYLE. Zynq-7000 and ZynqMP are not
#      interchangeable and the wrong one corrupts the load (CONTRACT.md section
#      9.5). This file validates the board pack's `bin_style` and publishes it;
#      an override that skips the validation ships a .bin nobody can boot.
#
#   3. LEAVE ::BITSTREAM_PROPS AND ::BITSTREAM_ARGS SET, and end with
#      `set ::BITSTREAM_OPTS_DONE 1`.
#
#   4. NOT WAIVE A write_bitstream DRC. If a DRC has to be waived, it is waived
#      in the project's XDC_POST_ROUTE file, where the waiver is a reviewable
#      artefact with an owner - not buried in a strategy file where the next
#      reader will take it for a tool default.
#
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
################################################################################

set BITSTREAM_PROPS {}
set BITSTREAM_ARGS  {}

# File-local. Records the property in ::BITSTREAM_PROPS (so the manifest carries
# what was set, whether or not a design was open) AND applies it when there is a
# design to apply it to - so this file loads under a bare tclsh for the knob
# census. An override that does not want it can drop it; nothing outside this
# file calls it.
proc _bitopt {name value} {
    lappend ::BITSTREAM_PROPS $name $value
    if {[flow_have current_design]} {
        if {[catch {set_property $name $value [current_design]} __e]} {
            warn "set_property $name $value failed: $__e"
            return 0
        }
    }
    say [format "  %-42s %s" $name $value]
    return 1
}


################################################################################
# 1. CFGBVS AND CONFIG_VOLTAGE - THE ONE LINE WHOSE OMISSION SHIPS A DEAD BOARD
#
# THIS IS THE LOAD-BEARING SECTION OF THE FILE.
#
# `write_bitstream` runs a design-rule check called CFGBVS-1, "Missing CFGBVS and
# CONFIG_VOLTAGE Design Properties". It is a WARNING. The bitstream is written.
# The run exits 0. Every artefact this flow asserts on exists and looks right.
#
# What the two properties do is tell the tool the voltage of the configuration
# bank, which decides the I/O standard the tool applies to the dedicated config
# pins and the drive settings baked into the bitstream. With them unset the tool
# assumes, and when the assumption is wrong the device either does not configure
# at all or configures unreliably - a failure that appears at the board, hours
# later, with nothing in the build log pointing at it. A warning in a
# write_bitstream log is not something anyone reads: there are hundreds.
#
# WHO OWNS THESE TWO VALUES IS AN OPEN QUESTION IN THE CONTRACT, and this file
# is where it surfaces, so it is written down rather than resolved by a guess:
#
#   * CONTRACT.md section 8 lists `cfgbvs` and `config_voltage` under the PART
#     pack's other keys.
#   * Every part pack this toolkit ships declines to set them, and gives the
#     right reason: they follow how the configuration bank is WIRED ON THE
#     BOARD. A device that supports both a 3.3 V and a 1.8 V bank-0 supply
#     cannot say which one is in front of you, and a part pack asserting one
#     would be asserting something it cannot know.
#   * The BOARD pack schema has no such key, so a project cannot state them
#     there either - an unknown key in a pack is an error, by design.
#
# So today nothing can state them, and the DRC they satisfy is a warning. That
# is a gap with a real consequence, not a formality, so this file resolves it in
# the only way that keeps the value visible: board pack first (it is a board
# fact), part pack second (in case a device really does fix it), and two knobs
# last - registered with `opt`, so whatever a project sets lands in the manifest
# and can be diffed between runs.
#
# If NOTHING states them, this stops. A bitstream nobody can trust is worse than
# no bitstream, because every artefact assertion in this flow passes on both.
################################################################################

opt BITSTREAM_CFGBVS          ""   ;# VCCO | GND. A BOARD fact: how the config bank is wired
opt BITSTREAM_CONFIG_VOLTAGE  ""   ;# volts, e.g. 3.3 or 1.8. A BOARD fact, see BITSTREAM_CFGBVS

step "device configuration"

set __cfgbvs  $BITSTREAM_CFGBVS
set __cfgvolt $BITSTREAM_CONFIG_VOLTAGE
if {$__cfgbvs  eq "" && [board_have cfgbvs]}          { set __cfgbvs  [board cfgbvs] }
if {$__cfgvolt eq "" && [board_have config_voltage]}  { set __cfgvolt [board config_voltage] }
if {$__cfgbvs  eq "" && [part_have  cfgbvs]}          { set __cfgbvs  [part  cfgbvs] }
if {$__cfgvolt eq "" && [part_have  config_voltage]}  { set __cfgvolt [part  config_voltage] }

if {$__cfgbvs ne "" && $__cfgvolt ne ""} {
    _bitopt CFGBVS         $__cfgbvs
    _bitopt CONFIG_VOLTAGE $__cfgvolt
} else {
    die "nothing states cfgbvs and config_voltage." \
        "  cfgbvs         = [expr {$__cfgbvs  eq {} ? {(unset)} : $__cfgbvs}]" \
        "  config_voltage = [expr {$__cfgvolt eq {} ? {(unset)} : $__cfgvolt}]" \
        "  write_bitstream reports their absence as DRC CFGBVS-1, which is a" \
        "  WARNING: the bitstream is written, the run exits 0, and every" \
        "  artefact this flow asserts on exists. The tool then assumes the" \
        "  configuration bank's voltage, and when the assumption is wrong the" \
        "  device configures unreliably or not at all - at the board, hours" \
        "  later, with nothing in the log pointing here." \
        "  They describe how the configuration bank is WIRED, so the board pack" \
        "  is the right owner - but its schema has no such key today, and the" \
        "  part packs decline to state them for exactly this reason. Until that" \
        "  is settled in CONTRACT.md section 8, set them per project:" \
        "      BITSTREAM_CFGBVS         = VCCO   (or GND)" \
        "      BITSTREAM_CONFIG_VOLTAGE = 3.3    (or whatever bank 0 runs at)" \
        "  Both are registered knobs, so the values land in the manifest."
}
unset -nocomplain __cfgbvs __cfgvolt


################################################################################
# 2. UNUSED PINS
#
# Vivado's default for an unused I/O is a PULL-UP. On a board where an unused
# device pin is externally driven low, or tied to a rail, that is a contention
# path the bitstream creates and nothing in the build can see: it is a property
# of the PCB, and the PCB is not an input to synthesis.
#
# `Pullnone` is the default here because it cannot create contention anywhere,
# and because an input that needs a defined level should get it from the board
# or from an explicit constraint, where it is visible. A project that wants the
# pull-up sets the knob, and the value lands in the manifest.
################################################################################

opt BITSTREAM_UNUSEDPIN  Pullnone   ;# Pullnone | Pullup | Pulldown. Vivado's own default is Pullup

_bitopt BITSTREAM.CONFIG.UNUSEDPIN $BITSTREAM_UNUSEDPIN


################################################################################
# 3. COMPRESSION AND CONFIGURATION TIMING
#
# Compression is a fact about the device (some families do not implement it) and
# a preference about load time, so the pack states whether it is available and
# the knob decides whether to use it.
#
# CONFIGRATE and SPI_BUSWIDTH matter only for a device that boots itself from
# flash, and both are board facts: the rate the board's flash can sustain and how
# many data lines are wired. A rate the flash cannot keep up with produces a
# device that configures intermittently - a failure that looks like a marginal
# power supply. Both default to unset, and unset means "leave Vivado's default",
# which is the slow, safe one.
################################################################################

opt BITSTREAM_COMPRESS     1    ;# 1 = compress. Smaller image, faster load
opt BITSTREAM_CONFIGRATE   ""   ;# MHz, for a flash boot. "" = the tool's slow default
opt BITSTREAM_SPI_BUSWIDTH ""   ;# 1 | 2 | 4 | 8, for a flash boot. "" = the tool's default

if {$BITSTREAM_COMPRESS} {
    if {[part_have bitstream_compress] && ![part bitstream_compress]} {
        warn "BITSTREAM_COMPRESS=1 but the part pack says this device does not"
        warn "  implement bitstream compression. The property is being set"
        warn "  anyway so the disagreement is visible in the log and in the"
        warn "  manifest rather than resolved silently by one of us."
    }
    _bitopt BITSTREAM.GENERAL.COMPRESS TRUE
}
if {$BITSTREAM_CONFIGRATE ne ""}   { _bitopt BITSTREAM.CONFIG.CONFIGRATE   $BITSTREAM_CONFIGRATE }
if {$BITSTREAM_SPI_BUSWIDTH ne ""} { _bitopt BITSTREAM.CONFIG.SPI_BUSWIDTH $BITSTREAM_SPI_BUSWIDTH }


################################################################################
# 4. OPTIONAL DEVICE FEATURES
#
# Both off by default and both are real changes to what the device does after
# configuration, which is why neither is inherited quietly.
#
# ESSENTIALBITS writes the .ebd file an SEU mitigation scheme needs. It costs
# nothing at run time and produces an extra artefact, so it is off unless asked
# for rather than on "in case".
#
# OVERTEMPSHUTDOWN makes the device power itself down on an over-temperature
# alarm. That is the right behaviour for a board in a rack and the wrong
# behaviour for a board on a bench with a probe on it, because the failure mode
# is a device that vanishes mid-capture and looks like a link fault.
################################################################################

opt BITSTREAM_ESSENTIALBITS    0   ;# 1 = also write the .ebd essential-bits file
opt BITSTREAM_OVERTEMPSHUTDOWN 0   ;# 1 = device powers down on over-temperature

if {$BITSTREAM_ESSENTIALBITS}    { _bitopt BITSTREAM.SEU.ESSENTIALBITS       YES }
if {$BITSTREAM_OVERTEMPSHUTDOWN} { _bitopt BITSTREAM.CONFIG.OVERTEMPSHUTDOWN ENABLE }


################################################################################
# 5. THE .bin, AND WHY THE STYLE IS VALIDATED HERE
#
# A `.bin` is not one format. Converting a `.bit` for a Zynq-7000 style loader
# needs a byte swap; converting one for a ZynqMP style loader needs the header
# stripped. INTERCHANGING THEM CORRUPTS THE LOAD (CONTRACT.md section 9.5), and
# the corruption is not detected by anything on the way: the file has the right
# size, the right name and a plausible first block, and the device simply does
# not come up.
#
# `bin_style` is therefore a REQUIRED board-pack key, and this file refuses an
# unknown value rather than letting the stage pick one. A default here would be a
# guess about somebody's board, made in a repository that is not allowed to know
# what board it is.
################################################################################

set BITSTREAM_BIN_STYLE ""
if {[board_have bin_style]} {
    set BITSTREAM_BIN_STYLE [string tolower [board bin_style]]
} else {
    set BITSTREAM_BIN_STYLE [string tolower [flow_env FPGA_BIN_STYLE]]
}
if {$BITSTREAM_BIN_STYLE eq ""} {
    warn "no bin_style: no .bin will be produced, only the .bit."
    warn "  bin_style is a REQUIRED board-pack key. A .bin for one loader"
    warn "  family loaded by another is corrupt in a way nothing detects - the"
    warn "  file is the right size, has a plausible first block, and the device"
    warn "  does not come up."
} elseif {[lsearch -exact {zynq7 zynqmp} $BITSTREAM_BIN_STYLE] < 0} {
    flow_refuse "bin_style is '$BITSTREAM_BIN_STYLE', which this flow does not implement." \
        "  Known styles: zynq7 (byte swap) and zynqmp (header strip)." \
        "  These are NOT interchangeable: the wrong conversion produces a file" \
        "  of the right size and name that the device will not boot, and" \
        "  nothing between here and the board detects it. Add the style to the" \
        "  bitstream stage deliberately rather than defaulting to one of these."
} else {
    say "bin style: $BITSTREAM_BIN_STYLE"
}


################################################################################
# 6. WHAT write_bitstream ITSELF IS CALLED WITH
#
# -force so a re-run overwrites rather than failing on an artefact this same flow
# wrote, and -bin_file only when a style is known - see section 5.
#
# THE PROBE FILE IS NOT OPTIONAL WHEN THERE ARE DEBUG CORES. It is written by the
# bitstream stage, from ila.tcl's declaration, and without it the debug cores in
# the image cannot be used at all. See flow/steps/ila.tcl section 3.
################################################################################

opt BITSTREAM_FORCE  1   ;# 1 = -force, overwrite an existing .bit from this same flow

if {$BITSTREAM_FORCE} { lappend BITSTREAM_ARGS -force }
if {$BITSTREAM_BIN_STYLE ne ""} { lappend BITSTREAM_ARGS -bin_file }

say "write_bitstream args: [expr {[llength $BITSTREAM_ARGS] ? $BITSTREAM_ARGS : {(none)}}]"
say "properties set: [expr {[llength $BITSTREAM_PROPS] / 2}]"

# THE LAST LINE. See the header.
set ::BITSTREAM_OPTS_DONE 1

# Copyright (C) 2026, SoC Labs (www.soclabs.org)
