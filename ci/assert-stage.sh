#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# ci/assert-stage.sh - judge a finished stage from what is on disk, after the fact
#
#   ci/assert-stage.sh <flist|package-ip|bd|synth|impl|bitstream> \
#                      [--fpga-dir <project fpga dir>] [--optional] [--list]
#
# WHY THIS EXISTS WHEN mk/flow.mk ALREADY ASSERTS.
#
# It is a SECOND, INDEPENDENT implementation of the same predicates, and that is
# the point rather than an oversight. Three reasons, all of them about CI rather
# than about make:
#
#   1. make's assertions run in the same process as the stage. A job killed by a
#      timeout, a lost licence seat, a full filesystem or a rebooted runner
#      never reaches them - and the artefacts left behind are then judged by
#      nobody. An implementation is tens of minutes to hours; that window is not
#      hypothetical.
#   2. A stage run BY HAND - which is how most long runs actually happen - leaves
#      no record a later CI job can read. This reads the disk, so it does not
#      care who ran the stage, or when, or whether make was involved at all.
#   3. make prints prose and exits 1. CI needs a VERDICT PER GATE, named, so the
#      red job says `impl.gate.hard` and not `make: *** [impl] Error 1`. One
#      gate id sends a reader to one paragraph of one file; an exit status sends
#      them to a 40,000-line log.
#
# It launches no tool, takes no licence, and runs in well under a second.
#
# WHAT IT DOES NOT DO: RE-DERIVE THE TOOL'S OWN FINDINGS. The stage scripts have
# already parsed the reports and written their numbers into the manifest and
# their verdict into <stage>_gate.txt. Re-scraping Vivado's reports here would
# be a second, fuzzier opinion competing with the authoritative one - which is
# precisely the trap the reference project's stage reporter fell into, where a
# case-sensitive grep undercounted DRC by 7% for weeks and nothing disagreed
# with it. READ THE MANIFEST. If the manifest does not say, the answer is
# UNVERIFIED and somebody has to go and make the stage record it.
#
# --optional AND THE TWO STAGES THAT MAY LEGITIMATELY WRITE NOTHING.
#
# package-ip and bd run only when the project sets PACKAGE_TCL and BD_TCL. FROM
# DISK ALONE, a stage that was switched off and a stage that ran and died before
# writing anything look identical: an empty reports/ either way. ci/tier.sh
# passes --optional for exactly those two.
#
# This does not resolve that by assuming. It READS THE PROJECT'S CONTRACT - the
# same values make resolved - and skips with the reason as a FACT: "PACKAGE_TCL
# is empty, so this stage writes nothing". A stage that IS configured and left
# nothing behind still fails, --optional or not, because that is a real failure
# and laundering it into a skip is how a green run comes to prove nothing. Only
# when the contract cannot be reached at all does --optional fall back to a skip
# naming the ambiguity, and it says to pass --fpga-dir.
#
# THE DURABLE FIX IS NOT HERE. It is for EVERY STAGE TO WRITE ITS MANIFEST EVEN
# WHEN IT DOES NOTHING, recording that it did nothing and why. Then "the stage
# was off" is a fact on disk rather than an inference from an absence, this flag
# is unnecessary, and `make status` stops having to guess as well.
#
# Env:
#   FPGA_RUN_DIR, FPGA_BLOCK, ...   what mk/flow.mk exports. Used when present.
#   CI_VERDICT_DIR                  where verdicts.tsv lands (default <run>/ci)
#   CI_MAKE_ARGS                    extra arguments for the `make env` fallback
#
# Exit status:
#   0    every gate passed
#   1    at least one gate is FAIL or UNVERIFIED
#   2    refused: could not resolve the run, or an unusable argument
#   130  interrupted
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci/lib.sh
. "$HERE/lib.sh"

# The help text IS the header, sed'd out of this file (CONTRACT.md section 10),
# so it cannot drift from what the file does.
usage() { sed -n '3,68p' "$0" | sed 's/^# \{0,1\}//'; }

trap 'echo; echo "assert-stage: interrupted"; exit 130' INT

#-----------------------------------------------------------------------------
# THE STAGES ARE THE STAGE GRAPH, IN ITS ORDER (CONTRACT.md section 4).
#
# One list, used for the argument check, for --list and for the help text, so
# adding a stage cannot leave one of the three behind - the same rule the seam
# list and the step list follow.
#-----------------------------------------------------------------------------
STAGES="flist package-ip bd synth impl bitstream"

