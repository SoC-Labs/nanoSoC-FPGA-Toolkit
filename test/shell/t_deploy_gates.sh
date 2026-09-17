#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# t_deploy_gates.sh - ci/deploy-gates.sh, the six verdicts a deploy owes
#
# DEFECT CLASS: A GATE GRADING A RECORD THAT NOTHING HAS EVER BEEN SEEN TO WRITE.
#
# The deploy tier has never programmed a device (test/KNOWN_DEFECTS). Every
# claim it makes about leases, program failures and busy boards is code that
# has been read, not run - and ci/deploy-gates.sh is the layer that turns those
# claims into PASS lines. A gate layer over an untested tier is where a green
# run means least: it is the one place a verdict can be produced with no
# hardware, no hub and no network in the loop, so nothing outside the gate can
# contradict it. Its own `--selftest` is a claim the file makes about ITSELF.
#
# So this suite drives the gate FROM OUTSIDE, on a fixture of its own, and
# asserts on what it RECORDED - the rows of verdicts.tsv and their detail
# column, the technique t_tier.sh settled on - never on an exit status alone.
# The properties, each with a planted-fault proof beside it:
#
#   1. THE SIX IDS ARE ONE LIST. The header documents six gate ids, six
#      gate_*() functions implement them, and main calls six. Three copies of
#      one list inside one file, compared against each other rather than
#      against a list in this one (CONTRACT.md rule three).
#   2. THE CLEAN FIXTURE IS GREEN, EXACTLY. Six rows, one per gate, in ladder
#      order, all PASS, nothing else, exit 0. "Exactly" is the property: a gate
#      that emitted twice, or a gate that was skipped, both leave a file that
#      says "passed" somewhere in it.
#   3. ONE PLANTED FAULT PER GATE, AND ONLY THAT GATE GOES RED. The selftest
#      checks that the named gate goes red. It does not check that the other
#      five did not - and a fault that turns two gates red is a gate reading
#      the wrong field, which is the reference project's DRC-undercount shape.
#   4. WHAT WAS NOT MEASURED IS UNVERIFIED, NEVER PASS - driven with the
#      UNVERIFIED:<reason> values the DRIVER writes (holdership check did not
#      answer; no DONE evidence in the 4000-character window; client timeout),
#      which the selftest's fixtures do not contain.
#   5. AN ABSENT RECORD IS REFUSED AND RECORDED. Exit 2, an UNVERIFIED row,
#      absent told apart from zero bytes. The selftest checks the exit code and
#      nothing else here - see the known defect that records that.
#   6. A HEALTHY DRY RUN IS GREEN, with five reasoned SKIPs, and the dry-run
#      values the driver writes (acquired=no, held_at_program=no) do not read
#      as an unheld board.
#   7. THE WARNINGS THE FILE PROMISES - the namespace collision, the anonymous
#      holder, the long TTL - are recorded and are not red.
#   8. THE GATE FILE (CONTRACT.md section 5): `HARD FAILURES: none` exactly on
#      a clean run, the failing gate listed on a red one, UNVERIFIED counted as
#      hard, and every SKIP enumerated under "NOT covered".
#   9. ARGUMENTS: an unknown one is refused with nothing recorded; --manifest
#      beats the environment; and the missing-operand spin that ci/tier.sh,
#      ci/assert-stage.sh and ci/capability.sh were each cured of on
#      2026-09-14 is STILL IN THIS FILE - carried as a known defect.
#  10. MAKE AGREES. The manifest and gate-file names the gate and the driver
#      spell are the ones mk/deploy.mk resolves - asked of make, not read out
#      of the makefile - and a checkout missing the gate is refused by name.
#  11. --selftest IS HONEST, proved by planting faults it claims to catch in a
#      copy and requiring `make deploy-selftest` on that copy to go red.
#  12. THE DRIVER-GATE JOINT. The selftest says plainly what it cannot prove:
#      "that scripts/fpga-flow-deploy writes these fields". Two halves of that
#      are provable with no hub. Statically: every key the gate READS is a key
#      the driver WRITES (one is not - a known defect). Dynamically: the real
#      driver, dry-run, against a socket nothing listens on, writes a manifest
#      the gate grades as "the hub never answered" - UNVERIFIED, not FAIL, not
#      PASS - and five dry-run skips.
#  13. THREE RECORDS THE GATE GRADES WRONGLY, each a manifest one sed edit
#      from the clean one: a key present twice, the skip flag absent, and a
#      lease held at program time on a run whose acquire failed. All three are
#      carried as known defects - this suite does not own ci/deploy-gates.sh.
#  15. A DISCARDED EXIT STATUS. awk exits non-zero when it cannot read its
#      operand, and the gate file's hard-failure test reads that as "nothing
#      found". Measured: verdict directory mode 000 plus a red gate produces
#      an artefact saying `HARD FAILURES: none`. Carried, with the section-8
#      control that proves the predicate can answer both ways.
#  14. THE LIVE HUB. The toolkit was written against a local fpgahub
#      0.1.0.dev0; the hub it runs against is 0.3.0, and the tier was driven
#      against a real KR260 on 2026-09-17. 0.3.0 assigns the lease holder from
#      the connection and ignores the one it is sent, so the toolkit's
#      distinctive-holder discipline is INERT and the one gate that would
#      notice warns on EVERY live run. That is asserted from a third fixture.
#      The second live finding - a preflight group-holder parse that read
#      "free" off a held board - is NOT gradable here, because the field it
#      wrote is read by no gate, and it is carried as a defect rather than
#      dressed up as an assertion.
#
# TEN KNOWN DEFECTS are carried, every one found by an assertion going the
# wrong way rather than by reading: the two argv spins; the selftest's
# blindness to the verdict it claims is recorded; `deploy.test.log`, read by
# the gate and written by nothing; a duplicated key graded from its FIRST
# value in silence when the driver's documented semantics are last-write-wins;
# `deploy.program.skipped` absent read as "not skipped" (a verdict from missing
# data, CONTRACT.md rule two); a lease reported held at program time on a
# run that reports no lease acquired, graded PASS; `deploy.preflight.
# group_holder`, written by the driver and graded by nobody; and the driver
# recording the holder it PROPOSED rather than the one the hub stored; and a
# DISCARDED awk EXIT STATUS that prints `HARD FAILURES: none` into the gate
# file when the verdict file could not be read - the artefact an archived run
# is read through, saying a red deploy was clean.
#
# WHICH FIXTURE SHAPE, AND WHY BOTH. A deploy manifest is a file the DRIVER
# writes, so its key set is the driver's own vocabulary and does not change
# with the hub version; what the hub version changes is which recorded VALUES
# are real. So the choice is not a schema but a set of values, and the suite
# carries both: the 0.1.0-era one, because it is the only manifest that
# reaches a clean six-PASS run and the gate's green path has to be exercised,
# and the 0.3.0 one, because against the live hub no run can reach that state.
# deploy.live.differs asserts the two do not grade alike, so neither can
# quietly stop carrying the difference it exists for.
#
# Every assertion below is paired with a MUTATION PROOF, one fault per copy.
# The fixtures are test/fixtures/deploy_manifest*.txt; every faulted manifest
# is one sed edit away from a clean one, and an edit that changes nothing is
# reported rather than run, because a fault that did not plant turns its
# assertion into a second run of the clean case.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/lib/harness.sh
. "$HERE/../lib/harness.sh"

t_sandbox; SB="$T_SANDBOX"
FIXDIR="$HERE/../fixtures"
FIX="$FIXDIR/deploy_manifest.txt"
FIX_DRY="$FIXDIR/deploy_manifest_dryrun.txt"

#-----------------------------------------------------------------------------
# WHAT HAS TO BE HERE. Skips with the reason, never passes: this repository is
# written by several sessions at once and a suite reporting green against a
# file that has not landed is reporting on nothing.
#-----------------------------------------------------------------------------
for f in ci/deploy-gates.sh ci/lib.sh mk/deploy.mk scripts/fpga-flow-deploy; do
    [ -f "$FLOW_DIR/$f" ] && continue
    t_skip deploy.all "no $FLOW_DIR/$f in this checkout - nothing to drive, and an absent file is not a passing one"
    t_summary; exit $?
done
for f in "$FIX" "$FIX_DRY"; do
    [ -s "$f" ] && continue
    t_skip deploy.all "no $f - the fixture this suite grades against is missing, so it would be grading nothing"
    t_summary; exit $?
done

#-----------------------------------------------------------------------------
# DRIVING THE GATE
#
# THE ENVIRONMENT IS BUILT, NOT INHERITED. FPGA_REPORT_DIR and REPORT_DIR are
# where the gate looks when no --manifest is given, CI_APPEND stops ci_init
# truncating, and a developer's shell may carry any of them.
#-----------------------------------------------------------------------------
GATE_ENV=(env -u FPGA_REPORT_DIR -u REPORT_DIR -u FPGA_RUN_DIR -u RUN_DIR
          -u CI_APPEND -u CI_LANE -u CI_SUMMARY_FILE -u GITHUB_STEP_SUMMARY
          CI_COLOUR=0)

## vd_new - a fresh verdict directory. mktemp rather than $RANDOM: t_check runs
## each predicate in a command substitution, and two predicates computing a
## name from $RANDOM can be handed the same number.
vd_new() { mktemp -d "$SB/vdXXXXXXXX"; }

## grade <toolkit> <verdict dir> [args...]
## Runs that toolkit's gate with its verdicts in <verdict dir>, prints what it
## printed plus EXIT=<n>, because the exit status is under test and `$?` does
## not survive a command substitution. `bash <path>` for test/run.sh's reason.
grade() {
    local dir="$1" vd="$2"; shift 2
    local rc=0 out
    out="$("${GATE_ENV[@]}" CI_VERDICT_DIR="$vd" bash "$dir/ci/deploy-gates.sh" "$@" 2>&1)" || rc=$?
    printf '%s\nEXIT=%d\n' "$out" "$rc"
}
exit_of() { printf '%s\n' "$1" | sed -n 's/^EXIT=//p' | tail -1; }

## verdicts_of <vd> <gate id>  - column 2 of EVERY row with that id
## detail_of   <vd> <gate id>  - column 4 of the first
verdicts_of() { awk -F'\t' -v g="$2" '$3 == g { print $2 }' "$1/verdicts.tsv" 2>/dev/null; }
detail_of()   { awk -F'\t' -v g="$2" '$3 == g { print $4; exit }' "$1/verdicts.tsv" 2>/dev/null; }
rows_of()     { cut -f2,3,4 "$1/verdicts.tsv" 2>/dev/null | cut -c1-110; }

## mfval <manifest> <key> - the same first-match read ci_mf performs
mfval() { awk -v k="$2" '$1 == k { $1 = ""; sub(/^[ \t]+/, ""); print; exit }' "$1"; }

## plant <mutant> <relative path> <sed expression...>
##
## t_mutate, plus the check a week of this repository's mistakes has earned.
##
## WHY NOT t_replace_line FOR EVERY PROOF. `t_replace_line` builds the sed
## script `${n}c\<replacement>`, and sed's `c\` EATS A TRAILING BACKSLASH: a
## fault aimed at a line ending in `\` - which is every continued `awk`, every
## continued `ci_warn`, every continued recipe line in this toolkit - plants a
## BROKEN CONTINUATION instead of the fault the proof describes. The mutant
## then means something other than what the proof says, and in the worst case
## dies of a syntax error: the predicate returns non-zero FOR FREE and
## t_check_fail prints `ok`. Measured here, on the one proof of the seven whose
## predicate could not tell the difference - mk/deploy.mk's presence guard,
## where the eaten backslash produced `/bin/sh: syntax error: unexpected end of
## file` and the assertion went green having never reached the 127 it exists to
## catch. Every proof in this file that aims at a continued line uses `plant`.
##
## AND THE MUTANT MUST STILL PARSE. A copy left unparseable - by a bad plant,
## or by a sandbox lost under load mid-run - makes EVERY predicate below return
## non-zero for free, which is the same false green from the other direction.
## Checked here rather than trusted, once per plant, for a few milliseconds.
plant() {
    local mut="$1" rel="$2"; shift 2
    t_mutate "$mut" "$rel" "$@" || return 2
    case "$rel" in
        *.mk)
            make -f "$mut/$rel" -n deploy-vars >/dev/null 2>&1 || {
                echo "harness: the planted fault left $rel unparseable to make" >&2; return 2; } ;;
        *)
            bash -n "$mut/$rel" 2>/dev/null || {
                echo "harness: the planted fault left $rel unparseable by bash" >&2; return 2; } ;;
    esac
    return 0
}

## faulted <clean manifest> <sed expression> -> a copy with ONE edit applied.
## REFUSES (exit 2, message) when the edit changed nothing: the assertion it
## feeds would otherwise pass or fail on the clean fixture's account, which is
## harness t_mutate's reason applied to the data side.
faulted() {
    local src="$1" expr="$2" dst
    dst="$(mktemp "$SB/mf.XXXXXXXX")" || return 2
    sed "$expr" "$src" > "$dst"
    if cmp -s "$src" "$dst"; then
        printf 'FAULT DID NOT PLANT in %s: %s\n' "$(basename "$src")" "$expr" >&2
        rm -f "$dst"; return 2
    fi
    printf '%s' "$dst"
}

#-----------------------------------------------------------------------------
# THE LADDER, DERIVED. Three lists in the file, none in this suite.
#-----------------------------------------------------------------------------

## header_ids <toolkit> - the gate ids the file's header documents, in order
header_ids() { grep -oE '^#   deploy\.[a-z]+ ' "$1/ci/deploy-gates.sh" | awk '{ print $2 }'; }
## fn_ids <toolkit>     - the gate_*() functions defined, in order, as ids
fn_ids()     { grep -oE '^gate_[a-z]+\(\)' "$1/ci/deploy-gates.sh" | sed 's/^gate_/deploy./; s/()$//'; }
## call_ids <toolkit>   - the gate_* calls main makes, in order, as ids
call_ids()   { grep -E '^gate_[a-z]+$' "$1/ci/deploy-gates.sh" | sed 's/^gate_/deploy./'; }

IDS="$(header_ids "$FLOW_DIR" | tr '\n' ' ')"
N_IDS="$(printf '%s' "$IDS" | wc -w)"

