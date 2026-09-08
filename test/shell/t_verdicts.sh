#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# t_verdicts.sh - the verdict model must be able to report a failure
#
# DEFECT CLASS: A LIBRARY THAT EXISTS TO STOP VACUOUS PASSES, PASSING VACUOUSLY.
#
# ci/lib.sh is where every gate in this toolkit says PASS or FAIL. Four of its
# properties are load-bearing, and each of them fails SILENTLY and GREENLY when
# it breaks - which is why they are tested from outside the library, on a copy,
# with the fault planted:
#
#   1. `ci_unverified` COUNTS AS A FAILURE. CONTRACT.md section 7: a check whose
#      input it could not read has not passed, it has not run. If a refactor
#      ever makes it count as a warning, every gate that reports a missing
#      report goes green while measuring nothing - the exact result the header
#      of ci/lib.sh exists to forbid.
#   2. `ci_exit` is non-zero when ANY gate failed, not when the LAST one did. A
#      tier that fails its third gate and passes its remaining eight must be
#      red. "The last command's status" is the natural shell idiom and it is
#      wrong here, so it is worth a test that would notice somebody restoring it.
#   3. `ci_assert_file` distinguishes ABSENT from ZERO BYTES. Vivado leaves a
#      zero-byte .bit when write_bitstream aborts, and it satisfies every
#      `test -e` in the world. The two cases send a reader to different places.
#   4. THE TSV IS EXACTLY FOUR TAB-SEPARATED COLUMNS. A detail carrying a tab or
#      a newline turns one row into five columns or into two rows, and every
#      `awk -F'\t'` downstream then reads a gate id out of the wrong field and
#      reports a verdict against a gate that does not exist. Silently.
#
# Every assertion below is paired with a MUTATION PROOF: the same assertion, run
# against a copy of the toolkit with one fault planted, must go red. An
# assertion that cannot go red is not measuring the library - it is measuring
# this file's optimism.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/lib/harness.sh
. "$HERE/../lib/harness.sh"

t_sandbox; SB="$T_SANDBOX"

#-----------------------------------------------------------------------------
# WHERE THE FILE UNDER TEST IS, AND WHAT HAPPENS IF IT IS NOT THERE.
#
# A missing ci/lib.sh is a SKIP WITH THE REASON, never a pass. This repository
# is being written by several sessions at once; a suite that reported green
# against a file that had not landed would be reporting on nothing.
#-----------------------------------------------------------------------------
if [ ! -f "$FLOW_DIR/ci/lib.sh" ]; then
    t_skip verdicts.all "ci/lib.sh is not in this checkout at $FLOW_DIR/ci/lib.sh - nothing to test, and an absent file is not a passing one"
    t_summary; exit $?
fi

#-----------------------------------------------------------------------------
# `drive <toolkit> <verdict dir> <body>` sources that toolkit's ci/lib.sh in a
# SUBPROCESS, runs the body, and prints everything the library printed plus a
# COUNTERS line and ci_exit's status.
#
# A subprocess because ci/lib.sh keeps CI_PASS and CI_FAIL in shell globals: a
# test that shared them with the library under test would be measuring itself,
# and `_CI_LIB_SOURCED` would make the second drive of a run a silent no-op.
#-----------------------------------------------------------------------------
drive() {
    local dir="$1" vd="$2" body="$3"
    mkdir -p "$vd"
    ( set -uo pipefail
      unset _CI_LIB_SOURCED
      CI_COLOUR=0; CI_VERDICT_DIR="$vd"; CI_LANE="t_verdicts"; CI_SUMMARY_FILE=""
      export CI_COLOUR CI_VERDICT_DIR CI_LANE CI_SUMMARY_FILE
      # shellcheck source=/dev/null
      . "$dir/ci/lib.sh" || exit 2
      ci_init
      eval "$body"
      rc=0; ci_exit "t_verdicts" >/dev/null 2>&1 || rc=$?
      printf 'COUNTERS PASS=%d FAIL=%d WARN=%d SKIP=%d EXIT=%d\n' \
          "$CI_PASS" "$CI_FAIL" "$CI_WARN" "$CI_SKIP" "$rc"
    ) 2>&1
}

