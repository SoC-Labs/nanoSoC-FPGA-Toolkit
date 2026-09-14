#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# t_doctor.sh - scripts/fpga-flow-doctor must report what is ACTUALLY on this
#               host, and must never round a fact it did not measure up to one
#               it did
#
# DEFECT CLASS: A HOST REPORT THAT IS CONFIDENTLY WRONG.
#
# mk/checks.mk calls doctor "can THIS MACHINE run the flow? No project, no
# licence, no tool run. Reports what is installed on the filesystem - which is
# not always what a modulefile advertises. Run it on any new host before
# trusting a result." That last sentence is the whole risk. doctor is what
# somebody reads when a build behaved differently on a new machine, and it is
# read INSTEAD OF looking, because looking is the thing it was written to save.
#
# So a doctor that says a tool is present when it is not - or absent when it is
# - does not merely fail to help. It sends the reader to debug the wrong layer,
# with a report in hand that says the layer they are leaving is fine. This lab
# has the measured instance: a capability declared absent that was present the
# whole time, and the hours went into the wrong half of the stack.
#
# Until this file landed, `fpga-flow-doctor` was named by no test
# (test/KNOWN_DEFECTS, UNPROVEN: "doctor reports what a host has ... has been
# run by hand and never asserted on").
#
# WHY THIS IS TESTABLE AT ALL, WHICH IS THE POINT OF THE FILE
#
# An assertion about the real host is not reproducible and is not an assertion:
# "vivado is on PATH" is true on the bench and false in CI, and a suite that
# asserted it would be reporting the weather. Every assertion below therefore
# drives doctor against a CONTROLLED environment - `env -i`, a sandbox PATH of
# STUB EXECUTABLES this file creates, a sandbox install tree, a sandbox module
# tree - so that "present", "absent" and "present but unusable" are things the
# suite DECIDES and doctor has to get right. The real host is READ in exactly
# four places - the python3 that starts doctor, the uid, the free space and one
# TCP port - and each of those decides whether an assertion can run at all, not
# whether it passed. No assertion below is true only on the machine that wrote
# it.
#
# The stubs are also tripwires: each one APPENDS TO A FILE WHEN IT RUNS, which
# is how doctor's loudest promise - "It launches NO EDA TOOL" - gets asserted
# rather than believed (doctor.notool). That assertion also checks the tripwire
# fires for the tools doctor DOES run, because "no marker appeared" proves
# nothing if no marker could ever appear.
#
# WHAT DOCTOR PROMISES, MEASURED FROM ITS OWN SOURCE (scripts/fpga-flow-doctor)
#
#   header 27-32  exit 0 every ESSENTIAL item present; 1 an essential item is
#                 missing; 2 crash; 130 interrupted. Advisory items NEVER
#                 change the status - Doctor's own docstring (line 88) says
#                 why: "a doctor that exits 1 on it teaches people to ignore it"
#   header 10-21  it reports what is ON THE FILESYSTEM AND REACHABLE BY YOU,
#                 enumerated at run time, and names every version a modulefile
#                 advertises that it cannot find. It never believes a
#                 modulefile and never hardcodes a version list
#   header 22-25  it launches NO EDA TOOL; the version comes from the install
#                 PATH and is labelled as such
#   usable() 472  THREE states, not two: absent / blocked (present but not
#                 usable by you) / ok - and Doctor.tool 107 applies the same
#                 three to a support tool, because a tclsh that is on PATH and
#                 cannot start is neither present nor absent
#   main() 856    it takes no arguments, and says so rather than ignoring them
#
# What it INSPECTS, which is what makes a stub PATH enough: PATH (shutil.which),
# the filesystem under each discovered install root, MODULEPATH and the
# modulefiles under it (parsed as text, never sourced), and the environment
# (XILINX_VIVADO, VIVADO_VER, the three licence variables, the three BUILD_DIR
# variables, NUM_JOBS, DISPLAY). It runs three small non-EDA commands: tclsh
# and git for their versions, and a second python3 if one is on PATH.
#
# EVERY ASSERTION IS PAIRED WITH A PLANTED-FAULT PROOF, AND EVERY PROOF GETS ITS
# OWN MUTANT. A shared copy accumulates faults and the fifteenth proof then
# passes or fails for the first proof's reason - a bug t_flow_utils.sh shipped
# and had to fix. An unplantable mutation is a SKIP WITH ITS REASON.
#
# COVERAGE HERE IS HOST-DEPENDENT IN FOUR PLACES, and the skip says which:
# doctor.state.untraversable and the two writability assertions need a mode that
# actually stops this user (they skip as uid 0, or on a mount where the mode is
# advisory); doctor.lic.noanswer needs 127.0.0.1:1 to be closed; and
# doctor.mod.unmeasured needs 20 GB free on $TMPDIR, because doctor advises
# below that and a single advisory is enough to stop the summary saying "This
# host can run the flow." Each is MEASURED before it is skipped. On a host where
# all four skip, FIVE planted-fault proofs skip with them - untraversable
# acquired one on 2026-09-14 when its defect was fixed - and the ledger does not
# go red for it: test/MUTATION_COVERAGE counts the proofs a suite CARRIES,
# rejections plus proofs that skipped for a stated reason, so a missing
# precondition is reported once, by the SKIP lines and run.sh's hole gate, and
# not twice.
#
# WHAT THIS FILE DOES NOT COVER, so the green line is not read as more than it
# is: the disk-space threshold (20 GB) is not exercised - making a filesystem
# with less than 20 GB free is not something a test may do to a host; the
# KeyboardInterrupt/130 arm needs a signal delivered mid-run; and the
# `os.statvfs` failure arm is unreachable from outside (doctor.disk.unmeasured
# records the measurement that says so).
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/lib/harness.sh
. "$HERE/../lib/harness.sh"

DOCTOR_REL="scripts/fpga-flow-doctor"

#-----------------------------------------------------------------------------
# Preconditions. Each is a SKIP WITH ITS REASON and never a pass: an absent
# precondition is exactly what the reader needed to know, and the reason is
# MEASURED HERE rather than described, so it cannot be true of a different run.
#-----------------------------------------------------------------------------
if [ ! -f "$FLOW_DIR/$DOCTOR_REL" ]; then
    t_skip doctor.all "$DOCTOR_REL is not in this checkout - there is no host report to test, and an absent file is not a passing one"
    t_summary; exit $?
fi

PYBIN="$(command -v python3 2>/dev/null)"
if [ -z "$PYBIN" ]; then
    t_skip doctor.all "no python3 on this host and $DOCTOR_REL is python3 - it cannot be run at all here, so every assertion below would measure an empty invocation"
    t_summary; exit $?
fi

# doctor is invoked as `python3 <script>` and NOT through its own shebang,
# because one of the assertions removes python3 from the sandbox PATH - and
# `#!/usr/bin/env python3` would then fail to start the very run that is
# supposed to report the absence. The interpreter therefore has to come from
# outside the controlled PATH, which means it has to survive `env -i`. On a
# site where python3 is a wrapper that needs its environment, it does not.
if ! env -i "$PYBIN" -c 'import sys; sys.exit(0)' 2>/dev/null; then
    t_skip doctor.all "$PYBIN does not start under a cleared environment (env -i), and every assertion here runs doctor under one so that PATH, MODULEPATH and the licence variables are what this file says they are rather than what the host happens to have"
    t_summary; exit $?
fi

t_sandbox; SB="$T_SANDBOX"

# doctor's modulefile parser matches `prepend-path PATH (\S+)`, so a sandbox
# path containing whitespace would make the module fixtures unparseable and
# every advertised-vs-installed assertion would measure the parser's whitespace
# handling instead of the comparison it is aimed at.
case "$SB" in
    *[[:space:]]*)
        t_skip doctor.all "the sandbox path '$SB' contains whitespace, and doctor's modulefile parser reads a PATH entry as a run of non-space characters - every module fixture below would be unparseable for a reason that has nothing to do with the toolkit"
        t_summary; exit $? ;;
esac

#=============================================================================
# THE FIXTURE
#
# Version numbers here are DELIBERATELY IMPLAUSIBLE. They have to match
# doctor's `^\d{4}\.\d+$` shape to be recognised as versions at all, and they
# must never be mistakable, in a failure message, for a statement about a real
# install on the machine running this suite. Nothing in this repository names a
# board, a pin or a project path (CONTRACT.md section 11.8) and a test fixture
# is part of this repository; these are the same rule applied to a tool version.
#
# Each version number is UNIQUE TO ITS TREE, and that is load-bearing rather
# than tidy: siblings() scans both `<parent>/*` AND `<grandparent>/*/<basename>`,
# so two trees that reused a version number would discover each other and the
# isolated fixtures would stop being isolated.
#=============================================================================
VER_MAIN=2040.1        # on PATH, usable                     - the good case
VER_BLOCKED=2040.2     # sibling, bin/vivado not executable   - the third state
VER_DANGLE=2040.3      # sibling, bin/vivado dangling symlink
VER_EMPTY=2040.4       # sibling, exists, has no bin/ at all  - the autofs shape
VER_SIBLING=2040.5     # sibling, usable, advertised by nobody
VER_UNRESOLVED=2040.9  # a modulefile this parser cannot read
VER_CLEAN=2041.1       # its own tree, no siblings            - the clean bill
VER_ONLY_DANGLE=2042.3 # alone in its tree, dangling
VER_ONLY_EMPTY=2042.4  # alone in its tree, no bin/
VER_GHOST=2043.6       # advertised; the root does not exist
VER_LOCKED=2044.8      # advertised; real vivado, unreadable parent

# EVERY INSTALL TREE LIVES UNDER ONE SUBDIRECTORY, and that is isolation rather
# than tidiness. siblings() scans `<grandparent>/*/<basename of the root>` as
# well as `<parent>/*`, so an install root placed directly in the sandbox has
# $TMPDIR for its grandparent - and doctor then globs $TMPDIR/*/<name> and finds
# the install trees belonging to OTHER sandboxes: one kept by T_KEEP=1, or one
# belonging to a concurrent run of this same suite, which this repository has
# several of at once. Measured, not theorised: the first version of this fixture
# reported an install from a sandbox that had been removed from the previous
# run's variables but not from the disk. One directory level makes the deepest
# glob doctor can reach stop at $SB.
TREES="$SB/trees"
XIL="$TREES/xil"              # the "site" tree: one good install and four traps
CLEAN_ROOT="$TREES/clean/$VER_CLEAN"
NOVER_ROOT="$TREES/noversion" # an install root whose path carries no version
LOCKED="$TREES/locked"        # the group-restricted-mount shape
GHOST_ROOT="$TREES/ghost/$VER_GHOST"   # never created, on purpose
RAN="$SB/ran"                 # one file per stub that was EXECUTED
TOOLS="$SB/tools"             # the canonical stubs
BIN="$SB/bin"                 # one directory per PATH flavour
MOD="$SB/mod"                 # one directory per MODULEPATH flavour
LIC_FILE="$SB/licence.dat"    # a file-based licence value: no port@host in it

mkdir -p "$RAN" "$TOOLS" "$BIN" "$MOD" "$TREES" "$SB/home" "$SB/tmp" \
         "$SB/build" "$SB/cwd" || { t_fail doctor.fixture "could not build the fixture under $SB"; t_summary; exit $?; }
: > "$LIC_FILE"

## mkstub <path> <stdout line|-> <stderr line|-> <exit code>
##
## An executable that RECORDS THAT IT RAN before doing anything else. The
## recording is what lets doctor.notool assert "no EDA tool was launched"
## instead of quoting the comment that says so.
##
## The record path is baked in at creation time rather than read from the
## environment, because the whole point of these runs is that doctor sees an
## environment this file cleared.
mkstub() {
    local p="$1" out="$2" err="$3" rc="$4" nm
    nm="$(basename "$p")"
    # THE NAME IS BAKED IN AT CREATION TIME, and `echo` is the only command the
    # stub uses, because a stub runs under the same `env -i PATH=<stubs only>`
    # as doctor does: there is no basename(1), no cat and no date on that PATH.
    # A stub that shelled out would write nothing, and the tripwire below would
    # then report "no EDA tool ran" on a run that launched one.
    #
    # Unquoted heredoc, so $RAN and $nm expand now. NO BACKTICKS: a backtick
    # inside an unquoted heredoc is command substitution, and that has already
    # corrupted one fixture in this repository.
    cat > "$p" <<EOF
#!/bin/sh
# a stub planted by t_doctor.sh. It records that it ran, which is the only
# reason it exists in an executable form at all.
echo ran >> "$RAN/$nm"
EOF
    [ "$out" = - ] || printf 'echo "%s"\n' "$out" >> "$p"
    [ "$err" = - ] || printf 'echo "%s" >&2\n' "$err" >> "$p"
    printf 'exit %s\n' "$rc" >> "$p"
    chmod +x "$p"
}

