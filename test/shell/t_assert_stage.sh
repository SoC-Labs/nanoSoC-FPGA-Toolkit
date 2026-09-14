#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# t_assert_stage.sh - ci/assert-stage.sh, the after-the-fact stage judge
#
# DEFECT CLASS: A JUDGE THAT EXITS 0 HAVING READ NOTHING.
#
# ci/assert-stage.sh exists because make's own assertions run in the same
# process as the stage, so a job killed by a timeout, a lost licence seat, a
# full filesystem or a rebooted runner never reaches them and the artefacts left
# behind are judged by nobody. It reads the DISK - the manifest and the gate
# file - after the fact, and never re-scrapes the tool's reports, because a
# second fuzzier opinion competing with the authoritative one is how a
# case-sensitive grep undercounted DRC by 7% for weeks in the reference project
# with nothing disagreeing with it.
#
# ITS AUTHOR EXERCISED IT BY HAND against fixture run directories - a clean run,
# a stale manifest, an exceeded budget, a delegation with no owner, a missing
# verdict, both --optional paths - and then RECORDED THE ABSENCE OF THIS FILE AS
# A GAP in test/README.md rather than in somebody's memory. This is that file.
# By hand is not by CI: a hand run happens once, against the tree as it was that
# afternoon, and proves nothing about the tree tomorrow.
#
# THE FOUR PROPERTIES THAT FAIL SILENTLY AND GREENLY, which is why each is
# tested from outside the script with the fault planted in a copy:
#
#   1. A STAGE THAT IS CONFIGURED AND WROTE NOTHING MUST FAIL, --optional or
#      not. --optional exists only for the two stages a project can switch OFF,
#      and laundering a real failure into a skip is how a green run comes to
#      prove nothing. The distinction is READ FROM THE PROJECT'S CONTRACT, so a
#      skip states a FACT ("BD_TCL is empty") rather than an inference from an
#      absence of output.
#   2. A MISSING VERDICT IS UNVERIFIED, NOT A PASS. CONTRACT.md section 7: a
#      check whose input it could not read has not passed, it has not run.
#   3. A MANIFEST FROM ANOTHER RUN MUST BE CAUGHT. The run namespace is supposed
#      to make that impossible, which is exactly why it is worth testing rather
#      than assuming - and there are three independent ways to notice it: the
#      stage field, the run tag, and a byte count that disagrees with the disk.
#   4. THE EXIT CODES MEAN WHAT CONTRACT.md section 10 SAYS. 0 ok, 1 we looked
#      and found something, 2 we could not look. A caller is entitled to tell
#      the last two apart, and a script that returns 1 for a missing run
#      directory sends a reader to the design instead of to their own job.
#
# Every assertion below is paired with a MUTATION PROOF: the same assertion, run
# against a copy of the toolkit with one guard neutered, must go red. The
# fixtures are in test/fixtures/ and the run directories are built under a
# mktemp -d; nothing here launches a tool, takes a licence or reads a real run.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/lib/harness.sh
. "$HERE/../lib/harness.sh"

t_sandbox; SB="$T_SANDBOX"
FIX="$HERE/../fixtures"

#-----------------------------------------------------------------------------
# WHAT HAS TO BE HERE. Both are SKIPS WITH THE REASON: this repository is being
# written by several sessions at once, and a suite that went green against a
# file that had not landed would be reporting on nothing.
#-----------------------------------------------------------------------------
if [ ! -f "$FLOW_DIR/ci/assert-stage.sh" ]; then
    t_skip assert.all "no $FLOW_DIR/ci/assert-stage.sh in this checkout - nothing to test, and an absent file is not a passing one"
    t_summary; exit $?
fi
for f in impl_manifest.txt impl_gate.txt impl_gate_budget.txt impl_gate_unowned.txt; do
    [ -f "$FIX/$f" ] && continue
    t_skip assert.all "no test/fixtures/$f - the fixtures this suite judges against are missing, so it would be judging nothing"
    t_summary; exit $?
done

BLOCK_NAME=demo_block          # CONTRACT.md section 1: this repository names no
RUN_TAG_NAME=t_assert_stage    # real block and no real board, fixtures included

#-----------------------------------------------------------------------------
# DRIVING THE SCRIPT
#
# THE ENVIRONMENT IS BUILT, NOT INHERITED. mk/flow.mk exports a dozen FPGA_*
# variables to every tool it launches, and this suite is run inside projects as
# well as in a bare checkout - an inherited FPGA_RUN_DIR would point the script
# at somebody's real run, and an inherited FPGA_SEAMS_FILE would silently make
# every "the contract could not be reached" case unreachable.
#
# AS_ENV carries the per-case additions. It is a bash array rather than a string
# because a project path may contain spaces (mk/flow.mk section 2 says so in as
# many words) and word-splitting one here would test the wrong thing.
#-----------------------------------------------------------------------------
AS_ENV=()

