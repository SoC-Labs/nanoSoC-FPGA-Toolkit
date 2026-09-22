#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# t_packs.sh - part/pack_api.tcl, the three shipped part packs, and the two
#              scripts that read them from outside Vivado
#
# DEFECT CLASS: A PACK THAT DESCRIBES A DEVICE THAT DOES NOT EXIST, AND A
# VALIDATOR THAT SAYS NOTHING ABOUT IT.
#
# Vivado SILENTLY RETARGETS legacy 7-series primitives on UltraScale(+). Ask for
# an MMCME2_ADV on xck26 and you get an MMCME4_ADV; ask for a PLLE2_ADV and you
# do not get a PLL at all, you get the MMCM; ask for a BUFHCE and you get a
# BUFGCTRL, WHICH HAS NO CLOCK ENABLE. Each succeeds. Each prints one
# [Coretcl 2-1024] into a log with thousands of lines. A part pack naming one of
# them is a pack that is wrong about the silicon, and every consumer inherits
# the error - which is the entire reason part/pack_api.tcl section 6 exists.
#
# This suite is the converted form of test/pending/pack_api_verify.sh, which is
# deleted by the same change that adds this file - test/pending existed to hold
# verification that was real and not yet in the harness, and holding it twice is
# how two copies come to disagree. The conversion is the point rather than a
# tidy-up. That script was written by the author of the code it checks, was run,
# and scored 37/38. Two things were wrong with it and only one was visible:
#
#   * ITS ONE FAILURE - `probe relative path from wrong cwd` - depended on the
#     current working directory being wrong. Moving the file out of a scratchpad
#     and into the repository made the directory no longer wrong, the relative
#     path resolved, and the assertion inverted. IT HAD BEEN PASSING FOR A
#     REASON THAT HAD NOTHING TO DO WITH WHAT IT CLAIMED TO TEST. The cwd is
#     PINNED here (section 11), and both directions are asserted.
#   * ITS MUTATIONS WERE `sed -i` CALLS WHOSE RETURN VALUE NOBODY READ. A sed
#     expression that stops matching - because somebody realigned a column in a
#     pack - changes nothing, the pack then loads cleanly, and a proof that the
#     validator rejects a fault reports that the validator accepted... nothing.
#     Every mutation here goes through t_mutate or t_replace_line, which FAIL
#     LOUDLY when they change nothing, and every one of those failures is a SKIP
#     WITH THE REASON rather than a green line.
#
# THE SHAPE OF EVERY PROOF BELOW, and it is two layers deep because the subject
# is a validator:
#
#   1. a fault is planted in a COPY OF A PACK, and the loader must REJECT it
#      AND SAY WHY in words that name the key. Any old error will not do: a pack
#      with a Tcl typo also fails to load.
#   2. the GUARD that made that rejection happen is then neutered in a COPY OF
#      THE TOOLKIT, and assertion 1 must go RED. Without layer 2 an assertion
#      passes as happily against a validator whose check has been deleted, which
#      is the exact failure this repository's third rule was written from.
#
# A note on cost: layer 1 copies one 300-line pack file, layer 2 copies the
# 1.4MB toolkit. Several layer-2 mutants are deliberately shared by a family of
# assertions - one fault per copy, several proofs from it - because that is what
# "these assertions measure THIS guard" means.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/lib/harness.sh
. "$HERE/../lib/harness.sh"

t_sandbox; SB="$T_SANDBOX"
TCLSH="${TCLSH:-tclsh}"

#-----------------------------------------------------------------------------
# WHAT HAS TO BE HERE, AND WHAT HAPPENS WHEN IT IS NOT.
#
# Both are SKIPS WITH THE REASON and never passes. A missing pack_api.tcl is the
# concurrent-authoring case this repository lives with; a missing tclsh is an
# environment fact, and reporting "the packs are fine" on a host that could not
# read one of them is the shape of a green run that measured nothing.
#-----------------------------------------------------------------------------
if [ ! -f "$FLOW_DIR/part/pack_api.tcl" ]; then
    t_skip packs.all "no $FLOW_DIR/part/pack_api.tcl - nothing to test, and an absent file is not a passing one"
    t_summary; exit $?
fi
if ! command -v "$TCLSH" >/dev/null 2>&1; then
    t_skip packs.all "no tclsh on this host, so the pack API cannot be sourced at all. That is the probe failing to run, which is not a verdict on the packs"
    t_summary; exit $?
fi

#-----------------------------------------------------------------------------
# DRIVERS
#
# Every Tcl body runs in a FRESH tclsh. pack_api.tcl guards itself with
# ::pack_api_loaded and keeps the loaded pack in globals, so a second load in
# one interpreter would be measuring the first pack's leftovers - and the
# `interp alias` block at the bottom of the file refuses to bind a name twice,
# so a shared interpreter would not even get that far.
#
# The FPGA_* variables are UNSET rather than left alone. This suite runs inside
# projects as well as in a bare checkout, and an inherited FPGA_DIR would add a
# board root that changes which packs `pack_roots` can see - which is precisely
# what section 9 measures.
#-----------------------------------------------------------------------------
_n=0
pack_run() {            # pack_run <toolkit> <tcl body...>
    local tk="$1"; shift
    _n=$((_n + 1))
    local f="$SB/drive.$_n.tcl"
    { printf 'source [file join {%s} part pack_api.tcl]\n' "$tk"
      printf '%s\n' "$@"
    } > "$f"
    env -u FPGA_DIR -u FPGA_BOARD_DIR -u FPGA_PART_DIR -u FPGA_RUN_DIR \
        -u FPGA_WORK_DIR -u FPGA_SEAMS_FILE \
        FPGA_FLOW_DIR="$tk" FPGA_PACK_ALLOW_MISSING_ENV=1 "$TCLSH" "$f" 2>&1
}

## pack_loads <toolkit> <role> <spec>  - the pack loads AND validates
pack_loads() {
    local tk="$1" role="$2" spec="$3" out rc=0
    out="$(pack_run "$tk" \
        "$(printf 'if {[catch {%s_load {%s}} e]} { puts $e; exit 1 }' "$role" "$spec")" \
        'exit 0')" || rc=$?
    [ "$rc" -eq 0 ] && return 0
    printf 'the %s pack at %s did not load:\n%s\n' "$role" "$spec" "$out"
    return 1
}

## pack_rejects <toolkit> <role> <spec> <needle>...
##
## The loader must REFUSE, and the message must contain EVERY needle. Asserting
## on the message and not merely on the exit status is not fussiness: a pack
## with an unbalanced brace also fails to load, and a proof satisfied by any
## non-zero exit would stay green on a checkout where the guard it was aimed at
## had been deleted and something unrelated was broken instead.
pack_rejects() {
    local tk="$1" role="$2" spec="$3"; shift 3
    local out rc=0 needle
    out="$(pack_run "$tk" \
        "$(printf 'if {[catch {%s_load {%s}} e]} { puts $e; exit 1 }' "$role" "$spec")" \
        'puts "LOADED CLEANLY"' 'exit 0')" || rc=$?
    if [ "$rc" -eq 0 ]; then
        printf 'the %s pack at %s LOADED - the planted fault was accepted.\n' "$role" "$spec"
        return 1
    fi
    for needle in "$@"; do
        if ! printf '%s' "$out" | grep -qF -- "$needle"; then
            printf 'rejected, but the message does not contain "%s":\n%s\n' "$needle" "$out"
            return 1
        fi
    done
    return 0
}

## pack_copy <name> <source pack file> <role>  -> prints the sandbox pack DIR
##
## The artefact under test in a layer-1 proof is the PACK, so the copy is of the
## pack and the validator is the shipped one. It still lands in the sandbox,
## because t_mutate refuses to edit anything outside one and this suite is not
## going to be the file that talks it into an exception.
pack_copy() {
    local name="$1" src="$2" role="$3"
    # SEPARATE `local` STATEMENTS, not one with four assignments. `local`
    # is a builtin and its arguments are EXPANDED BEFORE any of them are
    # assigned, so `local name="$1" d="$SB/packs/$name"` reads whatever `name`
    # the CALLER happened to have - which under `set -u` is an unbound-variable
    # error at some call sites and, at the ones where the caller does have a
    # `name`, a copy silently made in the wrong directory. Measured here.
    local d="$SB/packs/$name"
    rm -rf "$d"; mkdir -p "$d" || return 2
    cp "$src" "$d/$role.tcl" || return 2
    printf '%s' "$d"
}

