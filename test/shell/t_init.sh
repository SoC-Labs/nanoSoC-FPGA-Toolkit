#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# t_init.sh - scripts/fpga-flow-init must hand back a project that is WRONG IN
#             EXACTLY THE WAYS IT SAYS IT IS, and right in every other
#
# DEFECT CLASS: A SCAFFOLD THAT LOOKS FINISHED.
#
# A scaffolder is trusted absolutely by the person running it, because they have
# nothing yet to compare its output against. Everything downstream is read as a
# fact about THEIR project: a file at the wrong path is "my design.mk is wrong",
# a dropped template is "the flow wants something I have not written", a stray
# <<FILL IN>> that reaches synthesis is forty minutes and one licence-hour from
# the mistake that caused it. fpga-flow-init's own header says why it carries
# postconditions at all - the reference ASIC toolkit's scaffolder walked its
# templates with `find | while read`, incremented its counters in a SUBSHELL,
# discarded every increment at the `done`, and exited 0 having written nothing.
#
# Until this file landed, `fpga-flow-init` was named by no test. It had been run
# by hand and never asserted on (test/KNOWN_DEFECTS, UNPROVEN). This is the
# round trip that entry asked for.
#
# THE CENTRAL ASSERTION IS NOT "make check IS CLEAN".
#
# A freshly scaffolded project is DELIBERATELY incomplete. It carries <<FILL IN>>
# markers, and `make check` is supposed to name them and exit non-zero - that
# refusal is the feature. So the assertion is the harder one: `make check`
# reports EXACTLY the decisions the scaffolder left open, and NOTHING ELSE. Both
# halves matter and they fail in opposite directions:
#
#   more than that   the scaffold is broken in a way that reads as the
#                    project's fault - a file at a path no variable names, a
#                    manifest that points at something templates/ never wrote.
#   fewer than that  a decision was silently made FOR the project. That is the
#                    worse one: it is a value nobody chose, in a build that runs.
#
# The set was MEASURED against this checkout, not assumed; section 1 says what it
# is and how each entry gets there. Section 1 also proves the check can go GREEN
# on a scaffolded tree - fill in what it names and it says "Contract complete."
# A refusal that cannot be cleared is not a contract, it is a wall.
#
# WHAT RUNS WITHOUT A TOOL. Sections 2-8 need nothing but the scaffolder itself:
# what it claims to write, the entry contract it emits, where the markers land,
# what a re-run does, what it refuses, and where the part-pack list comes from.
# Section 1 needs `make` and `python3` (fpga-flow-check is python3) and SKIPS
# WITH ITS REASON without them, per test/README.md.
#
# EVERY ASSERTION IS PAIRED WITH A MUTATION PROOF, and EVERY PROOF GETS ITS OWN
# MUTANT. A shared copy accumulates faults, and the fifteenth proof then passes
# or fails for the first proof's reason - which is a bug this suite's sibling
# t_flow_utils.sh shipped and had to fix.
#
# THE FIXTURE NAMES NOTHING REAL. CONTRACT.md section 11.8: nothing in this
# repository names a board, a pin or a project path, and a test fixture is part
# of this repository. BLOCK_N and BOARD_N are placeholders.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/lib/harness.sh
. "$HERE/../lib/harness.sh"

t_sandbox; SB="$T_SANDBOX"

INIT_REL="scripts/fpga-flow-init"
BLOCK_N="demo_block"
BOARD_N="demo_board"

# The marker, spelled the way fpga-flow-check spells it (its MARKER regex is
# `<<\s*FILL\s+IN`) rather than as the literal string. The templates wrap one of
# them across two lines, and a plain substring search would miss it and then
# report a clean tree.
MARKER_RE='<<[[:space:]]*FILL[[:space:]]+IN'

# A line a PROJECT added, used to tell "the scaffolder left my file alone" from
# "the scaffolder rewrote it with identical bytes". Those are the same file and
# very different behaviours, and only an edit can separate them.
SENTINEL="# a line this project added - planted by t_init.sh"

#-----------------------------------------------------------------------------
# Preconditions. An absent file is a SKIP WITH ITS REASON and never a pass:
# several files in this repository are being written concurrently, so "not there
# yet" is a normal answer and it is never a green one.
#-----------------------------------------------------------------------------
if [ ! -f "$FLOW_DIR/$INIT_REL" ]; then
    t_skip init.all "$INIT_REL is not in this checkout - there is no scaffolder to test, and an absent file is not a passing one"
    t_summary; exit $?
fi
if [ -z "$(find "$FLOW_DIR/templates" -type f 2>/dev/null | head -1)" ]; then
    t_skip init.all "$FLOW_DIR/templates holds no files, so the scaffolder has nothing to install and every assertion below would measure an empty walk"
    t_summary; exit $?
fi

#=============================================================================
# HELPERS
#=============================================================================

## scaffold <toolkit> <name> [extra init args...]
##   -> sets SC_DIR (the project), SC_LOG (everything it printed), SC_RC
##
## SETS VARIABLES rather than printing, for the reason t_sandbox documents: the
## caller needs three results and `X=$(scaffold ...)` would run it in a subshell
## and lose two of them.
##
## The destination is passed LAST, because it is the positional argument.
scaffold() {
    local flow="$1" name="$2"; shift 2
    SC_DIR="$SB/proj-$name"
    SC_LOG="$SB/proj-$name.log"
    t_in_sandbox "$SC_DIR" || { echo "harness: refusing to scaffold outside a sandbox" >&2; return 2; }
    rm -rf "$SC_DIR"
    SC_RC=0
    "$flow/$INIT_REL" --block "$BLOCK_N" --board "$BOARD_N" "$@" "$SC_DIR" \
        > "$SC_LOG" 2>&1 || SC_RC=$?
    return 0
}

## sc_written / sc_skipped <log> - the paths the scaffolder CLAIMED, one per
## line, relative to the project directory exactly as it printed them.
sc_written() { sed -n 's/^   write  \(.*\)$/\1/p' "$1"; }
sc_skipped() { sed -n 's/^   skip   \(.*\)   (exists; --force to overwrite)$/\1/p' "$1"; }

## proj_env <fpga dir> <variable> - the value MAKE resolved, not the value this
## suite thinks it should be. Anything that compared against a path spelled here
## would be testing its own arithmetic.
proj_env() {
    make -C "$1" --no-print-directory env 2>/dev/null \
        | awk -v n="$2" '$1 == n { print $2; exit }'
}

## marker_profile <root> - one marker-LINE count per file that has any, sorted.
##
## A MULTISET, not a total. Two offsetting errors - one marker expanded away
## here, one invented there - keep a total identical and change this.
marker_profile() {
    find "$1" -type f -exec grep -cE "$MARKER_RE" {} \; 2>/dev/null \
        | grep -v '^0$' | LC_ALL=C sort -n
}

## marker_lines <root> - the same thing summed, for the one assertion that needs
## a total rather than a shape.
marker_lines() { marker_profile "$1" | awk '{ s += $1 } END { print s + 0 }'; }

## template_placeholders <toolkit> - @NAME@ spellings the templates actually
## use. DERIVED FROM templates/, never listed here: a list of six in this file
## would go stale the first time a seventh is added, and it would go stale
## SILENTLY, which is the failure this repository's third rule exists for.
template_placeholders() {
    grep -rhoE '@[A-Z_]+@' "$1/templates" 2>/dev/null | LC_ALL=C sort -u
}

## pack_dirs <toolkit> - the part packs a DIRECTORY LISTING knows about.
##
## Deliberately a different implementation from part_packs() in the script under
## test (`find -type d` rather than a `*/` glob). A test that re-used the
## script's own expression would agree with it even when both were wrong.
pack_dirs() {
    find "$1/part" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
        | sed 's|.*/||' | LC_ALL=C sort
}