_vd() { printf '%s/vd.%s.%s' "$SB" "$1" "$RANDOM"; }

## counters_are <output> <regex>  - the COUNTERS line must match
counters_are() { printf '%s\n' "$1" | grep -qE "^COUNTERS $2"; }

#=============================================================================
# 1. ci_unverified COUNTS AS A FAILURE
#=============================================================================
t_head "ci_unverified is a failure, not a warning"

## unverified_is_fail <toolkit>
unverified_is_fail() {
    local vd out; vd="$(_vd unv)"
    out="$(drive "$1" "$vd" 'ci_unverified g.evidence "no report at /nowhere"')"
    if counters_are "$out" 'PASS=0 FAIL=1 WARN=0 SKIP=0 EXIT=1'; then return 0; fi
    printf 'ci_unverified did not count as a failure. output:\n%s\n' "$out"
    return 1
}

## unverified_token <toolkit> - column 2 of the row must be the literal token
unverified_token() {
    local vd out; vd="$(_vd unvtok)"
    out="$(drive "$1" "$vd" 'ci_unverified g.evidence "no report"')"
    if awk -F'\t' 'NR==1 && $2 == "UNVERIFIED" { ok=1 } END { exit !ok }' "$vd/verdicts.tsv" 2>/dev/null; then
        return 0
    fi
    printf 'the row is not UNVERIFIED:\n%s\n%s\n' "$(cat "$vd/verdicts.tsv" 2>/dev/null)" "$out"
    return 1
}

t_check verdicts.unverified.fails \
    "ci_unverified moves the FAIL counter and makes ci_exit non-zero" \
    unverified_is_fail "$FLOW_DIR"
t_check verdicts.unverified.token \
    "and records the literal token UNVERIFIED, so a reader is sent to a missing file" \
    unverified_token "$FLOW_DIR"

# -- mutation proof ----------------------------------------------------------
# One fault per copy, so that when the assertion stops holding it is because of
# THIS fault and not some other line that happened to break at the same time.
M="$(t_mutant "$SB" unverified-warns)"
if t_mutate "$M" ci/lib.sh '/^ci_unverified() {/,/^}/ s/CI_FAIL=/CI_WARN=/'; then
    t_check_fail verdicts.unverified.fails.mutation \
        "with ci_unverified counting as a WARN, the assertion above goes red" \
        unverified_is_fail "$M"
else
    t_skip verdicts.unverified.fails.mutation "could not plant the fault: ci/lib.sh no longer has 'CI_FAIL=' inside ci_unverified()"
fi

M="$(t_mutant "$SB" unverified-token)"
if t_replace_line "$M" ci/lib.sh '    _ci_record UNVERIFIED "$id" "$*"' '    _ci_record WARN "$id" "$*"'; then
    t_check_fail verdicts.unverified.token.mutation \
        "with the row recorded as WARN, the token assertion goes red" \
        unverified_token "$M"
else
    t_skip verdicts.unverified.token.mutation "could not plant the fault: the _ci_record line in ci_unverified() has changed"
fi

#=============================================================================
# 2. ci_exit IS NON-ZERO WHEN AN EARLY GATE FAILED AND LATER ONES PASSED
#=============================================================================
t_head "ci_exit reports the run, not the last command"

## exit_is_sticky <toolkit>
exit_is_sticky() {
    local vd out; vd="$(_vd sticky)"
    out="$(drive "$1" "$vd" '
        ci_fail g.early "the third gate of eleven"
        ci_pass g.late  "and everything after it was fine"
        ci_pass g.later "which must not erase the failure above"')"
    if counters_are "$out" 'PASS=2 FAIL=1 WARN=0 SKIP=0 EXIT=1'; then return 0; fi
    printf 'a failed early gate did not survive two later passes. output:\n%s\n' "$out"
    return 1
}

t_check verdicts.exit.sticky \
    "an early FAIL followed by two passes still exits non-zero" \
    exit_is_sticky "$FLOW_DIR"

