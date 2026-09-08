# shellcheck shell=bash
#-----------------------------------------------------------------------------
# ci/lib.sh - the verdict model every ci/ script shares
#
# Sourced, never executed. Gives each script one way to say "this named gate
# passed" or "this named gate failed", so a CI run reports WHICH GATE FAILED
# rather than "job failed".
#
# WHY A GATE ID AT ALL.
#
# CONTRACT.md rule one: assert on artefacts, never on exit status. Vivado exits
# 0 on a failed route, on unmet timing, and on a constraint file that matched
# nothing - so every stage judges itself on artefacts instead, and that gives a
# run many independent verdicts: the checkpoint exists, the manifest was
# written, the .bin was converted with the right board style, the XDC matched
# something. Collapsing all of them into one process exit status throws away
# the only thing worth knowing. A red job that says `impl.gate.hard` sends you
# to one paragraph of one file. A red job that says `make: *** [impl] Error 1`
# sends you to a 40,000-line log.
#
# Every gate id is `<tier>.<subject>[.<detail>]`, lower case, dot separated, and
# STABLE across runs. They are meant to be grepped: "impl.timing.wns has fired
# on eleven of the last twenty runs" is a sentence CI should be able to support,
# and it cannot if the ids are prose.
#
# WHAT A GATE MAY NOT DO.
#
# CONTRACT.md rule two: a gate never invents a verdict from missing data. If the
# evidence is absent or unparseable the answer is UNVERIFIED, which counts as a
# FAILURE, never as a pass. Zeroes from an unread report are the best possible
# result produced from no measurement at all. That is why an unmeasured number
# is emitted as the literal token `unmeasured` and never as `0`: a `0` in a
# utilisation column is indistinguishable from an empty design, and both of
# those look like good news.
#
# Env:
#   CI_VERDICT_DIR   where verdicts.tsv and owner are written.
#                    Default $FPGA_RUN_DIR/ci, else $RUN_DIR/ci, else
#                    ./ci-verdicts. Resolved by ci_init, NOT at source time.
#   CI_SUMMARY_FILE  markdown destination. Default $GITHUB_STEP_SUMMARY if set,
#                    else stdout. GitLab has no equivalent, so a job there should
#                    point this at a file and publish it as an artefact.
#   CI_COLOUR        0 to suppress ANSI (default: auto, on only for a tty)
#   CI_LANE          this process's name in a collision report, when several
#                    lanes run at once. Default is the pid.
#   CI_APPEND        1 means "somebody upstream already started this run's
#                    verdict file" - see ci_init.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------

# Guard against double-sourcing: the tier driver sources this and so does every
# script it calls.
[ -n "${_CI_LIB_SOURCED:-}" ] && return 0
_CI_LIB_SOURCED=1

#-----------------------------------------------------------------------------
# CI_VERDICT_DIR IS NOT DEFAULTED HERE, DELIBERATELY.
#
# Every caller sources this file and THEN works out its run directory, because
# the run directory comes from make - `make env` is the only thing that can
# resolve a `?=` chain plus per-invocation overrides. A default invented at
# source time would make each caller's own `CI_VERDICT_DIR="${CI_VERDICT_DIR:-
# $RUN_DIR/ci}"` a silent no-op against a value already set to ./ci-verdicts,
# and the run's verdicts would land beside whatever directory the job started
# in instead of inside the run. `ci_init` resolves it, by which time the run
# directory is known.
#
# The summary file is different and IS resolved here: it comes from the CI
# platform's environment, which is complete before this file is sourced.
#-----------------------------------------------------------------------------
CI_SUMMARY_FILE="${CI_SUMMARY_FILE:-${GITHUB_STEP_SUMMARY:-}}"

if [ -z "${CI_COLOUR:-}" ]; then
    if [ -t 1 ]; then CI_COLOUR=1; else CI_COLOUR=0; fi
fi
if [ "$CI_COLOUR" = "1" ]; then
    _C_RED=$'\033[31m'; _C_YEL=$'\033[33m'; _C_GRN=$'\033[32m'; _C_OFF=$'\033[0m'
else
    _C_RED=""; _C_YEL=""; _C_GRN=""; _C_OFF=""