## ladder_rows <vd> - "<id> <verdict>" for every row whose id is a ladder id, in file order
ladder_rows() {
    awk -F'\t' -v ids=" $IDS " 'index(ids, " " $3 " ") { print $3, $2 }' "$1/verdicts.tsv" 2>/dev/null
}
## ladder_expect <default verdict> [id=VERDICT ...] - the ladder with those verdicts
ladder_expect() {
    local dflt="$1" id v ov; shift
    for id in $IDS; do
        v="$dflt"
        for ov in "$@"; do [ "${ov%%=*}" = "$id" ] && v="${ov#*=}"; done
        printf '%s %s\n' "$id" "$v"
    done
}

#=============================================================================
# 1. THE SIX IDS ARE ONE LIST
#
# The header is what a reader greps for; the functions are what runs; the
# calls in main are what a run records. A gate documented and never called
# records nothing - and a gate absent from the report is indistinguishable
# from a gate that passed (t_tier.sh, section 3, the same shape).
#=============================================================================
t_head "the six gate ids: documented, implemented and called are one list"

## ids_derivable <toolkit> - the header yields a usable list at all
ids_derivable() {
    local n; n="$(header_ids "$1" | grep -c .)"
    [ "$n" -ge 3 ] && return 0
    printf 'the header documents %s gate id(s). Every expectation in this suite is\n' "$n"
    printf 'derived from that list, and with nothing in it there is nothing to compare.\n'
    return 1
}

## ids_agree <toolkit> - header == functions == calls, as ordered lists
ids_agree() {
    local h f c
    h="$(header_ids "$1")"; f="$(fn_ids "$1")"; c="$(call_ids "$1")"
    if [ "$h" != "$f" ]; then
        printf 'DOCUMENTED:\n%s\nIMPLEMENTED (gate_*() functions):\n%s\n' "$h" "$f"
        printf 'A gate id in the header with no function is a promise; a function with no\n'
        printf 'header line is a verdict nobody knows to grep for.\n'
        return 1
    fi
    if [ "$f" != "$c" ]; then
        printf 'IMPLEMENTED:\n%s\nCALLED by main, in order:\n%s\n' "$f" "$c"
        printf 'A gate implemented and not called records NOTHING, and a run with five rows\n'
        printf 'looks exactly like a run that passed five gates.\n'
        return 1
    fi
    return 0
}

t_check deploy.ids.derivable "the header names the gate ids, and that list is this suite's source of truth" \
    ids_derivable "$FLOW_DIR"
t_check deploy.ids.agree "the ids documented, the gate_*() functions and the calls in main are one ordered list" \
    ids_agree "$FLOW_DIR"
t_say "$N_IDS gate ids: $IDS"

if [ "$N_IDS" -lt 3 ]; then
    t_skip deploy.all "the header yielded $N_IDS gate id(s) in THIS run (deploy.ids.derivable above is red); every expectation here is derived from that list and this suite will not invent one"
    t_summary; exit $?
fi

# THE TRAILING SPACE IS STRIPPED FIRST, and this suite shipped without that for
# one run, which is worth the comment. `$IDS` comes from `tr '\n' ' '`, so it
# ENDS in a space, and `${IDS##* }` on it is the empty string. LAST_FN became
# the bare `gate_`, which matches no line, so three proofs skipped - and
# LAST_HDR's `grep -E "^#   $LAST_ID "` became `^#    `, which matched the first
# CONTINUATION LINE of the header block instead. That proof then planted its
# fault into a comment, the assertion correctly stayed green, and t_check_fail
# reported THE CHECK ACCEPTED A PLANTED FAULT. A derivation that silently
# yields nothing is the same defect class this suite is pointed at, one level
# up: the empty value did not fail, it quietly addressed the wrong line.
LAST_ID="${IDS% }"; LAST_ID="${LAST_ID##* }"         # the last id, e.g. deploy.release
LAST_FN="gate_${LAST_ID#deploy.}"                    # its function, e.g. gate_release
LAST_HDR="$(grep -m1 -E "^#   $LAST_ID " "$FLOW_DIR/ci/deploy-gates.sh")"
if [ -z "$LAST_ID" ] || [ -z "$LAST_HDR" ]; then
    t_fail deploy.ids.derived "the last gate id derived from the header is '${LAST_ID:-<empty>}' and its header line is '${LAST_HDR:-<none>}' - four proofs below address lines computed from these, and an empty value addresses the wrong line rather than none"
fi

M="$(t_mutant "$SB" ids-uncalled)"
if t_replace_line "$M" ci/deploy-gates.sh "$LAST_FN" "# planted fault: main no longer calls $LAST_FN"; then
    t_check_fail deploy.ids.agree.mutation.uncalled \
        "with main's call to $LAST_FN deleted, the assertion goes red" \
        ids_agree "$M"
else
    t_skip deploy.ids.agree.mutation.uncalled "could not plant the fault: no bare '$LAST_FN' call line in the copy's main"
fi

M="$(t_mutant "$SB" ids-undocumented)"
if [ -n "$LAST_HDR" ] && t_replace_line "$M" ci/deploy-gates.sh "$LAST_HDR" "#   (planted fault: one gate id is no longer documented)"; then
    t_check_fail deploy.ids.agree.mutation.undocumented \
        "with $LAST_ID's header line removed, the assertion goes red" \
        ids_agree "$M"
else
    t_skip deploy.ids.agree.mutation.undocumented "could not plant the fault: no '#   $LAST_ID ' line in the copy's header"
fi

#=============================================================================
# 2. THE CLEAN FIXTURE IS GREEN, EXACTLY
#
# Six rows, one per gate id, in ladder order, every one PASS, no other row of
# any kind, exit 0. Each clause has a fault that breaks only it.
#=============================================================================
t_head "the clean six-moment fixture: exactly six PASS rows in ladder order, exit 0"

## clean_is_exactly_green <toolkit> <manifest>
clean_is_exactly_green() {
    local dir="$1" mf="$2" vd out rc got want n
    vd="$(vd_new)"
    out="$(grade "$dir" "$vd" --manifest "$mf")"; rc="$(exit_of "$out")"
    [ -s "$vd/verdicts.tsv" ] || { printf 'no verdicts.tsv was written:\n%s\n' "$out"; return 1; }
    got="$(ladder_rows "$vd")"; want="$(ladder_expect PASS)"
    if [ "$got" != "$want" ]; then
        printf 'the ladder rows are not the six PASSes in order.\nGOT:\n%s\nWANT:\n%s\n' "$got" "$want"
        return 1
    fi
    n="$(wc -l < "$vd/verdicts.tsv")"
    if [ "$n" -ne "$N_IDS" ]; then
        printf '%s rows for %s gates - a gate recorded twice, or a row that is not a gate:\n%s\n' \
            "$n" "$N_IDS" "$(rows_of "$vd")"
        return 1
    fi
    [ "$rc" = 0 ] && return 0
    printf 'six PASS rows and exit %s. ci_exit is non-zero only when a gate failed; nothing did.\n%s\n' "$rc" "$out"
    return 1
}

t_check deploy.clean.ladder \
    "the clean fixture grades as exactly $N_IDS PASS rows, one per gate, in ladder order, and exits 0" \
    clean_is_exactly_green "$FLOW_DIR" "$FIX"

M="$(t_mutant "$SB" clean-missing-row)"
if t_replace_line "$M" ci/deploy-gates.sh "$LAST_FN" "# planted fault: $LAST_FN is never reached"; then
    t_check_fail deploy.clean.ladder.mutation.missing \
        "with one gate never called, its row is absent and the assertion goes red" \
        clean_is_exactly_green "$M" "$FIX"
else
    t_skip deploy.clean.ladder.mutation.missing "could not plant the fault: no bare '$LAST_FN' call line in the copy's main"
fi

M="$(t_mutant "$SB" clean-double-row)"
if t_mutate "$M" ci/deploy-gates.sh "/^$LAST_FN\$/p"; then
    t_check_fail deploy.clean.ladder.mutation.twice \
        "with one gate called twice, it records two rows and the assertion goes red" \
        clean_is_exactly_green "$M" "$FIX"
else
    t_skip deploy.clean.ladder.mutation.twice "could not plant the fault: no bare '$LAST_FN' call line in the copy's main to duplicate"
fi

FIRST_FN="gate_${IDS%% *}"; FIRST_FN="${FIRST_FN/deploy./}"
SECOND_ID="$(printf '%s\n' $IDS | sed -n 2p)"; SECOND_FN="gate_${SECOND_ID#deploy.}"
M="$(t_mutant "$SB" clean-reordered)"
if t_mutate "$M" ci/deploy-gates.sh "/^$FIRST_FN\$/{N;s/^$FIRST_FN\\n$SECOND_FN\$/$SECOND_FN\\n$FIRST_FN/}"; then
    t_check_fail deploy.clean.ladder.mutation.reordered \
        "with the first two gates called in the other order, the rows leave ladder order and the assertion goes red" \
        clean_is_exactly_green "$M" "$FIX"
else
    t_skip deploy.clean.ladder.mutation.reordered "could not plant the fault: '$FIRST_FN' is not immediately followed by '$SECOND_FN' in the copy's main"
fi

# NOT the case arm - a `case` label cannot be given a second body by rewriting
# the label, so the fault goes in the arm's EMITTER, which is the line that
# decides the verdict class anyway.
M="$(t_mutant "$SB" clean-not-pass)"
if t_replace_line "$M" ci/deploy-gates.sh \
        '            ci_pass deploy.release "lease released (token-scoped, holder $(mf deploy.lease.holder))" ;;' \
        '            ci_warn deploy.release "lease released (token-scoped, holder $(mf deploy.lease.holder))" ;;'; then
    t_check_fail deploy.clean.ladder.mutation.not_pass \
        "with the release gate's pass demoted to a warning, the row is WARN and the assertion goes red" \
        clean_is_exactly_green "$M" "$FIX"
else
    t_skip deploy.clean.ladder.mutation.not_pass "could not plant the fault: gate_release's ci_pass line has changed shape"
fi

#=============================================================================
# 2.1 THE RECORD IS READ BY KEY, NOT BY POSITION
#
# THE SIX MOMENTS ARE TIME-ORDERED; THE FILE IS NOT, AND MUST NOT BE. A deploy
# manifest carries no per-field timestamp and no required line order - the
# driver emits keys in the order it happens to learn them, and `mf_set` makes
# a LATER write win IN PLACE, so a corrected value keeps its ORIGINAL
# POSITION. A gate that acquired any sensitivity to position would therefore
# misgrade archived manifests silently, which is the one direction that
# matters: the manifests this file exists to grade are read days later, by a
# version of the gate nobody diffed against the one that wrote them.
#
# So the assertion is that a manifest with its lines REVERSED grades
# identically to the clean one, and the proof makes the reader stop after
# twenty-five lines - the shape any "read just the head of it" optimisation
# would take. The ordering that IS enforced is SEMANTIC and lives in the
# gates: verify refuses to grade DONE when the program was never attempted
# (asserted in section 4), release skips when nothing was acquired. The one
# semantic ordering that is NOT enforced - a lease held at program time on a
# run whose acquire failed - is section 13's known defect.
#=============================================================================
t_head "the six moments are time-ordered; their record is read by key, and line order carries nothing"

## order_is_not_semantic <toolkit>
## The clean fixture and the same fixture reversed must produce the same
## verdicts, in the same order - the row order comes from the CALL order in
## main, never from the file.
order_is_not_semantic() {
    local dir="$1" a b rev
    rev="$(mktemp "$SB/rev.XXXXXXXX")" || return 2
    tac "$FIX" > "$rev"
    cmp -s "$FIX" "$rev" && { echo 'the fixture is a palindrome, so reversing it measures nothing'; return 1; }
    a="$(vd_new)"; b="$(vd_new)"
    grade "$dir" "$a" --manifest "$FIX" >/dev/null
    grade "$dir" "$b" --manifest "$rev" >/dev/null
    [ -s "$b/verdicts.tsv" ] || { echo 'the reversed manifest produced no verdicts at all'; return 1; }
    [ "$(cut -f2,3 "$a/verdicts.tsv")" = "$(cut -f2,3 "$b/verdicts.tsv")" ] && return 0
    printf 'the same record, reversed, grades differently.\nAS WRITTEN:\n%s\nREVERSED:\n%s\n' \
        "$(rows_of "$a")" "$(rows_of "$b")"
    printf 'A manifest has no required line order, so a gate sensitive to it returns a\n'
    printf 'different verdict for the same deploy depending on what the driver happened\n'
    printf 'to learn first.\n'
    return 1
}

t_check deploy.record.by_key \
    "the clean fixture and the same fixture with every line reversed grade identically - position carries nothing" \
    order_is_not_semantic "$FLOW_DIR"

# The fault is planted in ci_mf, which is the one reader every `mf` call goes
# through, and it is the shape a "just read the head of the file" change would
# take. t_verdicts.sh owns ci/lib.sh; this is a throwaway copy of it.
MF_AWK="$(grep -m1 -F 'awk -v k="$2"' "$FLOW_DIR/ci/lib.sh")"
M="$(t_mutant "$SB" mf-reads-head-only)"
if [ -n "$MF_AWK" ] && t_replace_line "$M" ci/lib.sh "$MF_AWK" \
        "$(printf '%s' "$MF_AWK" | sed "s/awk -v k=\"\\\$2\" '/awk -v k=\"\$2\" 'NR > 25 { exit } /")"; then
    t_check_fail deploy.record.by_key.mutation \
        "with the manifest reader stopping after twenty-five lines, the reversed record loses its late keys and the assertion goes red" \
        order_is_not_semantic "$M"
else
    t_skip deploy.record.by_key.mutation "could not plant the fault: ci_mf's awk is no longer a single line starting 'awk -v k=\"\$2\"'"
fi