# The canonical stubs. tclsh and git are the two doctor actually launches (for
# their versions); make and the licence utilities are pure tripwires.
mkstub "$TOOLS/make"   "GNU Make 4.0-stub"  - 0
mkstub "$TOOLS/tclsh"  "8.6.12"             - 0
mkstub "$TOOLS/git"    "git version 2.0.0-stub" - 0
mkstub "$TOOLS/lmutil" "lmutil - stub"      - 0
mkstub "$TOOLS/lmstat" "lmstat - stub"      - 0
# A tclsh that is installed and CANNOT START: the input that decides whether
# doctor can tell "present" from "present and unusable" in its support-tool tier.
#
# THE MESSAGE CARRIES A VERSION NUMBER ON PURPOSE, and this is the fixture
# earning its keep rather than decoration. A real dynamic-linker failure names
# the SONAME it could not find, and a soname carries the library's version - so
# the string a broken tclsh prints while dying is one that any "does this look
# like a version?" test accepts. With `libtcl.so` in it, doctor could pass this
# case by parsing alone and the exit status could go on being ignored; with
# `libtcl8.6.so` in it, only grading the status gets the answer right. The
# fixture has to be able to fool the weaker of the two checks or it does not
# measure the stronger one.
TCL_BROKEN_ERR="tclsh: error while loading shared libraries: libtcl8.6.so: cannot open shared object file"
mkstub "$TOOLS/tclsh-broken" - "$TCL_BROKEN_ERR" 127
# A tclsh that answers nothing at all and exits 0.
mkstub "$TOOLS/tclsh-silent" - - 0

## install_root <root> <state>  - one Vivado install root in the fixture
##   ok        bin/vivado, executable
##   blocked   bin/vivado, NOT executable      (the third state)
##   dangling  bin/vivado -> nothing           (a symlink that resolves nowhere)
##   empty     the root, and no bin/ at all    (the empty autofs mount point)
install_root() {
    local root="$1" state="$2"
    case "$state" in
        empty)    mkdir -p "$root" ;;
        dangling) mkdir -p "$root/bin"
                  ln -s "$root/there-is-no-vivado-here" "$root/bin/vivado" ;;
        ok)       mkdir -p "$root/bin"; mkstub "$root/bin/vivado" "Vivado stub" - 0 ;;
        blocked)  mkdir -p "$root/bin"; mkstub "$root/bin/vivado" "Vivado stub" - 0
                  chmod 644 "$root/bin/vivado" ;;
        *) echo "install_root: unknown state $state" >&2; return 2 ;;
    esac
}

install_root "$XIL/$VER_MAIN"     ok
install_root "$XIL/$VER_BLOCKED"  blocked
install_root "$XIL/$VER_DANGLE"   dangling
install_root "$XIL/$VER_EMPTY"    empty
install_root "$XIL/$VER_SIBLING"  ok
install_root "$CLEAN_ROOT"        ok
install_root "$NOVER_ROOT"        ok
install_root "$TREES/only-dangle/$VER_ONLY_DANGLE" dangling
install_root "$TREES/only-empty/$VER_ONLY_EMPTY"   empty
install_root "$LOCKED/$VER_LOCKED"              ok

## flavour <name> <spec>...  -> prints a PATH directory
## A spec is `tool` (link the canonical stub) or `tool=/path` (link that).
flavour() {
    local dir="$BIN/$1"; shift
    local spec name src
    mkdir -p "$dir"
    for spec in "$@"; do
        name="${spec%%=*}"; src="${spec#*=}"
        [ "$name" = "$spec" ] && src="$TOOLS/$name"
        ln -sf "$src" "$dir/$name"
    done
    printf '%s' "$dir"
}

# `python3=$PYBIN` on purpose: doctor compares the python3 on PATH with the one
# running it by realpath, and a DIFFERENT one produces an extra report line.
# The suite wants that line only where it is the thing being asserted.
BIN_FULL="$(flavour full      "vivado=$XIL/$VER_MAIN/bin/vivado" make tclsh git "python3=$PYBIN" lmutil lmstat)"
BIN_CLEAN="$(flavour clean    "vivado=$CLEAN_ROOT/bin/vivado"    make tclsh git "python3=$PYBIN")"
BIN_NOVIVADO="$(flavour novivado                                 make tclsh git "python3=$PYBIN")"
BIN_NOMAKE="$(flavour nomake  "vivado=$XIL/$VER_MAIN/bin/vivado"      tclsh git "python3=$PYBIN")"
BIN_NOPY="$(flavour nopy      "vivado=$XIL/$VER_MAIN/bin/vivado" make tclsh git)"
BIN_BARE="$(flavour bare      "vivado=$XIL/$VER_MAIN/bin/vivado" make           "python3=$PYBIN")"
BIN_NOVER="$(flavour nover    "vivado=$NOVER_ROOT/bin/vivado"    make tclsh git "python3=$PYBIN")"
BIN_TCLBAD="$(flavour tclbad  "vivado=$XIL/$VER_MAIN/bin/vivado" make git "python3=$PYBIN" "tclsh=$TOOLS/tclsh-broken")"
BIN_TCLMUTE="$(flavour tclmute "vivado=$XIL/$VER_MAIN/bin/vivado" make git "python3=$PYBIN" "tclsh=$TOOLS/tclsh-silent")"

## modulefile <dir> <version> <root|-> [alias target]
## A modulefile is Tcl, and doctor parses it as text rather than sourcing it.
## `-` writes one with no PATH and no XILINX_VIVADO line: the shape doctor must
## report as unresolved instead of dropping.
modulefile() {
    local dir="$1" ver="$2" root="$3"
    mkdir -p "$dir/vivado"
    if [ "$root" = - ]; then
        printf '#%%Module1.0\nsetenv SOMETHING_ELSE 1\n' > "$dir/vivado/$ver"
    else
        printf '#%%Module1.0\nset root %s\nprepend-path PATH $root/bin\n' \
            "$root" > "$dir/vivado/$ver"
    fi
}

# The site tree: one real version, one alias, one unreadable modulefile, one
# ghost. This is the shape doctor's header records as measured on a real site.
modulefile "$MOD/site" "$VER_MAIN"       "$XIL/$VER_MAIN"
modulefile "$MOD/site" "$VER_UNRESOLVED" -
modulefile "$MOD/site" "$VER_GHOST"      "$GHOST_ROOT"
ln -sf "$VER_MAIN" "$MOD/site/vivado/latest"
# One tree of its own for the clean bill of health, and one for the
# permission-versus-missing comparison.
modulefile "$MOD/clean"  "$VER_CLEAN"  "$CLEAN_ROOT"
modulefile "$MOD/locked" "$VER_GHOST"  "$GHOST_ROOT"
modulefile "$MOD/locked" "$VER_LOCKED" "$LOCKED/$VER_LOCKED"

#=============================================================================
# DRIVING DOCTOR, AND READING WHAT IT SAID
#=============================================================================

## run_doctor <toolkit> <tag> <cwd> <PATH dir> [VAR=VAL...]
##   -> sets DR_OUT (everything it printed) and DR_RC
##
## SETS VARIABLES rather than printing, for the reason t_sandbox documents: the
## caller needs two results and `X=$(run_doctor ...)` loses one of them.
##
## `env -i` is the point of the whole file. Inheriting the real environment
## would mean MODULEPATH, XILINXD_LICENSE_FILE and XILINX_VIVADO decided what
## doctor saw, and every assertion below would be a statement about the machine
## that ran it rather than about the toolkit.
run_doctor() {
    local flow="$1" tag="$2" cwd="$3" bin="$4"; shift 4
    DR_OUT="$SB/out-$tag.txt"
    DR_RC=0
    ( cd "$cwd" && env -i PATH="$bin" HOME="$SB/home" TMPDIR="$SB/tmp" "$@" \
        "$PYBIN" "$flow/$DOCTOR_REL" ) > "$DR_OUT" 2>&1 || DR_RC=$?
    return 0
}

## The report's line format is `"  %-6s %-*s %s" % (status, 24, name, detail)`,
## so a status line is two spaces, a 6-wide status, a space, a 24-wide name and
## then the detail - while a NOTE is nine spaces and prose. Reading it by column
## rather than by grep is not fussiness: the notes quote the names, and a loose
## grep for "vivado on PATH" matches the paragraph explaining what to do about
## it as happily as the line reporting it. A name longer than 24 overflows its
## field, which is why this matches the name as a PREFIX of the field and looks
## for the detail in what is left.

## dr_detail <out> <status> <name> -> prints the detail; non-zero if no such line
##
## Answers about the FIRST matching line, so it is only for items the report
## carries once. Use dr_has for anything reported per version - it looks at all
## of them.
dr_detail() {
    awk -v st="$2" -v nm="$3" '
        substr($0, 1, 2) != "  " { next }
        {
            s = substr($0, 3, 6); sub(/ +$/, "", s)
            if (s != st) next
            rest = substr($0, 10)
            if (substr(rest, 1, length(nm)) != nm) next
            d = substr(rest, length(nm) + 1); sub(/^ +/, "", d)
            print d; found = 1; exit
        }
        END { exit(found ? 0 : 1) }
    ' "$1"
}

## dr_block <out> <status> <name> - the line AND the note paragraph under it.
## The reason a line gives is in its note, and two different faults reported
## with the same reason is itself a finding (doctor.state.untraversable).
dr_block() {
    awk -v st="$2" -v nm="$3" '
        !inblock {
            if (substr($0, 1, 2) != "  ") next
            s = substr($0, 3, 6); sub(/ +$/, "", s)
            if (s != st) next
            rest = substr($0, 10)
            if (substr(rest, 1, length(nm)) != nm) next
            inblock = 1; print; next
        }
        inblock { if ($0 ~ /^         [^ ]/) { print; next } exit }
    ' "$1"
}

## dr_has <out> <status> <name> [detail substring]
##
## EVERY matching line is considered, not the first. `installed, not advertised`
## is reported once per version, and a matcher that stopped at the first would
## answer about whichever one sorted earliest - which is a test that passes or
## fails for a reason the reader cannot see.
dr_has() {
    awk -v st="$2" -v nm="$3" -v dt="${4-}" -v want="$#" '
        substr($0, 1, 2) != "  " { next }
        {
            s = substr($0, 3, 6); sub(/ +$/, "", s)
            if (s != st) next
            rest = substr($0, 10)
            if (substr(rest, 1, length(nm)) != nm) next
            if (want > 3) {
                d = substr(rest, length(nm) + 1)
                if (index(d, dt) == 0) next
            }
            found = 1; exit
        }
        END { exit(found ? 0 : 1) }
    ' "$1"
}

## dr_dump <out> - the report without its notes, for a failure message. What
## doctor said INSTEAD is the interesting half of a missing line.
dr_dump() { grep -vE '^ {9}' "$1" | sed 's/^/    | /'; }

## dr_says / dr_lacks <out> <status> <name> [detail] - assert and explain
##
## THE EXPLANATION IS PRINTED LAST, after the report it is about. t_check shows
## the last fourteen lines of a failing command, and a suite whose diagnosis
## scrolled off the top of its own evidence would be one more thing to go and
## read somewhere else at three in the morning.
dr_says() {
    dr_has "$@" && return 0
    dr_dump "$1"
    printf 'the report above carries no  %s  line for "%s"%s\n' \
        "$2" "$3" "${4:+ whose detail contains \"$4\"}"
    return 1
}
dr_lacks() {
    dr_has "$@" || return 0
    dr_dump "$1"
    printf 'the report above carries a  %s  line for "%s"%s and it must not\n' \
        "$2" "$3" "${4:+ whose detail contains \"$4\"}"
    return 1
}

## dr_rc <expected> <what the status means here>
dr_rc() {
    [ "$DR_RC" = "$1" ] && return 0
    dr_dump "$DR_OUT"
    printf 'doctor exited %s on the report above; expected %s (%s)\n' "$DR_RC" "$1" "$2"
    return 1
}

## dr_advisory <out> - the advisory COUNT out of the summary line; empty if the
## run did not reach "Essentials present."
##
## Counted rather than described, because "it is reported" and "it counts" are
## different properties and the second one is the one with teeth: an item that
## prints a line and increments nothing still lets the run end with "This host
## can run the flow." Comparing two runs that differ in ONE fixture is the only
## way to attribute a count to that fixture - asserting a number would be
## asserting the sum of everything else in the run as well.
dr_advisory() {
    sed -n 's/^Essentials present\. \([0-9][0-9]*\) advisory item(s).*/\1/p' "$1"
}

