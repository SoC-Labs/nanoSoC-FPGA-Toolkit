#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# t_tier.sh - the CI tier selector must never quietly select fewer checks
#
# DEFECT CLASS: A SELECTOR THAT SILENTLY SELECTS TOO FEW, AND IS THEN GREEN.
#
# ci/tier.sh decides WHICH checks a CI run performs. Everything downstream of
# that decision is a check that ran and passed; a check that was never selected
# leaves no trace of its own absence. So a selector that drops a tier - or
# selects nothing at all - produces a run in which every recorded gate passed,
# and the tier that did not run is indistinguishable from the tier that passed.
# That is the one result CONTRACT.md section 0 refuses to call a pass.
#
# It is the same shape as two failures this repository has already measured:
#   - test/run.sh counted FILES, so five suites that skipped themselves whole
#     read as five files that passed. The hole gate exists because of it.
#   - ci/lib.sh's verdict layer, where a gate that stopped counting a failure
#     would go green while measuring nothing. t_verdicts guards that.
#
# WHAT IS ASSERTED HERE IS SELECTION, NOT WHAT A TIER DOES. Every run below is
# pointed at an EMPTY project directory, so no tier can do real work: `make -C`
# fails in milliseconds, and no licence, no board and no Vivado are anywhere
# near this suite. What the suite reads is $CI_VERDICT_DIR/verdicts.tsv - one
# `tier.<name>` row per declared tier - and specifically its DETAIL column,
# because that is the only place the two kinds of "did not run" are
# distinguishable:
#
#   "not requested - 'X' was asked for"      the tier was NOT SELECTED
#   "X failed - a later tier's verdict ..."  it WAS selected, and the ladder
#                                            stopped at an earlier tier
#
# That distinction is the measurement. It separates "we chose not to run this"
# from "we could not", and it is independent of whether any tier passed - which
# is what lets this suite run on a laptop with no project and no tools.
#
# NO LIST OF TIERS APPEARS IN THIS FILE. CONTRACT.md's third rule - never
# hardcode a list a file or a directory already knows - applied to a test suite
# means the EXPECTED list has to be derived from the thing under test. It is
# taken from ci/tier.sh's own refusal message ("tier: name one of: ..."), which
# is the list the script tells a caller it will accept, and cross-checked
# against two independent derivations: the `run_tier` invocations in the file,
# and the tier block that `--help` prints. A suite carrying its own copy of the
# ladder would be the defect it is looking for, one level up.
#
# CI/CAPABILITY.SH IS COVERED AT THE END, and for one reason: it has the same
# hole in the same place. A label nobody declared has no recorded gaps, so
# `label_earned` answers YES for it - and exactly one line in the --require
# path stops a CI job being told it landed somewhere capable on the strength of
# a capability that does not exist anywhere in the declaration.
#
# Every assertion below is paired with a MUTATION PROOF: the same assertion,
# run against a copy of the toolkit with ONE fault planted, must go red. Each
# proof gets its OWN copy - a shared mutant accumulates faults, and the
# fifteenth proof then passes or fails for the first proof's reason, which this
# repository has already shipped once (see t_flow_utils.sh's header).
#
# THIS SUITE IS THE SLOW ONE, and the reason is worth knowing before somebody
# "optimises" it. Six of its runs select rung 1, which is the STATIC tier, and
# the static tier really runs - including test/shell/t_seams.sh, which is ten
# toolkit copies of its own. That is about fifteen seconds a run. It buys the
# only thing that matters here: the selection is measured on the real driver
# rather than on a re-implementation of it. Every other run is pointed at a
# rung whose make target fails in milliseconds.
#
# THREE OF THOSE SIX ARRIVED WITH THE TCL GATE, in section 6.1, and they are
# the price of judging a gate by what it put in the verdict file rather than by
# reading its source. Two of them exist to plant a fault and watch the
# assertion go red, which is the only evidence that the assertion can.
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
# A missing ci/tier.sh is a SKIP WITH THE REASON, never a pass. Several files
# in this repository are written concurrently, and a suite reporting green
# against a file that has not landed is reporting on nothing.
#-----------------------------------------------------------------------------
if [ ! -f "$FLOW_DIR/ci/tier.sh" ]; then
    t_skip tier.all "ci/tier.sh is not in this checkout at $FLOW_DIR/ci/tier.sh - there is no selector to drive, and an absent file is not a passing one"
    t_summary; exit $?
fi

#-----------------------------------------------------------------------------
# THE PROJECT EVERY RUN IS POINTED AT IS DELIBERATELY EMPTY.
#
# No Makefile, so every `make -C` the driver issues fails immediately and no
# tier can reach a tool. That is the point: this suite measures WHICH TIERS
# WERE SELECTED, and a tier's own verdict is irrelevant to that - a tier that
# was selected and failed and a tier that was selected and passed are both
# SELECTED, and they are both distinguishable from one that was never asked
# for. Giving this suite a real project would buy nothing and would make it
# need a part pack, a board pack and eventually a licence.
#-----------------------------------------------------------------------------
PROJ="$SB/project"
mkdir -p "$PROJ"

# A name that is not a tier and that contains NO regular-expression
# metacharacter. The distinction matters here - see the regex-shaped-name
# known defect below - so the plain case gets a plainly-spelled name.
NOT_A_TIER="no_such_tier"

# The environment every driven run gets. CI_* and FPGA_DIR inherited from
# whoever ran the suite would change what the driver does (CI_LABEL switches
# the host tier's implementation; CI_DEPLOY_TARGET makes the deploy tier run a
# make target; CI_APPEND stops ci_init truncating), so a suite that did not
# scrub them would measure the developer's shell.
TIER_ENV=(env -u FPGA_DIR -u RUN_TAG -u CI_APPEND -u CI_LANE -u CI_LABEL
          -u CI_CAPABILITY_CONF -u CI_DEPLOY_TARGET -u CI_MAKE_ARGS
          -u CI_SUMMARY_FILE -u GITHUB_STEP_SUMMARY -u GITHUB_RUN_NUMBER
          -u CI_PIPELINE_IID -u BUILD_NUMBER CI_COLOUR=0)

## vd_new - a fresh verdict directory. mktemp, not $RANDOM: t_check runs each
## predicate inside a command substitution, so two predicates that computed a
## name from $RANDOM can be handed the same number and would then read each
## other's verdict file.
vd_new() { mktemp -d "$SB/vdXXXXXXXX"; }

## climb <toolkit> <verdict dir> [args...]
## Runs that toolkit's ci/tier.sh against the empty project, with its verdicts
## in <verdict dir>, and prints everything it printed plus a trailing
## EXIT=<status> line - because the exit status is one of the things under test
## and `$?` does not survive a command substitution.
##
## `bash <path>` rather than executing it, for test/run.sh's reason: a copy that
## lost its execute bit, or a noexec /tmp, would otherwise be reported as a
## failing selector rather than as an environment problem.
##
## --fpga-dir comes FIRST so that a caller can pass a trailing `--fpga-dir`
## with no operand on purpose. That is one of the cases under test.
climb() {
    local dir="$1" vd="$2"; shift 2
    local rc=0 out
    local args=(--fpga-dir "$PROJ")
    [ "$#" -gt 0 ] && args+=("$@")
    out="$("${TIER_ENV[@]}" CI_VERDICT_DIR="$vd" RUN_TAG="t-tier-$(basename "$vd")" \
           bash "$dir/ci/tier.sh" "${args[@]}" 2>&1)" || rc=$?
    printf '%s\nEXIT=%d\n' "$out" "$rc"
}

## exit_of <climb output>
exit_of() { printf '%s\n' "$1" | sed -n 's/^EXIT=//p' | tail -1; }

## reported <verdict dir> - every tier the run recorded a row for, in order.
reported() {
    awk -F'\t' '$3 ~ /^tier\./ { sub(/^tier\./, "", $3); print $3 }' \
        "$1/verdicts.tsv" 2>/dev/null
}

## selected <verdict dir> - the tiers the run ASKED FOR, in order.
##
## THE DETAIL COLUMN IS THE DISCRIMINATOR, NOT THE VERDICT. run_tier records a
## SKIP either way; only the reason says which kind. "not requested" is
## ci/tier.sh's own wording for a tier the selection excluded, and every other
## reason - including "<tier> failed - a later tier's verdict would not mean
## anything" - belongs to a tier that WAS selected. If that wording ever
## changes, these assertions go red rather than quietly measuring nothing,
## which is the safe direction for a suite to break in.
selected() {
    awk -F'\t' '$3 ~ /^tier\./ && $4 !~ /^not requested/ { sub(/^tier\./, "", $3); print $3 }' \
        "$1/verdicts.tsv" 2>/dev/null
}

#-----------------------------------------------------------------------------
# THE THREE DERIVATIONS OF THE LADDER. None of them is a list in this file.
#-----------------------------------------------------------------------------

## ladder_names <toolkit> - the tiers the script SAYS it accepts, in order.
## Read from the refusal message, so it is what a caller is actually told, and
## it costs nothing: the refusal happens before any directory is created.
ladder_names() {
    bash "$1/ci/tier.sh" --fpga-dir "$PROJ" "$NOT_A_TIER" 2>&1 \
        | sed -n 's/^tier: name one of: *//p' | tr ' ' '\n' | grep -v '^[[:space:]]*$'
}

