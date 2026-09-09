#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# t_measure.sh - THE TWO READERS BLOCK 8 IS MADE OF, AND THE GATE THEY FEED
#
# DEFECT CLASS: A PARSER THAT TURNS A GOOD NUMBER INTO `unmeasured`, AND AN
# ALLOWLIST THAT CANNOT BE APPLIED TO THE STAGE IT WAS WRITTEN FOR.
#
# Both defects were measured on Vivado 2024.1, xc7z020clg400-1, and both had the
# same shape: a check that looked strict and was in fact BLIND.
#
#   1. `util_row` tested the used column of a utilisation table with
#      `string is integer -strict`. A 7-series report counts block RAM in HALF
#      tiles - the real report from the fixture design in this suite says
#
#          | Block RAM Tile    | 32.5 |     0 |          0 |       140 | 23.21 |
#
#      so the row was skipped, `bram` was recorded as `unmeasured` in the synth
#      AND impl manifests, `ci/assert-stage.sh synth` went red on a correct run
#      (UNVERIFIED synth.manifest.bram), and EXPECT_BRAM_MAX could never fire
#      because budget_max will not compare a budget against a token. CONTRACT.md
#      rule 2 spends `unmeasured` on "we could not measure"; this spent it on a
#      number the tool had reported perfectly well, which is the direction the
#      rule exists to prevent.
#
#   2. The message gate granted an exemption only when the ids read from the log
#      ACCOUNTED FOR the tool's own critical-warning count, tested as equality.
#      Vivado resets that counter at every synth_design, opt_design,
#      place_design, route_design and open_checkpoint, so the two numbers
#      disagree on any stage that emitted a message before its last such
#      command. Measured, both directions, on the fixture design:
#
#        counter 0, log 2   the gate is guarded by `> 0`, so it was SKIPPED and
#                           the run went green with two ungraded critical
#                           warnings from a bad set_bus_skew;
#        counter 1, log 3   the counts disagree, so no exemption is granted, and
#                           `Project 1-1924` - which write_hw_platform raises on
#                           EVERY design with no block design - left such a
#                           project permanently red with no route to green.
#
# WHAT THIS SUITE ASSERTS, and why each matters:
#
#   * a fractional count is READ, an integer count still is, and a cell that is
#     not a count at all is still REFUSED - the fix must not launder `n/a` or
#     `1e5` into a number a budget will then compare;
#   * a row that is not in the table is "" and NEVER 0, because a zero in a
#     utilisation column is indistinguishable from an empty design;
#   * the census counts the STAGE LOG, anchored at column 0, so it does not
#     count a Vivado log's echo of the parser's own source line;
#   * an exemption requires a COMPLETE id list, and `complete` still fails when
#     the log is short, absent or unreadable. Relaxing the completeness test is
#     how somebody else's undiagnosed exemptions get inherited, which CONTRACT.md
#     section 7 forbids - so the test asserts BOTH that a complete list can be
#     exempted and that an incomplete one cannot, even when every id on it is
#     allowlisted;
#   * neither stage script keeps a private copy of either reader. Both copies of
#     `util_row` carried the same defect; that is what duplication costs here.
#
# Every assertion is PAIRED WITH A MUTATION PROOF planted with t_mutate /
# t_replace_line, and every plant's RETURN VALUE IS HONOURED: a mutation that did
# not apply lands on t_skip with the reason, never on a t_check_fail against an
# unmutated - or empty - tree. A proof in this repository's history passed
# $FLOW_DIR to t_mutant as though it were the sandbox, t_mutant refused, the
# command ran against an empty path, failed for that reason, and t_check_fail
# reported `ok` on a check that had measured nothing.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/lib/harness.sh
. "$HERE/../lib/harness.sh"

t_sandbox; SB="$T_SANDBOX"

PV_REL="flow/common/provenance.tcl"
SY_REL="flow/vivado/4_synth.tcl"
IM_REL="flow/vivado/5_impl.tcl"

#-----------------------------------------------------------------------------
# PRECONDITIONS. Each is a SKIP WITH THE REASON, never a pass.
#-----------------------------------------------------------------------------
for f in "$PV_REL" "$SY_REL" "$IM_REL"; do
    if [ ! -f "$FLOW_DIR/$f" ]; then
        t_skip meas.all "no $f in this checkout - an absent file is not a passing one"
        t_summary; exit $?
    fi