fi

# Counters for the run. `ci_exit` turns them into an exit status.
CI_PASS=0
CI_FAIL=0
CI_WARN=0
CI_SKIP=0

#-----------------------------------------------------------------------------
# CONCURRENT LANES AND THE VERDICT FILE
#
# `ci_init` truncates verdicts.tsv and `_ci_record` appends to it unlocked. Both
# are right for ONE process writing ONE file, which is what a serial tier ladder
# is. Neither is right for two LANES sharing a $CI_VERDICT_DIR - a static check
# running alongside a two-hour implementation, say, which on an FPGA flow is a
# perfectly ordinary thing to want. Whichever calls ci_init second erases the
# first one's records, and nothing anywhere reports it: the lane that lost its
# evidence goes on to print "0 failed", the best possible result produced from
# no measurement at all, which is the exact mistake the header of this file
# exists to name.
#
# THE FIX IS NOT IN THIS FUNCTION, and deliberately so. It is that each lane
# sets its OWN CI_VERDICT_DIR, at which point the truncate is correctly scoped
# to a file that lane alone owns and no lock is needed anywhere.
#
# WHAT IS HERE is the enforcement: a guard that turns the silent version of the
# failure into a loud one, for every driver that has not been taught the
# convention yet. ci_init stamps an `owner` file beside verdicts.tsv, and a
# process that finds a LIVE FOREIGN owner refuses to truncate and fails a gate.
# A collision then costs a red run with a lane name in it, instead of a green
# run with a hole in it. The gate line lands in the shared file, so the
# collision is visible from BOTH sides rather than only to the loser.
#
# Liveness is pid + host + THE PID'S START TIME, read out of /proc. pid alone is
# not an identity: the owner file outlives the run that wrote it, pids are
# recycled, and a stale owner whose number came round again would fail every
# later run of that tag for no reason - a guard that cries wolf gets deleted,
# and a deleted guard protects nothing. Start time makes the match exact.
#
# THE OWNER FILE IS NEVER CLEANED UP, and that is not an oversight. Removing it
# would need an EXIT trap, and lib.sh is SOURCED - installing a trap here would
# silently replace the caller's own. A stale owner file costs nothing, because
# liveness is what is tested, not existence.
#
# APPENDS ARE NOT GUARDED, also deliberately. `_ci_record` writes one short line
# to a file opened O_APPEND by the shell; that is a single write() far under
# PIPE_BUF and the kernel does not interleave it. Two lanes appending to one
# file produce a readable mixture, never a torn line. It is the TRUNCATE that
# destroys evidence, so the truncate is what this guards.
#-----------------------------------------------------------------------------

# CI_LANE names this process in a collision report. A driver that forks lanes
# should set it to the lane's name; the default is the pid, which is unique and
# unhelpful, in that order of importance.
CI_LANE="${CI_LANE:-pid-$$}"

_ci_host() { hostname -s 2>/dev/null || echo unknown; }

## _ci_starttime <pid> - that pid's start time in clock ticks since boot.
## Field 22 of /proc/<pid>/stat. Field 2 is the executable name, which may
## contain BOTH spaces and parentheses, so this cuts after the LAST ')' instead
## of splitting the whole line - the parse that makes `sh -c 'exec -a "a) b"'`
## and every kernel thread with a bracketed name read correctly.
_ci_starttime() {
    local stat
    stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    printf '%s' "${stat##*') '}" | cut -d' ' -f20
}