## wired_names <toolkit> - the tiers the ladder actually RUNS, in order.
## `^run_tier <name>` invocations. `run_tier() {` is excluded by requiring
## whitespace and a lower-case letter after the name of the function.
wired_names() {
    grep -E '^run_tier[[:space:]]+[a-z]' "$1/ci/tier.sh" | awk '{ print $2 }'
}

## help_names <toolkit> - the tiers `--help` DOCUMENTS, in order.
## The block that follows "tiers, cheapest first:" up to the first blank line;
## a tier's own line starts at column 5 and its continuation lines are indented
## further, which is what separates them.
help_names() {
    bash "$1/ci/tier.sh" --help 2>/dev/null \
        | awk '/^ *tiers, cheapest first:/ { blk = 1; next }
               blk && /^[[:space:]]*$/     { exit }
               blk && /^    [a-z][a-z0-9_]*  +[^ ]/ { print $1 }'
}

## regex_shaped_name <toolkit> - a name that is NOT a tier but that MATCHES one
## as a regular expression: the first tier with its last character replaced by
## `.`. Derived, so it stays a non-tier whatever the ladder is called.
regex_shaped_name() { ladder_names "$1" | head -1 | sed 's/.$/./'; }

#=============================================================================
# 0. THE LADDER IS DERIVABLE AT ALL
#
# Everything below compares one derivation of the tier list against another,
# so if the refusal message stops yielding a list there is nothing to compare
# and every later assertion would pass vacuously. This is the assertion that
# refuses to let that happen quietly.
#=============================================================================
t_head "the refusal message names the tiers, and that list is this suite's source of truth"

## ladder_is_derivable <toolkit>
ladder_is_derivable() {
    local names n bad
    names="$(ladder_names "$1")"
    n="$(printf '%s\n' "$names" | grep -c .)"
    if [ "$n" -lt 3 ]; then
        printf 'the refusal named %s tier(s). This suite derives every expectation from that\n' "$n"
        printf 'message, so with nothing in it there is nothing to compare anything against.\n'
        printf 'ci/tier.sh printed:\n%s\n' \
            "$(bash "$1/ci/tier.sh" --fpga-dir "$PROJ" "$NOT_A_TIER" 2>&1)"
        return 1
    fi
    bad="$(printf '%s\n' "$names" | grep -vE '^[a-z][a-z0-9_]*$')"
    [ -z "$bad" ] || { printf 'not a tier name (gate ids are lower case, CONTRACT.md 7): %s\n' "$bad"; return 1; }
    return 0
}

t_check tier.ladder.offered \
    "refusing an unknown tier NAMES the tiers it would have accepted" \
    ladder_is_derivable "$FLOW_DIR"

## tiers_line <toolkit> - the declaration line, read out of the file rather than
## written out here. A new tier must not silently stop these proofs planting.
tiers_line() { grep -m1 '^TIERS=' "$1/ci/tier.sh"; }

M="$(t_mutant "$SB" ladder-empty)"
if t_replace_line "$M" ci/tier.sh "$(tiers_line "$M")" 'TIERS=""'; then
    t_check_fail tier.ladder.offered.mutation \
        "with the ladder declared empty, the refusal names nothing and the assertion goes red" \
        ladder_is_derivable "$M"
else
    t_skip tier.ladder.offered.mutation "could not plant the fault: ci/tier.sh has no single-line TIERS= declaration any more"
fi

LADDER="$(ladder_names "$FLOW_DIR")"
N_TIERS="$(printf '%s\n' "$LADDER" | grep -c .)"
t_say "$N_TIERS tiers offered: $(printf '%s ' $LADDER)"

if [ "$N_TIERS" -lt 3 ]; then
    t_skip tier.all "ci/tier.sh's refusal message yielded $N_TIERS tier name(s) in THIS run (see tier.ladder.offered above, which is red). Every expectation in this suite is derived from that list and this suite will not invent one"
    t_summary; exit $?
fi

#=============================================================================
# 1. ONE LADDER, THREE DERIVATIONS, AND THEY MUST AGREE
#
# The list a caller is offered, the list the ladder runs, and the list --help
# documents are three independent copies inside one file. Two failure modes,
# both silent:
#
#   DECLARED BUT NOT WIRED  asking for that tier selects a prefix that ends at
#                           a rung nothing runs. Everything up to it passes,
#                           the tier itself is never mentioned, and the run is
#                           green having skipped exactly the check that was
#                           asked for.
#   WIRED BUT NOT DECLARED  should_run walks the DECLARED list, so a tier the
#                           ladder calls but the list does not name can never
#                           match: it records "not requested" on every run
#                           forever, including the run that asked for it.
#=============================================================================
t_head "the tiers offered, the tiers run and the tiers documented are one list"

## ladder_is_wired <toolkit>
ladder_is_wired() {
    local off wir missing extra
    off="$(ladder_names "$1" | sort)"
    wir="$(wired_names "$1" | sort)"
    missing="$(comm -23 <(printf '%s\n' "$off") <(printf '%s\n' "$wir"))"
    extra="$(comm -13 <(printf '%s\n' "$off") <(printf '%s\n' "$wir"))"
    if [ -n "$missing" ]; then
        printf 'DECLARED BUT NEVER RUN: %s\n' "$(printf '%s ' $missing)"
        printf 'ci/tier.sh offers that tier to a caller and no run_tier line runs it, so the\n'
        printf 'run that asks for it is green having done everything except it.\n'
        return 1
    fi
    if [ -n "$extra" ]; then
        printf 'RUN BUT NOT DECLARED: %s\n' "$(printf '%s ' $extra)"
        printf 'should_run walks the declared list, so this tier can never be selected: it\n'
        printf 'reports "not requested" on every run, including the one that asked for it.\n'
        return 1
    fi
    return 0
}

## ladder_order_is_the_run_order <toolkit>
ladder_order_is_the_run_order() {
    local off wir
    off="$(ladder_names "$1")"; wir="$(wired_names "$1")"
    [ "$off" = "$wir" ] && return 0
    printf 'the declared order and the run order differ.\n'
    printf 'DECLARED (what should_run walks to build a prefix):\n%s\n' "$off"
    printf 'RUN (the order the ladder actually climbs):\n%s\n' "$wir"
    printf 'The ladder is cheapest-first by contract: a prefix taken in one order and\n'
    printf 'executed in another runs a tier before the tier that produces its input, and\n'
    printf 'stops at the wrong rung when one fails.\n'
    return 1
}

## ladder_is_documented <toolkit>
ladder_is_documented() {
    local off doc
    off="$(ladder_names "$1")"; doc="$(help_names "$1")"
    if [ -z "$doc" ]; then
        printf '--help documents no tiers at all; the offered list is:\n%s\n' "$off"
        return 1
    fi
    [ "$off" = "$doc" ] && return 0
    printf 'OFFERED by the refusal:\n%s\nDOCUMENTED by --help:\n%s\n' "$off" "$doc"
    printf 'A tier that is accepted and undocumented is an extension point nobody knows\n'
    printf 'about; a tier that is documented and refused is an instruction that fails.\n'
    return 1
}

t_check tier.ladder.wired \
    "every tier offered has a run_tier, and every run_tier is offered" \
    ladder_is_wired "$FLOW_DIR"
t_check tier.ladder.order \
    "the ladder runs the tiers in the order it declares them" \
    ladder_order_is_the_run_order "$FLOW_DIR"
t_check tier.ladder.documented \
    "--help documents exactly the tiers the script accepts, in the same order" \
    ladder_is_documented "$FLOW_DIR"

# -- proofs, one fault per copy ----------------------------------------------
# The faults are DERIVED from each copy rather than written out here, so that
# adding a tenth tier cannot quietly stop a proof from planting.

## last_run_tier <toolkit> - the ladder's last invocation line
last_run_tier() { grep -E '^run_tier[[:space:]]+[a-z]' "$1/ci/tier.sh" | tail -1; }

M="$(t_mutant "$SB" ladder-unwired)"
if t_replace_line "$M" ci/tier.sh "$(last_run_tier "$M")" \
        '# planted fault: the ladder no longer runs this tier'; then
    t_check_fail tier.ladder.wired.mutation.unwired \
        "with a declared tier's run_tier deleted, the assertion goes red" \
        ladder_is_wired "$M"
else
    t_skip tier.ladder.wired.mutation.unwired "could not plant the fault: no 'run_tier <name>' line to delete in the copy"
fi

M="$(t_mutant "$SB" ladder-undeclared)"
if t_mutate "$M" ci/tier.sh 's/^\(TIERS="[a-z_ ]*\) [a-z_]*"$/\1"/'; then
    t_check_fail tier.ladder.wired.mutation.undeclared \
        "with the last tier dropped from TIERS while the ladder still runs it, the assertion goes red" \
        ladder_is_wired "$M"
else
    t_skip tier.ladder.wired.mutation.undeclared "could not plant the fault: the TIERS declaration is not a single quoted list of names"
fi