STAGE=""
FPGA_PROJECT_DIR=""
OPTIONAL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --fpga-dir) FPGA_PROJECT_DIR="${2:-}"; shift 2 ;;
        --optional) OPTIONAL=1; shift ;;
        # The split of $STAGES is the point here: one stage per line, from the
        # one list, so `--list` cannot disagree with the argument check below.
        --list)     for st in $STAGES; do printf '%s\n' "$st"; done; exit 0 ;;
        -h|--help)  usage; exit 0 ;;
        -*)         echo "assert-stage: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
        *)          if [ -n "$STAGE" ]; then
                        echo "assert-stage: one stage at a time, got '$STAGE' and '$1'" >&2; exit 2
                    fi
                    STAGE="$1"; shift ;;
    esac
done
[ -n "$STAGE" ] || { usage >&2; exit 2; }

case " $STAGES " in
    *" $STAGE "*) ;;
    *) echo "assert-stage: unknown stage '$STAGE'." >&2
       echo "  known: $STAGES" >&2
       exit 2 ;;
esac

#-----------------------------------------------------------------------------
# WHERE THE RUN IS
#
# Prefer the exported FPGA_* variables: mk/flow.mk exports them to every tool it
# launches, so a job that ran `make impl` already has them and they are
# GUARANTEED to be the values that run used. Fall back to asking make, which is
# the only thing that can resolve a `?=` chain plus per-invocation overrides.
#
# NEVER GUESS A PATH HERE. Guessing `build/default` when the run was
# RUN_TAG=nightly asserts against an empty directory and reports a missing
# bitstream for a bitstream that exists - a red job pointing at the wrong file
# is worse than no job at all.
#
# THE `make env` OUTPUT IS PARSED, NOT eval'd. Its second column is a project's
# values: paths with spaces are supported deliberately (mk/flow.mk section 2
# says so in as many words), and `eval` would split them - and would execute
# anything a project put in a variable. A path is data.
#-----------------------------------------------------------------------------
ENV_TEXT=""
env_val() {
    printf '%s\n' "$ENV_TEXT" | awk -v k="$1" \
        '$1 == k { sub(/^[ \t]*[^ \t]+[ \t]+/, ""); if ($0 == "(none)") $0 = ""; print; exit }'
}

# WHERE THE CONTRACT CAME FROM, recorded rather than assumed: a skip below says
# "PACKAGE_TCL is empty" only when something actually told us so. An empty
# variable in an environment that never carried it is not a value, it is an
# absence, and the two must not read the same.
#
# FPGA_SEAMS_FILE is the marker for "make exported its whole interface into this
# process": mk/flow.mk section 6 exports it on every tool invocation and it is
# never empty. Its presence means an empty FPGA_BD_TCL is a FACT.
CONTRACT_SOURCE="none"
[ -n "${FPGA_SEAMS_FILE:-}" ] && CONTRACT_SOURCE="the environment mk/flow.mk exported"

PROJ="${FPGA_PROJECT_DIR:-${FPGA_DIR:-}}"
if [ "$CONTRACT_SOURCE" = "none" ] && [ -n "$PROJ" ] && [ -f "$PROJ/Makefile" ]; then
    # shellcheck disable=SC2086
    ENV_TEXT="$(make -C "$PROJ" --no-print-directory env ${CI_MAKE_ARGS:-} 2>/dev/null)"
    [ -n "$ENV_TEXT" ] && CONTRACT_SOURCE="\`make env\` in $PROJ"
fi

RUN_DIR="${FPGA_RUN_DIR:-${RUN_DIR:-$(env_val RUN_DIR)}}"
BLOCK="${FPGA_BLOCK:-${BLOCK:-$(env_val BLOCK)}}"

if [ -z "$RUN_DIR" ] || [ -z "$BLOCK" ]; then
    {
      echo "assert-stage: no FPGA_RUN_DIR/FPGA_BLOCK in the environment, and no"
      echo "  project Makefile to ask. Either run this in the same job as the"
      echo "  stage - mk/flow.mk exports both - or pass --fpga-dir <project>/fpga."
      echo "  Nothing is guessed here: asserting against a guessed run directory"
      echo "  reports a missing artefact for an artefact that exists."
    } >&2
    exit 2
fi