## _ci_owner_alive <pid> <host> <starttime> - 0 when THAT EXACT process still runs
_ci_owner_alive() {
    local pid="$1" host="$2" start="$3" now
    [ -n "$pid" ] || return 1
    # A different machine sharing the directory over NFS is not ours to judge:
    # we cannot test its liveness, and guessing would be the cry-wolf failure.
    [ "$host" = "$(_ci_host)" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(_ci_starttime "$pid") || return 0    # no /proc: kill -0 is all there is
    [ -n "$start" ] || return 0
    [ "$now" = "$start" ]
}

## ci_init - resolve CI_VERDICT_DIR, claim ownership, start the verdict file.
## Call it AFTER the run directory is known and before the first emitter.
ci_init() {
    local o_lane o_pid o_host o_start
    if [ -z "${CI_VERDICT_DIR:-}" ]; then
        # FPGA_RUN_DIR is what mk/flow.mk exports; RUN_DIR is the same value
        # under the name CONTRACT.md §3.5 gives it, accepted so a hand-run
        # `RUN_DIR=... ci/assert-stage.sh impl` does the obvious thing.
        CI_VERDICT_DIR="${FPGA_RUN_DIR:-${RUN_DIR:-}}"
        CI_VERDICT_DIR="${CI_VERDICT_DIR:+$CI_VERDICT_DIR/ci}"
        CI_VERDICT_DIR="${CI_VERDICT_DIR:-./ci-verdicts}"
    fi
    mkdir -p "$CI_VERDICT_DIR" 2>/dev/null || true
    [ "${CI_APPEND:-0}" = "1" ] && return 0

    # `[ -r ]` first, rather than letting the read's redirection fail: the shell
    # reports a failed INPUT redirection before it has applied the `2>/dev/null`
    # that sits to the right of it, so the no-owner-file case - which is every
    # first run - printed "No such file or directory" to a real stderr.
    if [ -r "$CI_VERDICT_DIR/owner" ] \
       && IFS=$'\t' read -r o_lane o_pid o_host o_start _ \
              < "$CI_VERDICT_DIR/owner" \
       && [ "${o_pid:-}" != "$$" ] \
       && _ci_owner_alive "${o_pid:-}" "${o_host:-}" "${o_start:-}"; then
        printf '%sCI-VERDICT-COLLISION%s %s\n' "$_C_RED" "$_C_OFF" \
            "$CI_VERDICT_DIR/verdicts.tsv" >&2
        printf '  it is owned by lane %s (pid %s on %s), which is STILL RUNNING.\n' \
            "${o_lane:-?}" "${o_pid:-?}" "${o_host:-?}" >&2
        printf '  Truncating it would delete that lane'"'"'s evidence and it would\n' >&2
        printf '  report "0 failed" having measured nothing. NOT truncating.\n' >&2
        printf '  Give each lane its own directory:  CI_VERDICT_DIR=<run>/ci/<lane>\n' >&2
        ci_fail ci.verdict.collision \
            "lane '$CI_LANE' found $CI_VERDICT_DIR owned by live lane '${o_lane:-?}' (pid ${o_pid:-?}) - set a per-lane CI_VERDICT_DIR"
        return 0
    fi

    : > "$CI_VERDICT_DIR/verdicts.tsv" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$CI_LANE" "$$" "$(_ci_host)" "$(_ci_starttime $$)" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$CI_VERDICT_DIR/owner" 2>/dev/null || true
}

ci_say()  { printf '   %s\n' "$*"; }
ci_head() { printf '\n== %s ==\n' "$*"; }

#-----------------------------------------------------------------------------
# THE VERDICT LINE. CONTRACT.md §7: exactly four tab-separated columns,
#   <ISO8601 UTC>\t<PASS|FAIL|UNVERIFIED|WARN|SKIP>\t<gate.id>\t<detail>
#
# The detail is SANITISED, and this is not fussiness. Details are built from
# tool output and from paths, and a tab or a newline arriving in one turns a
# four-column row into five columns or into two rows - at which point every
# awk -F'\t' downstream reads a gate id out of the wrong field and reports a
# verdict against a gate that does not exist. Silently. A wrapped detail is a
# cosmetic loss; a split row is a wrong answer.
#-----------------------------------------------------------------------------
# _ci_record <status> <gate id> <detail...>
_ci_record() {
    local status="$1" id="$2"; shift 2
    local detail="$*"
    # THE ID IS SANITISED TOO, and it was not until 2026-09-08.
    #
    # Only the detail was scrubbed, on the reasoning that a gate id is a
    # controlled string an author types. It is not: ids are COMPOSED -
    # `ci_fail "route.$(basename "$f")"` - so a filename with a tab in it puts a
    # tab in the id, and the row becomes five columns with the id split across
    # 3 and 4. The consequence is worse than the wrapped detail this function
    # already guarded against: a reader and every downstream parser then attach
    # a verdict to a gate that does not exist, silently. Found by t_verdicts.sh,
    # which carried it as a known defect until this line existed.
    #
    # An id with whitespace in it is already a bug in the caller, so the
    # substitution never fires in a healthy run - but "never fires" and "cannot
    # produce a wrong answer" are different claims, and only the second one is
    # worth having in the function that writes the record CI reads.
    id="${id//$'\t'/ }"
    id="${id//$'\n'/ }"
    id="${id//$'\r'/ }"
    detail="${detail//$'\t'/ }"
    detail="${detail//$'\n'/ }"
    detail="${detail//$'\r'/ }"
    printf '%s\t%s\t%s\t%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$status" "$id" "$detail" \
        >> "$CI_VERDICT_DIR/verdicts.tsv" 2>/dev/null || true
}

## ci_pass <gate id> [detail...]
ci_pass() {
    local id="$1"; shift
    CI_PASS=$((CI_PASS + 1))
    printf '%s  ok %s%s  %s\n' "$_C_GRN" "$_C_OFF" "$id" "$*"
    _ci_record PASS "$id" "$*"
}

## ci_fail <gate id> [detail...]   - the run is bad and CI must be red
ci_fail() {
    local id="$1"; shift
    CI_FAIL=$((CI_FAIL + 1))
    printf '%sFAIL%s  %s  %s\n' "$_C_RED" "$_C_OFF" "$id" "$*" >&2
    # The machine-readable line the job summary and any log scraper key on.
    printf 'CI-GATE: FAIL id=%s detail=%s\n' "$id" "$*"
    _ci_record FAIL "$id" "$*"
}

## ci_unverified <gate id> [why...]
## For the case the evidence is MISSING rather than bad. COUNTS AS A FAILURE -
## deliberately, and this is the whole point of having a separate word for it. A
## check whose input it could not read has not passed; it has not run. The
## separate word exists so the red line sends you to look for a missing file
## rather than to argue with a number.
ci_unverified() {
    local id="$1"; shift
    CI_FAIL=$((CI_FAIL + 1))
    printf '%sUNVERIFIED%s  %s  %s\n' "$_C_RED" "$_C_OFF" "$id" "$*" >&2
    printf 'CI-GATE: UNVERIFIED id=%s detail=%s\n' "$id" "$*"
    _ci_record UNVERIFIED "$id" "$*"
}

## ci_warn <gate id> [detail...]   - reported, never red
ci_warn() {
    local id="$1"; shift
    CI_WARN=$((CI_WARN + 1))
    printf '%swarn%s  %s  %s\n' "$_C_YEL" "$_C_OFF" "$id" "$*"
    _ci_record WARN "$id" "$*"
}

## ci_skip <gate id> [why...]
## A gate that did not apply. Recorded WITH ITS REASON, because "we did not
## check that" is information an auditor needs as much as a pass - and because
## a tier silently checking nothing is how a green run comes to prove nothing.
ci_skip() {
    local id="$1"; shift
    CI_SKIP=$((CI_SKIP + 1))
    printf '  --  %s  SKIP: %s\n' "$id" "$*"
    _ci_record SKIP "$id" "$*"
}

# --- assertion primitives ----------------------------------------------------
# Every one of these takes a GATE ID FIRST, so a failure names itself and the
# name is the thing to grep for across an archive of runs.

## ci_assert_file <gate id> <path> <why it matters>
## Distinguishes ABSENT from ZERO BYTES. Both are failures; they are different
## failures. A zero-byte artefact is the shape a tool leaves when it opened its
## output file and then died - Vivado does exactly this to a .bit when
## write_bitstream aborts - and it satisfies every `test -e` in the world. The
## two cases send you to different places: absent means the stage never got
## there, zero bytes means it got there and died mid-write.
ci_assert_file() {
    local id="$1" path="$2"; shift 2
    if [ -s "$path" ]; then
        ci_pass "$id" "$path"
    elif [ -e "$path" ]; then
        ci_fail "$id" "$path is ZERO BYTES - $*"
    else
        ci_fail "$id" "no $path - $*"
    fi
}

## ci_assert_dir <gate id> <path> <why it matters>
## Same three-way split: present and populated / present and EMPTY / absent. An
## empty directory is the shape make's own `mkdir -p` leaves behind when the
## stage that was going to fill it never ran.
ci_assert_dir() {
    local id="$1" path="$2"; shift 2
    if [ -d "$path" ] && [ -n "$(ls -A "$path" 2>/dev/null)" ]; then
        ci_pass "$id" "$path"
    elif [ -d "$path" ]; then
        ci_fail "$id" "$path exists but is EMPTY - $*"
    else
        ci_fail "$id" "no $path - $*"
    fi
}

## ci_assert_grep <gate id> <regex> <file> <why it matters>
## An unreadable file is UNVERIFIED, not FAIL: "the string was absent" and "we
## could not look" are different findings and only one of them is about the
## design. Set CI_GREP_CONTEXT to a looser pattern to have the failure path
## print the lines that DID match it - "the string was there saying FAIL" and
## "the string was not there at all" want different next actions.
ci_assert_grep() {
    local id="$1" re="$2" f="$3"; shift 3
    if [ ! -s "$f" ]; then
        ci_unverified "$id" "no evidence at $f - $*"
        return 1
    fi
    if grep -qE "$re" "$f"; then
        ci_pass "$id" "$(basename "$f")"
        return 0
    fi
    ci_fail "$id" "$f does not match /$re/ - $*"
    if [ -n "${CI_GREP_CONTEXT:-}" ]; then
        grep -nE "$CI_GREP_CONTEXT" "$f" 2>/dev/null | head -5 | sed 's/^/      /' >&2
    fi
    return 1
}

#-----------------------------------------------------------------------------
# THE BUDGET PRIMITIVE
#
# CONTRACT.md §3.3: every EXPECT_* knob defaults to -1, meaning MEASURE AND
# REPORT, DO NOT GATE. That three-way shape - unarmed / within / exceeded - is
# the one every utilisation and timing gate in this flow needs, and writing it
# out at each call site is how one of them ends up comparing a string to a
# number and passing everything.
#
# The unarmed case is a ci_warn and NOT a ci_skip, deliberately: the check did
# run and did produce a number, it simply had no budget to judge it against.
# ci_skip would say "not checked", which would be a lie about a measurement
# that is sitting right there in the detail column.
#
# The unmeasured case is UNVERIFIED even when the budget is unarmed, because a
# knob set to -1 disarms the COMPARISON, not the requirement that the run
# measured something. A report of "-1 vs unmeasured" is two absences agreeing.
#-----------------------------------------------------------------------------
## ci_assert_budget <gate id> <value> <budget> <max|min> <what it is>
ci_assert_budget() {
    local id="$1" val="$2" budget="$3" sense="$4"; shift 4
    if ! ci_is_measured "$val"; then
        ci_unverified "$id" "$* is '${val:-<absent>}' - the run recorded no measurement, so any gate on it is unarmed"
        return 1
    fi
    case "$budget" in
        ''|-1) ci_warn "$id" "$* = $val, no budget set (EXPECT_* is -1: measure and report, do not gate)"; return 0 ;;
    esac
    # awk, not [ -lt ]: WNS is a float in nanoseconds and the shell cannot
    # compare one. `-0.078 -lt 0` is a syntax error, and a syntax error inside
    # an `if` is a false, which reads as "within budget".
    if awk -v v="$val" -v b="$budget" -v s="$sense" \
        'BEGIN { exit !( (s == "max") ? (v+0 <= b+0) : (v+0 >= b+0) ) }'; then
        ci_pass "$id" "$* = $val, budget $sense $budget"
    else
        ci_fail "$id" "$* = $val exceeds budget ($sense $budget) - ratchet the EXPECT_* in design.mk with the measurement and the margin written beside it, or fix the design. Do not demote this gate in a CI configuration where no run record ever reaches it"
    fi
}