## declared_list <toolkit> <NAME> - a tuple constant read OUT OF THE SCRIPT.
## Spelling the licence variables or the build-directory variables in this file
## would make the test agree with itself, and it would go stale silently the
## first time a fourth one was added - which is the defect this repository's
## third rule exists for.
declared_list() {
    sed -n "s/^$2 = (\(.*\))\$/\1/p" "$1/$DOCTOR_REL" \
        | tr -d '" ' | tr ',' '\n' | grep -v '^$'
}

#=============================================================================
# 1. THE CONTRACT AT THE EDGES
#
# Everything in this section is host-independent: it is what doctor promises a
# CALLER, and ci/capability.sh (kind: doctor) and mk/checks.mk both act on it.
#=============================================================================
t_head "the exit-status contract, at the two edges nothing else reaches"

## refuses_arguments <toolkit> <tag>
## `fpga-flow-doctor --part xyz` is somebody asking doctor a question about a
## PROJECT. Answering it with a host report would be worse than refusing: the
## report would be correct, and about something else.
refuses_arguments() {
    local flow="$1" out rc=0
    out="$(env -i PATH="$BIN_FULL" HOME="$SB/home" "$PYBIN" "$flow/$DOCTOR_REL" \
        --part some-part 2>&1)" || rc=$?
    if [ "$rc" -ne 2 ]; then
        printf 'doctor exited %s on an argument it does not take; the contract reserves 2 for "refused".\n' "$rc"
        printf '%s\n' "$out"; return 1
    fi
    t_contains "$out" "takes no arguments" || {
        printf 'exit 2 with nothing that says WHY. A caller that cannot tell a refusal from a\n'
        printf 'crash retries the wrong one:\n%s\n' "$out"; return 1; }
    t_contains "$out" "fpga-flow-check" || {
        printf 'the refusal does not name the script that DOES answer a question about a project,\n'
        printf 'so the reader is refused and left nowhere:\n%s\n' "$out"; return 1; }
    return 0
}

## documents_its_exit_codes <toolkit> <tag>
## The four statuses are the whole interface for a caller that is not a human.
documents_its_exit_codes() {
    local flow="$1" out rc=0 code
    out="$(env -i PATH="$BIN_FULL" HOME="$SB/home" "$PYBIN" "$flow/$DOCTOR_REL" \
        --help 2>&1)" || rc=$?
    [ "$rc" -eq 0 ] || { printf -- '--help exited %s; asking for help is not an error.\n%s\n' "$rc" "$out"; return 1; }
    t_contains "$out" "Exit status:" || {
        printf -- '--help prints no exit-status block. mk/checks.mk and ci/capability.sh both\n'
        printf 'branch on the status, and this is where a reader finds out what it means.\n%s\n' "$out"
        return 1; }
    for code in 0 1 2 130; do
        t_matches "$out" "^ +$code +[A-Za-z]" || {
            printf -- '--help documents no exit code %s. The four codes are the interface.\n%s\n' "$code" "$out"
            return 1; }
    done
    return 0
}

t_check doctor.args \
    "an argument is REFUSED with exit 2, and the refusal names fpga-flow-check" \
    refuses_arguments "$FLOW_DIR"

t_check doctor.help \
    "--help exits 0 and documents all four exit codes a caller branches on" \
    documents_its_exit_codes "$FLOW_DIR"

M="$(t_mutant "$SB" args)"
if t_mutate "$M" "$DOCTOR_REL" '/It reports on THIS HOST/,+2s/^        return 2$/        return 0/'; then
    t_check_fail doctor.args.mutation \
        "with the refusal returning 0, a question about a project gets a clean host report and the assertion goes red" \
        refuses_arguments "$M"
else
    t_skip doctor.args.mutation "could not plant the fault: the 'return 2' under the 'It reports on THIS HOST' message in $DOCTOR_REL has moved or been reformatted, so this proof is aimed at nothing"
fi

M="$(t_mutant "$SB" help)"
if t_replace_line "$M" "$DOCTOR_REL" '            sys.stdout.write(__doc__)' \
                                     '            sys.stdout.write("")'; then
    t_check_fail doctor.help.mutation \
        "with --help printing nothing, the exit-code contract is undocumented and the assertion goes red" \
        documents_its_exit_codes "$M"
else
    t_skip doctor.help.mutation "could not plant the fault: $DOCTOR_REL has no line exactly '            sys.stdout.write(__doc__)'"
fi

#-----------------------------------------------------------------------------
# THE CRASH ARM. doctor's own comment: "Never exit 0 on a crash: a doctor that
# dies quietly is read as a clean bill of health, which is the one thing it must
# never be."
#
# THE CRASH IS THE FIXTURE, NOT THE PROOF. There is no way to make a correct
# doctor raise from outside it, so the assertion runs against a copy with a
# deliberate AttributeError planted in report_resources - the last section, so
# the run has already printed a page of perfectly good report before it dies,
# which is exactly the shape that reads as a pass. The PROOF then plants the
# same crash AND neuters the handler, and is the only place in this file where
# a mutant carries two edits; both are named in the skip reason if either fails
# to apply.
#-----------------------------------------------------------------------------
CRASH_SED='s/^    ncpu = os.cpu_count() or 0$/    ncpu = os.cpu_count_no_such_attribute()/'

## crash_is_not_a_pass <toolkit> <tag>
crash_is_not_a_pass() {
    run_doctor "$1" "$2" "$SB/cwd" "$BIN_FULL" BUILD_DIR="$SB/build"
    dr_rc 2 "the contract reserves 2 for a crash" || return 1
    t_contains "$(cat "$DR_OUT")" "CRASHED" || {
        printf 'doctor died without saying it died. The report above it is complete and correct,\n'
        printf 'which is what makes a silent non-zero exit read as a tool problem rather than as\n'
        printf 'an unfinished measurement:\n'; dr_dump "$DR_OUT"; return 1; }
    t_contains "$(cat "$DR_OUT")" "Traceback" || {
        printf 'it says it crashed and prints no traceback, so nothing says WHERE.\n'; return 1; }
    return 0
}

CRASH_M="$(t_mutant "$SB" crash)"
if t_mutate "$CRASH_M" "$DOCTOR_REL" "$CRASH_SED"; then
    t_check doctor.crash \
        "a doctor that raises exits 2 and SAYS it crashed - it never reports a clean host" \
        crash_is_not_a_pass "$CRASH_M" crash

    M="$(t_mutant "$SB" crashhandler)"
    if t_mutate "$M" "$DOCTOR_REL" "$CRASH_SED" \
       && t_mutate "$M" "$DOCTOR_REL" '/CRASHED (traceback above)/,+1s/^        return 2$/        return 0/'; then
        t_check_fail doctor.crash.mutation \
            "with the crash handler returning 0, the same crash reports a healthy host and the assertion goes red" \
            crash_is_not_a_pass "$M" crash-mut
    else
        t_skip doctor.crash.mutation "could not plant the fault: the proof needs BOTH the cpu_count crash and the 'return 2' under the CRASHED message, and one of the two no longer matches in $DOCTOR_REL"
    fi
else
    t_skip doctor.crash "could not plant the crash fixture: $DOCTOR_REL has no line exactly '    ncpu = os.cpu_count() or 0', so there is nothing to make this copy raise from"
    t_skip doctor.crash.mutation "not attempted: the crash fixture it depends on could not be planted in the first place"
fi

#=============================================================================
# 2. THE TOOL CENSUS, ON A PATH THIS FILE DECIDES
#
# The three answers doctor can give about a tool - here, not here, and here but
# advisory - and the one it must never give, which is an answer about the tool
# it is itself running under when it was asked about the one make will find.
#=============================================================================
t_head "a tool that is present, a tool that is absent, and which of the two is fatal"

## reports_vivado_present <toolkit> <tag>
## Both halves: the binary it found, and the version - which doctor derives
## from the install PATH and LABELS as such, because launching Vivado to ask
## costs tens of seconds and a licence queue.
reports_vivado_present() {
    run_doctor "$1" "$2" "$SB/cwd" "$BIN_FULL" BUILD_DIR="$SB/build"
    dr_says "$DR_OUT" ok "vivado on PATH" "$BIN_FULL/vivado" || return 1
    dr_says "$DR_OUT" ok "vivado on PATH" "(version $VER_MAIN, from the install path)" || return 1
    dr_says "$DR_OUT" ok "installed $VER_MAIN" "$XIL/$VER_MAIN" || return 1
    dr_rc 0 "every essential is present on this fixture" || return 1
    return 0
}

## reports_vivado_absent <toolkit> <tag> - the message half
reports_vivado_absent() {
    run_doctor "$1" "$2" "$SB/cwd" "$BIN_NOVIVADO" BUILD_DIR="$SB/build"
    dr_says "$DR_OUT" MISS "vivado on PATH" "not found" || return 1
    dr_says "$DR_OUT" MISS "installed versions" "none found on this filesystem" || return 1
    dr_lacks "$DR_OUT" ok "vivado on PATH" || return 1
    return 0
}

## vivado_absent_is_fatal <toolkit> <tag> - the exit-status half
## Asserted separately and proved separately, because they fail apart: a report
## that says MISS and exits 0 is read by ci/capability.sh as a host that can run
## the flow, and a non-zero exit with nothing that says which item is missing
## sends the reader to the wrong layer.
vivado_absent_is_fatal() {
    run_doctor "$1" "$2" "$SB/cwd" "$BIN_NOVIVADO" BUILD_DIR="$SB/build"
    dr_rc 1 "an essential item is missing - the flow cannot run on this host" || return 1
    t_matches "$(cat "$DR_OUT")" "^[0-9]+ ESSENTIAL item\(s\) missing" || {
        printf 'it exited 1 and the summary never says an ESSENTIAL item is missing.\n'; dr_dump "$DR_OUT"; return 1; }
    t_contains "$(cat "$DR_OUT")" "This host can run the flow." && {
        printf 'it printed a clean bill of health AND exited 1.\n'; dr_dump "$DR_OUT"; return 1; }
    return 0
}

t_check doctor.tool.present \
    "vivado on PATH is reported present, with its path and the version read off the install path" \
    reports_vivado_present "$FLOW_DIR" present

t_check doctor.tool.absent \
    "vivado absent is reported MISS twice - not on PATH, and no install on the filesystem" \
    reports_vivado_absent "$FLOW_DIR" absent

t_check doctor.tool.absent.exit \
    "and the exit status is 1, with a summary line that says an ESSENTIAL item is missing" \
    vivado_absent_is_fatal "$FLOW_DIR" absent-exit

M="$(t_mutant "$SB" version)"
if t_replace_line "$M" "$DOCTOR_REL" '        if re.match(r"^\d{4}\.\d+$", p):' \
                                     '        if False:'; then
    t_check_fail doctor.tool.present.mutation \
        "with the version pattern matching nothing, a perfectly good install reports as version unknown and the assertion goes red" \
        reports_vivado_present "$M" present-mut
else
    t_skip doctor.tool.present.mutation "could not plant the fault: version_of's '^\\d{4}\\.\\d+\$' line in $DOCTOR_REL has changed shape"
fi

M="$(t_mutant "$SB" absent)"
if t_replace_line "$M" "$DOCTOR_REL" '        d.essential("vivado on PATH", "not found")' \
                                     '        line("ok", "vivado on PATH", "not found")'; then
    t_check_fail doctor.tool.absent.mutation \
        "with the absent case reported as ok, a host with no Vivado reads as a host with one and the assertion goes red" \
        reports_vivado_absent "$M" absent-mut
else
    t_skip doctor.tool.absent.mutation "could not plant the fault: $DOCTOR_REL has no line exactly '        d.essential(\"vivado on PATH\", \"not found\")'"
fi

M="$(t_mutant "$SB" fatalcount)"
if t_replace_line "$M" "$DOCTOR_REL" '        self.fatal += 1' '        self.fatal += 0'; then
    t_check_fail doctor.tool.absent.exit.mutation \
        "with the essential counter never incrementing, every MISS still prints and the run exits 0 - the assertion goes red" \
        vivado_absent_is_fatal "$M" absent-exit-mut
else
    t_skip doctor.tool.absent.exit.mutation "could not plant the fault: Doctor.essential in $DOCTOR_REL has no line exactly '        self.fatal += 1'"
fi

#-----------------------------------------------------------------------------
# ESSENTIAL vs ADVISORY. Doctor's own docstring: "a host with no licence server
# reachable right now is still a host that can run the flow in ten minutes, and
# a doctor that exits 1 on it teaches people to ignore it." The split is only
# real if it is asserted from both sides.
#-----------------------------------------------------------------------------
t_head "the essential/advisory split is a behaviour, not a comment"