## offered_packs <toolkit> - what `--help` tells a new user they may pass to
## --part. The list lines are the ones indented by exactly two spaces, which is
## the indent part_packs_listed is called with; the two-line wrapped heading
## starts at column 0 and is excluded by the same rule.
offered_packs() {
    "$1/$INIT_REL" --help 2>/dev/null \
        | sed -n '/^Part packs in this checkout/,$p' \
        | sed -n 's/^  \([^ ].*\)$/\1/p' | LC_ALL=C sort
}

## contract_entry_block - CONTRACT.md section 2's three lines, read FROM THE
## CONTRACT. Spelling them in this file would make the test agree with itself.
contract_entry_block() {
    sed -n '/^## 2\. The entry contract$/,/^## 3\./p' "$FLOW_DIR/CONTRACT.md" 2>/dev/null \
        | sed -n '/^```make$/,/^```$/p' | sed '1d;$d'
}

#=============================================================================
# 1. THE ROUND TRIP - scaffold, then `make check` against the result
#
# This is the assertion test/KNOWN_DEFECTS asked for, in the shape the measured
# behaviour actually has.
#
# THE OPEN DECISIONS, MEASURED 2026-09-11 against a scaffold with no --part.
# Each is a MISS line in `make check`, and each is there because the scaffolder
# deliberately declined to invent it:
#
#   RTL_FLIST             design.mk: `<<FILL IN: absolute path to the master
#                         flist>>`. The single input that decides what is built.
#   PART_DIR              design.mk: `PART ?= <<FILL IN: the device...>>`. Only
#                         open when --part was NOT passed - see section 4.
#   TOP_HDL               design.mk: `<<FILL IN: ... or empty if the flist has
#                         it>>`. Named, therefore expected to exist.
#   XDC_BASELINE          design.mk: `<<FILL IN: ... after your first run>>`.
#   UNFILLED PLACEHOLDERS the tally of every marker still standing anywhere.
#
# THREE MORE VARIABLES CARRY A MARKER AND REPORT `ok`: TOP, SYS_CLK_FREQ_HZ and
# RTL_DEFINES_NEVER. That is not a bug and it is why the tally exists - those
# are not PATHS, so a path check cannot see that their value is scaffolding.
# `RTL_DEFINES_NEVER` even reports `ASSERTED ABSENT` about a literal marker.
# Only the UNFILLED PLACEHOLDERS line catches them, which is the whole reason
# fpga-flow-check reads file CONTENT instead of running `test -e`.
#
# This set is a CLOSED DECLARED LIST (CONTRACT.md section 6's form) because
# nothing in the filesystem knows it: it is the join of what the templates leave
# open and what the checker is able to see. If it changes, one of those two
# changed, and a human should read the diff - which is exactly what the failure
# message prints.
#=============================================================================
OPEN_DECISIONS="$(printf '%s\n' \
    'PART_DIR' 'RTL_FLIST' 'TOP_HDL' 'UNFILLED PLACEHOLDERS' 'XDC_BASELINE' \
    | LC_ALL=C sort)"

## reports_exactly_the_open_decisions <fpga dir>
##
## Asserting on the MESSAGE, not the exit status. `make check` on a project with
## three things wrong exits non-zero for all three, so a test that accepted any
## non-zero status would pass just as happily on a checkout where the marker
## scan had been deleted and something unrelated was broken instead.
reports_exactly_the_open_decisions() {
    local fpga="$1" out rc=0 got
    out="$(make -C "$fpga" --no-print-directory check 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ]; then
        printf 'make check EXITED 0 on a FRESHLY SCAFFOLDED project.\n'
        printf 'A scaffold carries <<FILL IN>> markers and is deliberately incomplete, so a\n'
        printf 'green check here is the "scaffold that looks finished" defect itself: the\n'
        printf 'decisions were made by nobody and the build will run anyway.\n%s\n' "$out"
        return 1
    fi
    # The report prints `"%s %-24s %s" % (status, label, detail)`, so the label
    # is a fixed 24-wide field starting at column 8. A label can contain a space
    # ("UNFILLED PLACEHOLDERS"), which is why this is a column cut and not $2.
    got="$(printf '%s\n' "$out" | awk '/^ MISS /{ print substr($0, 8, 24) }' \
            | sed 's/[[:space:]]*$//' | LC_ALL=C sort)"
    [ "$got" = "$OPEN_DECISIONS" ] && return 0
    printf 'make check named a different set of open decisions than the scaffolder leaves.\n'
    printf 'Read both columns: an entry that APPEARED is a scaffold the project must repair\n'
    printf 'before it can build; one that VANISHED is a decision something made for it.\n'
    printf 'expected:\n%s\n---\ngot:\n%s\n' "$OPEN_DECISIONS" "$got"
    printf '%s\n' "$out" | grep -E '^ MISS |^ WARN '
    return 1
}

## check_draws_no_warning <fpga dir>
check_draws_no_warning() {
    local fpga="$1" out
    out="$(make -C "$fpga" --no-print-directory check 2>&1)"
    if printf '%s\n' "$out" | grep -qE '^ WARN |^WARNINGS'; then
        printf 'a FRESHLY SCAFFOLDED project draws a WARNING from its very first make check.\n'
        printf 'A warning that is always there and always expected is worse than no warning:\n'
        printf 'it teaches the reader to skim the block, and the run where that block says\n'
        printf 'something real then scrolls past unread. fpga-flow-check carries a DOC_FILES\n'
        printf 'filter for exactly this - before it existed, every scaffolded project ever\n'
        printf 'made carried a standing "unrecognised file(s) in hooks/ - README.md".\n'
        printf '%s\n' "$out" | sed -n '/^WARNINGS/,$p'
        return 1
    fi
    return 0
}

## fill_in <fpga dir> <flist path> <keep|strip>
##
## Makes every decision the scaffolder left open, the way a new user would.
##
## The rule is uniform and it is the one the marker's own wording implies: a
## marker on a `VAR := ` or `VAR ?= ` line IS the decision, so it gets a value
## (or is cleared, which is how an optional says "does not apply"); a marker
## anywhere else sits in a COMMENT or in a commented-out pack key, so the honest
## way to answer it is to delete the line.
##
## <keep|strip> is about design.mk's COMMENTS only, and it exists to isolate one
## defect - see init.complete.decisions below. `strip` deletes them too.
##
## Nothing here spells a marker's text: every edit is driven by MARKER_RE, so a
## template that grows a new one is answered rather than silently skipped.
fill_in() {
    local fpga="$1" flist="$2" comments="$3" pins
    t_in_sandbox "$fpga" || { echo "harness: refusing to edit outside a sandbox" >&2; return 2; }

    # The three that need a real value. Everything else is an optional whose
    # empty value is legal, and `?=` with nothing after it is how that is said.
    sed -i -E "s#^(TOP)([[:space:]]*)(:=|\?=)[[:space:]].*${MARKER_RE}.*#\1\2\3 ${BLOCK_N}#" "$fpga/design.mk" || return 2
    sed -i -E "s#^(RTL_FLIST)([[:space:]]*)(:=|\?=)[[:space:]].*${MARKER_RE}.*#\1\2\3 ${flist}#" "$fpga/design.mk" || return 2
    sed -i -E "s#^(SYS_CLK_FREQ_HZ)([[:space:]]*)(:=|\?=)[[:space:]].*${MARKER_RE}.*#\1\2\3 50000000#" "$fpga/design.mk" || return 2
    sed -i -E "s#^([A-Z_][A-Z_0-9]*)([[:space:]]*)(:=|\?=)[[:space:]].*${MARKER_RE}.*#\1\2\3#" "$fpga/design.mk" || return 2

    # `-r` so an empty file list does not leave sed reading stdin forever.
    find "$fpga" -type f ! -name design.mk -print0 \
        | xargs -0 -r sed -i -E "/${MARKER_RE}/d" || return 2

    [ "$comments" = keep ] || sed -i -E "/${MARKER_RE}/d" "$fpga/design.mk" || return 2

    # XDC_PINS must carry at least one real constraint. A file that exists and
    # contains only comments is read by Vivado, applies nothing, and produces
    # the same log a correctly constrained run does - fpga-flow-check warns
    # about it, and a WARNING is not the thing under test here.
    # The path comes from MAKE, not from this file.
    pins="$(proj_env "$fpga" XDC_PINS)"
    [ -n "$pins" ] && [ -f "$pins" ] || { echo "fill_in: make resolved no XDC_PINS file" >&2; return 2; }
    printf '%s\n' 'set_property PACKAGE_PIN A1 [get_ports sys_clk]' >> "$pins"
    return 0
}