done
if ! command -v tclsh >/dev/null 2>&1; then
    t_skip meas.all "no tclsh on PATH - provenance.tcl is designed to load in a bare tclsh and that is the only tool-free way to drive it"
    t_summary; exit $?
fi

#=============================================================================
# THE DRIVER - a stand-in for a stage
#
# It sources the two files a stage sources and asks ONE question. Nothing about
# the code under test is stubbed EXCEPT `get_msg_config`, which is Vivado's and
# does not exist under tclsh: the census has to be drivable with the tool's
# counter set to a value this suite chose, because the whole defect is about
# what that counter means. T_TOOL_COUNT unset means "no tool", which is the
# other case the census has to handle.
#=============================================================================
cat > "$SB/meas_drive.tcl" <<'TCL'
set tk   [lindex $::argv 0]
set mode [lindex $::argv 1]
source [file join $tk flow common flow_utils.tcl]
flow_config prefix MEAS
source [file join $tk flow common provenance.tcl]

if {[info exists ::env(T_TOOL_COUNT)] && $::env(T_TOOL_COUNT) ne ""} {
    proc get_msg_config {args} { return $::env(T_TOOL_COUNT) }
}

switch -exact -- $mode {
    util {
        puts "value=[prov_util_row [lindex $::argv 2] [lindex $::argv 3]]"
    }
    number {
        puts "value=[prov_util_number [lindex $::argv 2]]"
    }
    msg {
        set d [prov_msg_criticals [lindex $::argv 2]]
        foreach k {total log tool complete} { puts "$k=[dict get $d $k]" }
        puts "ids=[dict get $d ids]"
        puts "basis=[dict get $d basis]"
    }
    verdict {
        set d [prov_msg_verdict [lindex $::argv 2] [lindex $::argv 3] \
                                [lindex $::argv 4] [lindex $::argv 5]]
        puts "verdict=[dict get $d verdict]"
        puts "unexempt=[dict get $d unexempt]"
    }
    default { puts "mode=UNKNOWN" ; exit 2 }
}
TCL

## drive <toolkit root> <mode> <args...> - prints the driver's output
drive() { timeout 60 tclsh "$SB/meas_drive.tcl" "$@" 2>&1; }

## field <output> <key> - the value of one `key=value` line
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

#=============================================================================
# THE FIXTURE REPORTS
#
# The fractional table is COPIED FROM A REAL RUN - Vivado 2024.1, xc7z020, 65
# RAMB18E1 - down to the column widths, because the parser splits on `|` and
# trims, and a hand-tidied table would not prove it against the real one.
#=============================================================================
cat > "$SB/util_frac.rpt" <<'RPT'
2. Memory
---------

+-------------------+------+-------+------------+-----------+-------+
|     Site Type     | Used | Fixed | Prohibited | Available | Util% |
+-------------------+------+-------+------------+-----------+-------+
| Block RAM Tile    | 32.5 |     0 |          0 |       140 | 23.21 |
|   RAMB36/FIFO*    |    0 |     0 |          0 |       140 |  0.00 |
|   RAMB18          |   65 |     0 |          0 |       280 | 23.21 |
+-------------------+------+-------+------------+-----------+-------+
RPT

cat > "$SB/util_int.rpt" <<'RPT'
+-------------------------+------+-------+------------+-----------+-------+
|        Site Type        | Used | Fixed | Prohibited | Available | Util% |
+-------------------------+------+-------+------------+-----------+-------+
| Slice LUTs*             |  234 |     0 |          0 |     53200 |  0.44 |
| Block RAM Tile          |    8 |     0 |          0 |       140 |  5.71 |
+-------------------------+------+-------+------------+-----------+-------+
RPT

# THE CELLS THAT ARE NOT COUNTS. `1e5` is the one that matters: it is what
# `string is double -strict` accepts and a utilisation column never holds, and it
# would sail into budget_max and be compared.
cat > "$SB/util_junk.rpt" <<'RPT'
+-------------------+------+-------+
|     Site Type     | Used | Fixed |
+-------------------+------+-------+
| Block RAM Tile    |  n/a |     0 |
| DSPs              |  1e5 |     0 |
| URAM              |    - |     0 |
+-------------------+------+-------+
RPT