## make_is_essential <toolkit> <tag>
make_is_essential() {
    run_doctor "$1" "$2" "$SB/cwd" "$BIN_NOMAKE" BUILD_DIR="$SB/build"
    dr_says "$DR_OUT" MISS "make" "not on PATH" || return 1
    dr_rc 1 "the engine is GNU make; without it nothing in the flow runs" || return 1
    return 0
}

## helpers_are_advisory <toolkit> <tag>
## tclsh and git missing cost provenance and offline syntax checking. They do
## not stop a build, and a doctor that failed the host over them would be
## ignored on the day it reported something that did.
helpers_are_advisory() {
    run_doctor "$1" "$2" "$SB/cwd" "$BIN_BARE" BUILD_DIR="$SB/build"
    dr_says "$DR_OUT" -- "tclsh" "not on PATH" || return 1
    dr_says "$DR_OUT" -- "git"   "not on PATH" || return 1
    dr_lacks "$DR_OUT" MISS "tclsh" || return 1
    dr_lacks "$DR_OUT" MISS "git"   || return 1
    dr_rc 0 "neither tclsh nor git stops a build" || return 1
    t_matches "$(cat "$DR_OUT")" "^Essentials present\." || {
        printf 'exit 0 without saying so. The summary is what a reader acts on:\n'; dr_dump "$DR_OUT"; return 1; }
    return 0
}

## python_on_path_is_not_the_interpreter <toolkit> <tag>
## doctor is python3 and is therefore GUARANTEED to have a python3 - the one
## that started it. make recipes call `python3` and get whatever PATH offers.
## Reporting the first as an answer about the second is the purest form of this
## suite's defect class: a true statement about the wrong thing.
python_on_path_is_not_the_interpreter() {
    run_doctor "$1" "$2" "$SB/cwd" "$BIN_NOPY" BUILD_DIR="$SB/build"
    dr_says "$DR_OUT" ok   "python3 (running)" || return 1
    dr_says "$DR_OUT" MISS "python3 on PATH" "not found" || return 1
    dr_rc 1 "make recipes call python3 and will not find one" || return 1
    return 0
}

t_check doctor.tool.essential.make \
    "make absent is ESSENTIAL: MISS, and exit 1" \
    make_is_essential "$FLOW_DIR" nomake

t_check doctor.tool.advisory \
    "tclsh and git absent are ADVISORY: reported, and the host still passes" \
    helpers_are_advisory "$FLOW_DIR" bare

t_check doctor.tool.python \
    "an absent python3 on PATH is MISS even though doctor is itself running under one" \
    python_on_path_is_not_the_interpreter "$FLOW_DIR" nopy

M="$(t_mutant "$SB" makeadvisory)"
if t_replace_line "$M" "$DOCTOR_REL" '    d.tool("make", True, "The engine is GNU make.")' \
                                     '    d.tool("make", False, "The engine is GNU make.")'; then
    t_check_fail doctor.tool.essential.make.mutation \
        "with make demoted to advisory, a host that cannot run the engine passes and the assertion goes red" \
        make_is_essential "$M" nomake-mut
else
    t_skip doctor.tool.essential.make.mutation "could not plant the fault: the d.tool(\"make\", ...) call in $DOCTOR_REL has changed shape"
fi

M="$(t_mutant "$SB" tclessential)"
if t_replace_line "$M" "$DOCTOR_REL" '    d.tool("tclsh", False,' \
                                     '    d.tool("tclsh", True,'; then
    t_check_fail doctor.tool.advisory.mutation \
        "with tclsh promoted to essential, a host that can build perfectly well is failed and the assertion goes red" \
        helpers_are_advisory "$M" bare-mut
else
    t_skip doctor.tool.advisory.mutation "could not plant the fault: the d.tool(\"tclsh\", ...) call in $DOCTOR_REL has changed shape"
fi

M="$(t_mutant "$SB" pypath)"
if t_replace_line "$M" "$DOCTOR_REL" '    elif not py:' '    elif False:'; then
    t_check_fail doctor.tool.python.mutation \
        "with the python3-on-PATH arm unreachable, the absence is silently dropped and the assertion goes red" \
        python_on_path_is_not_the_interpreter "$M" nopy-mut
else
    t_skip doctor.tool.python.mutation "could not plant the fault: $DOCTOR_REL has no line exactly '    elif not py:'"
fi

#-----------------------------------------------------------------------------
# THE VERSION OF A SUPPORT TOOL, AND WHAT HAPPENS WHEN IT CANNOT BE READ.
#
# One predicate, three inputs. doctor's own standard for this is written in its
# disk branch: "Reported as unmeasured rather than as fine. A check that could
# not read its input has not passed; it has not run." The tclsh and git version
# lines were the place that standard was NOT met, and the two assertions below
# were carried here as t_known_defect until 2026-09-14 - which is the whole
# reason they exist in this shape. Writing the predicate found both: a run()
# that merged stderr into stdout and dropped the exit status, so a tclsh that
# could not start had the LINKER'S ERROR printed as its version under `ok`, and
# a tclsh that answered nothing lost the line altogether.
#
# THE THREE INPUTS FAIL IN THREE DIRECTIONS, which is why one predicate is not
# enough and each has its own assertion below it:
#   a working tclsh      the version is read and printed        (doctor.tool.version)
#   one that cannot run  present, and unusable - never `ok`     (...version.garbage)
#   one that says nothing the version is unknown, and SAID to be (...version.silent)
# The second and third are opposite errors: reporting a silent tool as broken is
# as wrong as reporting a broken one as fine, so each asserts the other's case
# did not happen.
#-----------------------------------------------------------------------------
t_head "a version doctor could not read must be reported, not passed off or dropped"

## tool_version_is_honest <toolkit> <tag> <PATH flavour>
##
## The rule, applied to whatever the stub on that PATH does:
##   - there must be a line about tclsh's version at all. A missing line reads
##     as "fine" and nothing distinguishes it from a version nobody asked for.
##   - if that line is `ok`, its detail must LOOK like a version - it starts
##     with a digit. Anything else under `ok` is doctor stating, as a measured
##     fact, a string it did not parse.
## Both halves are satisfied by a working tclsh, which is what makes this a
## predicate that can pass and not a wish.
tool_version_is_honest() {
    local flow="$1" tag="$2" bin="$3" det st
    run_doctor "$flow" "$tag" "$SB/cwd" "$bin" BUILD_DIR="$SB/build"
    if det="$(dr_detail "$DR_OUT" ok "  tclsh version")"; then
        case "$det" in
            [0-9]*) return 0 ;;
            *) printf 'doctor reports, as an `ok` measured version:\n    %s\n' "$det"
               printf 'That is not a version. run() merges the child stderr into its stdout and\n'
               printf 'ignores the exit status, so a tclsh that cannot start at all has its\n'
               printf "linker error printed in the version's place, under ok.\n"
               dr_dump "$DR_OUT"; return 1 ;;
        esac
    fi
    # No `ok` version line. Any other status is honest - it says the version is
    # not known. Nothing at all is not.
    for st in -- WARN MISS; do
        dr_has "$DR_OUT" "$st" "  tclsh version" && return 0
    done
    printf 'tclsh is on PATH and reported `ok`, and the report says NOTHING about its version.\n'
    printf 'The line is simply absent, so a tclsh that answers nothing is indistinguishable\n'
    printf 'from one nobody asked. doctor applies the opposite rule to disk one section later:\n'
    printf '"A check that could not read its input has not passed; it has not run."\n'
    dr_dump "$DR_OUT"
    return 1
}

## unusable_tool_is_not_ok <toolkit> <tag>
##
## A tclsh on PATH that exits 127. Everything the report has to get right about
## it, in one run - and the first line is the generic rule above, so this does
## not restate it and cannot drift from it.
##
## What was MEASURED here before the fix:
##   ok     tclsh            <path>
##   ok       tclsh version  tclsh: error while loading shared libraries: libtcl...
## Two `ok` lines about a tool that cannot start, and the linker's message
## printed as a measured version.
unusable_tool_is_not_ok() {
    local flow="$1" tag="$2"
    tool_version_is_honest "$flow" "$tag-rule" "$BIN_TCLBAD" || return 1

    run_doctor "$flow" "$tag" "$SB/cwd" "$BIN_TCLBAD" BUILD_DIR="$SB/build"

    # THE TOOL'S OWN LINE, not just the version's. "Present" is true and "ok" is
    # not: a reader scanning the status column must not come away with a host
    # that has a working tclsh, because that column is the whole reason a report
    # is faster than looking.
    dr_lacks "$DR_OUT" ok   "tclsh" || return 1
    dr_says  "$DR_OUT" WARN "tclsh" "$BIN_TCLBAD/tclsh" || return 1

    # And it says what it MEASURED. "Present and unusable" with no exit status
    # behind it is an opinion, and the status is the one fact that separates
    # this from a tool doctor simply failed to parse.
    t_contains "$(dr_block "$DR_OUT" WARN "tclsh")" "exited 127" || {
        printf 'doctor reports tclsh as unusable and never says what it measured. The exit\n'
        printf 'status is the evidence, and a reader with no evidence has to go and run it:\n'
        dr_block "$DR_OUT" WARN "tclsh"; return 1; }

    # Nothing the dying tool printed appears under an `ok` ANYWHERE. Aimed at
    # the whole report rather than at the version line, because the defect was
    # never really about that line: it was about text from a failed probe being
    # restated as a measurement.
    if grep -E '^  ok ' "$DR_OUT" | grep -qF -- "${TCL_BROKEN_ERR:0:40}"; then
        printf 'what the tool printed while FAILING is repeated on an `ok` line:\n'
        grep -E '^  ok ' "$DR_OUT" | sed 's/^/    | /'
        printf 'That is a measured fact stated about a tool that never started.\n'
        return 1
    fi

    # THE EXIT CONTRACT. tclsh is advisory (Vivado carries its own Tcl), so
    # discovering that it is broken must NOT fail the host: doctor's own
    # docstring - "a doctor that exits 1 on it teaches people to ignore it" - is
    # the reason a newly-detected fault does not get to change the status.
    dr_rc 0 "a broken tclsh is advisory; the flow never launches one" || return 1
    t_matches "$(cat "$DR_OUT")" "^Essentials present\." || {
        printf 'exit 0 without saying so, on a run that found a tool it could not start:\n'
        dr_dump "$DR_OUT"; return 1; }
    return 0
}

## silent_version_is_unknown_and_counts <toolkit> <tag>
##
## The opposite error to the one above, and the reason they are two assertions:
## a tclsh that exits 0 and prints nothing IS usable. The tool line must stay
## `ok` and only the VERSION is unknown - reporting the tool as broken here
## would be the same class of defect pointed the other way.
##
## The second half is the half with teeth. A line that reports something and
## increments nothing still lets the run finish with "This host can run the
## flow.", so the count is measured against a control run that differs only in
## which tclsh is on PATH. doctor does exactly this for a disk it could not
## measure, one section later.
silent_version_is_unknown_and_counts() {
    local flow="$1" tag="$2" base got

    tool_version_is_honest "$flow" "$tag-rule" "$BIN_TCLMUTE" || return 1

    run_doctor "$flow" "$tag-control" "$SB/cwd" "$BIN_FULL" BUILD_DIR="$SB/build"
    base="$(dr_advisory "$DR_OUT")"
    [ -n "$base" ] || {
        printf 'the control run never reached "Essentials present.", so there is no advisory\n'
        printf 'count to compare against and the second half of this assertion would be vacuous:\n'
        dr_dump "$DR_OUT"; return 1; }

    run_doctor "$flow" "$tag" "$SB/cwd" "$BIN_TCLMUTE" BUILD_DIR="$SB/build"
    dr_says "$DR_OUT" ok "tclsh" "$BIN_TCLMUTE/tclsh" || return 1
    dr_lacks "$DR_OUT" WARN "tclsh" || return 1
    dr_says "$DR_OUT" -- "  tclsh version" "unknown" || return 1

    got="$(dr_advisory "$DR_OUT")"
    [ -n "$got" ] || {
        printf 'the run did not reach "Essentials present." at all:\n'; dr_dump "$DR_OUT"; return 1; }
    [ "$got" -eq $((base + 1)) ] || {
        printf 'the same host with a tclsh that answers nothing reports %s advisory item(s);\n' "$got"
        printf 'with one that answers, %s. A version doctor could not read has to COUNT, or\n' "$base"
        printf 'the summary a reader acts on says the host was measured clean when one of the\n'
        printf 'measurements did not happen. doctor does count an unmeasured disk.\n'
        dr_dump "$DR_OUT"; return 1; }
    dr_rc 0 "an unknown tclsh version is not a reason the flow cannot run here" || return 1
    return 0
}