## scaffold_completes_clean <toolkit> <name> <keep|strip>
##
## THE POSITIVE CONTROL. Everything else in section 1 asserts a refusal, and a
## checker that refused EVERYTHING would satisfy all of it. Fill in what the
## check names and it must go green - otherwise the scaffold is not a starting
## point, it is a dead end, and no amount of work by the project clears it.
scaffold_completes_clean() {
    local flow="$1" name="$2" comments="$3" dir fpga out rc=0 pack
    pack="$(pack_dirs "$flow" | head -1)"
    [ -n "$pack" ] || { printf 'this toolkit ships no part pack, so PART_DIR cannot be resolved by any value\n'; return 1; }
    scaffold "$flow" "$name" --part "$pack" || return 2
    if [ "$SC_RC" -ne 0 ]; then
        printf 'the scaffold itself failed (rc %s):\n' "$SC_RC"; tail -8 "$SC_LOG"; return 1
    fi
    dir="$SC_DIR"; fpga="$dir/fpga"
    mkdir -p "$dir/rtl"
    printf 'module %s;\nendmodule\n' "$BLOCK_N" > "$dir/rtl/$BLOCK_N.v"
    printf '%s\n' "$dir/rtl/$BLOCK_N.v" > "$dir/rtl/$BLOCK_N.flist"
    fill_in "$fpga" "$dir/rtl/$BLOCK_N.flist" "$comments" || return 2

    out="$(make -C "$fpga" --no-print-directory check 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'every decision the scaffolder left open has been made, and make check still refuses.\n'
        printf '%s\n' "$out" | grep -E '^ MISS |^ WARN '
        printf '%s\n' "$out" | sed -n '/^MISSING/,$p' | head -24
        return 1
    fi
    if ! printf '%s\n' "$out" | grep -qF 'Contract complete.'; then
        printf 'make check exited 0 without saying "Contract complete." - the verdict and the\n'
        printf 'exit status disagree, and only one of them is read by a human:\n%s\n' "$out"
        return 1
    fi
    if printf '%s\n' "$out" | grep -qE '^ WARN |^WARNINGS'; then
        printf 'the completed scaffold is green but still draws a WARNING:\n'
        printf '%s\n' "$out" | sed -n '/^WARNINGS/,$p'
        return 1
    fi
    return 0
}

