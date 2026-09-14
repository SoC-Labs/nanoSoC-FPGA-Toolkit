#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# ci/capability.sh - probe a host and DERIVE the runner labels it has earned
#
#   ci/capability.sh                      report; exit 1 if no label is earned
#   ci/capability.sh --labels             print earned labels, comma separated
#   ci/capability.sh --require <label>    assert one label; for a job's first step
#   ci/capability.sh --conf <file>        which declaration to read
#
# TWO JOBS, ONE SOURCE OF TRUTH.
#
#   before registering a runner   "can this host do the work, and which labels
#                                 has it earned?"
#   as a job's first step         "did I land somewhere capable?" A job that
#                                 lands on an under-provisioned host must fail
#                                 in seconds naming what is missing, not forty
#                                 minutes into synthesis.
#
# WHY DERIVE LABELS RATHER THAN HAND-ASSIGN THEM. A label is a claim about a
# host. Hand-assigned, it rots: a package update moves a binary, a module file
# starts advertising a Vivado that is not on the filesystem, somebody re-labels
# a box by hand - and the pool silently starts returning different answers for
# the same commit. Deriving them here means a drifted host DROPS a label
# instead of lying about it.
#
# WHY AN FPGA HOST DRIFTS MORE THAN AN ASIC ONE, AND WHAT FOLLOWS.
#
# THE BOARD IS A RUNTIME DEPENDENCY, AND THE ASIC TOOLKIT THIS IS MODELLED ON
# HAS NO ANALOGUE FOR IT. Every ASIC capability is a file, a binary or a
# licence server: things that change when somebody installs software. An FPGA
# deploy tier depends on a physical object - a board powered on, a JTAG cable
# in a socket, an fpgahub lease held by nobody else - and every one of those
# can stop being true between the moment a runner was registered and the moment
# a job lands on it, with no software change at all and nothing in any log.
#
# That is exactly why re-probing per job is not redundant with the runner's
# tag, and why the deploy label must be its own tier rather than an extra
# requirement bolted onto the implementation label: a host that synthesises
# perfectly well should keep doing so on the afternoon somebody borrows its
# cable.
#
# It is also why this script can only ever report a NECESSARY condition. A
# cable is present; a board answered a moment ago; a lease was free. None of
# those is a promise about the next two hours, and no probe can be.
#
# WHAT THIS DOES NOT DO, AND WHY. It does not know what your design needs.
# Every requirement is declared by the project, in a file this script reads,
# because the toolkit cannot know that your constraints are calibrated against
# one Vivado version or that your board lives behind one fpgahub instance. The
# generic part is the ENGINE: probe, accumulate gaps, derive labels, report the
# gaps that block the label you asked for and NO OTHERS. That last point
# matters more than it looks - a synthesis job failing must not also list the
# board it never needed, or one problem reads as four.
#
# THE TOOL AND VERSION HALF IS NOT DUPLICATED HERE. `kind: doctor` delegates to
# scripts/fpga-flow-doctor, which already reports what is on the filesystem
# rather than what a modulefile advertises - a distinction with teeth on these
# hosts, where the modulefiles offer Vivado releases that are not installed. A
# second implementation of that probe would drift from the first, and the two
# would disagree in front of somebody trying to work out why their job failed.
#
#-----------------------------------------------------------------------------
# THE DECLARATION FILE
#
#   <label>  <kind>  <spec>   | <why it matters>
#
# Blank lines and lines starting with # are ignored. Everything after the first
# `|` is the explanation printed when the requirement is not met - write it for
# somebody who has just been handed a red job and does not know this project.
#
#   kind      spec                      passes when
#   ------    ----------------------    ---------------------------------------
#   tool      <name>                    it is on PATH
#   path      <file or directory>       it is READABLE. Not "the mount point
#                                       exists" - an empty autofs mount point
#                                       exists and reads as success.
#   env       <VARNAME>                 it is set and non-empty
#   pymod     <module>                  `python3 -c 'import <module>'` succeeds
#   cmd       <shell command>           it exits 0. For version pins, board
#                                       probes and anything else; the rest of
#                                       the line up to `|` is passed to sh -c.
#   doctor    -                         scripts/fpga-flow-doctor exits 0
#   requires  <other label>             that label was also earned
#
# Search order for the file: --conf, then $CI_CAPABILITY_CONF, then
# $FPGA_DIR/ci-capability.conf, then ./ci-capability.conf. See
# ci/capability.conf.example.
#
# Exit status: 0 the label is satisfied (or, in report mode, at least one label
#                is earned) · 1 it is not · 2 no declaration file, or an
#                unknown kind in one · 130 interrupted
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOW_DIR="$(cd "$HERE/.." && pwd)"
# Exported so a `cmd` directive can name a toolkit script without assuming the
# caller's working directory. `cmd` runs under `sh -c`, so a bare relative path
# in a declaration silently resolves against wherever the job happened to start
# - which works from the toolkit root and nowhere else.
export FPGA_FLOW_DIR="${FPGA_FLOW_DIR:-$FLOW_DIR}"