t_check doctor.tool.version \
    "a working tclsh has its version read and reported beside it" \
    tool_version_is_honest "$FLOW_DIR" version-ok "$BIN_FULL"

t_check doctor.tool.version.garbage \
    "a tclsh that cannot start is WARN, never ok, and its failure text is never printed as a version" \
    unusable_tool_is_not_ok "$FLOW_DIR" version-broken

t_check doctor.tool.version.silent \
    "a tclsh that answers nothing keeps its ok - only the version is unknown, and the unknown counts" \
    silent_version_is_unknown_and_counts "$FLOW_DIR" version-silent

M="$(t_mutant "$SB" versionline)"
if t_replace_line "$M" "$DOCTOR_REL" '            line("ok", "  %s version" % name, ver)' \
                                     '            pass'; then
    t_check_fail doctor.tool.version.mutation \
        "with the version line suppressed, a working tclsh reports no version at all and the assertion goes red" \
        tool_version_is_honest "$M" version-mut "$BIN_FULL"
else
    t_skip doctor.tool.version.mutation "could not plant the fault: the ok version line inside Doctor.tool in $DOCTOR_REL has changed shape"
fi

# THE PROOF FOR THE BROKEN TOOL IS AIMED AT THE EXIT STATUS, and only at it. Two
# independent tests stand between a failed probe and an `ok` line - the child's
# status, and whether its output carries a version number at all - so a proof
# that removed either one and still went red would not say WHICH is load-bearing.
# It is the status: with it ignored, the stub's linker error parses as a version
# (it names libtcl8.6.so) and doctor prints it in the version's place, which is
# the defect verbatim.
M="$(t_mutant "$SB" versionrc)"
if t_replace_line "$M" "$DOCTOR_REL" '    if rc != 0:' '    if False:'; then
    t_check_fail doctor.tool.version.garbage.mutation \
        "with the exit status discarded again, a tclsh that cannot start reports ok and its linker error is printed as the version - the assertion goes red" \
        unusable_tool_is_not_ok "$M" version-broken-mut
else
    t_skip doctor.tool.version.garbage.mutation "could not plant the fault: probe_version's 'if rc != 0:' guard in $DOCTOR_REL has changed shape, and a mutation aimed at the version-token test beside it would prove the weaker of the two checks"
fi

# And the silent case's proof is aimed at the LINE. The defect was never a wrong
# answer; it was an absent one, and an absent line reads as fine.
M="$(t_mutant "$SB" versionsilent)"
if t_replace_line "$M" "$DOCTOR_REL" '        line("--", "  %s version" % name, "unknown - %s" % reason)' \
                                     '        pass'; then
    t_check_fail doctor.tool.version.silent.mutation \
        "with the unknown-version line dropped again, a tclsh that answers nothing is indistinguishable from one nobody asked and the assertion goes red" \
        silent_version_is_unknown_and_counts "$M" version-silent-mut
else
    t_skip doctor.tool.version.silent.mutation "could not plant the fault: the unknown-version line inside Doctor.tool in $DOCTOR_REL has changed shape"
fi

#=============================================================================
# 3. THE THREE STATES OF AN INSTALL
#
# usable() line 472: "Three states, because two is a lie on a shared site."
# absent / blocked / ok. The traps below are the shapes that look installed to
# anything cruder than doctor - and `test -d` is cruder than doctor.
#=============================================================================
t_head "present, absent, and present-but-not-usable-by-you"

## blocked_is_not_present <toolkit> <tag>
## An install whose bin/vivado is not executable BY YOU. doctor's note calls it
## "the third state a version can be in and the one that gets recorded as 'not
## installed' by whoever hits it first."
blocked_is_not_present() {
    run_doctor "$1" "$2" "$SB/cwd" "$BIN_FULL" BUILD_DIR="$SB/build"
    dr_says  "$DR_OUT" WARN "installed $VER_BLOCKED" "$XIL/$VER_BLOCKED" || return 1
    dr_lacks "$DR_OUT" ok   "installed $VER_BLOCKED" || return 1
    t_contains "$(dr_block "$DR_OUT" WARN "installed $VER_BLOCKED")" "NOT USABLE BY YOU" || {
        printf 'it is reported WARN and the note never says it is a PERMISSION rather than a\n'
        printf 'missing install, which is the whole difference between the two states:\n'
        dr_block "$DR_OUT" WARN "installed $VER_BLOCKED"; return 1; }
    dr_rc 0 "one usable version is present, so the host can still run the flow" || return 1
    return 0
}

## dangling_is_not_present <toolkit> <tag>
## bin/vivado is a symlink that resolves to nothing. `test -e` on the directory
## says yes, `ls bin/` says vivado, and the tool does not exist.
dangling_is_not_present() {
    local root="$TREES/only-dangle/$VER_ONLY_DANGLE"
    # Assert the FIXTURE first. A trap that stopped being a trap - the link
    # repaired, the directory gone - would make the assertion below pass for
    # the wrong reason, and nothing else here would notice.
    [ -L "$root/bin/vivado" ] && [ ! -e "$root/bin/vivado" ] || {
        printf 'the fixture is not a dangling symlink any more: %s\n' "$root/bin/vivado"; return 2; }
    run_doctor "$1" "$2" "$SB/cwd" "$BIN_NOVIVADO" BUILD_DIR="$SB/build" XILINX_VIVADO="$root"
    dr_lacks "$DR_OUT" ok   "installed $VER_ONLY_DANGLE" || return 1
    dr_lacks "$DR_OUT" WARN "installed $VER_ONLY_DANGLE" || return 1
    dr_says  "$DR_OUT" MISS "installed versions" "none found on this filesystem" || return 1
    dr_rc 1 "XILINX_VIVADO names a root whose vivado does not exist, so nothing is installed here" || return 1
    return 0
}

## empty_mount_is_not_present <toolkit> <tag>
## The documented hazard in this repository: an empty autofs mount point passes
## `test -d` and holds nothing. An install root discovered by directory shape
## alone would report a version that is not there.
empty_mount_is_not_present() {
    local root="$TREES/only-empty/$VER_ONLY_EMPTY"
    [ -d "$root" ] && [ ! -e "$root/bin" ] || {
        printf 'the fixture is not an empty directory any more: %s\n' "$root"; return 2; }
    run_doctor "$1" "$2" "$SB/cwd" "$BIN_NOVIVADO" BUILD_DIR="$SB/build" XILINX_VIVADO="$root"
    dr_lacks "$DR_OUT" ok   "installed $VER_ONLY_EMPTY" || return 1
    dr_lacks "$DR_OUT" WARN "installed $VER_ONLY_EMPTY" || return 1
    dr_says  "$DR_OUT" MISS "installed versions" "none found on this filesystem" || return 1
    return 0
}

## unknown_version_is_reported <toolkit> <tag>
## An install whose path carries no version. doctor derives the version from
## the path and says so; when the path does not say, the honest answer is
## "unknown" - and the install is still THERE, so dropping it would lose a
## usable Vivado over a directory-naming convention.
unknown_version_is_reported() {
    run_doctor "$1" "$2" "$SB/cwd" "$BIN_NOVER" BUILD_DIR="$SB/build"
    dr_says "$DR_OUT" ok "vivado on PATH" "(version unknown, from the install path)" || return 1
    dr_says "$DR_OUT" ok "installed unknown" "$NOVER_ROOT" || return 1
    dr_rc 0 "the install is usable; only its version is unknown" || return 1
    return 0
}

## sibling_is_discovered <toolkit> <tag>
## The measured site defect, from doctor's own header: "one installed version is
## advertised by no modulefile at all". It is found by scanning the SIBLINGS of
## the version directory the PATH binary lives in, which is the only way an
## install nothing points at can be found without a hardcoded list.
sibling_is_discovered() {
    run_doctor "$1" "$2" "$SB/cwd" "$BIN_FULL" BUILD_DIR="$SB/build"
    dr_says "$DR_OUT" ok "installed $VER_SIBLING" "$XIL/$VER_SIBLING" || return 1
    return 0
}

t_check doctor.state.blocked \
    "an install present but not executable by you is WARN, never ok, and the note says it is a permission" \
    blocked_is_not_present "$FLOW_DIR" blocked

t_check doctor.state.dangling \
    "a dangling bin/vivado symlink is not an installed version, and doctor says none was found" \
    dangling_is_not_present "$FLOW_DIR" dangling

t_check doctor.state.emptydir \
    "a root that exists with no bin/ - the empty autofs mount point - is not an installed version" \
    empty_mount_is_not_present "$FLOW_DIR" emptydir

t_check doctor.state.unknownver \
    "an install whose path carries no version is reported as unknown, not omitted" \
    unknown_version_is_reported "$FLOW_DIR" unknownver

t_check doctor.state.sibling \
    "a version nothing points at is found by scanning the siblings of the one on PATH" \
    sibling_is_discovered "$FLOW_DIR" sibling

M="$(t_mutant "$SB" blocked)"
if t_replace_line "$M" "$DOCTOR_REL" '    if not os.access(exe, os.X_OK):' \
                                     '    if False:'; then
    t_check_fail doctor.state.blocked.mutation \
        "with the executable-bit check removed, an install nobody can run reports ok and the assertion goes red" \
        blocked_is_not_present "$M" blocked-mut
else
    t_skip doctor.state.blocked.mutation "could not plant the fault: usable()'s os.access(exe, os.X_OK) guard in $DOCTOR_REL has changed shape"
fi

M="$(t_mutant "$SB" dangling)"
if t_replace_line "$M" "$DOCTOR_REL" '        return stat.S_ISREG(os.stat(exe).st_mode), False' \
                                     '        return os.path.lexists(exe), False'; then
    t_check_fail doctor.state.dangling.mutation \
        "with the discovery test following no symlink, a link that resolves to nothing counts as an install and the assertion goes red" \
        dangling_is_not_present "$M" dangling-mut
else
    t_skip doctor.state.dangling.mutation "could not plant the fault: bin_state's os.stat/S_ISREG test in $DOCTOR_REL has changed shape, and it is the one place that decides whether a symlink is followed"
fi

M="$(t_mutant "$SB" emptydir)"
if t_replace_line "$M" "$DOCTOR_REL" '            if present or (denied and cand == seed):' \
                                     '            if os.path.isdir(cand):'; then
    t_check_fail doctor.state.emptydir.mutation \
        "with discovery asking only whether the directory exists, an empty mount point counts as an install and the assertion goes red" \
        empty_mount_is_not_present "$M" emptydir-mut
else
    t_skip doctor.state.emptydir.mutation "could not plant the fault: install_roots' 'if present or (denied and cand == seed)' discovery test in $DOCTOR_REL has changed shape"
fi

M="$(t_mutant "$SB" unknownver)"
if t_replace_line "$M" "$DOCTOR_REL" '        for ver in sorted(installed):' \
                                     '        for ver in sorted(v for v in installed if v != "unknown"):'; then
    t_check_fail doctor.state.unknownver.mutation \
        "with unknown versions filtered out of the listing, a usable install vanishes from the report and the assertion goes red" \
        unknown_version_is_reported "$M" unknownver-mut
else
    t_skip doctor.state.unknownver.mutation "could not plant the fault: $DOCTOR_REL has no line exactly '        for ver in sorted(installed):'"
fi

M="$(t_mutant "$SB" siblings)"
if t_replace_line "$M" "$DOCTOR_REL" '        for cand in (seed,) + tuple(siblings(seed)):' \
                                     '        for cand in (seed,):'; then
    t_check_fail doctor.state.sibling.mutation \
        "with the sibling scan removed, the version no modulefile advertises is invisible and the assertion goes red" \
        sibling_is_discovered "$M" sibling-mut
else
    t_skip doctor.state.sibling.mutation "could not plant the fault: install_roots' seed-and-siblings loop in $DOCTOR_REL has changed shape"
fi

#-----------------------------------------------------------------------------
# A DIRECTORY YOU CANNOT TRAVERSE. This is the case doctor's header was written
# from - "the two newest live under a DIFFERENT install root on a
# group-restricted mount - so whether they exist is a per-user answer" - and
# until 2026-09-14 it was the one case usable()'s third state could not reach:
# os.path.isfile(exe) returns False on EACCES exactly as it does on ENOENT, so
# the traversal check below it never ran. A perfectly good install you have no
# permission to reach was reported with the reason "no bin/vivado", the note
# that follows told the reader it was "a site packaging fault ... tell whoever
# owns the module tree", and the install was dropped from the installed-versions
# list entirely. The owner of the module tree would have been told his tree is
# fine, by somebody holding a report that says the layer they are leaving is
# fine. Carried here as t_known_defect until the errno was graded.
#
# THE ASSERTION IS THAT THE TWO FINDINGS DIFFER, not that a particular sentence
# appears. Two roots go in: one that genuinely does not exist and one that
# exists, holds an executable vivado, and sits under a directory this test makes
# unreadable. They need opposite actions - a packaging fix from somebody else,
# and a group membership for you - so the report has to separate them, name the
# directory that refused, and give each the advice that belongs to it.
#-----------------------------------------------------------------------------
t_head "a permission you do not have is not the same finding as a file nobody installed"