M="$(t_mutant "$SB" exit-forgets)"
if t_replace_line "$M" ci/lib.sh '    if [ "$CI_FAIL" -gt 0 ]; then' '    if [ "$CI_FAIL" -gt 99 ]; then'; then
    t_check_fail verdicts.exit.sticky.mutation \
        "with ci_exit's failure test neutered, the assertion above goes red" \
        exit_is_sticky "$M"
else
    t_skip verdicts.exit.sticky.mutation "could not plant the fault: ci_exit()'s CI_FAIL test has changed shape"
fi

#=============================================================================
# 3. ci_assert_file DISTINGUISHES ABSENT FROM ZERO BYTES
#=============================================================================
t_head "ci_assert_file: absent and zero-byte are different failures"

printf 'content\n' > "$SB/present.bit"
: > "$SB/zero.bit"
rm -f "$SB/absent.bit"

## file_present_passes <toolkit>
file_present_passes() {
    local vd out; vd="$(_vd fpres)"
    out="$(drive "$1" "$vd" "ci_assert_file g.bit $SB/present.bit 'the image a board loads'")"
    counters_are "$out" 'PASS=1 FAIL=0' && return 0
    printf 'a real artefact did not pass:\n%s\n' "$out"; return 1
}

## file_zero_is_named_zero <toolkit> - FAIL, and the detail must say ZERO BYTES
file_zero_is_named_zero() {
    local vd out; vd="$(_vd fzero)"
    out="$(drive "$1" "$vd" "ci_assert_file g.bit $SB/zero.bit 'the image a board loads'")"
    counters_are "$out" 'PASS=0 FAIL=1' || {
        printf 'a zero-byte artefact did not fail:\n%s\n' "$out"; return 1; }
    grep -qF 'ZERO BYTES' "$vd/verdicts.tsv" 2>/dev/null && return 0
    printf 'the zero-byte case is not named as such:\n%s\n' "$(cat "$vd/verdicts.tsv" 2>/dev/null)"
    return 1
}

## file_absent_is_not_called_zero <toolkit>
file_absent_is_not_called_zero() {
    local vd out; vd="$(_vd fabs)"
    out="$(drive "$1" "$vd" "ci_assert_file g.bit $SB/absent.bit 'the image a board loads'")"
    counters_are "$out" 'PASS=0 FAIL=1' || {
        printf 'an absent artefact did not fail:\n%s\n' "$out"; return 1; }
    if grep -qF 'ZERO BYTES' "$vd/verdicts.tsv" 2>/dev/null; then
        printf 'an ABSENT artefact was reported as zero bytes - the two cases have collapsed:\n%s\n' \
            "$(cat "$vd/verdicts.tsv")"
        return 1
    fi
    grep -qF "no $SB/absent.bit" "$vd/verdicts.tsv" 2>/dev/null && return 0
    printf 'the absent case does not say the file is missing:\n%s\n' "$(cat "$vd/verdicts.tsv" 2>/dev/null)"
    return 1
}

t_check verdicts.file.present  "a real artefact passes"                       file_present_passes "$FLOW_DIR"
t_check verdicts.file.zero     "a ZERO-BYTE artefact fails and is named as such" file_zero_is_named_zero "$FLOW_DIR"
t_check verdicts.file.absent   "an ABSENT artefact fails and is NOT called zero-byte" file_absent_is_not_called_zero "$FLOW_DIR"

# THE MUTATION THAT MATTERS: `-s` becomes `-e`, which is the check every other
# flow in the tree writes and the one that passes a truncated bitstream.
M="$(t_mutant "$SB" file-exists-only)"
if t_replace_line "$M" ci/lib.sh '    if [ -s "$path" ]; then' '    if [ -e "$path" ]; then'; then
    t_check_fail verdicts.file.zero.mutation \
        "with -s weakened to -e a zero-byte artefact passes, so the assertion goes red" \
        file_zero_is_named_zero "$M"
else
    t_skip verdicts.file.zero.mutation "could not plant the fault: ci_assert_file()'s -s test has changed shape"
fi

