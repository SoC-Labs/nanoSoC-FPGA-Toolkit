#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# t_provenance.sh - flow/common/provenance.tcl: WHAT DESIGN DID THIS MEASURE?
#
# DEFECT CLASS: TWO REPORTS THAT DESCRIBE DIFFERENT DESIGNS AND SAY NOTHING
# ABOUT IT.
#
# provenance.tcl's own header records three wrong conclusions drawn in one week
# on the reference project by comparing two stage reports that were each
# internally consistent and were about different builds. Nothing in either file
# said which DESIGN it was about, so nothing could refuse the comparison. This
# file is what `compare-runs` reads, which makes every one of its properties a
# property somebody's conclusion rests on - and every one of them fails
# SILENTLY: a manifest with a field missing, a field blank, a `0` where nothing
# was measured, or a raw vendor mount point in it still looks like a manifest.
#
# The five things asserted here, and why each is load-bearing:
#
#   1. THE SEVEN BLOCKS ARE IN CONTRACT.md SECTION 5 ORDER. A manifest is read
#      by `diff`. Two manifests whose blocks moved diff as though every field
#      changed, and the reader stops using the tool.
#   2. A SITE PATH APPEARS ONLY AS A `sha256:` DIGEST. This is a DISCLOSURE
#      rule, not a formatting preference: a manifest gets pasted into bug
#      reports, issue trackers and vendor support tickets, and a vendor mount
#      point plus a revision-coded release directory says which IP this site
#      licences and which release of it. Both directions are proved - an
#      in-tree path IS shown as a `<project>/`-style label, because the reader
#      needs it and the repository already publishes it, and an out-of-tree one
#      is NOT shown at all.
#   3. A COUNT NOBODY TOOK IS THE LITERAL TOKEN `unmeasured`, NEVER `0`.
#      CONTRACT.md rule 2: `0` is a legitimate measurement - zero unrouted
#      nets - and a flow that writes `0` for "did not look" makes its best
#      result and its blindest one identical.
#   4. A FIELD THE COLLECTOR COULD NOT READ IS `UNVERIFIED:<reason>`, NEVER
#      BLANK AND NEVER ABSENT. Two empty strings compare EQUAL, which turns a
#      missing measurement into agreement.
#   5. THE KNOBS ARE ENUMERATED FROM THE `opt` DECLARATIONS. The reference
#      toolkit's hand-maintained list had already silently dropped three effort
#      knobs, every one of which changes QoR, so two runs that differed in
#      placement effort produced manifests that agreed.
#
# ...and that BOTH git shas are recorded with their dirty flags, because a run
# is the product of two repositories and a manifest carrying only the design's
# sha cannot tell "the RTL changed" from "the flow changed". The reference
# project's shipping GDS is unreproducible for exactly that reason.
#
# Everything runs under bare `tclsh`: provenance.tcl calls no Vivado command
# unguarded, and a collector that assumed a tool would take this suite with it.
#
# Every assertion is PAIRED WITH A MUTATION PROOF, planted with t_replace_line /
# t_mutate so that an edit which changed nothing is a LOUD failure rather than a
# proof that silently measures an empty path. See the note above the last proof
# in t_verdicts.sh for what that looks like when it goes wrong.
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
PV="$FLOW_DIR/flow/common/provenance.tcl"
if [ ! -f "$PV" ]; then
    t_skip prov.all "no flow/common/provenance.tcl at $PV - nothing to test, and an absent file is not a passing one"
    t_summary; exit $?
fi
if ! command -v tclsh >/dev/null 2>&1; then
    t_skip prov.all "no tclsh on PATH - provenance.tcl is designed to load in a bare tclsh and that is the only tool-free way to drive it"
    t_summary; exit $?
fi
if ! command -v sha256sum >/dev/null 2>&1; then
    t_skip prov.all "no sha256sum on PATH - provenance.tcl shells out to it for every digest (deliberately: tcllib is absent from the Tcl inside the EDA tools on this host), so every field under test would be UNVERIFIED:sha256sum-failed"
    t_summary; exit $?
fi

#=============================================================================
# THE FIXTURE
#
# FOUR TREES, and the geometry is the whole point of the site-path assertions:
#
#   $P/proj    the PROJECT       (a git repo, made DIRTY by an UNTRACKED file)
#   $P/tk      the TOOLKIT root  (a git repo, clean)
#   $P/run     this RUN's output tree
#   $P/site    OUTSIDE ALL THREE - a stand-in for a vendor mount, shaped like
#              one: <root>/vendor_ip/rel_1.2/. Nothing in a manifest may name it.
#
# The toolkit ROOT the manifest is told about ($P/tk) is deliberately NOT the
# checkout being tested. That keeps two things out of the assertions: this
# repository's real git state, which several sessions are committing to while
# this suite runs, and its real path.
#=============================================================================
P="$SB/p"
mkdir -p "$P/proj/rtl" "$P/tk" "$P/run/work" "$P/run/logs" "$P/run/reports" \
         "$P/run/outputs" "$P/site/vendor_ip/rel_1.2/include"
printf 'module in_project; endmodule\n'  > "$P/proj/rtl/in.v"
printf 'module vendor_a; endmodule\n'    > "$P/site/vendor_ip/rel_1.2/ip_a.v"
printf 'module vendor_b; endmodule\n'    > "$P/site/vendor_ip/rel_1.2/ip_b.v"
SITE_A="$P/site/vendor_ip/rel_1.2/ip_a.v"
SITE_B="$P/site/vendor_ip/rel_1.2/ip_b.v"

# --- the two git repositories ------------------------------------------------
# GIT_CONFIG_GLOBAL/SYSTEM=/dev/null and --template= so this cannot inherit the
# user's hooks, templates or identity - the fixture has to mean the same thing
# on a laptop and on a build host.
GIT_OK=0
git_fixture() {
    local d="$1"
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
        git -C "$d" init -q --template= >/dev/null 2>&1 || return 1
    printf 'tracked\n' > "$d/tracked.txt"
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
        git -C "$d" add -A >/dev/null 2>&1 || return 1
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
        git -C "$d" -c user.email=t@example.invalid -c user.name=t \
            -c commit.gpgsign=false commit -q -m "fixture" >/dev/null 2>&1 || return 1
    return 0
}
if command -v git >/dev/null 2>&1 && git_fixture "$P/proj" && git_fixture "$P/tk"; then
    # DIRTY BY AN UNTRACKED FILE ONLY. `git describe --dirty` IGNORES untracked
    # files; `git status --porcelain` does not. That difference is the reason
    # provenance.tcl decides dirtiness from status, and it is what the mutation
    # proof for the dirty flag plants.
    printf 'an override nobody committed\n' > "$P/proj/untracked_override.tcl"
    GIT_OK=1
fi

#=============================================================================
# THE DRIVER
#
# prov_manifest() is normally reached through flow_boot, which loads the part
# and board packs. This stands in for the stage: it publishes the four
# directories flow_boot publishes, registers two knobs exactly as a stage's
# `opt` declarations would, and writes the manifest. Nothing about the file
# under test is stubbed.
#
# FLOW_T0 IS DELIBERATELY NOT SET, so `runtime_s` takes the unmeasured path -
# which is the only place in the whole flow that the `unmeasured` token is
# actually emitted, and therefore the only place it can be tested end to end.
#=============================================================================
cat > "$SB/prov_drive.tcl" <<'TCL'
set tk    [lindex $::argv 0]
set stage [lindex $::argv 1]
source [file join $tk flow common flow_utils.tcl]
flow_config prefix PROV
source [file join $tk flow common provenance.tcl]
set WORK_DIR    $::env(FPGA_WORK_DIR)
set IN_WORK_DIR $::env(FPGA_WORK_DIR)
set LOG_DIR     $::env(FPGA_LOG_DIR)
set REPORT_DIR  $::env(FPGA_REPORT_DIR)
set OUT_DIR     $::env(FPGA_OUT_DIR)
# Two of the toolkit's own knobs, registered exactly as read_flist.tcl registers
# them at its left margin. FLIST_INCDIRS is a knob whose VALUE IS A PATH.
opt T_PROV_EMPTY_KNOB ""
opt FLIST_INCDIRS     ""
if {[info exists ::env(T_PROV_FILES)]} { set ::PROV_FILES $::env(T_PROV_FILES) }
puts [prov_manifest $stage]
TCL