## pack_fault <id> <desc> <role> <src pack> <sed expr> <needle>...
##
## LAYER 1, in one place because there are two dozen of them and two dozen
## copies of the same eight lines is how one of them comes to be subtly
## different. Same shape as t_verdicts.sh's mutation blocks:
##   * the fault goes into a copy, inside the sandbox
##   * t_mutate fails loudly when the expression matches nothing, and that is a
##     SKIP WITH THE REASON - a fault that was never planted leaves the
##     assertion below unable to fail, which is worse than not running it
##   * the assertion names the words the message has to carry
pack_fault() {
    local id="$1" desc="$2" role="$3" src="$4" expr="$5"; shift 5
    local name="${id//./_}" d
    d="$(pack_copy "$name" "$src" "$role")" || {
        t_skip "$id" "could not copy $src into the sandbox"; return 0; }
    if t_mutate "$SB" "packs/$name/$role.tcl" "$expr"; then
        t_check "$id" "$desc" pack_rejects "$FLOW_DIR" "$role" "$d" "$@"
    else
        t_skip "$id" "could not plant the fault: '$expr' matches nothing in $(basename "$(dirname "$src")")/$(basename "$src") any more, so the assertion below could not fail"
    fi
}

PART7=$FLOW_DIR/part/xc7z020clg400-1/part.tcl
PARTU=$FLOW_DIR/part/xck26-sfvc784-2LV-c/part.tcl
PARTK=$FLOW_DIR/part/xcku115-flvb1760-1-c/part.tcl

#-----------------------------------------------------------------------------
# THE BOARD FIXTURE.
#
# WRITTEN HERE, NOT SHIPPED AS A FILE. The rescued script it replaces scored
# 38/38 in a scratchpad and 30/38 an hour later from the repository, because
# eight of its fixtures had been left behind in the scratchpad. A fixture that
# can be left behind will be. This one cannot: it is in the suite that needs it.
#
# It names nothing real. CONTRACT.md section 1 forbids this repository from
# naming a board, and a fixture is part of this repository.
#-----------------------------------------------------------------------------
mkdir -p "$SB/board-src" "$SB/vendor-board-files"
cat > "$SB/board-src/board.tcl" <<'BOARD_FIXTURE'
# A BOARD PACK FIXTURE. Lives in a scratch project, never in the toolkit:
# CONTRACT.md section 1 says a board pack ships with the project.
board_set board_name      testbench-board
board_set part            xck26-sfvc784-2LV-c
board_set platform        bare
board_set sys_clk_freq_hz 50000000
board_set bin_style       zynqmp
board_set oscillator_hz   25000000
board_set board_rev       revA
board_set io_voltage_by_bank {44 1.8 64 3.3}
board_set deploy_style    jtag