# --- manifest reading --------------------------------------------------------
# Stage manifests are whitespace-separated `key value` lines (CONTRACT.md §5).
# The manifest is written LAST in every stage script, so its mere existence is
# the strongest cheap evidence that the script reached its final section.

## ci_mf <manifest file> <key>   -> value on stdout, empty if absent
ci_mf() {
    [ -s "$1" ] || return 1
    awk -v k="$2" '$1 == k { $1 = ""; sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); print; exit }' "$1"
}

# Values that mean "this run did not measure it". They must never be compared,
# and must never satisfy a gate. `unmeasured` is the literal token CONTRACT.md
# §0 mandates; `UNVERIFIED:<reason>` is the manifest field shape from §5;
# `n/a (...)` is what a failed Tcl query writes; the empty alternative catches
# a key that is present with no value at all.
CI_UNMEASURED_RE='^(unmeasured|not measured|n/a( \(.*\))?|UNVERIFIED(:.*)?|)$'

## ci_is_measured <value>  - true when the value is a real measurement
ci_is_measured() {
    [ -n "${1:-}" ] || return 1
    printf '%s' "$1" | grep -qE "$CI_UNMEASURED_RE" && return 1
    return 0
}

# --- summary -----------------------------------------------------------------

## ci_summary <<'EOF' ... EOF     - markdown to the job summary, or stdout
ci_summary() {
    if [ -n "$CI_SUMMARY_FILE" ]; then
        cat >> "$CI_SUMMARY_FILE"
    else
        cat
    fi
}