M="$(t_mutant "$SB" ladder-reordered)"
if t_mutate "$M" ci/tier.sh 's/^TIERS="\([a-z_]*\) \([a-z_]*\) /TIERS="\2 \1 /'; then
    t_check_fail tier.ladder.order.mutation \
        "with the first two rungs exchanged in TIERS only, the order assertion goes red" \
        ladder_order_is_the_run_order "$M"
else
    t_skip tier.ladder.order.mutation "could not plant the fault: the TIERS declaration is not a single quoted list of names"
fi

M="$(t_mutant "$SB" ladder-undocumented)"
DOC_T="$(ladder_names "$M" | tail -1)"
DOC_LINE="$(grep -m1 -E "^#     $DOC_T  +[^ ]" "$M/ci/tier.sh")"
if [ -n "$DOC_LINE" ] && t_replace_line "$M" ci/tier.sh "$DOC_LINE" \
        "$(printf '%s' "$DOC_LINE" | sed "s/^#     $DOC_T  */#     /")"; then
    t_check_fail tier.ladder.documented.mutation \
        "with one tier's name dropped from the --help block, the assertion goes red" \
        ladder_is_documented "$M"
else
    t_skip tier.ladder.documented.mutation "could not plant the fault: no '#     $DOC_T  ' line in the copy's --help block to take the name out of"
fi

#=============================================================================
# 2. A NAMED TIER SELECTS EXACTLY THE PREFIX UP TO IT, AND NOTHING ADJACENT
#
# `ci/tier.sh impl` runs static..impl. Both errors are silent and only one of
# them is ever noticed:
#
#   TOO FEW   the cheap tiers that were meant to run first do not, every gate
#             that did run passes, and the run is green. Nothing anywhere says
#             which checks were not performed - that is the defect class this
#             file exists for.
#   TOO MANY  the ladder does not stop at the rung asked for and walks on into
#             synthesis, implementation and a board. On this flow that is hours
#             of licence time a caller asked not to spend.
#
# RUNG 3 IS ASKED FOR, BY POSITION RATHER THAN BY NAME, so the assertion stays
# correct if the tiers are renamed. It is deep enough that the expected set has
# an inside and both edges, and shallow enough that the run touches no tool.
#=============================================================================
t_head "a named tier selects the prefix up to it - no more, no fewer"

RUNG=3

## prefix_selects_exactly <toolkit> <verdict dir>
prefix_selects_exactly() {
    local dir="$1" vd="$2" want expect got next row
    want="$(ladder_names "$dir" | sed -n "${RUNG}p")"
    [ -n "$want" ] || { printf 'this ladder has no rung %s to ask for\n' "$RUNG"; return 1; }
    climb "$dir" "$vd" "$want" > "$vd/.climb.log" 2>&1
    expect="$(ladder_names "$dir" | sed -n "1,${RUNG}p")"
    got="$(selected "$vd")"
    if [ "$got" != "$expect" ]; then
        printf 'asked for "%s" (rung %s). SELECTED:\n%s\nEXPECTED:\n%s\n' "$want" "$RUNG" "$got" "$expect"
        printf 'the run recorded:\n%s\n' "$(cut -f2,3,4 "$vd/verdicts.tsv" 2>/dev/null)"
        return 1
    fi
    # The rung immediately after the one asked for is where a fencepost error
    # lands, and it must be recorded as NOT REQUESTED - not left out, and not
    # skipped for some other reason that reads the same in a summary table.
    next="$(ladder_names "$dir" | sed -n "$((RUNG + 1))p")"
    [ -n "$next" ] || return 0
    row="$(awk -F'\t' -v g="tier.$next" '$3 == g { print $4; exit }' "$vd/verdicts.tsv" 2>/dev/null)"
    case "$row" in
        "not requested"*) return 0 ;;
        "") printf 'the rung after the one asked for (%s) has NO ROW AT ALL. A tier that is\n' "$next"
            printf 'absent from the report is indistinguishable from a tier that passed.\n'
            return 1 ;;
        *)  printf '%s was not asked for and its row does not say so: %s\n' "$next" "$row"; return 1 ;;
    esac
}

VD_PREFIX="$(vd_new)"
t_check tier.select.prefix \
    "asking for rung $RUNG selects rungs 1..$RUNG and records the rest as not requested" \
    prefix_selects_exactly "$FLOW_DIR" "$VD_PREFIX"

# THE DANGEROUS DIRECTION FIRST: the selector keeps only the tier asked for and
# drops every cheap tier before it. Every gate that runs then passes.
M="$(t_mutant "$SB" prefix-too-few)"
if t_replace_line "$M" ci/tier.sh '    for t in $TIERS; do' '    for t in $WANT; do'; then
    t_check_fail tier.select.prefix.mutation.too_few \
        "with the prefix collapsed to the named tier alone, the assertion goes red" \
        prefix_selects_exactly "$M" "$(vd_new)"
else
    t_skip tier.select.prefix.mutation.too_few "could not plant the fault: should_run no longer walks '\$TIERS' in a for loop"
fi

# AND THE OTHER DIRECTION: the ladder never stops, so a caller who asked for a
# licence-free tier gets synthesis, implementation and a board.
M="$(t_mutant "$SB" prefix-too-many)"
if t_replace_line "$M" ci/tier.sh '        [ "$t" = "$WANT" ] && return 1' \
        '        [ "$t" = "$WANT" ] && return 0'; then
    t_check_fail tier.select.prefix.mutation.too_many \
        "with the stop at the requested rung removed, the assertion goes red" \
        prefix_selects_exactly "$M" "$(vd_new)"
else
    t_skip tier.select.prefix.mutation.too_many "could not plant the fault: should_run's stop-at-WANT test has changed shape"
fi

#=============================================================================
# 3. EVERY DECLARED TIER IS REPORTED, IN EVERY RUN
#
# ci/tier.sh says so in its own header: a later tier is "recorded as a SKIP
# naming the tier that broke - never left silently absent, because a run that
# reports nine passes and nothing else looks exactly like a run that passed
# nine tiers". Nothing checked that until this assertion.
#=============================================================================
t_head "every declared tier has a row, whatever the run did"

## every_tier_reported <toolkit>
every_tier_reported() {
    local dir="$1" vd want rows names
    vd="$(vd_new)"
    want="$(ladder_names "$dir" | sed -n "${RUNG}p")"
    climb "$dir" "$vd" "$want" --only > "$vd/.climb.log" 2>&1
    names="$(ladder_names "$dir")"
    rows="$(reported "$vd")"
    [ "$rows" = "$names" ] && return 0
    printf 'the run recorded rows for:\n%s\nthe ladder declares:\n%s\n' "$rows" "$names"
    printf 'A declared tier with no row is a check nobody can see did not happen, and a\n'
    printf 'row out of order means the report is not the ladder.\n'
    return 1
}

t_check tier.select.every_tier_reported \
    "a --only run still records one row per declared tier, in ladder order" \
    every_tier_reported "$FLOW_DIR"

M="$(t_mutant "$SB" report-missing-tier)"
if t_replace_line "$M" ci/tier.sh "$(last_run_tier "$M")" \
        '# planted fault: this tier is never reached, so it reports nothing'; then
    t_check_fail tier.select.every_tier_reported.mutation \
        "with one tier's run_tier deleted, its row vanishes and the assertion goes red" \
        every_tier_reported "$M"
else
    t_skip tier.select.every_tier_reported.mutation "could not plant the fault: no 'run_tier <name>' line to delete in the copy"
fi

#=============================================================================
# 4. --only SELECTS EXACTLY ONE TIER, AND BEATS THE PREFIX
#
# PRECEDENCE IS THE PROPERTY. ci/tier.sh's header states it - "`ci/tier.sh
# impl` runs static..impl. `--only` runs the named tier alone, which is what a
# resumed job wants" - and a resumed job is exactly where getting it wrong is
# expensive: --only silently ignored re-runs hours of tiers that already
# passed, and --only selecting nothing re-runs none of them and says the resume
# succeeded.
#
# The LAST rung is asked for, by position, because the difference between the
# two readings is then the whole ladder rather than one tier.
#=============================================================================
t_head "--only runs the named tier alone"

## only_selects_one <toolkit>
only_selects_one() {
    local dir="$1" vd want got
    vd="$(vd_new)"
    want="$(ladder_names "$dir" | tail -1)"
    [ -n "$want" ] || { echo 'this ladder declares no tiers'; return 1; }
    climb "$dir" "$vd" "$want" --only > "$vd/.climb.log" 2>&1
    got="$(selected "$vd")"
    [ "$got" = "$want" ] && return 0
    printf 'asked for "%s" with --only. SELECTED:\n%s\n' "$want" "${got:-(nothing at all)}"
    printf 'the run recorded:\n%s\n' "$(cut -f2,3,4 "$vd/verdicts.tsv" 2>/dev/null)"
    return 1
}

t_check tier.select.only \
    "--only <last rung> selects that tier and nothing else" \
    only_selects_one "$FLOW_DIR"