# UltraScale spells the same row differently. A parser that knew one spelling
# would report `unmeasured` on every other device and call that a measurement.
cat > "$SB/util_us.rpt" <<'RPT'
+-------------------------+------+-------+-----------+-------+
|        Site Type        | Used | Fixed | Available | Util% |
+-------------------------+------+-------+-----------+-------+
| CLB LUTs*               | 1234 |     0 |    230400 |  0.53 |
+-------------------------+------+-------+-----------+-------+
RPT

: > "$SB/util_empty.rpt"

#=============================================================================
# THE FIXTURE STAGE LOG
#
# Three real messages, two distinct ids, one of them twice - plus the two shapes
# that must NOT be counted: a Vivado log echoes every line of the Tcl it sources
# with a `# ` prefix, so the census proc's own source line appears in the log of
# every stage that runs it, and a message quoted inside a report is indented.
#=============================================================================
cat > "$SB/stage_ok.log" <<'LOG'
INFO: [Common 17-349] Got license for feature 'Implementation'
CRITICAL WARNING: [Constraints 18-611] set_bus_skew: list of objects specified for option 'from' contains '4' objects of types '(port)'
CRITICAL WARNING: [Constraints 18-612] set_bus_skew: the constraint will not be applied
CRITICAL WARNING: [Constraints 18-611] set_bus_skew: and again, from the second file
#             if {[regexp {^CRITICAL WARNING: \[([^\]]+)\]} $line -> id]} {
  CRITICAL WARNING: [Quoted 1-1] quoted inside a report, indented
LOG

MISSING_LOG="$SB/no-such-stage.log"

#=============================================================================
# 1. A FRACTIONAL UTILISATION FIGURE IS A NUMBER
#=============================================================================
t_head "the utilisation reader"

## util_is <root> <report> <names> <expected> - the row reads back as expected
util_is() {
    local root="$1" rpt="$2" names="$3" want="$4" out got
    out="$(drive "$root" util "$rpt" "$names")" || { echo "$out"; return 1; }
    got="$(field "$out" value)"
    [ "$got" = "$want" ] && return 0
    echo "prov_util_row returned '$got', expected '$want'"
    echo "$out"
    return 1
}

t_check meas.util.fraction \
    "'Block RAM Tile | 32.5' reads back as 32.5, not as unmeasured" \
    util_is "$FLOW_DIR" "$SB/util_frac.rpt" "{Block RAM Tile}" "32.5"

M="$(t_mutant "$SB" util-integer-only)"
if t_replace_line "$M" "$PV_REL" \
    '    return [regexp {^[0-9]+(?:\.[0-9]+)?$} $s]' \
    '    return [string is integer -strict $s]'; then
    t_check_fail meas.util.fraction.mutation \
        "with the integer-only test restored, 32.5 is rejected and the check goes red" \
        util_is "$M" "$SB/util_frac.rpt" "{Block RAM Tile}" "32.5"
else
    t_skip meas.util.fraction.mutation "could not plant the fault: the number test in $PV_REL has changed shape"
fi

t_check meas.util.integer \
    "a whole-tile count still reads back unchanged" \
    util_is "$FLOW_DIR" "$SB/util_int.rpt" "{Block RAM Tile}" "8"

M="$(t_mutant "$SB" util-blind)"
if t_replace_line "$M" "$PV_REL" \
    '    return [regexp {^[0-9]+(?:\.[0-9]+)?$} $s]' \
    '    return 0'; then
    t_check_fail meas.util.integer.mutation \
        "with the number test always false, every row is skipped and the check goes red" \
        util_is "$M" "$SB/util_int.rpt" "{Block RAM Tile}" "8"
else
    t_skip meas.util.integer.mutation "could not plant the fault: the number test in $PV_REL has changed shape"
fi

t_check meas.util.arch_names \
    "the UltraScale spelling is found through the alternate-name list" \
    util_is "$FLOW_DIR" "$SB/util_us.rpt" "{Slice LUTs*} {CLB LUTs*}" "1234"

M="$(t_mutant "$SB" util-first-name-only)"
if t_mutate "$M" "$PV_REL" 's/^\([[:space:]]*\)foreach want \$names {/\1foreach want [lrange $names 0 0] {/'; then
    t_check_fail meas.util.arch_names.mutation \
        "with only the first spelling tried, the UltraScale row is missed and the check goes red" \
        util_is "$M" "$SB/util_us.rpt" "{Slice LUTs*} {CLB LUTs*}" "1234"