DESIGN_NAME="${FPGA_DESIGN_NAME:-$(env_val DESIGN_NAME)}"
: "${DESIGN_NAME:=$BLOCK}"
RUN_TAG="${FPGA_RUN_TAG:-$(env_val RUN_TAG)}"
BD_TCL="${FPGA_BD_TCL:-$(env_val BD_TCL)}"
PACKAGE_TCL="${FPGA_PACKAGE_TCL:-$(env_val PACKAGE_TCL)}"

# The four run directories are DERIVED and not settable (CONTRACT.md 3.5), so
# composing them from RUN_DIR gives the same answer make does. The exported
# values are preferred anyway: one source beats two agreeing sources.
WORK="${FPGA_WORK_DIR:-$RUN_DIR/work}"
LOGS="${FPGA_LOG_DIR:-$RUN_DIR/logs}"
REP="${FPGA_REPORT_DIR:-$RUN_DIR/reports}"
OUT="${FPGA_OUT_DIR:-$RUN_DIR/outputs}"

CI_VERDICT_DIR="${CI_VERDICT_DIR:-$RUN_DIR/ci}"
ci_init
ci_head "assert stage '$STAGE' - $BLOCK, $RUN_DIR"

#-----------------------------------------------------------------------------
# MANIFEST COMPLETENESS
#
# Every stage script writes its manifest LAST (CONTRACT.md section 5), so the
# manifest existing is the cheapest strong evidence that the script reached its
# final section rather than dying in the middle with its earlier artefacts
# already on disk - which is the exact shape of a Vivado failure, since it exits
# 0 after a failed synth_design and leaves the checkpoint from whatever point it
# stopped at.
#
# Then the KEYS. A manifest whose values are all `unmeasured` is a manifest from
# a run that measured nothing, and it passes any existence check ever written.
#
# THE PER-STAGE KEY NAMES BELOW ARE AN INTERFACE PROPOSAL, NOT A DISCOVERY. At
# the time this file was written the stage scripts under flow/vivado/ did not
# exist. CONTRACT.md section 5 fixes the UNIVERSAL fields - stage, run_tag,
# tool, the two git shas, the directory block - and those are required here
# without apology. The measurement keys are this file's proposal to whoever
# writes the stage scripts: if their manifest spells one differently, THEIRS IS
# THE NAME and the table below changes. What must not happen is the gate being
# deleted because it went red: an unmeasured number is UNVERIFIED, and that is a
# failure with a fix, not noise.
#-----------------------------------------------------------------------------

