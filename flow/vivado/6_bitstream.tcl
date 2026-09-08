################################################################################
# flow/vivado/6_bitstream.tcl - a routed checkpoint in, a loadable image out
#
# Stage 6, the last of the graph in CONTRACT.md section 4. It produces, and is
# graded on:
#
#   $OUT_DIR/$BLOCK.bit               what a JTAG programmer loads
#   $OUT_DIR/$BLOCK.bin               what a RUNNING SYSTEM loads - and it is NOT
#                                     one format. See below.
#   $OUT_DIR/$BLOCK.xsa               what a software build reads to learn the
#                                     address map. Without it the firmware and
#                                     the fabric agree only by coincidence
#   $REPORT_DIR/bitstream_manifest.txt
#   $REPORT_DIR/bitstream_gate.txt
#
# and, when the image carries debug cores, $OUT_DIR/$BLOCK.ltx - without which
# the cores in the image cannot be labelled, triggered or decoded at all.
#
#
# BIN_STYLE IS NOT COSMETIC. CONTRACT.md section 9.5, measured:
# ===========================================================================
#   zynq7   the payload needs a BYTE SWAP
#   zynqmp  the .bit header must be STRIPPED
#
# THE CONVERSION SUCCEEDS EITHER WAY. THE FILE IS THE RIGHT SIZE EITHER WAY. The
# loader accepts it either way, and the device does not come up - with nothing
# anywhere in the chain saying why. That is why it is a REQUIRED board-pack key
# and why this stage reads it FROM THE BOARD PACK through the accessor shim
# rather than from a bare variable, and never infers it from the part string:
# guessing a boot format from a device name is the kind of inference that is
# right until the day a board boots the other way round.
#
# flow/steps/bitstream_opts.tcl validates the value (it refuses anything that is
# not one of the two) and publishes ::BITSTREAM_BIN_STYLE. This stage performs
# the conversion the style names and RECORDS WHICH ONE IT DID in the manifest,
# because from the file alone the two are indistinguishable.
#
#
# post_bitstream IS ONE SEAM TOO LATE, DELIBERATELY
# ===========================================================================
# CONTRACT.md section 6.1.3 keeps the reference toolkit's trap here on purpose:
# the .bit is already written when post_bitstream fires, so a hook there CANNOT
# change what ships. It is for publishing, recording and notifying. Every other
# post_ seam in this flow fires before its stage's writes; this one cannot,
# because the write IS the stage.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
################################################################################

source [file join $env(FPGA_FLOW_DIR) flow common flow_utils.tcl]

flow_config prefix BIT
flow_boot
flow_banner bitstream


################################################################################
# 1. KNOBS
################################################################################

opt BITSTREAM_ROUTED_DCP ""   ;# "" = the routed checkpoint from this run (or IN_RUN_TAG's)
opt BITSTREAM_WRITE_XSA   1   ;# 1 = write the .xsa hardware handoff
opt BITSTREAM_WRITE_HWH   1   ;# 1 = publish the .hwh beside it when the design has one
opt BITSTREAM_WRITE_LTX   1   ;# 1 = write the .ltx probe file when the image has debug cores
opt ALLOW_CRITICAL_WARNINGS [flow_env FPGA_ALLOW_CRITICAL_WARNINGS 0] ;# 1 = report critical warnings, do not gate
opt MSG_GATE_ALLOWLIST   [flow_env FPGA_MSG_GATE_ALLOWLIST ""]  ;# a TCL LIST of message ids

set DESIGN_NAME [flow_env FPGA_DESIGN_NAME $block_name]
set PLATFORM    [flow_env FPGA_PLATFORM bare]


################################################################################
# 2. THE MEASUREMENT BLOCK
#
# See 4_synth.tcl section 2. ci/assert-stage.sh reads bin_style and bit_bytes out
# of the manifest as top-level keys, and cross-checks bit_bytes against the file
# on disk - so these are appended as block 8 rather than emitted through prov_set,
# which would put a RESULT in the `prov.` identity namespace.
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
    puts $fh "# 8. measurements - what this stage measured, read back off disk."
    puts $fh "#    'unmeasured' is a count nobody took, not 0."
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
# CONTRACT.md section 3.5 gives SYNTH_OUT_DIR for reading another run's synthesis
# outputs and has NO equivalent for implementation's, so this stage derives one:
# IN_WORK_DIR names the run whose databases this stage reads, and that run's
# outputs directory is its sibling. On a normal run this resolves to OUT_DIR and
# nothing is derived at all. Recorded in the handover as a contract gap rather
# than papered over silently.
################################################################################