#=============================================================================
# 3. ONE PLANTED FAULT PER GATE - AND ONLY THAT GATE GOES RED
#
# Each fixture below changes ONE line of the clean manifest to a value the
# driver would record on that failure. The named gate must be FAIL, every
# other gate must be exactly what it was on the clean run, and the process
# must exit 1 - "we looked and found something", not 2. The selftest asserts
# the first clause; the second is the discrimination it does not ask for.
#
# The faults are the ones the tier's own documentation names as the ways it
# fails: the KR260 gap (no program method), programming an unheld board, the
# 400 that reads as a bad bitstream, DONE not asserted, a failed action, a
# release the hub refused.
#=============================================================================
t_head "one planted fault per gate: that gate is FAIL, the other five untouched, exit 1"

## one_gate_red <toolkit> <manifest> <gate id>
one_gate_red() {
    local dir="$1" mf="$2" id="$3" vd out rc got want
    vd="$(vd_new)"
    out="$(grade "$dir" "$vd" --manifest "$mf")"; rc="$(exit_of "$out")"
    got="$(ladder_rows "$vd")"; want="$(ladder_expect PASS "$id=FAIL")"
    if [ "$got" != "$want" ]; then
        printf 'one line planted against %s.\nGOT:\n%s\nWANT:\n%s\n' "$id" "$got" "$want"
        return 1
    fi
    [ "$rc" = 1 ] && return 0
    printf '%s is FAIL and the process exited %s, not 1.\n' "$id" "$rc"
    return 1
}

# The six fixtures, planted once and shared by the assertion and its proof.
MF_PRE="$(faulted "$FIX" 's|^deploy.preflight.program_method .*|deploy.preflight.program_method none|')" || t_fail deploy.fixture.plant "preflight fault did not plant"
MF_LEASE="$(faulted "$FIX" 's|^deploy.lease.held_at_program .*|deploy.lease.held_at_program no|')" || t_fail deploy.fixture.plant "lease fault did not plant"
MF_PROG="$(faulted "$FIX" 's|^deploy.program.http_status .*|deploy.program.http_status 400|')" || t_fail deploy.fixture.plant "program fault did not plant"
MF_VERIFY="$(faulted "$FIX" 's|^deploy.verify.program_verified .*|deploy.verify.program_verified no|')" || t_fail deploy.fixture.plant "verify fault did not plant"
MF_TEST="$(faulted "$FIX" 's|^deploy.test.state .*|deploy.test.state failed|')" || t_fail deploy.fixture.plant "test fault did not plant"
MF_REL="$(faulted "$FIX" 's|^deploy.release.result .*|deploy.release.result http-500|')" || t_fail deploy.fixture.plant "release fault did not plant"

t_check deploy.preflight.red "no program method (the KR260 gap): deploy.preflight FAIL, the rest PASS, exit 1" \
    one_gate_red "$FLOW_DIR" "$MF_PRE" deploy.preflight
t_check deploy.lease.red "held_at_program=no: deploy.lease FAIL - the board was programmed unheld - the rest PASS" \
    one_gate_red "$FLOW_DIR" "$MF_LEASE" deploy.lease
t_check deploy.program.red "HTTP 400 from the program endpoint: deploy.program FAIL, the rest PASS" \
    one_gate_red "$FLOW_DIR" "$MF_PROG" deploy.program
t_check deploy.verify.red "program_verified=no: deploy.verify FAIL - the image reached the cable, not the fabric" \
    one_gate_red "$FLOW_DIR" "$MF_VERIFY" deploy.verify
t_check deploy.test.red "action state 'failed': deploy.test FAIL - the one gate that is about the design" \
    one_gate_red "$FLOW_DIR" "$MF_TEST" deploy.test
t_check deploy.release.red "release returned http-500: deploy.release FAIL - the board stays held until the TTL" \
    one_gate_red "$FLOW_DIR" "$MF_REL" deploy.release

# -- proofs: each gate's own refusal neutered in its own copy -----------------
M="$(t_mutant "$SB" preflight-accepts-none)"
if t_replace_line "$M" ci/deploy-gates.sh '    if [ "$method" = "none" ]; then' '    if false; then'; then
    t_check_fail deploy.preflight.red.mutation \
        "with the no-program-method test neutered, a KR260-shaped target passes preflight and the assertion goes red" \
        one_gate_red "$M" "$MF_PRE" deploy.preflight
else
    t_skip deploy.preflight.red.mutation "could not plant the fault: gate_preflight's 'method = none' test has changed shape"
fi

M="$(t_mutant "$SB" lease-accepts-unheld)"
if t_replace_line "$M" ci/deploy-gates.sh '    if ! truthy "$held"; then' '    if false; then'; then
    t_check_fail deploy.lease.red.mutation \
        "with the held-at-program test neutered, an unheld board passes the lease gate and the assertion goes red" \
        one_gate_red "$M" "$MF_LEASE" deploy.lease
else
    t_skip deploy.lease.red.mutation "could not plant the fault: gate_lease's truthy test on held_at_program has changed shape"
fi

M="$(t_mutant "$SB" program-accepts-any-status)"
if t_replace_line "$M" ci/deploy-gates.sh '        2??) ;;' '        *) ;;'; then
    t_check_fail deploy.program.red.mutation \
        "with every HTTP status accepted as 2xx, a 400 passes the program gate and the assertion goes red" \
        one_gate_red "$M" "$MF_PROG" deploy.program
else
    t_skip deploy.program.red.mutation "could not plant the fault: gate_program's '2??)' case arm has changed shape"
fi

M="$(t_mutant "$SB" verify-accepts-no)"
if t_replace_line "$M" ci/deploy-gates.sh '    if ! truthy "$verified"; then' '    if false; then'; then
    t_check_fail deploy.verify.red.mutation \
        "with the DONE test neutered, program_verified=no passes and the assertion goes red" \
        one_gate_red "$M" "$MF_VERIFY" deploy.verify
else
    t_skip deploy.verify.red.mutation "could not plant the fault: gate_verify's truthy test on program_verified has changed shape"
fi

M="$(t_mutant "$SB" test-accepts-failed)"
if t_replace_line "$M" ci/deploy-gates.sh '        ok)' '        ok|failed)'; then
    t_check_fail deploy.test.red.mutation \
        "with 'failed' added to the passing states, a failed action passes and the assertion goes red" \
        one_gate_red "$M" "$MF_TEST" deploy.test
else
    t_skip deploy.test.red.mutation "could not plant the fault: gate_test's 'ok)' case arm has changed shape"
fi

M="$(t_mutant "$SB" release-accepts-500)"
if t_replace_line "$M" ci/deploy-gates.sh '        ok|released)' '        ok|released|http-500)'; then
    t_check_fail deploy.release.red.mutation \
        "with http-500 added to the released states, a refused release passes and the assertion goes red" \
        one_gate_red "$M" "$MF_REL" deploy.release
else
    t_skip deploy.release.red.mutation "could not plant the fault: gate_release's 'ok|released)' case arm has changed shape"
fi

#=============================================================================
# 4. WHAT WAS NOT MEASURED IS UNVERIFIED, NEVER PASS
#
# CONTRACT.md rule two. The values planted here are the UNVERIFIED:<reason>
# strings the DRIVER writes - read out of scripts/fpga-flow-deploy, not
# invented - and none of them is in the selftest's fixtures, which delete the
# field instead. Deleting and writing `UNVERIFIED:<why>` are different records
# (section 5: "an empty field and a field saying why it is empty are different
# findings"), and only the second is what the driver produces.
#
# The verdict CLASS is asserted, not merely redness: each proof below turns an
# UNVERIFIED into a FAIL, which is still red and still exit 1 - and still wrong,
# because it sends the reader to argue with a number instead of to look for a
# missing measurement.
#=============================================================================
t_head "the driver's own UNVERIFIED:<reason> values grade as UNVERIFIED, never PASS and never FAIL"

## one_gate_unverified <toolkit> <manifest> <gate id> [other id=VERDICT...]
one_gate_unverified() {
    local dir="$1" mf="$2" id="$3" vd out rc got want; shift 3
    vd="$(vd_new)"
    out="$(grade "$dir" "$vd" --manifest "$mf")"; rc="$(exit_of "$out")"
    got="$(ladder_rows "$vd")"; want="$(ladder_expect PASS "$id=UNVERIFIED" "$@")"
    if [ "$got" != "$want" ]; then
        printf 'GOT:\n%s\nWANT:\n%s\n' "$got" "$want"
        return 1
    fi
    [ "$rc" = 1 ] && return 0
    printf 'an UNVERIFIED gate and exit %s, not 1 - UNVERIFIED counts as a failure (CONTRACT.md 7)\n' "$rc"
    return 1
}

MF_HELD_U="$(faulted "$FIX" 's|^deploy.lease.held_at_program .*|deploy.lease.held_at_program UNVERIFIED:holdership-check-http-500|')" || t_fail deploy.fixture.plant "held UNVERIFIED did not plant"
MF_DONE_U="$(faulted "$FIX" 's|^deploy.verify.program_verified .*|deploy.verify.program_verified UNVERIFIED:no PROGRAM_VERIFIED and no (DONE unverified) in the response|')" || t_fail deploy.fixture.plant "verify UNVERIFIED did not plant"
MF_STATE_U="$(faulted "$FIX" 's|^deploy.test.state .*|deploy.test.state UNVERIFIED:client timeout after 900s, action may still be running|')" || t_fail deploy.fixture.plant "state UNVERIFIED did not plant"
MF_ATT_U="$(faulted "$FIX" 's|^deploy.program.attempted .*|deploy.program.attempted UNVERIFIED:not-recorded|')" || t_fail deploy.fixture.plant "attempted UNVERIFIED did not plant"

t_check deploy.lease.unverified \
    "the holdership check that did not answer (the driver's own value) is UNVERIFIED on deploy.lease" \
    one_gate_unverified "$FLOW_DIR" "$MF_HELD_U" deploy.lease
t_check deploy.verify.unverified \
    "no DONE evidence either way in the 4000-character window is UNVERIFIED on deploy.verify" \
    one_gate_unverified "$FLOW_DIR" "$MF_DONE_U" deploy.verify
t_check deploy.test.unverified \
    "a client timeout with the action possibly still running is UNVERIFIED on deploy.test" \
    one_gate_unverified "$FLOW_DIR" "$MF_STATE_U" deploy.test

## attempted_unverified_never_configures <toolkit> <manifest>
## program.attempted=UNVERIFIED:x is UNVERIFIED on program AND on verify: a
## device nobody is sure was programmed has no DONE to grade. This is where the
## `truthy` whitelist earns its keep - `!= no` would read the UNVERIFIED string
## as yes and grade DONE off a program that may never have been sent.
attempted_unverified_never_configures() {
    one_gate_unverified "$1" "$2" deploy.program deploy.verify=UNVERIFIED
}
t_check deploy.truthy.whitelist \
    "program.attempted=UNVERIFIED:x is UNVERIFIED on program and on verify - the truthy whitelist, not '!= no'" \
    attempted_unverified_never_configures "$FLOW_DIR" "$MF_ATT_U"

# -- proofs -------------------------------------------------------------------
M="$(t_mutant "$SB" lease-unmeasured-is-fail)"
if t_replace_line "$M" ci/deploy-gates.sh '    if ! ci_is_measured "$held"; then' '    if false; then'; then
    t_check_fail deploy.lease.unverified.mutation \
        "with the measured-ness test skipped the UNVERIFIED value falls through to FAIL, and the class assertion goes red" \
        one_gate_unverified "$M" "$MF_HELD_U" deploy.lease
else
    t_skip deploy.lease.unverified.mutation "could not plant the fault: gate_lease's ci_is_measured test on held_at_program has changed shape"
fi

M="$(t_mutant "$SB" verify-unmeasured-is-fail)"
if t_replace_line "$M" ci/deploy-gates.sh '    if ! ci_is_measured "$verified"; then' '    if false; then'; then
    t_check_fail deploy.verify.unverified.mutation \
        "with the measured-ness test skipped the UNVERIFIED value falls through to FAIL, and the class assertion goes red" \
        one_gate_unverified "$M" "$MF_DONE_U" deploy.verify
else
    t_skip deploy.verify.unverified.mutation "could not plant the fault: gate_verify's ci_is_measured test on program_verified has changed shape"
fi

M="$(t_mutant "$SB" test-unmeasured-is-fail)"
if t_replace_line "$M" ci/deploy-gates.sh '    if ! ci_is_measured "$state"; then' '    if false; then'; then
    t_check_fail deploy.test.unverified.mutation \
        "with the measured-ness test skipped the UNVERIFIED state falls through to FAIL, and the class assertion goes red" \
        one_gate_unverified "$M" "$MF_STATE_U" deploy.test
else
    t_skip deploy.test.unverified.mutation "could not plant the fault: gate_test's ci_is_measured test on state has changed shape"
fi

M="$(t_mutant "$SB" truthy-is-not-no)"
if t_replace_line "$M" ci/deploy-gates.sh \
        'truthy() { [ "${1:-}" = "yes" ] || [ "${1:-}" = "true" ] || [ "${1:-}" = "1" ]; }' \
        'truthy() { [ "${1:-}" != "no" ]; }'; then
    t_check_fail deploy.truthy.whitelist.mutation \
        "with truthy back to '!= no', the UNVERIFIED string reads as yes, verify grades DONE off it, and the assertion goes red" \
        attempted_unverified_never_configures "$M" "$MF_ATT_U"
else
    t_skip deploy.truthy.whitelist.mutation "could not plant the fault: truthy() is no longer a one-line whitelist"
fi

#=============================================================================
# 5. THE ABSENT RECORD
#
# The file's header: "That case is refused (exit 2) with an UNVERIFIED verdict
# recorded - never a skip". Two claims. The selftest checks the exit code and
# nothing else, so a ci_skip planted there passes the selftest - the fourth
# known defect, recorded at the end of this section rather than fixed, because
# this suite does not own ci/deploy-gates.sh.
#=============================================================================
t_head "an absent record: exit 2, an UNVERIFIED row, and absent told apart from zero bytes"