# The dangerous reading: --only selects NOTHING. Every tier reports "not
# requested", no gate fails, and the resumed job exits 0.
M="$(t_mutant "$SB" only-selects-nothing)"
if t_replace_line "$M" ci/tier.sh \
        '    if [ "$ONLY" = 1 ]; then [ "$1" = "$WANT" ]; return; fi' \
        '    if [ "$ONLY" = 1 ]; then false; return; fi'; then
    t_check_fail tier.select.only.mutation.selects_nothing \
        "with --only selecting no tier at all, the assertion goes red" \
        only_selects_one "$M"
else
    t_skip tier.select.only.mutation.selects_nothing "could not plant the fault: should_run's --only branch has changed shape"
fi

# And the precedence reading: --only parsed but never acted on, so the prefix
# wins and a resume climbs the whole ladder again.
M="$(t_mutant "$SB" only-ignored)"
if t_replace_line "$M" ci/tier.sh '        --only)     ONLY=1; shift ;;' \
        '        --only)     ONLY=0; shift ;;'; then
    t_check_fail tier.select.only.mutation.ignored \
        "with --only parsed and ignored, the prefix wins and the assertion goes red" \
        only_selects_one "$M"
else
    t_skip tier.select.only.mutation.ignored "could not plant the fault: the --only argument is no longer parsed on one line"
fi

#=============================================================================
# 5. A NAME THAT IS NOT A TIER IS REFUSED, LOUDLY
#
# This is the hinge of the whole file. If an unusable tier name is accepted,
# the selection that follows is whatever the selector makes of nonsense - and
# the two outcomes it can produce are "run everything, including the tier that
# needs a board" and "run nothing and exit 0". The second is the one nobody
# notices.
#
# ci/README.md's exit table: 2 is "refused: unusable input", 1 is "at least one
# gate is FAIL". The difference is not cosmetic - 1 sends a reader to look for
# a broken design, 2 tells them the job was never asked for anything real.
#
# The runs below carry --only for one reason: with the refusal neutered by the
# planted fault, the driver would otherwise climb the entire ladder, and a
# proof must not cost a licence to demonstrate.
#=============================================================================
t_head "an unusable tier name is refused with exit 2, and nothing is recorded"

## refusal_is_clean <climb output> <verdict dir> <what was asked>
refusal_is_clean() {
    local out="$1" vd="$2" what="$3" rc
    rc="$(exit_of "$out")"
    if [ "$rc" != 2 ]; then
        printf 'asked for %s and got exit %s, not 2.\n' "$what" "$rc"
        printf 'ci/README.md reserves 2 for "refused: unusable input"; 1 would send a reader\n'
        printf 'looking for a broken design and 0 would report a run that never happened.\n%s\n' "$out"
        return 1
    fi
    if ! t_contains "$out" "tier: name one of:"; then
        printf 'the refusal does not name the tiers it would have accepted:\n%s\n' "$out"
        return 1
    fi
    if [ -e "$vd/verdicts.tsv" ]; then
        printf 'a REFUSED invocation still wrote a verdict file, so something ran:\n%s\n' \
            "$(cut -f2,3,4 "$vd/verdicts.tsv")"
        return 1
    fi
    return 0
}

## unknown_name_refused <toolkit>
unknown_name_refused() {
    local dir="$1" vd out
    vd="$(vd_new)"
    out="$(climb "$dir" "$vd" "$NOT_A_TIER" --only)"
    refusal_is_clean "$out" "$vd" "'$NOT_A_TIER'"
}

## no_name_refused <toolkit> - no tier named at all
no_name_refused() {
    local dir="$1" vd out
    vd="$(vd_new)"
    out="$(climb "$dir" "$vd" --only)"
    refusal_is_clean "$out" "$vd" "nothing at all"
}

t_check tier.refuse.unknown \
    "a name that is not a tier is refused: exit 2, the legal tiers named, no verdict file" \
    unknown_name_refused "$FLOW_DIR"
t_check tier.refuse.no_name \
    "naming no tier at all is refused the same way, rather than defaulting to something" \
    no_name_refused "$FLOW_DIR"

# Both proofs plant the SAME edit - the membership test that refuses - because
# it is the only thing that refuses either case: the `-z "$WANT"` clause on its
# own does not, since an empty name also fails the membership test. Each gets
# its own copy anyway, so that neither proof can pass or fail for the other's
# reason.
#
# THE LINE IS READ FROM THE FILE UNDER TEST rather than written out here. A
# copy of it in this file is a copy that goes stale: the membership test was
# rewritten once already - it used to be a regex match, see section 6 - and a
# literal here would have turned both proofs into skips at that moment, leaving
# the two assertions above standing with nothing behind them. What this file
# states is the SHAPE the guard must have, which is all it needs to find it.
GUARD_LINE="$(grep -m1 -E '^if \[ -z "\$WANT" \] \|\|' "$FLOW_DIR/ci/tier.sh")"

M="$(t_mutant "$SB" refuse-nothing-unknown)"
if t_replace_line "$M" ci/tier.sh "$GUARD_LINE" 'if false; then'; then
    t_check_fail tier.refuse.unknown.mutation \
        "with the membership test neutered, an unknown name is accepted and the assertion goes red" \
        unknown_name_refused "$M"
else
    t_skip tier.refuse.unknown.mutation "could not plant the fault: the tier-name membership test has changed shape"
fi

M="$(t_mutant "$SB" refuse-nothing-empty)"
if t_replace_line "$M" ci/tier.sh "$GUARD_LINE" 'if false; then'; then
    t_check_fail tier.refuse.no_name.mutation \
        "with the same test neutered, naming no tier is accepted and the assertion goes red" \
        no_name_refused "$M"
else
    t_skip tier.refuse.no_name.mutation "could not plant the fault: the tier-name membership test has changed shape"
fi

#=============================================================================
# 6. THE ARGUMENT SURFACE, AND THE FOUR HOLES IT USED TO HAVE
#
# Everything in this section arrived as a t_known_defect - an assertion this
# suite believed was correct and that ci/tier.sh did not satisfy - and became a
# real assertion with a planted fault behind it on 2026-09-14, when the driver
# was fixed. The measurements are kept, because what each assertion catches is
# only legible from the shape of what it caught.
#
# THE ROOT OF THE FIRST TWO WAS ONE LINE. The name was ACCEPTED by a regular
# expression - `printf '%s' " $TIERS " | grep -q " $WANT "` - and then SELECTED
# by string equality (`[ "$t" = "$WANT" ]`). Any name that matched as a regex
# and equalled no tier passed the gate and then matched no rung. With --only
# that selected NOTHING: nine "not requested" rows, no failing gate, "All
# recorded gates passed", exit 0. Without --only it selected EVERYTHING,
# because the walk that stops the prefix never found its stopping point - so
# `tier.sh 'stati.'` climbed all the way to deploy. A typo, a shell glob that
# got expanded, or a CI variable that arrived with a stray character reaches
# both. Acceptance is now the same equality the selection performs, and both
# proofs below plant the regex back.
#
# THE OTHER TWO ARE THE ARGUMENT LOOP ITSELF. An option whose operand was
# missing ended in `shift 2`, which FAILS with one argument left and shifts
# nothing - so the loop saw the same option again, forever, and the job held a
# runner until an external timeout killed it with no verdict at all. And a
# second tier name was overwritten in silence, so `tier.sh static deploy` ran
# DEPLOY: the caller asked for seconds of text checks and got the tier that
# needs hardware, with nothing anywhere saying a name had been dropped.
#
# ALL FOUR REFUSE WITH EXIT 2 rather than failing a gate. ci/README.md's table
# reserves 2 for "refused: unusable input", and the difference is what the
# reader does next: 1 sends them to look for a broken design, 2 tells them the
# job was never asked for anything real.
#=============================================================================
t_head "a name the selector cannot use is refused, and no name is dropped"

## regex_name_is_refused <toolkit>
regex_name_is_refused() {
    local dir="$1" vd out rc name sel
    name="$(regex_shaped_name "$dir")"
    vd="$(vd_new)"
    out="$(climb "$dir" "$vd" "$name" --only)"
    rc="$(exit_of "$out")"
    [ "$rc" = 2 ] && return 0
    sel="$(selected "$vd" | tr '\n' ' ')"
    printf 'ci/tier.sh accepted "%s", which is not one of its tiers: exit %s.\n' "$name" "$rc"
    printf 'it selected: %s\n' "${sel:-(nothing at all)}"
    return 1
}

## empty_selection_is_never_green <toolkit>
empty_selection_is_never_green() {
    local dir="$1" vd out rc sel name
    name="$(regex_shaped_name "$dir")"
    vd="$(vd_new)"
    out="$(climb "$dir" "$vd" "$name" --only)"
    rc="$(exit_of "$out")"
    [ "$rc" != 0 ] && return 0
    sel="$(selected "$vd")"
    [ -n "$sel" ] && return 0
    printf 'EXIT=0 AND NOT ONE TIER RAN. The run recorded:\n%s\n' \
        "$(cut -f2,3,4 "$vd/verdicts.tsv" 2>/dev/null)"
    printf 'and told the reader "All recorded gates passed".\n'
    return 1
}