step "inputs"

if {$BITSTREAM_ROUTED_DCP eq ""} {
    set __dir $OUT_DIR
    if {[file normalize $IN_WORK_DIR] ne [file normalize $WORK_DIR]} {
        set __dir [file join [file dirname $IN_WORK_DIR] outputs]
        warn "IN_RUN_TAG differs from RUN_TAG, so the routed checkpoint is being"
        warn "  read from another run's outputs: $__dir"
        warn "  That is a legitimate thing to do and it is announced every time,"
        warn "  because a stale one and a deliberate one look identical."
    }
    set BITSTREAM_ROUTED_DCP [file join $__dir ${block_name}_routed.dcp]
    unset __dir
}

if {![file exists $BITSTREAM_ROUTED_DCP] || ![file size $BITSTREAM_ROUTED_DCP]} {
    stage_stop bitstream "no routed checkpoint to write a bitstream from" [list \
        "there is no routed checkpoint." \
        "  looked for: $BITSTREAM_ROUTED_DCP" \
        "  'make impl' writes it. route_design returns 0 on a route it did not" \
        "  finish, so an absent checkpoint here is often the first hard evidence:" \
        "    grep -nE '^ERROR|Placer could not|Router' \$LOG_DIR/impl.log" \
        "  A record of this refusal is in reports/bitstream_manifest.txt and" \
        "  reports/bitstream_gate.txt."]
}
flow_assert_input $BITSTREAM_ROUTED_DCP \
    "the routed checkpoint this stage writes a bitstream from. 'make impl' writes\
     it; route_design returns 0 on a route it did not finish, so a checkpoint that\
     is absent here is the first hard evidence of that" \
    IN_RUN_TAG

prov_pin routed_dcp $BITSTREAM_ROUTED_DCP "bitstream-read"
set ::PROV_FILES [list routed_dcp $BITSTREAM_ROUTED_DCP]

# THE FIRMWARE IS INSIDE THE BITSTREAM. FPGA_IMAGE_HEX is read at elaboration and
# baked into the memory initialisation, so a firmware change with no bitstream
# rebuild changes nothing on the board, and a rebuild against a stale hex ships
# the old image silently. The hash recorded here is the only thing that can pair
# the two afterwards - and it is hashed at THIS stage even though the image was
# baked in at synthesis, which the gate says in as many words.
set FW_HEX [flow_env FPGA_IMAGE_HEX]
if {$FW_HEX ne ""} {
    flow_assert_input $FW_HEX \
        "the memory image \$readmemh resolves to - it is baked into the bitstream\
         at elaboration, so the pair can only be checked afterwards by hash" \
        FPGA_IMAGE_HEX
    prov_pin fpga_image_hex $FW_HEX "bitstream-hash"
    lappend ::PROV_FILES fpga_image_hex $FW_HEX
}

step "open the routed checkpoint"
open_checkpoint $BITSTREAM_ROUTED_DCP
if {[catch {current_design} __d] || $__d eq ""} {
    die "open_checkpoint returned and there is no design in memory: $BITSTREAM_ROUTED_DCP"
}
unset -nocomplain __d


################################################################################
# 4. DEVICE CONFIGURATION AND THE BIN STYLE
#
# flow/steps/bitstream_opts.tcl owns CFGBVS/CONFIG_VOLTAGE (whose absence is DRC
# CFGBVS-1, a WARNING - the bitstream is written, the run exits 0, and the device
# configures unreliably or not at all), the unused-pin policy, compression, and
# the validation of bin_style. It refuses an unknown style outright.
################################################################################

flow_step bitstream_opts