## absent_is_refused_and_recorded <toolkit>
absent_is_refused_and_recorded() {
    local dir="$1" vd out rc v d
    vd="$(vd_new)"
    out="$(grade "$dir" "$vd" --manifest "$vd/no-such-manifest.txt")"; rc="$(exit_of "$out")"
    v="$(verdicts_of "$vd" deploy.preflight)"; d="$(detail_of "$vd" deploy.preflight)"
    if [ "$v" != "UNVERIFIED" ]; then
        printf 'no manifest, and deploy.preflight is "%s", not UNVERIFIED:\n%s\n%s\n' "${v:-<no row>}" "$(rows_of "$vd")" "$out"
        return 1
    fi
    if ! t_contains "$d" "recorded no deploy"; then
        printf 'the row does not say the run recorded no deploy: %s\n' "$d"; return 1
    fi
    if grep -qE $'\tPASS\t' "$vd/verdicts.tsv"; then
        printf 'a run with no record has a PASS row in it:\n%s\n' "$(rows_of "$vd")"; return 1
    fi
    [ "$rc" = 2 ] && return 0
    printf 'exit %s, not 2. CONTRACT.md 10: 1 is "we looked", 2 is "we could not look".\n' "$rc"
    return 1
}

## zero_bytes_is_named <toolkit>
zero_bytes_is_named() {
    local dir="$1" vd out rc v d
    vd="$(vd_new)"; : > "$vd/deploy_manifest.txt"
    out="$(grade "$dir" "$vd" --manifest "$vd/deploy_manifest.txt")"; rc="$(exit_of "$out")"
    v="$(verdicts_of "$vd" deploy.preflight)"; d="$(detail_of "$vd" deploy.preflight)"
    [ "$v" = "UNVERIFIED" ] || { printf 'zero bytes, and deploy.preflight is "%s":\n%s\n' "${v:-<no row>}" "$out"; return 1; }
    if ! t_contains "$d" "ZERO BYTES"; then
        printf 'a ZERO-BYTE manifest was not named as such - it was reported as: %s\n' "$d"
        printf 'Absent means the driver never got there; zero bytes means it got there and died.\n'
        return 1
    fi
    [ "$rc" = 2 ] && return 0
    printf 'exit %s, not 2\n' "$rc"; return 1
}

## nothing_named_is_refused_unrecorded <toolkit>
## No --manifest and no run directory in the environment: exit 2 and NO verdict
## file, because nothing was located, so nothing was measured or recorded.
nothing_named_is_refused_unrecorded() {
    local dir="$1" vd out rc
    vd="$(vd_new)"
    out="$(grade "$dir" "$vd")"; rc="$(exit_of "$out")"
    [ "$rc" = 2 ] || { printf 'exit %s, not 2:\n%s\n' "$rc" "$out"; return 1; }
    if [ -e "$vd/verdicts.tsv" ]; then
        printf 'nothing was named and a verdict file was still written:\n%s\n' "$(rows_of "$vd")"; return 1
    fi
    t_contains "$out" "no manifest named" && return 0
    printf 'the refusal does not say what was missing:\n%s\n' "$out"; return 1
}

t_check deploy.absent.recorded "no manifest: exit 2, one UNVERIFIED deploy.preflight row saying so, no PASS anywhere" \
    absent_is_refused_and_recorded "$FLOW_DIR"
t_check deploy.absent.zero_bytes "a zero-byte manifest: exit 2 and an UNVERIFIED row that says ZERO BYTES, not absent" \
    zero_bytes_is_named "$FLOW_DIR"
t_check deploy.absent.nothing_named "no --manifest and no FPGA_REPORT_DIR: exit 2 and no verdict file at all" \
    nothing_named_is_refused_unrecorded "$FLOW_DIR"

# -- proofs -------------------------------------------------------------------
# The absent-branch emitter shares its first line with the zero-byte one, so
# the edit is addressed by the sentence on the line after it.
M_BLIND="$(t_mutant "$SB" absent-is-skip)"
if t_mutate "$M_BLIND" ci/deploy-gates.sh '/^        ci_unverified deploy.preflight \\$/{N;/this run recorded no deploy/s/ci_unverified/ci_skip/}'; then
    t_check_fail deploy.absent.recorded.mutation.skip \
        "with the absent record recorded as a SKIP (exit still 2), the assertion goes red" \
        absent_is_refused_and_recorded "$M_BLIND"
else
    t_skip deploy.absent.recorded.mutation.skip "could not plant the fault: the absent-manifest ci_unverified has changed shape"
    M_BLIND=""
fi

M="$(t_mutant "$SB" absent-exit-1)"
if t_mutate "$M" ci/deploy-gates.sh '/refusing to grade a deploy that left no record/{n;s/exit 2/exit 1/}'; then
    t_check_fail deploy.absent.recorded.mutation.exit1 \
        "with the refusal exiting 1 - 'we looked' for a run that left nothing to look at - the assertion goes red" \
        absent_is_refused_and_recorded "$M"
else
    t_skip deploy.absent.recorded.mutation.exit1 "could not plant the fault: the 'exit 2' after the refusal message has moved"
fi

M="$(t_mutant "$SB" zero-collapsed-to-absent)"
if t_replace_line "$M" ci/deploy-gates.sh '    if [ -e "$MANIFEST" ]; then' '    if false; then'; then
    t_check_fail deploy.absent.zero_bytes.mutation \
        "with the two branches collapsed a zero-byte manifest is reported as absent, so the assertion goes red" \
        zero_bytes_is_named "$M"
else
    t_skip deploy.absent.zero_bytes.mutation "could not plant the fault: the -e test that tells zero bytes from absent has changed shape"
fi

M="$(t_mutant "$SB" nothing-named-exit-0)"
if t_mutate "$M" ci/deploy-gates.sh '/no manifest named and no FPGA_REPORT_DIR/,/^fi$/ s/exit 2/exit 0/'; then
    t_check_fail deploy.absent.nothing_named.mutation \
        "with the no-manifest refusal exiting 0, a gate that located nothing reports success and the assertion goes red" \
        nothing_named_is_refused_unrecorded "$M"
else
    t_skip deploy.absent.nothing_named.mutation "could not plant the fault: the no-manifest refusal block has changed shape"
fi

# -- the selftest's blind spot, as a known defect ------------------------------
# The selftest's absent-record case asserts `rc = 2` and nothing about the
# verdict file. So the copy above, which records a SKIP where the header
# promises an UNVERIFIED, PASSES ITS OWN SELFTEST. This marker goes red the day
# the selftest starts reading the row - which is the day to delete it.
## selftest_rejects <toolkit> - 0 when that copy's --selftest exits NON-zero
selftest_rejects() {
    local dir="$1" rc=0
    "${GATE_ENV[@]}" bash "$dir/ci/deploy-gates.sh" --selftest >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ]
}
if [ -n "$M_BLIND" ]; then
    t_known_defect deploy.selftest.blind.absent_verdict \
        "the selftest catches an absent record recorded as SKIP instead of UNVERIFIED (today it checks exit 2 alone, and passes)" \
        selftest_rejects "$M_BLIND"
else
    t_skip deploy.selftest.blind.absent_verdict "the absent-is-skip copy could not be built (see the skipped proof above)"
fi

#=============================================================================
# 6. A HEALTHY DRY RUN IS GREEN
#
# The dry-run fixture carries the values the driver writes at DEPLOY_EXECUTE=0:
# acquired=no, held_at_program=no, program.attempted=no, no release.result.
# On an executed run every one of those is red. The mode has to be read
# FIRST, in every gate but preflight, or a correct dry run fails for the
# absence of a record of a thing that correctly did not happen.
#=============================================================================
t_head "a dry run: preflight graded, five SKIPs each with a reason, exit 0"

## dry_run_is_green <toolkit> <manifest>
dry_run_is_green() {
    local dir="$1" mf="$2" vd out rc got want id d first
    vd="$(vd_new)"
    out="$(grade "$dir" "$vd" --manifest "$mf")"; rc="$(exit_of "$out")"
    first="${IDS%% *}"
    got="$(ladder_rows "$vd")"; want="$(ladder_expect SKIP "$first=PASS")"
    if [ "$got" != "$want" ]; then
        printf 'GOT:\n%s\nWANT:\n%s\n' "$got" "$want"
        printf 'A dry run that grades red is a gate people learn to ignore.\n'
        return 1
    fi
    for id in $IDS; do
        [ "$id" = "$first" ] && continue
        d="$(detail_of "$vd" "$id")"
        [ -n "$d" ] || { printf '%s skipped with NO REASON\n' "$id"; return 1; }
    done
    [ "$rc" = 0 ] && return 0
    printf 'five skips, one pass, exit %s\n' "$rc"; return 1
}

t_check deploy.dryrun.green \
    "the dry-run fixture: preflight PASS, the other $((N_IDS - 1)) SKIP with reasons, exit 0" \
    dry_run_is_green "$FLOW_DIR" "$FIX_DRY"

M="$(t_mutant "$SB" lease-ignores-mode)"
if t_replace_line "$M" ci/deploy-gates.sh '    if [ "$(mf deploy.mode)" = "dry-run" ]; then' '    if false; then'; then
    t_check_fail deploy.dryrun.green.mutation.lease \
        "with the lease gate no longer reading the mode, held_at_program=no is an unheld board and the assertion goes red" \
        dry_run_is_green "$M" "$FIX_DRY"
else
    t_skip deploy.dryrun.green.mutation.lease "could not plant the fault: gate_lease's dry-run test has changed shape"
fi

M="$(t_mutant "$SB" verify-dryrun-unverified)"
if t_replace_line "$M" ci/deploy-gates.sh \
        '        ci_skip deploy.verify "DEPLOY_EXECUTE=0, so no device was configured and there is no DONE pin to read"' \
        '        ci_unverified deploy.verify "DEPLOY_EXECUTE=0, so no device was configured and there is no DONE pin to read"'; then
    t_check_fail deploy.dryrun.green.mutation.verify \
        "with verify's dry-run skip turned into UNVERIFIED (a case the selftest does not cover), the assertion goes red" \
        dry_run_is_green "$M" "$FIX_DRY"
else
    t_skip deploy.dryrun.green.mutation.verify "could not plant the fault: gate_verify's dry-run ci_skip line has changed shape"
fi

#=============================================================================
# 7. THE WARNINGS THE FILE PROMISES
#
# Three findings the gate says it reports and does not fail on: a group named
# the same as its target (the KR260 group contains a target of its own name,
# so it is a warning - docs/DEPLOY.md section 1), a holder string that names
# nobody, and a TTL longer than an hour. Each must appear as a WARN row with
# its own sub-id, leave the gate it decorates PASS, and leave the exit 0.
#=============================================================================
t_head "the promised warnings are recorded as WARN, and are not red"

## warned <toolkit> <manifest> <warn id> <gate id>
warned() {
    local dir="$1" mf="$2" wid="$3" gid="$4" vd out rc
    vd="$(vd_new)"
    out="$(grade "$dir" "$vd" --manifest "$mf")"; rc="$(exit_of "$out")"
    [ "$(verdicts_of "$vd" "$wid")" = "WARN" ] || {
        printf 'no WARN row for %s:\n%s\n' "$wid" "$(rows_of "$vd")"; return 1; }
    [ "$(verdicts_of "$vd" "$gid")" = "PASS" ] || {
        printf '%s is "%s", not PASS - the warning turned the gate red\n' "$gid" "$(verdicts_of "$vd" "$gid")"; return 1; }
    [ "$rc" = 0 ] && return 0
    printf 'a warning and exit %s - warnings never fail a run (CONTRACT.md 7)\n' "$rc"; return 1
}

MF_NS="$(faulted "$FIX" 's|^deploy.target .*|deploy.target demo_group|')" || t_fail deploy.fixture.plant "namespace fault did not plant"
MF_HOLDER="$(faulted "$FIX" 's|^deploy.lease.holder .*|deploy.lease.holder demo-host|')" || t_fail deploy.fixture.plant "holder fault did not plant"
MF_TTL="$(faulted "$FIX" 's|^deploy.lease.ttl_s .*|deploy.lease.ttl_s 7200|')" || t_fail deploy.fixture.plant "ttl fault did not plant"

t_check deploy.warn.namespace "group == target is a deploy.preflight.namespace WARN, and preflight still passes" \
    warned "$FLOW_DIR" "$MF_NS" deploy.preflight.namespace deploy.preflight
t_check deploy.warn.holder "a holder that does not name this toolkit is a deploy.lease.holder WARN, and lease still passes" \
    warned "$FLOW_DIR" "$MF_HOLDER" deploy.lease.holder deploy.lease
t_check deploy.warn.ttl "a TTL over an hour is a deploy.lease.ttl WARN - the only thing that frees a crashed run's board" \
    warned "$FLOW_DIR" "$MF_TTL" deploy.lease.ttl deploy.lease

M="$(t_mutant "$SB" namespace-is-fail)"
if plant "$M" ci/deploy-gates.sh 's#ci_warn deploy.preflight.namespace#ci_fail deploy.preflight.namespace#'; then
    t_check_fail deploy.warn.namespace.mutation \
        "with the namespace warning promoted to a failure, a KR260-shaped group/target pair is red and the assertion goes red" \
        warned "$M" "$MF_NS" deploy.preflight.namespace deploy.preflight
else
    t_skip deploy.warn.namespace.mutation "could not plant the fault, or the planted copy stopped parsing: gate_lease's namespace ci_warn has changed shape - see the harness line above"
fi

M="$(t_mutant "$SB" holder-never-warns)"
if t_replace_line "$M" ci/deploy-gates.sh '        *fpga-flow*) ;;' '        *) ;;'; then
    t_check_fail deploy.warn.holder.mutation \
        "with every holder accepted as distinctive, no WARN is recorded and the assertion goes red" \
        warned "$M" "$MF_HOLDER" deploy.lease.holder deploy.lease
else
    t_skip deploy.warn.holder.mutation "could not plant the fault: the holder case arm has changed shape"
fi

M="$(t_mutant "$SB" ttl-never-warns)"
if t_replace_line "$M" ci/deploy-gates.sh \
        '    if ci_is_measured "$ttl" && [ "$ttl" -gt 3600 ] 2>/dev/null; then' \
        '    if ci_is_measured "$ttl" && [ "$ttl" -gt 999999999 ] 2>/dev/null; then'; then
    t_check_fail deploy.warn.ttl.mutation \
        "with the TTL threshold raised past any real value, no WARN is recorded and the assertion goes red" \
        warned "$M" "$MF_TTL" deploy.lease.ttl deploy.lease
else
    t_skip deploy.warn.ttl.mutation "could not plant the fault: the TTL threshold line has changed shape"