else
    t_skip meas.util.arch_names.mutation "could not plant the fault: the name loop in $PV_REL has changed shape"
fi

# THE OTHER DIRECTION OF THE SAME FIX. Accepting 32.5 must not mean accepting
# anything that looks vaguely numeric: `1e5` passes `string is double`, and a
# budget compared against it would be comparing against 100000.
t_check meas.util.not_a_count \
    "a used cell that is not a count is refused, and the row reads back empty" \
    util_is "$FLOW_DIR" "$SB/util_junk.rpt" "{DSPs}" ""

M="$(t_mutant "$SB" util-loose-number)"
if t_replace_line "$M" "$PV_REL" \
    '    return [regexp {^[0-9]+(?:\.[0-9]+)?$} $s]' \
    '    return [string is double -strict $s]'; then
    t_check_fail meas.util.not_a_count.mutation \
        "with 'string is double' in place, 1e5 is accepted as a count and the check goes red" \
        util_is "$M" "$SB/util_junk.rpt" "{DSPs}" ""
else
    t_skip meas.util.not_a_count.mutation "could not plant the fault: the number test in $PV_REL has changed shape"
fi

# A ROW THAT IS NOT THERE IS "" AND NEVER 0. prov_stage_field spells "" as the
# token `unmeasured`; a 0 here would be indistinguishable from an empty design.
t_check meas.util.absent_row \
    "a row the table does not have reads back empty, not 0" \
    util_is "$FLOW_DIR" "$SB/util_int.rpt" "{URAM} {URAM288}" ""

M="$(t_mutant "$SB" util-zero-for-absent)"
if t_mutate "$M" "$PV_REL" '/^proc prov_util_row /,/^}/ s/^    return ""$/    return 0/'; then
    t_check_fail meas.util.absent_row.mutation \
        "with 0 returned for a row that is not there, the check goes red" \
        util_is "$M" "$SB/util_int.rpt" "{URAM} {URAM288}" ""
else
    t_skip meas.util.absent_row.mutation "could not plant the fault: the failure return in prov_util_row has changed shape"
fi

t_check meas.util.empty_report \
    "a zero-byte report is empty, not an error and not 0" \
    util_is "$FLOW_DIR" "$SB/util_empty.rpt" "{Block RAM Tile}" ""

M="$(t_mutant "$SB" util-no-file-guard)"
if t_replace_line "$M" "$PV_REL" \
    '    if {![file exists $file] || ![file size $file]} { return "" }' \
    '    if {0} { return "" }'; then
    t_check_fail meas.util.empty_report.mutation \
        "with the file guard removed the reader no longer answers for an unusable report, and the check goes red" \
        util_is "$M" "$SB/util_missing.rpt" "{Block RAM Tile}" ""
else
    t_skip meas.util.empty_report.mutation "could not plant the fault: the file guard in $PV_REL has changed shape"
fi

#=============================================================================
# 2. THE CRITICAL-WARNING CENSUS
#=============================================================================
t_head "the critical-warning census"

## msg_is <root> <log> <tool count or -> <key> <expected>
msg_is() {
    local root="$1" log="$2" tool="$3" key="$4" want="$5" out got
    if [ "$tool" = "-" ]; then
        out="$(drive "$root" msg "$log")" || { echo "$out"; return 1; }
    else
        out="$(T_TOOL_COUNT="$tool" drive "$root" msg "$log")" || { echo "$out"; return 1; }
    fi
    got="$(field "$out" "$key")"
    [ "$got" = "$want" ] && return 0
    echo "census $key returned '$got', expected '$want' (tool counter '$tool')"
    echo "$out"
    return 1
}

t_check meas.msg.ids \
    "the ids are unique and in first-seen order" \
    msg_is "$FLOW_DIR" "$SB/stage_ok.log" - ids "{Constraints 18-611} {Constraints 18-612}"

M="$(t_mutant "$SB" msg-ids-duplicated)"
if t_replace_line "$M" "$PV_REL" \
    '                if {[lsearch -exact $ids $id] < 0} { lappend ids $id }' \
    '                lappend ids $id'; then
    t_check_fail meas.msg.ids.mutation \
        "with the uniqueness test removed the id list repeats, and the check goes red" \
        msg_is "$M" "$SB/stage_ok.log" - ids "{Constraints 18-611} {Constraints 18-612}"