if {![info exists ::BITSTREAM_OPTS_DONE] || !$::BITSTREAM_OPTS_DONE} {
    die "bitstream_opts did not finish: ::BITSTREAM_OPTS_DONE is not set." \
        "  flow/steps/bitstream_opts.tcl sets it on its last line and every" \
        "  override must too. Without it this stage cannot tell a configuration" \
        "  file that ran from one that returned early - and the properties it" \
        "  sets are the difference between a device that configures and one that" \
        "  does not."
}
foreach v {BITSTREAM_ARGS BITSTREAM_PROPS BITSTREAM_BIN_STYLE} {
    if {![info exists $v]} {
        die "bitstream_opts left no $v." \
            "  The stage calls 'write_bitstream {*}\$BITSTREAM_ARGS <file>' and" \
            "  records \$BITSTREAM_PROPS and \$BITSTREAM_BIN_STYLE in the manifest."
    }
}

# THE BOARD PACK IS THE OWNER, AND THE DIVERGENCE IS ANNOUNCED. bitstream_opts
# reads the pack through the shim and falls back to the exported BIN_STYLE only
# when the pack declares none; this block says which one was in force, because a
# project override of a board fact is legitimate and a stale one looks identical.
set __pack_style ""
if {[board_have bin_style]} { set __pack_style [string tolower [board bin_style]] }
set __env_style [string tolower [flow_env FPGA_BIN_STYLE]]
if {$__pack_style ne "" && $__env_style ne "" && $__pack_style ne $__env_style} {
    warn "BIN_STYLE OVERRIDE IS ACTIVE: the board pack says '$__pack_style' and the"
    warn "  project set BIN_STYLE='$__env_style'. bitstream_opts takes the PACK's."
    warn "  The two conversions are not interchangeable and the wrong one produces"
    warn "  a file of the right size that the device will not boot."
}
say "bin style: [expr {$BITSTREAM_BIN_STYLE eq {} ? {(none - no .bin will be written)} : $BITSTREAM_BIN_STYLE}]\
     (board pack: [expr {$__pack_style eq {} ? {(declares none)} : $__pack_style}])"


################################################################################
# 5. WRITE THE BITSTREAM
#
# write_bitstream RUNS DRC AS A PRECONDITION and reports a refusal as a DRC, not
# as an exit code: a design with unrouted nets or unconstrained IO stops here
# with a message in a log of hundreds. So the .bit is asserted on disk
# afterwards, and the DRC counter is read out of the tool.
#
# -bin_file (added by bitstream_opts when a style is known) makes Vivado write a
# <stem>.bin beside the .bit. THAT FILE IS THE HEADER-STRIPPED PAYLOAD, which is
# the zynqmp form; the zynq7 form is that payload with every 32-bit word byte
# swapped. Section 6 does the conversion and records which one happened.
################################################################################

set BIT [file join $OUT_DIR ${block_name}.bit]
set BIN [file join $OUT_DIR ${block_name}.bin]
set XSA [file join $OUT_DIR ${block_name}.xsa]
set LTX [file join $OUT_DIR ${block_name}.ltx]

step "write_bitstream"
say "args: [expr {[llength $BITSTREAM_ARGS] ? $BITSTREAM_ARGS : {(none)}}]"
write_bitstream {*}$BITSTREAM_ARGS $BIT

if {![file exists $BIT] || ![file size $BIT]} {
    die "write_bitstream returned and there is no bitstream at $BIT" \
        "  It refuses a design with unrouted nets or unconstrained IO and says so" \
        "  as a DRC, not as an exit code:" \
        "    grep -nE '^ERROR|DRC|write_bitstream' \$LOG_DIR/bitstream.log"
}
say "bitstream: $BIT ([file size $BIT] bytes)"

# THE PROBE FILE IS NOT OPTIONAL WHEN THERE ARE DEBUG CORES. The bitstream
# carries the cores; it does NOT carry the map from a probe index to the net it
# was attached to. Without the .ltx the board programs, the ILA appears, and the
# waveform is anonymous - which reads as a tool problem and is a missing file the
# build was always going to write.
set DEBUG_CORES 0
catch { set DEBUG_CORES [llength [get_debug_cores -quiet]] }
if {$DEBUG_CORES > 0 && $BITSTREAM_WRITE_LTX} {
    write_debug_probes -force $LTX
    say "probes: $LTX ($DEBUG_CORES debug core(s))"
} elseif {$DEBUG_CORES > 0} {
    warn "$DEBUG_CORES debug core(s) in this image and BITSTREAM_WRITE_LTX=0."
    warn "  The cores in the image cannot be labelled, triggered or decoded, and"
    warn "  nothing about the .bit says so."
}