# THE SITE PATH. Never defaulted, never a literal: it arrives through board_env,
# which records the attempt whether it resolves or not.
board_set board_part "vendor:testbench:part0:1.0"
board_defer board_repo_paths {
    set root [board_env TESTBENCH_BOARD_FILES "the vendor board files for testbench-board"]
    if {![file isdirectory $root]} { error "not a directory: $root" }
    return $root
}
board_note {fixture pack, used by the pack API's own mutation tests}
BOARD_FIXTURE
BOARD=$SB/board-src/board.tcl
mkdir -p "$SB/boards/testbench-board"
cp "$BOARD" "$SB/boards/testbench-board/board.tcl"
BOARD_DIR=$SB/boards/testbench-board


#=============================================================================
# 1. THE SHIPPED PACKS LOAD AND VALIDATE - AND SO DOES A BOARD PACK
#
# The good case for everything below it. A validator that rejected a correct
# pack would make every layer-1 proof in this file pass for the wrong reason.
#=============================================================================
t_head "the shipped packs load and validate, and so does the other role"

## installed_part_packs <toolkit root> - every directory under part/ holding a
## part.tcl, globbed exactly as pack_installed globs them.
##
## DERIVED, AND IT DID NOT USED TO BE. This block named its three packs, one
## t_check each, for as long as there were three - so when a FOURTH pack was
## added (xcvu19p, 2026-09-17) it shipped with NO load assertion at all and the
## suite stayed green at 86 passed. That is CONTRACT.md's third rule broken
## inside the suite that exists to enforce it, and it is the reference
## toolkit's five-entry-whitelist defect exactly: a list that is merely
## INCOMPLETE still prints something plausible and says nothing about what it
## missed. Section 9 below already plants a fourth pack to prove the ENGINE's
## enumeration reads the directory; this one is the suite reading it too.
installed_part_packs() {
    local d
    for d in "$1"/part/*/; do
        [ -f "${d}part.tcl" ] || continue
        basename "$d"
    done
}

N_PACKS="$(installed_part_packs "$FLOW_DIR" | grep -c .)"
t_say "$N_PACKS part pack(s) installed under part/, found by glob"

# AN EMPTY LOOP ASSERTS NOTHING AND LOOKS GREEN. If part/ ever holds no pack -
# a bad checkout, a renamed directory - the loop below runs zero times and this
# suite would report a clean bill of health for packs it never opened.
t_check packs.load.any \
    "part/ holds at least one pack, so the loop below actually asserts something" \
    test "$N_PACKS" -gt 0

while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    t_check "packs.load.$_p" "part pack $_p loads and validates" \
        pack_loads "$FLOW_DIR" part "$_p"
done < <(installed_part_packs "$FLOW_DIR")

## every_installed_pack_loads <toolkit root>
## The same sweep as one predicate, so the property "this reads the DIRECTORY"
## can be proved. The loop above cannot be: each of its assertions names a pack
## that already exists, so all of them would stay green against a suite that
## had gone back to carrying three names.
every_installed_pack_loads() {
    local root="$1" p n=0 bad=0 out
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        n=$((n + 1))
        if ! out="$(pack_loads "$root" part "$p" 2>&1)"; then
            printf '%s\n' "$out"
            bad=1
        fi
    done < <(installed_part_packs "$root")
    [ "$n" -gt 0 ] || { printf 'no pack under %s/part - NOTHING was validated, which is not the same as nothing being wrong\n' "$root"; return 1; }
    return "$bad"
}

t_check packs.load.derived \
    "every pack the part/ DIRECTORY holds loads and validates - the list is the glob, not a list in this file" \
    every_installed_pack_loads "$FLOW_DIR"

# THE PROOF THAT IT IS THE DIRECTORY. A fifth pack is planted in a copy, and it
# is a pack that CANNOT validate - one required key and nothing else. A suite
# carrying its own list of pack names never opens it and stays green, which is
# precisely how the fourth pack came to ship unasserted.
M="$(t_mutant "$SB" fifth-pack-broken)"
if mkdir -p "$M/part/zz-planted-broken" \
   && printf 'part_set part_name zz-planted-broken\n' > "$M/part/zz-planted-broken/part.tcl"; then
    t_check_fail packs.load.derived.mutation \
        "with an INVALID fifth pack planted in the directory, the sweep goes red - it enumerated it rather than reciting three names" \
        every_installed_pack_loads "$M"
else
    t_skip packs.load.derived.mutation "could not plant a fifth pack directory inside the mutant"
fi

t_check packs.load.board   "a BOARD pack loads through the same engine (CONTRACT.md section 8: two roles, one validator)" \
    pack_loads "$FLOW_DIR" board "$BOARD_DIR"

# The proof that the assertion above is reading the pack rather than reporting
# that tclsh started. One character of a required key, in a copy.
M="$(t_mutant "$SB" pack-loads-good-case)"
if t_mutate "$M" part/xck26-sfvc784-2LV-c/part.tcl 's/^part_set vendor           xilinx/part_set vendor           {}/'; then
    t_check_fail packs.load.xck26.mutation \
        "with vendor blanked in a copy of the pack, the load assertion goes red" \
        pack_loads "$M" part xck26-sfvc784-2LV-c
else
    t_skip packs.load.xck26.mutation "could not plant the fault: 'part_set vendor           xilinx' is no longer in the xck26 pack"
fi


#=============================================================================
# 2. THE SCHEMA IS CLOSED: UNKNOWN KEY, DOUBLE SET, SET-BESIDE-A-DEFERRAL
#
# All three are copy-paste damage rather than intent (CONTRACT.md section 8),
# and all three are silent without a guard: an unknown key is a setting nothing
# ever reads, a second set is the first value quietly replaced, and a set beside
# a deferral is a pack claiming both that it could and that it could not obtain
# a value.
#=============================================================================
t_head "the schema is closed - unknown key, double set, set beside a deferral"

pack_fault packs.schema.unknown_key \
    "an unknown key is refused AND the nearest match is suggested, so a typo points at the right key" \
    part "$PARTU" 's/^part_set mmcm_count     4/part_set mmcm_cont      4/' \
    "unknown key 'mmcm_cont'" "Nearest matches:" "mmcm_count"

pack_fault packs.schema.double_set \
    "setting a key twice is refused, and the message quotes the value it already had" \
    part "$PARTU" 's/^part_set pll_count      8/part_set pll_count 8\npart_set mmcm_count 9/' \
    "already set to '4'"

pack_fault packs.schema.set_beside_defer \
    "setting a key the pack has already DEFERRED is refused - a key is stated or deferred, never both" \
    part "$PARTU" '$a part_set ps_clk_config whatever' \
    "already DEFERRED"

# -- mutation proof ----------------------------------------------------------
# ONE FAULT, TWO PROOFS, ON PURPOSE. pack_set is the single engine both name
# families alias to (pack_api.tcl section 10), so neutering its unknown-key
# guard once must make the part assertion AND the board assertion go red. If
# only one of them moved, the two roles would not be sharing a validator - which
# is the thing section 8 of the contract is trying to prevent, and it fails
# silently because nobody diffs two validators.
M="$(t_mutant "$SB" pack-set-unknown-key)"
P="$(pack_copy mut_unknown_key "$PARTU" part)"
B="$(pack_copy mut_unknown_key_board "$BOARD" board)"
if t_mutate "$M" part/pack_api.tcl \
        '/^proc pack_set /,/^}/ s/^    if {!\[info exists ::pack_schema($role,$k)\]} {$/    if {0} {/' \
   && t_mutate "$SB" packs/mut_unknown_key/part.tcl 's/^part_set mmcm_count     4/part_set mmcm_cont      4/' \
   && t_mutate "$SB" packs/mut_unknown_key_board/board.tcl 's/^board_set board_rev       revA/board_set board_revision  revA/'; then
    t_check_fail packs.schema.unknown_key.mutation \
        "with pack_set's unknown-key guard neutered, the assertion above goes red" \
        pack_rejects "$M" part "$P" "unknown key 'mmcm_cont'"
    t_check_fail packs.schema.unknown_key.mutation.board \
        "and the BOARD role goes red from the SAME fault, which is what 'one engine, two roles' has to mean" \
        pack_rejects "$M" board "$B" "unknown key 'board_revision'"
else
    t_skip packs.schema.unknown_key.mutation "could not plant the fault: pack_set()'s schema test, or one of the two pack lines it is proved with, has changed shape"
    t_skip packs.schema.unknown_key.mutation.board "could not plant the fault: pack_set()'s schema test, or one of the two pack lines it is proved with, has changed shape"
fi

M="$(t_mutant "$SB" pack-set-double-set)"
P="$(pack_copy mut_double_set "$PARTU" part)"
if t_mutate "$M" part/pack_api.tcl \
        '/^proc pack_set /,/^}/ s/^    if {\[info exists ::pack_val($role,$k)\]} {$/    if {0} {/' \
   && t_mutate "$SB" packs/mut_double_set/part.tcl 's/^part_set pll_count      8/part_set pll_count 8\npart_set mmcm_count 9/'; then
    t_check_fail packs.schema.double_set.mutation \
        "with pack_set's already-set guard neutered, a second set is accepted and the assertion goes red" \
        pack_rejects "$M" part "$P" "already set to '4'"
else
    t_skip packs.schema.double_set.mutation "could not plant the fault: pack_set()'s already-set test, or the pll_count line it is proved with, has changed shape"
fi

M="$(t_mutant "$SB" pack-set-beside-defer)"
P="$(pack_copy mut_set_defer "$PARTU" part)"
if t_mutate "$M" part/pack_api.tcl \
        '/^proc pack_set /,/^}/ s/^    if {\[info exists ::pack_defer_script($role,$k)\]} {$/    if {0} {/' \
   && t_mutate "$SB" packs/mut_set_defer/part.tcl '$a part_set ps_clk_config whatever'; then
    t_check_fail packs.schema.set_beside_defer.mutation \
        "with the deferral guard neutered the set silently wins, and the assertion goes red" \
        pack_rejects "$M" part "$P" "already DEFERRED"
else
    t_skip packs.schema.set_beside_defer.mutation "could not plant the fault: pack_set()'s deferral test has changed shape"
fi


#=============================================================================
# 3. A MISSING REQUIRED KEY REPORTS *EVERY* PROBLEM AT ONCE
#
# CONTRACT.md section 8 requires it and the reason is not tidiness: one-at-a-time
# validation turns a five-key mistake into five edit-and-rerun cycles, and the
# cycles are where people give up and start guessing. The rescued script tested
# ONE missing key, which a first-problem-only validator passes just as happily.
# So this plants TWO and requires BOTH by name plus the count.
#=============================================================================
t_head "a missing required key reports every problem at once, not the first"

pack_fault packs.required.one \
    "a missing required key is refused, and the message says what the key is FOR" \
    part "$PARTU" '/^part_set global_buffer         BUFGCTRL/d' \
    "MISSING required key 'global_buffer'" "what it is for:"

P="$(pack_copy required_all "$PARTU" part)"
if t_mutate "$SB" packs/required_all/part.tcl '/^part_set global_buffer         BUFGCTRL/d' \
   && t_mutate "$SB" packs/required_all/part.tcl '/^part_set vendor           xilinx/d'; then
    t_check packs.required.all \
        "TWO missing required keys are BOTH reported, with the count, in one run" \
        pack_rejects "$FLOW_DIR" part "$P" \
        "2 problems" \
        "MISSING required key 'global_buffer'" \
        "MISSING required key 'vendor'" \
        "EVERY problem found is listed above"
else
    t_skip packs.required.all "could not plant both faults: the global_buffer or vendor line in the xck26 pack has changed shape"
fi

# The mutation that matters here is NOT deleting the required-key check - it is
# reporting only the first problem, which is the natural way to write a
# validator and which passes every single-fault test ever written.
M="$(t_mutant "$SB" report-first-only)"
if t_replace_line "$M" part/pack_api.tcl \
        '        foreach p $problems {' \
        '        foreach p [lrange $problems 0 0] {'; then
    t_check_fail packs.required.all.mutation \
        "with the report truncated to the first problem, the two-fault assertion goes red" \
        pack_rejects "$M" part "$P" \
        "MISSING required key 'global_buffer'" "MISSING required key 'vendor'"
else
    t_skip packs.required.all.mutation "could not plant the fault: the problem-report loop in pack_validate() has changed shape"
fi

M="$(t_mutant "$SB" required-not-checked)"
if t_replace_line "$M" part/pack_api.tcl \
        '            if {$req eq "yes" && ![pack_is_deferred $role $k]} {' \
        '            if {0} {'; then
    t_check_fail packs.required.one.mutation \
        "with the required-key test neutered, a pack missing global_buffer loads clean" \
        pack_rejects "$M" part "$SB/packs/packs_required_one" "MISSING required key 'global_buffer'"
else
    t_skip packs.required.one.mutation "could not plant the fault: pack_validate()'s required test has changed shape"
fi


#=============================================================================
# 4. TYPES AND CLOSED VALUE SETS
#
# An empty string is not an omitted key: an omitted key ERRORS when read and a
# blank one is READ AS A VALUE. An empty list is a silent no-op downstream. A
# value outside a closed set is not a new option, it is a typo that reaches the
# tool as something else - and bin_style is the case that earns the mechanism,
# because both of its values "work" and one of them corrupts the load.
#=============================================================================
t_head "types, empties and closed value sets"

pack_fault packs.type.empty_str \
    "a BLANK string is refused - it is read as a value, where an omitted key errors" \
    part "$PARTU" 's/^part_set family_full_name "Zynq UltraScale+"/part_set family_full_name ""/' \
    "EMPTY 'family_full_name'"

pack_fault packs.type.empty_list \
    "an EMPTY LIST is refused - it would assert that the device has no IO banks by accident" \
    part "$PARTU" 's/^part_set io_banks {0 43 44 45 46 64 65 66 224 500 501 502 503 504 505}/part_set io_banks {}/' \
    "EMPTY LIST 'io_banks'"

pack_fault packs.type.bad_int \
    "a non-integer in an int key is refused" \
    part "$PARTU" 's/^part_set luts              117120/part_set luts              117k/' \
    "BAD TYPE 'luts'"

# THE NEEDLE CARRIES THE WHOLE SET, AND grep -F CANNOT ANCHOR IT.
# Measured 2026-09-22: when `none` was added to the enum, this assertion did NOT
# go red, because pack_rejects matches with `grep -qF` and the old needle
# "It must be one of: zynq7 zynqmp" is a PREFIX of the new message. A proof whose
# description says "the whole set is printed" was checking a prefix of it.
# Carrying the full current set makes a REMOVAL visible. An ADDITION appended to
# the end is still invisible to a substring match, and that is a property of the
# harness, not of this line - the proof below is what covers a member actually
# working, and it is the one to add to when the set next grows.
pack_fault packs.enum.bin_style \
    "bin_style outside its CLOSED set is refused and the whole set is printed - the wrong one corrupts the load and nothing says why" \
    board "$BOARD" 's/^board_set bin_style       zynqmp/board_set bin_style       zynq/' \
    "It must be one of: zynq7 zynqmp none"

# ONE FAULT, THREE PROOFS: the type switch is the single place all three type
# checks live, so neutering it must move all three.
M="$(t_mutant "$SB" type-switch-dead)"
if t_replace_line "$M" part/pack_api.tcl '        switch -- $type {' '        switch -- no-such-type {'; then
    t_check_fail packs.type.empty_str.mutation \
        "with the type switch neutered, the blank-string assertion goes red" \
        pack_rejects "$M" part "$SB/packs/packs_type_empty_str" "EMPTY 'family_full_name'"
    t_check_fail packs.type.empty_list.mutation \
        "and the empty-list assertion goes red from the same fault" \
        pack_rejects "$M" part "$SB/packs/packs_type_empty_list" "EMPTY LIST 'io_banks'"
    t_check_fail packs.type.bad_int.mutation \
        "and so does the integer-type assertion" \
        pack_rejects "$M" part "$SB/packs/packs_type_bad_int" "BAD TYPE 'luts'"
else
    t_skip packs.type.empty_str.mutation "could not plant the fault: pack_validate()'s type switch has changed shape"
    t_skip packs.type.empty_list.mutation "could not plant the fault: pack_validate()'s type switch has changed shape"
    t_skip packs.type.bad_int.mutation "could not plant the fault: pack_validate()'s type switch has changed shape"
fi

# bin_style none: A MEMBER THAT WORKS, NOT A STRING THAT IS NOT REFUSED.
#
# The assertion above proves a NON-member is refused. It cannot prove a member is
# ACCEPTED - and the two are different claims, because an enum that accepted
# everything would also pass it. `none` is the case where that matters most: it
# is the one value whose whole purpose is to relax a downstream assertion, so if
# it were quietly not in the set, a board declaring it would be refused at load
# and nobody would learn why from this suite.
NONEPACK="$(pack_copy packs_bin_style_none "$BOARD" board)" || NONEPACK=""
if [ -n "$NONEPACK" ] && t_mutate "$SB" "packs/packs_bin_style_none/board.tcl" \
        's/^board_set bin_style       zynqmp/board_set bin_style       none/'; then
    t_check packs.enum.bin_style.none \
        "bin_style none is a MEMBER of the closed set and a board declaring it loads" \
        pack_loads "$FLOW_DIR" board "$NONEPACK"

    M0="$(t_mutant "$SB" bin-style-none-not-a-member)"
    if t_replace_line "$M0" part/pack_schema.tcl \
            '    board,bin_style    {zynq7 zynqmp none}' \
            '    board,bin_style    {zynq7 zynqmp}'; then
        t_check_fail packs.enum.bin_style.none.mutation \
            "with none taken back out of the closed set, the same board is REFUSED and the assertion above goes red" \
            pack_loads "$M0" board "$NONEPACK"
    else
        t_skip packs.enum.bin_style.none.mutation "could not plant the fault: the bin_style enum line has changed shape"
    fi
else
    t_skip packs.enum.bin_style.none "could not build a board pack declaring bin_style none"
    t_skip packs.enum.bin_style.none.mutation "could not build a board pack declaring bin_style none"
fi

M="$(t_mutant "$SB" enum-not-checked)"
if t_replace_line "$M" part/pack_api.tcl \
        '        if {[info exists ::pack_enum_spec($role,$k)]} {' \
        '        if {0} {'; then
    t_check_fail packs.enum.bin_style.mutation \
        "with the closed-set test neutered, a bin_style of 'zynq' is accepted and the assertion goes red" \
        pack_rejects "$M" board "$SB/packs/packs_enum_bin_style" "It must be one of: zynq7 zynqmp none"
else
    t_skip packs.enum.bin_style.mutation "could not plant the fault: pack_validate()'s enum test has changed shape"
fi


#=============================================================================
# 5. CONDITIONAL CASCADES - THE KEYS A CONFIGURATION MAKES REQUIRED
#
# Four on the part role, two on the board role. Each fires only in one
# configuration, which is exactly why a suite that loaded the shipped packs and
# stopped would never touch one.
#=============================================================================
t_head "conditional cascades, both roles"

pack_fault packs.cascade.has_ps \
    "has_ps true makes ps_type required, and the message states the rule and not just the breach" \
    part "$PARTU" '/^part_set ps_type     PS8/d' \
    "'has_ps' is true makes required" "why the pairing:"

pack_fault packs.cascade.slrs \
    "slrs > 1 makes slr_topology required - on a stacked device the floorplan is part of timing closure" \
    part "$PARTU" 's/^part_set slrs              1/part_set slrs              2/' \
    "'slrs' is >1 makes required"

pack_fault packs.cascade.idelay \
    "idelay_available true makes idelay_primitive required - IDELAYE2 and IDELAYE3 have different tap counts" \
    part "$PARTU" '/^part_set idelay_primitive         IDELAYE3/d' \
    "'idelay_available' is true makes required"

pack_fault packs.cascade.has_mmcm \
    "has_mmcm true makes mmcm_primitive required - 'there is an MMCM' without a name is the whole defect" \
    part "$PARTU" '/^part_set mmcm_primitive MMCME4_ADV/d' \
    "'has_mmcm' is true makes required"

pack_fault packs.cascade.board_part \
    "board_part set makes board_repo_paths required - otherwise the VLNV resolves against whatever is installed on one host" \
    board "$BOARD" '/^board_defer board_repo_paths {/,/^}/d' \
    "'board_part' is set makes required"

pack_fault packs.cascade.fpgahub \
    "fpgahub_board set makes fpgahub_target required - the LEASE scope and the PROGRAM scope are different namespaces" \
    board "$BOARD" '$a board_set fpgahub_board grp' \
    "'fpgahub_board' is set makes required"

# ONE FAULT, SIX PROOFS. The cascade loop is one line; if it stops firing, all
# six configurations become silently unvalidated at once.
M="$(t_mutant "$SB" cascades-never-fire)"
if t_replace_line "$M" part/pack_api.tcl \
        '        if {![pack_cascade_holds $role $trig $op]} { continue }' \
        '        continue'; then
    t_check_fail packs.cascade.has_ps.mutation \
        "with the cascade loop neutered, the has_ps assertion goes red" \
        pack_rejects "$M" part "$SB/packs/packs_cascade_has_ps" "'has_ps' is true makes required"
    t_check_fail packs.cascade.slrs.mutation \
        "and the slrs cascade goes red from the same fault" \
        pack_rejects "$M" part "$SB/packs/packs_cascade_slrs" "'slrs' is >1 makes required"
    t_check_fail packs.cascade.idelay.mutation \
        "and the idelay cascade" \
        pack_rejects "$M" part "$SB/packs/packs_cascade_idelay" "'idelay_available' is true makes required"
    t_check_fail packs.cascade.has_mmcm.mutation \
        "and the has_mmcm cascade" \
        pack_rejects "$M" part "$SB/packs/packs_cascade_has_mmcm" "'has_mmcm' is true makes required"
    t_check_fail packs.cascade.board_part.mutation \
        "and the BOARD role's board_part cascade, from the same single fault" \
        pack_rejects "$M" board "$SB/packs/packs_cascade_board_part" "'board_part' is set makes required"
    t_check_fail packs.cascade.fpgahub.mutation \
        "and the fpgahub cascade" \
        pack_rejects "$M" board "$SB/packs/packs_cascade_fpgahub" "'fpgahub_board' is set makes required"
else
    for g in has_ps slrs idelay has_mmcm board_part fpgahub; do
        t_skip "packs.cascade.$g.mutation" "could not plant the fault: pack_validate()'s cascade loop has changed shape"
    done
fi


#=============================================================================
# 6. CROSS-CHECKS - VALUES THAT ARE INDIVIDUALLY WELL-FORMED AND MUTUALLY WRONG
#
# Every one of these passes a type check, an enum check and a required-key check.
# They are wrong only against another value in the same file, which is why they
# need their own pass and why none of them returns early.
#=============================================================================
t_head "cross-checks: individually well-formed, mutually inconsistent"

pack_fault packs.xcheck.speed_grade \
    "a part_name that does not carry the speed grade is refused - it resolves to a DIFFERENT part or to none" \
    part "$PARTU" 's/^part_set speed_grade      -2LV/part_set speed_grade      -1/' \
    "does not contain the speed"

pack_fault packs.xcheck.temp_grade \
    "a temp_grade the part string does not end with is refused - an absent grade and a commercial grade are different claims" \
    part "$PARTU" 's/^part_set temp_grade       c /part_set temp_grade       i /' \
    "does not end with '-i'"

pack_fault packs.xcheck.bram18 \
    "bram18s that is not twice brams is refused - the two units get compared without anyone noticing the denominators differ" \
    part "$PARTU" 's/^part_set bram18s           288/part_set bram18s           289/' \
    "is not twice brams"

pack_fault packs.xcheck.refclk \
    "an IDELAY reference clock outside every band the pack itself states is refused" \
    part "$PARTU" 's/^part_set idelay_ref_freq_default_hz 300000000/part_set idelay_ref_freq_default_hz 200000000/' \
    "outside every band"

pack_fault packs.xcheck.hz \
    "MHz in a HERTZ key is refused - the firmware and the fabric would agree and both be wrong" \
    board "$BOARD" 's/^board_set sys_clk_freq_hz 50000000/board_set sys_clk_freq_hz 50/' \
    "far too small to be HERTZ"

pack_fault packs.xcheck.fpgahub_ns \
    "fpgahub_board equal to fpgahub_target is refused - one is the LEASE scope and the other the PROGRAM scope" \
    board "$BOARD" '$a board_set fpgahub_board x\nboard_set fpgahub_target x' \
    "DIFFERENT NAMESPACES"

pack_fault packs.xcheck.bank_volts \
    "millivolts in an IO bank VOLTAGE key is refused" \
    board "$BOARD" 's/{44 1.8 64 3.3}/{44 1800 64 3.3}/' \
    "not millivolts"

# ONE FAULT PER ROLE. pack_validate dispatches to one cross-check proc per role;
# neutering the dispatch is the whole layer going quiet, which is what a refactor
# that "simplified" the validator would actually look like.
M="$(t_mutant "$SB" xcheck-part-dead)"
if t_replace_line "$M" part/pack_api.tcl \
        '    if {$role eq "part"}  { pack_crosscheck_part  problems }' \
        '    if {0} { pack_crosscheck_part problems }'; then
    t_check_fail packs.xcheck.speed_grade.mutation \
        "with the part cross-check layer dead, the speed-grade assertion goes red" \
        pack_rejects "$M" part "$SB/packs/packs_xcheck_speed_grade" "does not contain the speed"
    t_check_fail packs.xcheck.temp_grade.mutation \
        "and the temp-grade assertion" \
        pack_rejects "$M" part "$SB/packs/packs_xcheck_temp_grade" "does not end with '-i'"
    t_check_fail packs.xcheck.bram18.mutation \
        "and the bram18 arithmetic" \
        pack_rejects "$M" part "$SB/packs/packs_xcheck_bram18" "is not twice brams"
    t_check_fail packs.xcheck.refclk.mutation \
        "and the IDELAY reference-clock band" \
        pack_rejects "$M" part "$SB/packs/packs_xcheck_refclk" "outside every band"
else
    for g in speed_grade temp_grade bram18 refclk; do
        t_skip "packs.xcheck.$g.mutation" "could not plant the fault: pack_validate()'s part cross-check dispatch has changed shape"
    done
fi

M="$(t_mutant "$SB" xcheck-board-dead)"
if t_replace_line "$M" part/pack_api.tcl \
        '    if {$role eq "board"} { pack_crosscheck_board problems }' \
        '    if {0} { pack_crosscheck_board problems }'; then
    t_check_fail packs.xcheck.hz.mutation \
        "with the board cross-check layer dead, the hertz assertion goes red" \
        pack_rejects "$M" board "$SB/packs/packs_xcheck_hz" "far too small to be HERTZ"
    t_check_fail packs.xcheck.fpgahub_ns.mutation \
        "and the fpgahub namespace collision" \
        pack_rejects "$M" board "$SB/packs/packs_xcheck_fpgahub_ns" "DIFFERENT NAMESPACES"
    t_check_fail packs.xcheck.bank_volts.mutation \
        "and the bank-voltage sanity check" \
        pack_rejects "$M" board "$SB/packs/packs_xcheck_bank_volts" "not millivolts"
else
    for g in hz fpgahub_ns bank_volts; do
        t_skip "packs.xcheck.$g.mutation" "could not plant the fault: pack_validate()'s board cross-check dispatch has changed shape"
    done
fi


#=============================================================================
# 7. READING AN UNSET OPTIONAL IS AN ERROR, NOT ""
#
# CONTRACT.md section 8. An empty primitive name instantiates nothing, an empty
# frequency constrains nothing, an empty path concatenates into a plausible
# wrong one - and all three finish the run. temp_grade is genuinely unset on
# xc7z020clg400-1: its part string carries no temperature grade, and the pack
# leaves the key UNSET rather than blank precisely because the two are different
# claims about the same silicon.
#=============================================================================
t_head "an unset optional key ERRORS rather than returning an empty string"

## unset_optional_errors <toolkit>
unset_optional_errors() {
    local out rc=0
    out="$(pack_run "$1" \
        'part_load xc7z020clg400-1' \
        'if {[catch {part_get temp_grade} e]} { puts $e; exit 1 }' \
        'puts "RETURNED >>>[part_get temp_grade]<<< instead of erroring"' \
        'exit 0')" || rc=$?
    if [ "$rc" -eq 0 ]; then
        printf 'part_get on an unset optional did not error:\n%s\n' "$out"; return 1
    fi
    printf '%s' "$out" | grep -qF "It is an OPTIONAL key" || {
        printf 'it errored, but not with the reason a caller needs:\n%s\n' "$out"; return 1; }
    printf '%s' "$out" | grep -qF "part_has temp_grade" || {
        printf 'the error does not say how to ask the question properly:\n%s\n' "$out"; return 1; }
    return 0
}

## deferred_read_names_the_reason <toolkit>
## A DEFERRED key is a different answer from an absent one, and the pack's own
## sentence about why it could not be obtained is the whole value of the
## mechanism. license_class on xc7z020clg400-1 is a -permanent deferral.
deferred_read_names_the_reason() {
    local out rc=0
    out="$(pack_run "$1" \
        'part_load xc7z020clg400-1' \
        'if {[catch {part_get license_class} e]} { puts $e; exit 1 }' \
        'exit 0')" || rc=$?
    [ "$rc" -ne 0 ] || { printf 'reading a deferred key did not error:\n%s\n' "$out"; return 1; }
    printf '%s' "$out" | grep -qF "NOT OBTAINABLE" && return 0
    printf 'the error does not carry the pack recorded reason:\n%s\n' "$out"
    return 1
}

t_check packs.get.unset_optional \
    "part_get on an unset optional errors, and says to use part_has or part_opt" \
    unset_optional_errors "$FLOW_DIR"
t_check packs.get.deferred \
    "part_get on a PERMANENTLY DEFERRED key errors with the pack's own recorded reason" \
    deferred_read_names_the_reason "$FLOW_DIR"

M="$(t_mutant "$SB" get-returns-empty)"
if t_replace_line "$M" part/pack_api.tcl \
        '    if {[info exists ::pack_val($role,$k)]} { return $::pack_val($role,$k) }' \
        '    if {[info exists ::pack_val($role,$k)]} { return $::pack_val($role,$k) } ; return ""'; then
    t_check_fail packs.get.unset_optional.mutation \
        "with pack_get returning an empty string instead of erroring, the assertion goes red" \
        unset_optional_errors "$M"
    t_check_fail packs.get.deferred.mutation \
        "and a deferred key silently returns empty too, so its assertion goes red" \
        deferred_read_names_the_reason "$M"
else
    t_skip packs.get.unset_optional.mutation "could not plant the fault: pack_get()'s value return has changed shape"
    t_skip packs.get.deferred.mutation "could not plant the fault: pack_get()'s value return has changed shape"
fi


#=============================================================================
# 8. AN UNKNOWN PACK ENUMERATES WHAT IS INSTALLED, FROM THE DIRECTORY
#
# CONTRACT.md rule three: never hardcode a list a directory already knows. The
# reference toolkit hardcodes a five-entry whitelist over a seven-entry
# directory and grew two undocumented override points as a result - and that
# failure is SILENT, because a hardcoded list that is merely INCOMPLETE still
# prints something plausible.
#
# So it is not enough to check that the three shipped packs are named. A fourth
# pack is planted in a copy of the toolkit and must be named too.
#=============================================================================
t_head "an unknown pack enumerates the installed ones, read from the directory"

## unknown_pack_enumerates <toolkit> <name>...
unknown_pack_enumerates() {
    local tk="$1"; shift
    local out rc=0 n
    out="$(pack_run "$tk" \
        'if {[catch {part_load no-such-part} e]} { puts $e; exit 1 }' \
        'exit 0')" || rc=$?
    [ "$rc" -ne 0 ] || { printf 'an unknown pack did not error:\n%s\n' "$out"; return 1; }
    printf '%s' "$out" | grep -qF "Installed under" || {
        printf 'the error does not enumerate anything:\n%s\n' "$out"; return 1; }
    for n in "$@"; do
        printf '%s' "$out" | grep -qF -- "$n" || {
            printf 'the enumeration does not name %s:\n%s\n' "$n" "$out"; return 1; }
    done
    return 0
}

t_check packs.unknown.enumerates \
    "an unknown part pack is refused and every installed pack is named" \
    unknown_pack_enumerates "$FLOW_DIR" \
    xc7z020clg400-1 xck26-sfvc784-2LV-c xcku115-flvb1760-1-c

# THE REFERENCE TOOLKIT'S DEFECT, REPRODUCED: a fourth pack appears in the
# directory and the enumeration has to grow. A hardcoded list would still print
# three plausible names and say nothing about the fourth.
M="$(t_mutant "$SB" fourth-pack)"
if mkdir -p "$M/part/zz-fixture-part" && : > "$M/part/zz-fixture-part/part.tcl"; then
    t_check packs.unknown.enumerates.fourth \
        "a FOURTH pack dropped into part/ is enumerated too - the directory is the authority, not a list in the code" \
        unknown_pack_enumerates "$M" \
        xc7z020clg400-1 xck26-sfvc784-2LV-c xcku115-flvb1760-1-c zz-fixture-part
else
    t_skip packs.unknown.enumerates.fourth "could not create a fourth pack directory inside the mutant"
fi

M="$(t_mutant "$SB" installed-returns-nothing)"
if t_replace_line "$M" part/pack_api.tcl '    return $have' '    return {}'; then
    t_check_fail packs.unknown.enumerates.mutation \
        "with pack_installed returning nothing, the enumeration assertion goes red" \
        unknown_pack_enumerates "$M" xc7z020clg400-1
else
    t_skip packs.unknown.enumerates.mutation "could not plant the fault: pack_installed()'s return has changed shape"
fi


#=============================================================================
# 9. THE PHYSICAL-VERSUS-RETARGETED PRIMITIVE RULE
#
# THE HIGHEST-VALUE CHECK IN THIS FILE, because it is the only one whose absence
# produces a bitstream. A pack naming MMCME2_ADV for xck26 describes a device
# that does not exist; Vivado accepts it, retargets it to MMCME4_ADV, warns once
# in a log nobody reads, and the build succeeds. BUFHCE is worse - it becomes
# BUFGCTRL, WHICH HAS NO CLOCK ENABLE, so the clock gating the design asked for
# is silently gone.
#
# Two claims, and they are different claims:
#   * a legacy primitive in a physical key is REJECTED, with what it would
#     actually become
#   * each shipped pack states the primitive that is PHYSICAL FOR ITS
#     ARCHITECTURE. A validator that rejects the wrong value proves nothing
#     about whether the right one is present.
#=============================================================================
t_head "physical versus retargeted primitives - the trap the packs exist to prevent"

pack_fault packs.primitive.retargeted \
    "MMCME2_ADV in xck26's mmcm_primitive is REJECTED, and the message says what Vivado would silently make it" \
    part "$PARTU" 's/^part_set mmcm_primitive MMCME4_ADV/part_set mmcm_primitive MMCME2_ADV/' \
    "silently turns it into 'MMCME4_ADV'" "There is no MMCME2_ADV site or BEL on this device"

pack_fault packs.primitive.retargeted.idelay \
    "IDELAYE2 in xck26's idelay_primitive is REJECTED - IDELAYE2 and IDELAYE3 have different tap counts and different legal reference ranges" \
    part "$PARTU" 's/^part_set idelay_primitive         IDELAYE3/part_set idelay_primitive         IDELAYE2/' \
    "silently turns it into 'IDELAYE3'"

pack_fault packs.primitive.rejected \
    "a primitive the pack's own primitives_rejected names is REFUSED - PS7 does not exist on this architecture" \
    part "$PARTU" 's/^part_set ps_type     PS8/part_set ps_type     PS7/' \
    "primitives_rejected says this architecture REFUSES"

# THE SAME MISTAKE IN THE OTHER DIRECTION, AND WHY THE FAMILY IS NOT ENOUGH TO
# GUESS FROM. On xc7z020 it is BUFGCE that is merely accepted, and it becomes
# BUFGCTRL - which HAS NO CLOCK ENABLE, so the gating the design asked for is
# silently gone. BUFGCE is the PHYSICAL buffer on both UltraScale packs in this
# toolkit. Same name, same source, a clock enable on one device and none on the
# other, one warning either way.
pack_fault packs.primitive.retargeted.bufgce \
    "BUFGCE in xc7z020's clock_buffer_ce is REJECTED - it becomes BUFGCTRL, which has no clock enable" \
    part "$PART7" 's/^part_set clock_buffer_ce      BUFHCE/part_set clock_buffer_ce      BUFGCE/' \
    "silently turns it into 'BUFGCTRL'"

pack_fault packs.primitive.rejected.ultrascale \
    "an UltraScale MMCM named in the 7-series pack is REFUSED outright, not retargeted - it would fail at elaboration" \
    part "$PART7" 's/^part_set mmcm_primitive  MMCME2_ADV/part_set mmcm_primitive  MMCME4_ADV/' \
    "primitives_rejected says this architecture REFUSES"

# THE THIRD ARCHITECTURE, and the point of stating this per pack rather than
# deriving it: MMCME2_ADV is wrong on xck26 AND wrong on xcku115, and the two
# packs say it becomes two DIFFERENT cells. A rule that guessed from "not
# 7-series" would give the same answer to both and be wrong about one of them.
pack_fault packs.primitive.retargeted.kintexu \
    "MMCME2_ADV in xcku115's mmcm_primitive is rejected as becoming MMCME3_ADV - a different answer from xck26's, from the same wrong input" \
    part "$PARTK" 's/^part_set mmcm_primitive MMCME3_ADV/part_set mmcm_primitive MMCME2_ADV/' \
    "silently turns it into 'MMCME3_ADV'"

## part_key_is <toolkit> <pack> <key> <value>
## Read through the SHIPPED SCRIPT rather than through tclsh directly, so this
## also exercises the path a Makefile, a deploy hook or a CI job actually takes.
part_key_is() {
    local tk="$1" pack="$2" key="$3" want="$4" out rc=0
    out="$(env -u FPGA_DIR -u FPGA_BOARD_DIR -u FPGA_PART_DIR \
           FPGA_FLOW_DIR="$tk" "$tk/scripts/fpga-flow-part-get" \
           --part "$pack" "$key" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'fpga-flow-part-get exited %s for %s %s:\n%s\n' "$rc" "$pack" "$key" "$out"
        return 1
    fi
    [ "$out" = "$key $want" ] && return 0
    printf 'expected "%s %s", got "%s"\n' "$key" "$want" "$out"
    return 1
}

## physical_primitives_are <toolkit> <pack> <mmcm> <idelay> <clock buffer>
physical_primitives_are() {
    local tk="$1" pack="$2"
    part_key_is "$tk" "$pack" mmcm_primitive   "$3" || return 1
    part_key_is "$tk" "$pack" idelay_primitive "$4" || return 1
    part_key_is "$tk" "$pack" clock_buffer_ce  "$5" || return 1
    return 0
}

t_check packs.primitive.physical.xc7z020 \
    "xc7z020 (zynq) states the 7-series physical primitives: MMCME2_ADV, IDELAYE2, BUFHCE" \
    physical_primitives_are "$FLOW_DIR" xc7z020clg400-1 MMCME2_ADV IDELAYE2 BUFHCE
t_check packs.primitive.physical.xck26 \
    "xck26 (zynquplus) states MMCME4_ADV, IDELAYE3, BUFGCE - not one of them is the 7-series name" \
    physical_primitives_are "$FLOW_DIR" xck26-sfvc784-2LV-c MMCME4_ADV IDELAYE3 BUFGCE
t_check packs.primitive.physical.xcku115 \
    "xcku115 (kintexu) states MMCME3_ADV, IDELAYE3, BUFGCE - a THIRD MMCM name, which is why guessing from the family is not a strategy" \
    physical_primitives_are "$FLOW_DIR" xcku115-flvb1760-1-c MMCME3_ADV IDELAYE3 BUFGCE

# The proof that the three assertions above read the packs. Change one value in
# a copy and the pack must stop answering with it - here the validator refuses
# the pack outright, which is the strongest possible form of that.
M="$(t_mutant "$SB" xck26-legacy-mmcm)"
if t_mutate "$M" part/xck26-sfvc784-2LV-c/part.tcl \
        's/^part_set mmcm_primitive MMCME4_ADV/part_set mmcm_primitive MMCME2_ADV/'; then
    t_check_fail packs.primitive.physical.xck26.mutation \
        "with xck26's pack naming the 7-series MMCM, the physical-primitive assertion goes red" \
        physical_primitives_are "$M" xck26-sfvc784-2LV-c MMCME4_ADV IDELAYE3 BUFGCE
else
    t_skip packs.primitive.physical.xck26.mutation "could not plant the fault: the mmcm_primitive line in the xck26 pack has changed shape"
fi

# AND THE GUARD ITSELF. Without this, every assertion above would keep passing
# on a toolkit whose cross-check had been deleted - the packs would still be
# right and nothing would be stopping the next one from being wrong.
M="$(t_mutant "$SB" retarget-check-dead)"
if t_replace_line "$M" part/pack_api.tcl \
        '            if {[info exists retarget($prim)]} {' \
        '            if {0} {'; then
    t_check_fail packs.primitive.retargeted.mutation \
        "with the retarget cross-check neutered, MMCME2_ADV on xck26 is ACCEPTED and the assertion goes red" \
        pack_rejects "$M" part "$SB/packs/packs_primitive_retargeted" "silently turns it into 'MMCME4_ADV'"
    t_check_fail packs.primitive.retargeted.idelay.mutation \
        "and IDELAYE2 is accepted too, from the same fault" \
        pack_rejects "$M" part "$SB/packs/packs_primitive_retargeted_idelay" "silently turns it into 'IDELAYE3'"
else
    t_skip packs.primitive.retargeted.mutation "could not plant the fault: the retarget test in pack_crosscheck_part() has changed shape"
    t_skip packs.primitive.retargeted.idelay.mutation "could not plant the fault: the retarget test in pack_crosscheck_part() has changed shape"
fi

M="$(t_mutant "$SB" rejected-check-dead)"
if t_replace_line "$M" part/pack_api.tcl \
        '            if {[lsearch -exact $rejected $prim] >= 0} {' \
        '            if {0} {'; then
    t_check_fail packs.primitive.rejected.mutation \
        "with the rejected-primitive test neutered, PS7 on a zynquplus pack is accepted" \
        pack_rejects "$M" part "$SB/packs/packs_primitive_rejected" "primitives_rejected says this architecture REFUSES"
else
    t_skip packs.primitive.rejected.mutation "could not plant the fault: the rejected test in pack_crosscheck_part() has changed shape"
fi


#=============================================================================
# 10. THE SCRIPTS - fpga-flow-part-get
#
# A PARTIAL ANSWER IS THE DANGEROUS SHAPE. A caller reading line by line takes
# the values that resolved and silently defaults the rest, which is the exact
# failure the pack API's unset-optional rule exists to stop, reintroduced one
# process boundary away. So when ANY key is missing, NOTHING is printed.
#=============================================================================
t_head "fpga-flow-part-get: all of the answer, or none of it"

partget() {             # partget <toolkit> <args...> ; prints STDOUT only
    local tk="$1"; shift
    env -u FPGA_DIR -u FPGA_BOARD_DIR -u FPGA_PART_DIR \
        FPGA_FLOW_DIR="$tk" "$tk/scripts/fpga-flow-part-get" "$@" 2>/dev/null
}

## partget_prints_nothing_on_a_miss <toolkit>
partget_prints_nothing_on_a_miss() {
    local tk="$1" out rc=0 err
    out="$(partget "$tk" --part xc7z020clg400-1 luts temp_grade)" || rc=$?
    if [ "$rc" -ne 1 ]; then
        printf 'expected exit 1 (a check failed), got %s\n' "$rc"; return 1
    fi
    if [ -n "$out" ]; then
        printf 'STDOUT was not empty - a PARTIAL answer was printed:\n%s\n' "$out"; return 1
    fi
    err="$(env -u FPGA_DIR -u FPGA_BOARD_DIR -u FPGA_PART_DIR FPGA_FLOW_DIR="$tk" \
           "$tk/scripts/fpga-flow-part-get" --part xc7z020clg400-1 luts temp_grade 2>&1)"
    printf '%s' "$err" | grep -qF "does not supply: temp_grade" || {
        printf 'the refusal does not name the key that was missing:\n%s\n' "$err"; return 1; }
    printf '%s' "$err" | grep -qF "NOTHING HAS BEEN PRINTED" || {
        printf 'the refusal does not say that the resolved keys were withheld too:\n%s\n' "$err"; return 1; }
    return 0
}

## partget_rc <toolkit> <expected rc> <args...>
partget_rc() {
    local tk="$1" want="$2"; shift 2
    local rc=0
    partget "$tk" "$@" >/dev/null 2>&1 || rc=$?
    [ "$rc" = "$want" ] && return 0
    printf 'fpga-flow-part-get %s exited %s, wanted %s\n' "$*" "$rc" "$want"
    return 1
}

t_check packs.partget.all \
    "--all prints every key the pack sets and exits 0" \
    partget_rc "$FLOW_DIR" 0 --part xck26-sfvc784-2LV-c --all
t_check packs.partget.missing \
    "a missing key exits 1 (a check failed) and prints NOTHING, not even the keys that resolved" \
    partget_prints_nothing_on_a_miss "$FLOW_DIR"
t_check packs.partget.unknown_key \
    "an unknown key is a REFUSAL (2), not a failed check (1) - CONTRACT.md section 10" \
    partget_rc "$FLOW_DIR" 2 --part xc7z020clg400-1 luts_typo
t_check packs.partget.unknown_pack \
    "an unknown pack is a refusal (2) - the pack is broken, no question can be asked of it" \
    partget_rc "$FLOW_DIR" 2 --part xc7a35t luts

M="$(t_mutant "$SB" partget-partial-answer)"
if t_replace_line "$M" scripts/fpga-flow-part-get 'if {[llength $missing]} {' 'if {0} {'; then
    t_check_fail packs.partget.missing.mutation \
        "with the withholding removed, the resolved keys are printed and the assertion goes red" \
        partget_prints_nothing_on_a_miss "$M"
else
    t_skip packs.partget.missing.mutation "could not plant the fault: the missing-key block in fpga-flow-part-get has changed shape"
fi


#=============================================================================
# 11. THE SCRIPTS - fpga-flow-part-probe, AND THE ASSERTION THAT PASSED FOR THE
#     WRONG REASON
#
# THE RESCUED SCRIPT'S ONE FAILURE LIVED HERE. It asserted that probing a
# RELATIVE pack path is refused, and it depended on the process's current
# working directory being somewhere the path did not resolve. When the file
# moved out of a scratchpad into the repository the cwd became the toolkit root,
# `part/xck26-sfvc784-2LV-c` resolved, and the assertion inverted.
#
# The assertion was never wrong about pack_api.tcl. It was wrong about what it
# was measuring: a property of the CALLER'S cwd, asserted as though it were a
# property of the probe. So BOTH directions are pinned here, explicitly, and the
# refusal is asserted on the MESSAGE - which has to name the working directory,
# because "no such pack path" without one sends the reader to look at the wrong
# thing entirely.
#=============================================================================
t_head "fpga-flow-part-probe: a relative path is resolved against a PINNED cwd"

probe() {               # probe <toolkit> <cwd> <args...>
    local tk="$1" cwd="$2"; shift 2
    ( cd "$cwd" 2>/dev/null || exit 2
      env -u FPGA_DIR -u FPGA_BOARD_DIR -u FPGA_PART_DIR \
          FPGA_FLOW_DIR="$tk" "$tk/scripts/fpga-flow-part-probe" "$@" 2>&1 )
}

## probe_rc <toolkit> <cwd> <expected rc> <args...>
probe_rc() {
    local tk="$1" cwd="$2" want="$3"; shift 3
    local rc=0
    probe "$tk" "$cwd" "$@" >/dev/null || rc=$?
    [ "$rc" = "$want" ] && return 0
    printf 'probe %s from %s exited %s, wanted %s\n' "$*" "$cwd" "$rc" "$want"
    return 1
}

## probe_refuses_relative_from_elsewhere <toolkit>
## The cwd is PINNED to the sandbox, which is the whole fix.
probe_refuses_relative_from_elsewhere() {
    local tk="$1" out rc=0
    out="$(probe "$tk" "$SB" part/xck26-sfvc784-2LV-c)" || rc=$?
    if [ "$rc" != 2 ]; then
        printf 'a relative pack path from %s exited %s, wanted 2 (refused):\n%s\n' "$SB" "$rc" "$out"
        return 1
    fi
    printf '%s' "$out" | grep -qF "no such pack path: part/xck26-sfvc784-2LV-c" || {
        printf 'the refusal does not name the path it could not find:\n%s\n' "$out"; return 1; }
    printf '%s' "$out" | grep -qF "working directory: $SB" || {
        printf 'the refusal does not name the WORKING DIRECTORY, which is the whole explanation:\n%s\n' "$out"
        return 1; }
    return 0
}

t_check packs.probe.abs \
    "an ABSOLUTE pack path probes clean, whatever the cwd is" \
    probe_rc "$FLOW_DIR" "$SB" 0 -q "$FLOW_DIR/part/xck26-sfvc784-2LV-c"
t_check packs.probe.bare \
    "a BARE pack name resolves against \$FPGA_FLOW_DIR/part, whatever the cwd is" \
    probe_rc "$FLOW_DIR" "$SB" 0 -q xck26-sfvc784-2LV-c
t_check packs.probe.relative.refused \
    "a RELATIVE path from a cwd it does not resolve under is refused (2) and the message names that cwd" \
    probe_refuses_relative_from_elsewhere "$FLOW_DIR"
t_check packs.probe.relative.resolves \
    "and the SAME relative path from the toolkit root resolves - which is why the rescued assertion inverted when the file moved" \
    probe_rc "$FLOW_DIR" "$FLOW_DIR" 0 -q part/xck26-sfvc784-2LV-c
t_check packs.probe.unknown \
    "an unknown pack NAME with an explicit --role is refused (2)" \
    probe_rc "$FLOW_DIR" "$SB" 2 -q --role part nosuchpart
t_check packs.probe.no_role \
    "a directory that is neither a part pack nor a board pack is refused (2) rather than probed as a guess" \
    probe_rc "$FLOW_DIR" "$SB" 2 -q "$SB"

## probe_board_env <toolkit> <expected rc> [env assignment]
## A board pack whose site variable is UNSET is a HOST problem (1), and the same
## pack with it set is clean (0). No site path is ever defaulted, so the
# difference between those two runs is one exported variable and nothing else.
probe_board_env() {
    local tk="$1" want="$2" val="${3:-}" rc=0
    ( cd "$SB" || exit 2
      if [ -n "$val" ]; then export TESTBENCH_BOARD_FILES="$val"; else unset TESTBENCH_BOARD_FILES; fi
      env -u FPGA_DIR -u FPGA_BOARD_DIR -u FPGA_PART_DIR \
          FPGA_FLOW_DIR="$tk" "$tk/scripts/fpga-flow-part-probe" -q "$BOARD_DIR" >/dev/null 2>&1 ) || rc=$?
    [ "$rc" = "$want" ] && return 0
    printf 'board probe exited %s, wanted %s (TESTBENCH_BOARD_FILES=%s)\n' "$rc" "$want" "${val:-<unset>}"
    return 1
}

t_check packs.probe.board.unset \
    "a board pack whose site variable is unset reports a HOST problem (1), not a broken pack (2)" \
    probe_board_env "$FLOW_DIR" 1
t_check packs.probe.board.set \
    "and the same pack with the variable exported probes clean (0) - nothing was defaulted, one variable was set" \
    probe_board_env "$FLOW_DIR" 0 "$SB/vendor-board-files"

M="$(t_mutant "$SB" probe-cwd-silent)"
if t_replace_line "$M" scripts/fpga-flow-part-probe \
        '    elif case "$PACK" in */*|.*|/*) true ;; *) false ;; esac; then' \
        '    elif false; then'; then
    t_check_fail packs.probe.relative.refused.mutation \
        "with the path-shaped branch removed the refusal stops naming the cwd, and the assertion goes red" \
        probe_refuses_relative_from_elsewhere "$M"
else
    t_skip packs.probe.relative.refused.mutation "could not plant the fault: the path-shaped branch in fpga-flow-part-probe has changed shape"
fi


#=============================================================================
# 12. A DISAGREEMENT BETWEEN THE CODE AND THE CONTRACT, RECORDED RATHER THAN
#     SILENTLY PICKED
#
# CONTRACT.md section 8 was CORRECTED on 2026-09-08: "cfgbvs and config_voltage
# are BOARD keys, not part keys", and it lists both under the board role's other
# keys. part/pack_api.tcl still registers both in the PART table (section 1a,
# "configuration") and in NEITHER board table, and its comment there cites the
# pre-correction wording. Because an unknown key is an error, the consequence is
# not a default: a board pack CANNOT STATE EITHER OF THEM AT ALL.
#
# This suite does not own pack_api.tcl, so it records the defect instead of
# fixing it. The marker cannot outlive the bug: t_known_defect goes RED the day
# the assertion starts passing.
#=============================================================================
t_head "cfgbvs/config_voltage: CONTRACT.md says board, the schema says part"

## board_accepts_cfgbvs <toolkit>
board_accepts_cfgbvs() {
    local d="$SB/packs/cfgbvs_board"
    rm -rf "$d"; mkdir -p "$d"
    cp "$BOARD" "$d/board.tcl"
    printf 'board_set cfgbvs GND\nboard_set config_voltage 1.8\n' >> "$d/board.tcl"
    pack_loads "$1" board "$d"
}

t_check packs.contract.cfgbvs \
    "a BOARD pack can state cfgbvs and config_voltage - they follow how bank 0 is WIRED, which is a PCB fact" \
    board_accepts_cfgbvs "$FLOW_DIR"

# The mutation proof. Put them back in the part role only - which is exactly the
# state this suite found on 2026-09-08 - and a board pack can no longer state
# them, so the assertion above must go red.
#
# HISTORY, kept because it is the harness earning its keep: this shipped as a
# t_known_defect. CONTRACT.md section 8 had been corrected in PROSE ONLY, so the
# key lived in the part schema and in neither board table; since an unknown key
# is a hard error, nothing could state either key at all. All three shipped part
# packs had already declined to set them, so the gap stayed invisible until a
# board pack tried. When pack_api.tcl was fixed the marker went red by itself -
# "KNOWN-DEFECT marker is STALE - this now PASSES" - and became this assertion.
M="$(t_mutant "$SB" cfgbvs-part-only)"
# part/pack_schema.tcl, not pack_api.tcl: the schema rows moved into their own
# file on 2026-09-11. This proof found that by itself - t_replace_line refused to
# plant a fault it could not locate and the suite skipped WITH THE REASON, which
# is the whole point of a mutation that fails loudly rather than silently
# matching nothing.
if t_replace_line "$M" part/pack_schema.tcl \
       '    cfgbvs                no  str   config' \
       '    cfgbvs_moved_away     no  str   config'; then
    t_check_fail packs.contract.cfgbvs.mutation \
        "with cfgbvs removed from the board schema again, the assertion above goes red" \
        board_accepts_cfgbvs "$M"
else
    t_skip packs.contract.cfgbvs.mutation \
        "could not plant the fault: the cfgbvs row in the board schema has changed shape"
fi

t_summary

# Copyright (C) 2026, SoC Labs (www.soclabs.org)