M="$(t_mutant "$SB" file-collapsed)"
if t_replace_line "$M" ci/lib.sh '    elif [ -e "$path" ]; then' '    elif true; then'; then
    t_check_fail verdicts.file.absent.mutation \
        "with the two branches collapsed an absent file is reported as zero bytes, so the assertion goes red" \
        file_absent_is_not_called_zero "$M"
else
    t_skip verdicts.file.absent.mutation "could not plant the fault: ci_assert_file()'s -e branch has changed shape"
fi

#=============================================================================
# 4. THE TSV IS EXACTLY FOUR TAB-SEPARATED COLUMNS
#=============================================================================
t_head "verdicts.tsv: four columns, one row per verdict, whatever the detail says"

# Six emitters, one of which is handed a detail built the way real details are
# built - out of tool output and paths - carrying a tab, a newline and a
# carriage return.
BODY_TSV='
ci_pass       g.one   "first"
ci_fail       g.two   "second"
ci_unverified g.three "third"
ci_warn       g.four  "fourth"
ci_skip       g.five  "the reason a skip must always carry"
ci_fail       g.six   "$(printf "tab\there newline\nhere return\rhere")"
'

## tsv_four_columns <toolkit>
tsv_four_columns() {
    local vd out bad rows; vd="$(_vd tsv)"
    out="$(drive "$1" "$vd" "$BODY_TSV")"
    [ -s "$vd/verdicts.tsv" ] || { printf 'no verdicts.tsv was written:\n%s\n' "$out"; return 1; }
    rows="$(wc -l < "$vd/verdicts.tsv")"
    if [ "$rows" -ne 6 ]; then
        printf 'six emitters produced %s rows - a detail split a row in two:\n' "$rows"
        cat -A "$vd/verdicts.tsv"; return 1
    fi
    bad="$(awk -F'\t' 'NF != 4 { printf "line %d has %d fields: %s\n", NR, NF, $0 }' "$vd/verdicts.tsv")"
    if [ -n "$bad" ]; then
        printf 'not four columns:\n%s\n' "$bad"; return 1
    fi
    # Column 2 is the verdict and column 3 is the gate id. A row that split
    # would still have four fields in some arrangements, and the arrangement is
    # what every awk downstream depends on.
    bad="$(awk -F'\t' '
        $1 !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/ { print "col1 is not an ISO8601 UTC stamp: " $1 }
        $2 !~ /^(PASS|FAIL|UNVERIFIED|WARN|SKIP)$/                       { print "col2 is not a verdict: " $2 }
        $3 !~ /^g\.[a-z]+$/                                              { print "col3 is not the gate id: " $3 }' \
        "$vd/verdicts.tsv")"
    [ -z "$bad" ] && return 0
    printf 'the columns are not in contract order:\n%s\n' "$bad"
    return 1
}

t_check verdicts.tsv.columns \
    "six verdicts, one carrying a tab, a newline and a CR, give six four-column rows" \
    tsv_four_columns "$FLOW_DIR"

M="$(t_mutant "$SB" tsv-tab)"
if t_replace_line "$M" ci/lib.sh "    detail=\"\${detail//\$'\\t'/ }\"" '    :'; then
    t_check_fail verdicts.tsv.columns.mutation.tab \
        "without the tab sanitiser a detail becomes a fifth column, so the assertion goes red" \
        tsv_four_columns "$M"
else
    t_skip verdicts.tsv.columns.mutation.tab "could not plant the fault: the tab sanitiser in _ci_record has changed shape"
fi

M="$(t_mutant "$SB" tsv-newline)"
if t_replace_line "$M" ci/lib.sh "    detail=\"\${detail//\$'\\n'/ }\"" '    :'; then
    t_check_fail verdicts.tsv.columns.mutation.newline \
        "without the newline sanitiser one verdict becomes two rows, so the assertion goes red" \
        tsv_four_columns "$M"
else
    t_skip verdicts.tsv.columns.mutation.newline "could not plant the fault: the newline sanitiser in _ci_record has changed shape"
fi