################################################################################
# 6. THE .bin CONVERSION - THE ONE THAT SHIPS A DEAD BOARD
#
# Both styles start from the same payload: what `write_bitstream -bin_file` wrote
# beside the .bit, which is the .bit with its header removed.
#
#   zynqmp  that file IS the answer. Recorded as `header strip`.
#   zynq7   every 32-bit word is byte swapped. `binary scan I*` reads big-endian
#           words and `binary format i*` writes them little-endian, which is
#           exactly the swap - done in 1 MiB chunks so a 30 MB image does not
#           become 300 MB of Tcl list.
#
# THE RAW PAYLOAD IS KEPT in $WORK_DIR, so a board that will not boot can be
# retried against the other form without a rebuild, and so the two files can be
# diffed to prove the swap happened. A conversion that produced the right size
# and no evidence is how the wrong style survives a review.
################################################################################

proc bin_byteswap32 {src dst} {
    set in [open $src r]
    fconfigure $in -translation binary -encoding binary
    set out [open $dst w]
    fconfigure $out -translation binary -encoding binary
    set n 0
    while {1} {
        set chunk [read $in 1048576]
        if {[string length $chunk] == 0} { break }
        if {[string length $chunk] % 4} {
            close $in ; close $out
            error "payload is not a whole number of 32-bit words ([string length $chunk] left over)"
        }
        binary scan $chunk I* words
        puts -nonewline $out [binary format i* $words]
        incr n [string length $chunk]
    }
    close $in ; close $out
    return $n
}

set BIN_SOURCE "unmeasured"
set RAW_BIN [file join $WORK_DIR ${block_name}.payload.bin]

if {$BITSTREAM_BIN_STYLE eq ""} {
    warn "no bin_style, so NO .bin was written - only the .bit."
    warn "  bin_style is a REQUIRED board-pack key. mk/flow.mk asserts the .bin"
    warn "  exists, so this run will fail there, and that is the correct outcome:"
    warn "  a .bin nobody chose the conversion for is worse than no .bin."
    set BIN_SOURCE "none - bin_style is unset"
} elseif {![file exists $BIN] || ![file size $BIN]} {
    warn "bin_style is '$BITSTREAM_BIN_STYLE' and write_bitstream wrote no payload"
    warn "  at $BIN. -bin_file should have produced it beside the .bit."
    set BIN_SOURCE "UNVERIFIED:write_bitstream -bin_file produced no payload"
} else {
    step ".bin conversion ($BITSTREAM_BIN_STYLE)"
    file copy -force $BIN $RAW_BIN
    set raw_bytes [file size $RAW_BIN]
    switch -- $BITSTREAM_BIN_STYLE {
        zynqmp {
            # Already the answer. Nothing is copied over it, so the file the tool
            # wrote is the file that ships.
            set BIN_SOURCE "header strip (write_bitstream -bin_file), used as written"
            say "zynqmp: the -bin_file payload is the loadable form. $raw_bytes bytes"
        }
        zynq7 {
            set tmp [file join $WORK_DIR ${block_name}.bin.swap]
            set n [bin_byteswap32 $RAW_BIN $tmp]
            file rename -force $tmp $BIN
            set BIN_SOURCE "byte swap of every 32-bit word of the -bin_file payload"
            say "zynq7: byte-swapped $n bytes"
            # THE SWAP HAS TO HAVE HAPPENED. Same length, different content: a
            # copy that silently did not swap is the exact failure this stage
            # exists to prevent, and it is invisible in every other field.
            if {[file size $BIN] != $raw_bytes} {
                die "the byte-swapped .bin is [file size $BIN] bytes and the payload was\
                     $raw_bytes - a word-level swap cannot change the length."
            }
            set fa [open $RAW_BIN r] ; fconfigure $fa -translation binary -encoding binary
            set fb [open $BIN r]     ; fconfigure $fb -translation binary -encoding binary
            set a [read $fa 4096] ; set b [read $fb 4096]
            close $fa ; close $fb
            if {$a eq $b} {
                die "the .bin is byte-identical to the un-swapped payload over its first\
                     4 KiB, so the zynq7 conversion did not happen." \
                    "  A .bin of the right size and the wrong byte order loads, and the" \
                    "  device does not come up, and nothing in the chain says why."
            }
        }
        default {
            # Unreachable: bitstream_opts refuses any other value. Kept because
            # "unreachable" is a claim about a file this one does not own.
            set BIN_SOURCE "UNVERIFIED:unknown style '$BITSTREAM_BIN_STYLE'"
            warn "unknown bin_style '$BITSTREAM_BIN_STYLE' reached the stage."
        }
    }
}