## permission_is_not_a_missing_file <toolkit> <tag>
## Two advertised versions in one run: one whose root genuinely does not exist,
## and one that exists, contains an executable vivado, and sits under a
## directory this test makes unreadable. doctor must not give them the SAME
## reason, because they need opposite actions - one is the site's bug, the
## other is a group membership.
permission_is_not_a_missing_file() {
    local flow="$1" tag="$2" ghost locked
    chmod 000 "$LOCKED" 2>/dev/null || { printf 'could not make %s unreadable\n' "$LOCKED"; return 2; }
    run_doctor "$flow" "$tag" "$SB/cwd" "$BIN_NOVIVADO" BUILD_DIR="$SB/build" MODULEPATH="$MOD/locked"
    # Restored before anything can return, so the sandbox stays removable.
    chmod 755 "$LOCKED"
    ghost="$(dr_block  "$DR_OUT" WARN "ADVERTISED, NOT USABLE: $VER_GHOST"  | sed -n 's/.* on PATH, and \(.*\)\.$/\1/p')"
    locked="$(dr_block "$DR_OUT" WARN "ADVERTISED, NOT USABLE: $VER_LOCKED" | sed -n 's/.* on PATH, and \(.*\)\.$/\1/p')"
    [ -n "$ghost" ] && [ -n "$locked" ] || {
        printf 'one of the two advertised versions was not reported at all:\n'; dr_dump "$DR_OUT"; return 1; }
    [ "$ghost" != "$locked" ] || {
        printf 'a root that does not exist and a root you cannot traverse get the SAME reason:\n'
        printf '    %s : %s\n    %s : %s\n' "$VER_GHOST" "$ghost" "$VER_LOCKED" "$locked"
        printf 'They need opposite actions. The note under the second one tells the reader to\n'
        printf 'go and tell the owner of the module tree about a packaging fault that is not there.\n'
        return 1; }

    # DIFFERENT IS NOT YET ACTIONABLE. The reader has to be able to act without
    # going and looking, which is the thing doctor exists to save, so the reason
    # has to NAME THE DIRECTORY that refused - not the install root under it,
    # which is a path they cannot even stat.
    case "$locked" in
        *"$LOCKED"*) ;;
        *) printf 'the reason given for a version you cannot reach never names the directory that\n'
           printf 'refused (%s):\n    %s\n' "$LOCKED" "$locked"
           printf '"not usable" with no path in it is a finding nobody can take to anybody.\n'
           return 1 ;;
    esac

    # AND THE ADVICE HAS TO FOLLOW THE FINDING. The packaging-fault paragraph is
    # right for a version that is not installed and wrong for one that is: it
    # sends the reader to the owner of a module tree that is correct. Asserted
    # in BOTH directions, because an advice paragraph deleted outright would
    # otherwise pass - the ghost must still get it.
    t_contains "$(dr_block "$DR_OUT" WARN "ADVERTISED, NOT USABLE: $VER_GHOST")" "packaging fault" || {
        printf 'the version that genuinely is not installed no longer gets the packaging-fault\n'
        printf 'advice, so the test below it would hold on a doctor that gives no advice at all:\n'
        dr_block "$DR_OUT" WARN "ADVERTISED, NOT USABLE: $VER_GHOST"; return 1; }
    t_contains "$(dr_block "$DR_OUT" WARN "ADVERTISED, NOT USABLE: $VER_LOCKED")" "packaging fault" && {
        printf 'a version that IS installed, under a directory you cannot search, is reported as\n'
        printf 'a packaging fault in a module tree that is telling the truth:\n'
        dr_block "$DR_OUT" WARN "ADVERTISED, NOT USABLE: $VER_LOCKED"
        printf 'They will look, find the version exactly where their modulefile says it is, and\n'
        printf 'the reader will have spent the afternoon in the wrong layer.\n'
        return 1; }

    # THE OTHER HALF OF THE SAME DEFECT: the install was dropped from the
    # installed-versions list altogether, because discovery asked os.path.isfile
    # and got False for a reason it never distinguished. A version you cannot
    # reach is still a version this host HAS, and the list of what is installed
    # is what a reader compares against `module avail`.
    dr_says "$DR_OUT" WARN "installed $VER_LOCKED" "$LOCKED/$VER_LOCKED" || return 1
    dr_lacks "$DR_OUT" MISS "installed versions" || {
        printf 'doctor found an install it could not reach and still reported that none was found\n'
        printf 'on this filesystem.\n'; return 1; }
    return 0
}

# Probing the fixture rather than describing it: as uid 0, and on some mount
# options, mode 000 does not stop anybody, and the assertion would then be
# comparing two identical "root does not exist" answers and calling that a
# defect. The reason recorded on a skip must be true of THIS run.
chmod 000 "$LOCKED" 2>/dev/null
if [ -r "$LOCKED" ] || [ -x "$LOCKED" ] || ls "$LOCKED" >/dev/null 2>&1; then
    chmod 755 "$LOCKED"
    t_skip doctor.state.untraversable "mode 000 on $LOCKED does not block this user (uid $(id -u)) - the fixture cannot make a directory untraversable here, so nothing would distinguish it from a root that does not exist"
    t_skip doctor.state.untraversable.mutation "not attempted: its assertion was skipped because mode 000 on $LOCKED does not block this user (uid $(id -u))"
else
    chmod 755 "$LOCKED"
    t_check doctor.state.untraversable \
        "an install you cannot traverse to is reported as a PERMISSION on a path that exists - named, listed as installed, and never as 'no bin/vivado'" \
        permission_is_not_a_missing_file "$FLOW_DIR" untraversable

    # ONE GUARD, ONE PROOF. Every part of the finding above - the different
    # reason, the named directory, the advice, the install appearing in the list
    # at all - hangs on a single question asked in a single place: was the answer
    # "no such file" or "you may not look?" With the errno test gone, EACCES
    # reads as ENOENT again exactly as os.path.isfile used to make it, and all
    # four collapse back into "no bin/vivado".
    M="$(t_mutant "$SB" untraversable)"
    if t_replace_line "$M" "$DOCTOR_REL" '        if e.errno in (errno.EACCES, errno.EPERM):' \
                                         '        if False:'; then
        t_check_fail doctor.state.untraversable.mutation \
            "with EACCES graded as ENOENT again, a version you cannot reach is reported exactly like one nobody installed and the assertion goes red" \
            permission_is_not_a_missing_file "$M" untraversable-mut
    else
        t_skip doctor.state.untraversable.mutation "could not plant the fault: bin_state's errno test in $DOCTOR_REL has changed shape, and it is the only place the difference between 'not there' and 'not allowed' is decided"
    fi
fi

#=============================================================================
# 4. WHAT IS ADVERTISED vs WHAT IS INSTALLED
#
# doctor's reason for existing, from its own header: "`module load` then
# succeeds and the build runs on a version nobody chose." Everything here is a
# two-way comparison between a module tree this file writes and an install tree
# this file writes, so both sides are known.
#=============================================================================
t_head "every version a modulefile advertises, checked against the filesystem"

## ghost_is_named <toolkit> <tag>
## A modulefile that puts a directory on PATH which holds no vivado. `module
## load` succeeds, PATH gains an entry that resolves to nothing, and the build
## runs on whichever Vivado was already there.
ghost_is_named() {
    run_doctor "$1" "$2" "$SB/cwd" "$BIN_FULL" BUILD_DIR="$SB/build" MODULEPATH="$MOD/site"
    dr_says "$DR_OUT" WARN "ADVERTISED, NOT USABLE: $VER_GHOST" "$GHOST_ROOT" || return 1
    t_contains "$(dr_block "$DR_OUT" WARN "ADVERTISED, NOT USABLE: $VER_GHOST")" "$MOD/site/vivado/$VER_GHOST" || {
        printf 'the ghost is named and the MODULEFILE that advertises it is not, so nothing\n'
        printf 'says which file to take to the owner of the module tree:\n'
        dr_block "$DR_OUT" WARN "ADVERTISED, NOT USABLE: $VER_GHOST"; return 1; }
    dr_rc 0 "a ghost version is a site packaging fault, not a reason this host cannot build" || return 1
    return 0
}

## unresolved_is_reported <toolkit> <tag>
## doctor's comment: "a silently skipped modulefile is exactly the version that
## then surprises you." A parser that cannot read a file must say which file.
unresolved_is_reported() {
    run_doctor "$1" "$2" "$SB/cwd" "$BIN_FULL" BUILD_DIR="$SB/build" MODULEPATH="$MOD/site"
    dr_says "$DR_OUT" WARN "advertised $VER_UNRESOLVED" "modulefile not parseable" || return 1
    t_contains "$(dr_block "$DR_OUT" WARN "advertised $VER_UNRESOLVED")" "$MOD/site/vivado/$VER_UNRESOLVED" || {
        printf 'it reports an unreadable modulefile without naming it:\n'
        dr_block "$DR_OUT" WARN "advertised $VER_UNRESOLVED"; return 1; }
    return 0
}

## alias_is_not_a_version <toolkit> <tag>
## `latest -> 2040.1`. doctor's comment: "Counting it as one would make the
## advertised list wrong by inflation" - and the inflated entry would then be
## reported as a ghost, because no install is named `latest`.
alias_is_not_a_version() {
    run_doctor "$1" "$2" "$SB/cwd" "$BIN_FULL" BUILD_DIR="$SB/build" MODULEPATH="$MOD/site"
    dr_says  "$DR_OUT" -- "advertised latest" "an alias, not a version" || return 1
    dr_lacks "$DR_OUT" WARN "ADVERTISED, NOT USABLE: latest" || return 1
    dr_lacks "$DR_OUT" ok "installed latest" || return 1
    return 0
}

## unadvertised_is_named <toolkit> <tag>
## The mirror-image finding, and the reason this is a two-way comparison: a
## version nobody advertises is a version nobody will think to load.
unadvertised_is_named() {
    run_doctor "$1" "$2" "$SB/cwd" "$BIN_FULL" BUILD_DIR="$SB/build" MODULEPATH="$MOD/site"
    dr_says "$DR_OUT" -- "installed, not advertised" "$VER_SIBLING at $XIL/$VER_SIBLING" || return 1
    return 0
}

## unmeasured_is_not_clean <toolkit> <tag>
##
## THE NO-INVENTED-VERDICT ASSERTION, and the one with a positive control built
## into it, because the negative alone is satisfied by a doctor that never says
## anything good.
##
## Run 1 is a host where everything is present and everything cross-checks:
## doctor must reach "This host can run the flow."
## Run 2 is the SAME host with MODULEPATH unset, so the advertised-vs-installed
## comparison has no input. The answer is then UNMEASURED, not clean, and it
## must count as an advisory item - otherwise the run prints a clean bill of
## health for a comparison it never made.
unmeasured_is_not_clean() {
    local flow="$1" tag="$2"
    run_doctor "$flow" "$tag-control" "$SB/cwd" "$BIN_CLEAN" \
        BUILD_DIR="$SB/build" MODULEPATH="$MOD/clean" XILINXD_LICENSE_FILE="$LIC_FILE"
    t_contains "$(cat "$DR_OUT")" "This host can run the flow." || {
        printf 'the positive control never reached a clean bill of health, so the assertion below\n'
        printf 'it would hold on a doctor that can never say anything is fine:\n'; dr_dump "$DR_OUT"; return 1; }

    run_doctor "$flow" "$tag" "$SB/cwd" "$BIN_CLEAN" \
        BUILD_DIR="$SB/build" XILINXD_LICENSE_FILE="$LIC_FILE"
    dr_says "$DR_OUT" -- "modulefiles" "none found on MODULEPATH" || return 1
    t_contains "$(dr_block "$DR_OUT" -- "modulefiles")" "UNMEASURED" || {
        printf 'with no MODULEPATH, doctor reports the cross-check without saying it did not\n'
        printf 'happen:\n'; dr_block "$DR_OUT" -- "modulefiles"; return 1; }
    if t_contains "$(cat "$DR_OUT")" "This host can run the flow."; then
        printf 'doctor printed a CLEAN BILL OF HEALTH on a host where the advertised-vs-installed\n'
        printf 'comparison never ran. That is the summary line a reader acts on, and it is a\n'
        printf 'verdict invented from missing data: nothing was measured and nothing says so.\n'
        dr_dump "$DR_OUT"; return 1
    fi
    return 0
}