fi

#=============================================================================
# 8. THE GATE FILE - CONTRACT.md section 5's fixed section structure
#
# `HARD FAILURES: none` is the exact string mk/flow.mk greps for on the impl
# gate (mk/flow.mk, the `^HARD FAILURES: none` line under bitstream), so it is
# asserted anchored at both ends, as t_provenance.sh asserts it. The four
# verdict classes are the honesty mechanism: a green run still enumerates
# what it did not measure, and on a deploy that is most of what anybody wants.
#=============================================================================
t_head "--gate-file: the section-5 artefact, and what it lists under HARD FAILURES and NOT covered"

## gatefile_clean <toolkit> <manifest>
gatefile_clean() {
    local dir="$1" mf="$2" vd out g want2
    vd="$(vd_new)"; g="$vd/deploy_gate.txt"
    out="$(grade "$dir" "$vd" --manifest "$mf" --gate-file "$g")"
    [ -s "$g" ] || { printf 'no gate file was written at %s:\n%s\n' "$g" "$out"; return 1; }
    sed -n 1p "$g" | grep -qE '^DEPLOY gate, [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' || {
        printf 'line 1 is not "DEPLOY gate, <ISO8601 UTC>": %s\n' "$(sed -n 1p "$g")"; return 1; }
    want2="design $(mfval "$mf" block), run tag $(mfval "$mf" run_tag), board group $(mfval "$mf" deploy.board_group), target $(mfval "$mf" deploy.target)"
    [ "$(sed -n 2p "$g")" = "$want2" ] || {
        printf 'line 2 does not name the design, run, group and target FROM THE MANIFEST:\n  got  %s\n  want %s\n' "$(sed -n 2p "$g")" "$want2"; return 1; }
    grep -qE '^HARD FAILURES: none$' "$g" || {
        printf 'a clean run does not carry "HARD FAILURES: none" exactly. The gate file has:\n%s\n' "$(grep -n 'HARD FAILURES' "$g")"; return 1; }
    grep -q '^DECLARED ELSEWHERE - MEASURED HERE, OWNED BY SOMEBODY ELSE' "$g" || { echo 'no DECLARED ELSEWHERE section'; return 1; }
    grep -q '^NOT covered by ANY run of this flow, at any setting:' "$g" || { echo 'no NOT covered section'; return 1; }
    return 0
}

## gatefile_red <toolkit> <manifest> <gate id that must be listed>
## The failing gate is listed under HARD FAILURES by id, and "none" is gone.
gatefile_red() {
    local dir="$1" mf="$2" id="$3" vd g
    vd="$(vd_new)"; g="$vd/deploy_gate.txt"
    grade "$dir" "$vd" --manifest "$mf" --gate-file "$g" >/dev/null
    [ -s "$g" ] || { echo 'no gate file was written'; return 1; }
    if grep -qE '^HARD FAILURES: none' "$g"; then
        printf 'A RUN WITH A RED GATE STILL SAYS "HARD FAILURES: none" - the string make greps for:\n%s\n' "$(rows_of "$vd")"
        return 1
    fi
    grep -qE "^  - $id: " "$g" && return 0
    printf '%s is red in verdicts.tsv and is not listed under HARD FAILURES:\n%s\n' "$id" "$(sed -n '/^HARD FAILURES/,/^$/p' "$g")"
    return 1
}

## gatefile_lists_skips <toolkit> <manifest> - every SKIP row is under NOT covered
gatefile_lists_skips() {
    local dir="$1" mf="$2" vd g id
    vd="$(vd_new)"; g="$vd/deploy_gate.txt"
    grade "$dir" "$vd" --manifest "$mf" --gate-file "$g" >/dev/null
    [ -s "$g" ] || { echo 'no gate file was written'; return 1; }
    for id in $(awk -F'\t' '$2 == "SKIP" { print $3 }' "$vd/verdicts.tsv"); do
        sed -n '/^NOT covered/,$p' "$g" | grep -qE "^  - $id: " && continue
        printf '%s was SKIPPED and is not enumerated under "NOT covered":\n%s\n' "$id" "$(sed -n '/^NOT covered/,$p' "$g")"
        return 1
    done
    return 0
}

## summary_table <toolkit> <manifest> - --summary renders one row per gate
summary_table() {
    local dir="$1" mf="$2" vd id s
    vd="$(vd_new)"; s="$vd/summary.md"
    "${GATE_ENV[@]}" CI_VERDICT_DIR="$vd" CI_SUMMARY_FILE="$s" \
        bash "$dir/ci/deploy-gates.sh" --manifest "$mf" --summary >/dev/null 2>&1
    [ -s "$s" ] || { echo '--summary wrote nothing to CI_SUMMARY_FILE'; return 1; }
    for id in $IDS; do
        grep -qF "| \`$id\` |" "$s" && continue
        printf 'no table row for %s in:\n%s\n' "$id" "$(cat "$s")"; return 1
    done
    return 0
}

t_check deploy.gatefile.clean \
    "a clean run's gate file: the header from the manifest, 'HARD FAILURES: none' exactly, the two honesty sections" \
    gatefile_clean "$FLOW_DIR" "$FIX"
t_check deploy.gatefile.fail_listed \
    "a FAIL is listed under HARD FAILURES by gate id, and 'none' is gone" \
    gatefile_red "$FLOW_DIR" "$MF_VERIFY" deploy.verify
t_check deploy.gatefile.unverified_is_hard \
    "an UNVERIFIED is a hard failure in the artefact too, listed by id" \
    gatefile_red "$FLOW_DIR" "$MF_HELD_U" deploy.lease
t_check deploy.gatefile.skips_enumerated \
    "every SKIP of a dry run is enumerated under 'NOT covered' - a green run says what it did not measure" \
    gatefile_lists_skips "$FLOW_DIR" "$FIX_DRY"
t_check deploy.summary.table \
    "--summary renders a markdown table with one row per gate id into CI_SUMMARY_FILE" \
    summary_table "$FLOW_DIR" "$FIX"

M="$(t_mutant "$SB" gatefile-none-misspelt)"
if t_replace_line "$M" ci/deploy-gates.sh "            printf 'HARD FAILURES: none\\n'" "            printf 'HARD FAILURES:  none\\n'"; then
    t_check_fail deploy.gatefile.clean.mutation \
        "with the exact string broken by one space, the anchored grep fails and the assertion goes red" \
        gatefile_clean "$M" "$FIX"
else
    t_skip deploy.gatefile.clean.mutation "could not plant the fault: the 'HARD FAILURES: none' printf has changed shape"
fi

M="$(t_mutant "$SB" gatefile-never-red)"
if plant "$M" ci/deploy-gates.sh 's#\$2=="FAIL" || \$2=="UNVERIFIED" { found=1 }#$2=="NEVER" { found=1 }#'; then
    t_check_fail deploy.gatefile.fail_listed.mutation \
        "with the hard-failure test looking for a verdict that does not exist, a red run says 'none' and the assertion goes red" \
        gatefile_red "$M" "$MF_VERIFY" deploy.verify
else
    t_skip deploy.gatefile.fail_listed.mutation "could not plant the fault, or the planted copy stopped parsing: the gate file's hard-failure awk has changed shape - see the harness line above"
fi

M="$(t_mutant "$SB" gatefile-unverified-soft)"
if plant "$M" ci/deploy-gates.sh 's#\$2=="FAIL" || \$2=="UNVERIFIED" { printf#$2=="FAIL" { printf#'; then
    t_check_fail deploy.gatefile.unverified_is_hard.mutation \
        "with UNVERIFIED dropped from the listing, the unmeasured gate vanishes from the artefact and the assertion goes red" \
        gatefile_red "$M" "$MF_HELD_U" deploy.lease
else
    t_skip deploy.gatefile.unverified_is_hard.mutation "could not plant the fault, or the planted copy stopped parsing: the gate file's hard-failure listing awk has changed shape - see the harness line above"
fi

M="$(t_mutant "$SB" gatefile-skips-unlisted)"
if plant "$M" ci/deploy-gates.sh 's#\$2=="SKIP" { printf#$2=="NEVER" { printf#'; then
    t_check_fail deploy.gatefile.skips_enumerated.mutation \
        "with the SKIP listing looking for a verdict that does not exist, the not-covered list is silent and the assertion goes red" \
        gatefile_lists_skips "$M" "$FIX_DRY"
else
    t_skip deploy.gatefile.skips_enumerated.mutation "could not plant the fault, or the planted copy stopped parsing: the gate file's SKIP listing awk has changed shape - see the harness line above"
fi

M="$(t_mutant "$SB" summary-ignored)"
if t_replace_line "$M" ci/deploy-gates.sh '[ "$WANT_SUMMARY" = "1" ] && ci_summary_table "deploy gates"' '[ "$WANT_SUMMARY" = "9" ] && ci_summary_table "deploy gates"'; then
    t_check_fail deploy.summary.table.mutation \
        "with --summary parsed and never acted on, no table is written and the assertion goes red" \
        summary_table "$M" "$FIX"
else
    t_skip deploy.summary.table.mutation "could not plant the fault: the --summary dispatch line has changed shape"
fi

#=============================================================================
# 9. ARGUMENTS
#
# ci/README.md's exit table: 2 is "refused: unusable input". An unknown
# argument must be refused with NOTHING recorded - the alternative, ignoring
# it and grading whatever the environment points at, is a green run of the
# wrong record. --manifest must beat FPGA_REPORT_DIR, or `make deploy` grades
# the run directory while the caller believes it graded the file it named.
#
# AND THE MISSING-OPERAND SPIN. `--manifest) MANIFEST="${2:-}"; shift 2` with
# nothing after --manifest: `shift 2` fails with one argument left and shifts
# nothing, the loop sees --manifest again, forever. ci/tier.sh,
# ci/assert-stage.sh and ci/capability.sh were each cured of this on
# 2026-09-14 with a need_operand guard; this file was not. The timeout IS the
# assertion: a spin shows as 124, which is neither the 2 it owes nor a pass.
#=============================================================================
t_head "arguments: unknown is refused unrecorded, --manifest beats the environment, and the operand spin"

## unknown_arg_refused <toolkit>
## FPGA_REPORT_DIR points at a real, clean run directory on purpose: a gate
## that ignored the bad argument would then find a manifest and grade it green.
unknown_arg_refused() {
    local dir="$1" vd rd out rc
    vd="$(vd_new)"; rd="$vd/reports"; mkdir -p "$rd"; cp "$FIX" "$rd/deploy_manifest.txt"
    out="$("${GATE_ENV[@]}" FPGA_REPORT_DIR="$rd" CI_VERDICT_DIR="$vd" bash "$dir/ci/deploy-gates.sh" --no-such-option 2>&1)" || rc=$?
    rc="${rc:-0}"
    [ "$rc" = 2 ] || { printf 'exit %s, not 2 - an unusable argument was not refused:\n%s\n' "$rc" "$out"; return 1; }
    if [ -e "$vd/verdicts.tsv" ]; then
        printf 'a REFUSED invocation still wrote a verdict file, so something was graded:\n%s\n' "$(rows_of "$vd")"; return 1
    fi
    t_contains "$out" "unknown argument" && return 0
    printf 'the refusal does not name the argument:\n%s\n' "$out"; return 1
}

## manifest_beats_env <toolkit>
## The environment names a FAILING run; --manifest names the clean fixture.
manifest_beats_env() {
    local dir="$1" vd rd out rc
    vd="$(vd_new)"; rd="$vd/reports"; mkdir -p "$rd"; cp "$MF_VERIFY" "$rd/deploy_manifest.txt"
    out="$("${GATE_ENV[@]}" FPGA_REPORT_DIR="$rd" CI_VERDICT_DIR="$vd" bash "$dir/ci/deploy-gates.sh" --manifest "$FIX" 2>&1)" || rc=$?
    rc="${rc:-0}"
    if [ "$(ladder_rows "$vd")" != "$(ladder_expect PASS)" ]; then
        printf '--manifest named the clean fixture and the run directory was graded instead:\n%s\n' "$(rows_of "$vd")"
        return 1
    fi
    [ "$rc" = 0 ] && return 0
    printf 'the clean fixture was graded and the exit is %s\n' "$rc"; return 1
}

## operand_refused <toolkit> <option> - 0 iff the bare option exits 2 within 5s
operand_refused() {
    local dir="$1" opt="$2" rc=0
    timeout 5 "${GATE_ENV[@]}" CI_VERDICT_DIR="$(vd_new)" bash "$dir/ci/deploy-gates.sh" "$opt" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 2 ] && return 0
    [ "$rc" = 124 ] && { printf '%s with no operand had not terminated after 5 seconds - the argv loop is spinning\n' "$opt"; return 1; }
    printf 'exit %s, not 2\n' "$rc"; return 1
}

t_check deploy.argv.unknown "an unknown argument is refused with exit 2, named, and NO verdict file - even with a clean run directory in the environment" \
    unknown_arg_refused "$FLOW_DIR"
t_check deploy.argv.manifest_wins "--manifest is graded in preference to FPGA_REPORT_DIR" \
    manifest_beats_env "$FLOW_DIR"

if command -v timeout >/dev/null 2>&1; then
    t_known_defect deploy.argv.missing_operand.manifest \
        "--manifest with no operand is refused (exit 2) instead of spinning the argument loop" \
        operand_refused "$FLOW_DIR" --manifest
    t_known_defect deploy.argv.missing_operand.gate_file \
        "--gate-file with no operand is refused (exit 2) instead of spinning the argument loop" \
        operand_refused "$FLOW_DIR" --gate-file
else
    t_skip deploy.argv.missing_operand.manifest "no coreutils timeout on this host, and the case under test is a loop that does not terminate"
    t_skip deploy.argv.missing_operand.gate_file "no coreutils timeout on this host, and the case under test is a loop that does not terminate"
fi

M="$(t_mutant "$SB" argv-unknown-ignored)"
if t_replace_line "$M" ci/deploy-gates.sh \
        "        *) echo \"deploy-gates: unknown argument '\$1'\" >&2; usage >&2; exit 2 ;;" \
        '        *) shift ;;'; then
    t_check_fail deploy.argv.unknown.mutation \
        "with unknown arguments silently dropped, the run directory is graded green and the assertion goes red" \
        unknown_arg_refused "$M"