else
    t_skip meas.msg.ids.mutation "could not plant the fault: the id collector in $PV_REL has changed shape"
fi

# THE ANCHOR IS WHAT MAKES A GREP SAFE HERE. A Vivado log echoes the Tcl it
# sources with a `# ` prefix, so this proc's own source line is in the log of
# every stage that runs it; the fixture log carries that line and an indented
# quotation, and neither is a message this stage emitted.
t_check meas.msg.anchored \
    "3 messages counted: the echoed source line and the indented quotation are not messages" \
    msg_is "$FLOW_DIR" "$SB/stage_ok.log" - log "3"

M="$(t_mutant "$SB" msg-unanchored)"
if t_mutate "$M" "$PV_REL" 's/regexp {\^CRITICAL WARNING: /regexp {CRITICAL WARNING: /'; then
    t_check_fail meas.msg.anchored.mutation \
        "with the column-0 anchor removed the log's echo of this proc is counted, and the check goes red" \
        msg_is "$M" "$SB/stage_ok.log" - log "3"
else
    t_skip meas.msg.anchored.mutation "could not plant the fault: the message regexp in $PV_REL has changed shape"
fi

#-----------------------------------------------------------------------------
# COMPLETENESS. This is the half the old gate got wrong, and both directions are
# proved: a counter BELOW the log is the normal case and must stay complete; a
# counter ABOVE it means the log is not this stage's record and must not.
#-----------------------------------------------------------------------------
t_check meas.msg.complete.counter_reset \
    "a tool counter LOWER than the log (Vivado reset it at route_design) is still a complete reading" \
    msg_is "$FLOW_DIR" "$SB/stage_ok.log" 1 complete "1"

t_check meas.msg.total.counter_reset \
    "...and the number graded is the log's 3, not the counter's 1" \
    msg_is "$FLOW_DIR" "$SB/stage_ok.log" 1 total "3"

M="$(t_mutant "$SB" msg-equality-rule)"
if t_replace_line "$M" "$PV_REL" \
    '    } elseif {$tool ne "" && $tool > $n} {' \
    '    } elseif {$tool ne "" && $tool != $n} {'; then
    t_check_fail meas.msg.complete.counter_reset.mutation \
        "with the old counts-must-be-equal rule restored, a reset counter makes the reading incomplete and the check goes red" \
        msg_is "$M" "$SB/stage_ok.log" 1 complete "1"
else
    t_skip meas.msg.complete.counter_reset.mutation "could not plant the fault: the completeness test in $PV_REL has changed shape"
fi

t_check meas.msg.incomplete.short_log \
    "a tool counter ABOVE the log means the log is not this stage's whole record: incomplete" \
    msg_is "$FLOW_DIR" "$SB/stage_ok.log" 5 complete "0"

t_check meas.msg.total.short_log \
    "...and the number graded is then the higher one, 5, never the log's 3" \
    msg_is "$FLOW_DIR" "$SB/stage_ok.log" 5 total "5"

M="$(t_mutant "$SB" msg-always-complete)"
if t_replace_line "$M" "$PV_REL" \
    '    } elseif {$tool ne "" && $tool > $n} {' \
    '    } elseif {0} {'; then
    t_check_fail meas.msg.incomplete.short_log.mutation \
        "with the short-log branch removed, a log missing messages is called complete and the check goes red" \
        msg_is "$M" "$SB/stage_ok.log" 5 complete "0"
else
    t_skip meas.msg.incomplete.short_log.mutation "could not plant the fault: the completeness test in $PV_REL has changed shape"
fi

#-----------------------------------------------------------------------------
# NO LOG AT ALL. The counter is a FLOOR, not a total: it says what happened since
# the last design command and nothing about what came before. So the number is
# recorded, the reading is incomplete, and the basis says UNVERIFIED.
#-----------------------------------------------------------------------------
t_check meas.msg.no_log.incomplete \
    "an unreadable stage log is never a complete reading, whatever the counter says" \
    msg_is "$FLOW_DIR" "$MISSING_LOG" 2 complete "0"