# -- the skip's reason, which is a column-4 property ---------------------------
## skip_records_reason <toolkit>
skip_records_reason() {
    local vd out; vd="$(_vd skipr)"
    out="$(drive "$1" "$vd" 'ci_skip g.notapplicable "no board pack declares a bin style here"')"
    awk -F'\t' '$2 == "SKIP" && length($4) > 0 { ok=1 } END { exit !ok }' "$vd/verdicts.tsv" 2>/dev/null \
        && return 0
    printf 'a SKIP was recorded with no reason - "we did not check that" with no why:\n%s\n' \
        "$(cat "$vd/verdicts.tsv" 2>/dev/null)"
    return 1
}
t_check verdicts.skip.reason \
    "a SKIP carries its reason into column 4 (CONTRACT.md section 7)" \
    skip_records_reason "$FLOW_DIR"

M="$(t_mutant "$SB" skip-no-reason)"
if t_replace_line "$M" ci/lib.sh '    _ci_record SKIP "$id" "$*"' '    _ci_record SKIP "$id"'; then
    t_check_fail verdicts.skip.reason.mutation \
        "with the reason dropped from the record, the assertion goes red" \
        skip_records_reason "$M"
else
    t_skip verdicts.skip.reason.mutation "could not plant the fault: ci_skip()'s _ci_record call has changed shape"
fi

#=============================================================================
# 5. A KNOWN DEFECT: THE GATE ID IS NOT SANITISED, ONLY THE DETAIL
#
# _ci_record must strip tab, newline and CR from the GATE ID as well as from the
# detail. Ids are normally literals - but they are also COMPOSED
# (`ci_fail "route.$(basename "$f")"` is the obvious shape), and a composed id
# carrying a tab produced a FIVE-column row with the verdict still in column 2
# and the id split across 3 and 4. Every awk reading $4 as the detail then read
# half an id, and the verdict attached to a gate that does not exist.
#
# HISTORY, kept because it is the harness working: this shipped as a
# t_known_defect - this suite does not own ci/lib.sh, so it recorded the defect
# instead of fixing it. When ci/lib.sh was fixed the marker went RED by itself
# ("KNOWN-DEFECT marker is STALE - this now PASSES. Delete the marker") and was
# promoted to the ordinary assertion below. A defect marker that outlives its
# defect is how a suite starts lying; this one refused to.
#=============================================================================
t_head "the gate id is sanitised too, not just the detail"

## id_is_sanitised <toolkit>  - exits 0 when a tab in the ID is neutralised
id_is_sanitised() {
    local vd; vd="$(_vd idsan)"
    drive "$1" "$vd" 'ci_fail "$(printf "g.id\twith.tab")" "detail"' >/dev/null 2>&1
    awk -F'\t' 'NF != 4 { bad=1 } END { exit bad }' "$vd/verdicts.tsv" 2>/dev/null
}

t_check verdicts.tsv.id_sanitised \
    "a gate id carrying a tab still yields a four-column row, so no verdict attaches to a gate that does not exist" \
    id_is_sanitised "$FLOW_DIR"

# The mutation proof. Put the defect back in a throwaway copy and this must go
# red - otherwise the assertion above passes for some reason other than the
# sanitiser, and would keep passing if the sanitiser were removed again.
#
# Written wrong the first time, and kept as a warning: the first draft passed
# `$FLOW_DIR` to t_mutant as if it were the sandbox. t_mutant refuses that
# (correctly - it will not copy over the real checkout), returned 2 and printed
# NOTHING, so the command under test ran against an empty path, failed for that
# reason, and t_check_fail reported `ok`. A green mutation proof that proves
# nothing is worse than no mutation proof, because it is counted.
M="$(t_mutant "$SB" id-unsanitised)"
if t_replace_line "$M" ci/lib.sh '    id="${id//$'"'"'\t'"'"'/ }"' '    : # id tab sanitiser REMOVED by mutation'; then
    t_check_fail verdicts.tsv.id_sanitised.mutation \
        "with the id tab sanitiser removed, the assertion above goes red" \
        id_is_sanitised "$M"
else
    t_skip verdicts.tsv.id_sanitised.mutation \
        "could not plant the fault: the id tab-sanitiser line in _ci_record() has changed shape"
fi

t_summary