## layout_matches_the_contract <fpga dir>
##
## dest_for()'s own comment says: "The contract states the same shape in section
## 1 and section 3.3 (BOARD_DIR, TARGET_DIR); if this function and the contract
## disagree, one of them is a bug - say which, do not silently pick." NOTHING
## CHECKED THAT. This does, and it asks MAKE where those directories are rather
## than spelling the paths here - the disagreement being tested is precisely
## between the scaffolder's idea of the layout and the engine's.
layout_matches_the_contract() {
    local fpga="$1" bdir tdir f n=0 bad=""
    bdir="$(proj_env "$fpga" BOARD_DIR)"
    tdir="$(proj_env "$fpga" TARGET_DIR)"
    if [ -z "$bdir" ] || [ -z "$tdir" ]; then
        printf 'make env printed no BOARD_DIR/TARGET_DIR, so there is nothing to compare against\n'
        return 1
    fi
    [ -s "$bdir/board.tcl" ] || bad="$bad
  no board pack at BOARD_DIR/board.tcl ($bdir/board.tcl)"
    while IFS= read -r f; do
        n=$((n + 1))
        case "$f" in "$tdir"/*) ;; *) bad="$bad
  $f is outside TARGET_DIR ($tdir)" ;; esac
    done < <(find "$fpga" -type f -name '*.xdc' | LC_ALL=C sort)
    [ "$n" -gt 0 ] || bad="$bad
  the scaffolder wrote no .xdc at all, so this comparison measured nothing"
    [ -z "$bad" ] && return 0
    printf 'dest_for() and the engine disagree about where a scaffolded file lives.\n'
    printf 'The project would see this as its own constraints being ignored:%s\n' "$bad"
    return 1
}

t_head "the round trip: scaffold, then make check against the result"

if ! command -v make >/dev/null 2>&1; then
    for id in roundtrip warn.none complete complete.decisions layout; do
        t_skip "init.$id" "no make on this host, and the round trip is a make target - nothing here ran"
    done
elif ! command -v python3 >/dev/null 2>&1; then
    for id in roundtrip warn.none complete complete.decisions layout; do
        t_skip "init.$id" "no python3 on this host, and scripts/fpga-flow-check is python3 - make check cannot run, so the round trip measured nothing"
    done
else
    scaffold "$FLOW_DIR" "roundtrip"
    if [ "$SC_RC" -ne 0 ]; then
        for id in roundtrip warn.none layout; do
            t_skip "init.$id" "fpga-flow-init exited $SC_RC scaffolding the baseline fixture; see $SC_LOG. Nothing downstream of it can be measured"
        done
    else
        t_check init.roundtrip \
            "make check names exactly the decisions the scaffolder left open" \
            reports_exactly_the_open_decisions "$SC_DIR/fpga"

        t_check init.warn.none \
            "and draws no WARNING - a fresh scaffold starts with a clean warnings block" \
            check_draws_no_warning "$SC_DIR/fpga"

        t_check init.layout \
            "board.tcl and every .xdc land where make resolves BOARD_DIR and TARGET_DIR" \
            layout_matches_the_contract "$SC_DIR/fpga"
    fi

    # -- the positive control, and one defect it isolates ---------------------
    t_check init.complete \
        "filling in what the check names reaches 'Contract complete.' - the refusal is clearable" \
        scaffold_completes_clean "$FLOW_DIR" "complete" strip

    # templates/design.mk.in line 12 is an INSTRUCTION - `#  1. Fill in every
    # <<FILL IN>>.` - and it contains a literal marker, so fpga-flow-check counts
    # the sentence telling you to fill things in as a thing to fill in. A project
    # that has made every real decision still gets `UNFILLED PLACEHOLDERS 1
    # marker(s) in 1 file(s)` pointing at a comment, and the only way to clear it
    # is to delete its own instructions. Nothing in the next-steps text says so.
    # The fix is in the template, not the checker: spell the instruction without
    # a literal marker. Reported, not fixed here.
    t_known_defect init.complete.decisions \
        "making every DECISION should be enough; design.mk's own instruction line carries a literal marker and keeps check red" \
        scaffold_completes_clean "$FLOW_DIR" "complete-decisions" keep

    #-------------------------------------------------------------------------
    # MUTATION PROOFS for section 1. Each gets its own copy of the toolkit.
    #-------------------------------------------------------------------------

    # A template that grows an input the project must supply. This is the drift
    # that makes a scaffold "wrong in a way that reads as the project's fault":
    # nothing about the new MISS line says the toolkit put it there.
    M="$(t_mutant "$SB" roundtrip)"
    if t_replace_line "$M" templates/design.mk.in \
        'XDC_EXTRA       ?=' \
        'XDC_EXTRA       ?= $(TARGET_DIR)/planted_by_a_mutation_proof.xdc'; then
        scaffold "$M" "roundtrip-mut"
        t_check_fail init.roundtrip.mutation \
            "with a template naming one more input, the set of open decisions grows and the assertion goes red" \
            reports_exactly_the_open_decisions "$SC_DIR/fpga"
    else
        t_skip init.roundtrip.mutation "could not plant the fault: templates/design.mk.in has no line exactly 'XDC_EXTRA       ?=' - it has been reformatted, and this proof is measuring nothing until it is re-aimed"
    fi

    # The measured defect the DOC_FILES filter exists for, put back.
    M="$(t_mutant "$SB" warnfilter)"
    if t_replace_line "$M" scripts/fpga-flow-check \
        'DOC_FILES = ("readme", "license", "licence", "notice", "contributing", "todo")' \
        'DOC_FILES = ()'; then
        scaffold "$M" "warnfilter-mut"
        t_check_fail init.warn.none.mutation \
            "with the documentation filter emptied, the scaffolded hooks/README.md warns and the assertion goes red" \
            check_draws_no_warning "$SC_DIR/fpga"
    else
        t_skip init.warn.none.mutation "could not plant the fault: DOC_FILES in scripts/fpga-flow-check has changed shape"
    fi

    # The manifest names a file the scaffolder does not write. No amount of work
    # by the project clears this, which is what makes it worth a proof: the
    # positive control must be able to fail.
    M="$(t_mutant "$SB" completedrift)"
    if t_replace_line "$M" templates/design.mk.in \
        'XDC_TIMING      ?= $(TARGET_DIR)/$(BLOCK).timing.xdc' \
        'XDC_TIMING      ?= $(TARGET_DIR)/$(BLOCK).clocks.xdc'; then
        t_check_fail init.complete.mutation \
            "with design.mk naming a constraint file templates/ never writes, the project cannot complete the contract" \
            scaffold_completes_clean "$M" "complete-mut" strip
    else
        t_skip init.complete.mutation "could not plant the fault: the XDC_TIMING line in templates/design.mk.in has changed shape"
    fi

    # dest_for puts the target files under the BLOCK's name while TARGET_DIR
    # still resolves to the BOARD's. Every XDC is then present, readable and
    # invisible - the shape CONTRACT.md section 9.3 records for a constraint file
    # that matches nothing.
    M="$(t_mutant "$SB" layout)"
    if t_mutate "$M" "$INIT_REL" '/^        targets.block/s|[$]BOARD|${BLOCK}|'; then
        scaffold "$M" "layout-mut"
        t_check_fail init.layout.mutation \
            "with dest_for writing targets/<block>/ while TARGET_DIR says targets/<board>/, the assertion goes red" \
            layout_matches_the_contract "$SC_DIR/fpga"
    else
        t_skip init.layout.mutation "could not plant the fault: the targets/ arm of dest_for in $INIT_REL has changed shape"
    fi
fi

#=============================================================================
# 2. THE SCAFFOLDER'S OWN CLAIMS
#
# `   write  fpga/design.mk` is a CLAIM, and exit 0 is a claim that fpga/ exists
# and is usable. The reference toolkit made both while writing nothing.
#=============================================================================
t_head "every file it claims to write is on disk, non-empty, and accounted for"

## claims_are_true <project dir>
##
## Distinguishes ABSENT from ZERO BYTES, because a zero-byte file satisfies every
## `test -e` in the world and is exactly the shape a tool leaves when it opened
## its output and then died - which is the case install_one's own `[ -s ]` guard
## was written for.
claims_are_true() {
    local dir="$1" log="$1.log" rel n=0 bad="" stated
    [ -s "$log" ] || { printf 'no scaffolder log at %s\n' "$log"; return 1; }
    while IFS= read -r rel; do
        n=$((n + 1))
        if [ ! -e "$dir/$rel" ]; then
            bad="$bad
  $rel   CLAIMED WRITTEN, ABSENT"
        elif [ ! -s "$dir/$rel" ]; then
            bad="$bad
  $rel   CLAIMED WRITTEN, ZERO BYTES"
        fi
    done < <(sc_written "$log")
    if [ "$n" -eq 0 ]; then
        printf 'the scaffolder claimed to write nothing at all, and exited saying it was done.\n'
        printf 'That is the reference toolkit defect verbatim - a subshell that discarded\n'
        printf 'every counter - and it is why this suite counts lines rather than trusting rc.\n'
        return 1
    fi
    if [ -n "$bad" ]; then
        printf 'exit 0 is a claim that fpga/ exists and is usable:%s\n' "$bad"
        return 1
    fi
    # The closing tally is a THIRD claim, and it is the one a reader believes.
    stated="$(sed -n 's/^   \([0-9][0-9]*\) file(s) written, [0-9][0-9]* left alone.*/\1/p' "$log")"
    [ "$stated" = "$n" ] && return 0
    printf 'the scaffolder printed %s write line(s) and then said %s file(s) were written.\n' "$n" "$stated"
    printf 'A counter that disagrees with the lines above it is the subshell bug in slow motion.\n'
    return 1
}

## every_template_accounted_for <toolkit> <project dir>
##
## The count comes from `find templates/`, never from a number in this file.
## dest_for is a rewrite map and not a whitelist precisely so a newly added
## template still installs; this is what says so out loud.
every_template_accounted_for() {
    local flow="$1" dir="$2" log="$2.log" n_tpl n_acc dups
    n_tpl="$(find "$flow/templates" -type f | grep -c .)"
    [ "$n_tpl" -gt 0 ] || { printf 'no template files under %s/templates\n' "$flow"; return 1; }
    n_acc="$( { sc_written "$log"; sc_skipped "$log"; } | grep -c . )"
    if [ "$n_acc" != "$n_tpl" ]; then
        printf '%s/templates holds %s file(s); the run accounted for %s.\n' "$flow" "$n_tpl" "$n_acc"
        printf 'A template that is silently not installed is a file the project never learns\n'
        printf 'it was supposed to have, and it finds out at its first make.\n'
        return 1
    fi
    dups="$( { sc_written "$log"; sc_skipped "$log"; } | LC_ALL=C sort | uniq -d )"
    [ -z "$dups" ] && return 0
    printf 'two templates were installed at the SAME path, so one overwrote the other:\n%s\n' "$dups"
    return 1
}

scaffold "$FLOW_DIR" "claims"
if [ "$SC_RC" -ne 0 ]; then
    t_skip init.claims   "fpga-flow-init exited $SC_RC on the baseline fixture; see $SC_LOG"
    t_skip init.templates "fpga-flow-init exited $SC_RC on the baseline fixture; see $SC_LOG"
else
    t_check init.claims \
        "every 'write' line names a file that exists, is non-empty, and matches the tally" \
        claims_are_true "$SC_DIR"
    t_check init.templates \
        "the walk accounts for every file under templates/, each at its own path" \
        every_template_accounted_for "$FLOW_DIR" "$SC_DIR"
fi

# expand() produces nothing. install_one's `[ -s "$dst" ]` guard must catch it
# before the `write` line is printed - the claim is checked, then made.
#
# WHY THE FAULT IS PLANTED IN expand() AND NOT IN THE GUARD. The other direction
# - a zero-byte file that IS claimed - takes TWO faults to reach: the guard has
# to stop firing AND something has to produce the empty file. Neutering the
# guard alone changes nothing, because in a healthy checkout nothing writes an
# empty one. One fault per copy is the rule, so the proof is aimed at what the
# guard is there to catch. claims_are_true still tells ABSENT from ZERO BYTES,
# because the day that guard moves is the day the distinction starts mattering,
# and a zero-byte file satisfies every `test -e` in the world.
M="$(t_mutant "$SB" emptywrite)"
if t_replace_line "$M" "$INIT_REL" '        "$1" > "$2"' '        /dev/null > "$2"'; then
    scaffold "$M" "emptywrite-mut"
    t_check_fail init.claims.mutation \
        "with expand() producing an empty file, the run does not get to claim it wrote one" \
        claims_are_true "$SC_DIR"