# A second, smaller driver for the two token procs, which no stage path reaches
# with a value this suite controls.
cat > "$SB/prov_tokens.tcl" <<'TCL'
set tk  [lindex $::argv 0]
set out [lindex $::argv 1]
source [file join $tk flow common flow_utils.tcl]
flow_config prefix PROV
source [file join $tk flow common provenance.tcl]
prov_unmeasured  cells.unrouted
prov_unverified  reports.timing "no-report-at-stage-end"
prov_write $out
TCL

MAN=""
PROV_OUT=""
## prov_run <toolkit> <stage> [flist] [PROV_FILES] [FLIST_INCDIRS]
## Writes $P/run/reports/<stage>_manifest.txt and leaves its path in MAN.
prov_run() {
    local tk="$1" stage="$2" flist="${3:-}" pfiles="${4:-}" incdirs="${5:-}"
    local rd="$P/run/reports" rc=0
    rm -f "$rd/${stage}_manifest.txt"
    PROV_OUT="$(env \
        FPGA_DIR="$P/proj" FPGA_PROJECT_ROOT="$P/proj" FPGA_FLOW_DIR="$P/tk" \
        FPGA_RUN_DIR="$P/run" FPGA_WORK_DIR="$P/run/work" FPGA_LOG_DIR="$P/run/logs" \
        FPGA_REPORT_DIR="$rd" FPGA_OUT_DIR="$P/run/outputs" \
        FPGA_RTL_FLIST="$flist" T_PROV_FILES="$pfiles" FLIST_INCDIRS="$incdirs" \
        timeout 60 tclsh "$SB/prov_drive.tcl" "$tk" "$stage" 2>&1)" || rc=$?
    MAN="$rd/${stage}_manifest.txt"
    if [ "$rc" -ne 0 ] || [ ! -s "$MAN" ]; then
        printf 'the manifest writer failed (exit %d) or wrote nothing:\n%s\n' "$rc" "$PROV_OUT"
        return 1
    fi
    return 0
}

## first_line <regex> - line number of the first manifest line matching, or ""
first_line() { grep -nE -m1 -- "$1" "$MAN" | cut -d: -f1; }

# A third driver, for BLOCK 8 and the GATE FILE - the two artefacts a stage
# contributes to itself. Neither is reachable through prov_manifest, which is
# the whole reason both were written six times before they were written once.
#
# The fixture is chosen to exercise every branch of the value rule in one run:
#
#   vendor_src       a RAW SITE PATH. Must come out as sha256: and never in clear.
#   in_tree_src      ALREADY put through prov_site_path by the caller, as three
#                    of the six stage scripts do. Must come out UNCHANGED.
#   never_taken      recorded as "". Must become the token `unmeasured`.
#   explicitly_none  recorded as "(none)". Must stay "(none)" - a different fact.
#   zero_count       a measured 0. Must stay 0 (CONTRACT.md rule 2, other way up).
#
# The gate's delegated list carries a bullet with an EMBEDDED NEWLINE whose
# second line starts at column 0 with a capital, followed by a second bullet.
# That is the exact shape that truncates a section under ci/assert-stage.sh's
# awk, and the second bullet is what disappears when it does.
cat > "$SB/prov_stage.tcl" <<'TCL'
set tk    [lindex $::argv 0]
set stage [lindex $::argv 1]
set stem  [lindex $::argv 2]
source [file join $tk flow common flow_utils.tcl]
flow_config prefix PROV
source [file join $tk flow common provenance.tcl]
set WORK_DIR    $::env(FPGA_WORK_DIR)
set IN_WORK_DIR $::env(FPGA_WORK_DIR)
set LOG_DIR     $::env(FPGA_LOG_DIR)
set REPORT_DIR  $::env(FPGA_REPORT_DIR)
set OUT_DIR     $::env(FPGA_OUT_DIR)

# The four identity globals flow_boot publishes, which prov_gate puts in the
# gate's second line.
set block_name  demo_block
set RUN_TAG     [flow_env FPGA_RUN_TAG default]
set board_name  demo_board
set part_name   demo_part

prov_stage_field vendor_src      $::env(T_SITE_FILE)
prov_stage_field in_tree_src     [prov_site_path $::env(T_PROJ_FILE)]
prov_stage_field never_taken     ""
prov_stage_field explicitly_none "(none)"
prov_stage_field zero_count      0

set m [prov_manifest $stage $stem]
prov_stage_fields $m [list inline_count 7]

set hard {}
if {[flow_env T_HARD] ne ""} { set hard [list $::env(T_HARD)] }
prov_gate $stage $stem \
    [list "WHAT THIS CHECK IS: a fixture, and nothing else."] \
    $hard \
    {} \
    [list "first entry, owner=somebody: it has an embedded newline right here\nAnd A Capital Line At Column Zero after it" \
          "second entry, owner=somebody else: this one has to survive the first"] \
    [list "everything this fixture does not look at, which is everything"]
puts $m
TCL

SMAN=""
SGATE=""
## prov_stage_run <toolkit> <stage> <stem> [hard failure reason]
## Leaves the manifest path in SMAN and the gate path in SGATE - the paths the
## artefacts SHOULD be at. It deliberately does NOT assert they exist: two of
## the mutation proofs below plant a fault that puts them somewhere else, and
## finding that out is the assertion's job, not the driver's.
prov_stage_run() {
    local tk="$1" stage="$2" stem="$3" hard="${4:-}" rc=0
    local rd="$P/run/reports"
    rm -f "$rd/${stem}_manifest.txt" "$rd/${stem}_gate.txt" \
          "$rd/${stage}_manifest.txt" "$rd/${stage}_gate.txt"
    PROV_OUT="$(env \
        FPGA_DIR="$P/proj" FPGA_PROJECT_ROOT="$P/proj" FPGA_FLOW_DIR="$P/tk" \
        FPGA_RUN_DIR="$P/run" FPGA_WORK_DIR="$P/run/work" FPGA_LOG_DIR="$P/run/logs" \
        FPGA_REPORT_DIR="$rd" FPGA_OUT_DIR="$P/run/outputs" \
        T_SITE_FILE="$SITE_A" T_PROJ_FILE="$P/proj/rtl/in.v" T_HARD="$hard" \
        timeout 60 tclsh "$SB/prov_stage.tcl" "$tk" "$stage" "$stem" 2>&1)" || rc=$?
    SMAN="$rd/${stem}_manifest.txt"
    SGATE="$rd/${stem}_gate.txt"
    if [ "$rc" -ne 0 ]; then
        printf 'the block-8/gate driver failed (exit %d):\n%s\n' "$rc" "$PROV_OUT"
        return 1
    fi
    return 0
}


#=============================================================================
# 1. THE SEVEN BLOCKS, IN CONTRACT.md SECTION 5 ORDER
#
# ASSERTED ON THE FIELDS, NOT ON THE `# n.` COMMENTS. A comment can be moved
# without moving anything a reader diffs; the field is the artefact.
#=============================================================================
t_head "the seven blocks appear in CONTRACT.md section 5 order"