t_check meas.msg.no_log.total \
    "...and the counter's 2 is still recorded, because 2 messages did happen" \
    msg_is "$FLOW_DIR" "$MISSING_LOG" 2 total "2"

M="$(t_mutant "$SB" msg-no-log-complete)"
if t_mutate "$M" "$PV_REL" '/^    if {\$n eq ""} {/,/^    } elseif/ s/^        set complete 0$/        set complete 1/'; then
    t_check_fail meas.msg.no_log.incomplete.mutation \
        "with the no-log case called complete, an exemption could be granted from a log nobody read, and the check goes red" \
        msg_is "$M" "$MISSING_LOG" 2 complete "0"
else
    t_skip meas.msg.no_log.incomplete.mutation "could not plant the fault: the no-log branch in $PV_REL has changed shape"
fi

## basis_names_no_path <root> - the basis line does not carry the log path
##
## It is a MANIFEST FIELD, and CONTRACT.md section 5's site-path rule has no
## exemption for a diagnostic. prov_path_value does not rewrite a value that
## begins `UNVERIFIED:` - which this one does - so the path must not be in it.
basis_names_no_path() {
    local root="$1" out basis
    out="$(T_TOOL_COUNT=2 drive "$root" msg "$MISSING_LOG")" || { echo "$out"; return 1; }
    basis="$(field "$out" basis)"
    case "$basis" in
        UNVERIFIED:*) ;;
        *) echo "the basis for an unreadable log does not begin UNVERIFIED: '$basis'"; return 1 ;;
    esac
    if printf '%s' "$basis" | grep -qF -- "$MISSING_LOG"; then
        echo "the basis carries the raw log path, which a manifest may not: $basis"
        return 1
    fi
    return 0
}

t_check meas.msg.basis.no_path \
    "the unreadable-log basis says UNVERIFIED and does not name the path" \
    basis_names_no_path "$FLOW_DIR"

M="$(t_mutant "$SB" msg-basis-leaks-path)"
if t_replace_line "$M" "$PV_REL" \
    '        set why "no file at the recorded log path"' \
    '        set why "no file at $log"'; then
    t_check_fail meas.msg.basis.no_path.mutation \
        "with the path put back in the reason, the check goes red" \
        basis_names_no_path "$M"
else
    t_skip meas.msg.basis.no_path.mutation "could not plant the fault: the no-file reason in $PV_REL has changed shape"
fi

#=============================================================================
# 3. THE VERDICT: MAY THIS RUN CARRY THESE CRITICAL WARNINGS?
#=============================================================================
t_head "the message-gate verdict"

ALLOWED_BOTH="{Constraints 18-611} {Constraints 18-612}"
ALLOWED_ONE="{Constraints 18-611}"
IDS_BOTH="{Constraints 18-611} {Constraints 18-612}"

## verdict_is <root> <allow> <ids> <allowlist> <complete> <key> <expected>
verdict_is() {
    local root="$1" allow="$2" ids="$3" list="$4" complete="$5" key="$6" want="$7" out got
    out="$(drive "$root" verdict "$allow" "$ids" "$list" "$complete")" || { echo "$out"; return 1; }
    got="$(field "$out" "$key")"
    [ "$got" = "$want" ] && return 0
    echo "verdict $key returned '$got', expected '$want'"
    echo "$out"
    return 1
}

t_check meas.verdict.exempt \
    "a COMPLETE reading whose every id is allowlisted is exempt - the case the old rule could not reach at impl" \
    verdict_is "$FLOW_DIR" 0 "$IDS_BOTH" "$ALLOWED_BOTH" 1 verdict exempt

M="$(t_mutant "$SB" verdict-never-exempt)"
if t_replace_line "$M" "$PV_REL" \
    '    } elseif {$complete && ![llength $unexempt] && [llength $ids]} {' \
    '    } elseif {0} {'; then
    t_check_fail meas.verdict.exempt.mutation \
        "with the exemption branch dead, a fully allowlisted run cannot go green and the check goes red" \
        verdict_is "$M" 0 "$IDS_BOTH" "$ALLOWED_BOTH" 1 verdict exempt
else
    t_skip meas.verdict.exempt.mutation "could not plant the fault: the exemption branch in $PV_REL has changed shape"
fi