else
    t_skip init.claims.mutation "could not plant the fault: the closing line of expand() in $INIT_REL has changed shape"
fi

# A filter in the walk. The count postcondition is the only thing standing
# between this and a project that is quietly missing three files.
M="$(t_mutant "$SB" dropped)"
if t_replace_line "$M" "$INIT_REL" '    [ -n "$src" ] || continue' \
    '    [ -n "$src" ] || continue; case "$src" in */README.md) continue ;; esac'; then
    scaffold "$M" "dropped-mut"
    t_check_fail init.templates.mutation \
        "with the walk skipping three templates, the accounting goes red rather than handing back a partial tree" \
        every_template_accounted_for "$M" "$SC_DIR"
else
    t_skip init.templates.mutation "could not plant the fault: the walk's guard line in $INIT_REL has changed shape"
fi

#-----------------------------------------------------------------------------
# THE EXIT CODE OF A FAILED POSTCONDITION
#
# fpga-flow-init's header assigns the two failure verbs distinct meanings and
# distinct codes: `refuse` is exit 2, "Nothing was written"; `fail` is exit 1,
# "files were written and the tree is not the one templates/ describes". Its own
# comment says why: "A caller that cannot tell those apart retries the wrong one."
#
# install_one's empty-output guard uses `refuse`, and it runs AFTER expand() has
# created $dst and after earlier templates have already been installed. So the
# one path in the file that most certainly leaves a half-tree behind reports
# exit 2 - the code that promises nothing was written.
#
# Reaching that path needs expand() neutered, which is why this is measured on a
# mutant: the guard is shipped code, but nothing in a healthy checkout can make
# expand() fail. The mutation is the reachability, not the defect.
#
# FIX: `fail` rather than `refuse` at that line. Reported, not fixed here.
#-----------------------------------------------------------------------------
empty_write_is_a_postcondition_failure() {
    local flow="$1" name="$2"
    scaffold "$flow" "$name" || return 2
    if [ -z "$(find "$SC_DIR" -type f 2>/dev/null | head -1)" ]; then
        printf 'nothing was written at all, so exit 2 would be the right code and this\n'
        printf 'assertion no longer describes the situation it was written for\n'
        return 1
    fi
    [ "$SC_RC" -eq 1 ] && return 0
    printf 'files were written and the run exited %s. Exit 2 is documented as\n' "$SC_RC"
    printf '"refused ... Nothing was written"; this left a partial tree behind it:\n'
    find "$SC_DIR" -type f | head -6
    return 1
}

M="$(t_mutant "$SB" emptywrite-code)"
if t_replace_line "$M" "$INIT_REL" '        "$1" > "$2"' '        /dev/null > "$2"'; then
    t_known_defect init.exitcode.emptywrite \
        "an empty write leaves a partial tree, so it is a postcondition failure (1), not a refusal (2)" \
        empty_write_is_a_postcondition_failure "$M" "emptywrite-code-mut"
else
    t_skip init.exitcode.emptywrite "could not reach the guard: the closing line of expand() in $INIT_REL has changed shape"
fi

#=============================================================================
# 3. THE ENTRY CONTRACT (CONTRACT.md section 2)
#
# Three lines and nothing else. The generated Makefile is compared against the
# contract's own fenced block, read out of CONTRACT.md - so the two cannot drift
# apart without this going red, and this file contains no copy of either.
#=============================================================================
t_head "the generated Makefile is CONTRACT section 2's three lines, verbatim"

ENTRY_WANT="$(contract_entry_block)"

## effective_lines <file> - what make actually parses: comments and blanks out.
effective_lines() { grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null; }

entry_is_the_contract() {
    local dir="$1" got
    got="$(effective_lines "$dir/fpga/Makefile")"
    [ "$got" = "$ENTRY_WANT" ] && return 0
    printf 'the scaffolded fpga/Makefile is not the entry contract.\n'
    printf 'CONTRACT.md section 2:\n%s\n---\nfpga/Makefile:\n%s\n' "$ENTRY_WANT" "$got"
    return 1
}

## design.mk "also ends with the same include, so it is self-sufficient when
## included directly" (CONTRACT.md section 2). mk/flow.mk's include guard is what
## makes the double include safe; without the trailing include, a makefile that
## includes design.mk directly gets a manifest and no engine.
designmk_ends_with_the_include() {
    local dir="$1" want last
    want="$(printf '%s\n' "$ENTRY_WANT" | tail -1)"
    last="$(effective_lines "$dir/fpga/design.mk" | tail -1)"
    [ "$last" = "$want" ] && return 0
    printf 'design.mk does not end with the engine include CONTRACT section 2 requires.\n'
    printf 'want: %s\ngot : %s\n' "$want" "$last"
    return 1
}

# A SINGLE SKIP REASON FOR THE WHOLE SECTION, decided before anything asserts.
#
# THE ORDER HERE IS THE POINT. The first draft tested SC_RC and only then called
# scaffold, so it was reading the exit status of the LAST run of the previous
# section - a deliberately broken mutant - and skipped two real assertions with a
# reason that was true of a different run. A skip carrying a reason about the
# wrong thing is worse than a reasonless one: it is an explanation, and it is a
# false one.
ENTRY_SKIP=""
if [ -z "$ENTRY_WANT" ]; then
    ENTRY_SKIP="CONTRACT.md section 2 has no fenced make block in this checkout, so there is nothing authoritative to compare the generated Makefile against - and comparing it against a copy spelled in this file would only prove this file agrees with itself"
else
    scaffold "$FLOW_DIR" "entry"
    [ "$SC_RC" -eq 0 ] || ENTRY_SKIP="fpga-flow-init exited $SC_RC scaffolding this section's fixture; see $SC_LOG. Nothing downstream of it can be measured"
fi

if [ -n "$ENTRY_SKIP" ]; then
    for id in entry entry.mutation designmk.include designmk.include.mutation; do
        t_skip "init.$id" "$ENTRY_SKIP"
    done
else
    t_check init.entry \
        "fpga/Makefile parses to exactly the three lines CONTRACT section 2 prints" \
        entry_is_the_contract "$SC_DIR"
    t_check init.designmk.include \
        "design.mk ends with the same engine include, so it stands alone" \
        designmk_ends_with_the_include "$SC_DIR"

    M="$(t_mutant "$SB" entry)"
    if t_replace_line "$M" templates/Makefile.in \
        'include $(FPGA_FLOW_DIR)/mk/flow.mk' \
        '# the engine include, removed by a mutation proof'; then
        scaffold "$M" "entry-mut"
        t_check_fail init.entry.mutation \
            "with the engine include dropped from the template, the generated Makefile stops matching the contract" \
            entry_is_the_contract "$SC_DIR"
    else
        t_skip init.entry.mutation "could not plant the fault: templates/Makefile.in has no line exactly 'include \$(FPGA_FLOW_DIR)/mk/flow.mk'"
    fi

    M="$(t_mutant "$SB" designmk)"
    if t_replace_line "$M" templates/design.mk.in \
        'include $(FPGA_FLOW_DIR)/mk/flow.mk' \
        '# the engine include, removed by a mutation proof'; then
        scaffold "$M" "designmk-mut"
        t_check_fail init.designmk.include.mutation \
            "with the trailing include dropped, design.mk is no longer self-sufficient and the assertion goes red" \
            designmk_ends_with_the_include "$SC_DIR"
    else
        t_skip init.designmk.include.mutation "could not plant the fault: templates/design.mk.in has no line exactly 'include \$(FPGA_FLOW_DIR)/mk/flow.mk'"
    fi