## blocks_in_order <toolkit>
blocks_in_order() {
    local tk="$1" name ln prev=0 prevname="(start of file)"
    prov_run "$tk" order "$SITE_A" "in_src $P/proj/rtl/in.v" || return 1
    # block anchor -> the regex that finds its first field
    set -- \
        "1.header:^date[[:space:]]" \
        "2.provenance:^prov\." \
        "3.directories:^work_dir[[:space:]]" \
        "4.git_shas:^project_git_sha[[:space:]]" \
        "5.step_files:^step_files[[:space:]]" \
        "6.hooks_run:^hooks_run[[:space:]]" \
        "7.knobs:^knob\."
    for spec in "$@"; do
        name="${spec%%:*}"
        ln="$(first_line "${spec#*:}")"
        if [ -z "$ln" ]; then
            printf 'block %s is ABSENT from the manifest. A block that is missing and a block\n' "$name"
            printf 'that measured nothing must not look the same to a reader:\n' ; cat "$MAN"
            return 1
        fi
        if [ "$ln" -le "$prev" ]; then
            # THE EVIDENCE FIRST AND THE VERDICT LAST. t_check prints `tail -14`
            # of a failing predicate's output, so a diagnostic that leads with
            # its conclusion and then dumps a manifest has its conclusion cut
            # off - which is how the first draft of this reported a block-order
            # failure as fourteen unrelated knob lines. And the grep is anchored
            # per block: `^knob\.` alone matches sixty-odd rows.
            printf 'the block anchors, in the order the manifest actually emitted them:\n'
            { grep -nE '^(date|prov\.schema|work_dir|project_git_sha|step_files|hooks_run)[[:space:]]' "$MAN"
              grep -nE -m1 '^knob\.' "$MAN"; } | sort -t: -k1,1n | sed 's/^/  /'
            printf 'block %s (line %s) COMES BEFORE %s (line %s) - not CONTRACT.md section 5\n' \
                "$name" "$ln" "$prevname" "$prev"
            printf 'order. A manifest is read by diff, and two whose blocks moved diff as though\n'
            printf 'every field in them had changed.\n'
            return 1
        fi
        prev="$ln"; prevname="$name"
    done
    return 0
}

## header_fields_in_order <toolkit>
## Section 5 block 1, spelled out: date runtime_s stage run_tag host user tool
## tool_version log_file.
header_fields_in_order() {
    local tk="$1" f ln prev=0 prevf="(start of file)"
    prov_run "$tk" hdr "" "" || return 1
    for f in date runtime_s stage run_tag host user tool tool_version log_file; do
        ln="$(first_line "^${f}[[:space:]]")"
        if [ -z "$ln" ]; then
            printf 'header field %s is missing from block 1:\n' "$f"; cat "$MAN"; return 1
        fi
        if [ "$ln" -le "$prev" ]; then
            # Evidence first, verdict last - see blocks_in_order above.
            printf 'block 1 as the manifest emitted it:\n'
            grep -nE '^(date|runtime_s|stage|run_tag|host|user|tool|tool_version|log_file)[[:space:]]' \
                "$MAN" | sed 's/^/  /'
            printf 'header field %s (line %s) COMES BEFORE %s (line %s), so block 1 is not in\n' \
                "$f" "$ln" "$prevf" "$prev"
            printf 'CONTRACT.md section 5 order.\n'
            return 1
        fi
        prev="$ln"; prevf="$f"
    done
    return 0
}

t_check prov.blocks.order \
    "block 1 header, 2 provenance, 3 directories, 4 git shas, 5 step_files, 6 hooks_run, 7 knobs - in that order" \
    blocks_in_order "$FLOW_DIR"
t_check prov.header.order \
    "and inside block 1: date runtime_s stage run_tag host user tool tool_version log_file" \
    header_fields_in_order "$FLOW_DIR"

# -- mutation proof: SWAP BLOCK 5 AND BLOCK 6 --------------------------------
# Through a marker, because t_replace_line refuses a line that matches twice -
# and after a naive first edit the two lines would be identical.
M="$(t_mutant "$SB" blocks-5-6-swapped)"
SWAP_OK=0
if [ -n "$M" ] \
   && t_replace_line "$M" flow/common/provenance.tcl \
        '        mf $fh step_files "(none)"' '        mf $fh ZZ_SWAP_MARKER_ZZ "(none)"' \
   && t_replace_line "$M" flow/common/provenance.tcl \
        '        mf $fh hooks_run "(none)"' '        mf $fh step_files "(none)"' \
   && t_replace_line "$M" flow/common/provenance.tcl \
        '        mf $fh ZZ_SWAP_MARKER_ZZ "(none)"' '        mf $fh hooks_run "(none)"'; then
    SWAP_OK=1
fi
if [ "$SWAP_OK" = 1 ]; then
    t_check_fail prov.blocks.order.mutation \
        "with blocks 5 and 6 swapped - hooks_run emitted where step_files belongs - the assertion goes red" \
        blocks_in_order "$M"
else
    t_skip prov.blocks.order.mutation \
        "could not plant the fault: the step_files/hooks_run '(none)' lines in prov_manifest() have changed shape"
fi

M="$(t_mutant "$SB" header-fields-swapped)"
SWAP_OK=0
if [ -n "$M" ] \
   && t_replace_line "$M" flow/common/provenance.tcl \
        '    mf $fh stage   $stage' '    mf $fh ZZ_SWAP_MARKER_ZZ $stage' \
   && t_replace_line "$M" flow/common/provenance.tcl \
        '    mf $fh run_tag [prov_value [flow_env FPGA_RUN_TAG default]]' '    mf $fh stage   $stage' \
   && t_replace_line "$M" flow/common/provenance.tcl \
        '    mf $fh ZZ_SWAP_MARKER_ZZ $stage' '    mf $fh run_tag [prov_value [flow_env FPGA_RUN_TAG default]]'; then
    SWAP_OK=1
fi
if [ "$SWAP_OK" = 1 ]; then
    t_check_fail prov.header.order.mutation \
        "with 'stage' and 'run_tag' swapped inside block 1 the header assertion goes red" \
        header_fields_in_order "$M"
else
    t_skip prov.header.order.mutation \
        "could not plant the fault: the stage/run_tag lines in prov_manifest()'s header block have changed shape"
fi

#=============================================================================
# 2. THE SITE-PATH RULE, BOTH DIRECTIONS
#
# A path outside the project, the toolkit and the run tree appears ONLY as a
# `sha256:` digest and NEVER as text. A path inside one of them appears as a
# `<project>/`, `<toolkit>/` or `<run>/` label, because the reader needs it, the
# repository already publishes it, and two runs under different build roots then
# compare EQUAL instead of differing in every path field.
#=============================================================================
t_head "a site path is a sha256: digest and nothing else; an in-tree path is a label"

## site_path_never_raw <toolkit>
site_path_never_raw() {
    local tk="$1" dig_a dig_b
    prov_run "$tk" site_a "$SITE_A" "" || return 1
    if ! grep -qE '^prov\.flist\.path[[:space:]]+sha256:[0-9a-f]{64}$' "$MAN"; then
        printf 'the flist came from OUTSIDE the project, the toolkit and the run tree, and its\n'
        printf 'path field is not a sha256: digest:\n'
        grep -E '^prov\.flist\.' "$MAN"
        return 1
    fi
    if grep -qF -- "$P/site" "$MAN"; then
        printf 'A SITE PATH IS WRITTEN IN CLEAR IN THE MANIFEST. A manifest gets pasted into\n'
        printf 'bug reports and vendor tickets, and a mount point plus a revision-coded release\n'
        printf 'directory is inventory-shaped disclosure:\n'
        grep -nF -- "$P/site" "$MAN"
        return 1
    fi
    dig_a="$(grep -E '^prov\.flist\.path' "$MAN" | awk '{print $2}')"

    # ...AND THE DIGEST STILL DISCRIMINATES. If it did not, a vendor root
    # repointed at a different release between two runs would compare equal,
    # which is precisely the event this field exists to catch.
    prov_run "$tk" site_b "$SITE_B" "" || return 1
    dig_b="$(grep -E '^prov\.flist\.path' "$MAN" | awk '{print $2}')"
    [ -n "$dig_a" ] && [ -n "$dig_b" ] && [ "$dig_a" != "$dig_b" ] && return 0
    printf 'two DIFFERENT site paths produced the same field (%s vs %s), so the digest\n' "$dig_a" "$dig_b"
    printf 'discloses nothing AND distinguishes nothing.\n'
    return 1
}

## intree_path_is_labelled <toolkit>
intree_path_is_labelled() {
    local tk="$1"
    prov_run "$tk" intree "" "in_src $P/proj/rtl/in.v" || return 1
    if ! grep -qE '^prov\.in_src\.path[[:space:]]+<project>/rtl/in\.v$' "$MAN"; then
        printf 'a file INSIDE the project is not shown as a <project>/... label. Two checkouts\n'
        printf 'of the same design at different paths would then differ in every path field and\n'
        printf 'compare-runs would refuse every pair there is:\n'
        grep -E '^prov\.in_src\.' "$MAN"
        return 1
    fi
    if ! grep -qE '^work_dir[[:space:]]+<run>/work$' "$MAN"; then
        printf 'the run tree is not labelled <run>/..., so the labels are not per-root:\n'
        grep -E '^(work_dir|log_dir|report_dir|out_dir)' "$MAN"
        return 1
    fi
    return 0
}

t_check prov.site_path.digest \
    "an OUT-OF-TREE path appears only as sha256:<64 hex>, never as text, and still discriminates" \
    site_path_never_raw "$FLOW_DIR"
t_check prov.site_path.intree_label \
    "an IN-TREE path appears as <project>/... and the run tree as <run>/..." \
    intree_path_is_labelled "$FLOW_DIR"

M="$(t_mutant "$SB" site-path-in-clear)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/provenance.tcl \
        '    return "sha256:[prov_sha256_string $p]"' \
        '    return $p'; then
    t_check_fail prov.site_path.digest.mutation \
        "with prov_site_path returning the raw path, the vendor mount point lands in the manifest and the assertion goes red" \
        site_path_never_raw "$M"
else
    t_skip prov.site_path.digest.mutation \
        "could not plant the fault: prov_site_path()'s digest return has changed shape"
fi

M="$(t_mutant "$SB" no-intree-label)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/provenance.tcl \
        '        if {[string first "${r}/" "${p}/"] == 0} {' \
        '        if {0} {'; then
    t_check_fail prov.site_path.intree_label.mutation \
        "with the in-tree prefix test disabled every project path becomes an opaque digest, so the assertion goes red" \
        intree_path_is_labelled "$M"
else
    t_skip prov.site_path.intree_label.mutation \
        "could not plant the fault: the root-prefix test in prov_site_path() has changed shape"
fi

#=============================================================================
# 3. AN UNMEASURED VALUE IS THE LITERAL TOKEN `unmeasured`
#=============================================================================
t_head "a count nobody took is 'unmeasured' - not 0, and not absent"

## runtime_unmeasured <toolkit>
## The driver does not set FLOW_T0, so flow_boot's clock was never started.
runtime_unmeasured() {
    local tk="$1" v
    prov_run "$tk" unmeas "" "" || return 1
    v="$(grep -E '^runtime_s[[:space:]]' "$MAN" | head -1 | awk '{print $2}')"
    if [ -z "$v" ]; then
        printf 'runtime_s is missing or blank. Absent and unmeasured must not look the same:\n'
        sed -n '1,14p' "$MAN"; return 1
    fi
    [ "$v" = "unmeasured" ] && return 0
    printf "runtime_s is '%s', not the literal token 'unmeasured'. 0 is a legitimate\n" "$v"
    printf 'measurement, so a flow that writes it for "did not look" makes its best result\n'
    printf 'and its blindest one identical (CONTRACT.md rule 2).\n'
    return 1
}

## token_procs <toolkit> - prov_unmeasured and prov_unverified, at the source
token_procs() {
    local tk="$1" out="$P/run/reports/tokens.txt" rc=0
    rm -f "$out"
    timeout 60 tclsh "$SB/prov_tokens.tcl" "$tk" "$out" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] || [ ! -s "$out" ]; then
        printf 'prov_write produced nothing (exit %d)\n' "$rc"; return 1
    fi
    grep -qE '^prov\.cells\.unrouted[[:space:]]+unmeasured$' "$out" || {
        printf 'prov_unmeasured did not write the literal token:\n'; cat "$out"; return 1; }
    grep -qE '^prov\.reports\.timing[[:space:]]+UNVERIFIED:no-report-at-stage-end$' "$out" || {
        printf 'prov_unverified did not write UNVERIFIED:<reason>:\n'; cat "$out"; return 1; }
    return 0
}