t_check doctor.mod.ghost \
    "a version advertised by a modulefile and not on the filesystem is named, with its modulefile, and is advisory" \
    ghost_is_named "$FLOW_DIR" ghost

t_check doctor.mod.unresolved \
    "a modulefile the parser cannot read is REPORTED as unreadable and named, never dropped" \
    unresolved_is_reported "$FLOW_DIR" unresolved

t_check doctor.mod.alias \
    "an alias modulefile is reported as an alias and never counted as a version" \
    alias_is_not_a_version "$FLOW_DIR" alias

t_check doctor.mod.unadvertised \
    "an installed version no modulefile offers is named - the mirror-image finding" \
    unadvertised_is_named "$FLOW_DIR" unadvertised

M="$(t_mutant "$SB" ghost)"
if t_replace_line "$M" "$DOCTOR_REL" '                ghosts.append((ver, mf, root, state, detail))' \
                                     '                line("ok", "advertised %s" % ver, "installed at %s" % root)'; then
    t_check_fail doctor.mod.ghost.mutation \
        "with an unusable advertised root reported as installed, the modulefile's lie is repeated by the tool written to catch it and the assertion goes red" \
        ghost_is_named "$M" ghost-mut
else
    t_skip doctor.mod.ghost.mutation "could not plant the fault: the ghosts.append line in $DOCTOR_REL has changed shape"
fi

M="$(t_mutant "$SB" unresolved)"
if t_replace_line "$M" "$DOCTOR_REL" '            out.append((ver, mf, root, reason))' \
                                     '            if root: out.append((ver, mf, root, reason))'; then
    t_check_fail doctor.mod.unresolved.mutation \
        "with unresolvable modulefiles quietly dropped, the version that surprises you later is the one that is not reported and the assertion goes red" \
        unresolved_is_reported "$M" unresolved-mut
else
    t_skip doctor.mod.unresolved.mutation "could not plant the fault: advertised_versions' out.append line in $DOCTOR_REL has changed shape"
fi

M="$(t_mutant "$SB" alias)"
if t_replace_line "$M" "$DOCTOR_REL" '            if os.path.islink(mf):' '            if False:'; then
    t_check_fail doctor.mod.alias.mutation \
        "with aliases read as versions, the 'latest' link becomes a fourth advertised version that no install can satisfy and the assertion goes red" \
        alias_is_not_a_version "$M" alias-mut
else
    t_skip doctor.mod.alias.mutation "could not plant the fault: the os.path.islink(mf) alias test in $DOCTOR_REL has changed shape"
fi

M="$(t_mutant "$SB" unadvertised)"
if t_replace_line "$M" "$DOCTOR_REL" '        unadvertised = sorted(set(installed) - adv_vers - set(["unknown"]))' \
                                     '        unadvertised = []'; then
    t_check_fail doctor.mod.unadvertised.mutation \
        "with the mirror-image comparison emptied, an install nobody advertises is silently unreported and the assertion goes red" \
        unadvertised_is_named "$M" unadvertised-mut
else
    t_skip doctor.mod.unadvertised.mutation "could not plant the fault: the 'unadvertised = sorted(...)' line in $DOCTOR_REL has changed shape"
fi

#-----------------------------------------------------------------------------
# The clean-bill assertion is the only one here that depends on a RESOURCE of
# the host rather than on the fixture: doctor advises when the build location
# has less than 20 GB free, and an advisory is all it takes to stop the summary
# saying "This host can run the flow." Measured here rather than assumed,
# because the reason on a skip has to be true of THIS run.
#-----------------------------------------------------------------------------
SB_FREE_GB="$(df -Pk "$SB" 2>/dev/null | awk 'NR==2 { printf "%d", $4 / 1048576 }')"
if [ -z "$SB_FREE_GB" ]; then
    t_skip doctor.mod.unmeasured "could not measure the free space on $SB, and the positive control in this assertion needs a filesystem doctor will not advise about (its threshold is 20 GB)"
    t_skip doctor.mod.unmeasured.mutation "not attempted: its assertion was skipped for the same reason"
elif [ "$SB_FREE_GB" -lt 21 ]; then
    t_skip doctor.mod.unmeasured "the sandbox filesystem has ${SB_FREE_GB} GB free and doctor advises below 20 GB, so the positive control - a host with NO advisory items - is unreachable here and the assertion would be measuring the disk"
    t_skip doctor.mod.unmeasured.mutation "not attempted: its assertion was skipped because the sandbox filesystem has ${SB_FREE_GB} GB free"
else
    t_check doctor.mod.unmeasured \
        "with nothing on MODULEPATH the cross-check is UNMEASURED, and the run cannot print a clean bill of health" \
        unmeasured_is_not_clean "$FLOW_DIR" unmeasured

    M="$(t_mutant "$SB" unmeasured)"
    if t_mutate "$M" "$DOCTOR_REL" '/MODULEPATH is not set in this shell/,+1s/^        d.advisory += 1$/        d.advisory += 0/'; then
        t_check_fail doctor.mod.unmeasured.mutation \
            "with the unmeasured cross-check counting for nothing, doctor declares the host clean without having compared anything and the assertion goes red" \
            unmeasured_is_not_clean "$M" unmeasured-mut
    else
        t_skip doctor.mod.unmeasured.mutation "could not plant the fault: the 'd.advisory += 1' after the MODULEPATH note in $DOCTOR_REL has moved, and the two identical lines elsewhere in the file would prove something else"
    fi
fi

#=============================================================================
# 5. THE BUILD LOCATION, AND THE DIFFERENCE BETWEEN MEASURED AND ASKED FOR
#
# The same unwritable directory is FATAL when a project declared it and
# ADVISORY when doctor merely found itself standing in it. That is not
# inconsistency: the verdict follows what was DECLARED, and doctor says which
# of the two it measured. A report that lost the distinction would be wrong in
# whichever direction it collapsed.
#=============================================================================
t_head "where the build would write, and whether doctor knows that it knows"

## says_which_directory_it_measured <toolkit> <tag>
says_which_directory_it_measured() {
    local flow="$1" tag="$2"
    run_doctor "$flow" "$tag-declared" "$SB/cwd" "$BIN_FULL" BUILD_DIR="$SB/build"
    dr_says "$DR_OUT" ok "build location" "$SB/build   (from BUILD_DIR)" || return 1
    [ -z "$(dr_block "$DR_OUT" ok "build location" | sed 1d)" ] || {
        printf 'a DECLARED build directory still carries the "nothing named a build directory"\n'
        printf 'note, so the one warning that matters reads as boilerplate:\n'
        dr_block "$DR_OUT" ok "build location"; return 1; }

    run_doctor "$flow" "$tag-undeclared" "$SB/cwd" "$BIN_FULL"
    dr_says "$DR_OUT" -- "build location" "$SB/cwd   (from current directory (BUILD_DIR not exported))" || return 1
    t_contains "$(dr_block "$DR_OUT" -- "build location")" "may not be where the flow will write" || {
        printf 'doctor measured the current directory and did not say that is what it did. Disk\n'
        printf 'and writability below it are then read as facts about the build directory:\n'
        dr_block "$DR_OUT" -- "build location"; return 1; }
    return 0
}

## every_declared_variable_is_honoured <toolkit> <tag>
## BUILD_DIR_VARS is read OUT OF THE SCRIPT: a list spelled in this file would
## agree with a doctor that had quietly stopped reading one of them.
every_declared_variable_is_honoured() {
    local flow="$1" tag="$2" var n=0
    for var in $(declared_list "$flow" BUILD_DIR_VARS); do
        n=$((n + 1))
        run_doctor "$flow" "$tag-$var" "$SB/cwd" "$BIN_FULL" "$var=$SB/build"
        dr_says "$DR_OUT" ok "build location" "$SB/build   (from $var)" || {
            printf '%s is declared in BUILD_DIR_VARS and setting it did not name the build location.\n' "$var"
            return 1; }
    done
    [ "$n" -gt 0 ] && return 0
    printf 'BUILD_DIR_VARS could not be read out of %s, so this assertion compared nothing.\n' "$flow/$DOCTOR_REL"
    return 1
}

t_check doctor.build.undeclared \
    "doctor says WHICH directory it measured, and warns only when nothing declared one" \
    says_which_directory_it_measured "$FLOW_DIR" build

t_check doctor.build.vars \
    "every variable BUILD_DIR_VARS declares is honoured, and the report names the one it read" \
    every_declared_variable_is_honoured "$FLOW_DIR" buildvar

M="$(t_mutant "$SB" buildnote)"
if t_replace_line "$M" "$DOCTOR_REL" '    if not explicit:' '    if explicit:'; then
    t_check_fail doctor.build.undeclared.mutation \
        "with the caveat attached to the wrong case, a measured guess reads as a declared fact and the assertion goes red" \
        says_which_directory_it_measured "$M" buildnote-mut
else
    t_skip doctor.build.undeclared.mutation "could not plant the fault: $DOCTOR_REL has no line exactly '    if not explicit:'"
fi

M="$(t_mutant "$SB" buildvars)"
if t_replace_line "$M" "$DOCTOR_REL" '    for var in BUILD_DIR_VARS:' \
                                     '    for var in BUILD_DIR_VARS[:1]:'; then
    t_check_fail doctor.build.vars.mutation \
        "with only the first declared variable read, the other two are silently ignored while the tuple still lists them and the assertion goes red" \
        every_declared_variable_is_honoured "$M" buildvar-mut
else
    t_skip doctor.build.vars.mutation "could not plant the fault: $DOCTOR_REL has no line exactly '    for var in BUILD_DIR_VARS:'"
fi

#-----------------------------------------------------------------------------
# WRITABILITY. Two assertions on one fact, and they fail in opposite
# directions, so they get separate proofs.
#-----------------------------------------------------------------------------
RO="$SB/readonly"
mkdir -p "$RO" && chmod 555 "$RO"

## declared_unwritable_is_fatal <toolkit> <tag>
declared_unwritable_is_fatal() {
    run_doctor "$1" "$2" "$SB/cwd" "$BIN_FULL" BUILD_DIR="$RO"
    dr_says "$DR_OUT" MISS "writable" "$RO is not writable" || return 1
    dr_rc 1 "everything a run produces goes under the declared build directory" || return 1
    return 0
}

## undeclared_unwritable_is_advisory <toolkit> <tag>
## The same directory, as the current directory. doctor's note: "It would be
## fatal if BUILD_DIR pointed here."
undeclared_unwritable_is_advisory() {
    run_doctor "$1" "$2" "$RO" "$BIN_FULL"
    dr_says "$DR_OUT" WARN "writable" "$RO is not writable" || return 1
    dr_rc 0 "nothing declared this directory, so it is not a statement about the build" || return 1
    return 0
}

# Probed, not described. As uid 0 - and on a filesystem mounted so the mode is
# advisory - mode 555 does not stop a write, doctor's os.access() agrees, and
# both assertions would be measuring a directory that is in fact writable.
if ( : > "$RO/probe" ) 2>/dev/null; then
    rm -f "$RO/probe"
    t_skip doctor.build.declared.unwritable "mode 555 on $RO does not stop this user (uid $(id -u)) writing to it, so the fixture is not an unwritable directory on this host and the assertion would measure nothing"
    t_skip doctor.build.declared.unwritable.mutation "not attempted: its assertion was skipped because mode 555 does not stop this user writing"
    t_skip doctor.build.undeclared.unwritable "mode 555 on $RO does not stop this user (uid $(id -u)) writing to it, so the fixture is not an unwritable directory on this host and the assertion would measure nothing"
    t_skip doctor.build.undeclared.unwritable.mutation "not attempted: its assertion was skipped because mode 555 does not stop this user writing"
