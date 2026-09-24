#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# t_bitstream.sh - flow/vivado/6_bitstream.tcl: THE STAGE THAT SHIPS
#
# DEFECT CLASS: A RECORD THAT DESCRIBES A DEVICE IT DID NOT BUILD.
#
# The bitstream stage is the one whose output leaves the building. Everything
# before it hands a file to the next stage; this one hands a file to a board,
# and the manifest beside it is the only thing that will ever say what is in
# that file. So every property here is about the record agreeing with the
# artefact - and every way they can disagree is silent, because the artefact is
# binary and the record is prose.
#
# THE ONE WITH A MEASURED FAILURE BEHIND IT: a legacy flow in the reference
# project wrote `"usr_access": "0xdf2b43ed"` into a manifest for a bitstream
# whose build log said `NOT stamping a commit SHA`, because the tree was dirty.
# The stamp code and the manifest code were two files: the stamper correctly
# declined a dirty tree, and the manifest writer stripped the `-dirty` suffix
# and COMPUTED the field from the sha anyway. A value that looks like evidence
# and is arithmetic. Every dirty build carried a register value that was never
# written into the device, and the bench's provenance check read it and passed.
#
# The honest shape is a disjunction, and it is asserted exactly that way:
# either the stage stamped and the manifest carries WHAT REACHED THE TOOL, or
# the manifest says it did not stamp AND WHY. Never a value that did not reach
# set_property. The assertion is a KNOWN DEFECT today - see section 5 for what
# the stage actually does - and it is proved from both sides: two honest
# mutants pass it, two dishonest ones (one of them the legacy shape, verbatim)
# are rejected.
#
# THREE THINGS THIS SUITE FOUND, all carried as KNOWN DEFECTS because it does
# not own the stage, and all of one class - A HAZARD THE CODE DOCUMENTS AND
# THEN DOES NOT CHECK:
#
#   bit.usr_access.honest      the stage neither stamps USR_ACCESS nor records
#                              that it did not. It does NOT fabricate - the
#                              dangerous half of the legacy failure is absent -
#                              but silence is not the other half of the
#                              disjunction either. Section 5.
#   bit.input.stale_dcp        impl records dcp_bytes so the checkpoint can be
#                              paired with the run that made it; this stage
#                              reads the checkpoint and never the record, so a
#                              routed checkpoint from another run is opened and
#                              shipped. Section 7.
#   bit.override.config_bank   flow/steps/bitstream_opts.tcl tells an override
#                              in capitals that it MUST keep the CFGBVS /
#                              CONFIG_VOLTAGE section; the stage's acceptance
#                              test is BITSTREAM_OPTS_DONE and three variable
#                              NAMES, so an override that drops it is accepted
#                              in silence. Section 9.
#
# Each has a CONTROL beside it - a mutant that implements the missing check -
# so the assertion is shown satisfiable rather than merely failing today.
#
#
# HOW A VIVADO STAGE RUNS WITH NO VIVADO. The stage script is sourced UNMODIFIED
# under bare tclsh, after the driver has defined RECORDING STUBS for the seven
# tool commands it calls - open_checkpoint, current_design, set_property,
# get_debug_cores, write_debug_probes, write_bitstream, write_hw_platform. Each
# stub appends what it was told to a log file AS IT IS CALLED, so the order and
# the arguments survive whatever the stage does next, including `die`. The two
# tool commands the stage reaches through provenance.tcl (get_msg_config and
# version) are guarded there and are simply absent, which is the tclsh case
# provenance.tcl documents. Nothing about the file under test is stubbed:
# flow_boot, the real part pack, a fixture board pack, bitstream_opts.tcl, the
# .bin conversion, the gate and the manifest all run as they would in the tool.
#
# EVERY PATH COMES FROM make. The fixture project is a real three-line entry
# contract and `make` is asked for OUT_DIR, REPORT_DIR, BOARD_DIR, HOOKS_DIR and
# the rest - the same way ci/assert-stage.sh asks - so these assertions look
# where the flow puts things and not where this file believes it does.
#
# THE STUB LOG IS THE POINT, and it is what makes several assertions possible at
# all: "the knob reached the tool" and "the manifest records what the tool was
# told" are questions about a set_property call, and only something standing
# where the tool stands can answer them.
#
# WHAT THE STUBS CANNOT PROVE, said plainly: that write_bitstream accepts the
# properties, that the .bit is loadable, that the device configures, that the
# .xsa is a zip, that unzip finds a .hwh in it. Every stub here writes a small
# deterministic file where the tool would write a real one. The .bin conversion
# IS real - it is the stage's own Tcl over the stub's payload - and the byte
# order is checked from the shell.
#
# `die` EXITS THE INTERPRETER, so nothing here catches it: the driver's exit
# status is read from the shell, and the artefacts are read from disk.
#
# Every assertion is PAIRED WITH A MUTATION PROOF, planted with t_replace_line
# and t_mutate so that an edit which changed nothing is a LOUD failure. One
# fault per copy. A fault that could not be planted is a SKIP WITH THE REASON.
#
# AND EVERY PROOF GOES THROUGH bit_proof, which is this file's own answer to a
# hole it fell into first. t_check_fail accepts ANY non-zero exit, so a mutant
# that broke the stage for an unrelated reason satisfies its proof while
# proving nothing - and one here did exactly that, a Tcl line-continuation
# eaten by the sed that planted it, reported as a green `ok` on a stage that
# died at `invalid command name` before reaching the code under test. A proof
# is now valid only when the predicate fails AND the stage did not merely
# crash; section 0 proves that guard can itself go red.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/lib/harness.sh
. "$HERE/../lib/harness.sh"

t_sandbox; SB="$T_SANDBOX"

#-----------------------------------------------------------------------------
# PRECONDITIONS. Each is a SKIP WITH THE REASON, never a pass.
#-----------------------------------------------------------------------------
ST_REL="flow/vivado/6_bitstream.tcl"
OP_REL="flow/steps/bitstream_opts.tcl"
if [ ! -f "$FLOW_DIR/$ST_REL" ]; then
    t_skip bit.all "no $ST_REL - nothing to test, and an absent stage is not a passing one"
    t_summary; exit $?
fi
if [ ! -f "$FLOW_DIR/$OP_REL" ]; then
    t_skip bit.all "no $OP_REL - the stage sources it through flow_step and dies without it, so nothing below would measure the stage"
    t_summary; exit $?
fi
for _t in tclsh make sha256sum; do
    if ! command -v "$_t" >/dev/null 2>&1; then
        t_skip bit.all "no $_t on PATH - tclsh runs the stage, make resolves every path, sha256sum is what provenance.tcl hashes with; without any one of them nothing here measures the stage"
        t_summary; exit $?
    fi
done
unset _t