################################################################################
# 7. THE HARDWARE HANDOFF
#
# The .xsa is what a software build reads to learn the address map. Without it
# the firmware and the fabric agree only by coincidence, which is why
# CONTRACT.md section 4 asserts it for EVERY bitstream.
#
# MEASURED ON THIS HOST, 2024.1: `write_hw_platform -fixed -force -include_bit`
# works on a routed checkpoint with no project and no block design - and on a
# design with no IPI block design it emits
#
#     CRITICAL WARNING: [Project 1-1924] Failed to write hardware handoff data
#
# and writes an .xsa with NO .hwh in it. The .xsa is still produced and is still
# what the tools want for a PL-only design; a PYNQ overlay, which needs the .hwh,
# is not. So the presence of the handoff is MEASURED and reported rather than
# assumed from the fact that the command returned - and when PLATFORM is pynq and
# there is no .hwh, that is a hard failure, because the overlay cannot load.
################################################################################

set XSA_WRITTEN 0
set HWH ""
if {$BITSTREAM_WRITE_XSA} {
    step "hardware handoff"
    if {[catch {write_hw_platform -fixed -force -include_bit $XSA} __e]} {
        warn "write_hw_platform failed: $__e"
        warn "  mk/flow.mk asserts the .xsa for every bitstream, so this run will"
        warn "  fail there. If this design genuinely cannot produce one, that is a"
        warn "  contract question - raise it, do not delete the test."
    }
    if {[file exists $XSA] && [file size $XSA]} {
        set XSA_WRITTEN 1
        say "handoff: $XSA ([file size $XSA] bytes)"
    }
    unset -nocomplain __e
}