fi

#=============================================================================
# 4. THE MARKERS - where they are meant to be, and NOWHERE ELSE
#
# <<FILL IN>> is the one thing expand() must never substitute: turning "you have
# not decided this yet" into a value is a decision nobody made. The comparison is
# against templates/ itself, so this file spells no expected count.
#
# @PART@ is the single deliberate exception. With no --part the scaffolder
# substitutes a MARKER, so `make check` names the device in the same list as
# everything else instead of the manifest quietly claiming one.
#=============================================================================
t_head "markers appear where the templates put them, and only there"

markers_match_the_templates() {
    local flow="$1" dir="$2" want got
    want="$(marker_profile "$flow/templates")"
    got="$(marker_profile "$dir/fpga")"
    if [ -z "$want" ]; then
        printf 'no template carries a marker, so this comparison would pass on any scaffold\n'
        return 1
    fi
    [ "$want" = "$got" ] && return 0
    printf 'the scaffold does not carry the templates markers, file for file.\n'
    printf 'A marker that VANISHED is a decision made for the project; one that APPEARED is\n'
    printf 'scaffolding in a file that was meant to be finished.\n'
    printf 'templates/ (marker lines per file, sorted):\n%s\n---\nscaffold:\n%s\n' "$want" "$got"
    return 1
}

## markers_gain_exactly_the_part_lines <toolkit> <project dir>
##
## The no---part case. The extra markers must be exactly the lines the templates
## spell @PART@ on - counted from the templates, not asserted as "two".
markers_gain_exactly_the_part_lines() {
    local flow="$1" dir="$2" want got n_part
    want="$(marker_lines "$flow/templates")"
    got="$(marker_lines "$dir/fpga")"
    n_part="$(grep -rE '@PART@' "$flow/templates" 2>/dev/null | grep -c .)"
    [ "$n_part" -gt 0 ] || { printf 'no template spells @PART@, so this assertion measures nothing\n'; return 1; }
    [ "$got" -eq "$((want + n_part))" ] && return 0
    printf 'scaffolding WITHOUT --part should leave the device undecided, and it is the\n'
    printf 'only value allowed to become a marker.\n'
    printf 'templates: %s marker line(s), @PART@ on %s line(s) -> expected %s; got %s.\n' \
        "$want" "$n_part" "$((want + n_part))" "$got"
    printf 'Fewer means design.mk now states a device nobody chose.\n'
    return 1
}

## every_placeholder_expanded <toolkit> <project dir>
every_placeholder_expanded() {
    local flow="$1" dir="$2" p n=0 left=""
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        n=$((n + 1))
        grep -rqF -- "$p" "$dir/fpga" 2>/dev/null && left="$left $p"
    done < <(template_placeholders "$flow")
    [ "$n" -gt 0 ] || { printf 'the templates spell no @NAME@ placeholder, so nothing was measured\n'; return 1; }
    [ -z "$left" ] && return 0
    printf 'the scaffold still carries unexpanded template placeholder(s):%s\n' "$left"
    printf 'A literal @BOARD@ in a manifest is not an error anywhere: make treats it as a\n'
    printf 'word, Vivado as a filename, and the run fails somewhere else entirely.\n'
    for p in $left; do grep -rnF -- "$p" "$dir/fpga" | head -3; done
    return 1
}

PACK1="$(pack_dirs "$FLOW_DIR" | head -1)"
if [ -z "$PACK1" ]; then
    t_skip init.markers.shape "this checkout ships no part pack, so no --part value exists that would resolve the device and leave the template's own markers as the only ones"
else
    scaffold "$FLOW_DIR" "markers" --part "$PACK1"
    t_check init.markers.shape \
        "with --part given, the scaffold's markers are the templates' markers, file for file" \
        markers_match_the_templates "$FLOW_DIR" "$SC_DIR"
fi

scaffold "$FLOW_DIR" "markers-nopart"
t_check init.markers.part \
    "with no --part, the only markers added are the @PART@ lines - the device stays undecided" \
    markers_gain_exactly_the_part_lines "$FLOW_DIR" "$SC_DIR"
t_check init.placeholders \
    "no @NAME@ placeholder survives into the project" \
    every_placeholder_expanded "$FLOW_DIR" "$SC_DIR"

# expand() substitutes the marker away. Every path check stays green - the files
# all exist - and the project ships with a clock period nobody chose.
M="$(t_mutant "$SB" markerstrip)"
if t_replace_line "$M" "$INIT_REL" '        "$1" > "$2"' \
    '        -e "s|FILL IN|DECIDED|g" "$1" > "$2"'; then
    if [ -z "$PACK1" ]; then
        t_skip init.markers.shape.mutation "this checkout ships no part pack, so the baseline assertion this proof belongs to did not run"
    else
        scaffold "$M" "markerstrip-mut" --part "$PACK1"
        t_check_fail init.markers.shape.mutation \
            "with expand() substituting the marker, the scaffold looks finished and the assertion goes red" \
            markers_match_the_templates "$M" "$SC_DIR"
    fi
else
    t_skip init.markers.shape.mutation "could not plant the fault: the closing line of expand() in $INIT_REL has changed shape"
fi

# The manifest quietly claims a device. This is the exact thing the PART_SUBST
# branch's own comment forbids - "the manifest must not quietly claim a device".
M="$(t_mutant "$SB" partinvent)"
if t_replace_line "$M" "$INIT_REL" \
    '    PART_SUBST="<<FILL IN: the device, or delete this line and let the board pack say>>"' \
    '    PART_SUBST="unknown"'; then
    scaffold "$M" "partinvent-mut"
    t_check_fail init.markers.part.mutation \
        "with a device invented for an omitted --part, the marker count drops and the assertion goes red" \
        markers_gain_exactly_the_part_lines "$M" "$SC_DIR"
else
    t_skip init.markers.part.mutation "could not plant the fault: the PART_SUBST default in $INIT_REL has changed shape"
fi

# One substitution silently stops firing. @BOARD@ is chosen because it reaches
# both design.mk and the board pack, so the failure is broad and still silent.
M="$(t_mutant "$SB" placeholder)"
if t_mutate "$M" "$INIT_REL" 's|@BOARD@|@NOTBOARD@|'; then
    scaffold "$M" "placeholder-mut"
    t_check_fail init.placeholders.mutation \
        "with one substitution aimed at a placeholder no template spells, @BOARD@ survives into the project" \
        every_placeholder_expanded "$M" "$SC_DIR"
else
    t_skip init.placeholders.mutation "could not plant the fault: @BOARD@ no longer appears in $INIT_REL"
fi

#=============================================================================
# 5. RE-RUNNING OVER A LIVE PROJECT
#
# The header claims "It NEVER overwrites an existing file unless --force is
# given... this script is safe to re-run on a live project." It does not REFUSE
# the whole run - it declines file by file and exits 0, which is the stronger
# behaviour: a project that has grown a second board re-runs init to scaffold it
# and keeps everything already written.
#
# Both directions need proving. Without --force the edit must survive; WITH
# --force it must not, or "safe to re-run" would be indistinguishable from a
# script that had stopped writing anything at all.
#=============================================================================
t_head "a re-run keeps the project's own edits, and --force is what overrides that"