## second_tier_name_is_refused <toolkit>
second_tier_name_is_refused() {
    local dir="$1" vd out rc first last
    first="$(ladder_names "$dir" | head -1)"
    last="$(ladder_names "$dir" | tail -1)"
    vd="$(vd_new)"
    # The cheap rung is named LAST on purpose: if the last name silently wins,
    # this costs milliseconds. A defect must not cost a licence to demonstrate.
    out="$(climb "$dir" "$vd" "$first" "$last" --only)"
    rc="$(exit_of "$out")"
    [ "$rc" = 2 ] && return 0
    printf '%s\n' "$out" | grep -qiE 'ignor|only one tier|more than one tier' && return 0
    printf 'asked for "%s" AND "%s": exit %s, selected "%s".\n' \
        "$first" "$last" "$rc" "$(selected "$vd" | tr '\n' ' ')"
    printf 'One of the two names was discarded and nothing anywhere says which, so a\n'
    printf 'caller that meant the first one gets a green run of a different set of checks.\n'
    return 1
}

t_check tier.refuse.regex_name \
    "a name that is not a tier but MATCHES one as a regular expression is refused" \
    regex_name_is_refused "$FLOW_DIR"

t_check tier.select.empty_is_never_green \
    "no invocation both selects zero tiers and exits 0 - a run that measured nothing is never green" \
    empty_selection_is_never_green "$FLOW_DIR"

t_check tier.argv.second_name \
    "a second tier name is refused, naming both, rather than one of them winning in silence" \
    second_tier_name_is_refused "$FLOW_DIR"

# -- proofs, one fault per copy ----------------------------------------------
# The first two plant THE SAME historical fault - acceptance by regex, over a
# selection by equality - in two copies, because it is the one line that
# produced both symptoms and the two assertions catch different halves of it:
# one that the name is refused at all, one that whatever happens next is not a
# green run of nothing.
REGEX_GUARD='if [ -z "$WANT" ] || ! printf '"'"'%s'"'"' " $TIERS " | grep -q " $WANT "; then'

M="$(t_mutant "$SB" accept-by-regex)"
if [ -n "$GUARD_LINE" ] && t_replace_line "$M" ci/tier.sh "$GUARD_LINE" "$REGEX_GUARD"; then
    t_check_fail tier.refuse.regex_name.mutation \
        "with acceptance back to a regex match over a selection by equality, a regex-shaped non-tier is accepted and the assertion goes red" \
        regex_name_is_refused "$M"
else
    t_skip tier.refuse.regex_name.mutation "could not plant the fault: no single-line 'if [ -z \"\$WANT\" ] || ...' acceptance test in the copy to replace"
fi

M="$(t_mutant "$SB" accept-by-regex-green)"
if [ -n "$GUARD_LINE" ] && t_replace_line "$M" ci/tier.sh "$GUARD_LINE" "$REGEX_GUARD"; then
    t_check_fail tier.select.empty_is_never_green.mutation \
        "with the same fault planted, --only on that name selects no tier at all and exits 0, and the assertion goes red" \
        empty_selection_is_never_green "$M"
else
    t_skip tier.select.empty_is_never_green.mutation "could not plant the fault: no single-line 'if [ -z \"\$WANT\" ] || ...' acceptance test in the copy to replace"
fi

# THE SECOND-NAME ARM, read out of the file for the reason GUARD_LINE is: the
# fault to plant is the line as it was BEFORE the fix, which is written out
# here, but the line to replace is whatever the driver says today.
NAME_ARM="$(grep -m1 -F -- 'refuse_second_name "$WANT"' "$FLOW_DIR/ci/tier.sh")"

M="$(t_mutant "$SB" second-name-wins)"
if [ -n "$NAME_ARM" ] && t_replace_line "$M" ci/tier.sh "$NAME_ARM" \
        '        *)          WANT="$1"; shift ;;'; then
    t_check_fail tier.argv.second_name.mutation \
        "with the second name overwriting the first again, two names run one of them in silence and the assertion goes red" \
        second_tier_name_is_refused "$M"
else
    t_skip tier.argv.second_name.mutation "could not plant the fault: the positional arm of the argument loop no longer refuses a second name on one line"
fi

## fpga_dir_without_operand_is_refused <toolkit>
## `--fpga-dir` with nothing after it. It used to `shift 2`, and a `shift 2`
## with one argument left fails and shifts NOTHING, so the argument loop spun
## forever: the job burned a runner until somebody's timeout killed it, and
## reported no verdict at all. THE TIMEOUT IS PART OF THE ASSERTION - without
## it the proof below would hang this suite instead of failing it, and 124 is
## graded as its own answer so a red line says "it never returned" rather than
## the unrelated "it exited 124".
fpga_dir_without_operand_is_refused() {
    local dir="$1" rc=0 want
    want="$(ladder_names "$dir" | tail -1)"
    timeout 5 "${TIER_ENV[@]}" CI_VERDICT_DIR="$(vd_new)" RUN_TAG="t-tier-operand" \
        bash "$dir/ci/tier.sh" "$want" --only --fpga-dir >/dev/null 2>&1 || rc=$?
    [ "$rc" = 2 ] && return 0
    if [ "$rc" = 124 ]; then
        printf 'it had not terminated after 5 seconds.\n'
        return 1
    fi
    printf 'exit %s, not 2 (refused: unusable input)\n' "$rc"
    return 1
}

if command -v timeout >/dev/null 2>&1; then
    t_check tier.argv.missing_operand \
        "--fpga-dir with no operand is refused (exit 2) instead of spinning the argument loop" \
        fpga_dir_without_operand_is_refused "$FLOW_DIR"

    # The fault planted is the line as it stood before the fix, verbatim. The
    # proof therefore measures the defect itself rather than some other way of
    # reaching a non-zero exit: the mutant does not refuse, does not fail, and
    # does not return - t_check_fail sees the assertion go red on a 5-second
    # timeout, which is exactly what CI saw for as long as the line was there.
    FPGA_DIR_ARM="$(grep -m1 -F -- '--fpga-dir) need_operand' "$FLOW_DIR/ci/tier.sh")"
    M="$(t_mutant "$SB" fpga-dir-shift2)"
    if [ -n "$FPGA_DIR_ARM" ] && t_replace_line "$M" ci/tier.sh "$FPGA_DIR_ARM" \
            '        --fpga-dir) FPGA_PROJECT="${2:-}"; shift 2 ;;'; then
        t_check_fail tier.argv.missing_operand.mutation \
            "with the operand check removed and the bare 'shift 2' back, the loop never terminates and the assertion goes red" \
            fpga_dir_without_operand_is_refused "$M"
    else
        t_skip tier.argv.missing_operand.mutation "could not plant the fault: the --fpga-dir arm of the argument loop no longer checks its operand on one line"
    fi
else
    t_skip tier.argv.missing_operand "no coreutils timeout on this host, and the case under test is a script that never returns - running it without a timeout would hang this suite"
    t_skip tier.argv.missing_operand.mutation "no coreutils timeout on this host, and the fault this proof plants is the non-terminating loop itself - it would hang this suite rather than fail it"
fi

#=============================================================================
# 6.1 AND ONE DEFECT INSIDE A TIER, FOUND BY RUNNING IT.
#
# The static tier claims to check that Tcl files balance "via `info complete`".
# It piped a one-line script into `tclsh - "$f"` - and a standard tclsh does
# not consume that `-`: it reads the script from stdin and leaves argv as
# `{- <file>}`, so `[lindex $argv 0]` was the DASH. Every open failed, the
# one-liner exited 2 - its OWN "could not read" code - and the caller graded
# every non-zero as unbalanced. The tier reported every .tcl file in the
# toolkit as having "unbalanced braces/brackets/quotes", which meant the static
# tier COULD NOT PASS on any host that had a tclsh. A false RED rather than a
# false green, which is the better direction to fail in - but also a gate
# stating a specific finding about a file it never opened, which is CONTRACT.md
# rule two.
#
# FIXED 2026-09-14, and in two parts, because the second is the one that keeps
# it fixed: the reader is a FILE passed to tclsh by name, and it answers in
# THREE states - balances, does not balance, could not be read. The third is
# what the gate had no word for, and a gate with no word for "I could not look"
# has to borrow one from "I looked and it is broken".
#
# Both halves are asserted here, on the verdict file rather than on the source:
#   tier.static.tcl_gate             what it reports agrees, file for file and
#                                    count for count, with an independent
#                                    reader over the same file set
#   tier.static.tcl_gate.unreadable  a .tcl that cannot be OPENED is reported
#                                    as unread, and never as a syntax finding
#
# Judged against a SECOND, INDEPENDENT implementation of the same check,
# written here, for the reason ci/README.md gives for assert-stage.sh existing
# beside make's own assertions: a claim checked only by the thing that made it
# is not checked.
#=============================================================================
t_head "the static tier's Tcl gate reports what it read, and only what it read"

# The independent reader. Its exit codes are the three states above.
#
# BE PRECISE ABOUT WHAT IT IS INDEPENDENT OF. It asks Tcl the same question the
# gate does, deliberately - if `info complete` is the wrong question, this pair
# agrees and is wrong together, and nothing here would notice. What it does not
# share with the gate is how the file is handed to tclsh and how the answer is
# graded, and that is where every defect in this section lived: a file name
# that never reached the script, and a read failure graded as a syntax finding.
cat > "$SB/complete.tcl" <<'TCL'
set f [lindex $argv 0]
if {[catch {set c [open $f]}]} { exit 3 }
set d [read $c]
close $c
exit [expr {[info complete $d] ? 0 : 1}]
TCL