stage_run() {           # stage_run <toolkit> <run dir> <stage> [args...]
    local tk="$1" run="$2" st="$3"; shift 3
    # A FRESH VERDICT DIRECTORY EVERY TIME. ci_init refuses to truncate a
    # verdicts.tsv owned by a live lane, and this suite runs the same run
    # directory through several toolkits; a stale owner file would turn one
    # assertion into a report about the previous one.
    case "$run" in
        "$SB"/*) rm -rf "$run/ci" ;;
        *) echo "t_assert_stage: refusing to touch $run - not in the sandbox" >&2; return 2 ;;
    esac
    env -u FPGA_DIR -u FPGA_SEAMS_FILE -u FPGA_BD_TCL -u FPGA_PACKAGE_TCL \
        -u FPGA_DESIGN_NAME -u FPGA_WORK_DIR -u FPGA_LOG_DIR -u FPGA_REPORT_DIR \
        -u FPGA_OUT_DIR -u RUN_DIR -u BLOCK -u CI_APPEND -u CI_SUMMARY_FILE \
        FPGA_RUN_DIR="$run" FPGA_BLOCK="$BLOCK_NAME" FPGA_RUN_TAG="$RUN_TAG_NAME" \
        CI_VERDICT_DIR="$run/ci" CI_COLOUR=0 CI_LANE=t_assert_stage \
        ${AS_ENV[@]+"${AS_ENV[@]}"} \
        "$tk/ci/assert-stage.sh" "$st" "$@" 2>&1
}

## mkrun <name> -> prints a run directory holding a CLEAN, COMPLETE impl run
##
## The four directories CONTRACT.md section 5 fixes, a routed checkpoint of
## exactly the size the manifest claims, a timing report, the manifest and the
## gate file. Every case below starts from this and breaks one thing.
mkrun() {
    local d="$SB/runs/$1"
    rm -rf "$d"; mkdir -p "$d/work" "$d/logs" "$d/reports" "$d/outputs" || return 2
    head -c 4096 /dev/zero > "$d/outputs/${BLOCK_NAME}_routed.dcp" || return 2
    printf 'timing summary (fixture)\n' > "$d/reports/timing_summary.rpt"
    printf 'utilisation (fixture)\n'    > "$d/reports/utilization_synth.rpt"
    cp "$FIX/impl_manifest.txt" "$d/reports/impl_manifest.txt" || return 2
    cp "$FIX/impl_gate.txt"     "$d/reports/impl_gate.txt"     || return 2
    printf '%s' "$d"
}

## as_verdicts <run> - the verdict file that run produced
as_verdicts() { printf '%s/ci/verdicts.tsv' "$1"; }

## as_passes <toolkit> <run> <stage> [args...]
## Exit 0 AND no FAIL/UNVERIFIED row. The second half matters: ci_exit's status
## is the thing under test in half this file, so a proof that trusted it alone
## would be asking the subject to grade itself.
as_passes() {
    local tk="$1" run="$2" st="$3"; shift 3
    local out rc=0 v; v="$(as_verdicts "$run")"
    out="$(stage_run "$tk" "$run" "$st" "$@")" || rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'exit %s, wanted 0:\n%s\n' "$rc" "$out"; return 1
    fi
    if awk -F'\t' '$2 == "FAIL" || $2 == "UNVERIFIED" { bad = 1 } END { exit !bad }' "$v" 2>/dev/null; then
        printf 'it exited 0 while recording a failure - ci_exit and the verdict file disagree:\n%s\n' \
            "$(cat "$v")"
        return 1
    fi
    return 0
}

## as_gate <toolkit> <run> <stage> <want rc> <VERDICT> <gate id> [args...]
##
## THE EXIT STATUS AND THE NAMED GATE, TOGETHER. Asserting only the status would
## pass on a run that failed for an unrelated reason - and half the cases here
## deliberately break one thing in a directory with a dozen other gates in it.
as_gate() {
    local tk="$1" run="$2" st="$3" want="$4" verdict="$5" gate="$6"; shift 6
    local out rc=0 v; v="$(as_verdicts "$run")"
    out="$(stage_run "$tk" "$run" "$st" "$@")" || rc=$?
    if [ "$rc" != "$want" ]; then
        printf 'exit %s, wanted %s:\n%s\n' "$rc" "$want" "$out"; return 1
    fi
    if ! awk -F'\t' -v v="$verdict" -v g="$gate" \
            '$2 == v && $3 == g { ok = 1 } END { exit !ok }' "$v" 2>/dev/null; then
        printf 'no %s row for gate %s. the verdict file says:\n%s\n' \
            "$verdict" "$gate" "$(cat "$v" 2>/dev/null)"
        return 1
    fi
    return 0
}

## as_detail <toolkit> <run> <stage> <gate id> <needle>... [-- args...]
## The gate's DETAIL must carry these words. A skip that does not say WHY is the
## thing CONTRACT.md section 7 refuses to call a skip.
as_detail() {
    local tk="$1" run="$2" st="$3" gate="$4"; shift 4
    local needles=() args=() seen=0 a
    for a in "$@"; do
        if [ "$a" = "--" ]; then seen=1; continue; fi
        if [ "$seen" = 1 ]; then args+=("$a"); else needles+=("$a"); fi
    done
    local out v detail; v="$(as_verdicts "$run")"
    out="$(stage_run "$tk" "$run" "$st" ${args[@]+"${args[@]}"})"
    detail="$(awk -F'\t' -v g="$gate" '$3 == g { print $4; exit }' "$v" 2>/dev/null)"
    if [ -z "$detail" ]; then
        printf 'gate %s recorded no detail. the verdict file says:\n%s\n%s\n' \
            "$gate" "$(cat "$v" 2>/dev/null)" "$out"
        return 1
    fi
    for a in ${needles[@]+"${needles[@]}"}; do
        printf '%s' "$detail" | grep -qF -- "$a" || {
            printf 'the detail for %s does not contain "%s":\n  %s\n' "$gate" "$a" "$detail"
            return 1; }
    done
    return 0
}

## as_gates_pass <toolkit> <run> <stage> <gate id>...
## Every one of these must be a PASS. THE POINT: a judge that measured nothing
## also exits 0, so "the clean run passed" is only worth something beside the
## list of gates it actually reached.
as_gates_pass() {
    local tk="$1" run="$2" st="$3"; shift 3
    local out rc=0 v g; v="$(as_verdicts "$run")"
    out="$(stage_run "$tk" "$run" "$st")" || rc=$?
    for g in "$@"; do
        awk -F'\t' -v g="$g" '$2 == "PASS" && $3 == g { ok = 1 } END { exit !ok }' "$v" 2>/dev/null \
            || { printf 'gate %s is not a PASS - it did not run at all:\n%s\n%s\n' \
                     "$g" "$(cat "$v" 2>/dev/null)" "$out"; return 1; }
    done
    return 0
}


#=============================================================================
# 1. A CLEAN RUN PASSES - AND SAYS WHICH GATES IT REACHED
#=============================================================================
t_head "a clean impl run passes, and the gates it passed are named"

CLEAN="$(mkrun clean)"
t_check assert.clean.impl \
    "a complete impl run - checkpoint, timing report, manifest, gate file - exits 0 with no FAIL or UNVERIFIED row" \
    as_passes "$FLOW_DIR" "$CLEAN" impl
t_check assert.clean.gates \
    "and it actually reached the gates: manifest, provenance, tool, completeness, gate file, hard failures, budgets, not-covered, and the dcp cross-check" \
    as_gates_pass "$FLOW_DIR" "$CLEAN" impl \
    impl.manifest impl.manifest.tool impl.provenance impl.manifest.complete \
    impl.gate impl.gate.hard impl.gate.budgets impl.gate.notcovered impl.dcp.consistent

# -- mutation proof ----------------------------------------------------------
# THE FAULT IS IN THE EVIDENCE, not in the judge: one measurement in the
# manifest becomes `unmeasured`, which is what a stage that ran and measured
# nothing leaves behind and which passes any existence check ever written.
UNMEAS="$(mkrun unmeasured)"
if t_mutate "$UNMEAS" reports/impl_manifest.txt 's/^wns  *0\.213$/wns                      unmeasured/'; then
    t_check_fail assert.clean.impl.mutation \
        "with wns recorded as 'unmeasured', the clean-run assertion goes red - an unmeasured number is UNVERIFIED, not a pass" \
        as_passes "$FLOW_DIR" "$UNMEAS" impl
else
    t_skip assert.clean.impl.mutation "could not plant the fault: test/fixtures/impl_manifest.txt no longer records 'wns 0.213'"
fi

# And the fault this file's own header warns about: the gate that gets DELETED
# because it went red. The clean run then still exits 0 while measuring less.
M="$(t_mutant "$SB" gate-file-not-read)"
if t_replace_line "$M" ci/assert-stage.sh \
        '    assert_gate_file impl "$REP/impl_gate.txt"' \
        '    : # the verdict artefact is no longer read'; then
    t_check_fail assert.clean.gates.mutation \
        "with the gate file no longer read, the run still exits 0 and the named gates vanish, so the assertion goes red" \
        as_gates_pass "$M" "$CLEAN" impl impl.gate.hard impl.gate.notcovered
else
    t_skip assert.clean.gates.mutation "could not plant the fault: the assert_gate_file call in the impl arm has changed shape"
fi


#=============================================================================
# 2. A CONFIGURED STAGE THAT WROTE NOTHING FAILS - AND --optional DOES NOT
#    LAUNDER IT
#
# package-ip and bd run only when the project sets PACKAGE_TCL and BD_TCL. FROM
# DISK ALONE a stage that was switched off and a stage that ran and died before
# writing anything are identical, and --optional exists for exactly that
# ambiguity. It is not a licence to pass: a stage the contract says is ON and
# that left nothing behind is a real failure, and a skip there is how a green
# run comes to prove nothing.
#=============================================================================
t_head "a CONFIGURED stage that wrote nothing fails, with --optional or without"

ONBD="$(mkrun bd-on)"
AS_ENV=(FPGA_SEAMS_FILE="$FLOW_DIR/flow/common/seams.txt" FPGA_BD_TCL="/fixture/does-not-exist/bd.tcl")
t_check assert.configured.fails \
    "bd is switched ON in the contract and wrote no block design - that is a FAIL, not an absence" \
    as_gate "$FLOW_DIR" "$ONBD" bd 1 FAIL bd.design
t_check assert.configured.optional_no_launder \
    "and --optional does NOT turn it into a skip - the flag is for an ambiguity, not for a failure" \
    as_gate "$FLOW_DIR" "$ONBD" bd 1 FAIL bd.design --optional

M="$(t_mutant "$SB" optional-launders)"
if t_replace_line "$M" ci/assert-stage.sh \
        '    [ -z "$val" ] || return 0          # configured ON: assert it, and mean it' \
        '    if [ "$OPTIONAL" = 1 ]; then ci_skip "$st.stage" "laundered by --optional"; ci_exit "assert-stage($STAGE)"; exit $?; fi'; then
    t_check_fail assert.configured.optional_no_launder.mutation \
        "with --optional allowed to skip a configured stage, the assertion goes red - and the run reports green having measured nothing" \
        as_gate "$M" "$ONBD" bd 1 FAIL bd.design --optional
else
    t_skip assert.configured.optional_no_launder.mutation "could not plant the fault: the configured-ON early return in stage_switched_off() has changed shape"
fi
AS_ENV=()


#=============================================================================
# 3. A STAGE THAT IS NOT CONFIGURED SKIPS WITH THE FACT
#
# The reason has to be a FACT READ FROM THE CONTRACT, not an inference from an
# empty directory - and when the contract cannot be reached at all, the honest
# answer names the ambiguity and says how to remove it.
#=============================================================================
t_head "a stage the project switched off skips with the reason, read from the contract"

OFFBD="$(mkrun bd-off)"
AS_ENV=(FPGA_SEAMS_FILE="$FLOW_DIR/flow/common/seams.txt")
t_check assert.offstage.skips \
    "BD_TCL empty in a contract that WAS reachable: exit 0 and a SKIP, not a pass and not a failure" \
    as_gate "$FLOW_DIR" "$OFFBD" bd 0 SKIP bd.stage
t_check assert.offstage.skips.reason \
    "and the skip states the FACT - which variable, and where the contract was read from" \
    as_detail "$FLOW_DIR" "$OFFBD" bd bd.stage \
    "BD_TCL is empty" "the environment mk/flow.mk exported" "Nothing was measured here"
AS_ENV=()

t_check assert.offstage.unreachable_refuses \
    "with the contract UNREACHABLE and no --optional, the stage is asserted and fails honestly rather than being excused" \
    as_gate "$FLOW_DIR" "$OFFBD" bd 1 FAIL bd.design
t_check assert.offstage.unreachable_optional \
    "with the contract unreachable AND --optional, it skips naming the ambiguity and how to make the answer knowable" \
    as_detail "$FLOW_DIR" "$OFFBD" bd bd.stage \
    "could not be reached" "died before writing anything" "--fpga-dir" -- --optional

M="$(t_mutant "$SB" contract-source-ignored)"
if t_replace_line "$M" ci/assert-stage.sh \
        '    if [ "$CONTRACT_SOURCE" != "none" ]; then' \
        '    if false; then'; then
    t_check_fail assert.offstage.skips.mutation \
        "with the contract source ignored, a switched-off stage is asserted instead of skipped and the assertion goes red" \
        as_gate "$M" "$OFFBD" bd 0 SKIP bd.stage
else
    t_skip assert.offstage.skips.mutation "could not plant the fault: the CONTRACT_SOURCE test in stage_switched_off() has changed shape"
fi


#=============================================================================
# 4. A STALE MANIFEST IS CAUGHT - THREE INDEPENDENT WAYS
#
# THE FAULTS ARE PLANTED WITH t_mutate RATHER THAN SHIPPED AS FIXTURES, on
# purpose. A shipped "stale" manifest that quietly lost its `stage` field would
# make this suite pass for the wrong reason - assert-stage warns about an ABSENT
# stage field and FAILS on a WRONG one, and the two are different verdicts.
# t_mutate proves the clean fixture had the right value to spoil.
#=============================================================================
t_head "a manifest from another run is caught by the stage, the run tag and the byte count"

STALE="$(mkrun stale-stage)"
if t_mutate "$STALE" reports/impl_manifest.txt 's/^stage  *impl$/stage                    synth/'; then
    t_check assert.stale.stage \
        "a manifest naming a different STAGE fails - every number under it belongs to something else" \
        as_gate "$FLOW_DIR" "$STALE" impl 1 FAIL impl.manifest.stage
else
    t_skip assert.stale.stage "could not plant the fault: test/fixtures/impl_manifest.txt no longer records 'stage impl'"
fi

STALETAG="$(mkrun stale-tag)"
if t_mutate "$STALETAG" reports/impl_manifest.txt "s/^run_tag  *$RUN_TAG_NAME\$/run_tag                  some-other-run/"; then
    t_check assert.stale.run_tag \
        "a manifest carrying another RUN TAG fails - the reports directory holds another run's evidence" \
        as_gate "$FLOW_DIR" "$STALETAG" impl 1 FAIL impl.manifest.run_tag
else
    t_skip assert.stale.run_tag "could not plant the fault: test/fixtures/impl_manifest.txt no longer records run_tag $RUN_TAG_NAME"
fi

STALEDCP="$(mkrun stale-dcp)"
head -c 512 /dev/zero > "$STALEDCP/outputs/${BLOCK_NAME}_routed.dcp"
t_check assert.stale.dcp \
    "a checkpoint whose size disagrees with the manifest fails - they are written seconds apart by one script, so they cannot honestly differ" \
    as_gate "$FLOW_DIR" "$STALEDCP" impl 1 FAIL impl.dcp.consistent

M="$(t_mutant "$SB" stale-stage-ignored)"
if t_replace_line "$M" ci/assert-stage.sh \
        '    elif [ "$ms" != "$st" ]; then' \
        '    elif false; then'; then
    t_check_fail assert.stale.stage.mutation \
        "with the stage cross-check neutered, another stage's manifest is accepted and the assertion goes red" \
        as_gate "$M" "$STALE" impl 1 FAIL impl.manifest.stage
else
    t_skip assert.stale.stage.mutation "could not plant the fault: the stage cross-check in assert_manifest() has changed shape"
fi

# A RANGE-RESTRICTED sed, not t_replace_line: `if [ "$mb" = "$db" ]; then`
# appears TWICE - the impl arm compares dcp_bytes and the bitstream arm compares
# bit_bytes - and t_replace_line refuses a line that matches more than once, on
# purpose. Planting the fault in both arms at once would stop this proof
# isolating one guard.
M="$(t_mutant "$SB" stale-dcp-ignored)"
if t_mutate "$M" ci/assert-stage.sh \
        '/^impl)$/,/^bitstream)$/ s/^        if \[ "\$mb" = "\$db" \]; then$/        if true; then/'; then
    t_check_fail assert.stale.dcp.mutation \
        "with the byte-count comparison always true, a checkpoint from another run is accepted" \
        as_gate "$M" "$STALEDCP" impl 1 FAIL impl.dcp.consistent
else
    t_skip assert.stale.dcp.mutation "could not plant the fault: the dcp_bytes comparison in the impl arm has changed shape"
fi


#=============================================================================
# 5. AN EXCEEDED BUDGET FAILS - AND AN ABSENT SECTION IS NOT AN EMPTY ONE
#
# CONTRACT.md section 5 fixes the gate file's structure. A reader cannot tell
# "no budget was exceeded" from "budgets were never checked" unless the heading
# is required, so a missing heading is UNVERIFIED rather than a quiet pass.
#=============================================================================
t_head "an exceeded budget fails, and a missing BUDGETS section is UNVERIFIED"

BUDGET="$(mkrun budget)"
cp "$FIX/impl_gate_budget.txt" "$BUDGET/reports/impl_gate.txt"
t_check assert.budget.exceeded \
    "a budget bullet under BUDGETS EXCEEDED is a FAIL, and the failing metric is in the detail" \
    as_gate "$FLOW_DIR" "$BUDGET" impl 1 FAIL impl.gate.budgets
t_check assert.budget.exceeded.detail \
    "and the detail quotes the measurement, so the red job names the number rather than the file" \
    as_detail "$FLOW_DIR" "$BUDGET" impl impl.gate.budgets "lut 61234 > budget 53200"

NOBUDGET="$(mkrun no-budget-section)"
if t_mutate "$NOBUDGET" reports/impl_gate.txt '/^BUDGETS EXCEEDED$/d'; then
    t_check assert.budget.absent_section \
        "a gate file with NO BUDGETS EXCEEDED heading is UNVERIFIED - an absent section is not an empty one" \
        as_gate "$FLOW_DIR" "$NOBUDGET" impl 1 UNVERIFIED impl.gate.budgets
else
    t_skip assert.budget.absent_section "could not plant the fault: test/fixtures/impl_gate.txt no longer has a BUDGETS EXCEEDED heading"
fi

M="$(t_mutant "$SB" budget-never-fires)"
if t_replace_line "$M" ci/assert-stage.sh \
        '    elif awk '"'"'/^BUDGETS EXCEEDED/ { s=1; next } s && /^[A-Z]/ { exit } s && /^  - / { n++ } END { exit !(n>0) }'"'"' "$g"; then' \
        '    elif false; then'; then
    t_check_fail assert.budget.exceeded.mutation \
        "with the budget scan neutered, an exceeded budget is reported as 'no budget exceeded'" \
        as_gate "$M" "$BUDGET" impl 1 FAIL impl.gate.budgets
else
    t_skip assert.budget.exceeded.mutation "could not plant the fault: the BUDGETS EXCEEDED awk in assert_gate_file() has changed shape"
fi


#=============================================================================
# 6. A DELEGATION WITH NO NAMED OWNER FAILS
#
# "Somebody else measures this" with no somebody is how a thing comes to be
# measured by nobody. A delegation WITH an owner is reported and never red -
# that is the honesty mechanism, not a defect - so both halves are asserted:
# the check has to be able to tell them apart.
#=============================================================================
t_head "a delegation with no owner= fails; one with an owner is reported, not red"

UNOWNED="$(mkrun unowned)"
cp "$FIX/impl_gate_unowned.txt" "$UNOWNED/reports/impl_gate.txt"
t_check assert.delegated.unowned \
    "a DECLARED ELSEWHERE entry with no owner= is a FAIL" \
    as_gate "$FLOW_DIR" "$UNOWNED" impl 1 FAIL impl.gate.delegated.unowned
t_check assert.delegated.owned \
    "and the SAME section with owner= is a WARN on a run that still exits 0 - reported, never red" \
    as_gate "$FLOW_DIR" "$CLEAN" impl 0 WARN impl.gate.delegated

M="$(t_mutant "$SB" owner-not-required)"
if t_replace_line "$M" ci/assert-stage.sh \
        '        unowned="$(printf '"'"'%s\n'"'"' "$d" | grep -v '"'"'owner='"'"')"' \
        '        unowned=""'; then
    t_check_fail assert.delegated.unowned.mutation \
        "with the owner= test neutered, an unowned delegation passes and the assertion goes red" \
        as_gate "$M" "$UNOWNED" impl 1 FAIL impl.gate.delegated.unowned
else
    t_skip assert.delegated.unowned.mutation "could not plant the fault: the owner= filter in assert_gate_file() has changed shape"
fi


#=============================================================================
# 7. A MISSING VERDICT IS UNVERIFIED, NOT A PASS
#
# CONTRACT.md section 4 asks for a verdict artefact from impl and from no other
# stage, so the two cases are genuinely different and both must be visible:
# impl with no gate file is UNVERIFIED (which counts as a failure), and synth
# with no gate file is a SKIP CARRYING THE REASON. Neither is a pass.
#=============================================================================
t_head "a missing verdict artefact: UNVERIFIED for impl, a stated skip elsewhere"

NOGATE="$(mkrun no-gate)"
rm -f "$NOGATE/reports/impl_gate.txt"
t_check assert.verdict.missing \
    "impl with no impl_gate.txt is UNVERIFIED and the run exits 1 - nothing judged it" \
    as_gate "$FLOW_DIR" "$NOGATE" impl 1 UNVERIFIED impl.gate
t_check assert.verdict.missing.reason \
    "and the row says so in those words, so a reader is sent to the stage rather than to the design" \
    as_detail "$FLOW_DIR" "$NOGATE" impl impl.gate "That is UNVERIFIED, not passing"

SYNTH="$(mkrun synth-no-gate)"
cp "$FIX/impl_manifest.txt" "$SYNTH/reports/synth_manifest.txt"
head -c 128 /dev/zero > "$SYNTH/outputs/${BLOCK_NAME}_synth.dcp"
t_check assert.verdict.optional_stage \
    "a stage CONTRACT.md does not ask a verdict artefact from records a SKIP WITH THE REASON, never a silent pass" \
    as_detail "$FLOW_DIR" "$SYNTH" synth synth.gate "CONTRACT.md section 4 asks for a verdict artefact from impl only"

# THE MUTATION THAT MATTERS: ci_unverified demoted to a warning. Every gate that
# reports a missing input then goes green while measuring nothing - which is the
# exact failure ci/lib.sh's own header exists to forbid, seen from one layer up.
M="$(t_mutant "$SB" unverified-is-a-warning)"
if t_mutate "$M" ci/lib.sh '/^ci_unverified() {/,/^}/ s/CI_FAIL=/CI_WARN=/'; then
    t_check_fail assert.verdict.missing.mutation \
        "with ci_unverified counting as a WARN, a run with no verdict artefact at all exits 0 and the assertion goes red" \
        as_gate "$M" "$NOGATE" impl 1 UNVERIFIED impl.gate
else
    t_skip assert.verdict.missing.mutation "could not plant the fault: ci/lib.sh no longer has 'CI_FAIL=' inside ci_unverified()"
fi


#=============================================================================
# 8. THE EXIT CODES ARE THE ONES CONTRACT.md SECTION 10 FIXES
#
# 0 ok - 1 we looked and found something - 2 we could not look. The last two are
# the pair a caller is entitled to tell apart: 1 sends a reader to the design,
# 2 sends them to their own job configuration, and a script that reports a
# missing run directory as 1 sends them a very long way in the wrong direction.
#=============================================================================
t_head "exit codes: 0 ok, 1 a check failed, 2 refused"

## as_rc <toolkit> <run> <want> <args...>  - the run dir may be empty here
as_rc() {
    local tk="$1" run="$2" want="$3"; shift 3
    local rc=0 out
    out="$(stage_run "$tk" "$run" "$@")" || rc=$?
    [ "$rc" = "$want" ] && return 0
    printf 'exit %s, wanted %s, for: %s\n%s\n' "$rc" "$want" "$*" "$out"
    return 1
}

## as_rc_norun <toolkit> <want> <args...>  - NO run directory in the environment
as_rc_norun() {
    local tk="$1" want="$2"; shift 2
    local rc=0 out
    out="$(env -u FPGA_DIR -u FPGA_RUN_DIR -u FPGA_BLOCK -u RUN_DIR -u BLOCK \
               -u FPGA_SEAMS_FILE -u FPGA_REPORT_DIR -u FPGA_OUT_DIR -u FPGA_WORK_DIR \
               CI_VERDICT_DIR="$SB/norun-ci" CI_COLOUR=0 \
               "$tk/ci/assert-stage.sh" "$@" 2>&1)" || rc=$?
    [ "$rc" = "$want" ] && return 0
    printf 'exit %s, wanted %s, for: %s\n%s\n' "$rc" "$want" "$*" "$out"
    return 1
}

t_check assert.exit.1 \
    "a run with a failing gate exits 1 - we looked and found something" \
    as_rc "$FLOW_DIR" "$UNOWNED" 1 impl
t_check assert.exit.2.unknown_stage \
    "an unknown stage name is REFUSED (2), not judged" \
    as_rc "$FLOW_DIR" "$CLEAN" 2 route
t_check assert.exit.2.unknown_option \
    "an unusable option is refused (2)" \
    as_rc "$FLOW_DIR" "$CLEAN" 2 impl --no-such-flag
t_check assert.exit.2.two_stages \
    "two stages in one invocation is refused (2) - one stage at a time, and the second is not silently ignored" \
    as_rc "$FLOW_DIR" "$CLEAN" 2 impl synth
t_check assert.exit.2.no_run \
    "no run directory anywhere is REFUSED (2), never reported as a failed check - nothing is guessed" \
    as_rc_norun "$FLOW_DIR" 2 impl

M="$(t_mutant "$SB" any-stage-accepted)"
if t_replace_line "$M" ci/assert-stage.sh '    *" $STAGE "*) ;;' '    *) ;;'; then
    t_check_fail assert.exit.2.unknown_stage.mutation \
        "with the stage-name check neutered, 'route' falls through every arm and the run exits 0 having judged nothing" \
        as_rc "$M" "$CLEAN" 2 route
else
    t_skip assert.exit.2.unknown_stage.mutation "could not plant the fault: the stage-name case in assert-stage.sh has changed shape"
fi

M="$(t_mutant "$SB" run-dir-guessed)"
if t_replace_line "$M" ci/assert-stage.sh \
        'if [ -z "$RUN_DIR" ] || [ -z "$BLOCK" ]; then' \
        'if false; then'; then
    t_check_fail assert.exit.2.no_run.mutation \
        "with the refusal removed it asserts against an unresolved run and reports 1 - a red job pointing at the wrong file" \
        as_rc_norun "$M" 2 impl
else
    t_skip assert.exit.2.no_run.mutation "could not plant the fault: the run-directory refusal in assert-stage.sh has changed shape"
fi


#=============================================================================
# 9. THE STAGE LIST IS ONE LIST
#
# $STAGES feeds the argument check and --list, and the header says it feeds the
# help text too "so adding a stage cannot leave one of the three behind". The
# synopsis in that header is a HAND-WRITTEN copy of the same six names, so the
# third consumer can drift silently - and a hardcoded list that is merely
# INCOMPLETE still prints something plausible. That is the reference toolkit's
# five-entry whitelist over a seven-entry directory, in a smaller place.
#=============================================================================
t_head "--list, the argument check and the usage synopsis name the same stages"

## stages_agree <toolkit>
stages_agree() {
    local tk="$1" listed syn st rc
    listed="$("$tk/ci/assert-stage.sh" --list 2>/dev/null)"
    [ -n "$listed" ] || { echo "--list printed nothing"; return 1; }
    syn="$("$tk/ci/assert-stage.sh" --help 2>&1)"
    for st in $listed; do
        printf '%s' "$syn" | grep -qF -- "$st" \
            || { printf 'the usage synopsis does not mention the stage "%s", which --list offers\n' "$st"; return 1; }
        rc=0
        stage_run "$tk" "$SB/runs/clean" "$st" >/dev/null 2>&1 || rc=$?
        [ "$rc" = 2 ] && { printf 'stage "%s" is offered by --list and REFUSED by the argument check\n' "$st"; return 1; }
    done
    return 0
}

t_check assert.stages.agree \
    "every stage --list offers is accepted by the argument check and appears in the usage synopsis" \
    stages_agree "$FLOW_DIR"

M="$(t_mutant "$SB" seventh-stage)"
if t_replace_line "$M" ci/assert-stage.sh \
        'STAGES="flist package-ip bd synth impl bitstream"' \
        'STAGES="flist package-ip bd synth impl bitstream sim"'; then
    t_check_fail assert.stages.agree.mutation \
        "a SEVENTH stage in the list is not in the hand-written synopsis, and the assertion goes red - which is the drift this check exists for" \
        stages_agree "$M"
else
    t_skip assert.stages.agree.mutation "could not plant the fault: the STAGES assignment in assert-stage.sh has changed shape"
fi

#-----------------------------------------------------------------------------
# AN OPTION WITH NO OPERAND MUST REFUSE, NOT SPIN
#
# `shift 2` with one argument left FAILS and shifts nothing, so the argv loop
# never terminates: no verdict, no output, and a CI runner held until an
# external timeout kills it. That is worse than a wrong answer, because a job
# that never finishes produces no evidence about why.
#
# The same line existed in ci/tier.sh and ci/capability.sh and was fixed there
# on 2026-09-11; this one survived because nothing drove assert-stage's argument
# loop. It was found by reading, and this is the assertion that stops it coming
# back.
#
# DRIVEN UNDER `timeout`, and the timeout IS the assertion: a spin shows up as
# 124, which is neither the 2 this must return nor a pass.
#-----------------------------------------------------------------------------
t_head "an option with no operand refuses instead of spinning"

## no_operand_refuses <toolkit> - exit 2 within 5s, and SAY which option
no_operand_refuses() {
    local tk="$1" out rc=0
    out="$(timeout 5 "$tk/ci/assert-stage.sh" impl --fpga-dir 2>&1)" || rc=$?
    [ "$rc" -eq 2 ] || { printf 'exit %s, wanted 2 (124 = it spun)\n%s\n' "$rc" "$out"; return 1; }
    t_contains "$out" -- '--fpga-dir' || { printf 'refused without naming the option:\n%s\n' "$out"; return 1; }
    return 0
}

if ! command -v timeout >/dev/null 2>&1; then
    t_skip assert.argv.missing_operand \
        "no coreutils timeout on PATH - a spin would hang this suite instead of failing it, and an assertion that can hang the runner is worse than the one it guards"
else
    t_check assert.argv.missing_operand \
        "--fpga-dir with nothing after it exits 2 within 5s and names the option" \
        no_operand_refuses "$FLOW_DIR"

    M="$(t_mutant "$SB" argv-missing-operand)"
    if t_replace_line "$M" ci/assert-stage.sh \
            '        --fpga-dir) need_operand "$#" --fpga-dir "a project fpga/ directory"' \
            '        --fpga-dir) FPGA_PROJECT_DIR="${2:-}"; shift 2 ;; #'; then
        t_check_fail assert.argv.missing_operand.mutation \
            "with the guard removed the argv loop spins and the 5s timeout fires - the defect verbatim, as it stood before 2026-09-14" \
            no_operand_refuses "$M"
    else
        t_skip assert.argv.missing_operand.mutation \
            "could not plant the fault: the --fpga-dir arm of assert-stage.sh's argv loop has changed shape"
    fi
fi

t_summary

# Copyright (C) 2026, SoC Labs (www.soclabs.org)