t_check meas.verdict.unlisted \
    "an id that is NOT allowlisted is refused, on the same complete reading" \
    verdict_is "$FLOW_DIR" 0 "$IDS_BOTH" "$ALLOWED_ONE" 1 verdict unlisted

t_check meas.verdict.unlisted.names \
    "...and the refusal names exactly the id that is missing from the list" \
    verdict_is "$FLOW_DIR" 0 "$IDS_BOTH" "$ALLOWED_ONE" 1 unexempt "{Constraints 18-612}"

M="$(t_mutant "$SB" verdict-allowlist-blind)"
if t_replace_line "$M" "$PV_REL" \
    '        if {[lsearch -exact $allowlist $id] < 0} { lappend unexempt $id }' \
    '        if {0} { lappend unexempt $id }'; then
    t_check_fail meas.verdict.unlisted.mutation \
        "with the allowlist search never failing, an undeclared id is exempted and the check goes red" \
        verdict_is "$M" 0 "$IDS_BOTH" "$ALLOWED_ONE" 1 verdict unlisted
else
    t_skip meas.verdict.unlisted.mutation "could not plant the fault: the allowlist search in $PV_REL has changed shape"
fi

# THE ANTI-INHERITANCE PROPERTY, CONTRACT.md section 7. Every id here IS
# allowlisted; the reading is not complete; the answer is still no. An allowlist
# that stops verifying its own completeness is how somebody else's undiagnosed
# exemptions get inherited.
t_check meas.verdict.incomplete \
    "an INCOMPLETE reading is refused even when every id on it is allowlisted" \
    verdict_is "$FLOW_DIR" 0 "$IDS_BOTH" "$ALLOWED_BOTH" 0 verdict incomplete

M="$(t_mutant "$SB" verdict-drops-completeness)"
if t_replace_line "$M" "$PV_REL" \
    '    } elseif {$complete && ![llength $unexempt] && [llength $ids]} {' \
    '    } elseif {![llength $unexempt] && [llength $ids]} {'; then
    t_check_fail meas.verdict.incomplete.mutation \
        "with the completeness test dropped from the exemption, a partial reading is exempted and the check goes red" \
        verdict_is "$M" 0 "$IDS_BOTH" "$ALLOWED_BOTH" 0 verdict incomplete
else
    t_skip meas.verdict.incomplete.mutation "could not plant the fault: the exemption branch in $PV_REL has changed shape"
fi

# AN EMPTY ID LIST IS NOT AN ALLOWLISTED ONE. "Nothing to object to" and "every
# id is allowed" are different facts, and only one of them is an exemption.
t_check meas.verdict.no_ids \
    "a complete reading that produced NO ids is not exempt" \
    verdict_is "$FLOW_DIR" 0 "" "$ALLOWED_BOTH" 1 verdict unlisted

M="$(t_mutant "$SB" verdict-empty-ids-exempt)"
if t_replace_line "$M" "$PV_REL" \
    '    } elseif {$complete && ![llength $unexempt] && [llength $ids]} {' \
    '    } elseif {$complete && ![llength $unexempt]} {'; then
    t_check_fail meas.verdict.no_ids.mutation \
        "with the non-empty test dropped, a run with no ids at all is exempted and the check goes red" \
        verdict_is "$M" 0 "" "$ALLOWED_BOTH" 1 verdict unlisted
else
    t_skip meas.verdict.no_ids.mutation "could not plant the fault: the exemption branch in $PV_REL has changed shape"
fi

t_check meas.verdict.allow_knob \
    "ALLOW_CRITICAL_WARNINGS=1 reports rather than gates, whatever the ids are" \
    verdict_is "$FLOW_DIR" 1 "$IDS_BOTH" "" 0 verdict allowed

M="$(t_mutant "$SB" verdict-ignores-knob)"
if t_replace_line "$M" "$PV_REL" '    if {$allow} {' '    if {0} {'; then
    t_check_fail meas.verdict.allow_knob.mutation \
        "with the knob ignored, a project that declared it out loud is still gated and the check goes red" \
        verdict_is "$M" 1 "$IDS_BOTH" "" 0 verdict allowed
else
    t_skip meas.verdict.allow_knob.mutation "could not plant the fault: the knob branch in $PV_REL has changed shape"
fi