## tcl_roots <toolkit> - the directories the gate searches for .tcl files.
##
## READ OUT OF ci/tier.sh's own `find`, never copied into this file: comparing
## the gate against a DIFFERENT set of files than it looked at would produce a
## disagreement that is this suite's fault, and - the direction that matters -
## a suite whose list had gone short would agree with the gate about files
## neither of them read.
tcl_roots() {
    local dir="$1"
    # The find spans two lines: the roots, then `-name '*.tcl' -type f`. Keep a
    # one-line window and print it when the second line arrives.
    awk '{ win = prev "\n" $0; prev = $0 }
         /-name .\*\.tcl./ { print win; exit }' "$dir/ci/tier.sh" \
        | grep -o '[$]FLOW_DIR/[A-Za-z0-9_]*' \
        | sed 's|^[$]FLOW_DIR/||' \
        | while IFS= read -r r; do [ -n "$r" ] && printf '%s/%s\n' "$dir" "$r"; done
}

## tcl_files <toolkit> - every .tcl file the gate would have found, sorted.
tcl_files() {
    local dir="$1" r
    local -a roots=()
    while IFS= read -r r; do
        [ -n "$r" ] && [ -d "$r" ] && roots+=("$r")
    done < <(tcl_roots "$dir")
    [ "${#roots[@]}" -gt 0 ] || return 1
    find "${roots[@]}" -name '*.tcl' -type f 2>/dev/null | sort
}

## static_climb <toolkit> - run RUNG 1 alone and print the verdict directory.
## Rung 1 BY POSITION, never by name: no list of tiers appears in this file.
static_climb() {
    local dir="$1" vd
    vd="$(vd_new)"
    climb "$dir" "$vd" "$(ladder_names "$dir" | head -1)" --only > "$vd/.climb.log" 2>&1
    printf '%s' "$vd"
}

## tcl_gate_row <verdict dir> - the gate's row, or nothing.
tcl_gate_row() {
    awk -F'\t' '$3 == "static.tcl.complete" { print; exit }' "$1/verdicts.tsv" 2>/dev/null
}

## tcl_gate_agrees_with_tclsh <verdict dir of a run that included rung 1> <toolkit>
tcl_gate_agrees_with_tclsh() {
    local vd="$1" dir="$2" row status detail f irc n=0 bad="" unread="" said
    row="$(tcl_gate_row "$vd")"
    [ -n "$row" ] || {
        printf 'no static.tcl.complete row in that run. The gate either did not run or no\n'
        printf 'longer records under that id, and either way nothing here is measuring it.\n'
        return 1; }
    status="$(printf '%s\n' "$row" | cut -f2)"
    detail="$(printf '%s\n' "$row" | cut -f4)"

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        n=$((n + 1))
        irc=0
        tclsh "$SB/complete.tcl" "$f" >/dev/null 2>&1 || irc=$?
        case "$irc" in 0) ;; 1) bad="$bad $f" ;; *) unread="$unread $f" ;; esac
    done < <(tcl_files "$dir")

    if [ "$n" -eq 0 ]; then
        printf 'the independent reader found no .tcl file under the roots ci/tier.sh searches\n'
        printf '(%s), so there is nothing here to compare the gate against.\n' "$(tcl_roots "$dir" | tr '\n' ' ')"
        return 1
    fi

    if [ -z "$bad" ] && [ -z "$unread" ]; then
        # Every file opened and every one balances, so the gate has exactly one
        # correct answer - and the COUNT is part of that answer. A gate that
        # passes having read three files out of twenty-one is the same defect
        # wearing a green badge, and the count is the only place it shows.
        if [ "$status" != "PASS" ]; then
            printf 'an independent [info complete] opened all %d .tcl file(s) the gate searches\n' "$n"
            printf 'and every one of them BALANCES. The gate recorded %s: %s\n' "$status" "$detail"
            return 1
        fi
        said="$(printf '%s' "$detail" | sed -n 's/^\([0-9][0-9]*\) file(s).*/\1/p')"
        if [ "$said" != "$n" ]; then
            printf 'the gate passed, and says it checked %s of the %d file(s) that are there: %s\n' \
                "${said:-no number at all}" "$n" "$detail"
            return 1
        fi
        return 0
    fi

    # This checkout really does have a bad .tcl in it. The gate must then have
    # found the SAME thing and said so in the right words - an unopenable file
    # reported as unread, an unbalanced one as unbalanced, never one dressed as
    # the other.
    for f in $unread $bad; do
        t_contains "$detail" "$f" || {
            printf 'an independent reader has something to say about %s and the gate does not\n' "$f"
            printf 'mention it at all: %s\n' "$detail"
            return 1; }
    done
    if [ -n "$unread" ] && [ "$status" != "UNVERIFIED" ]; then
        printf 'a .tcl file could not be opened, and the gate recorded %s rather than UNVERIFIED.\n' "$status"
        printf 'Missing evidence is not a finding: %s\n' "$detail"
        return 1
    fi
    if [ -z "$unread" ] && [ "$status" != "FAIL" ]; then
        printf 'a .tcl file does not balance, and the gate recorded %s: %s\n' "$status" "$detail"
        return 1
    fi
    return 0
}

## plant_unreadable_tcl <toolkit copy> - print the path of a .tcl in it that
## cannot be opened, or fail if this host will not let one exist.
##
## THE CONTENT BALANCES. If anything ever opens the file the gate must pass, so
## the word "unbalanced" can only reach the verdict by the conflation this pair
## of assertions is about. This is a planted CONDITION, not a planted fault:
## both the assertion and its proof get one, and only the proof gets a fault.
plant_unreadable_tcl() {
    local dir="$1" root f
    root="$(tcl_roots "$dir" | head -1)"
    [ -n "$root" ] && [ -d "$root" ] || return 1
    f="$root/unreadable_by_construction.tcl"
    printf 'puts "this file balances; the whole point of it is that nothing can read it"\n' > "$f" || return 1
    chmod 000 "$f" 2>/dev/null || return 1
    # And it is REALLY unreadable here. uid 0 reads it anyway, and so does a
    # filesystem that ignores mode bits - and a proof that quietly lost its
    # precondition is a proof that cannot fail.
    cat "$f" >/dev/null 2>&1 && return 1
    printf '%s' "$f"
}

## unreadable_tcl_is_not_called_unbalanced <verdict dir> <the planted file>
unreadable_tcl_is_not_called_unbalanced() {
    local vd="$1" f="$2" row status detail
    row="$(tcl_gate_row "$vd")"
    [ -n "$row" ] || { echo 'no static.tcl.complete row in that run'; return 1; }
    status="$(printf '%s\n' "$row" | cut -f2)"
    detail="$(printf '%s\n' "$row" | cut -f4)"
    if [ "$status" = "PASS" ]; then
        printf 'a .tcl file that cannot be opened at all went unnoticed: %s\n' "$detail"
        printf 'The gate passed, so it counted a file it never read among the ones that balance.\n'
        return 1
    fi
    t_contains "$detail" "$f" || {
        printf 'the gate is %s and does not name the file it could not read:\n%s\n' "$status" "$detail"
        return 1; }
    if printf '%s' "$detail" | grep -qi 'unbalanc'; then
        printf 'the gate called a file it could not OPEN unbalanced:\n%s\n' "$detail"
        printf 'It never read a byte of it, so it has no finding about the braces in it. That\n'
        printf 'conflation is what reported all 21 .tcl files in this toolkit as broken on\n'
        printf 'every host with a tclsh, for as long as the gate existed.\n'
        return 1
    fi
    printf '%s' "$detail" | grep -qi 'could not read' || {
        printf 'the gate is %s and names the file, but never says it could not READ it - so\n' "$status"
        printf 'the reader is left to guess which kind of problem this is:\n%s\n' "$detail"
        return 1; }
    [ "$status" = "UNVERIFIED" ] || {
        printf 'evidence that is MISSING is UNVERIFIED in this toolkit (ci/lib.sh counts it as\n'
        printf 'a failure and says why); the gate recorded %s: %s\n' "$status" "$detail"
        return 1; }
    return 0
}

if ! command -v tclsh >/dev/null 2>&1; then
    # All four need a tclsh: two to read the toolkit, two to plant a fault in
    # the reader and watch this suite notice. The gate itself reports
    # UNVERIFIED on such a host and there is no claim of its to check.
    t_skip tier.static.tcl_gate "no tclsh on this host, so the static tier reported that gate UNVERIFIED in this run and there is no claim of its to check"
    t_skip tier.static.tcl_gate.mutation "no tclsh on this host, so the gate under the planted fault would report UNVERIFIED for the same reason as the unmutated one, and the proof would pass for the wrong reason"
    t_skip tier.static.tcl_gate.unreadable "no tclsh on this host, so the gate never opens a file at all and cannot distinguish one it could not read"
    t_skip tier.static.tcl_gate.unreadable.mutation "no tclsh on this host, so the gate never opens a file at all and the fault this proof plants is unreachable"