t_check prov.unmeasured.runtime \
    "with no stage clock, runtime_s is the token 'unmeasured'" \
    runtime_unmeasured "$FLOW_DIR"
t_check prov.unmeasured.procs \
    "prov_unmeasured writes 'unmeasured' and prov_unverified writes 'UNVERIFIED:<reason>'" \
    token_procs "$FLOW_DIR"

M="$(t_mutant "$SB" unmeasured-is-zero)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/provenance.tcl \
        '        mf $fh runtime_s "unmeasured"' \
        '        mf $fh runtime_s 0'; then
    t_check_fail prov.unmeasured.runtime.mutation \
        "with an unmeasured runtime written as 0 - a legitimate value - the assertion goes red" \
        runtime_unmeasured "$M"
else
    t_skip prov.unmeasured.runtime.mutation \
        "could not plant the fault: the unmeasured-runtime line in prov_manifest() has changed shape"
fi

M="$(t_mutant "$SB" token-procs-broken)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/provenance.tcl \
        'proc prov_unmeasured {key} { prov_set $key "unmeasured" }' \
        'proc prov_unmeasured {key} { prov_set $key 0 }'; then
    t_check_fail prov.unmeasured.procs.mutation \
        "with prov_unmeasured writing 0 the assertion goes red - 'clean' and 'never looked' would be identical" \
        token_procs "$M"
else
    t_skip prov.unmeasured.procs.mutation \
        "could not plant the fault: prov_unmeasured() has changed shape"
fi

#=============================================================================
# 4. A FIELD THE COLLECTOR COULD NOT READ IS `UNVERIFIED:<reason>`, NOT BLANK
#=============================================================================
t_head "an unreadable field is UNVERIFIED:<reason>, and NO field is ever blank"

## unreadable_is_unverified <toolkit>
unreadable_is_unverified() {
    local tk="$1"
    prov_run "$tk" unver "$P/proj/rtl/there_is_no_such_flist.f" "" || return 1
    grep -qE '^prov\.flist\.sha256[[:space:]]+UNVERIFIED:missing-file$' "$MAN" || {
        printf 'the hash of a flist that is not there is not UNVERIFIED:missing-file. Two empty\n'
        printf 'strings compare EQUAL, which turns a missing measurement into agreement:\n'
        grep -E '^prov\.flist\.' "$MAN"; return 1; }
    grep -qE '^prov\.flist\.bytes[[:space:]]+UNVERIFIED:no-file$' "$MAN" || {
        printf 'the byte count of a flist that is not there is not UNVERIFIED:<reason>:\n'
        grep -E '^prov\.flist\.' "$MAN"; return 1; }
    return 0
}

## no_blank_fields <toolkit>
## Every non-comment line carries a key AND a value. An empty field reads as one
## the writer forgot; `(none)` is the token for "explicitly nothing". The driver
## registers a knob whose resolved value is the empty string precisely so this
## has something to measure.
no_blank_fields() {
    local tk="$1" bad
    prov_run "$tk" blank "" "" || return 1
    bad="$(awk 'NF==0 || /^#/ { next } NF < 2 { printf "  line %d: [%s]\n", NR, $0 }' "$MAN")"
    [ -z "$bad" ] && return 0
    printf 'these manifest fields are BLANK. A blank field is indistinguishable from one the\n'
    printf 'writer forgot, and "(none)" is the token for explicitly nothing:\n%s\n' "$bad"
    return 1
}

t_check prov.unverified.reason \
    "a flist that is not there gives UNVERIFIED:missing-file and UNVERIFIED:no-file, not blanks" \
    unreadable_is_unverified "$FLOW_DIR"
t_check prov.no_blank_fields \
    "every field in the manifest has a value, including a knob resolved to the empty string" \
    no_blank_fields "$FLOW_DIR"

# The documented hazard, planted: an unreadable hash defaulted to "". Two runs
# that each failed to read their flist then compare EQUAL.
M="$(t_mutant "$SB" hash-defaults-empty)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/provenance.tcl \
        '    if {![file exists $path]}                { return "UNVERIFIED:missing-file" }' \
        '    if {![file exists $path]}                { return "" }'; then
    t_check_fail prov.unverified.reason.mutation \
        "with a missing file's hash defaulting to the empty string the assertion goes red" \
        unreadable_is_unverified "$M"
else
    t_skip prov.unverified.reason.mutation \
        "could not plant the fault: prov_sha256()'s missing-file return has changed shape"
fi

M="$(t_mutant "$SB" unverified-loses-token)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/provenance.tcl \
        'proc prov_unverified {key why} { prov_set $key "UNVERIFIED:$why" }' \
        'proc prov_unverified {key why} { prov_set $key "$why" }'; then
    t_check_fail prov.unverified.reason.mutation.token \
        "with the UNVERIFIED: prefix dropped the reason reads as a value, so the assertion goes red" \
        unreadable_is_unverified "$M"
else
    t_skip prov.unverified.reason.mutation.token \
        "could not plant the fault: prov_unverified() has changed shape"
fi

M="$(t_mutant "$SB" blank-is-allowed)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/provenance.tcl \
        '    if {[string trim $v] eq ""} { return "(none)" }' \
        '    if {0} { return "(none)" }'; then
    t_check_fail prov.no_blank_fields.mutation \
        "with prov_value no longer rendering empty as (none) an empty knob leaves a blank field, so the assertion goes red" \
        no_blank_fields "$M"
else
    t_skip prov.no_blank_fields.mutation \
        "could not plant the fault: the empty-value test in prov_value() has changed shape"
fi