#=============================================================================
# 4. NEITHER STAGE KEEPS A PRIVATE COPY
#
# Both copies of `util_row` carried the same defect, and it would have been
# fixed in one of them. CONTRACT.md section 12.4 already says a stage that writes
# its own manifest emitter is duplicating provenance.tcl; the readers those
# emitters are fed from are the same argument.
#=============================================================================
t_head "the readers live in one place"

# Whole-line comments removed first: the stage headers TALK about these procs,
# and a check that counted prose would report a call present in a file that had
# lost it. Not a parser - a `#` inside a string survives, which can only make
# this stricter.
code_of() { sed 's/^[[:space:]]*#.*$//' "$1"; }
# `grep -c`, never `grep -q`: under `set -o pipefail` a `grep -q` exits on the
# first match, the producer dies of SIGPIPE with 141, and the check goes red
# exactly when its assertion HOLDS.
n_matching() { code_of "$1" | grep -cE -- "$2"; }

## stages_share_readers <root> - both stages call the shared procs and define
## neither of them.
stages_share_readers() {
    local root="$1" rel rc=0
    for rel in "$SY_REL" "$IM_REL"; do
        if [ "$(n_matching "$root/$rel" '(^|\[)[[:space:]]*prov_util_row[[:space:]]')" -lt 1 ]; then
            echo "$rel does not call prov_util_row"; rc=1
        fi
        if [ "$(n_matching "$root/$rel" '(^|\[)[[:space:]]*prov_msg_criticals')" -lt 1 ]; then
            echo "$rel does not call prov_msg_criticals"; rc=1
        fi
        if [ "$(n_matching "$root/$rel" '^[[:space:]]*proc[[:space:]]+(util_row|msg_criticals)[[:space:]]')" -gt 0 ]; then
            echo "$rel defines its own copy of util_row/msg_criticals"; rc=1
        fi
    done
    [ "$rc" -eq 0 ] && return 0
    echo "The parser was duplicated once before and BOTH copies rejected 32.5."
    return 1
}

t_check meas.dedup.readers \
    "4_synth.tcl and 5_impl.tcl read through provenance.tcl and define no copy" \
    stages_share_readers "$FLOW_DIR"

M="$(t_mutant "$SB" stage-private-parser)"
if t_mutate "$M" "$IM_REL" 's/prov_util_row/util_row/g'; then
    t_check_fail meas.dedup.readers.mutation \
        "with the impl stage calling a private util_row again, the check goes red" \
        stages_share_readers "$M"
else
    t_skip meas.dedup.readers.mutation "could not plant the fault: the reader calls in $IM_REL have changed shape"
fi

## stages_gate_on_verdict <root> - the gate asks prov_msg_verdict, and no stage
## still decides completeness by comparing the two counts.
stages_gate_on_verdict() {
    local root="$1" rel rc=0
    for rel in "$SY_REL" "$IM_REL"; do
        if [ "$(n_matching "$root/$rel" 'prov_msg_verdict')" -lt 1 ]; then
            echo "$rel does not reach its message verdict through prov_msg_verdict"; rc=1
        fi
        if [ "$(n_matching "$root/$rel" '\$__nfound[[:space:]]*==[[:space:]]*\$__cw')" -gt 0 ]; then
            echo "$rel still requires the log count to EQUAL the tool counter."
            echo "Vivado resets that counter at opt_design, place_design and"
            echo "route_design, so the two disagree on every impl run that"
            echo "emitted a message before route_design - and the exemption is"
            echo "then refused whatever the project declares."
            rc=1
        fi
    done
    [ "$rc" -eq 0 ] && return 0
    return 1
}

t_check meas.dedup.verdict \
    "both gates decide through prov_msg_verdict, and neither compares the two counts for equality" \
    stages_gate_on_verdict "$FLOW_DIR"

M="$(t_mutant "$SB" stage-equality-gate)"
if t_replace_line "$M" "$SY_REL" \
    '    set __v [prov_msg_verdict $ALLOW_CRITICAL_WARNINGS $__ids \' \
    '    if {$__nfound == $__cw} { set __v {} } ;# the old rule'; then
    t_check_fail meas.dedup.verdict.mutation \
        "with the equality rule planted back in the synth gate, the check goes red" \
        stages_gate_on_verdict "$M"
else
    t_skip meas.dedup.verdict.mutation "could not plant the fault: the gate call in $SY_REL has changed shape"
fi

t_summary