## assert_manifest <stage> <manifest file> [required measurement key]...
assert_manifest() {
    local st="$1" f="$2"; shift 2
    if [ ! -s "$f" ]; then
        ci_fail "$st.manifest" \
            "no $f - the manifest is written last, so the stage script did not reach its final section whatever its exit status said. tail -40 $LOGS/$st.log"
        return 1
    fi
    ci_pass "$st.manifest" "$f"

    # The stage field, cross-checked. A manifest naming a different stage is a
    # file left over from an earlier run in this directory, or a copy-paste in a
    # stage script - and either way every number below it belongs to something
    # else. The run namespace is supposed to make this impossible, which is
    # exactly why it is worth testing rather than assuming.
    local ms; ms="$(ci_mf "$f" stage)"
    if [ -z "$ms" ]; then
        ci_warn "$st.manifest.stage" "the manifest records no 'stage' field (CONTRACT.md section 5 header)"
    elif [ "$ms" != "$st" ]; then
        ci_fail "$st.manifest.stage" \
            "the manifest at $f says stage '$ms', not '$st' - it is not this stage's manifest, so nothing read out of it describes this stage"
    fi

    # And the run tag, for the same reason one level up.
    local mt; mt="$(ci_mf "$f" run_tag)"
    if [ -n "$RUN_TAG" ] && [ -n "$mt" ] && [ "$mt" != "$RUN_TAG" ]; then
        ci_fail "$st.manifest.run_tag" \
            "the manifest says run_tag '$mt' and this run is '$RUN_TAG' - the reports directory holds another run's evidence"
    fi

    # tool/tool_version come from the tool's own query, which only answers
    # inside a real session. An unmeasured one means the manifest was written by
    # something that was not the tool.
    local tv; tv="$(ci_mf "$f" tool_version)"
    if ci_is_measured "$tv"; then
        ci_pass "$st.manifest.tool" "$(ci_mf "$f" tool) $tv"
    else
        ci_warn "$st.manifest.tool" \
            "tool_version is '${tv:-<absent>}' - the manifest cannot say which tool build produced this run, so nothing later can be compared against it by version"
    fi

    # Provenance. A dirty tree does not fail the run, but it means the recorded
    # sha does not describe it, so no comparison against that sha is reproducible.
    local pd td
    pd="$(ci_mf "$f" project_git_dirty)"; td="$(ci_mf "$f" toolkit_git_dirty)"
    if [ "$pd" = "yes" ] || [ "$td" = "yes" ]; then
        ci_warn "$st.provenance.dirty" \
            "project_git_dirty=$pd toolkit_git_dirty=$td - the recorded shas do not describe this run"
    elif [ -n "$(ci_mf "$f" project_git_sha)" ]; then
        ci_pass "$st.provenance" \
            "project $(ci_mf "$f" project_git_sha) toolkit $(ci_mf "$f" toolkit_git_sha)"
    else
        ci_unverified "$st.provenance" \
            "the manifest records no project_git_sha - CONTRACT.md section 5 requires both shas, and without them this run cannot be reproduced or compared"
    fi

    # The step files and the hooks that shaped the run. Not a pass/fail - a
    # record. `(none)` is a legitimate value and an ABSENT field is not: it means
    # the stage did not say, and a run shaped by project code that nothing wrote
    # down is a result nobody can trace.
    local sf hr
    sf="$(ci_mf "$f" step_files)"; hr="$(ci_mf "$f" hooks_run)"
    [ -n "$sf" ] && ci_say "$(printf '%-24s %s' step_files "$sf")"
    if [ -n "$hr" ]; then
        ci_say "$(printf '%-24s %s' hooks_run "$hr")"
    else
        ci_warn "$st.manifest.hooks_run" \
            "no hooks_run field - CONTRACT.md section 6.1 requires a hook's name and runtime to land in the manifest, so a result can be traced to the project code that shaped it"
    fi

    local k v miss=0
    for k in "$@"; do
        v="$(ci_mf "$f" "$k")"
        if ci_is_measured "$v"; then
            ci_say "$(printf '%-24s %s' "$k" "$v")"
        else
            ci_unverified "$st.manifest.$k" \
                "'$k' is '${v:-<absent>}' - either the stage measured nothing, or this file and the stage script disagree about the key name. Reconcile the two; do not delete the gate"
            miss=$((miss + 1))
        fi
    done
    [ "$miss" -eq 0 ] && ci_pass "$st.manifest.complete" "every required key carries a measurement"
    return 0
}