else
    t_skip deploy.argv.unknown.mutation "could not plant the fault: the unknown-argument arm has changed shape"
fi

M="$(t_mutant "$SB" argv-env-wins)"
if t_mutate "$M" ci/deploy-gates.sh '/^# LOCATE THE RECORD/,/^fi$/ s/^if \[ -z "\$MANIFEST" \]; then$/if true; then/'; then
    t_check_fail deploy.argv.manifest_wins.mutation \
        "with the environment consulted even when --manifest was given, the wrong record is graded and the assertion goes red" \
        manifest_beats_env "$M"
else
    t_skip deploy.argv.manifest_wins.mutation "could not plant the fault: the LOCATE THE RECORD block has changed shape"
fi

#=============================================================================
# 10. MAKE AGREES ABOUT THE NAMES
#
# The manifest lands where mk/deploy.mk says (`DEPLOY_MANIFEST`), the driver
# writes it there and hands the gate `DEPLOY_GATE`, and the gate looks for it
# under FPGA_REPORT_DIR - which mk/flow.mk exports from REPORT_DIR. Three
# files spelling one basename. The value is ASKED OF MAKE, never read out of
# the makefile, because a `?=` chain and a `$(if $(strip ...))` guard are
# exactly the things a grep of the makefile gets wrong.
#=============================================================================
t_head "make, the driver and the gate spell the manifest and gate-file names the same way"

MAKE_ENV=(env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u FPGA_FLOW_DIR -u FPGA_ENGINE_DIR)

## make_var <toolkit> <VAR> - that variable as mk/deploy.mk resolves it standalone
make_var() {
    "${MAKE_ENV[@]}" make -s -f "$1/mk/deploy.mk" --eval="t_probe: ; @echo \$($2)" t_probe \
        REPORT_DIR=/probe LOG_DIR=/probe 2>/dev/null
}
## make_run <toolkit> <target...> - run mk/deploy.mk standalone, print output + EXIT
make_run() {
    local dir="$1"; shift
    local rc=0 out
    out="$("${MAKE_ENV[@]}" make -f "$dir/mk/deploy.mk" "$@" 2>&1)" || rc=$?
    printf '%s\nEXIT=%d\n' "$out" "$rc"
}

MF_NAME="$(basename "$(make_var "$FLOW_DIR" DEPLOY_MANIFEST)")"
GF_NAME="$(basename "$(make_var "$FLOW_DIR" DEPLOY_GATE)")"
t_say "make says: manifest '$MF_NAME', gate file '$GF_NAME'"

## gate_finds_make_manifest <toolkit>
## The clean fixture under make's basename in a run directory, the gate told
## only FPGA_REPORT_DIR: six PASS rows, or the gate looked for a different name.
gate_finds_make_manifest() {
    local dir="$1" vd rd out rc name
    name="$(basename "$(make_var "$dir" DEPLOY_MANIFEST)")"
    [ -n "$name" ] && [ "$name" != "/" ] || { echo 'make resolved no DEPLOY_MANIFEST'; return 1; }
    vd="$(vd_new)"; rd="$vd/reports"; mkdir -p "$rd"; cp "$FIX" "$rd/$name"
    out="$("${GATE_ENV[@]}" FPGA_REPORT_DIR="$rd" CI_VERDICT_DIR="$vd" bash "$dir/ci/deploy-gates.sh" 2>&1)" || rc=$?
    rc="${rc:-0}"
    [ "$(ladder_rows "$vd")" = "$(ladder_expect PASS)" ] && [ "$rc" = 0 ] && return 0
    printf 'make names the manifest %s; given FPGA_REPORT_DIR the gate did not grade it (exit %s):\n%s\n%s\n' \
        "$name" "$rc" "$(rows_of "$vd")" "$out"
    return 1
}

## driver_spells_like_make <toolkit>
## Every "$REPORT_DIR/<file>" the driver composes is one of make's two
## basenames, and each of the two appears at least once.
driver_spells_like_make() {
    local dir="$1" mf gf spelled s seen_mf=0 seen_gf=0
    mf="$(basename "$(make_var "$dir" DEPLOY_MANIFEST)")"; gf="$(basename "$(make_var "$dir" DEPLOY_GATE)")"
    spelled="$(grep -oE '"\$REPORT_DIR/[A-Za-z0-9_.-]+"' "$dir/scripts/fpga-flow-deploy" | sed 's|^"\$REPORT_DIR/||; s|"$||' | sort -u)"
    [ -n "$spelled" ] || { echo 'the driver composes no "$REPORT_DIR/<file>" path at all'; return 1; }
    for s in $spelled; do
        case "$s" in
            "$mf") seen_mf=1 ;;
            "$gf") seen_gf=1 ;;
            *) printf 'the driver writes "$REPORT_DIR/%s"; make knows only %s and %s. The banner in\n' "$s" "$mf" "$gf"
               printf 'mk/deploy.mk sends a reader to the path MAKE resolves, and nothing is there.\n'; return 1 ;;
        esac
    done
    [ "$seen_mf" = 1 ] || { printf 'the driver never composes the manifest as "$REPORT_DIR/%s"\n' "$mf"; return 1; }
    [ "$seen_gf" = 1 ] || { printf 'the driver never composes the gate file as "$REPORT_DIR/%s"\n' "$gf"; return 1; }
    return 0
}

## broken_checkout_says_so <toolkit copy WITHOUT ci/deploy-gates.sh>
broken_checkout_says_so() {
    local out rc
    out="$(make_run "$1" deploy-selftest)"; rc="$(exit_of "$out")"
    [ "$rc" = 2 ] || { printf 'exit %s, not 2. A missing gate script is a BROKEN CHECKOUT and must say so:\n%s\n' "$rc" "$out"; return 1; }
    t_contains "$out" "missing or not executable" || { printf 'the refusal does not name the missing file:\n%s\n' "$out"; return 1; }
    t_contains "$out" "record no verdict" || { printf 'the refusal does not say why it matters:\n%s\n' "$out"; return 1; }
    return 0
}

t_check deploy.make.manifest_found \
    "given only FPGA_REPORT_DIR, the gate finds the manifest under the basename make resolves for DEPLOY_MANIFEST" \
    gate_finds_make_manifest "$FLOW_DIR"
t_check deploy.make.driver_spelling \
    "every \$REPORT_DIR path the driver composes is make's DEPLOY_MANIFEST or DEPLOY_GATE basename, and both occur" \
    driver_spells_like_make "$FLOW_DIR"

M_NOGATE="$(t_mutant "$SB" checkout-without-gate)"
if [ -n "$M_NOGATE" ] && rm -f "$M_NOGATE/ci/deploy-gates.sh"; then
    t_check deploy.make.broken_checkout \
        "a checkout with no ci/deploy-gates.sh is refused by make deploy-selftest: exit 2, the file named, the consequence stated" \
        broken_checkout_says_so "$M_NOGATE"
else
    t_skip deploy.make.broken_checkout "could not build a copy without the gate script"
fi

M="$(t_mutant "$SB" gate-looks-elsewhere)"
if t_mutate "$M" ci/deploy-gates.sh 's|"\$FPGA_REPORT_DIR/deploy_manifest\.txt"|"$FPGA_REPORT_DIR/deploy-manifest.txt"|'; then
    t_check_fail deploy.make.manifest_found.mutation \
        "with the gate looking for a differently-spelt file under FPGA_REPORT_DIR, it finds nothing and the assertion goes red" \
        gate_finds_make_manifest "$M"
else
    t_skip deploy.make.manifest_found.mutation "could not plant the fault: the gate no longer composes \$FPGA_REPORT_DIR/deploy_manifest.txt"
fi

M="$(t_mutant "$SB" driver-spells-differently)"
if plant "$M" scripts/fpga-flow-deploy 's#--manifest "\$REPORT_DIR/deploy_manifest.txt"#--manifest "$REPORT_DIR/deploy-manifest.txt"#'; then
    t_check_fail deploy.make.driver_spelling.mutation \
        "with the driver handing the gate a name make does not know, the assertion goes red" \
        driver_spells_like_make "$M"
else
    t_skip deploy.make.driver_spelling.mutation "could not plant the fault, or the planted copy stopped parsing: the driver's --manifest line has changed shape - see the harness line above"
fi

# The proof copy carries the missing file AND the neutered guard: the removal
# is the case under test, the guard is the planted fault. Without the guard
# make runs the recipe, /bin/sh cannot find the script, and the exit is 127 -
# "command not found", which reads as a PATH problem in the project.
M="$(t_mutant "$SB" checkout-without-gate-unguarded)"
if [ -n "$M" ] && rm -f "$M/ci/deploy-gates.sh" \
   && plant "$M" mk/deploy.mk 's#@test -x \$(DEPLOY_GATES)#@true#'; then
    t_check_fail deploy.make.broken_checkout.mutation \
        "with the presence guard neutered, the missing script surfaces as exit 127 from /bin/sh and the assertion goes red" \
        broken_checkout_says_so "$M"
else
    t_skip deploy.make.broken_checkout.mutation "could not plant the fault, or the planted copy stopped parsing: mk/deploy.mk's 'test -x \$(DEPLOY_GATES)' guard has changed shape - see the harness line above"
fi

#=============================================================================
# 11. --selftest IS HONEST
#
# Driven through `make deploy-selftest`, which is what a person types. The
# assertion: it passes, and the "N of N" it prints is the number of cases the
# file carries (37 case_is calls plus the two hand-rolled absent-record cases,
# counted out of the file rather than written here). The proofs plant, each in
# its own copy, a fault the selftest CLAIMS to catch, and require the make
# target on that copy to go red. A selftest that stayed green on any of them
# would be a claim the file makes about itself that is not true.
#=============================================================================
t_head "make deploy-selftest passes, counts its own cases, and goes red on the faults it claims to catch"

## selftest_passes <toolkit>
selftest_passes() {
    local dir="$1" out rc claimed cases
    out="$(make_run "$dir" deploy-selftest)"; rc="$(exit_of "$out")"
    [ "$rc" = 0 ] || { printf 'make deploy-selftest exited %s:\n%s\n' "$rc" "$(printf '%s\n' "$out" | grep -E '^FAIL|of .* selftest|EXIT')"; return 1; }
    if printf '%s\n' "$out" | grep -qE '^FAIL'; then
        printf 'exit 0 with a FAIL line in it:\n%s\n' "$(printf '%s\n' "$out" | grep -E '^FAIL')"; return 1
    fi
    claimed="$(printf '%s\n' "$out" | sed -n 's/^\([0-9][0-9]*\) of \1: every gate goes red.*/\1/p')"
    [ -n "$claimed" ] || { printf 'no "N of N: every gate goes red" line:\n%s\n' "$out"; return 1; }
    cases=$(( $(grep -cE '^    case_is ' "$dir/ci/deploy-gates.sh") + $(grep -cE '^    n=\$\(\(n \+ 1\)\)$' "$dir/ci/deploy-gates.sh") ))
    [ "$claimed" = "$cases" ] && return 0
    printf 'the selftest claims %s cases; the file carries %s\n' "$claimed" "$cases"; return 1
}

## selftest_fails <toolkit> - the proof predicate: make deploy-selftest exits NON-zero and says FAIL
selftest_fails() {
    local out rc
    out="$(make_run "$1" deploy-selftest)"; rc="$(exit_of "$out")"
    [ "$rc" -ne 0 ] || return 1
    printf '%s\n' "$out" | grep -qE '^FAIL' || return 1
    return 0
}

t_check deploy.selftest.passes \
    "make deploy-selftest exits 0 with no FAIL line, and its N of N equals the cases the file carries" \
    selftest_passes "$FLOW_DIR"

# The proofs read backwards from the way the others do: t_check, not
# t_check_fail, because the predicate IS "the selftest went red". Each still
# carries `.mutation` in its id, because each is a planted fault the ledger
# must count.
M="$(t_mutant "$SB" selftest-truthy-always)"
if t_replace_line "$M" ci/deploy-gates.sh \
        'truthy() { [ "${1:-}" = "yes" ] || [ "${1:-}" = "true" ] || [ "${1:-}" = "1" ]; }' \
        'truthy() { return 0; }'; then
    t_check deploy.selftest.mutation.truthy \
        "with truthy accepting everything, held_at_program=no passes the lease gate and the selftest goes red" \
        selftest_fails "$M"
else
    t_skip deploy.selftest.mutation.truthy "could not plant the fault: truthy() is no longer a one-line whitelist"
fi

# THREE PROOFS, NOT ONE PER SELFTEST CLAIM, AND THE REASON IS COST. Each of
# these runs the 41-case selftest end to end - about fifty seconds - so the
# three are chosen to cover three DIFFERENT halves of the file rather than
# three faults: a fault in a gate the selftest drives through case_is; a fault
# in the hand-rolled absent-record cases below the case_is block, which no
# case_is touches; and a fault in the selftest's OWN GOOD_MANIFEST, which is
# what makes every red below it mean something. The verdict-level faults that
# would be redundant here (the DONE-property case, the daemon's skip path) are
# each proven in sections 3 and 4 against the gate directly, at a hundredth of
# the cost and with the same discrimination.

M="$(t_mutant "$SB" selftest-zero-bytes-graded)"
if t_replace_line "$M" ci/deploy-gates.sh 'if [ ! -s "$MANIFEST" ]; then' 'if [ ! -e "$MANIFEST" ]; then'; then
    t_check deploy.selftest.mutation.zero_bytes \
        "with -s weakened to -e a zero-byte manifest is graded (exit 1, not refused), and the selftest goes red" \
        selftest_fails "$M"
else
    t_skip deploy.selftest.mutation.zero_bytes "could not plant the fault: the manifest -s test has changed shape"
fi

M="$(t_mutant "$SB" selftest-baseline-broken)"
if t_replace_line "$M" ci/deploy-gates.sh "deploy.release.result ok'" "deploy.release.result UNVERIFIED:not-recorded'"; then
    t_check deploy.selftest.mutation.baseline \
        "with the selftest's own good fixture no longer clean, the baseline rows fail and the selftest goes red" \
        selftest_fails "$M"