else
    if ! grep -q 'static\.tcl\.complete' "$VD_PREFIX/verdicts.tsv" 2>/dev/null; then
        t_skip tier.static.tcl_gate "the prefix run above recorded no static.tcl.complete row in THIS run (see tier.select.prefix), so there is no verdict of that gate to compare against"
    else
        t_check tier.static.tcl_gate \
            "the gate's verdict, its file list and its count agree with an independent [info complete] over the same files" \
            tcl_gate_agrees_with_tclsh "$VD_PREFIX" "$FLOW_DIR"
    fi

    # THE FAULT IS THE LINE AS IT STOOD BEFORE THE FIX, verbatim, so the proof
    # measures the defect that was there rather than some other way of upsetting
    # the gate. Under it every open fails, and the gate - which now HAS a word
    # for that - reports UNVERIFIED over all 21 files while the independent
    # reader opens every one of them.
    TCL_READ_LINE="$(grep -m1 -F -- 'tclsh "$reader"' "$FLOW_DIR/ci/tier.sh")"
    TCL_PIPED_LINE="        echo 'if {[catch {set d [read [set c [open [lindex \$argv 0]]]]}]} {exit 2}; close \$c; exit [expr {[info complete \$d] ? 0 : 1}]' | tclsh - \"\$f\" >/dev/null 2>&1 || trc=\$?"
    M="$(t_mutant "$SB" tcl-reader-on-stdin)"
    if [ -n "$TCL_READ_LINE" ] && t_replace_line "$M" ci/tier.sh "$TCL_READ_LINE" "$TCL_PIPED_LINE"; then
        VD_TCL="$(static_climb "$M")"
        t_check_fail tier.static.tcl_gate.mutation \
            "with the reader piped into 'tclsh - \$f' again, every file fails to open and the assertion goes red" \
            tcl_gate_agrees_with_tclsh "$VD_TCL" "$M"
    else
        t_skip tier.static.tcl_gate.mutation "could not plant the fault: the gate no longer runs 'tclsh \"\$reader\" \"\$f\"' on one line, so there is no invocation to put back on stdin"
    fi

    # -- and the third state, which is the half that keeps it fixed -----------
    M="$(t_mutant "$SB" tcl-unreadable)"
    UNREAD_F="$(plant_unreadable_tcl "$M")" || UNREAD_F=""
    if [ -z "$UNREAD_F" ]; then
        t_skip tier.static.tcl_gate.unreadable "this host reads a mode-000 file anyway (uid $(id -u), or a filesystem that ignores mode bits), so a .tcl the gate cannot open cannot be created here"
    else
        VD_UNREAD="$(static_climb "$M")"
        t_check tier.static.tcl_gate.unreadable \
            "a .tcl file that cannot be opened is reported as unread (UNVERIFIED), by name, and never as unbalanced" \
            unreadable_tcl_is_not_called_unbalanced "$VD_UNREAD" "$UNREAD_F"
    fi

    # The fault is the conflation itself: the reader still answers in three
    # states and the caller folds two of them together again, which is what the
    # old `|| tbad="$tbad $f"` did to every non-zero exit.
    TCL_UNREAD_ARM="$(grep -m1 -F -- 'tunread="$tunread' "$FLOW_DIR/ci/tier.sh")"
    M="$(t_mutant "$SB" tcl-unreadable-conflated)"
    UNREAD_F2="$(plant_unreadable_tcl "$M")" || UNREAD_F2=""
    if [ -z "$UNREAD_F2" ]; then
        t_skip tier.static.tcl_gate.unreadable.mutation "this host reads a mode-000 file anyway (uid $(id -u), or a filesystem that ignores mode bits), so the case this proof plants a fault against cannot be created here"
    elif [ -z "$TCL_UNREAD_ARM" ] || ! t_replace_line "$M" ci/tier.sh "$TCL_UNREAD_ARM" \
            '            *) tbad="$tbad $f" ;;   # planted fault: any non-zero is a syntax finding again'; then
        t_skip tier.static.tcl_gate.unreadable.mutation "could not plant the fault: the gate's reader no longer has a single-line '*) tunread=...' arm to fold back into the unbalanced list"
    else
        VD_UNREAD2="$(static_climb "$M")"
        t_check_fail tier.static.tcl_gate.unreadable.mutation \
            "with 'could not read' folded back into 'unbalanced', a file the gate never opened is called a syntax finding and the assertion goes red" \
            unreadable_tcl_is_not_called_unbalanced "$VD_UNREAD2" "$UNREAD_F2"
    fi
fi

#=============================================================================
# 7. ci/capability.sh - THE SAME HOLE, ONE DIRECTORY ACROSS
#
# It is here rather than in a file of its own because it is the same defect
# class and it is cheap: the script is pure text-in, text-out - a declaration
# file in, a verdict out - and every run below takes milliseconds and probes
# nothing but `sh` and $HOME.
#
# THE ONE THAT MATTERS IS `--require <label nobody declared>`. Gaps accumulate
# per label, and `label_earned` is "this label has no recorded gaps" - so a
# label that appears nowhere in the declaration has no gaps and reads as
# EARNED. One clause in the --require path stops that, and this is the shape of
# what it stops: the first step of a CI job, whose whole purpose is to fail in
# seconds when it lands on an under-provisioned host, confirming the host is
# capable of something that does not exist. A typo in a workflow file reaches
# it, and the job then runs synthesis on a runner with no Vivado.
#=============================================================================
t_head "ci/capability.sh: a capability nobody declared is never satisfied"

if [ ! -f "$FLOW_DIR/ci/capability.sh" ]; then
    t_skip cap.all "ci/capability.sh is not in this checkout at $FLOW_DIR/ci/capability.sh - an absent file is not a passing one"
else

CAP_DIR="$SB/capability"
mkdir -p "$CAP_DIR/nowhere"
CAP_CONF="$CAP_DIR/ci-capability.conf"
GHOST="ghost_label"

# The declaration this section probes. Nothing in it belongs to a site: `sh`
# and $HOME exist on every host that can run this suite, and the missing tool
# is missing by construction. CONTRACT.md section 1 forbids this repository
# from naming a board, a part or a lab path, and a fixture is part of it.
cat > "$CAP_CONF" <<'CONF'
met    tool      sh                    | a shell is on every host
met    env       HOME                  | every login has one
unmet  tool      no_such_tool_t_tier   | nothing provides this, deliberately
child  requires  unmet                 | one label including another, the ladder shape
child  tool      sh                    | and one requirement of its own that IS met
CONF

cat > "$CAP_DIR/unknown-kind.conf" <<'CONF'
alpha  bogus  whatever  | a directive this script has never heard of
CONF

## cap <toolkit> [args...]
## Run from a directory with no ci-capability.conf of its own, so the search
## order cannot pick one up by accident and answer about the wrong file.
cap() {
    local dir="$1"; shift
    local rc=0 out
    out="$(cd "$CAP_DIR/nowhere" && env -u CI_CAPABILITY_CONF -u FPGA_DIR \
           bash "$dir/ci/capability.sh" "$@" 2>&1)" || rc=$?
    printf '%s\nEXIT=%d\n' "$out" "$rc"
}

## undeclared_label_is_not_satisfied <toolkit>
undeclared_label_is_not_satisfied() {
    local dir="$1" out rc
    out="$(cap "$dir" --conf "$CAP_CONF" --require "$GHOST")"
    rc="$(exit_of "$out")"
    if [ "$rc" = 0 ]; then
        printf 'a label NOBODY DECLARED was reported satisfied (exit 0):\n%s\n' "$out"
        printf 'An undeclared label accumulates no gaps, and "no gaps" then reads as EARNED.\n'
        return 1
    fi
    t_contains "$out" "is not declared anywhere in" && return 0
    printf 'it failed, but not because the label is undeclared - the reader is sent to hunt\n'
    printf 'for a missing tool instead of a missing declaration line:\n%s\n' "$out"
    return 1
}

## require_reports_only_its_own_gaps <toolkit>
## The script's own promise: "the gaps that block the label you asked for and
## NO OTHERS ... a synthesis job failing must not also list the board it never
## needed, or one problem reads as four".
require_reports_only_its_own_gaps() {
    local dir="$1" out rc
    out="$(cap "$dir" --conf "$CAP_CONF" --require unmet)"
    rc="$(exit_of "$out")"
    [ "$rc" = 1 ] || { printf 'an unmet label exited %s, not 1:\n%s\n' "$rc" "$out"; return 1; }
    t_contains "$out" "no_such_tool_t_tier" \
        || { printf 'the gap that blocks the label is not named:\n%s\n' "$out"; return 1; }
    if t_contains "$out" "inherits from"; then
        printf 'asking about one label also reported ANOTHER label(s) gap:\n%s\n' "$out"
        printf 'One problem then reads as several, and the one that is actually blocking\n'
        printf 'this job is somewhere in the middle of them.\n'
        return 1
    fi
    return 0
}