## ci_summary_table [title] - render verdicts.tsv as a markdown table into
## $CI_SUMMARY_FILE (which defaults to $GITHUB_STEP_SUMMARY) or stdout.
ci_summary_table() {
    local title="${1:-CI gates}"
    {
        printf '### %s\n\n' "$title"
        if [ ! -s "${CI_VERDICT_DIR:-}/verdicts.tsv" ]; then
            # An empty verdict file is a finding, not an empty table. A tier
            # that recorded nothing measured nothing.
            printf '_No gates were recorded. That is not a pass: the tier did not run, or it wrote its verdicts somewhere else (`CI_VERDICT_DIR`)._\n\n'
            return 0
        fi
        printf '| gate | result | detail |\n|---|---|---|\n'
        awk -F'\t' '
            { g = $3; r = $2; d = $4
              gsub(/\|/, "\\|", d)
              gsub(/`/, "'"'"'", d)
              if (length(d) > 110) d = substr(d, 1, 107) "..."
              mark = (r == "PASS") ? "ok" \
                   : (r == "WARN") ? "warn" \
                   : (r == "SKIP") ? "--" : "**" r "**"
              printf "| `%s` | %s | %s |\n", g, mark, d }
        ' "$CI_VERDICT_DIR/verdicts.tsv"
        printf '\n'
        awk -F'\t' '
            $2=="FAIL" || $2=="UNVERIFIED" { n++ }
            $2=="SKIP" { s++ }
            END {
              if (n) printf "**%d gate(s) failed.** The gate id is the thing to search for, in this repository and in previous runs.\n\n", n
              else   printf "All recorded gates passed. Read what that does and does not prove - and read the %d skipped gate(s) above, because a skip is a check that did not happen.\n\n", s+0 }' \
            "$CI_VERDICT_DIR/verdicts.tsv"
    } | ci_summary
}

## ci_exit [label] - final verdict line and process status.
##
## Non-zero when ANY gate failed. Deliberately NOT "the last command's status":
## a tier that runs eleven gates and fails the third must still run the other
## eight, because a two-hour implementation's evidence is worth collecting in
## full, and because the last gate in a list is not the important one - it is
## merely the last one.
##
## Exit status: 0 every gate passed (warnings and skips do not fail a run)
##              1 at least one gate is FAIL or UNVERIFIED
ci_exit() {
    local label="${1:-ci}"
    printf '\n%s: %d passed, %d failed, %d warned, %d skipped\n' \
        "$label" "$CI_PASS" "$CI_FAIL" "$CI_WARN" "$CI_SKIP"
    if [ "$CI_FAIL" -gt 0 ]; then
        printf 'FAILED GATES:\n'
        awk -F'\t' '$2 == "FAIL" || $2 == "UNVERIFIED" { printf "  %-34s %s\n", $3, $4 }' \
            "${CI_VERDICT_DIR:-}/verdicts.tsv" 2>/dev/null
        return 1
    fi
    return 0
}