#-----------------------------------------------------------------------------
# THE STAGE VERDICT ARTEFACT (CONTRACT.md section 5)
#
# Fixed section structure, and four verdict classes:
#   HARD FAILURES: none                     the exact string, anchored
#   BUDGETS EXCEEDED                        a budget knob was passed
#   DECLARED ELSEWHERE ... owner=<who>      measured here, owned by somebody else
#   NOT covered by ANY run of this flow     the honesty mechanism
#
# ANCHORED, because an unanchored grep for `HARD FAILURES` matches the section
# HEADING and therefore passes on every gate file ever written - the same shape
# as a grep that matches the comment describing the thing it is looking for.
#
# The last two classes are why a green run is worth reading. A delegation with
# no named owner is not a delegation, it is a shrug, so it fails.
#-----------------------------------------------------------------------------
assert_gate_file() {   # assert_gate_file <stage> <gate file>
    local st="$1" g="$2"
    if [ ! -s "$g" ]; then
        ci_unverified "$st.gate" \
            "no verdict at $g - the stage did not reach its verdict section, so nothing has judged this run. That is UNVERIFIED, not passing"
        return 1
    fi
    ci_pass "$st.gate" "$g"

    CI_GREP_CONTEXT='^  - ' ci_assert_grep "$st.gate.hard" '^HARD FAILURES: none' "$g" \
        "the run is broken, not merely short of budget - the lines above name what"

    # BUDGETS EXCEEDED: entries are `  - ` bullets under the heading. A missing
    # heading is not a pass; it is a gate file that does not have the structure
    # section 5 fixes, and a reader cannot tell "no budget was exceeded" from
    # "budgets were never checked".
    if ! grep -q '^BUDGETS EXCEEDED' "$g"; then
        ci_unverified "$st.gate.budgets" \
            "$g has no BUDGETS EXCEEDED section - CONTRACT.md section 5 fixes the structure, and an absent section is not an empty one"
    elif awk '/^BUDGETS EXCEEDED/ { s=1; next } s && /^[A-Z]/ { exit } s && /^  - / { n++ } END { exit !(n>0) }' "$g"; then
        ci_fail "$st.gate.budgets" \
            "a budget was exceeded: $(awk '/^BUDGETS EXCEEDED/{s=1;next} s&&/^[A-Z]/{exit} s&&/^  - /{print}' "$g" | head -3 | tr '\n' ';')"\
            "Ratchet the EXPECT_* knob in design.mk WITH the measurement and the margin written beside it, or fix the design. Do not demote this gate in a CI configuration, where no run record ever reaches it"
    else
        ci_pass "$st.gate.budgets" "no budget exceeded"
    fi

    # DELEGATED WITH A NAMED OWNER. Reported, never red - but an entry with no
    # owner= is red, because "somebody else measures this" with no somebody is
    # how a thing comes to be measured by nobody.
    local d unowned
    d="$(awk '/^DECLARED ELSEWHERE/ { s=1; next } s && /^[A-Z]/ { exit } s && /^  - / { print }' "$g")"
    if [ -n "$d" ]; then
        unowned="$(printf '%s\n' "$d" | grep -v 'owner=')"
        if [ -n "$unowned" ]; then
            ci_fail "$st.gate.delegated.unowned" \
                "delegated with no named owner: $(printf '%s' "$unowned" | head -2 | tr '\n' ';')"
        else
            ci_warn "$st.gate.delegated" \
                "$(printf '%s\n' "$d" | grep -c .) finding(s) measured here and owned elsewhere - read them"
        fi
    fi

    # NOT COVERED. Printed, every time, on a PASSING run: it is the section
    # people stop reading once a build goes green, which is exactly when it
    # matters. An absent section fails; an empty one is a warning, because a run
    # that claims to cover everything is claiming something no run does.
    if ! grep -q '^NOT covered by ANY run' "$g"; then
        ci_unverified "$st.gate.notcovered" \
            "$g does not enumerate what this flow does not cover. CONTRACT.md section 5 requires it: a green run that lists nothing it failed to measure is the shape of a run nobody can audit"
    else
        local nc
        nc="$(awk '/^NOT covered by ANY run/ { s=1; next } s && /^[A-Z]/ { exit } s && /^  - / { print }' "$g")"
        if [ -z "$nc" ]; then
            ci_warn "$st.gate.notcovered" "the NOT-covered section is empty - no flow covers everything"
        else
            ci_pass "$st.gate.notcovered" "$(printf '%s\n' "$nc" | grep -c .) item(s) this run does not cover"
            printf '%s\n' "$nc" | sed 's/^/      /'
        fi
    fi
    return 0
}

## A stage other than impl has no gate file in the graph today (CONTRACT.md
## section 4 lists impl_gate.txt only). If one appears it is READ; if it does
## not, that is recorded as a skip WITH the reason and never as a pass.
assert_gate_optional() {
    local st="$1" g="$2"
    if [ -e "$g" ]; then
        assert_gate_file "$st" "$g"
    else
        ci_skip "$st.gate" \
            "no $g, and CONTRACT.md section 4 asks for a verdict artefact from impl only. This stage was judged on its artefacts and its manifest"
    fi
}

## A stage the project has switched off is a SKIP WITH THE REASON READ FROM THE
## CONFIGURATION - never a guess, and never a pass. Both optional stages are
## selected by a variable being non-empty, so when the contract is in reach the
## reason is a FACT rather than an inference from an absence of output.
##
## Returns 0 to mean "carry on and assert". Skips and exits otherwise.
stage_switched_off() {   # stage_switched_off <stage> <var name> <var value>
    local st="$1" var="$2" val="$3"
    [ -z "$val" ] || return 0          # configured ON: assert it, and mean it
    if [ "$CONTRACT_SOURCE" != "none" ]; then
        ci_skip "$st.stage" \
            "$var is empty in the contract resolved from $CONTRACT_SOURCE, so this stage writes nothing and is not expected to. Nothing was measured here"
    elif [ "$OPTIONAL" = 1 ]; then
        # The honest version of --optional: we could not read the contract, and
        # from disk a stage that was switched off is indistinguishable from one
        # that died before writing anything. Say which of those we cannot tell
        # apart, and how to make the answer knowable.
        ci_skip "$st.stage" \
            "--optional, and this project's contract could not be reached, so $var is unknown. From disk a stage that was switched off and one that died before writing anything are identical. Pass --fpga-dir <project>/fpga to turn this skip into a fact"
    else
        return 0                       # unknown and not optional: assert, and fail honestly
    fi
    ci_exit "assert-stage($STAGE)"
    exit $?
}