## unknown_kind_is_refused <toolkit>
## A declaration line whose directive is not understood must stop the script.
## Skipping it silently is the same defect one level down: the requirement is
## never probed, records no gap, and its label is therefore EARNED for free.
unknown_kind_is_refused() {
    local dir="$1" out rc
    out="$(cap "$dir" --conf "$CAP_DIR/unknown-kind.conf")"
    rc="$(exit_of "$out")"
    [ "$rc" = 2 ] || {
        printf 'a declaration line with an unknown directive exited %s, not 2:\n%s\n' "$rc" "$out"
        printf 'A line nobody understands must not be read past: the requirement it states\n'
        printf 'is then never probed and its label is earned for free.\n'
        return 1; }
    t_contains "$out" "unknown kind" \
        || { printf 'the refusal does not say which directive it did not understand:\n%s\n' "$out"; return 1; }
    t_contains "$out" "bogus" \
        || { printf 'the refusal does not quote the offending directive:\n%s\n' "$out"; return 1; }
    return 0
}

## no_declaration_is_refused <toolkit>
## No declaration file anywhere is a REFUSAL (2), never "nothing is required,
## so everything is satisfied".
no_declaration_is_refused() {
    local dir="$1" out rc
    out="$(cap "$dir" --conf "$CAP_DIR/nowhere/absent.conf")"
    rc="$(exit_of "$out")"
    [ "$rc" = 2 ] || {
        printf 'with no declaration file anywhere it exited %s, not 2:\n%s\n' "$rc" "$out"
        return 1; }
    t_contains "$out" "no declaration file" \
        || { printf 'the refusal does not say a declaration file is what is missing:\n%s\n' "$out"; return 1; }
    return 0
}

t_check cap.require.undeclared \
    "--require <label nobody declared> is not satisfied, and says the label is undeclared" \
    undeclared_label_is_not_satisfied "$FLOW_DIR"
t_check cap.require.own_gaps \
    "an unmet label reports the gaps that block IT and no others" \
    require_reports_only_its_own_gaps "$FLOW_DIR"
t_check cap.conf.unknown_kind \
    "a declaration line with an unknown directive is refused (exit 2), not read past" \
    unknown_kind_is_refused "$FLOW_DIR"
t_check cap.conf.absent \
    "no declaration file anywhere is a refusal, never a host that needs nothing" \
    no_declaration_is_refused "$FLOW_DIR"

M="$(t_mutant "$SB" cap-undeclared-earned)"
if t_replace_line "$M" ci/capability.sh \
        '       && printf '"'"'%s'"'"' " $LABELS_SEEN " | grep -q " $REQUIRE "; then' \
        '       && true; then'; then
    t_check_fail cap.require.undeclared.mutation \
        "with the declared-anywhere test dropped, an undeclared label is 'satisfied' and the assertion goes red" \
        undeclared_label_is_not_satisfied "$M"
else
    t_skip cap.require.undeclared.mutation "could not plant the fault: the LABELS_SEEN test in capability.sh's --require path has changed shape"
fi

M="$(t_mutant "$SB" cap-all-gaps)"
if t_mutate "$M" ci/capability.sh 's/\$1==l { \$1=""/{ \$1=""/'; then
    t_check_fail cap.require.own_gaps.mutation \
        "with label_gaps ignoring which label was asked for, the assertion goes red" \
        require_reports_only_its_own_gaps "$M"
else
    t_skip cap.require.own_gaps.mutation "could not plant the fault: label_gaps() no longer filters with an awk '\$1==l' clause"
fi

M="$(t_mutant "$SB" cap-unknown-kind-ignored)"
if t_replace_line "$M" ci/capability.sh '        exit 2 ;;' '        ;;'; then
    t_check_fail cap.conf.unknown_kind.mutation \
        "with the unknown directive read past instead of refused, the assertion goes red" \
        unknown_kind_is_refused "$M"
else
    t_skip cap.conf.unknown_kind.mutation "could not plant the fault: the unknown-kind arm no longer ends in 'exit 2 ;;'"
fi

M="$(t_mutant "$SB" cap-noconf-continues)"
# SCOPED TO THE BLOCK IT BELONGS TO, and it was not until 2026-09-14. The
# target used to be the literal line `    exit 2`, which t_replace_line refuses
# once a second one exists anywhere in the file - and one does, since the
# argument loop grew a refusal of its own. The proof did not go red; it went
# QUIET, skipping with a reason that was true of the file and false of the
# guard, which is the shape of a proof that stops proving anything.
if t_mutate "$M" ci/capability.sh \
        '/^capability: no declaration file\./,/^fi$/ s/^    exit 2$/    :/'; then
    t_check_fail cap.conf.absent.mutation \
        "with the missing-declaration refusal removed, the assertion goes red" \
        no_declaration_is_refused "$M"
else
    t_skip cap.conf.absent.mutation "could not plant the fault: the block that prints 'capability: no declaration file.' no longer ends in a bare 'exit 2'"
fi

#-----------------------------------------------------------------------------
# AND THE SAME ARGUMENT-LOOP DEFECT AS ci/tier.sh, IN THE SAME SHAPE.
# `--require` and `--conf` both ended in `shift 2`, which fails and shifts
# NOTHING when one argument is left - so the loop spun forever. The first step
# of every CI job is this script; a job that hangs there reports no verdict at
# all and holds a runner until somebody's timeout kills it. Fixed 2026-09-14
# alongside ci/tier.sh's --fpga-dir, which had it too.
#
# BOTH OPTIONS ARE DRIVEN, and each has its own proof. They are two separate
# lines in one loop: an assertion that only ever exercised --require would say
# nothing whatever about --conf, and "the other one was fixed at the same time"
# is a claim about somebody's memory of an afternoon.
#-----------------------------------------------------------------------------
## _cap_argv_refused <toolkit> <the option under test> -- <argv...>
## THE TIMEOUT IS PART OF THE ASSERTION: the failure being measured is a script
## that never returns, so 124 is graded as its own answer rather than being
## reported as an exit status the script chose.
_cap_argv_refused() {
    local dir="$1" opt="$2" rc=0; shift 3
    timeout 5 env -u CI_CAPABILITY_CONF -u FPGA_DIR \
        bash "$dir/ci/capability.sh" "$@" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 2 ] && return 0
    [ "$rc" = 124 ] && { printf '%s with no operand had not terminated after 5 seconds.\n' "$opt"; return 1; }
    printf '%s with no operand exited %s, not 2 (refused: unusable input)\n' "$opt" "$rc"
    return 1
}

## cap_options_without_operand_are_refused <toolkit>
cap_options_without_operand_are_refused() {
    local dir="$1"
    _cap_argv_refused "$dir" --require -- --conf "$CAP_CONF" --require || return 1
    _cap_argv_refused "$dir" --conf    -- --conf || return 1
    return 0
}

if command -v timeout >/dev/null 2>&1; then
    t_check cap.argv.missing_operand \
        "--require and --conf with no operand are each refused (exit 2) instead of spinning the argument loop" \
        cap_options_without_operand_are_refused "$FLOW_DIR"

    # One fault per copy, and the fault is each line as it stood before the fix.
    CAP_REQUIRE_ARM="$(grep -m1 -F -- '--require) need_operand' "$FLOW_DIR/ci/capability.sh")"
    M="$(t_mutant "$SB" cap-require-shift2)"
    if [ -n "$CAP_REQUIRE_ARM" ] && t_replace_line "$M" ci/capability.sh "$CAP_REQUIRE_ARM" \
            '        --require) MODE=require; REQUIRE="${2:-}"; shift 2 ;;'; then
        t_check_fail cap.argv.missing_operand.mutation.require \
            "with --require back to a bare 'shift 2', the loop never terminates and the assertion goes red" \
            cap_options_without_operand_are_refused "$M"
    else
        t_skip cap.argv.missing_operand.mutation.require "could not plant the fault: the --require arm of capability.sh's argument loop no longer checks its operand on one line"
    fi

    CAP_CONF_ARM="$(grep -m1 -F -- '--conf)    need_operand' "$FLOW_DIR/ci/capability.sh")"
    M="$(t_mutant "$SB" cap-conf-shift2)"
    if [ -n "$CAP_CONF_ARM" ] && t_replace_line "$M" ci/capability.sh "$CAP_CONF_ARM" \
            '        --conf)    CONF="${2:-}"; shift 2 ;;'; then
        t_check_fail cap.argv.missing_operand.mutation.conf \
            "and with --conf back to a bare 'shift 2' - the option the first proof never touches - the assertion goes red too" \
            cap_options_without_operand_are_refused "$M"
    else
        t_skip cap.argv.missing_operand.mutation.conf "could not plant the fault: the --conf arm of capability.sh's argument loop no longer checks its operand on one line"
    fi
else
    t_skip cap.argv.missing_operand "no coreutils timeout on this host, and the case under test is a script that never returns - running it without a timeout would hang this suite"
    t_skip cap.argv.missing_operand.mutation.require "no coreutils timeout on this host, and the fault this proof plants is the non-terminating loop itself - it would hang this suite rather than fail it"
    t_skip cap.argv.missing_operand.mutation.conf "no coreutils timeout on this host, and the fault this proof plants is the non-terminating loop itself - it would hang this suite rather than fail it"
fi

fi   # ci/capability.sh present

t_summary