usage() { sed -n '2,/^# Copyright/p' "$0" | sed 's/^#\{1,\} \{0,1\}//;s/^#$//'; }
trap 'exit 130' INT

#-----------------------------------------------------------------------------
# AN OPTION WITH NO OPERAND MUST REFUSE, NOT SPIN.
#
# `--require` and `--conf` both ended in `shift 2`, and a `shift 2` with one
# argument left FAILS - it shifts NOTHING. The loop then sees the same option
# again, and again, forever. Measured: `capability.sh --conf <file> --require`
# never returns. THIS SCRIPT IS THE FIRST STEP OF A CI JOB, whose entire
# purpose is to fail in seconds when the job lands on an under-provisioned
# host; hanging there is the one failure mode that costs more than the forty
# minutes of synthesis it exists to save, because the job reports nothing at
# all and holds a runner until somebody's external timeout kills it.
#
# The test has to happen BEFORE the shift. Exit 2 is this script's "unusable
# input" (see the header's exit table) and is deliberately not 1: 1 means this
# host does not provide the label, which would send a reader hunting for a
# missing tool that has nothing to do with it.
#-----------------------------------------------------------------------------

## need_operand <arguments remaining> <option> <what it takes>
need_operand() {
    [ "$1" -ge 2 ] && return 0
    echo "capability: $2 takes $3 after it, and nothing followed it." >&2
    echo "  Nothing was probed. Exit 2 is 'unusable arguments', not an unmet requirement." >&2
    exit 2
}

MODE=report
REQUIRE=""
CONF=""
while [ $# -gt 0 ]; do
    case "$1" in
        --labels)  MODE=labels; shift ;;
        --require) need_operand "$#" --require "the label to assert"; MODE=require; REQUIRE="$2"; shift 2 ;;
        --conf)    need_operand "$#" --conf "the declaration file to read"; CONF="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "capability: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

for c in "$CONF" "${CI_CAPABILITY_CONF:-}" "${FPGA_DIR:-}/ci-capability.conf" \
         "./ci-capability.conf"; do
    [ -n "$c" ] && [ -f "$c" ] && { CONF="$c"; break; }
done
if [ -z "$CONF" ] || [ ! -f "$CONF" ]; then
    cat >&2 <<EOF
capability: no declaration file.

  This script probes what a PROJECT declares it needs; it has no built-in list,
  deliberately. Copy the annotated example and edit it:

      cp $FLOW_DIR/ci/capability.conf.example <project>/fpga/ci-capability.conf

  Searched: --conf, \$CI_CAPABILITY_CONF, \$FPGA_DIR/ci-capability.conf,
  ./ci-capability.conf
EOF
    exit 2
fi

# label -> "met" unless a gap is recorded. Some sites' /bin/bash predates
# associative arrays, so gaps accumulate as newline-separated "label|detail".
GAPS=""
LABELS_SEEN=""
NOTES=""

record_gap()  { GAPS="${GAPS}${1}|${2}"$'\n'; }
record_note() { NOTES="${NOTES}${1}|${2}|${3}"$'\n'; }
seen_label()  {
    case " $LABELS_SEEN " in *" $1 "*) ;; *) LABELS_SEEN="$LABELS_SEEN $1" ;; esac
}

# Deferred, because `requires` may name a label declared later in the file.
REQUIRES=""