else
    t_skip deploy.selftest.mutation.baseline "could not plant the fault: GOOD_MANIFEST no longer ends with 'deploy.release.result ok'"
fi

#=============================================================================
# 12. THE DRIVER-GATE JOINT
#
# STATICALLY: every key the gate reads with `mf` is a key the driver sets with
# `mf_set`. A key read and never written is a field that is UNVERIFIED on
# every run, or - worse - a detail that always reads empty. One such key
# exists today (deploy.test.log, in the sentence about the one gate that is
# about the design), carried as a known defect; the guard beside it stops a
# second one arriving unnoticed, by naming the first in exactly one place.
#
# The fixtures are held to the same standard: every key they carry is one
# the driver writes, so they cannot drift from the code they imitate.
#
# DYNAMICALLY: the real driver, dry-run, pointed at a unix socket nothing
# listens on. Every request fails with curl-7, the driver records
# UNVERIFIED:http-curl-7 for what it could not read, and the gate - which the
# driver invokes itself - must grade that as UNVERIFIED on preflight: not FAIL
# (nothing was wrong), not PASS (nothing was measured), with five dry-run
# skips. And the driver's refusal of a run with no target must reach the gate
# as the namespace FAIL, through the UNVERIFIED:<reason> spelling both agree
# on. Neither needs a hub; both need curl and python3, which the driver
# refuses to start without.
#=============================================================================
t_head "the driver-gate joint: keys read are keys written; a dry run against nothing grades as unmeasured"

## gate_reads <toolkit>   - every manifest key the gate reads, sorted
## driver_writes <toolkit> - every manifest key the driver sets, sorted
gate_reads()    { grep -oE '\bmf (deploy\.[a-z0-9_.]+|block|run_tag)\b' "$1/ci/deploy-gates.sh" | awk '{ print $2 }' | sort -u; }
driver_writes() { grep -oE '\bmf_set (deploy\.[a-z0-9_.]+|[a-z_]+)\b' "$1/scripts/fpga-flow-deploy" | awk '{ print $2 }' | sort -u; }

## orphan_reads <toolkit> - keys the gate reads that the driver never writes
orphan_reads() { comm -23 <(gate_reads "$1") <(driver_writes "$1"); }

# THE ONE ORPHAN KNOWN TODAY, named here and nowhere else. When the defect is
# fixed the marker below goes red; delete this line and the marker together.
KNOWN_ORPHANS="deploy.test.log"

## no_orphan_reads <toolkit> - the known-defect predicate: the orphan set is EMPTY
no_orphan_reads() {
    local o; o="$(orphan_reads "$1")"
    [ -z "$o" ] && return 0
    printf 'read by the gate, written by nothing in the driver:\n%s\n' "$o"; return 1
}
## no_new_orphan_reads <toolkit> - the guard: nothing beyond the recorded one
no_new_orphan_reads() {
    local o k new=""
    [ "$(gate_reads "$1" | grep -c .)" -ge 10 ] || { echo 'the gate reads fewer than ten keys - the grep is not finding them'; return 1; }
    for k in $(orphan_reads "$1"); do
        case " $KNOWN_ORPHANS " in *" $k "*) ;; *) new="$new $k" ;; esac
    done
    [ -z "$new" ] && return 0
    printf 'NEW keys read by the gate that the driver never writes:%s\n' "$new"
    printf 'Such a key is UNVERIFIED on every run, or a detail that always reads empty.\n'
    return 1
}

## fixture_keys_are_written <toolkit> - every key in every deploy fixture is a driver key
fixture_keys_are_written() {
    local dir="$1" f k bad=""
    for f in "$dir"/test/fixtures/deploy_manifest*.txt; do
        [ -s "$f" ] || continue
        for k in $(awk '$1 !~ /^#/ && NF >= 2 { print $1 }' "$f" | sort -u); do
            driver_writes "$dir" | grep -qxF "$k" || bad="$bad $(basename "$f"):$k"
        done
    done
    [ -z "$bad" ] && return 0
    printf 'fixture keys the driver never writes - the fixture has drifted from the code it imitates:%s\n' "$bad"
    return 1
}

t_known_defect deploy.joint.orphan_reads \
    "every manifest key the gate reads is one the driver writes (deploy.test.log is read in the failed-action sentence and written by nothing)" \
    no_orphan_reads "$FLOW_DIR"
t_check deploy.joint.no_new_orphans \
    "no key the gate reads is unwritten by the driver, beyond the one recorded as a defect" \
    no_new_orphan_reads "$FLOW_DIR"
t_check deploy.fixture.realism \
    "every key in test/fixtures/deploy_manifest*.txt is a key scripts/fpga-flow-deploy sets" \
    fixture_keys_are_written "$FLOW_DIR"

M="$(t_mutant "$SB" driver-renames-ttl)"
if t_replace_line "$M" scripts/fpga-flow-deploy '    mf_set deploy.lease.ttl_s "$TTL"' '    mf_set deploy.lease.ttl_secs "$TTL"'; then
    t_check_fail deploy.joint.no_new_orphans.mutation \
        "with the driver spelling one key differently from the gate, a new orphan appears and the assertion goes red" \
        no_new_orphan_reads "$M"
else
    t_skip deploy.joint.no_new_orphans.mutation "could not plant the fault: the driver's ttl_s mf_set has changed shape"
fi

M="$(t_mutant "$SB" fixture-invents-key)"
if [ -n "$M" ] && printf 'deploy.moment.seventh yes\n' >> "$M/test/fixtures/deploy_manifest.txt"; then
    t_check_fail deploy.fixture.realism.mutation \
        "with a key the driver never writes added to the fixture, the assertion goes red" \
        fixture_keys_are_written "$M"
else
    t_skip deploy.fixture.realism.mutation "could not plant the fault: the fixture copy could not be appended to"
fi

# -- the dynamic half ---------------------------------------------------------
DRIVER_ENV=(env -u FPGAHUB_ADDR -u FPGAHUB_SOCKET -u FPGAHUB_TOKEN -u FPGAHUB_TLS_DIR
            -u FPGA_REPORT_DIR -u REPORT_DIR -u FPGA_RUN_DIR -u RUN_DIR -u CI_APPEND -u CI_LANE
            -u CI_SUMMARY_FILE -u GITHUB_STEP_SUMMARY CI_COLOUR=0)
TMO=()
command -v timeout >/dev/null 2>&1 && TMO=(timeout 120)

## drive <toolkit> <run dir> <subcommand> [driver options...]
## The REAL driver, dry-run, against a socket nothing listens on. It invokes
## the gate itself, so <run dir>/ci/verdicts.tsv is the gate's grading of what
## the driver recorded, and <run dir>/reports/ holds both artefacts.
drive() {
    local dir="$1" run="$2"; shift 2
    local rc=0 out
    mkdir -p "$run"
    printf 'not a bitstream - a fixture for the driver to hash and stage\n' > "$run/demo_block.bit"
    out="$("${DRIVER_ENV[@]}" CI_VERDICT_DIR="$run/ci" ${TMO[@]+"${TMO[@]}"} \
           bash "$dir/scripts/fpga-flow-deploy" "$@" --dry-run \
               --bitstream "$run/demo_block.bit" --report-dir "$run/reports" --log-dir "$run/logs" \
               --out-dir "$run/outputs/deploy" --work-dir "$run/work" \
               --block demo_block --run-tag t_deploy_gates \
               --url "unix:$run/nobody-listens.sock" 2>&1)" || rc=$?
    printf '%s\nEXIT=%d\n' "$out" "$rc"
}

## driver_dryrun_unmeasured <toolkit>
driver_dryrun_unmeasured() {
    local dir="$1" run out rc vd got want first d
    run="$(vd_new)"; vd="$run/ci"
    out="$(drive "$dir" "$run" run --board demo_group --target demo_group_pl)"; rc="$(exit_of "$out")"
    [ -s "$run/reports/deploy_manifest.txt" ] || { printf 'the driver wrote no manifest:\n%s\n' "$out"; return 1; }
    [ -s "$vd/verdicts.tsv" ] || { printf 'the driver did not invoke the gate (no verdicts.tsv):\n%s\n' "$out"; return 1; }
    first="${IDS%% *}"
    got="$(ladder_rows "$vd")"; want="$(ladder_expect SKIP "$first=UNVERIFIED")"
    if [ "$got" != "$want" ]; then
        printf 'a dry run against a hub that never answered.\nGOT:\n%s\nWANT:\n%s\nmanifest:\n%s\n' \
            "$got" "$want" "$(grep -v '^#' "$run/reports/deploy_manifest.txt")"
        return 1
    fi
    d="$(detail_of "$vd" "$first")"
    t_contains "$d" "were not read" || { printf 'preflight is UNVERIFIED for the wrong reason: %s\n' "$d"; return 1; }
    [ -s "$run/reports/deploy_gate.txt" ] || { echo 'the driver handed the gate no --gate-file, or it was not written'; return 1; }
    [ "$rc" = 1 ] && return 0
    printf 'the driver exited %s, not 1, on a preflight it could not complete\n' "$rc"; return 1
}

## driver_no_target_is_namespace_fail <toolkit>
driver_no_target_is_namespace_fail() {
    local dir="$1" run out rc vd first v d
    run="$(vd_new)"; vd="$run/ci"
    out="$(drive "$dir" "$run" preflight --board demo_group)"; rc="$(exit_of "$out")"
    [ -s "$vd/verdicts.tsv" ] || { printf 'the driver did not invoke the gate:\n%s\n' "$out"; return 1; }
    first="${IDS%% *}"
    v="$(verdicts_of "$vd" "$first")"; d="$(detail_of "$vd" "$first")"
    [ "$v" = "FAIL" ] || { printf 'no target: %s is "%s", not FAIL\n%s\n' "$first" "${v:-<no row>}" "$(rows_of "$vd")"; return 1; }
    t_contains "$d" "DIFFERENT namespaces" || { printf 'the failure does not name the namespace split: %s\n' "$d"; return 1; }
    [ "$rc" = 2 ] && return 0
    printf 'the driver exited %s, not 2, on a refused preflight\n' "$rc"; return 1
}

if command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    t_check deploy.joint.dryrun_unmeasured \
        "the real driver, dry-run against a socket nobody answers, is graded UNVERIFIED on preflight and SKIP elsewhere, exit 1" \
        driver_dryrun_unmeasured "$FLOW_DIR"
    t_check deploy.joint.no_target \
        "the real driver refused a run with no target, and the gate reads that as the namespace FAIL" \
        driver_no_target_is_namespace_fail "$FLOW_DIR"

    M="$(t_mutant "$SB" driver-renames-mode)"
    if t_replace_line "$M" scripts/fpga-flow-deploy 'mf_set deploy.mode "$MODE"' 'mf_set deploy.run_mode "$MODE"'; then
        t_check_fail deploy.joint.dryrun_unmeasured.mutation \
            "with the driver recording the mode under a key the gate does not read, the dry run's skips become UNVERIFIED and the assertion goes red" \
            driver_dryrun_unmeasured "$M"
    else
        t_skip deploy.joint.dryrun_unmeasured.mutation "could not plant the fault: the driver's deploy.mode mf_set has changed shape"
    fi

    M="$(t_mutant "$SB" driver-unset-is-a-value)"
    if t_replace_line "$M" scripts/fpga-flow-deploy \
            'mf_set deploy.target "${TARGET:-UNVERIFIED:FPGAHUB_TARGET-unset}"' \
            'mf_set deploy.target "${TARGET:-unset}"'; then
        t_check_fail deploy.joint.no_target.mutation \
            "with the driver recording an unset target as the word 'unset', the gate reads a value and the namespace FAIL is lost, so the assertion goes red" \
            driver_no_target_is_namespace_fail "$M"
    else
        t_skip deploy.joint.no_target.mutation "could not plant the fault: the driver's deploy.target mf_set has changed shape"
    fi
else
    t_skip deploy.joint.dryrun_unmeasured "no curl or no python3 on this host - the driver refuses to start without both, so its manifest cannot be produced here"
    t_skip deploy.joint.no_target "no curl or no python3 on this host - the driver refuses to start without both"
    t_skip deploy.joint.dryrun_unmeasured.mutation "no curl or no python3 on this host - the driver this proof mutates cannot run"
    t_skip deploy.joint.no_target.mutation "no curl or no python3 on this host - the driver this proof mutates cannot run"
fi

#=============================================================================
# 13. THREE MORE KNOWN DEFECTS, FOUND BY GRADING RECORDS THE DRIVER NEVER WRITES
#
# Each is an assertion this suite believes is correct and the gate does not
# satisfy. None is red today; each goes RED the day it starts passing.
#
# DUPLICATE KEY. ci_mf returns the FIRST match. The driver knows this and
# makes its own last write win IN PLACE (docs/DEPLOY.md, item 5), so it never
# emits a duplicate. But the gate grades archived manifests, and a manifest
# with two answers for one gate-bearing key is graded from whichever came
# first, in silence - the later one being, by the driver's own documented
# semantics, the correction. An ambiguous record is not evidence; PASS is the
# one verdict it must not produce.
#
# SKIPPED UNMEASURED. `deploy.program.skipped` is the only field that tells a
# real program from the daemon's ok:true skip path (the gate's own comment:
# "A skip is therefore not a successful deploy"). It is read with `truthy`
# alone, so an ABSENT field reads as "not skipped" and the gate passes on the
# 2xx - a verdict from missing data, CONTRACT.md rule two, in the gate whose
# header says "ci_is_measured is what tells them apart - never a test for
# emptiness".
#
# HELD WITHOUT ACQUIRE. `deploy.lease.acquired no` with `why http-500` says
# the acquire failed; `held_at_program yes` says the board was held at the
# instant of programming. The gate grades the pair PASS on lease and SKIP on
# release ("no lease was acquired") in the same file. The gate does reason
# across moments elsewhere - verify refuses to grade DONE when program was not
# attempted, release refuses when nothing was acquired - and lease-after-
# acquire is the one ordering it does not check.
#=============================================================================
t_head "known defects: a duplicated key, an unmeasured skip flag, a lease held before it was acquired"