rerun_keeps_edits() {
    local flow="$1" name="$2" dir rc=0
    scaffold "$flow" "$name" || return 2
    [ "$SC_RC" -eq 0 ] || { printf 'the first scaffold failed (rc %s)\n' "$SC_RC"; tail -6 "$SC_LOG"; return 1; }
    dir="$SC_DIR"
    printf '%s\n' "$SENTINEL" >> "$dir/fpga/design.mk"
    "$flow/$INIT_REL" --block "$BLOCK_N" --board "$BOARD_N" "$dir" > "$dir.rerun.log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 're-running over an existing project failed (rc %s) - the header calls this safe:\n' "$rc"
        tail -8 "$dir.rerun.log"; return 1
    fi
    if [ "$(tail -1 "$dir/fpga/design.mk")" != "$SENTINEL" ]; then
        printf 'the re-run OVERWROTE the project own design.mk without --force.\n'
        printf 'Everything the project had decided is gone, and the run exited 0.\n'
        return 1
    fi
    grep -qE '^   0 file\(s\) written, [1-9][0-9]* left alone' "$dir.rerun.log" && return 0
    printf 'the edit survived but the report does not say nothing was written:\n'
    grep -E 'file\(s\) written' "$dir.rerun.log"
    return 1
}

force_rewrites() {
    local flow="$1" name="$2" dir rc=0
    scaffold "$flow" "$name" || return 2
    [ "$SC_RC" -eq 0 ] || { printf 'the first scaffold failed (rc %s)\n' "$SC_RC"; tail -6 "$SC_LOG"; return 1; }
    dir="$SC_DIR"
    printf '%s\n' "$SENTINEL" >> "$dir/fpga/design.mk"
    "$flow/$INIT_REL" --block "$BLOCK_N" --board "$BOARD_N" --force "$dir" > "$dir.force.log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        printf '--force failed (rc %s)\n' "$rc"; tail -8 "$dir.force.log"; return 1
    fi
    if [ "$(tail -1 "$dir/fpga/design.mk")" = "$SENTINEL" ]; then
        printf '--force did NOT overwrite. The no-clobber assertion beside this one would\n'
        printf 'then pass against a scaffolder that had stopped writing files altogether.\n'
        return 1
    fi
    grep -qE '^   [1-9][0-9]* file\(s\) written, 0 left alone' "$dir.force.log" && return 0
    printf '--force rewrote the file but the report does not say everything was written:\n'
    grep -E 'file\(s\) written' "$dir.force.log"
    return 1
}

t_check init.noclobber \
    "a second run without --force leaves every existing file alone, and says so" \
    rerun_keeps_edits "$FLOW_DIR" "noclobber"

t_check init.force \
    "--force rewrites the same file, so the refusal above is about the flag and not about inertness" \
    force_rewrites "$FLOW_DIR" "force"

M="$(t_mutant "$SB" noclobber)"
if t_replace_line "$M" "$INIT_REL" '    if [ -e "$dst" ] && [ "$FORCE" -eq 0 ]; then' \
    '    if false; then'; then
    t_check_fail init.noclobber.mutation \
        "with the exists-check disabled, a plain re-run silently destroys the project's work" \
        rerun_keeps_edits "$M" "noclobber-mut"
else
    t_skip init.noclobber.mutation "could not plant the fault: install_one's exists-check in $INIT_REL has changed shape"
fi

M="$(t_mutant "$SB" force)"
if t_replace_line "$M" "$INIT_REL" '        --force)    FORCE=1; shift ;;' \
    '        --force)    FORCE=0; shift ;;'; then
    t_check_fail init.force.mutation \
        "with --force parsed but ignored, the documented escape hatch is gone and the assertion goes red" \
        force_rewrites "$M" "force-mut"
else
    t_skip init.force.mutation "could not plant the fault: the --force arm of the argument loop in $INIT_REL has changed shape"
fi

#=============================================================================
# 6. CONTAINMENT, AND WHAT IT REFUSES TO START
#
# "it never touches anything outside <project-dir>/fpga/" - the header. A
# scaffolder is usually pointed at a directory that already holds somebody's RTL.
#
# And the two failure verbs: exit 2 is documented as "refused ... Nothing was
# written". A refusal that has already created the project directory is a
# different promise from the one the caller read.
#=============================================================================
t_head "it writes inside fpga/ only, and a refusal leaves no trace"

touches_only_fpga() {
    local flow="$1" name="$2" dir before after rc=0
    dir="$SB/proj-$name"
    t_in_sandbox "$dir" || return 2
    rm -rf "$dir"; mkdir -p "$dir/src"
    printf 'the project owns this file\n' > "$dir/keep.txt"
    printf 'module %s;\nendmodule\n' "$BLOCK_N" > "$dir/src/top.v"
    # Names AND contents: a scaffolder that rewrote src/top.v in place would
    # leave the tree listing identical.
    before="$( cd "$dir" && find . -not -path './fpga*' | LC_ALL=C sort; cat keep.txt src/top.v )"
    "$flow/$INIT_REL" --block "$BLOCK_N" --board "$BOARD_N" "$dir" > "$dir.log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'scaffolding into a project directory that already had files failed (rc %s):\n' "$rc"
        tail -8 "$dir.log"; return 1
    fi
    [ -d "$dir/fpga" ] || { printf 'no fpga/ was created, so "it touched nothing else" is trivially true\n'; return 1; }
    after="$( cd "$dir" && find . -not -path './fpga*' | LC_ALL=C sort; cat keep.txt src/top.v )"
    [ "$before" = "$after" ] && return 0
    printf 'the scaffolder changed something outside fpga/:\n'
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -12
    return 1
}

## refused_and_wrote_nothing <toolkit> <name> <args...>
## The destination for the cases that pass one is $SB/refuse-<name>, so its
## absence afterwards is the whole assertion.
refused_and_wrote_nothing() {
    local flow="$1" name="$2"; shift 2
    local dir="$SB/refuse-$name" rc=0
    t_in_sandbox "$dir" || return 2
    rm -rf "$dir"
    "$flow/$INIT_REL" "$@" > "$dir.log" 2>&1 || rc=$?
    if [ "$rc" -ne 2 ]; then
        printf 'expected exit 2 (refused, nothing written); got %s.\n' "$rc"
        printf 'Exit 1 means "files were written and the tree is wrong" and exit 0 means it\n'
        printf 'accepted the input - three different things for the caller to do next.\n'
        tail -8 "$dir.log"; return 1
    fi
    [ -e "$dir" ] || return 0
    printf 'the run exited 2 - which its own header defines as "Nothing was written" - and\n'
    printf 'yet %s exists:\n' "$dir"
    find "$dir" | head -10
    return 1
}

t_check init.containment \
    "scaffolding into a populated project leaves everything outside fpga/ byte-identical" \
    touches_only_fpga "$FLOW_DIR" "containment"

t_check init.refuse.block \
    "--block with a path separator is refused - it would escape fpga/ and corrupt every artefact name" \
    refused_and_wrote_nothing "$FLOW_DIR" "block" --block "a/b" --board "$BOARD_N" "$SB/refuse-block"

t_check init.refuse.board \
    "--board with a path separator is refused - it becomes a directory name and a Tcl word" \
    refused_and_wrote_nothing "$FLOW_DIR" "board" --block "$BLOCK_N" --board "b/b" "$SB/refuse-board"

t_check init.refuse.missing \
    "a missing project directory is refused before anything is created" \
    refused_and_wrote_nothing "$FLOW_DIR" "missing" --block "$BLOCK_N" --board "$BOARD_N"

M="$(t_mutant "$SB" containment)"
if t_replace_line "$M" "$INIT_REL" '    install_one "$src" "$FPGA/$(dest_for "$rel")"' \
    '    install_one "$src" "$DEST/$(dest_for "$rel")"'; then
    t_check_fail init.containment.mutation \
        "with the walk installing into the project root, files land beside the project's own RTL" \
        touches_only_fpga "$M" "containment-mut"
else
    t_skip init.containment.mutation "could not plant the fault: the template walk's install line in $INIT_REL has changed shape"
fi