#=============================================================================
# 5. THE KNOBS ARE ENUMERATED FROM THE `opt` DECLARATIONS
#
# Not from a list anybody maintains. The predicate reads the SAME source of
# truth the manifest is supposed to read - `^opt` at the left margin of the step
# files - so a knob that exists and is not in the manifest is a failure whatever
# the reason.
#=============================================================================
t_head "every knob declared by an 'opt' reaches the manifest"

## knobs_enumerated <toolkit>
knobs_enumerated() {
    local tk="$1" n missing="" declared=0
    prov_run "$tk" knobs "" "" || return 1
    for n in $(grep -hE '^opt[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]' "$tk"/flow/steps/*.tcl 2>/dev/null \
               | awk '{print $2}' | sort -u); do
        declared=$((declared + 1))
        grep -qE "^knob\.${n}[[:space:]]" "$MAN" || missing="$missing $n"
    done
    if [ "$declared" -eq 0 ]; then
        printf 'no `opt` declaration was found in %s/flow/steps - this predicate would pass\n' "$tk"
        printf 'vacuously, which is the one result that must never be called green.\n'
        return 1
    fi
    [ -z "$missing" ] && return 0
    printf '%d knob(s) are DECLARED by an `opt` in flow/steps and ABSENT from the manifest:\n' \
        "$(printf '%s' "$missing" | wc -w)"
    printf '  %s\n' "$missing"
    printf 'The reference toolkit hand-maintained this list and it had already dropped three\n'
    printf 'effort knobs, every one of which changes QoR.\n'
    return 1
}

t_check prov.knobs.enumerated \
    "every 'opt' declared in flow/steps/*.tcl appears as a knob. line in the manifest" \
    knobs_enumerated "$FLOW_DIR"

# -- ADD AN `opt` AND IT MUST APPEAR ------------------------------------------
# The positive half of the proof: a knob that did not exist when this suite was
# written is enumerated anyway, because the manifest reads the files.
M="$(t_mutant "$SB" knob-planted)"
if [ -n "$M" ] && t_mutate "$M" flow/steps/ila.tcl \
        '$a\opt T_PROV_PLANTED_KNOB 7   ;# planted by t_provenance.sh - must be enumerated'; then
    t_check prov.knobs.enumerated.planted \
        "an 'opt' that did not exist when this suite was written is enumerated anyway" \
        knobs_enumerated "$M"
else
    t_skip prov.knobs.enumerated.planted \
        "could not plant the knob: flow/steps/ila.tcl is not in the mutant"
fi

# -- ...AND THE ASSERTION CAN GO RED ------------------------------------------
# The reference toolkit's defect, in its exact shape: a hand-maintained list
# where a directory scan belongs. Three entries against a directory that
# declares dozens.
#
# THE PLANTED LIST NAMES NO REAL STEP FILE, and that is not cosmetic.
# t_seams.sh scans every file in this repository for a copy of the step list and
# counts three of those names inside a three-line window as one. The first draft
# of the line below spelled its three sources as the real basenames from
# flow/steps/, which turned THIS SUITE into the very drift the anti-drift suite
# exists to catch - and t_seams went red naming this line, twice: once for the
# code and once for the comment that explained the first fix. The third field is
# only the basename that ends up in `UNVERIFIED:declared-in-<file>`, and
# knobs_enumerated never reads it, so a placeholder says the same thing without
# planting a second copy of a list the directory already knows.
M="$(t_mutant "$SB" knobs-hardcoded)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/provenance.tcl \
        '        foreach decl [flow_knob_scan $d] {' \
        '        foreach decl {{SYNTH_DIRECTIVE default hand-maintained-list.tcl} {IMPL_ROUTE_DIRECTIVE default hand-maintained-list.tcl} {REPORT_DRC 1 hand-maintained-list.tcl}} {'; then
    t_check_fail prov.knobs.enumerated.mutation \
        "with a THREE-ENTRY hand-maintained list in place of the scan - the reference toolkit's defect - the assertion goes red" \
        knobs_enumerated "$M"
else
    t_skip prov.knobs.enumerated.mutation \
        "could not plant the fault: the flow_knob_scan call in prov_knobs() has changed shape"
fi

#=============================================================================
# 6. BOTH GIT SHAS, AND BOTH DIRTY FLAGS
#
# A run is the product of TWO repositories - the design and the engine that
# built it - and a manifest carrying only the design's sha cannot tell "the RTL
# changed" from "the flow changed".
#=============================================================================
t_head "both git shas and both dirty flags are recorded"

## both_git_shas <toolkit>
both_git_shas() {
    local tk="$1"
    prov_run "$tk" git "" "" || return 1
    grep -qE '^project_git_sha[[:space:]]+[0-9a-f]{40}$' "$MAN" || {
        printf 'the PROJECT sha is not a 40-hex commit:\n'; grep -E '_git_' "$MAN"; return 1; }
    grep -qE '^toolkit_git_sha[[:space:]]+[0-9a-f]{40}$' "$MAN" || {
        printf 'the TOOLKIT sha is not a 40-hex commit. A manifest with only the design sha\n'
        printf 'cannot tell "the RTL changed" from "the flow changed", which is why the\n'
        printf 'reference project ships a GDS nobody can reproduce:\n'
        grep -E '_git_' "$MAN"; return 1; }
    grep -qE '^project_git_dirty[[:space:]]+DIRTY$' "$MAN" || {
        printf 'the project tree carries an UNTRACKED override file and the manifest calls it\n'
        printf 'clean. A build that consumed an uncommitted file is not reproducible and the\n'
        printf 'manifest is claiming that it is:\n'; grep -E '_git_' "$MAN"; return 1; }
    grep -qE '^toolkit_git_dirty[[:space:]]+clean$' "$MAN" || {
        printf 'the toolkit fixture has nothing uncommitted in it and is not reported clean -\n'
        printf 'so the flag is not measuring the tree:\n'; grep -E '_git_' "$MAN"; return 1; }
    grep -qE '^prov\.design\.git_sha[[:space:]]+[0-9a-f]{40}$' "$MAN" || {
        printf 'block 2 does not carry the design sha:\n'; grep -E '^prov\.design\.' "$MAN"; return 1; }
    return 0
}

if [ "$GIT_OK" = 1 ]; then
    t_check prov.git.both \
        "project and toolkit shas are both 40-hex, the dirty project reads DIRTY and the clean toolkit reads clean" \
        both_git_shas "$FLOW_DIR"

    M="$(t_mutant "$SB" no-git-sha)"
    if [ -n "$M" ] && t_replace_line "$M" flow/common/provenance.tcl \
            '    catch { set sha [string trim [exec git -C $dir rev-parse HEAD]] }' \
            '    catch { set sha "0000000" }'; then
        t_check_fail prov.git.both.mutation.sha \
            "with rev-parse neutered neither sha is a commit, so the assertion goes red" \
            both_git_shas "$M"
    else
        t_skip prov.git.both.mutation.sha \
            "could not plant the fault: the rev-parse line in prov_git() has changed shape"
    fi

    # THE DOCUMENTED FAULT: decide dirtiness from `git describe --dirty` instead
    # of from `git status --porcelain`. `--dirty` IGNORES UNTRACKED FILES, so a
    # build that consumed an untracked override file is reported clean - which
    # is a claim of reproducibility that is not there.
    M="$(t_mutant "$SB" dirty-from-describe)"
    if [ -n "$M" ] && t_replace_line "$M" flow/common/provenance.tcl \
            '        set drt [expr {[string trim $st] eq "" ? "clean" : "DIRTY"}]' \
            '        set drt [expr {[string match "*-dirty" $des] ? "DIRTY" : "clean"}]'; then
        t_check_fail prov.git.both.mutation.dirty \
            "with dirtiness taken from the describe suffix an untracked override reads clean, so the assertion goes red" \
            both_git_shas "$M"
    else
        t_skip prov.git.both.mutation.dirty \
            "could not plant the fault: the status-porcelain dirtiness line in prov_git() has changed shape"
    fi
else
    t_skip prov.git.both \
        "no usable git here - could not create the two fixture repositories under $P, so there is nothing to read a sha or a dirty flag from"
    t_skip prov.git.both.mutation.sha \
        "no usable git here - the good case above was skipped, so its mutation proof would be measuring nothing"
    t_skip prov.git.both.mutation.dirty \
        "no usable git here - the good case above was skipped, so its mutation proof would be measuring nothing"
fi

#=============================================================================
# 7. A KNOWN DEFECT: BLOCK 7 WRITES KNOB VALUES IN CLEAR
#
# The site-path rule in this file's own header is unconditional - "prov_site_
# path is the ONE place that decision is made; nothing else in the flow may
# write a path into a manifest" - and CONTRACT.md section 5 says any site path
# is a digest, never the raw path. Block 7 emits every knob's RESOLVED VALUE
# straight through prov_value, and several toolkit knobs hold paths by design:
# FLIST_INCDIRS ("extra include dirs"), FLIST_DEFINES, SYNTH_EXTRA_ARGS,
# IMPL_INCREMENTAL_DCP. Point one of them at a vendor mount and the mount point
# is in the manifest, in clear, below a block that carefully digested the same
# kind of path.
#
# Recorded, not fixed: this suite does not own provenance.tcl. If it starts
# passing, the marker goes RED and gets deleted.
#=============================================================================
t_head "known defect: a knob whose value is a site path"

## knob_site_path_digested <toolkit>
knob_site_path_digested() {
    local tk="$1"
    prov_run "$tk" knobpath "" "" "$P/site/vendor_ip/rel_1.2/include" || return 1
    grep -qF -- "$P/site" "$MAN" || return 0
    printf 'the vendor mount point appears in clear in block 7:\n'
    grep -nF -- "$P/site" "$MAN"
    printf 'Block 2 digested the same shape of path four lines earlier.\n'
    return 1
}

t_check prov.knobs.site_path \
    "a knob whose value is a site path is digested like every other path, not written in clear" \
    knob_site_path_digested "$FLOW_DIR"

# Mutation proof: send knob values straight to prov_value again - which is the
# state this suite found on 2026-09-08 - and the mount point reappears in clear.
M="$(t_mutant "$SB" knob-raw-path)"
if t_replace_line "$M" flow/common/provenance.tcl \
       '        mf $fh knob.$k [prov_knob_value $v]' \
       '        mf $fh knob.$k [prov_value $v]'; then
    t_check_fail prov.knobs.site_path.mutation \
        "with knob values written raw again, the site path is disclosed and the assertion goes red" \
        knob_site_path_digested "$M"
else
    t_skip prov.knobs.site_path.mutation \
        "could not plant the fault: the knob emission line in prov_knobs has changed shape"
fi

#=============================================================================
# 8. BLOCK 8: WHAT THE STAGE ITSELF MEASURED
#
# prov_manifest writes CONTRACT.md section 5's seven blocks and closes the
# file. ci/assert-stage.sh then grades the stage by reading the stage's OWN
# numbers out of that same manifest with `awk '$1 == key'` - file_count, vlnv,
# lut/ff/bram/dsp, wns/whs/unrouted_nets, bin_style/bit_bytes. Those are block
# 8, and the whole of what makes them different from block 2 is that they are
# RESULTS and not IDENTITY:
#
#   * they must be TOP-LEVEL keys. `prov.lut` is invisible to assert-stage's
#     awk, so a stage whose numbers went through prov_set would be graded
#     UNVERIFIED on every measurement it actually took;
#   * they must NOT be in the `prov.` namespace for a second and larger reason.
#     `compare-runs` treats that namespace as design identity and REFUSES a pair
#     that differs in it. Two runs of one design that differ in LUT count are
#     the normal case - that is what an A/B experiment IS - so a utilisation
#     figure recorded as identity makes the comparison tool refuse every pair
#     anybody would want to compare, and a tool that refuses everything gets
#     switched off within a day.
#
# Six stage scripts wrote their own emitter for this before provenance.tcl had
# one, in two mutually incompatible spellings. These assertions are about the
# one that replaced them.
#=============================================================================
t_head "block 8 is the stage's own measurements, as TOP-LEVEL keys"

## stage_fields_toplevel <toolkit>
## The key `inline_count` must be readable exactly the way ci/assert-stage.sh
## reads it: first whitespace-separated field on a line of its own.
stage_fields_toplevel() {
    local tk="$1" v
    prov_stage_run "$tk" meas meas || return 1
    v="$(awk '$1 == "inline_count" { print $2; exit }' "$SMAN")"
    [ "$v" = "7" ] && {
        # ...and NOT under the identity prefix as well, which would put a
        # RESULT where compare-runs reads design identity.
        grep -qE '^prov\.inline_count' "$SMAN" && {
            printf 'inline_count is ALSO emitted as prov.inline_count. That is the\n'
            printf 'namespace compare-runs treats as design identity, and a utilisation\n'
            printf 'figure there makes it refuse every A/B pair:\n'
            grep -nE '^prov\.inline_count' "$SMAN"; return 1; }
        return 0
    }
    printf "ci/assert-stage.sh reads a measurement with awk '\$1 == key'. Reading\n"
    printf "'inline_count' that way gave '%s', not 7 - so every gate that depends on\n" "$v"
    printf 'a stage measurement grades UNVERIFIED on a number the stage did take:\n'
    awk '/# 8\./{p=1} p' "$SMAN"
    return 1
}

t_check prov.stage_fields.toplevel \
    "a measurement is a top-level manifest key, readable by assert-stage's awk, and not in the prov. identity namespace" \
    stage_fields_toplevel "$FLOW_DIR"

# THE MUTATION IS THE MISTAKE THE DESIGN EXISTS TO PREVENT: send block 8 through
# the `prov.` prefix, exactly as prov_emit does for block 2.
M="$(t_mutant "$SB" block8-in-identity-namespace)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/provenance.tcl \
        '        mf $fh $k [prov_path_value $::prov_stage($k)]' \
        '        mf $fh prov.$k [prov_path_value $::prov_stage($k)]'; then
    t_check_fail prov.stage_fields.toplevel.mutation \
        "with block 8 emitted under the prov. prefix, assert-stage's awk finds nothing and the assertion goes red" \
        stage_fields_toplevel "$M"
else
    t_skip prov.stage_fields.toplevel.mutation \
        "could not plant the fault: the emission line in prov_stage_fields() has changed shape"
fi

#=============================================================================
# 9. A MEASUREMENT NOBODY TOOK IS `unmeasured` - NOT `(none)`, NOT BLANK
#
# `(none)` and `unmeasured` are NOT interchangeable and collapsing them is a
# silent failure with a green verdict on the end of it. ci/lib.sh's
# CI_UNMEASURED_RE matches `unmeasured` and does NOT match `(none)`, so
# ci_is_measured calls `(none)` A MEASUREMENT - correctly: somebody looked and
# the answer was nothing. A stage that wrote `(none)` for "did not look" is
# therefore GRADED GREEN by assert-stage on a number nobody took.
#
# One of the six deleted copies of this emitter did exactly that.
#=============================================================================
t_head "a blank measurement becomes 'unmeasured', which assert-stage refuses to grade"

## stage_fields_unmeasured <toolkit>
stage_fields_unmeasured() {
    local tk="$1" v
    prov_stage_run "$tk" meas meas || return 1
    v="$(awk '$1 == "never_taken" { print $2; exit }' "$SMAN")"
    if [ "$v" != "unmeasured" ]; then
        printf "a measurement recorded as the empty string came out as '%s'.\n" "$v"
        printf 'CI_UNMEASURED_RE in ci/lib.sh matches `unmeasured` and does NOT match\n'
        printf '`(none)`, so anything else here is GRADED AS A MEASUREMENT by\n'
        printf 'ci/assert-stage.sh - a green verdict on a number nobody took.\n'
        return 1
    fi
    # ...and the other direction: an EXPLICIT `(none)` is left alone. Somebody
    # looked and the answer was nothing, which is a different fact.
    v="$(awk '$1 == "explicitly_none" { print $2; exit }' "$SMAN")"
    if [ "$v" != "(none)" ]; then
        printf "an explicit '(none)' came out as '%s'. CONTRACT.md section 11 fixes\n" "$v"
        printf '`(none)` for "explicitly nothing"; only the caller can tell that from\n'
        printf '"did not look", so the emitter must not decide it for them.\n'
        return 1
    fi
    # ...and a real zero stays a real zero. CONTRACT.md rule 2 from the other side.
    v="$(awk '$1 == "zero_count" { print $2; exit }' "$SMAN")"
    if [ "$v" != "0" ]; then
        printf "a measured 0 came out as '%s'. 0 is a legitimate count - zero unrouted\n" "$v"
        printf 'nets, zero blackboxes - and rewriting it loses the best result the flow has.\n'
        return 1
    fi
    return 0
}

t_check prov.stage_fields.unmeasured \
    "a blank measurement is 'unmeasured', an explicit '(none)' survives, and a measured 0 stays 0" \
    stage_fields_unmeasured "$FLOW_DIR"

M="$(t_mutant "$SB" blank-measurement-is-none)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/provenance.tcl \
        '    if {[string trim $value] eq ""} { set value "unmeasured" }' \
        '    if {[string trim $value] eq ""} { set value "(none)" }'; then
    t_check_fail prov.stage_fields.unmeasured.mutation \
        "with a blank measurement written as (none) - which ci_is_measured GRADES - the assertion goes red" \
        stage_fields_unmeasured "$M"
else
    t_skip prov.stage_fields.unmeasured.mutation \
        "could not plant the fault: the blank-value line in prov_stage_field() has changed shape"
fi

#=============================================================================
# 10. A MEASUREMENT CAN BE A PATH, AND THE SITE-PATH RULE HAS NO EXEMPTION
#
# Measurements hold paths routinely - sources_tcl, source_census, component_xml,
# bd_wrapper, bd_regen_tcl, inbody_record. This file's header says
# prov_site_path is the ONE place a path-in-a-manifest decision is made and
# nothing else in the flow may write a path into a manifest; block 7 did not
# obey that until 2026-09-08 and block 8 is the same shape of hole.
#
# BOTH DIRECTIONS ARE PROVED, and the second one is the subtle half:
#
#   * a raw site path is DIGESTED. It never appears in clear.
#   * a value the stage ALREADY put through prov_site_path is left ALONE. Three
#     of the six stage scripts call prov_site_path at the point of measurement,
#     because the value is a path or an UNVERIFIED depending on a branch. Twelve
#     manifest fields across the three front-half stages take that route. If the
#     rule were applied a second time, `<run>/work/sources.tcl` - which resolves
#     nowhere - would fall through to the site branch and be emitted as a DIGEST
#     OF A LABEL: the reader loses the only field that says which file was read,
#     and two runs under different build roots start differing in every path
#     field again, which is the failure the labels exist to prevent.
#=============================================================================
t_head "a measurement that is a path goes through the site-path rule - exactly once"

## stage_site_path_digested <toolkit>
stage_site_path_digested() {
    local tk="$1"
    prov_stage_run "$tk" meas meas || return 1
    grep -qF -- "$P/site" "$SMAN" || return 0
    printf 'a MEASUREMENT disclosed the vendor mount point in clear:\n'
    grep -nF -- "$P/site" "$SMAN"
    printf 'Block 2 digested the same shape of path a hundred lines earlier. A manifest\n'
    printf 'gets pasted into bug reports and a mount point is inventory-shaped disclosure.\n'
    return 1
}

## stage_label_not_redigested <toolkit>
stage_label_not_redigested() {
    local tk="$1" v
    prov_stage_run "$tk" meas meas || return 1
    v="$(awk '$1 == "in_tree_src" { print $2; exit }' "$SMAN")"
    case "$v" in
        "<project>/rtl/in.v") return 0 ;;
    esac
    printf "a value the stage had ALREADY put through prov_site_path came out as '%s'.\n" "$v"
    printf 'It went in as <project>/rtl/in.v. A label re-fed to the site-path rule\n'
    printf 'resolves nowhere, falls through to the site branch and becomes a digest of a\n'
    printf 'label - so the reader loses the only field that says WHICH file was read,\n'
    printf 'and two runs under different build roots differ in every path field again.\n'
    return 1
}

t_check prov.stage_fields.site_path \
    "a measurement that is a raw site path is a sha256: digest, never the mount point" \
    stage_site_path_digested "$FLOW_DIR"
t_check prov.stage_fields.idempotent \
    "a measurement the stage already labelled is left alone, not digested a second time" \
    stage_label_not_redigested "$FLOW_DIR"

M="$(t_mutant "$SB" measurement-path-raw)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/provenance.tcl \
        '        mf $fh $k [prov_path_value $::prov_stage($k)]' \
        '        mf $fh $k [prov_value $::prov_stage($k)]'; then
    t_check_fail prov.stage_fields.site_path.mutation \
        "with measurements written raw the vendor mount point is disclosed, so the assertion goes red" \
        stage_site_path_digested "$M"
else
    t_skip prov.stage_fields.site_path.mutation \
        "could not plant the fault: the emission line in prov_stage_fields() has changed shape"
fi

M="$(t_mutant "$SB" no-idempotence-guard)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/provenance.tcl \
        '        if {[string index $tok 0] eq "<" || [string first "sha256:" $tok] == 0} {' \
        '        if {0} {'; then
    t_check_fail prov.stage_fields.idempotent.mutation \
        "without the already-through-the-rule guard, an in-tree LABEL is digested a second time and the assertion goes red" \
        stage_label_not_redigested "$M"
else
    t_skip prov.stage_fields.idempotent.mutation \
        "could not plant the fault: the idempotence guard in prov_path_value() has changed shape"
fi

#=============================================================================
# 11. THE VERDICT ARTEFACT: FOUR CLASSES, AND ONE STRING THAT IS PUNCTUATION
#
# CONTRACT.md section 5 fixes the gate file's structure and section 12.3 makes
# `HARD FAILURES: none` the exact string mk/flow.mk greps for. ci/assert-stage.sh
# greps for it ANCHORED, because an unanchored grep for `HARD FAILURES` also
# matches the section heading and would therefore pass on every gate file ever
# written - including one listing nine of them.
#
# Every section is written even when empty: assert-stage calls a MISSING heading
# UNVERIFIED, because a reader cannot tell "no budget was exceeded" from
# "budgets were never checked".
#
# THE ASSERTIONS BELOW READ THE GATE WITH assert-stage's OWN awk, not with a
# looser pattern of this suite's invention. A test that parses the artefact more
# forgivingly than the consumer does is a test that passes on files the consumer
# rejects.
#=============================================================================
t_head "the gate file has the four verdict classes, and 'HARD FAILURES: none' exactly"

## gate_clean_structure <toolkit> - a run with nothing wrong
gate_clean_structure() {
    local tk="$1" h
    prov_stage_run "$tk" gateok gateok "" || return 1
    grep -qE '^HARD FAILURES: none$' "$SGATE" || {
        printf 'the clean gate does not carry the exact anchored string mk/flow.mk and\n'
        printf 'ci/assert-stage.sh grep for. It is punctuation, not prose:\n'
        grep -n 'HARD FAILURES' "$SGATE"; return 1; }
    for h in '^BUDGETS EXCEEDED' '^DECLARED ELSEWHERE - MEASURED HERE, OWNED BY SOMEBODY ELSE' \
             '^NOT covered by ANY run of this flow, at any setting:'; do
        grep -qE -- "$h" "$SGATE" || {
            printf 'the gate has no section matching /%s/. An absent section is not an\n' "$h"
            printf 'empty one - assert-stage calls a missing heading UNVERIFIED, because a\n'
            printf 'reader cannot tell "none exceeded" from "never checked":\n'
            cat "$SGATE"; return 1; }
    done
    # ...and the NOT-covered bullets are readable by assert-stage's own awk.
    h="$(awk '/^NOT covered by ANY run/ { s=1; next } s && /^[A-Z]/ { exit } s && /^  - / { print }' "$SGATE" | grep -c .)"
    [ "$h" -ge 1 ] || {
        printf 'assert-stage.sh reads the NOT-covered bullets with its own awk and found\n'
        printf 'none. A green run that lists nothing it failed to measure is the shape of\n'
        printf 'a run nobody can audit:\n'; cat "$SGATE"; return 1; }
    return 0
}

## gate_hard_counted <toolkit> - a run WITH a hard failure
## The one that matters: a broken run must not carry the string that makes
## every gate in the flow pass.
gate_hard_counted() {
    local tk="$1"
    prov_stage_run "$tk" gatebad gatebad "the input this stage needed is not there" || return 1
    if grep -qE '^HARD FAILURES: none' "$SGATE"; then
        printf 'A RUN WITH A HARD FAILURE STILL SAYS "HARD FAILURES: none". That is the\n'
        printf 'exact string mk/flow.mk and ci/assert-stage.sh grep for, so this broken\n'
        printf 'run grades GREEN everywhere:\n'; cat "$SGATE"; return 1
    fi
    grep -qE '^HARD FAILURES: 1$' "$SGATE" || {
        printf 'the gate does not report the COUNT of hard failures:\n'
        grep -n 'HARD FAILURES' "$SGATE"; return 1; }
    grep -qE '^  - the input this stage needed is not there$' "$SGATE" || {
        printf 'the hard failure is not listed as a `  - ` bullet, which is what the awk\n'
        printf 'in ci/assert-stage.sh keys on:\n'; cat "$SGATE"; return 1; }
    return 0
}

## gate_bullet_one_line <toolkit>
## A bullet carrying an embedded newline ENDS ITS SECTION at the second line if
## that line starts with a capital - assert-stage's awk exits on /^[A-Z]/ - so
## every later bullet in the section is silently dropped. The fixture plants a
## delegated entry with exactly that shape and a second entry after it.
gate_bullet_one_line() {
    local tk="$1" n
    prov_stage_run "$tk" gateok gateok "" || return 1
    n="$(awk '/^DECLARED ELSEWHERE/ { s=1; next } s && /^[A-Z]/ { exit } s && /^  - / { print }' "$SGATE" | grep -c .)"
    [ "$n" = "2" ] && return 0
    printf 'ci/assert-stage.sh reads %s delegated bullet(s); the fixture wrote 2. A bullet\n' "$n"
    printf 'with an embedded newline whose next line starts with a capital TERMINATES the\n'
    printf 'section, silently dropping every entry after it - and a delegation nobody\n'
    printf 'reads is a finding owned by nobody:\n'
    sed -n '/^DECLARED ELSEWHERE/,/^NOT covered/p' "$SGATE"
    return 1
}

t_check prov.gate.structure \
    "a clean gate carries 'HARD FAILURES: none' exactly, and all four section headings" \
    gate_clean_structure "$FLOW_DIR"
t_check prov.gate.hard_counted \
    "a gate with a hard failure reports the count and the bullet, and never the passing string" \
    gate_hard_counted "$FLOW_DIR"
t_check prov.gate.bullet_one_line \
    "a bullet carrying an embedded newline is flattened, so it cannot truncate its own section" \
    gate_bullet_one_line "$FLOW_DIR"

M="$(t_mutant "$SB" gate-none-capitalised)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/provenance.tcl \
        '        puts $fh "HARD FAILURES: none"' \
        '        puts $fh "HARD FAILURES: None"'; then
    t_check_fail prov.gate.structure.mutation \
        "with one letter of the load-bearing string capitalised, every gate in the flow stops matching and the assertion goes red" \
        gate_clean_structure "$M"
else
    t_skip prov.gate.structure.mutation \
        "could not plant the fault: the clean-verdict line in prov_gate() has changed shape"
fi

M="$(t_mutant "$SB" gate-drops-budget-heading)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/provenance.tcl \
        '    puts $fh "BUDGETS EXCEEDED"' \
        '    if {[llength $budgets]} { puts $fh "BUDGETS EXCEEDED" }'; then
    t_check_fail prov.gate.structure.mutation.empty_section \
        "with the BUDGETS heading written only when non-empty, 'none exceeded' and 'never checked' become the same file, so the assertion goes red" \
        gate_clean_structure "$M"
else
    t_skip prov.gate.structure.mutation.empty_section \
        "could not plant the fault: the BUDGETS EXCEEDED heading in prov_gate() has changed shape"
fi

M="$(t_mutant "$SB" gate-always-none)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/provenance.tcl \
        '    if {[llength $hard]} {' \
        '    if {0} {'; then
    t_check_fail prov.gate.hard_counted.mutation \
        "with the hard-failure branch dead, a broken run writes the passing string and the assertion goes red" \
        gate_hard_counted "$M"
else
    t_skip prov.gate.hard_counted.mutation \
        "could not plant the fault: the hard-failure branch in prov_gate() has changed shape"
fi

M="$(t_mutant "$SB" gate-bullet-unflattened)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/provenance.tcl \
        '    foreach d $delegated { puts $fh "  - [regsub -all {\s+} $d { }]" }' \
        '    foreach d $delegated { puts $fh "  - $d" }'; then
    t_check_fail prov.gate.bullet_one_line.mutation \
        "without the flattener a bullet's embedded newline truncates its section, so the assertion goes red" \
        gate_bullet_one_line "$M"
else
    t_skip prov.gate.bullet_one_line.mutation \
        "could not plant the fault: the delegated-bullet line in prov_gate() has changed shape"
fi

#=============================================================================
# 12. THE STAGE NAME AND THE ARTEFACT STEM ARE TWO THINGS
#
# One string used to do both jobs, and package-ip could not satisfy it. Both
# ways were MEASURED against the real ci/assert-stage.sh on 2026-09-08:
#
#   one string = package_ip -> assert-stage FAILS: "the manifest says stage
#                              'package_ip', not 'package-ip' - it is not this
#                              stage's manifest, so nothing read out of it
#                              describes this stage"
#   one string = package-ip -> the file lands at package-ip_manifest.txt, where
#                              neither mk/flow.mk nor assert-stage looks
#
# The stage script worked around it by writing under one name and RENAMING the
# file, which put an artefact-naming decision in a stage script and left the
# next hyphenated stage to rediscover the whole thing. The two are now separate
# arguments, and this is the assertion that they stay separate.
#=============================================================================
t_head "prov_manifest names the FILE from the stem and the 'stage' FIELD from the stage"

## manifest_stage_and_stem <toolkit>
manifest_stage_and_stem() {
    local tk="$1" f v
    prov_stage_run "$tk" package-ip package_ip || return 1
    f="$P/run/reports/package_ip_manifest.txt"
    if [ ! -s "$f" ]; then
        printf 'no manifest at %s.\n' "$f"
        printf 'CONTRACT.md section 4 fixes that filename and mk/flow.mk asserts it; what\n'
        printf 'the stage actually wrote was:\n'
        ls -1 "$P/run/reports" | sed 's/^/  /'
        return 1
    fi
    # ci/assert-stage.sh reads this field and FAILS the run when it disagrees
    # with the stage it was invoked as.
    v="$(awk '$1 == "stage" { print $2; exit }' "$f")"
    if [ "$v" != "package-ip" ]; then
        printf "the manifest at %s says stage '%s'.\n" "$f" "$v"
        printf 'ci/assert-stage.sh is invoked as `package-ip` and cross-checks this field:\n'
        printf 'it FAILS the run with "it is not this manifest of this stage, so nothing\n'
        printf 'read out of it describes this stage".\n'
        return 1
    fi
    # ...and the gate followed the stem, with the STAGE in its title.
    [ -s "$P/run/reports/package_ip_gate.txt" ] || {
        printf 'the gate did not follow the artefact stem: no package_ip_gate.txt\n'
        ls -1 "$P/run/reports" | sed 's/^/  /'; return 1; }
    grep -qE '^PACKAGE-IP gate,' "$P/run/reports/package_ip_gate.txt" || {
        printf 'the gate TITLE does not name the stage:\n'
        head -1 "$P/run/reports/package_ip_gate.txt"; return 1; }
    return 0
}

t_check prov.manifest.stem \
    "stage 'package-ip' with stem 'package_ip' writes package_ip_manifest.txt whose stage field says package-ip" \
    manifest_stage_and_stem "$FLOW_DIR"

# The state this repository was in until 2026-09-08: one string for both. The
# file lands where nothing looks for it.
M="$(t_mutant "$SB" one-string-for-both-filename)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/provenance.tcl \
        '    set path [file join $REPORT_DIR ${stem}_manifest.txt]' \
        '    set path [file join $REPORT_DIR ${stage}_manifest.txt]'; then
    t_check_fail prov.manifest.stem.mutation.filename \
        "with the filename taken from the stage name, package-ip_manifest.txt lands where nothing looks and the assertion goes red" \
        manifest_stage_and_stem "$M"
else
    t_skip prov.manifest.stem.mutation.filename \
        "could not plant the fault: the manifest path line in prov_manifest() has changed shape"
fi

# ...and the other half of the same trap: the right filename, the wrong `stage`
# field. This is the one assert-stage catches and calls a foreign manifest.
M="$(t_mutant "$SB" one-string-for-both-field)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/provenance.tcl \
        '    mf $fh stage   $stage' \
        '    mf $fh stage   $stem'; then
    t_check_fail prov.manifest.stem.mutation.field \
        "with the stage FIELD taken from the artefact stem, assert-stage reads a foreign manifest and the assertion goes red" \
        manifest_stage_and_stem "$M"
else
    t_skip prov.manifest.stem.mutation.field \
        "could not plant the fault: the stage field line in prov_manifest() has changed shape"
fi


t_summary