# The part pack the fixture board names. ANY shipped pack will do - the stage's
# behaviour under test does not depend on the device - so it is the first one
# the directory lists rather than a name written here. Per toolkit copy,
# because a mutant's part/ is its own.
first_part() { local d; for d in "$1"/part/*/; do [ -f "$d/part.tcl" ] && { basename "$d"; return 0; }; done; return 1; }
if ! PART_NAME="$(first_part "$FLOW_DIR")"; then
    t_skip bit.all "no part pack under $FLOW_DIR/part - flow_boot cannot load one, so the stage cannot boot"
    t_summary; exit $?
fi

# git is OPTIONAL: the fixture project is a dirty git repository when it can
# be, because the recorded usr_access failure keyed on the `-dirty` suffix, and
# the mutant that reproduces it needs a sha to do arithmetic on. Every
# assertion runs without git; one proof skips.
GIT_OK=0
command -v git >/dev/null 2>&1 && GIT_OK=1
gitq() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git "$@"; }

#=============================================================================
# THE DRIVER
#
# Recording stubs, then the stage, unmodified. The stubs DECIDE NOTHING: they
# write what a tool would write - a fixed 48-byte .bit whose last 16 bytes are
# the payload, the same payload as the .bin when -bin_file was asked for - and
# they append every call to $T_STUB_LOG as it happens. What they write is
# steered by three env variables the predicates set:
#
#   T_BIT_MODE     normal | absent | zero | nobin | zerobin   what write_bitstream leaves
#   T_XSA_MODE     normal | absent | zero                     what write_hw_platform leaves
#   T_DEBUG_CORES  n                                          what get_debug_cores reports
#
# THE PAYLOAD IS 01 02 03 .. 10, sixteen bytes: four 32-bit words with no
# symmetry, so a byte swap changes every byte and a swap that did not happen is
# visible from `od`. That is the property section 3 reads off disk.
#=============================================================================
cat > "$SB/bit_drive.tcl" <<'TCL'
set tk [lindex $::argv 0]
set ::stublog $::env(T_STUB_LOG)
proc t_rec {args} { set fh [open $::stublog a]; puts $fh [join $args " "]; close $fh }
proc t_bytes {path data} {
    set fh [open $path w]; fconfigure $fh -translation binary; puts -nonewline $fh $data; close $fh
}
proc t_mode {var} { return [expr {[info exists ::env($var)] && $::env($var) ne "" ? $::env($var) : "normal"}] }
set ::payload [binary format c* {1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16}]
set ::header  [string repeat H 32]

proc open_checkpoint {path} { t_rec open_checkpoint $path }
proc current_design  {}     { return design_1 }
proc set_property    {args} { t_rec set_property {*}$args }
proc get_debug_cores {args} {
    set n [t_mode T_DEBUG_CORES]; if {$n eq "normal"} { set n 0 }
    set l {}; for {set i 0} {$i < $n} {incr i} { lappend l u_ila_$i }
    return $l
}
proc write_debug_probes {args} { t_rec write_debug_probes {*}$args; t_bytes [lindex $args end] "probes" }
proc write_bitstream {args} {
    set bit [lindex $args end]
    set bin [file rootname $bit].bin
    t_rec write_bitstream {*}$args
    switch -- [t_mode T_BIT_MODE] {
        absent  { }
        zero    { t_bytes $bit "" }
        nobin   { t_bytes $bit "$::header$::payload" }
        zerobin { t_bytes $bit "$::header$::payload"; t_bytes $bin "" }
        default {
            t_bytes $bit "$::header$::payload"
            if {[lsearch -exact $args -bin_file] >= 0} { t_bytes $bin $::payload }
        }
    }
}
proc write_hw_platform {args} {
    set xsa [lindex $args end]
    t_rec write_hw_platform {*}$args
    switch -- [t_mode T_XSA_MODE] {
        absent  { }
        zero    { t_bytes $xsa "" }
        default { t_bytes $xsa "a stand-in for the hardware handoff archive" }
    }
}
source [file join $tk flow vivado 6_bitstream.tcl]
TCL

# Expected .bin bytes, as `od -An -tx1 -v` prints them, one space-separated
# line. The zynq7 form is every 32-bit word of the payload byte-swapped.
PAYLOAD_HEX="01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10"
SWAPPED_HEX="04 03 02 01 08 07 06 05 0c 0b 0a 09 10 0f 0e 0d"
hex_of() { od -An -tx1 -v "$1" | tr -s ' \n' ' ' | sed 's/^ //; s/ $//'; }

#=============================================================================
# THE FIXTURE PROJECT, AND THE RUN
#
# bit_run <toolkit> <label> [bin_style] [VAR=value ...]
#
# One project per run, so that a mutant's paths come from make asked about
# THAT toolkit. The project is the three-line entry contract plus PART (a
# project override CONTRACT.md section 3.2 allows, and the only way make can
# resolve PART_DIR without reading Tcl). make is then asked for every path the
# stage is given - the same values mk/flow.mk would export - and the fixture is
# written where make said: the board pack in BOARD_DIR, the hook in HOOKS_DIR,
# the routed checkpoint in OUT_DIR, the .hwh in WORK_DIR, the log in LOG_DIR.
#
# Fixture controls, read from the trailing VAR=value arguments (which are also
# exported to the driver, so one list steers both halves):
#
#   T_DCP_MODE=absent|zero      no routed checkpoint / a zero-byte one
#   T_HWH=0                     no .hwh in the work directory
#   T_IMPL_DCP_BYTES=<n>        plant an impl_manifest.txt recording dcp_bytes n
#   FPGA_PLATFORM, FPGA_BIN_STYLE, BITSTREAM_*, T_BIT_MODE, T_XSA_MODE, T_DEBUG_CORES
#
# The exit status of the driver is left in BR_RC and NOT graded here: several
# predicates below assert that the stage REFUSES, and a runner that failed on a
# refusal would make those unassertable. BR_OUT is the captured stdout, BR_STUB
# the stub log, BR_MAN and BR_GATE the manifest and gate paths make implies.
#
# THE LABEL NAMES THE RUN DIRECTORY AND IS DELIBERATELY REUSED: a predicate
# driven against the real toolkit and then against four mutants writes
# $SB/r-<label> five times, wiped by the `rm -rf` below each time, which keeps
# the sandbox small and each run honest. The consequence matters only under
# T_KEEP=1: what survives in r-<label> is the LAST toolkit that ran there,
# which is a mutant whenever the label has a proof behind it.
#=============================================================================
BR_RC=0; BR_OUT=""; BR_STUB=""; BR_MAN=""; BR_GATE=""
BR_OUTDIR=""; BR_WORKDIR=""; BR_REPDIR=""; BR_LOGDIR=""; BR_RUNDIR=""
BR_BLOCK=""; BR_DESIGN=""; BR_FPGA=""; BR_ROOT=""

## mk_paths <fpga dir> - one make call, every path, as KEY=VALUE lines
mk_paths() {
    make -C "$1" --no-print-directory --eval='t_paths: ; @printf "%s\n" "BLOCK=$(BLOCK)" "DESIGN_NAME=$(DESIGN_NAME)" "PLATFORM=$(PLATFORM)" "RUN_TAG=$(RUN_TAG)" "RUN_DIR=$(RUN_DIR)" "WORK_DIR=$(WORK_DIR)" "LOG_DIR=$(LOG_DIR)" "REPORT_DIR=$(REPORT_DIR)" "OUT_DIR=$(OUT_DIR)" "IN_WORK_DIR=$(IN_WORK_DIR)" "PART_DIR=$(PART_DIR)" "BOARD_DIR=$(BOARD_DIR)" "HOOKS_DIR=$(HOOKS_DIR)" "OVERRIDES_DIR=$(OVERRIDES_DIR)" "PROJECT_ROOT=$(PROJECT_ROOT)"' t_paths 2>&1
}

bit_run() {
    local tk="$1" label="$2" style="${3:-zynqmp}"; shift 3 2>/dev/null || shift $#
    local root="$SB/r-$label" fpga kv key val paths part
    local dcp_mode=normal hwh=1 impl_bytes="" ovr_opts=0 stale_xsa=0 extra=()
    for kv in "$@"; do
        case "$kv" in
            T_DCP_MODE=*)       dcp_mode="${kv#*=}" ;;
            T_HWH=*)            hwh="${kv#*=}" ;;
            T_IMPL_DCP_BYTES=*) impl_bytes="${kv#*=}" ;;
            T_OVERRIDE_OPTS=*)  ovr_opts="${kv#*=}" ;;
            T_STALE_XSA=*)      stale_xsa="${kv#*=}" ;;
        esac
        extra+=("$kv")
    done
    part="$(first_part "$tk")" || { printf 'no part pack under %s/part\n' "$tk"; return 1; }

    rm -rf "$root"; mkdir -p "$root/proj/fpga" || return 1
    fpga="$root/proj/fpga"
    # The entry contract, spelled with the literal include path for the reason
    # t_project gives; PART is the one addition, see above.
    cat > "$fpga/Makefile" <<EOF
FPGA_DIR := \$(CURDIR)
include \$(FPGA_DIR)/design.mk
EOF
    cat > "$fpga/design.mk" <<EOF
FPGA_FLOW_DIR := $tk
BLOCK := demo_block
BOARD := demo_board
PART := $part
include $tk/mk/flow.mk
EOF
    paths="$(mk_paths "$fpga")" || { printf 'make could not resolve the paths:\n%s\n' "$paths"; return 1; }
    BR_BLOCK=""; BR_DESIGN=""; BR_OUTDIR=""; BR_WORKDIR=""; BR_REPDIR=""; BR_LOGDIR=""; BR_RUNDIR=""
    local platform run_tag in_work part_dir board_dir hooks_dir ovr_dir
    while IFS='=' read -r key val; do
        case "$key" in
            BLOCK)         BR_BLOCK="$val" ;;
            DESIGN_NAME)   BR_DESIGN="$val" ;;
            PLATFORM)      platform="$val" ;;
            RUN_TAG)       run_tag="$val" ;;
            RUN_DIR)       BR_RUNDIR="$val" ;;
            WORK_DIR)      BR_WORKDIR="$val" ;;
            LOG_DIR)       BR_LOGDIR="$val" ;;
            REPORT_DIR)    BR_REPDIR="$val" ;;
            OUT_DIR)       BR_OUTDIR="$val" ;;
            IN_WORK_DIR)   in_work="$val" ;;
            PART_DIR)      part_dir="$val" ;;
            BOARD_DIR)     board_dir="$val" ;;
            HOOKS_DIR)     hooks_dir="$val" ;;
            OVERRIDES_DIR) ovr_dir="$val" ;;
            PROJECT_ROOT)  BR_ROOT="$val" ;;
        esac
    done <<< "$paths"
    for key in BR_BLOCK BR_OUTDIR BR_WORKDIR BR_REPDIR BR_LOGDIR BR_RUNDIR part_dir board_dir hooks_dir; do
        [ -n "${!key}" ] || { printf 'make did not resolve %s:\n%s\n' "$key" "$paths"; return 1; }
    done
    BR_FPGA="$fpga"

    # --- the fixture, where make said ---------------------------------------
    mkdir -p "$board_dir" "$hooks_dir" "$BR_OUTDIR" "$BR_WORKDIR" "$BR_LOGDIR" "$BR_REPDIR" || return 1
    # The board pack: the five required keys, plus the two config-bank facts
    # bitstream_opts.tcl dies without. bin_style is what section 3 is about.
    cat > "$board_dir/board.tcl" <<EOF
board_set board_name      demo_board
board_set part            $part
board_set platform        $platform
board_set sys_clk_freq_hz 100000000
board_set bin_style       $style
board_set cfgbvs          VCCO
board_set config_voltage  3.3
EOF
    # The hook: it records what the .bit looked like AT THE MOMENT THE SEAM
    # FIRED. Sourced in the stage's scope, so OUT_DIR and block_name are the
    # stage's own. t_rec is the driver's; a real hook would not have it.
    cat > "$hooks_dir/post_bitstream.tcl" <<'EOF'
set __b [file join $OUT_DIR ${block_name}.bit]
t_rec HOOK post_bitstream bit_exists=[file exists $__b] bit_bytes=[expr {[file exists $__b] ? [file size $__b] : 0}]
EOF
    # A PROJECT OVERRIDE OF bitstream_opts THAT KEEPS THE LETTER AND DROPS THE
    # LOAD-BEARING SECTION. flow/steps/bitstream_opts.tcl's header lists four
    # things an override MUST still do, and puts SET CFGBVS AND CONFIG_VOLTAGE
    # first - "the whole reason this file is a step of its own". This override
    # does the other three and skips that one, which is exactly the shape a
    # project arrives at by copying the file and deleting the part it did not
    # need. It sets every variable the stage checks for, and ends with the last
    # line the header demands.
    if [ "$ovr_opts" = 1 ]; then
        mkdir -p "$ovr_dir" || return 1
        cat > "$ovr_dir/bitstream_opts.tcl" <<EOF
# A project override that satisfies every check the stage makes and none of the
# ones that decide whether the device configures. Planted by t_bitstream.sh.
set BITSTREAM_PROPS {}
set BITSTREAM_ARGS  {}
set BITSTREAM_BIN_STYLE $style
lappend BITSTREAM_ARGS -force
if {\$BITSTREAM_BIN_STYLE ne ""} { lappend BITSTREAM_ARGS -bin_file }
set ::BITSTREAM_OPTS_DONE 1
EOF
    fi
    case "$dcp_mode" in
        absent) ;;
        zero)   : > "$BR_OUTDIR/${BR_BLOCK}_routed.dcp" ;;
        *)      printf 'routed checkpoint stand-in, %s\n' "$label" > "$BR_OUTDIR/${BR_BLOCK}_routed.dcp" ;;
    esac
    [ "$hwh" = 1 ] && printf '<hwh design="%s"/>\n' "$BR_DESIGN" > "$BR_WORKDIR/${BR_DESIGN}.hwh"
    # A handoff left in OUT_DIR by an EARLIER run in the same RUN_TAG - the shape
    # a project arrives at by flipping BITSTREAM_WRITE_XSA off without a clean.
    [ "$stale_xsa" = 1 ] && printf 'an .xsa from an earlier run of a different bitstream\n' > "$BR_OUTDIR/${BR_BLOCK}.xsa"
    if [ -n "$impl_bytes" ]; then
        printf '# impl manifest stand-in\nstage                        impl\ndcp_bytes                    %s\n' "$impl_bytes" \
            > "$BR_REPDIR/impl_manifest.txt"
    fi
    # The stage log, at the path vivado_stage composes: $(LOG_DIR)/<stage>.log.
    # Empty, so the critical-warning census reads a complete log with nothing
    # in it, which is the clean case.
    : > "$BR_LOGDIR/bitstream.log"

    # A DIRTY git repository at PROJECT_ROOT, dirty by a MODIFIED TRACKED FILE.
    # That is the shape `git describe --dirty` reports as `-dirty`, and it is
    # deliberately not t_provenance's untracked-file shape: the legacy
    # fabrication stripped that exact suffix.
    if [ "$GIT_OK" = 1 ]; then
        if gitq -C "$root/proj" init -q --template= >/dev/null 2>&1; then
            printf 'tracked\n' > "$root/proj/tracked.txt"
            gitq -C "$root/proj" add -A >/dev/null 2>&1
            gitq -C "$root/proj" -c user.email=t@example.invalid -c user.name=t \
                 -c commit.gpgsign=false commit -q -m fixture >/dev/null 2>&1
            printf 'modified after the commit\n' > "$root/proj/tracked.txt"
        fi
    fi

    # --- the run -------------------------------------------------------------
    BR_STUB="$root/stub.log"; : > "$BR_STUB"
    BR_OUT="$root/stage.out"
    BR_MAN="$BR_REPDIR/bitstream_manifest.txt"
    BR_GATE="$BR_REPDIR/bitstream_gate.txt"
    BR_RC=0
    # cwd is WORK_DIR, as vivado_stage does it. FPGA_LOG_FILE and FPGA_STAGE are
    # the per-stage exports the macro adds; FPGA_TOOL_HINT says what this was.
    ( cd "$BR_WORKDIR" && env \
        FPGA_FLOW_DIR="$tk" FPGA_DIR="$fpga" FPGA_PROJECT_ROOT="$BR_ROOT" \
        FPGA_BLOCK="$BR_BLOCK" FPGA_DESIGN_NAME="$BR_DESIGN" \
        FPGA_RUN_TAG="$run_tag" FPGA_RUN_DIR="$BR_RUNDIR" \
        FPGA_WORK_DIR="$BR_WORKDIR" FPGA_LOG_DIR="$BR_LOGDIR" \
        FPGA_REPORT_DIR="$BR_REPDIR" FPGA_OUT_DIR="$BR_OUTDIR" FPGA_IN_WORK_DIR="$in_work" \
        FPGA_PART_DIR="$part_dir" FPGA_BOARD_DIR="$board_dir" \
        FPGA_HOOKS_DIR="$hooks_dir" FPGA_OVERRIDES_DIR="$ovr_dir" \
        FPGA_PLATFORM="$platform" FPGA_STAGE=bitstream \
        FPGA_LOG_FILE="$BR_LOGDIR/bitstream.log" FPGA_TOOL_HINT="tclsh+recording-stubs" \
        T_STUB_LOG="$BR_STUB" "${extra[@]}" \
        timeout 120 tclsh "$SB/bit_drive.tcl" "$tk" ) > "$BR_OUT" 2>&1 || BR_RC=$?

    # AN UNCAUGHT TCL ERROR IS ANNOUNCED HERE, UNCONDITIONALLY, and not left to
    # whichever branch of whichever predicate happens to call show_run. It is
    # the one fact that invalidates every assertion downstream of it - the
    # stage did not run, so nothing it did or did not write means anything -
    # and bit_proof keys on it to refuse a mutation proof that never reached
    # the code it was aimed at. Printing it from the one place every run goes
    # through is what makes that guard reliable rather than incidental.
    if grep -qE '^ +while executing$|^invalid command name|^wrong # args' "$BR_OUT"; then
        printf 'THE STAGE DIED WITH AN UNCAUGHT TCL ERROR (exit %s):\n' "$BR_RC"
        grep -nE '^ +while executing$|^invalid command name|^wrong # args|^ +\(file ' "$BR_OUT" | head -4 | sed 's/^/  | /'
    fi
    return 0
}

## bit_mf <manifest> <key> - the value, whole line after the key, as ci_mf reads it
bit_mf() { [ -s "$1" ] || return 1; awk -v k="$2" '$1 == k { $1 = ""; sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); print; exit }' "$1"; }
## stub_line <regex> - line NUMBER of the first stub-log line matching, or ""
stub_line() { grep -nE -m1 -- "$1" "$BR_STUB" | cut -d: -f1; }
## show_run - the evidence, for a failing predicate
## show_run - the evidence for a failing predicate.
##
## The stage's OWN diagnosis comes out first when it has one. Every refusal and
## every hard failure in this stage is printed as `<prefix>-FAIL:` or
## `<prefix>-REFUSED:` (flow_utils.tcl section 1), and when the stage stopped
## itself those lines say why far better than six lines of tail - which on a
## stage that stopped mid-section are whatever it happened to be printing.
## Falls back to the tail when there is no such line, because a stage that
## exited 0 wrongly has no diagnosis to quote.
show_run() {
    local diag
    printf 'exit %s; stub log:\n' "$BR_RC"; sed 's/^/  | /' "$BR_STUB"
    diag="$(grep -E '^[A-Z]+-(FAIL|REFUSED):' "$BR_OUT" | head -6)"
    if [ -n "$diag" ]; then
        printf "the stage's own diagnosis:\n"; printf '%s\n' "$diag" | sed 's/^/  | /'
    else
        printf 'last lines of the stage:\n'; tail -6 "$BR_OUT" | sed 's/^/  | /'
    fi
}

## bit_proof <predicate> <mutant> [args...]
##
## EVERY MUTATION PROOF IN THIS FILE GOES THROUGH THIS, and it exists because
## the first draft of one did not.
##
## t_check_fail accepts ANY non-zero exit, so a mutant that broke the stage for
## a reason unrelated to the planted fault satisfies its proof while proving
## nothing. That is not hypothetical here: the .xsa proof below was planted with
## t_replace_line, whose sed `Nc\` form EATS A TRAILING BACKSLASH, so the Tcl
## line-continuation vanished, one command became two, and the stage died with
## `invalid command name`. It exited non-zero, wrote no gate, and the proof
## reported `ok` - a green line for a mutant that never reached the code the
## assertion is about.
##
## So a proof is valid only when the predicate fails AND the failure is not an
## uncaught Tcl error or a fixture that could not be built. Anything else and
## this returns 0, which makes t_check_fail report the proof RED with the
## evidence - because "the mutant is broken" and "the check rejected the fault"
## are different findings and must not print the same word.
##
## The patterns are Tcl's own uncaught-error shapes plus this file's two
## infrastructure messages. A stage that CATCHES an error and reports it (which
## several paths here do, deliberately) is not matched: the marker is the
## interpreter's traceback, not the word "error".
bit_proof() {
    local out rc=0
    out="$("$@" 2>&1)" || rc=$?
    printf '%s\n' "$out"
    if [ "$rc" -eq 0 ]; then
        printf '\nTHE PREDICATE ACCEPTED THE PLANTED FAULT.\n'
        return 0
    fi
    if printf '%s' "$out" | grep -qE 'THE STAGE DIED WITH AN UNCAUGHT TCL ERROR|could not resolve the paths|no part pack under'; then
        printf '\nTHE MUTANT DID NOT REACH THE ASSERTION: the stage died with an uncaught Tcl\n'
        printf 'error, or the fixture could not be built. It exited non-zero, so the proof\n'
        printf 'would have read `ok` - on a mutant that never ran the code this proof is\n'
        printf 'about. Re-plant the fault so the stage still parses and still runs.\n'
        return 0
    fi
    return 1
}


#=============================================================================
# 0. THE PROOF GUARD ITSELF, PROVED
#
# bit_proof is a check, so it gets the same treatment as everything it guards:
# a check that cannot fail is not a check. The mutant below is deliberately
# NOT a design fault - it is a BROKEN STAGE, a Tcl line-continuation removed so
# that one command becomes two and the interpreter stops at `invalid command
# name`. That is the exact shape that fooled the .xsa proof in this file's
# first draft.
#
# t_check, not t_check_fail, and the polarity is worth a sentence: bit_proof
# returns 0 for "this proof is NOT valid", because that is what t_check_fail
# has to see to print a red line. So a green line here means bit_proof SPOTTED
# the broken mutant and would have refused to call it a proof.
#=============================================================================
t_head "the proof guard refuses a mutant that never reached the assertion"

## bit_boots <toolkit> - the smallest predicate there is: the stage runs and
## leaves a bitstream. Its only job is to give the guard something to guard.
bit_boots() {
    local tk="$1"
    bit_run "$tk" guard-probe || return 1
    [ -s "$BR_OUTDIR/$BR_BLOCK.bit" ] || { printf 'no .bit after the run\n'; show_run; return 1; }
    return 0
}

M="$(t_mutant "$SB" broken-not-a-fault)"
if [ -n "$M" ] && t_replace_line "$M" "$ST_REL" \
        '    lappend __required $XSA \' \
        '    lappend __required $XSA'; then
    t_check bit.proof.guard \
        "a mutant that dies with an uncaught Tcl error is refused as a proof, not counted as one" \
        bit_proof bit_boots "$M"
else
    t_skip bit.proof.guard "could not plant the broken mutant: the __required lappend for the .xsa has changed shape"
fi


#=============================================================================
# 1. THE ARTEFACTS, AND THE MANIFEST THAT DESCRIBES THEM
#
# CONTRACT.md section 4: `bitstream` is asserted on the .bit, the .bin, the
# .xsa and its manifest; the stage's own header adds the .hwh. Asserted at the
# paths make composes, non-zero, and cross-checked against block 8: a manifest
# saying `bit_bytes 48` about a 48-byte file is the pairing ci/assert-stage.sh
# reads to decide "same run" (its bitstream.consistent gate).
#=============================================================================
t_head "the four artefacts exist, are not empty, and the manifest describes them"

## artefacts_present <toolkit>
artefacts_present() {
    local tk="$1" f n v
    bit_run "$tk" artefacts || return 1
    for f in "$BR_OUTDIR/$BR_BLOCK.bit" "$BR_OUTDIR/$BR_BLOCK.bin" "$BR_OUTDIR/$BR_BLOCK.xsa" "$BR_OUTDIR/$BR_DESIGN.hwh"; do
        if [ ! -e "$f" ]; then
            printf 'no %s. CONTRACT.md section 4 asserts it for every bitstream:\n' "$f"; ls -l "$BR_OUTDIR"; show_run; return 1
        elif [ ! -s "$f" ]; then
            printf '%s is ZERO BYTES - the shape a tool leaves when it opened its output and died:\n' "$f"; ls -l "$BR_OUTDIR"; show_run; return 1
        fi
    done
    for f in bit bin xsa; do
        n="$(stat -c %s "$BR_OUTDIR/$BR_BLOCK.$f")"
        v="$(bit_mf "$BR_MAN" ${f}_bytes)"
        if [ "$v" != "$n" ]; then
            printf 'the manifest says %s_bytes=%s and the .%s on disk is %s bytes. That is the\n' "$f" "$v" "$f" "$n"
            printf 'pairing ci/assert-stage.sh reads to decide whether the manifest and the file\n'
            printf 'are from the same run, and here they are not:\n'
            grep -nE '^(bit|bin|xsa|payload)_bytes' "$BR_MAN"; return 1
        fi
    done
    v="$(bit_mf "$BR_MAN" hwh)"
    [ "$v" = "$BR_DESIGN.hwh" ] || {
        printf "the manifest's hwh field is '%s', not %s.hwh - the overlay file shipped and\n" "$v" "$BR_DESIGN"
        printf 'the record does not say so:\n'; grep -n '^hwh' "$BR_MAN"; return 1; }
    [ "$BR_RC" -eq 0 ] || { printf 'every artefact is on disk and the stage still exited %s:\n' "$BR_RC"; show_run; return 1; }
    return 0
}

t_check bit.artefacts.present \
    ".bit .bin .xsa .hwh are on disk and non-zero, and bit/bin/xsa_bytes and hwh in the manifest describe those files" \
    artefacts_present "$FLOW_DIR"

# A manifest field that does not describe the file beside it. The reference
# project's dcp_bytes gate exists because of exactly this shape.
M="$(t_mutant "$SB" bit-bytes-constant)"
if [ -n "$M" ] && t_replace_line "$M" "$ST_REL" \
        'prov_stage_field bit_bytes    [expr {[file exists $BIT] ? [file size $BIT] : ""}]' \
        'prov_stage_field bit_bytes    0'; then
    t_check_fail bit.artefacts.present.mutation.bit_bytes \
        "with bit_bytes recorded as a constant the manifest describes a file that is not on disk, so the assertion goes red" \
        bit_proof artefacts_present "$M"
else
    t_skip bit.artefacts.present.mutation.bit_bytes "could not plant the fault: the bit_bytes measurement line has changed shape"
fi

M="$(t_mutant "$SB" no-hwh)"
if [ -n "$M" ] && t_replace_line "$M" "$ST_REL" \
        'if {$BITSTREAM_WRITE_HWH} {' \
        'if {0} {'; then
    t_check_fail bit.artefacts.present.mutation.hwh \
        "with the .hwh publication disabled the overlay file never reaches outputs/, so the assertion goes red" \
        bit_proof artefacts_present "$M"
else
    t_skip bit.artefacts.present.mutation.hwh "could not plant the fault: the BITSTREAM_WRITE_HWH branch has changed shape"
fi

#-----------------------------------------------------------------------------
# THE CONSUMER GRADES THE RUN. ci/assert-stage.sh is the second, independent
# implementation of the artefact and manifest checks (its own header says why),
# and it reads the manifest with `awk '$1 == key'` and fixed key names. So the
# manifest FORMAT is asserted by running the REAL grader over the fixture run -
# the grader from $FLOW_DIR always, because the property is that the STAGE
# writes what the consumer reads, and a mutant's own grader is not the consumer.
#-----------------------------------------------------------------------------
## grader_green <toolkit>
grader_green() {
    local tk="$1" out rc=0 vd
    bit_run "$tk" grader || return 1
    vd="$BR_RUNDIR/ci"; rm -rf "$vd"
    out="$(cd "$BR_RUNDIR" && env FPGA_RUN_DIR="$BR_RUNDIR" FPGA_BLOCK="$BR_BLOCK" FPGA_DESIGN_NAME="$BR_DESIGN" \
              FPGA_REPORT_DIR="$BR_REPDIR" FPGA_OUT_DIR="$BR_OUTDIR" FPGA_WORK_DIR="$BR_WORKDIR" FPGA_LOG_DIR="$BR_LOGDIR" \
              FPGA_SEAMS_FILE="$FLOW_DIR/flow/common/seams.txt" CI_VERDICT_DIR="$vd" \
              bash "$FLOW_DIR/ci/assert-stage.sh" bitstream 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'ci/assert-stage.sh bitstream - the real consumer of this manifest - is RED on a\n'
        printf 'run every artefact assertion above passes (exit %s):\n' "$rc"
        printf '%s\n' "$out" | grep -E '^(FAIL|UNVERIFIED| *[A-Za-z.]+ +(FAIL|UNVERIFIED))|FAILED GATES' -A3 | head -12
        return 1
    fi
    # ...and no gate in its ledger is red. The exit status is the summary; the
    # ledger is the evidence.
    if [ -s "$vd/verdicts.tsv" ] && awk -F'\t' '$2 == "FAIL" || $2 == "UNVERIFIED" { bad = 1 } END { exit !bad }' "$vd/verdicts.tsv"; then
        printf 'assert-stage exited 0 and its verdicts.tsv carries a red gate:\n'
        awk -F'\t' '$2 == "FAIL" || $2 == "UNVERIFIED"' "$vd/verdicts.tsv"; return 1
    fi
    return 0
}

t_check bit.manifest.grader \
    "the REAL ci/assert-stage.sh grades the run green: the keys it reads (bin_style, bit_bytes, stage) are where it reads them" \
    grader_green "$FLOW_DIR"

# The key the consumer requires, spelled differently by the stage. assert-stage
# calls it UNVERIFIED - the manifest exists, is complete, and says nothing the
# grader can use.
M="$(t_mutant "$SB" bin-style-key-renamed)"
if [ -n "$M" ] && t_replace_line "$M" "$ST_REL" \
        'prov_stage_field bin_style    [expr {$BITSTREAM_BIN_STYLE eq "" ? "" : $BITSTREAM_BIN_STYLE}]' \
        'prov_stage_field binstyle     [expr {$BITSTREAM_BIN_STYLE eq "" ? "" : $BITSTREAM_BIN_STYLE}]'; then
    t_check_fail bit.manifest.grader.mutation.key \
        "with bin_style written under another key the consumer finds nothing and grades UNVERIFIED, so the assertion goes red" \
        bit_proof grader_green "$M"
else
    t_skip bit.manifest.grader.mutation.key "could not plant the fault: the bin_style measurement line has changed shape"
fi


#=============================================================================
# 2. THE GATE REFUSES: ABSENT AND ZERO-BYTE ARE BOTH RED, AND ARE TOLD APART
#
# ci/lib.sh's ci_assert_file makes a three-way split - present / zero bytes /
# absent - because a zero-byte artefact "satisfies every test -e in the world"
# and is the shape a tool leaves when it died mid-write. The stage's own gate
# makes the same split for the .bit and the .xsa, and this section drives both
# polarities of each and reads the bullet. The exit status is graded from the
# shell because `die` exits; the VERDICT is read from the gate file.
#
# The .bit is the one the stage cannot get past at all: write_bitstream leaving
# nothing stops the stage on the spot, BEFORE the handoff, the seam and the
# manifest. That early stop is a property in its own right (2c) - a
# post_bitstream hook is where deployment can be wired, and it must not fire
# for a bitstream that does not exist.
#=============================================================================
t_head "the gate refuses an absent or zero-byte artefact, and says which"

## gate_refuses_xsa <toolkit> - both polarities of the hardware handoff
gate_refuses_xsa() {
    local tk="$1"
    bit_run "$tk" xsa-absent zynqmp T_XSA_MODE=absent || return 1
    [ "$BR_RC" -ne 0 ] || { printf 'write_hw_platform left no .xsa and the stage exited 0:\n'; show_run; return 1; }
    grep -qE '^HARD FAILURES: [1-9]' "$BR_GATE" 2>/dev/null || {
        printf 'no .xsa, and the gate does not count a hard failure:\n'; grep -n 'HARD FAILURES' "$BR_GATE" 2>/dev/null || printf '  (no gate file at %s)\n' "$BR_GATE"; return 1; }
    grep -qE "^  - no $BR_BLOCK\\.xsa at " "$BR_GATE" || {
        printf 'the hard failure does not name the ABSENT .xsa as absent:\n'; sed -n '/^HARD FAILURES/,/^BUDGETS/p' "$BR_GATE"; return 1; }
    ! grep -q 'bitstream OK' "$BR_OUT" || { printf 'the stage printed "bitstream OK" over a hard failure:\n'; show_run; return 1; }

    bit_run "$tk" xsa-zero zynqmp T_XSA_MODE=zero || return 1
    [ "$BR_RC" -ne 0 ] || { printf 'a ZERO-BYTE .xsa and the stage exited 0:\n'; show_run; return 1; }
    grep -qE "^  - $BR_BLOCK\\.xsa is ZERO BYTES" "$BR_GATE" 2>/dev/null || {
        printf 'a zero-byte .xsa is not reported as ZERO BYTES. Absent and empty are different\n'
        printf 'diagnoses - one is a tool that never ran, the other a tool that died writing:\n'
        sed -n '/^HARD FAILURES/,/^BUDGETS/p' "$BR_GATE" 2>/dev/null; return 1; }
    return 0
}

t_check bit.gate.xsa \
    "an absent .xsa is a hard failure naming it absent; a zero-byte .xsa is a hard failure saying ZERO BYTES; both exit non-zero" \
    gate_refuses_xsa "$FLOW_DIR"

# THE .xsa QUIETLY DROPS OUT OF THE REQUIRED SET. Section 7 still writes the
# handoff; only the gate stops asking for it.
#
# PLANTED WITH A RANGE-ANCHORED `t_mutate`, NOT WITH t_replace_line, and the
# reason is a trap this proof fell into first. The obvious edit is the `lappend
# __required $XSA \` line - but t_replace_line plants with sed's `Nc\<text>`,
# and sed EATS A TRAILING BACKSLASH as its own line continuation. The
# replacement landed without the Tcl line-continuation, splitting one command
# into two, the second of which is a bare string: the stage died with `invalid
# command name`, exited non-zero and wrote no gate at all. The proof went green
# on a mutant that had no gate to accept anything - a fault that broke the
# stage for an unrelated reason, which is exactly the "check that cannot fail"
# this discipline exists to catch, found inside the check.
#
# `if {$BITSTREAM_WRITE_XSA} {` appears TWICE in the stage - once at the write,
# once at the gate - so t_replace_line correctly refuses it as ambiguous. The
# sed RANGE below is what disambiguates: it can only match inside the gate's
# required-set block, so section 7 still writes the .xsa and the mutation is
# one fault in one place.
M="$(t_mutant "$SB" xsa-not-required)"
if [ -n "$M" ] && t_mutate "$M" "$ST_REL" \
        '/^set __required \[list \$BIT/,/^}$/ s/^if {\$BITSTREAM_WRITE_XSA} {$/if {0} {/'; then
    t_check_fail bit.gate.xsa.mutation.not_required \
        "with the .xsa dropped from the required set an absent handoff passes the gate, so the assertion goes red" \
        bit_proof gate_refuses_xsa "$M"
else
    t_skip bit.gate.xsa.mutation.not_required "could not plant the fault: the gate's required-set block, or its BITSTREAM_WRITE_XSA test, has changed shape"
fi

# The zero-byte branch goes dead: a 0-byte handoff exists, so it passes.
M="$(t_mutant "$SB" zero-bytes-not-checked)"
if [ -n "$M" ] && t_replace_line "$M" "$ST_REL" \
        '    } elseif {![file size $f]} {' \
        '    } elseif {0} {'; then
    t_check_fail bit.gate.xsa.mutation.zero_bytes \
        "with the zero-byte test dead a 0-byte .xsa satisfies the gate, so the assertion goes red" \
        bit_proof gate_refuses_xsa "$M"
else
    t_skip bit.gate.xsa.mutation.zero_bytes "could not plant the fault: the zero-byte branch of the required-file loop has changed shape"
fi

## gate_refuses_bin <toolkit> - the .bin, both polarities. -bin_file was asked
## for (the style is zynqmp) and the tool left nothing / an empty file.
gate_refuses_bin() {
    local tk="$1" mode
    for mode in nobin zerobin; do
        bit_run "$tk" bin-$mode zynqmp T_BIT_MODE=$mode || return 1
        [ "$BR_RC" -ne 0 ] || { printf '.bin mode %s and the stage exited 0:\n' "$mode"; show_run; return 1; }
        grep -qE '^HARD FAILURES: [1-9]' "$BR_GATE" 2>/dev/null || {
            printf '.bin mode %s: the gate counts no hard failure:\n' "$mode"; grep -n 'HARD FAILURES' "$BR_GATE" 2>/dev/null; return 1; }
        grep -qE '^  - no \.bin at ' "$BR_GATE" || {
            printf '.bin mode %s: no hard-failure bullet about the .bin:\n' "$mode"; sed -n '/^HARD FAILURES/,/^BUDGETS/p' "$BR_GATE"; return 1; }
        ! grep -q 'bitstream OK' "$BR_OUT" || { printf '.bin mode %s: "bitstream OK" printed over a hard failure:\n' "$mode"; show_run; return 1; }
    done
    return 0
}

t_check bit.gate.bin \
    "a .bin that the tool did not write, or wrote empty, is a hard failure and the stage exits non-zero" \
    gate_refuses_bin "$FLOW_DIR"

# THE VERDICT AND THE EXIT DISAGREE. The gate file still lists the hard failure;
# the stage prints "bitstream OK" and exits 0. Every make assertion after it
# then passes on the artefacts that DO exist, and the .bin's absence is a line
# in a file nobody opens on a green run.
M="$(t_mutant "$SB" hard-failures-do-not-exit)"
if [ -n "$M" ] && t_replace_line "$M" "$ST_REL" \
        'if {[llength $HARD]} {' \
        'if {0} {'; then
    t_check_fail bit.gate.bin.mutation.exit_collapsed \
        "with the hard-failure exit dead the gate records the failure and the stage says OK, so the assertion goes red" \
        bit_proof gate_refuses_bin "$M"
else
    t_skip bit.gate.bin.mutation.exit_collapsed "could not plant the fault: the hard-failure exit line has changed shape"
fi

## no_bit_stops_early <toolkit> - write_bitstream returned and left nothing
## (or an empty file). The stage must stop THERE: no handoff attempted, no
## post_bitstream hook fired, no manifest claiming a run.
no_bit_stops_early() {
    local tk="$1" mode; shift
    local modes="${*:-absent zero}"
    for mode in $modes; do
        bit_run "$tk" bit-$mode zynqmp T_BIT_MODE=$mode || return 1
        [ "$BR_RC" -ne 0 ] || { printf '.bit mode %s and the stage exited 0:\n' "$mode"; show_run; return 1; }
        if grep -qE '^HOOK post_bitstream' "$BR_STUB"; then
            printf '.bit mode %s: THE post_bitstream HOOK FIRED WITH NO BITSTREAM ON DISK. That is the\n' "$mode"
            printf 'seam where publishing and deployment are wired, and it ran for an image that\n'
            printf 'does not exist:\n'; show_run; return 1
        fi
        if grep -qE '^write_hw_platform' "$BR_STUB"; then
            printf '.bit mode %s: the stage went on to write a hardware handoff for a bitstream it\n' "$mode"
            printf 'had just found missing:\n'; show_run; return 1
        fi
        if [ -e "$BR_MAN" ]; then
            printf '.bit mode %s: a manifest was written for a run that produced no bitstream:\n' "$mode"; grep -nE '^(stage|bit_bytes|stage_status)' "$BR_MAN"; return 1
        fi
    done
    return 0
}

t_check bit.gate.bit.stops_early \
    "write_bitstream leaving no .bit (or an empty one) stops the stage before the handoff, the seam and the manifest" \
    no_bit_stops_early "$FLOW_DIR"

# THE PROOF DRIVES THE ZERO-BYTE MODE ONLY, and the reason is a distinction
# bit_proof forced into the open rather than a convenience.
#
# With the check dead and NO .bit at all, the next line is
# `say "bitstream: $BIT ([file size $BIT] bytes)"` - and `file size` on a
# missing file THROWS. The stage dies with an uncaught Tcl error, which is a
# rejection, but an ambiguous one: it is indistinguishable from a mutant that
# was malformed, and that is precisely what bit_proof refuses to count.
#
# The ZERO-BYTE mode has no such ambiguity. The file exists, `file size`
# answers 0, and the stage walks calmly on to write a hardware handoff, fire
# the terminal seam and write a manifest - for a bitstream that is zero bytes.
# That is the fault this proof is about, demonstrated without a crash to hide
# behind.
M="$(t_mutant "$SB" no-bit-not-checked)"
if [ -n "$M" ] && t_replace_line "$M" "$ST_REL" \
        'if {![file exists $BIT] || ![file size $BIT]} {' \
        'if {0} {'; then
    t_check_fail bit.gate.bit.stops_early.mutation \
        "with the post-write_bitstream check dead the stage carries on - handoff, hook, manifest - over a ZERO-BYTE .bit, so the assertion goes red" \
        bit_proof no_bit_stops_early "$M" zero
else
    t_skip bit.gate.bit.stops_early.mutation "could not plant the fault: the no-bitstream check after write_bitstream has changed shape"
fi


#=============================================================================
# 3. THE .bin CONVERSION, READ OFF DISK
#
# CONTRACT.md section 9.5: zynq7 needs a BYTE SWAP, zynqmp a HEADER STRIP, the
# two are not interchangeable and the wrong one is a file of the right size
# that the device does not boot. The stub's -bin_file payload is sixteen known
# bytes, so the conversion the stage performed is readable with `od`: the
# zynqmp form is the payload as written, the zynq7 form has every 32-bit word
# reversed. The raw payload must also survive in WORK_DIR - that is how a board
# that will not boot gets retried against the other form without a rebuild.
#
# And the style comes from the BOARD PACK, through the accessor shim, with the
# exported BIN_STYLE as a fallback only. A project that exports the other style
# is announced and overridden. The mutant for that is the fallback made
# unconditional.
#=============================================================================
t_head "the .bin is converted the way the board pack says, and the record says which"

## bin_zynqmp <toolkit>
bin_zynqmp() {
    local tk="$1" h v
    bit_run "$tk" zynqmp zynqmp || return 1
    [ "$BR_RC" -eq 0 ] || { show_run; return 1; }
    h="$(hex_of "$BR_OUTDIR/$BR_BLOCK.bin")"
    [ "$h" = "$PAYLOAD_HEX" ] || {
        printf 'zynqmp: the .bin is not the header-stripped payload as the tool wrote it:\n  got  %s\n  want %s\n' "$h" "$PAYLOAD_HEX"
        printf 'A zynqmp loader given a byte-swapped image accepts it and the device does not come up.\n'; return 1; }
    v="$(bit_mf "$BR_MAN" bin_style)";  [ "$v" = zynqmp ] || { printf "manifest bin_style is '%s', not zynqmp\n" "$v"; return 1; }
    v="$(bit_mf "$BR_MAN" bin_source)"
    case "$v" in "header strip"*) ;; *) printf "manifest bin_source is '%s' - it does not say the payload was used as written\n" "$v"; return 1 ;; esac
    return 0
}

## bin_zynq7 <toolkit>
bin_zynq7() {
    local tk="$1" h v
    bit_run "$tk" zynq7 zynq7 || return 1
    [ "$BR_RC" -eq 0 ] || { show_run; return 1; }
    h="$(hex_of "$BR_OUTDIR/$BR_BLOCK.bin")"
    [ "$h" = "$SWAPPED_HEX" ] || {
        printf 'zynq7: the .bin is not the payload with every 32-bit word byte-swapped:\n  got  %s\n  want %s\n' "$h" "$SWAPPED_HEX"
        printf 'A zynq7 loader given the unswapped payload accepts it and the device does not come up.\n'; return 1; }
    h="$(hex_of "$BR_WORKDIR/$BR_BLOCK.payload.bin")"
    [ "$h" = "$PAYLOAD_HEX" ] || {
        printf 'the raw payload was not kept unchanged in WORK_DIR (got: %s). Without it a board that\n' "$h"
        printf 'will not boot cannot be retried against the other form without a rebuild.\n'; return 1; }
    v="$(bit_mf "$BR_MAN" bin_style)";  [ "$v" = zynq7 ] || { printf "manifest bin_style is '%s', not zynq7\n" "$v"; return 1; }
    v="$(bit_mf "$BR_MAN" bin_source)"
    case "$v" in "byte swap"*) ;; *) printf "manifest bin_source is '%s' - it does not say a byte swap happened\n" "$v"; return 1 ;; esac
    return 0
}

## pack_owns_style <toolkit> - board pack zynqmp, project exports zynq7
pack_owns_style() {
    local tk="$1" h v
    bit_run "$tk" style-override zynqmp FPGA_BIN_STYLE=zynq7 || return 1
    [ "$BR_RC" -eq 0 ] || { show_run; return 1; }
    h="$(hex_of "$BR_OUTDIR/$BR_BLOCK.bin")"
    [ "$h" = "$PAYLOAD_HEX" ] || {
        printf "the board pack says zynqmp and the project exported BIN_STYLE=zynq7; the .bin was\n"
        printf 'converted the PROJECT way (got %s). The pack owns this fact, and the stage is\n' "$h"
        printf 'supposed to take it from the pack and announce the divergence.\n'; return 1; }
    v="$(bit_mf "$BR_MAN" bin_style)"; [ "$v" = zynqmp ] || { printf "manifest bin_style is '%s', not the pack's zynqmp\n" "$v"; return 1; }
    grep -q 'BIN_STYLE OVERRIDE IS ACTIVE' "$BR_OUT" || {
        printf 'the pack and the project disagree about bin_style and the stage did not announce\n'
        printf 'it. A legitimate override and a stale one look identical without the warning.\n'; return 1; }
    return 0
}

## bin_none <toolkit> - bin_style none: NO .bin, and that absence is DECLARED
##
## The other two styles prove a conversion happened. This one proves one did not,
## which is the harder claim: "no .bin" is also what a stage that died early
## produces, and what a stage that forgot -bin_file produces. So the assertion is
## not "the file is absent" - it is that the file is absent AND the manifest says
## why AND the gate is satisfied.
bin_none() {
    local tk="$1" v
    bit_run "$tk" none none || return 1
    [ "$BR_RC" -eq 0 ] || { printf 'bin_style none and the stage exited %s:\n' "$BR_RC"; show_run; return 1; }
    [ ! -s "$BR_OUTDIR/$BR_BLOCK.bin" ] || {
        printf 'bin_style none and a .bin was written at %s.\n' "$BR_OUTDIR/$BR_BLOCK.bin"
        printf 'Something passed -bin_file: the board says this family has no conversion,\n'
        printf 'so a payload here is a file nothing declares and nobody checks.\n'; return 1; }
    v="$(bit_mf "$BR_MAN" bin_style)"; [ "$v" = none ] || { printf "manifest bin_style is '%s', not none\n" "$v"; return 1; }
    v="$(bit_mf "$BR_MAN" bin_source)"
    case "$v" in
        none:*) ;;
        *) printf "manifest bin_source is '%s' - it does not DECLARE the absence.\n" "$v"
           printf 'An unmeasured bin_source with no .bin is indistinguishable from a stage\n'
           printf 'that died before its conversion block.\n'; return 1 ;;
    esac
    grep -qE '^HARD FAILURES: 0|^HARD FAILURES: none' "$BR_GATE" 2>/dev/null || {
        printf 'bin_style none and the gate still counts a hard failure:\n'
        sed -n '/^HARD FAILURES/,/^BUDGETS/p' "$BR_GATE" 2>/dev/null; return 1; }
    return 0
}

t_check bit.bin.zynqmp "zynqmp: the .bin is the payload as written, kept as written, and the manifest says 'header strip'" bin_zynqmp "$FLOW_DIR"
t_check bit.bin.zynq7  "zynq7: every 32-bit word is byte-swapped, the raw payload is kept in WORK_DIR, and the manifest says 'byte swap'" bin_zynq7 "$FLOW_DIR"
t_check bit.bin.pack_owns_style "the board pack's bin_style wins over an exported BIN_STYLE, and the divergence is announced" pack_owns_style "$FLOW_DIR"
t_check bit.bin.none   "none: NO .bin is written, the manifest DECLARES the absence, and the gate is satisfied" bin_none "$FLOW_DIR"

# THE SUPPRESSION IS THE WHOLE MECHANISM. With -bin_file appended for every
# non-empty style - the shape of the line before `none` existed - the stub writes
# a payload, a .bin appears for a board that says it has none, and bin_none's
# absence assertion goes red. This is the proof that `none` does something rather
# than merely being tolerated.
M="$(t_mutant "$SB" bin-file-always)"
if [ -n "$M" ] && t_replace_line "$M" "$OP_REL" \
        'if {$BITSTREAM_BIN_STYLE ni {"" "none"}} { lappend BITSTREAM_ARGS -bin_file }' \
        'if {$BITSTREAM_BIN_STYLE ne ""} { lappend BITSTREAM_ARGS -bin_file }'; then
    t_check_fail bit.bin.none.mutation \
        "with -bin_file appended for every non-empty style, a .bin appears for a none board and the assertion goes red" \
        bit_proof bin_none "$M"
else
    t_skip bit.bin.none.mutation "could not plant the fault: the -bin_file line has changed shape"
fi

## xsa_grade <toolkit> - run THAT toolkit's ci/assert-stage.sh over the last
## bit_run. Leaves XG_RC, XG_OUT and XG_VD (where the verdict ledger is).
##
## THE GRADER COMES FROM THE TOOLKIT UNDER TEST here, where grader_green takes it
## from $FLOW_DIR on purpose. grader_green's property is the manifest FORMAT - the
## stage writes what the real consumer reads - so a mutant's own grader is not
## the consumer. Here the property is the grader's own LOGIC, so a fault planted
## in it has to be the one that runs.
xsa_grade() {
    local tk="$1"
    XG_VD="$BR_RUNDIR/ci"; rm -rf "$XG_VD"; XG_RC=0
    XG_OUT="$(cd "$BR_RUNDIR" && env FPGA_RUN_DIR="$BR_RUNDIR" FPGA_BLOCK="$BR_BLOCK" FPGA_DESIGN_NAME="$BR_DESIGN" \
              FPGA_REPORT_DIR="$BR_REPDIR" FPGA_OUT_DIR="$BR_OUTDIR" FPGA_WORK_DIR="$BR_WORKDIR" FPGA_LOG_DIR="$BR_LOGDIR" \
              FPGA_SEAMS_FILE="$tk/flow/common/seams.txt" CI_VERDICT_DIR="$XG_VD" \
              bash "$tk/ci/assert-stage.sh" bitstream 2>&1)" || XG_RC=$?
}
## xg_verdict <gate id> - that gate's status in the last xsa_grade's ledger
xg_verdict() { awk -F'\t' -v k="$1" '$3 == k { print $2; exit }' "$XG_VD/verdicts.tsv" 2>/dev/null; }

## xsa_off <toolkit> - BITSTREAM_WRITE_XSA=0: no handoff, DECLARED, and graded
##
## The .xsa has three graders (the stage gate, mk/flow.mk, ci/assert-stage.sh)
## and the declaration relaxes all three, so this is five claims, not one:
##   1. the stage does not call write_hw_platform, leaves no .xsa, records the
##      knob as 0 in the manifest - where the other two graders read it - and its
##      gate counts no hard failure;
##   2. the CI grader passes bitstream.xsa on that run;
##   3. the same grader still FAILS bitstream.xsa on a run that asked for a
##      handoff and got none. It must be that gate by name: the stage gate is red
##      on that run too, so the grader's exit status would be red either way, and
##      a grader that had stopped checking the .xsa would still look right;
##   4. an .xsa left over from an earlier run is a hard failure under 0, in the
##      stage gate;
##   5. ...and in the CI grader.
## Without 3 the relaxation is indistinguishable from deleting the check.
xsa_off() {
    local tk="$1" v
    bit_run "$tk" xsa-off none BITSTREAM_WRITE_XSA=0 || return 1
    [ "$BR_RC" -eq 0 ] || { printf 'BITSTREAM_WRITE_XSA=0 and the stage exited %s:\n' "$BR_RC"; show_run; return 1; }
    [ -z "$(stub_line '^write_hw_platform')" ] || {
        printf 'BITSTREAM_WRITE_XSA=0 and write_hw_platform was still called:\n'; grep -n '^write_hw_platform' "$BR_STUB"; return 1; }
    [ ! -e "$BR_OUTDIR/$BR_BLOCK.xsa" ] || { printf 'BITSTREAM_WRITE_XSA=0 and an .xsa is on disk at %s\n' "$BR_OUTDIR/$BR_BLOCK.xsa"; return 1; }
    v="$(bit_mf "$BR_MAN" knob.BITSTREAM_WRITE_XSA)"
    [ "$v" = 0 ] || { printf "manifest knob.BITSTREAM_WRITE_XSA is '%s', not 0 - mk/flow.mk and the CI grader read it there\n" "$v"; return 1; }
    grep -qE '^HARD FAILURES: (0|none)' "$BR_GATE" 2>/dev/null || {
        printf 'BITSTREAM_WRITE_XSA=0 and the gate still counts a hard failure:\n'
        sed -n '/^HARD FAILURES/,/^BUDGETS/p' "$BR_GATE" 2>/dev/null; return 1; }

    xsa_grade "$tk"
    v="$(xg_verdict bitstream.xsa)"
    [ "$v" = PASS ] || { printf "the CI grader's bitstream.xsa is '%s' on a run that DECLARED no handoff:\n" "$v"
        printf '%s\n' "$XG_OUT" | grep -E 'xsa' | head -4; return 1; }

    bit_run "$tk" xsa-asked-absent none T_XSA_MODE=absent || return 1
    xsa_grade "$tk"
    v="$(xg_verdict bitstream.xsa)"
    [ "$v" = FAIL ] || { printf "the CI grader's bitstream.xsa is '%s' on a run that ASKED for a handoff and got\n" "${v:-(no verdict)}"
        printf 'none. The relaxation has become a deletion.\n'; return 1; }

    bit_run "$tk" xsa-stale none BITSTREAM_WRITE_XSA=0 T_STALE_XSA=1 || return 1
    [ "$BR_RC" -ne 0 ] || { printf 'a stale .xsa under BITSTREAM_WRITE_XSA=0 and the stage exited 0:\n'; show_run; return 1; }
    grep -qE '^  - BITSTREAM_WRITE_XSA is 0 and yet an \.xsa exists at ' "$BR_GATE" 2>/dev/null || {
        printf 'a stale .xsa under BITSTREAM_WRITE_XSA=0 is not a hard failure naming it:\n'
        sed -n '/^HARD FAILURES/,/^BUDGETS/p' "$BR_GATE" 2>/dev/null; return 1; }
    xsa_grade "$tk"
    v="$(xg_verdict bitstream.xsa.unexpected)"
    [ "$v" = FAIL ] || { printf "the CI grader's bitstream.xsa.unexpected is '%s' with a stale .xsa on disk\n" "${v:-(no verdict)}"; return 1; }
    return 0
}

t_check bit.xsa.off "BITSTREAM_WRITE_XSA=0: no handoff and no write_hw_platform, the manifest declares it, stage and CI pass it - CI still fails a run that asked for one, and a stale .xsa is refused by both" xsa_off "$FLOW_DIR"

# THE STALE-FILE REFUSAL, IN THE STAGE. Dead, an .xsa from an earlier run of a
# different bitstream sits in OUT_DIR under a run that declares it wrote none -
# exactly where a software build would look - and the gate is green.
M="$(t_mutant "$SB" xsa-stale-not-refused)"
if [ -n "$M" ] && t_replace_line "$M" "$ST_REL" \
        'if {!$BITSTREAM_WRITE_XSA && [file exists $XSA]} {' \
        'if {0} {'; then
    t_check_fail bit.xsa.off.mutation.stale \
        "with the stage's stale-.xsa refusal dead, a leftover handoff passes the gate and the assertion goes red" \
        bit_proof xsa_off "$M"
else
    t_skip bit.xsa.off.mutation.stale "could not plant the fault: the stage's stale-.xsa test has changed shape"
fi

# THE RELAXATION BECOMES A DELETION, IN THE CI GRADER. With its knob test always
# true, bitstream.xsa passes whatever the run declared - including a run that
# asked for a handoff and got none - and half 3 goes red.
M="$(t_mutant "$SB" xsa-grader-always-relaxed)"
if [ -n "$M" ] && t_replace_line "$M" ci/assert-stage.sh \
        '    if [ "$wx" = "0" ]; then' \
        '    if true; then'; then
    t_check_fail bit.xsa.off.mutation.grader \
        "with the CI grader's knob test always true, a run that asked for a handoff and got none passes bitstream.xsa, and the assertion goes red" \
        bit_proof xsa_off "$M"
else
    t_skip bit.xsa.off.mutation.grader "could not plant the fault: ci/assert-stage.sh's BITSTREAM_WRITE_XSA test has changed shape"
fi

# The style is ignored and the swap always happens: a zynqmp board gets a
# zynq7 image of the right size.
M="$(t_mutant "$SB" always-swaps)"
if [ -n "$M" ] && t_replace_line "$M" "$ST_REL" \
        '    switch -- $BITSTREAM_BIN_STYLE {' \
        '    switch -- zynq7 {'; then
    t_check_fail bit.bin.zynqmp.mutation \
        "with the style switch pinned to zynq7 a zynqmp board gets a byte-swapped image of the right size, so the assertion goes red" \
        bit_proof bin_zynqmp "$M"
else
    t_skip bit.bin.zynqmp.mutation "could not plant the fault: the bin_style switch has changed shape"
fi

# The swap that does not swap: read little-endian and write little-endian is
# a copy. The stage's own 4 KiB comparison catches this one too - which is why
# the predicate reads the bytes itself rather than trusting that check.
M="$(t_mutant "$SB" swap-is-a-copy)"
if [ -n "$M" ] && t_replace_line "$M" "$ST_REL" \
        '        binary scan $chunk I* words' \
        '        binary scan $chunk i* words'; then
    t_check_fail bit.bin.zynq7.mutation \
        "with the word scan changed to little-endian the 'swap' is a copy, so the assertion goes red" \
        bit_proof bin_zynq7 "$M"
else
    t_skip bit.bin.zynq7.mutation "could not plant the fault: the byte-swap scan line has changed shape"
fi

# The pack is never consulted; the exported variable decides. That is a
# project variable deciding a board fact, which is the split CONTRACT.md
# section 1 exists to prevent.
M="$(t_mutant "$SB" env-style-wins)"
if [ -n "$M" ] && t_replace_line "$M" "$OP_REL" \
        'if {[board_have bin_style]} {' \
        'if {0} {'; then
    t_check_fail bit.bin.pack_owns_style.mutation \
        "with the board-pack read disabled the exported BIN_STYLE decides the conversion, so the assertion goes red" \
        bit_proof pack_owns_style "$M"
else
    t_skip bit.bin.pack_owns_style.mutation "could not plant the fault: the board_have bin_style test in bitstream_opts.tcl has changed shape"
fi


#=============================================================================
# 4. A KNOB REACHES THE TOOL, AND THE RECORD IS WHAT THE TOOL WAS TOLD
#
# BITSTREAM_UNUSEDPIN is the knob with a paragraph: the reference project
# measured all four values byte-for-byte against the shipping bitstream, and
# found its own parity harness had FORCED `Pullup` to match a figure, after
# which the forced value was mistaken for the shipped one. Two things have to
# be true and the stub log is the only witness to the first: the value the
# project set is the value set_property received, and the manifest's
# bitstream_props is a transcript of the set_property calls - not of what the
# step file intended.
#=============================================================================
t_head "BITSTREAM_UNUSEDPIN reaches set_property with the project's value, and the record matches the calls"

## unusedpin_reaches_tool <toolkit>
unusedpin_reaches_tool() {
    local tk="$1" v
    bit_run "$tk" unusedpin zynqmp BITSTREAM_UNUSEDPIN=Pulldown || return 1
    [ "$BR_RC" -eq 0 ] || { show_run; return 1; }
    grep -qE '^set_property BITSTREAM\.CONFIG\.UNUSEDPIN Pulldown ' "$BR_STUB" || {
        printf 'the project set BITSTREAM_UNUSEDPIN=Pulldown and set_property was told:\n'
        grep -E 'UNUSEDPIN' "$BR_STUB" || printf '  (nothing about UNUSEDPIN at all)\n'
        printf 'The consequence is electrical and visible in no report this flow writes.\n'; return 1; }
    v="$(bit_mf "$BR_MAN" knob.BITSTREAM_UNUSEDPIN)"
    [ "$v" = Pulldown ] || { printf "the manifest records knob.BITSTREAM_UNUSEDPIN as '%s', not Pulldown\n" "$v"; return 1; }
    # ...and the default is a value, not silence: with nothing set, the
    # shipped default reaches the tool too.
    bit_run "$tk" unusedpin-default zynqmp || return 1
    grep -qE '^set_property BITSTREAM\.CONFIG\.UNUSEDPIN [A-Za-z]+ ' "$BR_STUB" || {
        printf 'with the knob unset no UNUSEDPIN property reached the tool at all, so the device\n'
        printf "takes Vivado's own default and the manifest's knob line describes nothing:\n"; cat "$BR_STUB"; return 1; }
    return 0
}

## props_match_calls <toolkit>
## Every `set_property NAME VALUE design_1` the stub saw before write_bitstream
## appears in bitstream_props as `NAME VALUE`, and the counts agree.
props_match_calls() {
    local tk="$1" props n_calls n_props name value
    bit_run "$tk" props zynqmp BITSTREAM_UNUSEDPIN=Pulldown || return 1
    [ "$BR_RC" -eq 0 ] || { show_run; return 1; }
    props="$(bit_mf "$BR_MAN" bitstream_props)"
    n_calls="$(awk '$1 == "write_bitstream" { exit } $1 == "set_property" { n++ } END { print n + 0 }' "$BR_STUB")"
    [ "$n_calls" -gt 0 ] || { printf 'the stub saw no set_property before write_bitstream - nothing to compare:\n'; cat "$BR_STUB"; return 1; }
    while read -r name value; do
        case " $props " in
            *" $name $value "*) ;;
            *) printf 'set_property was told %s %s and the manifest'"'"'s bitstream_props does not say so:\n  %s\n' "$name" "$value" "$props"
               printf 'The record is supposed to be a transcript of what reached the device.\n'; return 1 ;;
        esac
    done < <(awk '$1 == "write_bitstream" { exit } $1 == "set_property" { print $2, $3 }' "$BR_STUB")
    n_props=$(( $(printf '%s\n' "$props" | wc -w) / 2 ))
    [ "$n_props" -eq "$n_calls" ] || {
        printf 'bitstream_props lists %s properties and set_property was called %s times before\n' "$n_props" "$n_calls"
        printf 'write_bitstream. A property recorded and never applied, or applied and never\n'
        printf 'recorded, is the shape of the usr_access failure with a different name:\n  %s\n' "$props"
        grep '^set_property' "$BR_STUB"; return 1; }
    return 0
}

t_check bit.unusedpin.reaches_tool \
    "BITSTREAM_UNUSEDPIN=Pulldown arrives at set_property as Pulldown and is recorded as Pulldown; unset, the default still reaches the tool" \
    unusedpin_reaches_tool "$FLOW_DIR"
t_check bit.props.record_matches_calls \
    "bitstream_props is a transcript of the set_property calls made before write_bitstream - every one, and no others" \
    props_match_calls "$FLOW_DIR"

# THE PARITY HARNESS'S FAULT, verbatim: a value forced in the step file, so the
# project's knob is read, recorded, and never reaches the tool.
M="$(t_mutant "$SB" unusedpin-forced)"
if [ -n "$M" ] && t_replace_line "$M" "$OP_REL" \
        '_bitopt BITSTREAM.CONFIG.UNUSEDPIN $BITSTREAM_UNUSEDPIN' \
        '_bitopt BITSTREAM.CONFIG.UNUSEDPIN Pullnone'; then
    t_check_fail bit.unusedpin.reaches_tool.mutation.forced \
        "with the property forced to Pullnone in the step file the project's Pulldown never reaches the tool, so the assertion goes red" \
        bit_proof unusedpin_reaches_tool "$M"
else
    t_skip bit.unusedpin.reaches_tool.mutation.forced "could not plant the fault: the UNUSEDPIN _bitopt line has changed shape"
fi

# Recorded, never applied: _bitopt keeps the manifest entry and skips the
# set_property. The knob line says Pulldown; the device pulls up.
M="$(t_mutant "$SB" props-recorded-not-applied)"
if [ -n "$M" ] && t_replace_line "$M" "$OP_REL" \
        '    if {[flow_have current_design]} {' \
        '    if {0} {'; then
    t_check_fail bit.unusedpin.reaches_tool.mutation.recorded_not_applied \
        "with _bitopt recording the property and never calling set_property, the manifest says Pulldown and the tool was never told, so the assertion goes red" \
        bit_proof unusedpin_reaches_tool "$M"
else
    t_skip bit.unusedpin.reaches_tool.mutation.recorded_not_applied "could not plant the fault: the current_design guard in _bitopt has changed shape"
fi

# Applied, recorded wrong: the transcript carries a value the tool was not
# given.
M="$(t_mutant "$SB" props-record-wrong-value)"
if [ -n "$M" ] && t_replace_line "$M" "$OP_REL" \
        '    lappend ::BITSTREAM_PROPS $name $value' \
        '    lappend ::BITSTREAM_PROPS $name recorded'; then
    t_check_fail bit.props.record_matches_calls.mutation \
        "with the record carrying a value the tool was not given, the transcript and the calls disagree, so the assertion goes red" \
        bit_proof props_match_calls "$M"
else
    t_skip bit.props.record_matches_calls.mutation "could not plant the fault: the BITSTREAM_PROPS lappend in _bitopt has changed shape"
fi


#=============================================================================
# 5. usr_access: THE RECORD IS WHAT REACHED THE DEVICE, OR IT SAYS IT DID NOT
#
# THE MEASURED FAILURE, from the reference project's legacy flow. Three files:
#
#   build_design.tcl        exported the low 32 bits of the sha ONLY for a clean
#                           tree, and printed `NOT stamping a commit SHA`
#                           otherwise. Correct.
#   msg_gate_child_check    called set_property BITSTREAM.CONFIG.USR_ACCESS with
#                           the exported value when there was one. Correct.
#   build_provenance.tcl    `string map {"-dirty" ""} $sha`, then wrote
#                           `"usr_access": "0x<low 8 hex>"` into the manifest
#                           UNCONDITIONALLY. The manifest never asked whether
#                           the stamp happened. It computed the answer.
#
# So every dirty build shipped a manifest whose usr_access was the low 32 bits
# of a commit the device did not carry, and the bench's provenance check -
# `grep -oE '0x[0-9a-f]+'` on that field - read it and passed. A field that
# looks like evidence and is arithmetic.
#
# THE HONEST SHAPE is a disjunction and the predicate asserts exactly it:
#
#   stamped:   a value reached set_property BITSTREAM.CONFIG.USR_ACCESS, and the
#              manifest's usr_access is THAT VALUE - read from the stub log, the
#              only witness to what the tool was told.
#   unstamped: nothing reached set_property, and the manifest's usr_access says
#              so IN WORDS. Not `0x...` (that is the fabrication), not absent (a
#              reader cannot tell "this flow does not stamp" from "the field was
#              dropped"), not `unmeasured` ("did not look" is not "did not
#              stamp") and not `(none)` (which carries no why).
#
# WHAT THE STAGE DOES TODAY: nothing. No line in this toolkit mentions
# USR_ACCESS - it neither stamps nor records - so the manifest is silent, and
# silence fails the disjunction on the absent branch. That is a KNOWN DEFECT:
# the marker goes red the day the stage records either answer.
#
# It is proved from BOTH SIDES, because a predicate that fails on the real
# toolkit needs to be shown satisfiable before its rejections mean anything:
# two honest mutants pass it (one stamps and records the same value, one
# records that it did not stamp), and two dishonest mutants are rejected - the
# legacy shape verbatim, and a stage that stamps one value and records another.
#=============================================================================
t_head "known defect: usr_access is what reached set_property, or a stated reason it did not"

## usr_access_honest <toolkit>
usr_access_honest() {
    local tk="$1" v told
    bit_run "$tk" usr-access zynqmp || return 1
    [ "$BR_RC" -eq 0 ] || { show_run; return 1; }
    v="$(bit_mf "$BR_MAN" usr_access)"
    told="$(awk '$1 == "set_property" && $2 == "BITSTREAM.CONFIG.USR_ACCESS" { print $3; exit }' "$BR_STUB")"
    if [ -n "$told" ]; then
        [ "$v" = "$told" ] && return 0
        printf 'set_property was told BITSTREAM.CONFIG.USR_ACCESS %s and the manifest says\n' "$told"
        printf "usr_access '%s'. The register in the device and the record of it disagree.\n" "${v:-(absent)}"
        return 1
    fi
    # Nothing reached the tool. The record has to say so.
    case "$v" in
        "")
            printf 'the manifest carries NO usr_access field, and nothing reached set_property.\n'
            printf 'A reader cannot tell "this flow does not stamp USR_ACCESS" from "the field was\n'
            printf 'dropped", and the bench check that reads this field will read whatever a later\n'
            printf 'tool leaves there. The stage has to say it did not stamp, and why.\n'
            return 1 ;;
        0x[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
            printf "the manifest says usr_access %s and NOTHING REACHED set_property. That value was\n" "$v"
            printf 'never written into the device. This is the legacy flow'"'"'s failure: a field that\n'
            printf 'looks like evidence and is arithmetic.\n'
            return 1 ;;
        unmeasured|"(none)")
            printf "usr_access is '%s'. Nothing reached set_property, and that token says\n" "$v"
            printf '"did not look" or "nothing" - not "did not stamp, and here is why". A reader\n'
            printf 'cannot act on either of the first two.\n'
            return 1 ;;
    esac
    return 0
}

t_known_defect bit.usr_access.honest \
    "usr_access is the value set_property received, or a reason in words that nothing was stamped - never a value the device does not carry" \
    usr_access_honest "$FLOW_DIR"

# -- POSITIVE CONTROLS: the predicate is satisfiable, both branches ---------
# An honest stage that stamps: set_property before write_bitstream, and the
# manifest records the same literal.
UA_ANCHOR='/^prov_stage_field platform     \$PLATFORM$/'
WB_ANCHOR='/^write_bitstream {\*}\$BITSTREAM_ARGS \$BIT$/'
M="$(t_mutant "$SB" usr-access-honest-stamped)"
if [ -n "$M" ] \
   && t_mutate "$M" "$ST_REL" -e "${WB_ANCHOR}i\\" -e 'set_property BITSTREAM.CONFIG.USR_ACCESS 0xdeadbeef [current_design]' \
   && t_mutate "$M" "$ST_REL" -e "${UA_ANCHOR}a\\" -e 'prov_stage_field usr_access 0xdeadbeef'; then
    t_check bit.usr_access.control.stamped \
        "CONTROL: a stage that stamps 0xdeadbeef and records 0xdeadbeef satisfies the assertion" \
        usr_access_honest "$M"
else
    t_skip bit.usr_access.control.stamped "could not plant the control: the write_bitstream or platform anchor line has changed shape"
fi

# An honest stage that does not stamp and says so.
M="$(t_mutant "$SB" usr-access-honest-unstamped)"
if [ -n "$M" ] \
   && t_mutate "$M" "$ST_REL" -e "${UA_ANCHOR}a\\" -e 'prov_stage_field usr_access "not stamped: this flow sets no BITSTREAM.CONFIG.USR_ACCESS, the register holds the tool default"'; then
    t_check bit.usr_access.control.unstamped \
        "CONTROL: a stage that stamps nothing and records 'not stamped: <why>' satisfies the assertion" \
        usr_access_honest "$M"
else
    t_skip bit.usr_access.control.unstamped "could not plant the control: the platform anchor line has changed shape"
fi

# -- THE DISHONEST SHAPES, REJECTED ----------------------------------------
# build_provenance.tcl:275-278, transplanted: strip `-dirty`, take the low 8
# hex digits, write them as the stamp. No set_property anywhere. The fixture
# tree IS dirty, so the suffix is there to strip.
if [ "$GIT_OK" = 1 ]; then
    M="$(t_mutant "$SB" usr-access-fabricated)"
    if [ -n "$M" ] \
       && t_mutate "$M" "$ST_REL" -e "${UA_ANCHOR}a\\" \
            -e 'set __ua_sha [string map {-dirty {}} [exec git -C [flow_env FPGA_PROJECT_ROOT] describe --always --dirty --abbrev=40]]\' \
            -e 'prov_stage_field usr_access "0x[string range $__ua_sha end-7 end]"'; then
        t_check_fail bit.usr_access.mutation.fabricated \
            "the legacy flow's fault verbatim - usr_access computed from the sha with -dirty stripped, nothing stamped - is rejected" \
            bit_proof usr_access_honest "$M"
    else
        t_skip bit.usr_access.mutation.fabricated "could not plant the fault: the platform anchor line has changed shape"
    fi
else
    t_skip bit.usr_access.mutation.fabricated "no git on PATH - the legacy fabrication is arithmetic on a git sha, and there is no repository to take one from"
fi

# Stamped one value, recorded another.
M="$(t_mutant "$SB" usr-access-mismatch)"
if [ -n "$M" ] \
   && t_mutate "$M" "$ST_REL" -e "${WB_ANCHOR}i\\" -e 'set_property BITSTREAM.CONFIG.USR_ACCESS 0xdeadbeef [current_design]' \
   && t_mutate "$M" "$ST_REL" -e "${UA_ANCHOR}a\\" -e 'prov_stage_field usr_access 0x00000001'; then
    t_check_fail bit.usr_access.mutation.mismatch \
        "a stage that stamps 0xdeadbeef and records 0x00000001 - a value the device does not carry - is rejected" \
        bit_proof usr_access_honest "$M"
else
    t_skip bit.usr_access.mutation.mismatch "could not plant the fault: the write_bitstream or platform anchor line has changed shape"
fi


#=============================================================================
# 6. post_bitstream FIRES AFTER THE .bit IS WRITTEN, AND BEFORE THE RECORD
#
# CONTRACT.md section 6.1.3: every other post_ seam fires BEFORE its stage's
# writes; this one cannot, because the write IS the stage. templates/hooks/
# README.md warns that a hook here cannot change what ships. The suite asserts
# the ORDER the warning describes - the hook fixture records what the .bit
# looked like at the instant the seam fired, and the stub log records what came
# before it - and that the hook still lands in the manifest's hooks_run, which
# is what puts it before the manifest.
#=============================================================================
t_head "post_bitstream fires after write_bitstream, sees the .bit, and is recorded"

## seam_after_write <toolkit>
seam_after_write() {
    local tk="$1" wb hk line v
    bit_run "$tk" seam zynqmp || return 1
    [ "$BR_RC" -eq 0 ] || { show_run; return 1; }
    hk="$(stub_line '^HOOK post_bitstream ')"
    [ -n "$hk" ] || { printf 'the post_bitstream hook never ran. A hook file was in HOOKS_DIR:\n'; show_run; return 1; }
    wb="$(stub_line '^write_bitstream ')"
    [ -n "$wb" ] || { printf 'write_bitstream was never called:\n'; show_run; return 1; }
    [ "$wb" -lt "$hk" ] || {
        printf 'post_bitstream (stub line %s) fired BEFORE write_bitstream (line %s). The seam is\n' "$hk" "$wb"
        printf 'terminal by definition: a hook there cannot change what ships, and the README\n'
        printf 'says so. Fired first, it would be the one seam whose hook CAN - silently:\n'; show_run; return 1; }
    line="$(sed -n "${hk}p" "$BR_STUB")"
    case "$line" in
        *"bit_exists=1"*) ;;
        *) printf 'the hook fired and saw no .bit on disk: %s\n' "$line"; show_run; return 1 ;;
    esac
    case "$line" in
        *"bit_bytes=0"*|*"bit_bytes=0 "*) printf 'the hook fired over a zero-byte .bit: %s\n' "$line"; return 1 ;;
    esac
    v="$(bit_mf "$BR_MAN" hooks_run)"
    case "$v" in
        *"post_bitstream("*) ;;
        *) printf "the hook ran and the manifest's hooks_run says '%s'. A result that a hook shaped\n" "$v"
           printf 'has to trace to the hook, and this is the field that does it.\n'; return 1 ;;
    esac
    return 0
}

t_check bit.seam.post_bitstream \
    "the hook fires after write_bitstream, sees a non-empty .bit, and is recorded in hooks_run" \
    seam_after_write "$FLOW_DIR"

# THE SEAM MOVED to before the write. Two edits, one fault: the same call at
# the other side of write_bitstream.
M="$(t_mutant "$SB" seam-before-write)"
if [ -n "$M" ] \
   && t_replace_line "$M" "$ST_REL" 'flow_hook post_bitstream' '# seam moved by t_bitstream.sh' \
   && t_mutate "$M" "$ST_REL" -e "${WB_ANCHOR}i\\" -e 'flow_hook post_bitstream'; then
    t_check_fail bit.seam.post_bitstream.mutation.moved \
        "with the seam moved before write_bitstream the hook sees no .bit, so the assertion goes red" \
        bit_proof seam_after_write "$M"
else
    t_skip bit.seam.post_bitstream.mutation.moved "could not plant the fault: the flow_hook or write_bitstream line has changed shape"
fi

# THE SEAM DELETED. A hook in HOOKS_DIR then never runs, and the manifest
# says (none) - which reads exactly like a project that has no hooks.
M="$(t_mutant "$SB" seam-removed)"
if [ -n "$M" ] && t_replace_line "$M" "$ST_REL" 'flow_hook post_bitstream' '# seam removed by t_bitstream.sh'; then
    t_check_fail bit.seam.post_bitstream.mutation.removed \
        "with the seam deleted the hook never fires and hooks_run says (none), so the assertion goes red" \
        bit_proof seam_after_write "$M"
else
    t_skip bit.seam.post_bitstream.mutation.removed "could not plant the fault: the flow_hook post_bitstream line has changed shape"
fi


#=============================================================================
# 7. THE INPUT: A MISSING CHECKPOINT IS A REFUSAL THAT LEAVES A RECORD, AND A
#    CHECKPOINT ANOTHER RUN'S MANIFEST DOES NOT DESCRIBE IS ACCEPTED (DEFECT)
#
# CONTRACT.md section 10: exit 2 is "refused, nothing measured", exit 1 is "a
# check ran and failed". A stage with no routed checkpoint has measured nothing,
# and section 12.2.7 asks it to leave a record saying so, so that assert-stage
# can tell "refused" from "died". Both halves are asserted: the exact exit code
# from the shell, the record from disk, and NO tool call in between.
#
# The second half is the cross-check the brief asks for and the stage does not
# have. impl writes `dcp_bytes` into impl_manifest.txt for exactly the reason
# ci/assert-stage.sh's impl.dcp.consistent gate reads it: to pair the record
# with the file. The bitstream stage reads the file and never the record, so a
# routed checkpoint left over from another run - a different design, an older
# route - is opened and written out with a manifest that pins its hash and says
# nothing about the disagreement. That is the provenance defect class
# t_provenance.sh's header is written from, one stage later. Recorded as a
# KNOWN DEFECT; the control mutant shows the shape of the fix (nine lines,
# reading the impl manifest beside the checkpoint) and that the predicate is
# satisfiable.
#=============================================================================
t_head "no routed checkpoint: exit 2, a record of the refusal, and no tool call"

## dcp_refused <toolkit> - absent and zero-byte
dcp_refused() {
    local tk="$1" mode v
    for mode in absent zero; do
        bit_run "$tk" dcp-$mode zynqmp T_DCP_MODE=$mode || return 1
        [ "$BR_RC" -eq 2 ] || {
            printf 'routed checkpoint %s: the stage exited %s, not 2. A missing input is a REFUSAL\n' "$mode" "$BR_RC"
            printf '(nothing measured), not a failed check, and make and ci/lib.sh grade the two\n'
            printf 'differently:\n'; show_run; return 1; }
        ! grep -q '^open_checkpoint' "$BR_STUB" || {
            printf 'routed checkpoint %s: the stage still called open_checkpoint on it:\n' "$mode"; show_run; return 1; }
        v="$(bit_mf "$BR_MAN" stage_status 2>/dev/null)"
        case "$v" in
            "REFUSED:"*) ;;
            *) printf 'routed checkpoint %s: no record of the refusal. CONTRACT.md section 12.2.7 asks the\n' "$mode"
               printf 'stage to leave one, so that "refused" and "died before writing anything" do not\n'
               printf "look the same from disk. stage_status is '%s'; manifest %s\n" "${v:-(absent)}" \
                   "$([ -s "$BR_MAN" ] && echo present || echo ABSENT)"; return 1 ;;
        esac
        grep -qE '^HARD FAILURES: 1$' "$BR_GATE" 2>/dev/null || {
            printf 'routed checkpoint %s: the gate does not record exactly one hard failure:\n' "$mode"
            grep -n 'HARD FAILURES' "$BR_GATE" 2>/dev/null || printf '  (no gate at %s)\n' "$BR_GATE"; return 1; }
    done
    return 0
}

t_check bit.input.dcp_refused \
    "an absent or zero-byte routed checkpoint: exit 2, stage_status REFUSED in the manifest, one hard failure in the gate, no open_checkpoint" \
    dcp_refused "$FLOW_DIR"

# The stage's own check goes dead. flow_assert_input still refuses (exit 2) -
# but it leaves NO RECORD, and that is what the assertion is about: the second
# guard is the one that knows how to write the manifest.
M="$(t_mutant "$SB" dcp-check-dead)"
if [ -n "$M" ] && t_replace_line "$M" "$ST_REL" \
        'if {![file exists $BITSTREAM_ROUTED_DCP] || ![file size $BITSTREAM_ROUTED_DCP]} {' \
        'if {0} {'; then
    t_check_fail bit.input.dcp_refused.mutation \
        "with the stage's own checkpoint test dead the refusal still happens and leaves no record, so the assertion goes red" \
        bit_proof dcp_refused "$M"
else
    t_skip bit.input.dcp_refused.mutation "could not plant the fault: the routed-checkpoint existence test has changed shape"
fi

t_head "known defect: a routed checkpoint that impl_manifest.txt does not describe"

## stale_dcp_refused <toolkit>
## impl_manifest.txt beside the checkpoint says dcp_bytes 999999; the file on
## disk is a few dozen bytes. They are not the same file. An honest stage
## refuses (exit 2) and leaves a record; the real one opens it and ships.
stale_dcp_refused() {
    local tk="$1" v
    bit_run "$tk" stale-dcp zynqmp T_IMPL_DCP_BYTES=999999 || return 1
    if [ "$BR_RC" -eq 0 ]; then
        printf 'impl_manifest.txt says dcp_bytes 999999 and the routed checkpoint on disk is %s bytes.\n' \
            "$(stat -c %s "$BR_OUTDIR/${BR_BLOCK}_routed.dcp")"
        printf 'The stage opened it, wrote a bitstream and exited 0. Nothing in the run says the\n'
        printf 'checkpoint is not the one implementation recorded.\n'; return 1
    fi
    [ "$BR_RC" -eq 2 ] || { printf 'the stage stopped with exit %s, not a refusal (2):\n' "$BR_RC"; show_run; return 1; }
    v="$(bit_mf "$BR_MAN" stage_status 2>/dev/null)"
    case "$v" in "REFUSED:"*) ;; *) printf "refused without a record (stage_status '%s')\n" "${v:-(absent)}"; return 1 ;; esac
    ! grep -q '^open_checkpoint' "$BR_STUB" || { printf 'refused AFTER opening the checkpoint:\n'; show_run; return 1; }
    return 0
}

t_known_defect bit.input.stale_dcp \
    "a routed checkpoint whose size disagrees with impl_manifest.txt's dcp_bytes is refused (exit 2) with a record, before any tool call" \
    stale_dcp_refused "$FLOW_DIR"

# The control: the cross-check, added after the checkpoint is pinned. Reads
# the impl manifest from the run the checkpoint came from (IN_WORK_DIR's
# sibling), compares dcp_bytes with the file, refuses through stage_stop.
DCP_ANCHOR='/^set ::PROV_FILES \[list routed_dcp \$BITSTREAM_ROUTED_DCP\]$/'
M="$(t_mutant "$SB" stale-dcp-crosscheck)"
if [ -n "$M" ] && t_mutate "$M" "$ST_REL" -e "${DCP_ANCHOR}a\\" \
        -e 'set __im [file join [file dirname $IN_WORK_DIR] reports impl_manifest.txt]\' \
        -e 'if {[file exists $__im]} {\' \
        -e '    set __fh [open $__im r]; set __want ""\' \
        -e '    while {[gets $__fh __l] >= 0} { if {[lindex $__l 0] eq "dcp_bytes"} { set __want [lindex $__l 1] } }\' \
        -e '    close $__fh\' \
        -e '    if {$__want ne "" && $__want ne [file size $BITSTREAM_ROUTED_DCP]} {\' \
        -e '        stage_stop bitstream "the routed checkpoint is not the one impl_manifest.txt describes" [list "impl_manifest.txt records dcp_bytes $__want and the checkpoint on disk is [file size $BITSTREAM_ROUTED_DCP] bytes - not the same file"]\' \
        -e '    }\' \
        -e '}'; then
    t_check bit.input.stale_dcp.control \
        "CONTROL: with a nine-line cross-check against impl_manifest.txt the stale checkpoint is refused with a record, so the assertion is satisfiable" \
        stale_dcp_refused "$M"
else
    t_skip bit.input.stale_dcp.control "could not plant the control: the PROV_FILES anchor line has changed shape"
fi


#=============================================================================
# 8. THE OTHER TWO ARTEFACT GATES: PROBES WITH DEBUG CORES, .hwh ON PYNQ
#
# Both are "the board programs and the thing you wanted is silently missing":
# an ILA with no .ltx is an anonymous waveform, a PYNQ overlay with no .hwh
# cannot load. The stage writes the .ltx when the image has cores and refuses
# when it has cores and no probe file; it refuses a pynq platform with no .hwh.
#=============================================================================
t_head "debug cores need a .ltx; a pynq platform needs a .hwh"

## ltx_with_cores <toolkit>
ltx_with_cores() {
    local tk="$1" v n
    bit_run "$tk" ltx zynqmp T_DEBUG_CORES=2 || return 1
    [ "$BR_RC" -eq 0 ] || { show_run; return 1; }
    [ -s "$BR_OUTDIR/$BR_BLOCK.ltx" ] || { printf 'two debug cores and no .ltx at %s:\n' "$BR_OUTDIR/$BR_BLOCK.ltx"; ls -l "$BR_OUTDIR"; return 1; }
    n="$(stat -c %s "$BR_OUTDIR/$BR_BLOCK.ltx")"
    v="$(bit_mf "$BR_MAN" ltx_bytes)"; [ "$v" = "$n" ] || { printf "manifest ltx_bytes '%s', file is %s bytes\n" "$v" "$n"; return 1; }
    v="$(bit_mf "$BR_MAN" debug_cores)"; [ "$v" = 2 ] || { printf "manifest debug_cores '%s', the tool reported 2\n" "$v"; return 1; }
    # ...and cores with the probe file switched off is a hard failure, not a
    # warning: the image ships and the cores in it cannot be used.
    bit_run "$tk" ltx-off zynqmp T_DEBUG_CORES=2 BITSTREAM_WRITE_LTX=0 || return 1
    [ "$BR_RC" -ne 0 ] || { printf 'two debug cores, BITSTREAM_WRITE_LTX=0, and the stage exited 0:\n'; show_run; return 1; }
    grep -qE '^  - 2 debug core\(s\) are in this image and there is no \.ltx' "$BR_GATE" 2>/dev/null || {
        printf 'no hard-failure bullet about the missing probe file:\n'; sed -n '/^HARD FAILURES/,/^BUDGETS/p' "$BR_GATE" 2>/dev/null; return 1; }
    return 0
}

## pynq_needs_hwh <toolkit>
pynq_needs_hwh() {
    local tk="$1"
    bit_run "$tk" pynq zynqmp T_HWH=0 FPGA_PLATFORM=pynq || return 1
    [ "$BR_RC" -ne 0 ] || { printf 'PLATFORM=pynq, no .hwh anywhere, and the stage exited 0. The overlay cannot load:\n'; show_run; return 1; }
    grep -qE '^  - PLATFORM is pynq and this design produced no \.hwh' "$BR_GATE" 2>/dev/null || {
        printf 'no hard-failure bullet about the missing .hwh:\n'; sed -n '/^HARD FAILURES/,/^BUDGETS/p' "$BR_GATE" 2>/dev/null; return 1; }
    return 0
}

t_check bit.ltx "with debug cores the .ltx is written and measured; with BITSTREAM_WRITE_LTX=0 it is a hard failure" ltx_with_cores "$FLOW_DIR"
t_check bit.gate.pynq_hwh "PLATFORM=pynq with no .hwh is a hard failure" pynq_needs_hwh "$FLOW_DIR"

M="$(t_mutant "$SB" ltx-not-gated)"
if [ -n "$M" ] && t_replace_line "$M" "$ST_REL" \
        'if {$DEBUG_CORES > 0 && ![file exists $LTX]} {' \
        'if {0} {'; then
    t_check_fail bit.ltx.mutation \
        "with the probe-file gate dead an image with cores and no .ltx passes, so the assertion goes red" \
        bit_proof ltx_with_cores "$M"
else
    t_skip bit.ltx.mutation "could not plant the fault: the debug-cores/.ltx gate line has changed shape"
fi

M="$(t_mutant "$SB" pynq-not-gated)"
if [ -n "$M" ] && t_replace_line "$M" "$ST_REL" \
        'if {$PLATFORM eq "pynq" && $HWH eq ""} {' \
        'if {0} {'; then
    t_check_fail bit.gate.pynq_hwh.mutation \
        "with the pynq/.hwh gate dead an overlay with no .hwh passes, so the assertion goes red" \
        bit_proof pynq_needs_hwh "$M"
else
    t_skip bit.gate.pynq_hwh.mutation "could not plant the fault: the pynq/.hwh gate line has changed shape"
fi


#=============================================================================
# 9. A HAZARD THE STEP FILE DOCUMENTS AND NOTHING CHECKS
#
# flow/steps/bitstream_opts.tcl's header lists four things a project override
# MUST still do, and puts this one first, in capitals, as "THE LOAD-BEARING
# SECTION OF THE FILE":
#
#     1. SET CFGBVS AND CONFIG_VOLTAGE. Section 1 is the whole reason this
#        file is a step of its own. Omitting them produces a bitstream Vivado
#        writes without complaint and that a device may refuse to configure
#        from.
#
# The toolkit's own copy enforces it on itself - it DIES when nothing states
# them. An OVERRIDE replaces that file wholesale, and the stage's acceptance
# test for an override is `::BITSTREAM_OPTS_DONE` plus the EXISTENCE of three
# variables. None of that is section 1. So an override that keeps the letter
# and drops the load-bearing part is accepted in silence: write_bitstream
# reports the absence as DRC CFGBVS-1, which is a WARNING, the run exits 0,
# every artefact assertion in this file passes, and the failure appears at the
# board hours later with nothing in the log pointing here.
#
# THIS IS THE SAME CLASS AS usr_access, one level out: a file that documents a
# hazard, names the remedy, and never checks the remedy was applied. The
# difference is that here the remedy is a property on the design, so the
# manifest CAN be asked - `bitstream_props` is the transcript section 4 already
# proves faithful, and CFGBVS is either in it or it is not.
#
# Recorded, not fixed: this suite does not own the stage. The control beside it
# is nine lines and shows the assertion is satisfiable.
#=============================================================================
t_head "known defect: an override may drop the section the step file calls load-bearing"

## override_sets_config_bank <toolkit>
## A project override that satisfies every check the stage makes, and never
## sets the two properties that decide whether the device configures.
override_sets_config_bank() {
    local tk="$1" props
    bit_run "$tk" ovr-opts zynqmp T_OVERRIDE_OPTS=1 || return 1
    # THE OVERRIDE IS IN FORCE, read from the STAGE LOG and not from the
    # manifest. flow_step announces every step file and its source as it
    # sources it, which is the one piece of evidence available on BOTH
    # outcomes - a stage that refuses over the missing properties never reaches
    # its manifest, and keying on the manifest would make the honest answer
    # indistinguishable from a fixture that did not plant the override.
    grep -q 'step file: bitstream_opts (PROJECT OVERRIDE)' "$BR_OUT" 2>/dev/null || {
        printf 'the override was not in force, so this predicate measured the toolkit step file:\n'
        grep -n 'step file:' "$BR_OUT" 2>/dev/null || printf '  (the stage logged no step file at all)\n'
        return 1; }
    if [ "$BR_RC" -ne 0 ]; then
        # Refused. That is one honest answer, and it needs no further checking.
        return 0
    fi
    props="$(bit_mf "$BR_MAN" bitstream_props)"
    case " $props " in
        *" CFGBVS "*) return 0 ;;
    esac
    printf 'an override replaced bitstream_opts, set no CFGBVS and no CONFIG_VOLTAGE, and the\n'
    printf 'stage wrote a bitstream and exited 0. bitstream_props records:\n  %s\n' "${props:-(nothing)}"
    printf 'The step file calls that section LOAD-BEARING and tells an override it MUST keep\n'
    printf 'it; the stage accepts BITSTREAM_OPTS_DONE and three variable names instead.\n'
    printf 'write_bitstream reports the absence as CFGBVS-1, a WARNING - so the run is green,\n'
    printf 'the artefacts all exist, and the device configures unreliably or not at all.\n'
    return 1
}

t_known_defect bit.override.config_bank \
    "an override that sets no CFGBVS/CONFIG_VOLTAGE is refused, or the stage records that the config bank was never stated" \
    override_sets_config_bank "$FLOW_DIR"

# The control: the stage asserts what the step file's header already requires,
# in the same place it asserts BITSTREAM_OPTS_DONE and for the same reason.
M="$(t_mutant "$SB" opts-must-state-config-bank)"
if [ -n "$M" ] && t_mutate "$M" "$ST_REL" \
        -e '/^foreach v {BITSTREAM_ARGS BITSTREAM_PROPS BITSTREAM_BIN_STYLE} {$/i\' \
        -e 'foreach __cb {CFGBVS CONFIG_VOLTAGE} {\' \
        -e '    if {[lsearch -exact $::BITSTREAM_PROPS $__cb] < 0} {\' \
        -e '        die "bitstream_opts set no $__cb." "  An override must keep section 1: without it write_bitstream raises DRC CFGBVS-1, which is only a WARNING, and the device configures unreliably or not at all."\' \
        -e '    }\' \
        -e '}'; then
    t_check bit.override.config_bank.control \
        "CONTROL: with the stage asserting CFGBVS/CONFIG_VOLTAGE reached the design, the override is refused - so the assertion is satisfiable" \
        override_sets_config_bank "$M"
else
    t_skip bit.override.config_bank.control "could not plant the control: the bitstream_opts variable-existence loop has changed shape"
fi


t_summary