## not_pass_on <toolkit> <manifest> <gate id> - 0 iff that gate is not PASS and the exit is not 0
not_pass_on() {
    local dir="$1" mf="$2" id="$3" vd out rc v
    vd="$(vd_new)"
    out="$(grade "$dir" "$vd" --manifest "$mf")"; rc="$(exit_of "$out")"
    v="$(verdicts_of "$vd" "$id" | head -1)"
    [ "$v" != "PASS" ] && [ "$rc" != 0 ] && return 0
    printf '%s is "%s" and the exit is %s:\n%s\n' "$id" "${v:-<no row>}" "$rc" "$(rows_of "$vd")"
    return 1
}

MF_DUP="$(faulted "$FIX" '$a\deploy.lease.held_at_program no')" || t_fail deploy.fixture.plant "duplicate-key fault did not plant"
MF_NOSKIP="$(faulted "$FIX" '/^deploy.program.skipped /d')" || t_fail deploy.fixture.plant "skipped-absent fault did not plant"
MF_HELD_NOACQ="$(faulted "$FIX" 's|^deploy.lease.acquired .*|deploy.lease.acquired no\ndeploy.lease.why http-500|')" || t_fail deploy.fixture.plant "held-without-acquire fault did not plant"

t_known_defect deploy.manifest.duplicate_key \
    "a manifest carrying held_at_program twice (yes, then no) is not graded PASS from the first value in silence" \
    not_pass_on "$FLOW_DIR" "$MF_DUP" deploy.lease
t_known_defect deploy.program.skipped_unmeasured \
    "with deploy.program.skipped absent, deploy.program is not PASS - the skip flag is the only evidence a 2xx programmed anything" \
    not_pass_on "$FLOW_DIR" "$MF_NOSKIP" deploy.program
t_known_defect deploy.lease.held_without_acquire \
    "held_at_program=yes on a run whose acquire failed (acquired=no, why=http-500) is not graded PASS on deploy.lease" \
    not_pass_on "$FLOW_DIR" "$MF_HELD_NOACQ" deploy.lease

#=============================================================================
# 14. THE LIVE HUB - fpgahub 0.3.0, AND WHAT IT DOES TO THIS RECORD
#
# Everything above grades manifests whose values come from the DRIVER'S
# SOURCE, and that source was written against a local fpgahub 0.1.0.dev0
# checkout. On 2026-09-17 the tier was run against the live hub - 0.3.0, on a
# real KR260 - and two findings change what a manifest from a real run says.
# test/fixtures/deploy_manifest_live_hub.txt carries them; its header says
# exactly which three facts are measured and which fields are the clean
# fixture unchanged, because no manifest from that run reached this repository
# and inventing the rest would be a fixture agreeing with its author.
#
# WHAT THIS SECTION CAN ASSERT, AND WHAT IT DELIBERATELY CANNOT.
#
# FINDING 1 IS GRADABLE. 0.3.0's LeaseAcquireRequest has no holder, user or
# unix_user field; the hub records `holder: mtls-peer@<ip>` from the
# connection whatever the body said. So against the live hub NO holder can
# ever match `*fpga-flow*`, and deploy.lease.holder - the toolkit's only
# lease-identity gate - WARNS ON EVERY RUN. That is assertable from the
# fixture and is asserted, with a proof, because a warning that fires on every
# healthy run is one people stop reading, and it is the run where a lease
# really has outlived its owner that then goes unnoticed. The gate is not
# wrong; the discipline behind it is inert, which is a different finding and a
# worse one.
#
# FINDING 2 IS NOT GRADABLE BY THIS GATE, AND NO FIXTURE CAN MAKE IT SO. The
# preflight group-holder parse reads `lease.holder` / `leases.0.holder`; 0.3.0
# sends `{"state":"held","members":[{"current":{"holder":..}}]}`, so the
# driver printed "group is free" while the hub said HELD. The field it wrote,
# deploy.preflight.group_holder, IS READ BY NO GATE - so no verdict in any run
# is different for that wrong value, and a fixture asserting otherwise would
# be asserting against a verdict the file does not emit. It is carried below
# as a known defect instead: the mirror of deploy.joint.orphan_reads, a field
# recorded at cost and graded by nobody, and the one that would have caught a
# board that was somebody else's before we asked for it.
#
# FINDING 3 IS A DRIVER PROPERTY AND IS ASSERTED AS ONE. The driver records
# deploy.lease.holder from its OWN $HOLDER, before the request, and never from
# the response - so on 0.3.0 the manifest states a holder the hub never
# stored, and nothing downstream can know. That is checkable in the driver's
# source with no hub at all, and is carried as a known defect.
#=============================================================================
t_head "the live hub (0.3.0): the holder discipline is inert, and the gate that would notice warns on every run"

FIX_LIVE="$FIXDIR/deploy_manifest_live_hub.txt"

## live_holder_always_warns <toolkit> <manifest>
## The six gates still pass - nothing about the deploy is wrong - and the run
## carries the holder WARN as a SEVENTH row. Asserting the row count is what
## separates "the warning fired" from "the fixture happens to be green".
live_holder_always_warns() {
    local dir="$1" mf="$2" vd out rc got d
    [ -s "$mf" ] || { printf 'no live-hub fixture at %s\n' "$mf"; return 1; }
    vd="$(vd_new)"
    out="$(grade "$dir" "$vd" --manifest "$mf")"; rc="$(exit_of "$out")"
    got="$(ladder_rows "$vd")"
    [ "$got" = "$(ladder_expect PASS)" ] || {
        printf 'the six gates are not all PASS - the live-hub holder must not fail a deploy:\n%s\n' "$got"; return 1; }
    [ "$(verdicts_of "$vd" deploy.lease.holder)" = "WARN" ] || {
        printf 'the hub-assigned holder did NOT warn. Against 0.3.0 the holder is\n'
        printf 'mtls-peer@<ip> for every run from every host, so a lease that outlives its\n'
        printf 'run names nothing and this is the only row that would have said so:\n%s\n' "$(rows_of "$vd")"
        return 1; }
    d="$(detail_of "$vd" deploy.lease.holder)"
    t_contains "$d" "does not name this toolkit" || {
        printf 'the warning does not say what is wrong with the holder: %s\n' "$d"; return 1; }
    [ "$rc" = 0 ] && return 0
    printf 'a warning made the run exit %s - warnings are never red (CONTRACT.md 7)\n' "$rc"; return 1
}

## live_differs_from_local <toolkit>
## The point of keeping both fixtures: the 0.1.0-era one is the ONLY one that
## reaches a clean six-row run. If these two ever grade identically, one of
## them has stopped carrying the difference it exists to carry.
live_differs_from_local() {
    local dir="$1" a b
    a="$(vd_new)"; b="$(vd_new)"
    grade "$dir" "$a" --manifest "$FIX"      >/dev/null
    grade "$dir" "$b" --manifest "$FIX_LIVE" >/dev/null
    [ "$(cut -f2,3 "$a/verdicts.tsv" 2>/dev/null)" != "$(cut -f2,3 "$b/verdicts.tsv" 2>/dev/null)" ] && return 0
    printf 'the 0.1.0-era fixture and the live-hub one grade identically, so the suite is\n'
    printf 'no longer measuring what the live hub changed:\n%s\n' "$(rows_of "$b")"
    return 1
}

t_check deploy.live.holder_warns \
    "the hub-assigned holder (mtls-peer@<ip>) warns on deploy.lease.holder while all six gates pass - the lease-identity discipline is inert against 0.3.0" \
    live_holder_always_warns "$FLOW_DIR" "$FIX_LIVE"
t_check deploy.live.differs \
    "the live-hub fixture and the 0.1.0-era one do not grade identically - the suite still measures the difference" \
    live_differs_from_local "$FLOW_DIR"

# THE SAME EDIT AS deploy.warn.holder.mutation IN SECTION 7, IN ITS OWN COPY.
# One line produces both symptoms and the two assertions catch different
# halves: section 7 that the mechanism warns at all, on an invented holder;
# this one that it warns on the holder the LIVE hub assigns, that the six
# gates stay green while it does, and that the sentence names the problem.
# Separate copies, so neither proof can pass or fail for the other's reason.
M="$(t_mutant "$SB" live-holder-never-warns)"
if t_replace_line "$M" ci/deploy-gates.sh '        *fpga-flow*) ;;' '        *) ;;'; then
    t_check_fail deploy.live.holder_warns.mutation \
        "with every holder accepted as distinctive, the hub-assigned holder passes unremarked and the assertion goes red" \
        live_holder_always_warns "$M" "$FIX_LIVE"
else
    t_skip deploy.live.holder_warns.mutation "could not plant the fault: gate_lease's holder case arm has changed shape"
fi

M="$(t_mutant "$SB" live-same-as-local)"
if plant "$M" ci/deploy-gates.sh 's#ci_warn deploy.lease.holder#:#'; then
    t_check_fail deploy.live.differs.mutation \
        "with the holder warning removed entirely, the two fixtures grade identically and the assertion goes red" \
        live_differs_from_local "$M"
else
    t_skip deploy.live.differs.mutation "could not plant the fault, or the planted copy stopped parsing: gate_lease's holder ci_warn has changed shape - see the harness line above"
fi

# -- the two findings this gate cannot see, carried, not fixed ----------------

## key_is_graded <toolkit> <manifest key> - some gate reads it
key_is_graded() { gate_reads "$1" | grep -qxF "$2"; }

## driver_records_hub_holder <toolkit>
## At least one `mf_set deploy.lease.holder` takes its value from the hub's
## response (a jget) rather than only from the holder this run proposed.
driver_records_hub_holder() {
    grep -E 'mf_set +deploy\.lease\.holder' "$1/scripts/fpga-flow-deploy" | grep -q 'jget'
}

t_known_defect deploy.live.group_holder_ungraded \
    "deploy.preflight.group_holder is read by some gate - the driver records who held the board at preflight and on 0.3.0 recorded 'none' for a board that was HELD, and no verdict anywhere is different for it" \
    key_is_graded "$FLOW_DIR" deploy.preflight.group_holder
t_known_defect deploy.live.holder_is_proposed \
    "the driver records deploy.lease.holder from the hub's response, not only from the holder it proposed - on 0.3.0 the hub ignores the holder it is sent, so the manifest states a value the hub never stored" \
    driver_records_hub_holder "$FLOW_DIR"

#=============================================================================
# 15. A DISCARDED EXIT STATUS, AND THE ARTEFACT THAT LIES BECAUSE OF IT
#
# Found by looking for one specific idiom after a sibling suite hit it in
# ci/check-vendor-collateral.sh: A TOOL'S EXIT STATUS DISCARDED, SO "I COULD
# NOT LOOK" BECOMES "I LOOKED AND FOUND NOTHING". ci/deploy-gates.sh has it,
# in the one place where it writes the artefact a person reads days later:
#
#     if awk -F'\t' '$2=="FAIL" || $2=="UNVERIFIED" { found=1 } END { exit !found }' \
#            "$CI_VERDICT_DIR/verdicts.tsv" 2>/dev/null; then
#         printf 'HARD FAILURES:\n'   ... list them ...
#     else
#         printf 'HARD FAILURES: none\n'
#     fi
#
# awk exits NON-ZERO when it cannot read its operand, and non-zero here is the
# else branch. So a run whose verdict file could not be written - an
# unwritable CI_VERDICT_DIR, which ci_init reaches with `mkdir -p ... || true`
# and `: > ... || true`, both deliberately non-fatal - produces a gate file
# that says `HARD FAILURES: none` FOR A RUN WHOSE GATES FAILED. Measured:
# with deploy.verify red and the verdict directory mode 000, the console says
# FAIL and reports the failing gate, and reports/deploy_gate.txt says none.
#
# THE PROCESS EXIT IS NOT AFFECTED - ci_exit counts in memory, so CI keyed on
# the status still goes red. What is affected is the ARTEFACT, which is what
# docs/DEPLOY.md sends a reader to, what CONTRACT.md section 5 defines as the
# verdict, and what `^HARD FAILURES: none` is grepped for elsewhere in this
# toolkit. An archived run is read through the artefact and nothing else.
#
# THE CONTROL IS ALREADY IN SECTION 8: deploy.gatefile.fail_listed drives the
# same failing manifest with a WRITABLE verdict directory and requires the
# failure to be listed. So the predicate below is known to be able to answer
# both ways, which is the only thing that makes its red mean anything.
#=============================================================================
t_head "the gate file must not claim 'none' when it could not read the evidence"

## gatefile_no_evidence_no_claim <toolkit>
## 0 when a gate file written WITHOUT a readable verdict file declines to
## claim `HARD FAILURES: none`.
gatefile_no_evidence_no_claim() {
    local dir="$1" vd g rc=0
    vd="$(vd_new)"; g="$vd/deploy_gate.txt"
    mkdir -p "$vd/locked" && chmod 000 "$vd/locked" || return 1
    "${GATE_ENV[@]}" CI_VERDICT_DIR="$vd/locked/ci" \
        bash "$dir/ci/deploy-gates.sh" --manifest "$MF_VERIFY" --gate-file "$g" >/dev/null 2>&1 || rc=$?
    chmod 755 "$vd/locked" 2>/dev/null
    [ -s "$g" ] || { echo 'no gate file was written at all'; return 1; }
    if grep -qE '^HARD FAILURES: none$' "$g"; then
        printf 'THE ARTEFACT SAYS "HARD FAILURES: none" FOR A RUN WITH A RED GATE.\n'
        printf 'The verdict file could not be written, awk could not read it, and a\n'
        printf 'non-zero awk is the else branch - so "we could not look" was printed as\n'
        printf '"we looked and found nothing". The process exited %s; the artefact, which\n' "$rc"
        printf 'is what an archived run is read through, says the deploy was clean.\n'
        return 1
    fi
    return 0
}

if [ "$(id -u)" = 0 ]; then
    t_skip deploy.gatefile.no_evidence_no_claim "running as uid 0, where a mode-000 directory does not bite - the case under test is a verdict file that CANNOT be read, and root can read it"
else
    t_known_defect deploy.gatefile.no_evidence_no_claim \
        "with the verdict file unreadable, the gate file declines to claim 'HARD FAILURES: none' - today a discarded awk status prints that claim for a run whose gates failed" \
        gatefile_no_evidence_no_claim "$FLOW_DIR"
fi

t_summary