# The .hwh, for a PYNQ overlay. It is generated by the BD, so it is looked for
# where the bd stage would have left it, and only then inside the .xsa - which is
# a zip, and `unzip` may not be on an EDA host, so that path is optional work and
# says so when it cannot run.
if {$BITSTREAM_WRITE_HWH} {
    foreach d [list $IN_WORK_DIR $WORK_DIR] {
        foreach f [glob -nocomplain -directory $d -types f *.hwh] { set HWH $f }
        foreach f [glob -nocomplain -directory $d -types f */*.hwh] { set HWH $f }
    }
    if {$HWH eq "" && $XSA_WRITTEN} {
        try_step "extract the .hwh from the .xsa" {
            exec unzip -o -j $XSA *.hwh -d $OUT_DIR
        }
        foreach f [glob -nocomplain -directory $OUT_DIR -types f *.hwh] { set HWH $f }
    }
    if {$HWH ne "" && [file dirname [file normalize $HWH]] ne [file normalize $OUT_DIR]} {
        file copy -force $HWH [file join $OUT_DIR ${DESIGN_NAME}.hwh]
        set HWH [file join $OUT_DIR ${DESIGN_NAME}.hwh]
    }
    if {$HWH ne ""} {
        say "hwh: $HWH ([file size $HWH] bytes)"
    } else {
        say "hwh: none in this design (there is no block design to generate one)"
    }
}


################################################################################
# 8. THE TERMINAL SEAM
#
# post_bitstream fires with everything already written. It CANNOT change what
# ships, and that is deliberate (CONTRACT.md section 6.1.3): it is the seam for
# publishing, recording and notifying - the deploy step lands after it, as a
# post-stage make target, where a busy board is fatal to the claim and not to the
# build.
################################################################################

flow_hook post_bitstream


################################################################################
# 9. MEASUREMENT
################################################################################

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

# `stage` is already in manifest block 1; ci_mf takes the first match.
stage_meas bin_style    [expr {$BITSTREAM_BIN_STYLE eq "" ? "" : $BITSTREAM_BIN_STYLE}]
stage_meas bin_source   $BIN_SOURCE
stage_meas bit_bytes    [expr {[file exists $BIT] ? [file size $BIT] : ""}]
stage_meas bin_bytes    [expr {[file exists $BIN] ? [file size $BIN] : ""}]
stage_meas payload_bytes [expr {[file exists $RAW_BIN] ? [file size $RAW_BIN] : ""}]
stage_meas xsa_bytes    [expr {[file exists $XSA] ? [file size $XSA] : ""}]
stage_meas hwh          [expr {$HWH ne "" ? [file tail $HWH] : ""}]
stage_meas ltx_bytes    [expr {[file exists $LTX] ? [file size $LTX] : ""}]
stage_meas debug_cores  $DEBUG_CORES
stage_meas platform     $PLATFORM
stage_meas bitstream_props [expr {[llength $BITSTREAM_PROPS] ? [join $BITSTREAM_PROPS { }] : "(none)"}]

# THE FIRMWARE HASH. ci/assert-stage.sh warns when it is absent, and it is right
# to: nothing else records which memory image is inside this bitstream, so the
# pair cannot be checked afterwards. `unmeasured` when no image is configured -
# which is a different statement from "the image is empty".
if {$FW_HEX ne ""} {
    stage_meas fpga_image_hex_sha256 [prov_sha256 [prov_resolve $FW_HEX]]
    stage_meas fpga_image_hex_bytes  [file size $FW_HEX]
} else {
    stage_meas fpga_image_hex_sha256 ""
    stage_meas fpga_image_hex_bytes  ""
}

foreach {__cw __ids __nfound} [msg_criticals] break
stage_meas critical_warnings    $__cw
stage_meas critical_warning_ids [expr {[llength $__ids] ? [join $__ids {,}] : "(none)"}]

foreach {k v} $::MEAS { say [format "  %-24s %s" $k $v] }


################################################################################
# 10. THE VERDICT
################################################################################

set HARD    {}
set BUDGETS {}
set OWNED   {}
set NOTCOV  {}

set __required [list $BIT "the bitstream a programmer loads"]
if {$BITSTREAM_WRITE_XSA} {
    lappend __required $XSA \
        "the hardware handoff a software build reads to learn the address map"
}
foreach {f what} $__required {
    if {![file exists $f]} {
        lappend HARD "no [file tail $f] at $f - $what"
    } elseif {![file size $f]} {
        lappend HARD "[file tail $f] is ZERO BYTES - $what. That is the shape a tool\
                      leaves when it opened its output and then died, and it\
                      satisfies every 'test -e' in the world"
    }
}
unset __required
if {$BITSTREAM_BIN_STYLE eq ""} {
    lappend HARD "no bin_style, so no .bin was written. It is a REQUIRED board-pack\
                  key and an unset one is not a default - it is a conversion nobody\
                  chose"
} elseif {![file exists $BIN] || ![file size $BIN]} {
    lappend HARD "no .bin at $BIN - the .bin is what a running system loads"
} elseif {![stage_meas_measured bin_source] || [string match "UNVERIFIED*" $BIN_SOURCE]} {
    lappend HARD "the .bin exists and nothing recorded which conversion produced it:\
                  $BIN_SOURCE"
}
if {$DEBUG_CORES > 0 && ![file exists $LTX]} {
    lappend HARD "$DEBUG_CORES debug core(s) are in this image and there is no .ltx at\
                  $LTX - the cores cannot be labelled, triggered or decoded, the board\
                  programs anyway, and the waveform is anonymous"
}
if {$PLATFORM eq "pynq" && $HWH eq ""} {
    lappend HARD "PLATFORM is pynq and this design produced no .hwh - a PYNQ overlay\
                  is the bitstream PLUS its .hwh, and the overlay cannot load without\
                  one. There is no block design in this run to generate it"
}

if {[stage_meas_measured critical_warnings] && $__cw > 0} {
    set __unexempt {}
    foreach id $__ids {
        if {[lsearch -exact $MSG_GATE_ALLOWLIST $id] < 0} { lappend __unexempt $id }
    }
    if {$ALLOW_CRITICAL_WARNINGS} {
        lappend OWNED "$__cw critical warning(s), owner=ALLOW_CRITICAL_WARNINGS=1 in\
                       design.mk: reported, not gated. ids: [join $__ids {, }]"
    } elseif {$__nfound == $__cw && ![llength $__unexempt] && [llength $__ids]} {
        lappend OWNED "$__cw critical warning(s), owner=MSG_GATE_ALLOWLIST: every id is\
                       allowlisted with a diagnosis in design.mk. ids: [join $__ids {, }]"
    } else {
        lappend BUDGETS "critical_warnings $__cw > budget 0 (ALLOW_CRITICAL_WARNINGS=0;\
                         ids not allowlisted: [expr {[llength $__unexempt] ? [join $__unexempt {, }] : {none readable in the stage log}}])"
    }
    unset __unexempt
}

lappend OWNED "which conversion this .bin needs, owner=the board pack's bin_style:\
               this run used '[stage_meas_get bin_style]' ([stage_meas_get bin_source]).\
               The other style produces a file of the same size that the device does\
               not boot, and nothing between here and the board detects it"
if {$FW_HEX ne ""} {
    lappend OWNED "which firmware image is inside this bitstream, owner=FPGA_IMAGE_HEX:\
                   sha256 [stage_meas_get fpga_image_hex_sha256] recorded at this\
                   stage. The image was baked in at ELABORATION, so this hash proves\
                   which file is on disk now, and the synth manifest is what proves\
                   which one was read"
}
if {$XSA_WRITTEN && $HWH eq ""} {
    lappend OWNED "the .xsa carries no hardware handoff (.hwh), owner=BD_TCL: this\
                   design has no IPI block design, so write_hw_platform wrote the\
                   platform without one and said so as a critical warning. A PL-only\
                   flow does not need it; a PYNQ overlay does"
}

lappend NOTCOV "whether this image CONFIGURES THE DEVICE. Nothing before the bench\
                loads it, and the two .bin styles are indistinguishable from the file"
lappend NOTCOV "whether the firmware and the fabric agree about SYS_CLK_FREQ_HZ. Both\
                are recorded in the manifest and nothing compares them at run time"
lappend NOTCOV "readback, essential-bits and SEU behaviour unless BITSTREAM_ESSENTIALBITS\
                was set - and even then the .ebd is written, not checked"
lappend NOTCOV "deployment. Programming a board is a post-stage target\
                (BITSTREAM_POST_TARGETS), and its failure is fatal to the claim, not\
                to this build"


set GATE [file join $REPORT_DIR bitstream_gate.txt]
write_gate $GATE bitstream $HARD $BUDGETS $OWNED $NOTCOV [list \
    "This gate is about FILES: that the image, its loadable .bin and the hardware" \
    "handoff exist, are not zero bytes, and that the .bin was converted the way" \
    "the board pack says this family needs. It is NOT a statement that the device" \
    "configures - the two .bin styles produce files of the same size and the wrong" \
    "one simply does not come up - and it is NOT a statement about the design," \
    "which the impl gate graded."]

say "verdict: $GATE"


################################################################################
# 11. THE MANIFEST, LAST
################################################################################

set MANIFEST [prov_manifest bitstream]
stage_meas_append $MANIFEST

if {![file exists $MANIFEST] || ![file size $MANIFEST]} {
    die "the manifest at $MANIFEST was not written."
}

step "bitstream summary"
say "bitstream: $BIT"
say ".bin     : [expr {[file exists $BIN] ? $BIN : {(none)}}]  style=[stage_meas_get bin_style]"
say "handoff  : [expr {[file exists $XSA] ? $XSA : {(none)}}]"
say "verdict  : $GATE"
say "manifest : $MANIFEST"

if {[llength $HARD]} {
    foreach h $HARD { puts "BIT-FAIL: $h" }
    die "[llength $HARD] hard failure(s) - see $GATE"
}
if {[llength $BUDGETS]} {
    foreach b $BUDGETS { puts "BIT-FAIL: budget exceeded: $b" }
    die "[llength $BUDGETS] budget(s) exceeded - see $GATE"
}
say "bitstream OK"

# Copyright (C) 2026, SoC Labs (www.soclabs.org)