# NOTE ON THE EMPTY-ARGUMENT CASES. An empty --block is guarded TWICE - by the
# `[ -n "$BLOCK" ]` line and again by the `''|` arm of the name check - so no
# SINGLE planted fault can make it through, and a proof aimed at it would be
# reporting a deleted guard as working. That is the same defence-in-depth trap
# t_contract.sh documents for RUN_TAG. The missing-argument proof is therefore
# aimed at DEST, which is guarded once.
M="$(t_mutant "$SB" blockname)"
if t_replace_line "$M" "$INIT_REL" "    ''|*[!A-Za-z0-9_]*)" "    ''|*[!A-Za-z0-9_/]*)"; then
    t_check_fail init.refuse.block.mutation \
        "with '/' allowed in a block name, the refusal stops firing and a project is scaffolded" \
        refused_and_wrote_nothing "$M" "block" --block "a/b" --board "$BOARD_N" "$SB/refuse-block"
else
    t_skip init.refuse.block.mutation "could not plant the fault: the --block name check in $INIT_REL has changed shape"
fi

M="$(t_mutant "$SB" boardname)"
if t_replace_line "$M" "$INIT_REL" '    *[!A-Za-z0-9_.-]*|*/*)' '    *[!A-Za-z0-9_./-]*)'; then
    t_check_fail init.refuse.board.mutation \
        "with '/' allowed in a board name, the refusal stops firing" \
        refused_and_wrote_nothing "$M" "board" --block "$BLOCK_N" --board "b/b" "$SB/refuse-board"
else
    t_skip init.refuse.board.mutation "could not plant the fault: the --board name check in $INIT_REL has changed shape"
fi

M="$(t_mutant "$SB" destarg)"
if t_replace_line "$M" "$INIT_REL" \
    '[ -n "$DEST"  ] || { usage >&2; refuse "a project directory is required"; }' ':'; then
    t_check_fail init.refuse.missing.mutation \
        "with the destination guard removed, the run dies somewhere else with a different code" \
        refused_and_wrote_nothing "$M" "missing" --block "$BLOCK_N" --board "$BOARD_N"
else
    t_skip init.refuse.missing.mutation "could not plant the fault: the DEST guard in $INIT_REL has changed shape"
fi

#=============================================================================
# 7. THE PART-PACK LIST COMES FROM THE DIRECTORY
#
# CONTRACT rule three, and this repository's founding defect: the reference
# toolkit hardcodes a FIVE-entry step-override whitelist against a SEVEN-file
# directory, so two real extension points are undocumented and warn spuriously.
#
# `--help` is where a new user learns what --part accepts, so a list that is
# right today and hardcoded is a list that is wrong the day a pack is added -
# and nothing anywhere says so. part_packs()'s own comment records the other
# half: a naive `ls part/` offers README.md and pack_api.tcl as devices, and a
# list that names a thing --part cannot take is worse than no list, because the
# reader tries it.
#=============================================================================
t_head "the part packs --help offers are the directories under part/"

packs_come_from_the_directory() {
    local flow="$1" want got
    want="$(pack_dirs "$flow")"
    got="$(offered_packs "$flow")"
    if [ -z "$want" ]; then
        printf '%s\n' "$got" | grep -q '(none' && return 0
        printf 'part/ holds no pack directories and --help did not say so explicitly.\n'
        printf 'A blank where a list should be reads as "the question was not asked".\n%s\n' "$got"
        return 1
    fi
    [ "$want" = "$got" ] && return 0
    printf 'the packs --help offers are not the directories under part/.\n'
    printf 'find part/ -type d:\n%s\n---\n--help offers:\n%s\n' "$want" "$got"
    return 1
}

t_check init.packs \
    "--help offers exactly the pack directories, derived at run time" \
    packs_come_from_the_directory "$FLOW_DIR"

# THE REFERENCE TOOLKIT'S DEFECT, with this repository's own numbers: a list that
# is correct on the day it is written, against a directory that then grows. The
# names are generated from the directory, so this file still carries no copy of
# the pack list.
M="$(t_mutant "$SB" packshardcoded)"
HARD="$(pack_dirs "$FLOW_DIR" | sed 's/^/echo /' | paste -sd';' -)"
if [ -z "$HARD" ]; then
    t_skip init.packs.mutation.hardcoded "this checkout ships no part pack, so there is no list to hardcode and no directory for it to drift from"
elif t_replace_line "$M" "$INIT_REL" \
    "      for d in */; do [ -d \"\$d\" ] || continue; printf '%s\\n' \"\${d%/}\"; done )" \
    "      { $HARD; } )"; then
    mkdir -p "$M/part/zz_pack_added_after_the_list_was_written"
    t_check_fail init.packs.mutation.hardcoded \
        "with the list hardcoded and one pack added, a real device is not offered and the assertion goes red" \
        packs_come_from_the_directory "$M"
else
    t_skip init.packs.mutation.hardcoded "could not plant the fault: part_packs() in $INIT_REL has changed shape"
fi

M="$(t_mutant "$SB" packsnaive)"
if t_replace_line "$M" "$INIT_REL" \
    "      for d in */; do [ -d \"\$d\" ] || continue; printf '%s\\n' \"\${d%/}\"; done )" \
    "      for d in *; do printf '%s\\n' \"\$d\"; done )"; then
    t_check_fail init.packs.mutation.naive \
        "with a naive listing, README.md and pack_api.tcl are offered as devices" \
        packs_come_from_the_directory "$M"
else
    t_skip init.packs.mutation.naive "could not plant the fault: part_packs() in $INIT_REL has changed shape"
fi

#=============================================================================
# 8. THE EXECUTABLE BIT
#
# install_one chmods `*.sh` and `*/run_*`. No template in this checkout matches
# either, so the claim is currently unexercised - which is exactly when a line
# stops working without anyone noticing. The first `run_*.sh` template added
# would install unrunnable, and the error a user sees is "Permission denied"
# from a shell, several steps from the scaffolder.
#
# BOTH the assertion and its proof run against COPIES carrying an added template,
# because this suite must not write into the checkout it is measuring. The same
# arrangement t_contract.sh uses for the examples/ refusal.
#=============================================================================
t_head "a template that is meant to be run installs runnable"

PROBE_REL="templates/run_probe.sh"
PROBE_OUT="fpga/run_probe.sh"

add_probe_template() {   # <mutant> - a template matching BOTH chmod arms
    printf '#!/bin/sh\n# a probe template planted by t_init.sh\necho @BLOCK@\n' > "$1/$PROBE_REL"
}

installs_executable() {
    local flow="$1" name="$2"
    scaffold "$flow" "$name" || return 2
    [ "$SC_RC" -eq 0 ] || { printf 'the scaffold failed (rc %s)\n' "$SC_RC"; tail -6 "$SC_LOG"; return 1; }
    if [ ! -f "$SC_DIR/$PROBE_OUT" ]; then
        printf 'the added template did not install at %s. It claimed:\n' "$PROBE_OUT"
        sc_written "$SC_LOG"
        return 1
    fi
    [ -x "$SC_DIR/$PROBE_OUT" ] && return 0
    printf '%s installed without its executable bit, so it is a script nobody can run:\n' "$PROBE_OUT"
    ls -l "$SC_DIR/$PROBE_OUT"
    return 1
}

EXEC_BASE="$(t_mutant "$SB" execbaseline)"
add_probe_template "$EXEC_BASE"
t_check init.exec \
    "a run_*.sh template installs with its executable bit set" \
    installs_executable "$EXEC_BASE" "exec"

M="$(t_mutant "$SB" execchmod)"
add_probe_template "$M"
if t_replace_line "$M" "$INIT_REL" '        *.sh|*/run_*) chmod +x "$dst" ;;' \
    '        *.this_suffix_matches_nothing) : ;;'; then
    t_check_fail init.exec.mutation \
        "with the chmod arm aimed at nothing, the same template installs unrunnable" \
        installs_executable "$M" "exec-mut"
else
    t_skip init.exec.mutation "could not plant the fault: install_one's chmod case in $INIT_REL has changed shape"
fi

t_summary