while IFS= read -r raw; do
    line="${raw%%#*}"
    [ -z "${line// /}" ] && continue
    why="${raw#*|}"; [ "$why" = "$raw" ] && why=""
    why="${why#"${why%%[![:space:]]*}"}"   # trim the leading space after the |
    line="${line%%|*}"
    # shellcheck disable=SC2086
    set -- $line
    [ $# -ge 2 ] || continue
    label="$1"; kind="$2"; shift 2
    spec="$*"
    seen_label "$label"

    case "$kind" in
    tool)
        if p=$(command -v "$spec" 2>/dev/null); then
            record_note "$label" "OK" "$spec -> $p"
        else
            record_note "$label" "MISSING" "$spec not on PATH"
            record_gap "$label" "$spec (not on PATH).${why:+ $why}"
        fi ;;
    path)
        # READABLE, not "exists". An autofs mount point whose map entry is
        # missing on this host is an empty directory that passes every `test
        # -d` and then makes the tool fail forty minutes later. `-r` on a
        # directory also fails for a permission problem, which is the other way
        # a path that is plainly there turns out to be useless.
        if [ -r "$spec" ]; then
            record_note "$label" "OK" "$spec readable"
        else
            record_note "$label" "MISSING" "$spec unreadable"
            record_gap "$label" "$spec is not READABLE (it may well exist).${why:+ $why}"
        fi ;;
    env)
        if [ -n "${!spec:-}" ]; then
            record_note "$label" "OK" "$spec=${!spec}"
        else
            record_note "$label" "MISSING" "$spec unset"
            record_gap "$label" "\$$spec is unset.${why:+ $why}"
        fi ;;
    pymod)
        if "${PYTHON:-python3}" -c "import $spec" 2>/dev/null; then
            record_note "$label" "OK" "python module $spec"
        else
            record_note "$label" "MISSING" "python module $spec"
            record_gap "$label" "python module '$spec' is not importable.${why:+ $why}"
        fi ;;
    cmd)
        if sh -c "$spec" >/dev/null 2>&1; then
            record_note "$label" "OK" "$spec"
        else
            record_note "$label" "MISSING" "$spec"
            record_gap "$label" "the check \`$spec\` failed.${why:+ $why}"
        fi ;;
    doctor)
        if [ ! -x "$FLOW_DIR/scripts/fpga-flow-doctor" ]; then
            record_note "$label" "MISSING" "no scripts/fpga-flow-doctor to delegate to"
            record_gap "$label" "this declaration delegates to scripts/fpga-flow-doctor and there is no such script - nothing probed the tools at all.${why:+ $why}"
        elif "$FLOW_DIR/scripts/fpga-flow-doctor" >/dev/null 2>&1; then
            record_note "$label" "OK" "fpga-flow-doctor: essentials present"
        else
            record_note "$label" "MISSING" "fpga-flow-doctor reports missing essentials"
            record_gap "$label" "fpga-flow-doctor reports a missing essential. Run it directly for the list - it reports what is ON THE FILESYSTEM, not what a modulefile advertises.${why:+ $why}"
        fi ;;
    requires)
        REQUIRES="${REQUIRES}${label}|${spec}"$'\n' ;;
    *)
        echo "capability: $CONF: unknown kind '$kind' for label '$label'" >&2
        echo "  known: tool path env pymod cmd doctor requires" >&2
        exit 2 ;;
    esac
done < "$CONF"

label_gaps() { printf '%s' "$GAPS" | awk -F'|' -v l="$1" '$1==l { $1=""; sub(/^\|/,""); print }'; }
label_earned() { [ -z "$(label_gaps "$1")" ]; }

# `requires` is transitive but not recursive here: two passes cover every real
# ladder (deploy requires impl requires synth requires lint) and a cycle would
# hang. A third pass would too, so the depth is fixed rather than searched.
for _ in 1 2 3; do
    while IFS='|' read -r child parent; do
        [ -z "$child" ] && continue
        if ! label_earned "$parent"; then
            case "$GAPS" in
                *"$child|inherits from '$parent'"*) ;;
                *) record_gap "$child" "inherits from '$parent', which this host has not earned" ;;
            esac
        fi
    done <<< "$REQUIRES"
done

EARNED=""
for l in $LABELS_SEEN; do
    label_earned "$l" && EARNED="${EARNED:+$EARNED,}$l"
done

case "$MODE" in
labels)
    echo "$EARNED"
    [ -n "$EARNED" ] || exit 1
    exit 0 ;;
require)
    if [ -n "$REQUIRE" ] && label_earned "$REQUIRE" \
       && printf '%s' " $LABELS_SEEN " | grep -q " $REQUIRE "; then
        echo "capability OK on $(hostname -s 2>/dev/null || echo '?'): '$REQUIRE' satisfied"
        exit 0
    fi
    echo "CI-GATE: FAIL id=host.capability detail=this host does not provide '$REQUIRE'"
    echo "CAPABILITY FAILED on $(hostname -s 2>/dev/null || echo '?'): '$REQUIRE' not satisfied" >&2
    case " $LABELS_SEEN " in
        *" $REQUIRE "*) ;;
        *) echo "  '$REQUIRE' is not declared anywhere in $CONF." >&2; exit 1 ;;
    esac
    # ONLY the gaps that block the label ASKED FOR. A synthesis job that failed
    # must not also list the board and the cable it never needed.
    label_gaps "$REQUIRE" | sed 's/^/  MISSING: /' >&2
    exit 1 ;;
esac

echo "== capability: $(hostname -s 2>/dev/null || echo '?') =="
echo "   declaration: $CONF"
printf '   cores %s   mem %sGB\n' "$(nproc 2>/dev/null || echo '?')" \
    "$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo '?')"
echo ""
for l in $LABELS_SEEN; do
    if label_earned "$l"; then echo "  EARNED   $l"; else echo "  no       $l"; fi
    printf '%s' "$NOTES" | awk -F'|' -v l="$l" '$1==l { printf "      %-8s %s\n", $2, $3 }'
    label_gaps "$l" | sed 's/^/      blocks: /'
done
echo ""
if [ -n "$EARNED" ]; then
    echo "EARNED LABELS: $EARNED"
else
    echo "EARNED LABELS: (none) - do NOT register a runner here"
fi
[ -n "$EARNED" ]