case "$STAGE" in

#-----------------------------------------------------------------------------
flist)
    # sources.tcl is what every later stage sources to get the design. Without
    # it synthesis reads an empty fileset and elaborates a black box, which
    # Vivado reports as a warning and which costs no LUTs - a design that looks
    # like it met every budget it has.
    ci_assert_file flist.sources "$WORK/sources.tcl" \
        "every later stage sources this to get the design; without it synthesis elaborates a black box and reports a warning"
    assert_manifest flist "$REP/flist_manifest.txt" file_count
    assert_gate_optional flist "$REP/flist_gate.txt"
    ;;

#-----------------------------------------------------------------------------
package-ip)
    stage_switched_off package-ip PACKAGE_TCL "$PACKAGE_TCL"
    # THE VLNV IS NOT KNOWABLE HERE. The directory under outputs/ip/ is named by
    # the vendor:library:name:version the packaging script chose, and computing
    # it here would be a second copy of a decision made in the layer best able to
    # make it. The claim this layer is entitled to is "at least one component.xml
    # exists"; the manifest records WHICH.
    if [ -n "$(find "$OUT/ip" -name component.xml -type f -print -quit 2>/dev/null)" ]; then
        ci_pass package-ip.component "$(find "$OUT/ip" -name component.xml -type f 2>/dev/null | head -1)"
    else
        ci_fail package-ip.component \
            "no component.xml anywhere under $OUT/ip - ipx::package_project logs its refusals as warnings and the tool still exits 0, so this is the only place it shows"
    fi
    # CONTRACT.md section 9.2: packaging DROPS fileset defines by three separate
    # routes, and did so silently for an entire FPGA build. Parameters survive as
    # CONFIG.*; defines do not. So what survived is a measurement, not a detail.
    assert_manifest package-ip "$REP/package_ip_manifest.txt" vlnv params_packaged
    assert_gate_optional package-ip "$REP/package_ip_gate.txt"
    ;;

#-----------------------------------------------------------------------------
bd)
    stage_switched_off bd BD_TCL "$BD_TCL"
    # DESIGN_NAME, not BLOCK: write_bd_tcl names the .bd after the block
    # design, and a project that renames its top module without renaming the BD
    # writes <old>.bd while every assertion looks for <new>.bd.
    ci_assert_file bd.design "$WORK/$DESIGN_NAME.bd" \
        "the block design the later stages open. DESIGN_NAME is '$DESIGN_NAME'"
    assert_manifest bd "$REP/bd_manifest.txt" bd_cells overlays_applied
    assert_gate_optional bd "$REP/bd_gate.txt"
    ;;

#-----------------------------------------------------------------------------
synth)
    ci_assert_file synth.checkpoint "$OUT/${BLOCK}_synth.dcp" \
        "implementation has no input. Vivado exits 0 after a failed synth_design, so the exit status said nothing"
    # THE FIRST PLACE AN ALMOST-EMPTY DESIGN SHOWS UP. A black-boxed module
    # costs no LUTs and raises no error, and a constraint that matched nothing is
    # dropped without one (CONTRACT.md section 9.3). A missing utilisation report
    # is UNVERIFIED, not a pass.
    ci_assert_file synth.utilisation "$REP/utilization_synth.rpt" \
        "a design that elaborated to almost nothing shows up here first, and nowhere else without a licence"
    assert_manifest synth "$REP/synth_manifest.txt" lut ff bram dsp
    assert_gate_optional synth "$REP/synth_gate.txt"
    ;;