else
    t_check doctor.build.declared.unwritable \
        "a DECLARED build directory that cannot be written is ESSENTIAL: MISS, and exit 1" \
        declared_unwritable_is_fatal "$FLOW_DIR" rodeclared

    t_check doctor.build.undeclared.unwritable \
        "the same directory, merely the one doctor was run from, is ADVISORY - the verdict follows what was declared" \
        undeclared_unwritable_is_advisory "$FLOW_DIR" roundeclared

    M="$(t_mutant "$SB" wfatal)"
    if t_replace_line "$M" "$DOCTOR_REL" '        d.essential("writable", "%s is not writable" % probe)' \
                                         '        d.advise("writable", "%s is not writable" % probe)'; then
        t_check_fail doctor.build.declared.unwritable.mutation \
            "with a declared unwritable build directory demoted to advisory, the host passes and the first stage fails instead - the assertion goes red" \
            declared_unwritable_is_fatal "$M" rodeclared-mut
    else
        t_skip doctor.build.declared.unwritable.mutation "could not plant the fault: the d.essential(\"writable\", ...) call in $DOCTOR_REL has changed shape"
    fi

    M="$(t_mutant "$SB" wadvisory)"
    if t_replace_line "$M" "$DOCTOR_REL" '        d.advise("writable", "%s is not writable" % probe)' \
                                         '        d.essential("writable", "%s is not writable" % probe)'; then
        t_check_fail doctor.build.undeclared.unwritable.mutation \
            "with the undeclared case promoted to essential, doctor fails a host over a directory nobody named as the build directory and the assertion goes red" \
            undeclared_unwritable_is_advisory "$M" roundeclared-mut
    else
        t_skip doctor.build.undeclared.unwritable.mutation "could not plant the fault: the d.advise(\"writable\", ...) call in $DOCTOR_REL has changed shape"
    fi
fi

#-----------------------------------------------------------------------------
# DISPLAY: the same absent/present/present-but-unusable distinction, applied to
# an environment variable rather than to a file. A malformed value passes every
# non-empty test, and the tool then falls back to batch with a warning that
# reads as the GUI simply not starting.
#-----------------------------------------------------------------------------
## display_malformed_is_not_set <toolkit> <tag>
display_malformed_is_not_set() {
    local flow="$1" tag="$2"
    run_doctor "$flow" "$tag-unset" "$SB/cwd" "$BIN_FULL" BUILD_DIR="$SB/build"
    dr_says "$DR_OUT" -- "DISPLAY" "unset" || return 1
    dr_rc 0 "a batch run needs no DISPLAY" || return 1

    run_doctor "$flow" "$tag-bad" "$SB/cwd" "$BIN_FULL" BUILD_DIR="$SB/build" DISPLAY=no-colon-here
    dr_says  "$DR_OUT" WARN "DISPLAY" "(no colon?)" || return 1
    dr_lacks "$DR_OUT" ok   "DISPLAY" || return 1
    dr_rc 0 "a malformed DISPLAY costs the GUI, not the build" || return 1
    return 0
}

t_check doctor.display \
    "a DISPLAY that is set to nonsense is distinguished from one that is unset" \
    display_malformed_is_not_set "$FLOW_DIR" display

M="$(t_mutant "$SB" display)"
if t_replace_line "$M" "$DOCTOR_REL" '        d.advise("DISPLAY", "%s   (no colon?)" % display)' \
                                     '        line("ok", "DISPLAY", display)'; then
    t_check_fail doctor.display.mutation \
        "with a malformed DISPLAY reported ok, a value no X server will accept reads as a working one and the assertion goes red" \
        display_malformed_is_not_set "$M" display-mut
else
    t_skip doctor.display.mutation "could not plant the fault: the d.advise(\"DISPLAY\", ...) call in $DOCTOR_REL has changed shape"
fi

#-----------------------------------------------------------------------------
# The statvfs failure arm - `line("--", "disk", "could not measure (%s)")` -
# is not reachable from outside doctor, and this is the measurement rather than
# an opinion: the probe walks UP from the build directory until it finds a path
# that exists, and any path that exists has a statvfs. A directory made
# unreadable does not help, because statvfs needs search permission on the
# PARENT, which the walk has by construction.
#-----------------------------------------------------------------------------
t_skip doctor.disk.unmeasured "os.statvfs's failure arm cannot be reached from outside doctor: report_resources walks up from the build directory to the first path that EXISTS, and statvfs on an existing path needs only search permission on its parent - which that walk has by construction. Reaching it would need a filesystem error this suite may not cause on a host"

#=============================================================================
# 6. LICENCES - and the promise that asking about one takes none
#=============================================================================
t_head "licence variables: reported, probed by socket, and never fatal"

## names_every_declared_variable <toolkit> <tag>
## The names come OUT OF THE SCRIPT. A list spelled here would agree with a
## doctor that had stopped reporting one of them.
names_every_declared_variable() {
    local flow="$1" tag="$2" var det n=0
    run_doctor "$flow" "$tag" "$SB/cwd" "$BIN_FULL" BUILD_DIR="$SB/build"
    det="$(dr_detail "$DR_OUT" -- "licence variables")" || {
        printf 'no licence variable is set and doctor says nothing about it at all.\n'; dr_dump "$DR_OUT"; return 1; }
    for var in $(declared_list "$flow" LICENCE_VARS); do
        n=$((n + 1))
        case "$det" in
            *"$var"*) ;;
            *) printf '%s is declared in LICENCE_VARS and the report does not name it:\n    %s\n' "$var" "$det"
               printf 'A reader setting the two it does name would still have an unset licence and a\n'
               printf 'doctor that said nothing about it.\n'; return 1 ;;
        esac
    done
    [ "$n" -gt 0 ] || { printf 'LICENCE_VARS could not be read out of %s.\n' "$flow/$DOCTOR_REL"; return 1; }
    dr_rc 0 "a site may configure licences through a wrapper; this is not a reason the host cannot build" || return 1
    return 0
}

## file_based_value_is_not_probed <toolkit> <tag>
## `XILINXD_LICENSE_FILE=/path/to/file` is a FILE, not a server. There is
## nothing to open a socket to, and saying so is the difference between "not
## probed" and "probed and fine".
file_based_value_is_not_probed() {
    run_doctor "$1" "$2" "$SB/cwd" "$BIN_FULL" BUILD_DIR="$SB/build" XILINXD_LICENSE_FILE="$LIC_FILE"
    dr_says "$DR_OUT" ok "XILINXD_LICENSE_FILE" || return 1
    dr_says "$DR_OUT" -- "  (file-based)" "no port@host entries to probe" || return 1
    dr_rc 0 "a file-based licence is not an essential item missing" || return 1
    return 0
}

## unanswered_server_is_advisory <toolkit> <tag>
unanswered_server_is_advisory() {
    run_doctor "$1" "$2" "$SB/cwd" "$BIN_FULL" BUILD_DIR="$SB/build" \
        XILINXD_LICENSE_FILE="$DEAD_PORT@$DEAD_HOST"
    dr_says "$DR_OUT" WARN "  $DEAD_HOST:$DEAD_PORT" "no answer" || return 1
    dr_rc 0 "a server that is down now is up later, and the host is otherwise fine" || return 1
    return 0
}

t_check doctor.lic.none \
    "with no licence variable set, doctor names every variable it looked at, and does not fail the host" \
    names_every_declared_variable "$FLOW_DIR" licnone

t_check doctor.lic.file \
    "a file-based licence value is reported as file-based and not probed" \
    file_based_value_is_not_probed "$FLOW_DIR" licfile

M="$(t_mutant "$SB" licnames)"
if t_replace_line "$M" "$DOCTOR_REL" '        line("--", "licence variables", "none of %s set" % " / ".join(LICENCE_VARS))' \
                                     '        line("--", "licence variables", "none of %s set" % " / ".join(LICENCE_VARS[:1]))'; then
    t_check_fail doctor.lic.none.mutation \
        "with the message naming only the first variable, two of the three doctor actually reads go unmentioned and the assertion goes red" \
        names_every_declared_variable "$M" licnone-mut
else
    t_skip doctor.lic.none.mutation "could not plant the fault: the 'none of %s set' line in $DOCTOR_REL has changed shape"
fi

M="$(t_mutant "$SB" licfile)"
if t_replace_line "$M" "$DOCTOR_REL" '        if not endpoints:' '        if False:'; then
    t_check_fail doctor.lic.file.mutation \
        "with the file-based case silently dropped, a licence file reads as a probed and healthy server and the assertion goes red" \
        file_based_value_is_not_probed "$M" licfile-mut
else
    t_skip doctor.lic.file.mutation "could not plant the fault: $DOCTOR_REL has no line exactly '        if not endpoints:'"
fi

# A port nothing listens on, MEASURED rather than assumed. 127.0.0.1:1 is not
# a network access - it is a loopback connection refused by the kernel - but a
# host that does listen there would make the assertion below pass for a reason
# that has nothing to do with the toolkit, so this checks and skips WITH THE
# MEASUREMENT if it cannot find a dead port.
DEAD_HOST=127.0.0.1
DEAD_PORT=1
if "$PYBIN" - "$DEAD_HOST" "$DEAD_PORT" <<'PROBE'
import socket, sys
try:
    socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=1.0).close()
except OSError:
    sys.exit(1)            # nothing answered: the fixture is a dead port
sys.exit(0)                # something answered
PROBE
then
    t_skip doctor.lic.noanswer "something on this host answers $DEAD_HOST:$DEAD_PORT, so it is not the unreachable licence server this assertion needs and doctor would correctly report it as answering"
    t_skip doctor.lic.noanswer.mutation "not attempted: its assertion was skipped because $DEAD_HOST:$DEAD_PORT answered"
else
    t_check doctor.lic.noanswer \
        "a licence server that answers nothing is ADVISORY, named with its host and port" \
        unanswered_server_is_advisory "$FLOW_DIR" licdead

    M="$(t_mutant "$SB" licdead)"
    if t_replace_line "$M" "$DOCTOR_REL" '                d.advise("  %s:%d" % (host, port), "no answer (%s)" % e)' \
                                         '                d.essential("  %s:%d" % (host, port), "no answer (%s)" % e)'; then
        t_check_fail doctor.lic.noanswer.mutation \
            "with an unreachable server made fatal, a host that can build in ten minutes is failed today and the assertion goes red" \
            unanswered_server_is_advisory "$M" licdead-mut
    else
        t_skip doctor.lic.noanswer.mutation "could not plant the fault: the d.advise(\"  %s:%d\", ...) call in $DOCTOR_REL has changed shape"
    fi
fi

#=============================================================================
# 7. IT LAUNCHES NOTHING
#
# The claim doctor makes twice - in its header and in the second line it prints
# - is the reason it is safe to run on a busy site and the reason its version
# numbers are read off a path. Asserted here rather than believed, because a
# single stray `run([vivado, "-version"])` would cost tens of seconds, write a
# journal file into the caller's directory, and on a busy site queue behind a
# licence. None of that shows up as a failure; it shows up as doctor being slow.
#=============================================================================
t_head "no EDA tool is launched, and no licence is taken"

## launches_no_tool <toolkit> <tag>
launches_no_tool() {
    local flow="$1" tag="$2" t ran=""
    rm -f "$RAN"/* 2>/dev/null
    run_doctor "$flow" "$tag" "$SB/cwd" "$BIN_FULL" BUILD_DIR="$SB/build" MODULEPATH="$MOD/site"

    # THE TRIPWIRE'S OWN CONTROL. "No marker appeared" proves nothing unless a
    # marker CAN appear, and doctor does legitimately run tclsh and git for
    # their versions. If those two left no mark either, the stubs are not
    # recording and every line below is vacuous.
    for t in tclsh git; do
        [ -s "$RAN/$t" ] || {
            printf 'the %s stub recorded no execution, and doctor is supposed to run it for its\n' "$t"
            printf 'version. The tripwire is not armed, so "vivado did not run" below would be\n'
            printf 'true of a doctor that did run it.\n'; return 1; }
    done

    for t in vivado make lmutil lmstat; do
        [ -e "$RAN/$t" ] && ran="$ran $t"
    done
    [ -z "$ran" ] || {
        printf 'doctor EXECUTED:%s\n' "$ran"
        printf 'Its own second printed line says "No EDA tool is launched by anything below. No\n'
        printf 'licence is checked out." Starting Vivado to read a version costs tens of seconds,\n'
        printf 'writes a journal file into the caller directory, and can queue behind a licence.\n'
        return 1; }

    # And it still did the work: the version it reports comes from the install
    # path. Without this half, a doctor that did nothing at all would pass.
    dr_says "$DR_OUT" ok "vivado on PATH" "(version $VER_MAIN, from the install path)" || return 1
    return 0
}

t_check doctor.notool \
    "no vivado, make or licence utility is executed - and the stubs prove they would have recorded it" \
    launches_no_tool "$FLOW_DIR" notool

M="$(t_mutant "$SB" notool)"
if t_mutate "$M" "$DOCTOR_REL" '/^        real = os.path.realpath(onpath)$/s/$/; run([onpath, "-version"])/'; then
    t_check_fail doctor.notool.mutation \
        "with one added call to the binary on PATH, the EDA tool runs and the assertion goes red" \
        launches_no_tool "$M" notool-mut
else
    t_skip doctor.notool.mutation "could not plant the fault: $DOCTOR_REL has no line exactly '        real = os.path.realpath(onpath)' to hang a tool launch on"
fi

t_summary