#-----------------------------------------------------------------------------
impl)
    ci_assert_file impl.checkpoint "$OUT/${BLOCK}_routed.dcp" \
        "route_design returns 0 on a route it did not finish, so the checkpoint is the evidence and the exit status is not"
    ci_assert_file impl.timing "$REP/timing_summary.rpt" \
        "an implementation with no timing report has not been timed - that is UNVERIFIED, not a design that met timing"
    assert_manifest impl "$REP/impl_manifest.txt" wns whs unrouted_nets
    # The one stage CONTRACT.md section 4 requires a verdict artefact from.
    assert_gate_file impl "$REP/impl_gate.txt"

    #-------------------------------------------------------------------------
    # THE CROSS-CHECK: the manifest and the disk must agree about the routed
    # checkpoint. They are written by the same script seconds apart, so a
    # disagreement means the checkpoint landed after the manifest, or the
    # manifest is left over from an earlier run in this directory - which is the
    # failure a run namespace exists to make impossible, and therefore worth
    # proving rather than assuming.
    #-------------------------------------------------------------------------
    mb="$(ci_mf "$REP/impl_manifest.txt" dcp_bytes 2>/dev/null)"
    if [ -s "$OUT/${BLOCK}_routed.dcp" ] && ci_is_measured "$mb"; then
        db=$(stat -c %s "$OUT/${BLOCK}_routed.dcp" 2>/dev/null || echo 0)
        if [ "$mb" = "$db" ]; then
            ci_pass impl.dcp.consistent "$db bytes, manifest agrees"
        else
            ci_fail impl.dcp.consistent \
                "the manifest says dcp_bytes=$mb and the file on disk is $db bytes - they are not from the same run"
        fi
    fi
    ;;

#-----------------------------------------------------------------------------
bitstream)
    ci_assert_file bitstream.bit "$OUT/$BLOCK.bit" \
        "write_bitstream refuses a design with unrouted nets or unconstrained IO and says so as a DRC, not as an exit code"
    # .bin IS BOARD-FAMILY DEPENDENT (CONTRACT.md section 9.5): one family needs
    # a byte swap and another a header strip, the two are not interchangeable,
    # and the wrong one produces a file that loads and does not run - a board
    # that comes up dead with no error anywhere. So the .bin is asserted AND the
    # style that produced it is read out of the manifest.
    ci_assert_file bitstream.bin "$OUT/$BLOCK.bin" \
        "the .bin is what a running system loads"
    ci_assert_file bitstream.xsa "$OUT/$BLOCK.xsa" \
        "a software build reads this to learn the address map; without it the firmware and the fabric agree only by coincidence"
    assert_manifest bitstream "$REP/bitstream_manifest.txt" bin_style bit_bytes

    style="$(ci_mf "$REP/bitstream_manifest.txt" bin_style 2>/dev/null)"
    if ci_is_measured "$style"; then
        ci_pass bitstream.bin_style "$style"
    else
        ci_unverified bitstream.bin_style \
            "the manifest does not record which .bin conversion was used. BIN_STYLE is a REQUIRED board-pack key and an unset one is not a default - it is a conversion nobody chose"
    fi

    # THE FIRMWARE IS INSIDE THE BITSTREAM (CONTRACT.md section 4, bitstream):
    # the hex is read at elaboration and baked in, so a firmware change with no
    # bitstream rebuild changes nothing on the board and a rebuild with a stale
    # hex silently ships the old image. The manifest is the only record of which
    # image is in there, and it is only useful if it is present.
    fw="$(ci_mf "$REP/bitstream_manifest.txt" fpga_image_hex_sha256 2>/dev/null)"
    if ci_is_measured "$fw"; then
        ci_pass bitstream.firmware "image hash recorded: $fw"
    else
        ci_warn bitstream.firmware \
            "no fpga_image_hex_sha256 in the manifest - nothing records which firmware image is inside this bitstream, so the pair cannot be checked afterwards"
    fi

    mb="$(ci_mf "$REP/bitstream_manifest.txt" bit_bytes 2>/dev/null)"
    if [ -s "$OUT/$BLOCK.bit" ] && ci_is_measured "$mb"; then
        db=$(stat -c %s "$OUT/$BLOCK.bit" 2>/dev/null || echo 0)
        if [ "$mb" = "$db" ]; then
            ci_pass bitstream.consistent "$db bytes, manifest agrees"
        else
            ci_fail bitstream.consistent \
                "the manifest says bit_bytes=$mb and the file on disk is $db bytes - they are not from the same run"
        fi
    fi
    assert_gate_optional bitstream "$REP/bitstream_gate.txt"
    ;;
esac

ci_exit "assert-stage($STAGE)"
