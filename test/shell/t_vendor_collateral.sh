#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# t_vendor_collateral.sh - the vendor-collateral scanner must never report
# clean over content it did not read
#
# DEFECT CLASS: A SCAN THAT SKIPPED PART OF ITS CORPUS AND STILL EXITED 0.
#
# ci/check-vendor-collateral.sh stands between this repository and the public.
# It is the scanner behind the pre-commit and pre-push git hooks and behind the
# CI gate, and its one job is to say NO when vendor collateral - an encrypted-IP
# envelope, a catalogue customisation, a board file, a bitstream, a site fact -
# is about to be published. Every other component of this toolkit fails towards
# a wrong bitstream; this one fails towards a disclosure that cannot be undone,
# because removing a file from HEAD removes it from nothing.
#
# The failure shape this suite is built around has a name in this lab's own
# records: "vendor scan exits 0 with half skipped". A scanner that could not
# open a file, could not resolve a revision, or was pointed at an empty corpus,
# and then printed OK, is not a weak guard. It is a green light with no bulb.
# The checker's own header says the same thing at length, and says that it
# ARMS every rule and CENSUSES its corpus before it is entitled to a verdict.
# Those are claims the file makes about itself. This suite drives them from
# OUTSIDE, against real git revisions. The arming block, the census, the
# revision range and every refusal hold. THREE things do not, and each is
# carried below as a KNOWN-DEFECT marker that goes RED the day it is fixed:
#
#   THE UNREADABLE FILE. For the corpora the checker materialises for itself
#   (--staged reads blobs out of the index, --rev extracts an archive) there is
#   nothing on disk it cannot open. For the one it reads straight off the
#   filesystem - the default worktree scan CI runs, and --untracked-only, which
#   the push hook runs - one tracked file at mode 000 makes awk abort the whole
#   batch, so every file sorting after it is never read, the census still counts
#   them as "read for content", the size pass mis-attributes every size in the
#   batch, and the run exits 0. Section 9, with the one place the checker DOES
#   say "could not be measured" asserted beside it so the difference is visible.
#
#   THE PRE-COMMIT HOOK'S OWN FLAGS. `--staged --fast --new-lines-only` builds
#   its map of added lines from the WORKING TREE while scanning the INDEX, so
#   when the two differ - the exact case --staged exists for, and the one the
#   checker's header uses as its worked example - every CONTENT finding in the
#   staged blob is filed as pre-existing backlog and dropped. Section 5, with a
#   control beside it that pins the cause to the divergence.
#
#   THE DOTFILE. The text corpus admits every EXTENSIONLESS file, deliberately,
#   because a data file is the likeliest thing to be a dump of something. It
#   decides "extensionless" with the glob `*.*`, which `.envrc` and
#   `.gitmodules` match - so a dotfile is read as having an extension and is
#   never opened. A licence-server export lands in exactly such a file.
#   Section 10.
#
# WHAT IS ASSERTED, AND ON WHAT EVIDENCE. Never the exit status alone. Every
# predicate reads the checker's OUTPUT - the path and the rule it names, or the
# silence --fast promises - and its VERDICT FILE ($CI_VERDICT_DIR/vendor/
# verdicts.tsv, one row per gate, written by ci/lib.sh), and asks whether both
# agree with the exit status. A gate that is red for the wrong reason, or green
# with no corpus row behind it, is caught by the row and not by the number.
#
# THE FIXTURES ARE REAL GIT REPOSITORIES: `git init` inside the harness
# sandbox, with commits, an index and untracked files of their own, driven by
# revision. That is the precondition class test/KNOWN_DEFECTS said no suite
# here had, and it is what makes --staged, --rev, --since and the range
# questions answerable at all. EVERY git call in this file goes through one
# function that refuses a path outside the sandbox and scrubs GIT_DIR,
# GIT_WORK_TREE, GIT_INDEX_FILE and the global and system config from the
# environment - a suite that is itself run from a git hook inherits those, and
# with them a `git rev-parse --show-toplevel` in a fixture answers about the
# real repository. The global config is scrubbed for a second reason: the
# toolkit's own hook installer sets core.hooksPath, and a developer who has it
# set globally would find this suite's planted commits refused by the very
# hook it is testing the scanner behind.
#
# EVERY SPECIMEN IS INVENTED AND ASSEMBLED AT RUNTIME from fragments, so that
# no line of THIS file matches a rule in the table. The toolkit's CI runs the
# scanner over test/ like everything else; a suite that carried the envelope
# directive as a literal would need a waiver in the allowlist to exist, and the
# allowlist is the list of places vendor-shaped text is permitted to live,
# which a test file has no business being on. The comments below say "the
# directive" and "the markers" for the same reason.
#
# NO LIST OF RULES APPEARS IN THIS FILE. The rule count, the pattern strings
# and the row numbers are read out of ci/check-vendor-collateral.sh's own
# table at run time (CONTRACT.md rule three: never hardcode a list a file
# already knows), so a rule added tomorrow is covered by the one-place check
# tomorrow, without anybody editing this suite.
#
# ONE FAULT PER COPY. Every proof gets a fresh t_mutant; a shared mutant
# accumulates faults and the twentieth proof then passes or fails for the
# first proof's reason (t_flow_utils.sh's header records the one time this
# repository shipped that). ONE proof carries a FIXTURE edit beside its fault -
# vendor.arm.refusal.mutation, whose assertion is ABOUT a refusal, so a refusal
# has to be made to happen before the fault can remove its row number - and it
# says so where it is planted.
#
# THIS IS NOW THE SLOW SUITE - about four minutes, against t_tier's two - and
# the reason is worth knowing before somebody "optimises" it. Nearly all of it
# is the 24 mutation proofs: each takes its OWN copy of the toolkit, because a
# shared mutant accumulates faults. The scanner itself is fast (a scan of a
# five-file fixture is milliseconds) and the git fixtures are built once. The
# cost is `cp -a` of the repository, 24 times, and the alternative - one mutant
# carrying several faults - is the thing this repository has already shipped
# once and written a header about. Nothing here needs a tool, a licence or a
# network, and `ci/tier.sh`'s static tier runs t_seams.sh rather than the whole
# suite, so this file's runtime does not land in a CI tier.
#
# THE HOOKS' CALLING SHAPES are used verbatim where they matter, read from
# hooks/pre-commit and hooks/pre-push rather than invented: the commit hook
# runs `--staged --fast --new-lines-only`, the push hook runs `--rev <sha>
# --since <base> --new-lines-only --fast` per pushed commit and
# `--untracked-only --fast` for the file no commit can show. The installer
# (scripts/fpga-flow-hooks) is NOT under test here.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/lib/harness.sh
. "$HERE/../lib/harness.sh"

t_sandbox; SB="$T_SANDBOX"

CHK_REL=ci/check-vendor-collateral.sh

#-----------------------------------------------------------------------------
# PRECONDITIONS - each a SKIP WITH THE REASON, never a pass.
#-----------------------------------------------------------------------------
if [ ! -f "$FLOW_DIR/$CHK_REL" ]; then
    t_skip vendor.all "$CHK_REL is not in this checkout at $FLOW_DIR/$CHK_REL - there is no scanner to drive, and an absent file is not a passing one"
    t_summary; exit $?
fi
if ! command -v git >/dev/null 2>&1; then
    t_skip vendor.all "no git on PATH - every fixture here is a git repository and the scanner itself is a set of git questions, so nothing below could be measured"
    t_summary; exit $?
fi

#-----------------------------------------------------------------------------
# THE SCRUBBED ENVIRONMENT, AND THE ONE DOOR EVERY GIT CALL GOES THROUGH.
#
# `env -u` options must all precede the first NAME=VALUE: GNU env stops
# parsing options at the first non-option word, and a `-u` after an assignment
# would be taken as the COMMAND. Hence one list of names, assembled first.
#-----------------------------------------------------------------------------
_SCRUB=(-u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY
        -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_COMMON_DIR -u GIT_NAMESPACE
        -u GIT_CEILING_DIRECTORIES -u GIT_TEMPLATE_DIR
        -u CI_VERDICT_DIR -u CI_APPEND -u CI_LANE -u CI_SUMMARY_FILE
        -u GITHUB_STEP_SUMMARY -u FPGA_RUN_DIR -u RUN_DIR
        -u VENDOR_CHECK_BACKLOG_OUT -u VENDOR_CHECK_FINDINGS_OUT)
GIT_ENV=(env "${_SCRUB[@]}"
         GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
         GIT_AUTHOR_NAME=t-vendor GIT_AUTHOR_EMAIL=t-vendor@example.invalid
         GIT_COMMITTER_NAME=t-vendor GIT_COMMITTER_EMAIL=t-vendor@example.invalid)
VC_ENV=("${GIT_ENV[@]}" CI_COLOUR=0)

# An EMPTY template directory, so `git init` installs no sample hooks and
# nothing from the host's init.templateDir - which the scrubbed config could
# not otherwise reach - lands in a fixture.
TPL="$SB/empty-template"; mkdir -p "$TPL"

## gitf <repo> <git args...> - git, scrubbed, and ONLY inside a sandbox repo.
## The refusal is the safety property of this whole file: a fixture path that
## was never created, or a typo, must not turn into a `git add -A` somewhere
## real.
gitf() {
    local repo="$1"; shift
    t_in_sandbox "$repo" || { echo "harness: refusing git outside a sandbox: $repo" >&2; return 2; }
    "${GIT_ENV[@]}" git -C "$repo" "$@"
}

## mkrepo <dir> - a fresh, empty repository in the sandbox
mkrepo() {
    t_in_sandbox "$1" || { echo "harness: refusing to init outside a sandbox: $1" >&2; return 2; }
    mkdir -p "$1" || return 2
    "${GIT_ENV[@]}" git -c init.defaultBranch=main init -q --template="$TPL" "$1"
}

## commit_all <repo> <message> - stage everything and commit; prints the sha.
## --no-verify is belt beside the braces of the scrubbed config: a hook must
## never get a say in whether a FIXTURE commit exists.
commit_all() {
    gitf "$1" add -A && \
    gitf "$1" -c commit.gpgsign=false commit -q --no-verify -m "$2" && \
    gitf "$1" rev-parse HEAD
}

#-----------------------------------------------------------------------------
# THE SPECIMENS. Invented, and assembled from fragments at run time so that
# THIS file matches nothing in the scanner's table (see the header).
#-----------------------------------------------------------------------------
## ipenc_line - the encrypted-IP envelope directive with its opening marker.
## Fires two `ipenc` rows on the one line; the finding is reported at :2 of
## whatever plant_core writes.
ipenc_line()   { printf '`pragma %s begin_%s' protect protected; }
## keyhdr_line - the key/data header row of the same envelope
keyhdr_line()  { printf '`pragma %s %s_method = "invented-9999"' protect data; }
## licence_line - a port-at-host licence server. Invented; resolves nowhere.
licence_line() { printf 'export XILINXD_LICENSE_FILE=%s@%s' 9999 licsrv9999.invented-site.test; }

## plant_core <file> - a three-line invented core whose LINE 2 is the directive
plant_core() {
    mkdir -p "$(dirname "$1")" || return 2
    { printf 'module specimen_core_9999;\n'; ipenc_line; printf '\nendmodule\n'; } > "$1"
}
## plant_clean <file> [text] - an ordinary file
plant_clean() {
    mkdir -p "$(dirname "$1")" || return 2
    printf '%s\n' "${2:-invented content, nothing to find}" > "$1"
}

# A commit id that no fixture holds. Forty hex digits, so it is refused for
# not EXISTING and not for being malformed - a different refusal, and one that
# would let the wrong check pass the assertion.
NOSHA=0123456789abcdef0123456789abcdef01234567

#-----------------------------------------------------------------------------
# DRIVING THE SCANNER, AND READING WHAT IT WROTE.
#-----------------------------------------------------------------------------
## vd_new - a fresh verdict directory. mktemp, not $RANDOM: t_check runs each
## predicate inside a command substitution, and two predicates handed the same
## number would read each other's verdict file.
vd_new() { mktemp -d "$SB/vdXXXXXXXX"; }

## scan <toolkit> <repo> <verdict dir> [args...]
## Runs that toolkit's scanner from INSIDE <repo>, verdicts under <verdict
## dir>, and prints everything it printed plus a trailing EXIT=<status> line -
## the exit status is under test and `$?` does not survive a substitution.
## SCAN_ENV, when set by the caller, adds NAME=VALUE pairs (the backlog and
## findings channels the hooks use).
## `bash <path>` and `< /dev/null`, for the same reasons hooks/lib-hook.sh
## gives: a copy that lost its execute bit is an environment problem, not a
## scanner verdict; and the pre-push hook's ref list arrives on stdin.
SCAN_ENV=()
scan() {
    local tk="$1" repo="$2" vd="$3"; shift 3
    local rc=0 out
    t_in_sandbox "$repo" || { printf 'harness: refusing to scan outside a sandbox: %s\n' "$repo"; return 2; }
    out="$(cd "$repo" && "${VC_ENV[@]}" CI_VERDICT_DIR="$vd" ${SCAN_ENV[@]+"${SCAN_ENV[@]}"} \
           bash "$tk/$CHK_REL" "$@" 2>&1 < /dev/null)" || rc=$?
    printf '%s\nEXIT=%d\n' "$out" "$rc"
}
exit_of() { printf '%s\n' "$1" | sed -n 's/^EXIT=//p' | tail -1; }

## The verdict file the scanner writes: $CI_VERDICT_DIR/vendor/verdicts.tsv,
## four tab-separated columns - timestamp, status, gate id, detail.
vfile()     { printf '%s/vendor/verdicts.tsv' "$1"; }
rows()      { cut -f2- "$(vfile "$1")" 2>/dev/null; }
## has_row <vd> <status> <id>        - a row with exactly that status and id
has_row()   { awk -F'\t' -v s="$2" -v i="$3" '$2 == s && $3 == i { f = 1 } END { exit !f }' "$(vfile "$1")" 2>/dev/null; }
## id_like <vd> <id regex>           - ANY row whose id matches
id_like()   { awk -F'\t' -v i="$2" '$3 ~ i { f = 1 } END { exit !f }' "$(vfile "$1")" 2>/dev/null; }
## detail_of <vd> <id>               - the detail column of that gate
detail_of() { awk -F'\t' -v i="$2" '$3 == i { print $4 }' "$(vfile "$1")" 2>/dev/null; }

## show <output> <vd> - the evidence, printed only when an assertion fails
show() {
    printf -- '--- scanner output (last 25 lines):\n%s\n' "$(printf '%s\n' "$1" | tail -25)"
    printf -- '--- verdict rows:\n%s\n' "$(rows "$2")"
}

#-----------------------------------------------------------------------------
# A PROOF NEEDS ITS FIXTURE TO STILL BE THERE, AND THIS SUITE LEARNED THAT THE
# EXPENSIVE WAY.
#
# A mutation proof passes when the assertion goes RED. "The fixture repository
# was deleted underneath the run" also makes it go red - the scanner cannot cd
# into a directory that is gone - so a proof that reads only the exit status
# reports `ok` for a scanner it never invoked. Measured here on 2026-09-17: a
# run in which $TMPDIR was cleared out mid-suite printed 18 FAILs among the
# plain assertions and 23 cheerful `ok`s among the proofs. The assertions were
# doing their job; every proof beside them was vacuous, and the vacuity was
# invisible in the one column anybody reads.
#
# That is this suite's own subject matter one level up: a check that reports a
# verdict it did not measure. This host makes it a live hazard rather than a
# thought experiment - several sessions run these suites concurrently and share
# one $TMPDIR (see the lab note "concurrent sessions mutate this repo").
#
# So the proofs go through t_proof, which brackets the run with an integrity
# check on the fixtures and refuses to call a rejection a proof unless the
# thing being measured still existed on both sides of it.
#-----------------------------------------------------------------------------

## FIXTURES - the repositories every predicate reads, named once. Set after
## each is built; t_proof and the final assertion walk this list, so a fixture
## added later is covered without editing either.
FIXTURES=()

## fixtures_intact - every fixture is still a directory with a .git in it.
## Prints what is missing. An EMPTY list is NOT intact: a proof cannot be
## validated against a list of nothing, which is the same sentence this whole
## suite is about.
fixtures_intact() {
    local d missing=""
    if [ "${#FIXTURES[@]}" -eq 0 ]; then
        printf 'the fixture list is empty - there is nothing to check integrity against\n'; return 1
    fi
    for d in "${FIXTURES[@]}"; do
        [ -d "$d" ] && [ -e "$d/.git" ] || missing="$missing $d"
    done
    [ -z "$missing" ] && return 0
    printf 'fixture repositor(y/ies) gone from the sandbox:%s\n' "$missing"
    printf 'Something outside this suite removed them - several sessions share this\n'
    printf '$TMPDIR. Nothing measured after that point means anything.\n'
    return 1
}

## t_proof <id> <description> <command...>
##
## t_check_fail, plus the two things it cannot know. The command must exit
## NON-ZERO because the planted fault was rejected - not because the fixture
## it needed had vanished. The id keeps the `.mutation` suffix, so
## test/MUTATION_COVERAGE counts these exactly as it counts every other
## suite's proofs.
t_proof() {
    local id="$1" desc="$2"; shift 2
    local out rc=0 why
    if ! why="$(fixtures_intact)"; then
        t_fail "$id" "$desc - THE FIXTURE WAS ALREADY GONE BEFORE THIS PROOF RAN, so it measured nothing"
        printf '%s\n' "$why" | sed 's/^/        /' >&2
        return 1
    fi
    out="$("$@" 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ]; then
        t_fail "$id" "$desc - THE CHECK ACCEPTED A PLANTED FAULT, so it cannot fail"
        printf '%s\n' "$out" | tail -14 | sed 's/^/        /' >&2
        return 1
    fi
    if ! why="$(fixtures_intact)"; then
        t_fail "$id" "$desc - the assertion went red, but SO DID ITS FIXTURE: this rejection proves nothing"
        printf '%s\n' "$why" | sed 's/^/        /' >&2
        return 1
    fi
    t_ok "$id" "$desc"
}

#=============================================================================
# THE FIXTURE REPOSITORIES. Built once, read by every predicate. Nothing below
# writes into one after this block except the two that lock a file's mode -
# and those do it here, so a predicate never changes what the next one sees.
#=============================================================================
t_head "fixtures - throwaway git repositories under $SB"

# R_PLANT: A is clean, B adds the core. HEAD is B.
R_PLANT="$SB/r-plant"; mkrepo "$R_PLANT" || exit 2
plant_clean "$R_PLANT/docs/readme.md"; plant_clean "$R_PLANT/build.tcl" 'set invented 1'
PLANT_A="$(commit_all "$R_PLANT" 'A: clean')" || exit 2
plant_core "$R_PLANT/ip/core.v"
PLANT_B="$(commit_all "$R_PLANT" 'B: adds the core')" || exit 2
t_say "r-plant     A=${PLANT_A:0:12} (clean)  B=${PLANT_B:0:12} (ip/core.v carries the directive at :2)"
FIXTURES+=("$R_PLANT")

# R_BACKLOG: the core is ALREADY in A. B touches a clean line elsewhere; C adds
# a vendor line to that same file. What --since/--new-lines-only must charge
# and must set aside.
R_BACKLOG="$SB/r-backlog"; mkrepo "$R_BACKLOG" || exit 2
plant_core "$R_BACKLOG/ip/core.v"
mkdir -p "$R_BACKLOG/docs" && printf 'hello\nworld\n' > "$R_BACKLOG/docs/readme.md"
BACK_A="$(commit_all "$R_BACKLOG" 'A: core already here')" || exit 2
printf 'hello\nworld\nmore\n' > "$R_BACKLOG/docs/readme.md"
BACK_B="$(commit_all "$R_BACKLOG" 'B: a clean line')" || exit 2
{ printf 'hello\nworld\nmore\n'; keyhdr_line; printf '\n'; } > "$R_BACKLOG/docs/readme.md"
BACK_C="$(commit_all "$R_BACKLOG" 'C: a vendor line at :4')" || exit 2
t_say "r-backlog   A=${BACK_A:0:12} B=${BACK_B:0:12} C=${BACK_C:0:12}"
FIXTURES+=("$R_BACKLOG")

# R_STAGED: the shape the checker's header names - `git add core && printf ''
# > core` - the INDEX holds the directive and the working tree does not.
R_STAGED="$SB/r-staged"; mkrepo "$R_STAGED" || exit 2
plant_clean "$R_STAGED/docs/readme.md"
commit_all "$R_STAGED" 'A: clean' >/dev/null || exit 2
plant_core "$R_STAGED/ip/core.v"
gitf "$R_STAGED" add ip/core.v || exit 2
plant_clean "$R_STAGED/ip/core.v" 'module specimen_core_9999; endmodule'
t_say "r-staged    index holds ip/core.v with the directive; the working copy is clean"
FIXTURES+=("$R_STAGED")

# R_STAGED_AGREE: the SAME staging, with the working copy left ALONE. The
# control for the known defect in section 5 - it isolates "the index and the
# working tree disagree" from "--new-lines-only drops things", which are two
# different bugs with two different fixes.
R_STAGED_AGREE="$SB/r-staged-agree"; mkrepo "$R_STAGED_AGREE" || exit 2
plant_clean "$R_STAGED_AGREE/docs/readme.md"
commit_all "$R_STAGED_AGREE" 'A: clean' >/dev/null || exit 2
plant_core "$R_STAGED_AGREE/ip/core.v"
gitf "$R_STAGED_AGREE" add ip/core.v || exit 2
FIXTURES+=("$R_STAGED_AGREE")

# R_FIRST: no commit yet. The very first `git add` of a repository.
R_FIRST="$SB/r-first"; mkrepo "$R_FIRST" || exit 2
plant_core "$R_FIRST/ip/core.v"
gitf "$R_FIRST" add -A || exit 2
FIXTURES+=("$R_FIRST")

# R_UNTRACKED: one clean commit; the core is UNTRACKED and not ignored; a
# bitstream is untracked AND ignored.
R_UNTRACKED="$SB/r-untracked"; mkrepo "$R_UNTRACKED" || exit 2
plant_clean "$R_UNTRACKED/readme.md"; printf 'build/\n' > "$R_UNTRACKED/.gitignore"
commit_all "$R_UNTRACKED" 'A: clean' >/dev/null || exit 2
plant_core "$R_UNTRACKED/scratch/core.v"
mkdir -p "$R_UNTRACKED/build"; printf 'invented bits\n' > "$R_UNTRACKED/build/out.bit"
FIXTURES+=("$R_UNTRACKED")

# R_BINONLY: one tracked file and it is a PNG. Nothing the text rules can read.
R_BINONLY="$SB/r-binonly"; mkrepo "$R_BINONLY" || exit 2
printf 'PNG\0\0\0invented' > "$R_BINONLY/logo.png"
commit_all "$R_BINONLY" 'A: a picture' >/dev/null || exit 2
FIXTURES+=("$R_BINONLY")

# R_NOTHING: git init and nothing else.
R_NOTHING="$SB/r-nothing"; mkrepo "$R_NOTHING" || exit 2
FIXTURES+=("$R_NOTHING")

# R_BIN: a text file beside an EXTENSIONLESS file holding NUL bytes - in the
# text corpus by name, binary by content.
R_BIN="$SB/r-bin"; mkrepo "$R_BIN" || exit 2
plant_clean "$R_BIN/readme.md"; printf 'LOGO\0\0\0invented' > "$R_BIN/LOGO"
commit_all "$R_BIN" 'A: text and a binary' >/dev/null || exit 2
FIXTURES+=("$R_BIN")

# R_DOT: a dotfile carrying a licence-server line. See the known defect at
# the end for why this fixture exists.
R_DOT="$SB/r-dot"; mkrepo "$R_DOT" || exit 2
plant_clean "$R_DOT/readme.md"; { licence_line; printf '\n'; } > "$R_DOT/.envrc"
commit_all "$R_DOT" 'A: a dotfile with a site fact' >/dev/null || exit 2
FIXTURES+=("$R_DOT")

# R_LOCK1: one clean commit, ONE untracked file, unreadable. The single-file
# batch, where the size pass's own "could not be measured" guard can fire.
R_LOCK1="$SB/r-lock1"; mkrepo "$R_LOCK1" || exit 2
plant_clean "$R_LOCK1/readme.md"
commit_all "$R_LOCK1" 'A: clean' >/dev/null || exit 2
plant_core "$R_LOCK1/scratch/core.v"
chmod 000 "$R_LOCK1/scratch/core.v" 2>/dev/null
FIXTURES+=("$R_LOCK1")

# R_LOCK2: two tracked files. aa/readme.md sorts FIRST and is unreadable;
# zz/core.v sorts after it and carries the directive. Both were committed
# readable - git cannot hash what it cannot open - and locked afterwards.
R_LOCK2="$SB/r-lock2"; mkrepo "$R_LOCK2" || exit 2
plant_clean "$R_LOCK2/aa/readme.md"; plant_core "$R_LOCK2/zz/core.v"
commit_all "$R_LOCK2" 'A: a readme and a core' >/dev/null || exit 2
chmod 000 "$R_LOCK2/aa/readme.md" 2>/dev/null
FIXTURES+=("$R_LOCK2")

# R_LOCK3: the size batch. aa/readme.md unreadable, data/big.csv is 300 000
# bytes of invented text (over the 262 144 threshold), zz/core.v is small and
# clean. Exactly one file is over the limit and it is the middle one.
R_LOCK3="$SB/r-lock3"; mkrepo "$R_LOCK3" || exit 2
plant_clean "$R_LOCK3/aa/readme.md"; plant_clean "$R_LOCK3/zz/core.v" 'module specimen_core_9999; endmodule'
mkdir -p "$R_LOCK3/data"; head -c 300000 /dev/zero | tr '\0' 'a' > "$R_LOCK3/data/big.csv"
commit_all "$R_LOCK3" 'A: one large file' >/dev/null || exit 2
chmod 000 "$R_LOCK3/aa/readme.md" 2>/dev/null
FIXTURES+=("$R_LOCK3")

# DOES MODE 000 BITE? Probed, not assumed: as uid 0, and on some mounts, the
# mode is honoured on paper and ignored in fact, and every assertion about an
# unreadable file would then be measuring a readable one.
MODE_BITES=1
if cat "$R_LOCK2/aa/readme.md" >/dev/null 2>&1; then MODE_BITES=0; fi
[ "$MODE_BITES" = 1 ] || t_say "mode 000 does NOT stop uid $(id -u) on $SB - the unreadable-file assertions will skip"

#=============================================================================
# 1. THE ARMING BLOCK - the file's claim about itself, driven from outside
#
# --arm-only is "prove every rule fires on its own specimen and stays silent
# on its counter-specimen. Scans nothing." Three things are asserted: that it
# passes on the rule table as shipped and that the count it reports is the
# count of rows in the source; that when a pattern rots the refusal NAMES the
# row; and that "scans nothing" is visible - a planted core in the cwd is
# neither named nor claimed clean, because no corpus verdict is written at all.
#=============================================================================
t_head "arming - --arm-only proves the table, names a rotted row, and scans nothing"

## n_text_rules / n_path_rules <toolkit> - rows in the SOURCE table
n_text_rules() { grep -cE '^vc_text_rule[[:space:]]' "$1/$CHK_REL"; }
n_path_rules() { grep -cE '^vc_path_rule[[:space:]]' "$1/$CHK_REL"; }

## arm_fires <toolkit>
## --arm-only exits 0, records PASS vendor.arm, and the detail's "N content
## rule form(s) ... and M path rule(s)" agree with the source. Two
## derivations of one number: a row that the arming loop stopped visiting
## would leave the source count ahead of the reported one.
arm_fires() {
    local vd out rc detail said_t said_p src_t src_p
    vd="$(vd_new)"; out="$(scan "$1" "$R_PLANT" "$vd" --arm-only)"; rc="$(exit_of "$out")"
    if [ "$rc" != 0 ]; then printf -- '--arm-only exited %s, expected 0\n' "$rc"; show "$out" "$vd"; return 1; fi
    has_row "$vd" PASS vendor.arm || { printf 'no PASS vendor.arm row\n'; show "$out" "$vd"; return 1; }
    detail="$(detail_of "$vd" vendor.arm)"
    said_t="$(printf '%s\n' "$detail" | sed -n 's/^\([0-9][0-9]*\) content rule form.*/\1/p')"
    said_p="$(printf '%s\n' "$detail" | sed -n 's/.* and \([0-9][0-9]*\) path rule(s).*/\1/p')"
    src_t="$(n_text_rules "$1")"; src_p="$(n_path_rules "$1")"
    if [ -z "$said_t" ] || [ -z "$said_p" ]; then
        printf 'vendor.arm detail no longer states its counts: %s\n' "$detail"; return 1
    fi
    if [ "$src_t" -lt 1 ] || [ "$src_p" -lt 1 ]; then
        printf 'the source table has %s text and %s path rows - nothing to compare against\n' "$src_t" "$src_p"; return 1
    fi
    if [ "$said_t" != "$src_t" ] || [ "$said_p" != "$src_p" ]; then
        printf 'arming reported %s text / %s path rule(s); the source declares %s / %s\n' "$said_t" "$said_p" "$src_t" "$src_p"
        return 1
    fi
    return 0
}
t_check vendor.arm.fires \
    "--arm-only passes, and the row count it reports is the row count in the source table" \
    arm_fires "$FLOW_DIR"

# The fault: the FIRST row's pattern loses a letter. sed BRE, with the
# brackets escaped so that the expression text itself is not the pattern.
ROT_EXPR='s/pragma\[\[:space:\]\]+protect/pragma[[:space:]]+protekt/'
M="$(t_mutant "$SB" arm-rotted)"
if t_mutate "$M" "$CHK_REL" "$ROT_EXPR"; then
    t_proof vendor.arm.fires.mutation \
        "with the first row's pattern rotted, --arm-only refuses and the assertion goes red" \
        arm_fires "$M"
    M_ROT="$M"
else
    t_skip vendor.arm.fires.mutation "could not plant the fault: the first ipenc row's pattern in $CHK_REL no longer matches $ROT_EXPR"
    M_ROT=""
fi

## arm_refusal_names_row <toolkit> <rule id> <row>
## On a copy whose row N has rotted: exit 2, an UNVERIFIED vendor.arm row, and
## the detail names "<rule>(row N:" - the thing a person has to fix. "The rule
## id appeared somewhere" is the weaker check and it is the one the checker's
## own header explains a half-dead rule hides behind.
arm_refusal_names_row() {
    local vd out rc detail
    vd="$(vd_new)"; out="$(scan "$1" "$R_PLANT" "$vd" --arm-only)"; rc="$(exit_of "$out")"
    if [ "$rc" != 2 ]; then printf 'a rotted table exited %s, expected 2 (refused)\n' "$rc"; show "$out" "$vd"; return 1; fi
    has_row "$vd" UNVERIFIED vendor.arm || { printf 'no UNVERIFIED vendor.arm row\n'; show "$out" "$vd"; return 1; }
    detail="$(detail_of "$vd" vendor.arm)"
    t_contains "$detail" "$2(row $3:" && return 0
    printf 'the refusal does not name %s(row %s: ...) - it says: %s\n' "$2" "$3" "$detail"
    return 1
}
if [ -n "$M_ROT" ]; then
    t_check vendor.arm.refusal \
        "a rotted row is refused with exit 2 and the refusal names the rule AND the row number" \
        arm_refusal_names_row "$M_ROT" ipenc 1
    # FIXTURE plus FAULT in one copy, stated: the rot is the fixture (the
    # assertion is about a refusal, so a refusal must happen), and the fault is
    # the message dropping its row number.
    M="$(t_mutant "$SB" arm-rotted-unnamed)"
    if t_mutate "$M" "$CHK_REL" "$ROT_EXPR" \
       && t_mutate "$M" "$CHK_REL" 's/(row \$_ln: /(/'; then
        t_proof vendor.arm.refusal.mutation \
            "with the refusal's row number removed, the same assertion goes red" \
            arm_refusal_names_row "$M" ipenc 1
    else
        t_skip vendor.arm.refusal.mutation "could not plant the fault: the 'unarmed=... (row \$_ln: ...' line in $CHK_REL has changed shape"
    fi
else
    t_skip vendor.arm.refusal "not attempted: the rotted copy it is measured on could not be planted"
    t_skip vendor.arm.refusal.mutation "not attempted: the rotted copy it is measured on could not be planted"
fi

## armonly_scans_nothing <toolkit>
## From inside a repository whose HEAD carries the core: exit 0, the core is
## NOT named, and - the part that makes "scans nothing" honest rather than
## silent - no vendor.corpus* or vendor.tracked* row exists. A caller reading
## the verdict file sees an arming verdict and no corpus verdict, which is
## the truth. A PASS vendor.tracked row here would be a clean-scan claim over
## a tree that was never read.
armonly_scans_nothing() {
    local vd out rc
    vd="$(vd_new)"; out="$(scan "$1" "$R_PLANT" "$vd" --arm-only)"; rc="$(exit_of "$out")"
    if [ "$rc" != 0 ]; then printf -- '--arm-only exited %s, expected 0\n' "$rc"; show "$out" "$vd"; return 1; fi
    if t_contains "$out" 'ip/core.v'; then printf -- '--arm-only named ip/core.v - it scanned\n'; show "$out" "$vd"; return 1; fi
    has_row "$vd" PASS vendor.arm || { printf 'no PASS vendor.arm row\n'; show "$out" "$vd"; return 1; }
    if id_like "$vd" '^vendor\.(corpus|tracked|untracked)'; then
        printf -- '--arm-only recorded a corpus or tracked verdict - a claim about a tree it says it does not scan\n'
        show "$out" "$vd"; return 1
    fi
    return 0
}
t_check vendor.arm.scansnothing \
    "--arm-only in a repository holding the core: exit 0, the core unnamed, and NO corpus verdict recorded" \
    armonly_scans_nothing "$FLOW_DIR"

M="$(t_mutant "$SB" arm-falls-through)"
if t_replace_line "$M" "$CHK_REL" 'if [ "$MODE_ARM_ONLY" = 1 ]; then' 'if false; then'; then
    t_proof vendor.arm.scansnothing.mutation \
        "with --arm-only falling through into the scan, the core is named and the assertion goes red" \
        armonly_scans_nothing "$M"
else
    t_skip vendor.arm.scansnothing.mutation "could not plant the fault: $CHK_REL has no line exactly 'if [ \"\$MODE_ARM_ONLY\" = 1 ]; then'"
fi

#=============================================================================
# 2. THE RULE TABLE LIVES IN ONE PLACE
#
# The checker's header: "A hook with its own private pattern list drifts from
# the CI gate, and two guards that disagree about the same file are worse than
# one - the disagreement teaches everybody that a red hook is noise." The
# hooks/ directory calls the scanner rather than carrying rules, and this is
# the assertion that keeps it so: every content pattern in the table is found,
# as a string, in no other file of the toolkit. The list is READ OUT OF THE
# TABLE at run time; there is no copy of it here to drift either.
#=============================================================================
t_head "one table - no other file in the toolkit carries a content pattern"

## rule_patterns <toolkit> - the <pattern> field of every vc_text_rule row.
## The row is `vc_text_rule <id> <case> \` and the pattern is the first quoted
## string on the line after it.
rule_patterns() {
    sed -n "/^vc_text_rule /{n;s/^[[:space:]]*'\([^']*\)'.*/\1/p}" "$1/$CHK_REL"
}

## rules_one_place <toolkit>
rules_one_place() {
    local pats n src_n p hits bad=""
    pats="$(rule_patterns "$1")"; n="$(printf '%s\n' "$pats" | grep -c .)"
    src_n="$(n_text_rules "$1")"
    if [ "$n" -ne "$src_n" ] || [ "$n" -lt 1 ]; then
        printf 'extracted %s pattern(s) from %s vc_text_rule row(s) - the table layout changed and this check is reading nothing\n' "$n" "$src_n"
        return 1
    fi
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        hits="$(grep -rlF --exclude-dir=.git -- "$p" "$1" 2>/dev/null | grep -vF "/$CHK_REL")"
        [ -z "$hits" ] || bad="$bad
  $p
     -> $(printf '%s ' $hits)"
    done <<< "$pats"
    [ -z "$bad" ] && return 0
    printf 'content pattern(s) copied outside %s:%s\n' "$CHK_REL" "$bad"
    printf 'A second copy is a second rule set, and the two will disagree.\n'
    return 1
}
t_check vendor.rules.oneplace \
    "every content pattern in the table appears in no other file of the toolkit ($(n_text_rules "$FLOW_DIR") rows read from the source)" \
    rules_one_place "$FLOW_DIR"

# The fault: hooks/lib-hook.sh grows a private copy of the first pattern - the
# exact drift the checker's header warns about.
FIRST_PAT="$(rule_patterns "$FLOW_DIR" | head -1)"
M="$(t_mutant "$SB" hook-private-rule)"
if [ -n "$FIRST_PAT" ] && [ -f "$M/hooks/lib-hook.sh" ] \
   && t_mutate "$M" hooks/lib-hook.sh "\$ a VC_HOOK_PRIVATE_PATTERN='${FIRST_PAT}'"; then
    t_proof vendor.rules.oneplace.mutation \
        "with a private copy of one pattern planted in hooks/lib-hook.sh, the assertion goes red" \
        rules_one_place "$M"
else
    t_skip vendor.rules.oneplace.mutation "could not plant the fault: no pattern could be read from the table, or hooks/lib-hook.sh is not in this checkout"
fi

#=============================================================================
# 3. --rev: FOUND, NAMED, NON-ZERO - AND THE RANGE IS RESPECTED
#
# The pushed-ref corpus. Three revisions of one repository answer three
# questions: the commit that adds the core is red and names it; the commit
# before it is green and does not; a commit the repository does not have is
# REFUSED, with exit 2 and an UNVERIFIED row, never an empty clean scan.
#=============================================================================
t_head "--rev - the commit that adds the core is named; its parent is not; an unknown sha is refused"

## rev_found <toolkit>
rev_found() {
    local vd out rc
    vd="$(vd_new)"; out="$(scan "$1" "$R_PLANT" "$vd" --rev "$PLANT_B")"; rc="$(exit_of "$out")"
    if [ "$rc" != 1 ]; then printf -- '--rev B exited %s, expected 1 (found collateral)\n' "$rc"; show "$out" "$vd"; return 1; fi
    has_row "$vd" FAIL vendor.tracked.ipenc || { printf 'no FAIL vendor.tracked.ipenc row\n'; show "$out" "$vd"; return 1; }
    t_contains "$out" 'ip/core.v:2' || { printf 'the finding does not name ip/core.v:2\n'; show "$out" "$vd"; return 1; }
    return 0
}
t_check vendor.rev.found \
    "--rev <B>: exit 1, FAIL vendor.tracked.ipenc, and the report names ip/core.v:2" \
    rev_found "$FLOW_DIR"

# The fault: an over-broad waiver. One allowlist line, glob `ip/*`, well
# formed in every field the checker validates - which is exactly why a waiver
# widened by a typo is a hole and not a mess.
M="$(t_mutant "$SB" rev-waived)"
if t_mutate "$M" "$CHK_REL" '/^VENDOR_COLLATERAL.md|ipenc,eula,path|/a ip/*|ipenc|an over-broad waiver planted by this suite to prove that a finding can be silenced|nobody'; then
    t_proof vendor.rev.found.mutation \
        "with a waiver for ip/* planted in the allowlist, the core is silenced and the assertion goes red" \
        rev_found "$M"
else
    t_skip vendor.rev.found.mutation "could not plant the fault: the VENDOR_COLLATERAL.md allowlist entry in $CHK_REL, which the planted line is appended after, has changed shape"
fi

## rev_range_before <toolkit>
## The parent commit, which has no ip/core.v: green, the path unnamed, and the
## corpus row counts A's two files rather than B's three - so a scanner that
## resolved the rev and then read HEAD anyway is caught by the count as well
## as by the name.
rev_range_before() {
    local vd out rc detail
    vd="$(vd_new)"; out="$(scan "$1" "$R_PLANT" "$vd" --rev "$PLANT_A")"; rc="$(exit_of "$out")"
    if [ "$rc" != 0 ]; then printf -- '--rev A exited %s, expected 0\n' "$rc"; show "$out" "$vd"; return 1; fi
    has_row "$vd" PASS vendor.tracked || { printf 'no PASS vendor.tracked row\n'; show "$out" "$vd"; return 1; }
    if t_contains "$out" 'ip/core.v'; then printf -- '--rev A named ip/core.v, which A does not contain\n'; show "$out" "$vd"; return 1; fi
    detail="$(detail_of "$vd" vendor.corpus.rev)"
    case "$detail" in "2 file(s) from the tree at $PLANT_A"*) return 0 ;; esac
    printf 'the corpus row does not describe the tree at A: %s\n' "$detail"; show "$out" "$vd"; return 1
}
t_check vendor.rev.range \
    "--rev <A>, the parent: exit 0, PASS vendor.tracked, ip/core.v unnamed, and the corpus row counts A's files" \
    rev_range_before "$FLOW_DIR"

# The fault: the rev is validated and then HEAD is read. One token.
M="$(t_mutant "$SB" rev-reads-head)"
if t_mutate "$M" "$CHK_REL" 's/"\$MODE_REV^{commit}"/"HEAD^{commit}"/'; then
    t_proof vendor.rev.range.mutation \
        "with the named rev replaced by HEAD (which is B), --rev A reports the core and the assertion goes red" \
        rev_range_before "$M"
else
    t_skip vendor.rev.range.mutation "could not plant the fault: the rev-parse of \"\$MODE_REV^{commit}\" in $CHK_REL has changed shape"
fi

## rev_unknown_refused <toolkit>
rev_unknown_refused() {
    local vd out rc detail
    if gitf "$R_PLANT" cat-file -e "$NOSHA" 2>/dev/null; then
        printf 'the fixture somehow contains %s - the assertion would be about a real object\n' "$NOSHA"; return 1
    fi
    vd="$(vd_new)"; out="$(scan "$1" "$R_PLANT" "$vd" --rev "$NOSHA")"; rc="$(exit_of "$out")"
    if [ "$rc" != 2 ]; then printf -- '--rev <unknown> exited %s, expected 2 (refused)\n' "$rc"; show "$out" "$vd"; return 1; fi
    has_row "$vd" UNVERIFIED vendor.corpus || { printf 'no UNVERIFIED vendor.corpus row\n'; show "$out" "$vd"; return 1; }
    detail="$(detail_of "$vd" vendor.corpus)"
    t_contains "$detail" 'does not resolve' || { printf 'the refusal does not say the sha does not resolve: %s\n' "$detail"; return 1; }
    if id_like "$vd" '^vendor\.tracked'; then printf 'a tracked verdict was recorded for a tree that does not exist\n'; show "$out" "$vd"; return 1; fi
    if id_like "$vd" '^vendor\.corpus\.rev$'; then printf 'a corpus.rev row was recorded - the empty-tree skip - for a sha that does not exist\n'; show "$out" "$vd"; return 1; fi
    return 0
}
t_check vendor.rev.unknown \
    "--rev <sha the repository does not have>: exit 2, UNVERIFIED vendor.corpus saying it does not resolve, and no tracked verdict" \
    rev_unknown_refused "$FLOW_DIR"

# The fault: the refusal becomes the "nothing to scan" skip - exit 0 with a
# SKIP row, which is the empty clean scan by name.
LINE="$(grep -F 'does not resolve to a commit in this repository' "$FLOW_DIR/$CHK_REL" | head -1)"
M="$(t_mutant "$SB" rev-unknown-skips)"
if [ -n "$LINE" ] && t_replace_line "$M" "$CHK_REL" "$LINE" \
       '        ci_skip vendor.corpus.rev "nothing to scan - $MODE_REV is not here"; ci_exit vendor-collateral; exit 0'; then
    t_proof vendor.rev.unknown.mutation \
        "with the refusal turned into a SKIP-and-exit-0, the assertion goes red" \
        rev_unknown_refused "$M"
else
    t_skip vendor.rev.unknown.mutation "could not plant the fault: $CHK_REL has no single line containing 'does not resolve to a commit in this repository'"
fi

#=============================================================================
# 4. --since / --new-lines-only: WHAT A PUSH ADDS IS CHARGED, WHAT IT
#    INHERITS IS SET ASIDE - AND SAID
#
# The pre-push hook's shape. The narrowing exists so a backlog does not make
# the gate unpassable, and the checker's header is emphatic that a filter
# which removes findings in silence is indistinguishable from a clean tree.
# So both halves are asserted: the set-aside is announced in prose (and, in
# --fast, on the backlog channel the hook reads), and an added vendor line is
# charged. A base that does not resolve is refused, not warned past.
#=============================================================================
t_head "--since/--new-lines-only - inherited findings are set aside AND announced; added lines are charged"

## backlog_said <toolkit>
backlog_said() {
    local vd out rc
    vd="$(vd_new)"; out="$(scan "$1" "$R_BACKLOG" "$vd" --rev "$BACK_B" --since "$BACK_A" --new-lines-only)"; rc="$(exit_of "$out")"
    if [ "$rc" != 0 ]; then printf 'B since A exited %s, expected 0 - the core is inherited, not added\n' "$rc"; show "$out" "$vd"; return 1; fi
    has_row "$vd" PASS vendor.tracked || { printf 'no PASS vendor.tracked row\n'; show "$out" "$vd"; return 1; }
    # ANCHORED TO ci_say's OWN PREFIX - `printf '   %s\n'`, three spaces - and
    # not to the sentence alone. scan() captures stderr as well as stdout, and
    # the first attempt at this proof planted a fault that left the message
    # dangling as its own bash command: bash then echoed the whole expanded
    # string back in `command not found`, the loose pattern matched THAT, and
    # the proof reported that a scanner which had said nothing had spoken. A
    # predicate that can be satisfied by the shell complaining about the code
    # under test is not measuring the code under test.
    t_matches "$out" '^   [1-9][0-9]* pre-existing finding\(s\) on lines this change does not add' && return 0
    printf 'the run set findings aside and did not say so\n'; show "$out" "$vd"; return 1
}
t_check vendor.since.backlog.said \
    "--rev B --since A --new-lines-only over an inherited core: exit 0, and the set-aside count is announced" \
    backlog_said "$FLOW_DIR"

# The fault: the announcement's call becomes `:`, which ignores its argument.
# NOT t_replace_line here: that line ENDS IN A BACKSLASH continuing onto the
# message, and sed's `c\` text swallows a trailing backslash - the replacement
# would silently drop the continuation, leave the message standing as its own
# command, and have bash print it. Substituting the command name keeps the
# continuation and the string exactly where they are.
M="$(t_mutant "$SB" backlog-silent)"
if t_mutate "$M" "$CHK_REL" '/_before:-0}/s/ci_say/:/'; then
    t_proof vendor.since.backlog.said.mutation \
        "with the announcement removed, the same clean run says nothing and the assertion goes red" \
        backlog_said "$M"
else
    t_skip vendor.since.backlog.said.mutation "could not plant the fault: the '_before -ne _after && ci_say' line in $CHK_REL has changed shape"
fi

## backlog_channel <toolkit>
## --fast silences the prose, so the hook reads VENDOR_CHECK_BACKLOG_OUT. It
## must name the inherited finding: rule, path, line.
backlog_channel() {
    local vd out rc bk
    vd="$(vd_new)"; bk="$vd/backlog.tsv"
    SCAN_ENV=("VENDOR_CHECK_BACKLOG_OUT=$bk")
    out="$(scan "$1" "$R_BACKLOG" "$vd" --rev "$BACK_B" --since "$BACK_A" --new-lines-only --fast)"; rc="$(exit_of "$out")"
    SCAN_ENV=()
    if [ "$rc" != 0 ]; then printf 'B since A --fast exited %s, expected 0\n' "$rc"; show "$out" "$vd"; return 1; fi
    [ -f "$bk" ] || { printf 'VENDOR_CHECK_BACKLOG_OUT was not written at all\n'; return 1; }
    awk -F'\t' '$1 == "ipenc" && $2 == "ip/core.v" && $3 == "2" { f = 1 } END { exit !f }' "$bk" && return 0
    printf 'the backlog channel does not carry "ipenc <TAB> ip/core.v <TAB> 2"; it holds:\n%s\n' "$(cat "$bk")"
    return 1
}
t_check vendor.since.backlog.channel \
    "the same run under --fast writes the inherited finding to VENDOR_CHECK_BACKLOG_OUT as rule/path/line" \
    backlog_channel "$FLOW_DIR"

M="$(t_mutant "$SB" backlog-empty-channel)"
if t_replace_line "$M" "$CHK_REL" \
       '        cp "$SCRATCH/all.drop" "$VENDOR_CHECK_BACKLOG_OUT" 2>/dev/null || : > "$VENDOR_CHECK_BACKLOG_OUT"' \
       '        : > "$VENDOR_CHECK_BACKLOG_OUT"'; then
    t_proof vendor.since.backlog.channel.mutation \
        "with the channel written EMPTY instead of with the set-aside findings, the assertion goes red" \
        backlog_channel "$M"
else
    t_skip vendor.since.backlog.channel.mutation "could not plant the fault: the cp of all.drop to VENDOR_CHECK_BACKLOG_OUT in $CHK_REL has changed shape"
fi

## added_line_charged <toolkit>
## C adds one vendor line to docs/readme.md, at :4. The push hook's exact
## shape must name it and exit 1.
added_line_charged() {
    local vd out rc
    vd="$(vd_new)"; out="$(scan "$1" "$R_BACKLOG" "$vd" --rev "$BACK_C" --since "$BACK_B" --new-lines-only --fast)"; rc="$(exit_of "$out")"
    if [ "$rc" != 1 ]; then printf 'C since B exited %s, expected 1 - C ADDS a vendor line\n' "$rc"; show "$out" "$vd"; return 1; fi
    has_row "$vd" FAIL vendor.ipenc || { printf 'no FAIL vendor.ipenc row\n'; show "$out" "$vd"; return 1; }
    t_contains "$out" 'docs/readme.md:4' || { printf 'the added line docs/readme.md:4 is not named\n'; show "$out" "$vd"; return 1; }
    return 0
}
t_check vendor.since.added \
    "--rev C --since B --new-lines-only --fast: the vendor line C adds is charged, at docs/readme.md:4" \
    added_line_charged "$FLOW_DIR"

M="$(t_mutant "$SB" newlines-drop-added)"
if t_mutate "$M" "$CHK_REL" '/in new)/s/print > keep/print > drop/'; then
    t_proof vendor.since.added.mutation \
        "with added lines routed to the drop pile, the change is uncharged and the assertion goes red" \
        added_line_charged "$M"
else
    t_skip vendor.since.added.mutation "could not plant the fault: the awk 'in new) ... print > keep' line in $CHK_REL has changed shape"
fi

## since_unknown_refused <toolkit>
since_unknown_refused() {
    local vd out rc detail
    vd="$(vd_new)"; out="$(scan "$1" "$R_BACKLOG" "$vd" --rev "$BACK_C" --since "$NOSHA" --new-lines-only --fast)"; rc="$(exit_of "$out")"
    if [ "$rc" != 2 ]; then printf -- '--since <unknown> exited %s, expected 2 (refused)\n' "$rc"; show "$out" "$vd"; return 1; fi
    has_row "$vd" UNVERIFIED vendor.corpus || { printf 'no UNVERIFIED vendor.corpus row\n'; show "$out" "$vd"; return 1; }
    detail="$(detail_of "$vd" vendor.corpus)"
    t_contains "$detail" 'does not resolve' || { printf 'the refusal does not say the base does not resolve: %s\n' "$detail"; return 1; }
    if id_like "$vd" '^vendor\.(tracked|ipenc)'; then printf 'a finding verdict was recorded against a base that does not exist\n'; show "$out" "$vd"; return 1; fi
    return 0
}
t_check vendor.since.unknown \
    "--since <sha the repository does not have>: exit 2 and UNVERIFIED vendor.corpus - not a warning and a whole-tree charge" \
    since_unknown_refused "$FLOW_DIR"

M="$(t_mutant "$SB" since-unknown-warns)"
if t_replace_line "$M" "$CHK_REL" \
       '            vc_refuse vendor.corpus \' \
       '            ci_warn vendor.newlines.unavailable \'; then
    t_proof vendor.since.unknown.mutation \
        "with the refusal downgraded to a warning, the run proceeds and the assertion goes red" \
        since_unknown_refused "$M"
else
    t_skip vendor.since.unknown.mutation "could not plant the fault: $CHK_REL has no line exactly '            vc_refuse vendor.corpus \\' (the --since refusal)"
fi

#=============================================================================
# 5. --staged READS THE INDEX, NOT THE WORKING TREE
#
# `git add core && printf '' > core`: the developer's tree is clean and the
# commit is about to publish the core, which is the whole reason this mode
# exists. The fixture's realism is checked first - the plain worktree scan of
# the same repository IS clean - so the assertion cannot pass on a fixture
# where both corpora happened to hold the core.
#
# --staged gets the answer right. The PRE-COMMIT HOOK'S OWN FLAGS do not, and
# the known defect below is where that is measured and why.
#=============================================================================
t_head "--staged - the index is scanned; the first commit is not a blind spot; the hook's own flags drop content findings (KNOWN DEFECT)"

## staged_reads_index <toolkit>
staged_reads_index() {
    local vd out rc
    vd="$(vd_new)"; out="$(scan "$1" "$R_STAGED" "$vd")"; rc="$(exit_of "$out")"
    if [ "$rc" != 0 ] || ! has_row "$vd" PASS vendor.tracked; then
        printf 'FIXTURE: the working tree of r-staged is not clean (exit %s), so index-vs-tree cannot be told apart here\n' "$rc"
        show "$out" "$vd"; return 1
    fi
    vd="$(vd_new)"; out="$(scan "$1" "$R_STAGED" "$vd" --staged --fast)"; rc="$(exit_of "$out")"
    if [ "$rc" != 1 ]; then printf -- '--staged exited %s, expected 1 - the INDEX holds the core\n' "$rc"; show "$out" "$vd"; return 1; fi
    has_row "$vd" FAIL vendor.ipenc || { printf 'no FAIL vendor.ipenc row\n'; show "$out" "$vd"; return 1; }
    t_contains "$out" 'ip/core.v:2' || { printf 'the staged finding does not name ip/core.v:2\n'; show "$out" "$vd"; return 1; }
    return 0
}
t_check vendor.staged.index \
    "the working tree is clean and --staged --fast still names ip/core.v:2 out of the index" \
    staged_reads_index "$FLOW_DIR"

# The fault: the staged corpus reads its paths from the working tree instead
# of from the materialised blobs. Addressed to the --staged branch only; the
# --rev branch has the same line and is not the one under proof.
M="$(t_mutant "$SB" staged-reads-tree)"
if t_mutate "$M" "$CHK_REL" '/CORPUS" = staged ]; then/,/^elif/ s|VC_PREFIX="\$SCRATCH/corpus/"|VC_PREFIX=""|'; then
    t_proof vendor.staged.index.mutation \
        "with --staged reading the working tree's bytes, the emptied file yields nothing and the assertion goes red" \
        staged_reads_index "$M"
else
    t_skip vendor.staged.index.mutation "could not plant the fault: the VC_PREFIX assignment inside the --staged branch of $CHK_REL has changed shape"
fi

#-----------------------------------------------------------------------------
# THE PRE-COMMIT HOOK'S EXACT FLAGS, AND WHAT THEY DROP - KNOWN DEFECT
#
# hooks/pre-commit runs `--staged --fast --new-lines-only`. The first flag
# says READ THE INDEX; the third says charge only the lines this change adds.
# The map of added lines comes from vc_addedlines, which runs
#
#     git diff --unified=0 --no-renames --diff-filter=ACMRTU <HEAD>
#
# with NO --cached. That diffs HEAD against the WORKING TREE, so the lines it
# calls "added" are the working tree's, while the content being scanned is the
# index's. When the two agree - the ordinary commit - the map is right by
# coincidence and everything works. When they differ, every CONTENT finding in
# the staged blob falls outside the map, is filed as pre-existing backlog, and
# is dropped. The commit proceeds, silently, exit 0.
#
# The divergent case is not exotic. It is the one the file's own header offers
# as the reason --staged exists at all: "`git add core.edn && printf '' >
# core.edn` leaves a clean working tree and a commit that publishes a netlist."
# Measured here 2026-09-17: `--staged --fast` finds ip/core.v:2 and exits 1;
# adding --new-lines-only - which is what the installed hook does - exits 0 and
# prints nothing. Restoring the working copy to match the index makes the same
# command find it again, which is what identifies the diff rather than the scan.
#
# A PATH-shaped finding survives, and that is why this has not been noticed: a
# staged `.edn` has no line number, the line filter cannot touch it, and the
# header's worked example is a .edn. It is the CONTENT rules - the encrypted-IP
# envelope, the EULA header, the licence server, everything that arrives inside
# a file with an innocent name - that this drops.
#
# NOT FIXED HERE (this suite reports; it does not repair the thing it grades).
# What would settle it: `--cached` in the --staged branch's call to
# vc_addedlines, so the map describes the same content the scan reads. The
# marker goes RED the day that lands.
#-----------------------------------------------------------------------------
## staged_newlines_sees_index <toolkit>
## The hook's exact invocation over the exact shape it exists for.
staged_newlines_sees_index() {
    local vd out rc
    vd="$(vd_new)"; out="$(scan "$1" "$R_STAGED" "$vd" --staged --fast --new-lines-only)"; rc="$(exit_of "$out")"
    if [ "$rc" != 1 ]; then printf -- '--staged --fast --new-lines-only exited %s, expected 1 - the INDEX holds the core at :2\n' "$rc"; show "$out" "$vd"; return 1; fi
    t_contains "$out" 'ip/core.v:2' || { printf 'the finding does not name ip/core.v:2\n'; show "$out" "$vd"; return 1; }
    return 0
}
t_known_defect vendor.staged.newlines \
    "the pre-commit shape --staged --fast --new-lines-only charges a vendor line the index adds (today: the added-line map is built from the WORKING TREE, so a diverged copy drops every content finding and the commit passes)" \
    staged_newlines_sees_index "$FLOW_DIR"

## staged_newlines_agreeing_copy <toolkit>
## THE CONTROL THAT MAKES THE MARKER ABOVE A MEASUREMENT RATHER THAN A GUESS.
## Same repository, same flags; the only difference is that the working copy
## is restored to what was staged. It passes - so the marker above is about
## the DIVERGENCE between index and working tree, and not about
## --new-lines-only being broken in general, which would be a different bug
## with a different fix.
staged_newlines_agreeing_copy() {
    local vd out rc
    vd="$(vd_new)"; out="$(scan "$1" "$R_STAGED_AGREE" "$vd" --staged --fast --new-lines-only)"; rc="$(exit_of "$out")"
    if [ "$rc" != 1 ]; then printf 'with the working copy agreeing, the hook shape exited %s, expected 1\n' "$rc"; show "$out" "$vd"; return 1; fi
    t_contains "$out" 'ip/core.v:2' || { printf 'the finding does not name ip/core.v:2\n'; show "$out" "$vd"; return 1; }
    return 0
}
t_check vendor.staged.newlines.control \
    "the same flags on the same repository DO charge the line when the working copy matches the index - so the marker above is about the divergence" \
    staged_newlines_agreeing_copy "$FLOW_DIR"

# The fault: the --staged branch's added-line map is written EMPTY, so no
# finding can be on a line the change adds. `: > file` succeeds, so the `|| {`
# block below it - which warns and turns the narrowing OFF - stays unentered;
# a fault that tripped that block would have DISABLED the filter and left the
# control green for the opposite reason.
M="$(t_mutant "$SB" newlines-map-empty)"
if t_replace_line "$M" "$CHK_REL" \
       '        vc_addedlines "$_against" > "$SCRATCH/addedlines.tsv" || {' \
       '        : > "$SCRATCH/addedlines.tsv" || {'; then
    t_proof vendor.staged.newlines.control.mutation \
        "with the added-line map emptied, even an agreeing working copy drops the finding and the control goes red" \
        staged_newlines_agreeing_copy "$M"
else
    t_skip vendor.staged.newlines.control.mutation "could not plant the fault: the vc_addedlines call in the --staged branch of $CHK_REL has changed shape"
fi

## staged_first_commit <toolkit>
## No HEAD to diff against. The checker diffs against the empty tree so a
## fresh import plus `git add -A` is scanned rather than skipped.
staged_first_commit() {
    local vd out rc
    vd="$(vd_new)"; out="$(scan "$1" "$R_FIRST" "$vd" --staged --fast --new-lines-only)"; rc="$(exit_of "$out")"
    if [ "$rc" != 1 ]; then printf 'the first commit exited %s, expected 1\n' "$rc"; show "$out" "$vd"; return 1; fi
    has_row "$vd" FAIL vendor.ipenc || { printf 'no FAIL vendor.ipenc row\n'; show "$out" "$vd"; return 1; }
    t_contains "$out" 'ip/core.v:2' || { printf 'the finding does not name ip/core.v:2\n'; show "$out" "$vd"; return 1; }
    return 0
}
t_check vendor.staged.firstcommit \
    "a repository with no commit yet: --staged still names the core in its very first index" \
    staged_first_commit "$FLOW_DIR"

M="$(t_mutant "$SB" staged-needs-head)"
if t_replace_line "$M" "$CHK_REL" \
       '    [ -n "$_against" ] || _against="$(git hash-object -t tree /dev/null 2>/dev/null)"' \
       '    [ -n "$_against" ] || _against=HEAD'; then
    t_proof vendor.staged.firstcommit.mutation \
        "with the empty-tree fallback replaced by HEAD, the first commit cannot be diffed and the assertion goes red" \
        staged_first_commit "$M"
else
    t_skip vendor.staged.firstcommit.mutation "could not plant the fault: the empty-tree fallback line in $CHK_REL has changed shape"
fi

#=============================================================================
# 6. THE WORKTREE CORPUS: UNTRACKED FILES ARE A SEPARATE PILE, --no-untracked
#    SAYS WHAT IT SKIPPED, AND AN IGNORED FILE IS A DECISION
#=============================================================================
t_head "worktree - an untracked core is found in its own pile; --no-untracked warns; ignored files stay out"

## untracked_found <toolkit>
untracked_found() {
    local vd out rc
    vd="$(vd_new)"; out="$(scan "$1" "$R_UNTRACKED" "$vd")"; rc="$(exit_of "$out")"
    if [ "$rc" != 1 ]; then printf 'the worktree scan exited %s, expected 1\n' "$rc"; show "$out" "$vd"; return 1; fi
    has_row "$vd" FAIL vendor.untracked.ipenc || { printf 'no FAIL vendor.untracked.ipenc row - the finding is not in the untracked pile\n'; show "$out" "$vd"; return 1; }
    has_row "$vd" PASS vendor.tracked || { printf 'the tracked pile is not PASS - the two piles have merged\n'; show "$out" "$vd"; return 1; }
    t_contains "$out" 'scratch/core.v:2' || { printf 'the finding does not name scratch/core.v:2\n'; show "$out" "$vd"; return 1; }
    return 0
}
t_check vendor.untracked.found \
    "an untracked, non-ignored core: FAIL vendor.untracked.ipenc naming scratch/core.v:2, with the tracked pile still PASS" \
    untracked_found "$FLOW_DIR"

M="$(t_mutant "$SB" untracked-off)"
if t_replace_line "$M" "$CHK_REL" 'MODE_UNTRACKED=1' 'MODE_UNTRACKED=0'; then
    t_proof vendor.untracked.found.mutation \
        "with the untracked scan defaulted off, the core is not reported and the assertion goes red" \
        untracked_found "$M"
else
    t_skip vendor.untracked.found.mutation "could not plant the fault: $CHK_REL has no line exactly 'MODE_UNTRACKED=1'"
fi

## nountracked_warns <toolkit>
## The one narrowing a caller can ask for by flag. It must be RECORDED - a
## WARN row saying the files were NOT scanned - so the verdict file never
## reads as a full scan.
nountracked_warns() {
    local vd out rc detail
    vd="$(vd_new)"; out="$(scan "$1" "$R_UNTRACKED" "$vd" --no-untracked)"; rc="$(exit_of "$out")"
    if [ "$rc" != 0 ]; then printf -- '--no-untracked exited %s, expected 0 (the tracked tree is clean)\n' "$rc"; show "$out" "$vd"; return 1; fi
    has_row "$vd" WARN vendor.corpus.untracked || { printf 'no WARN vendor.corpus.untracked row - the narrowing left no trace\n'; show "$out" "$vd"; return 1; }
    detail="$(detail_of "$vd" vendor.corpus.untracked)"
    t_contains "$detail" 'NOT scanned' || { printf 'the warning does not say the files were NOT scanned: %s\n' "$detail"; return 1; }
    return 0
}
t_check vendor.untracked.warned \
    "--no-untracked: exit 0, and a WARN vendor.corpus.untracked row saying the files were NOT scanned" \
    nountracked_warns "$FLOW_DIR"

M="$(t_mutant "$SB" untracked-silent-skip)"
if t_replace_line "$M" "$CHK_REL" \
       '    [ "$MODE_UNTRACKED" = 1 ] || ci_warn vendor.corpus.untracked \' \
       '    true || ci_warn vendor.corpus.untracked \'; then
    t_proof vendor.untracked.warned.mutation \
        "with the warning removed, --no-untracked skips in silence and the assertion goes red" \
        nountracked_warns "$M"
else
    t_skip vendor.untracked.warned.mutation "could not plant the fault: the '--no-untracked' ci_warn line in $CHK_REL has changed shape"
fi

## ignored_stays_out <toolkit>
## build/out.bit is untracked AND matched by .gitignore. It is a bitstream by
## name, and it must NOT be reported: an ignored file is a decision somebody
## wrote down, and a hook that flags a build tree on every commit is a hook
## people switch off. The census must count one untracked file, not two.
ignored_stays_out() {
    local vd out rc detail
    vd="$(vd_new)"; out="$(scan "$1" "$R_UNTRACKED" "$vd")"; rc="$(exit_of "$out")"
    if t_contains "$out" 'build/out.bit'; then printf 'the IGNORED build/out.bit was reported\n'; show "$out" "$vd"; return 1; fi
    detail="$(detail_of "$vd" vendor.corpus)"
    case "$detail" in *'+ 1 untracked-not-ignored'*) return 0 ;; esac
    printf 'the census does not count exactly one untracked-not-ignored file: %s\n' "$detail"; show "$out" "$vd"; return 1
}
t_check vendor.untracked.ignored \
    "an ignored bitstream is neither reported nor counted - the census says 1 untracked-not-ignored" \
    ignored_stays_out "$FLOW_DIR"

# The fault: --exclude-standard dropped from BOTH untracked listings. One
# fault - "ignore rules are not consulted" - that the checker spells twice.
M="$(t_mutant "$SB" untracked-ignores-gitignore)"
if t_mutate "$M" "$CHK_REL" 's/git ls-files --others --exclude-standard/git ls-files --others/'; then
    t_proof vendor.untracked.ignored.mutation \
        "with .gitignore no longer consulted, the bitstream is reported and the assertion goes red" \
        ignored_stays_out "$M"
else
    t_skip vendor.untracked.ignored.mutation "could not plant the fault: 'git ls-files --others --exclude-standard' no longer appears in $CHK_REL"
fi

#=============================================================================
# 7. THE CENSUS REFUSES AN EMPTY CORPUS
#
# The reference guard's failure in one line: it never asked how many files it
# had looked at. Two shapes of nothing, both refused with exit 2 and an
# UNVERIFIED row, and each proof turns the refusal off and watches "0 files
# scanned" become a pass.
#=============================================================================
t_head "census - zero readable files and zero tracked files are refused, never passed"

## binonly_refused <toolkit>
binonly_refused() {
    local vd out rc detail
    vd="$(vd_new)"; out="$(scan "$1" "$R_BINONLY" "$vd")"; rc="$(exit_of "$out")"
    if [ "$rc" != 2 ]; then printf 'a corpus of one PNG exited %s, expected 2 (refused)\n' "$rc"; show "$out" "$vd"; return 1; fi
    has_row "$vd" UNVERIFIED vendor.corpus || { printf 'no UNVERIFIED vendor.corpus row\n'; show "$out" "$vd"; return 1; }
    detail="$(detail_of "$vd" vendor.corpus)"
    t_contains "$detail" 'NOT ONE matched the text corpus' || { printf 'the refusal does not say no file matched the text corpus: %s\n' "$detail"; return 1; }
    if id_like "$vd" '^vendor\.tracked'; then printf 'a tracked verdict was recorded over a corpus with nothing readable in it\n'; show "$out" "$vd"; return 1; fi
    return 0
}
t_check vendor.census.noreadable \
    "one tracked file and it is a PNG: exit 2, UNVERIFIED vendor.corpus, no tracked verdict" \
    binonly_refused "$FLOW_DIR"

M="$(t_mutant "$SB" census-zero-text-ok)"
if t_replace_line "$M" "$CHK_REL" '    if [ "${n_text_tracked:-0}" -eq 0 ]; then' '    if false; then'; then
    t_proof vendor.census.noreadable.mutation \
        "with the zero-readable-files refusal disabled, the empty scan passes and the assertion goes red" \
        binonly_refused "$M"
else
    t_skip vendor.census.noreadable.mutation "could not plant the fault: the n_text_tracked refusal in $CHK_REL has changed shape"
fi

## nothing_refused <toolkit>
nothing_refused() {
    local vd out rc detail
    vd="$(vd_new)"; out="$(scan "$1" "$R_NOTHING" "$vd")"; rc="$(exit_of "$out")"
    if [ "$rc" != 2 ]; then printf 'an empty repository exited %s, expected 2 (refused)\n' "$rc"; show "$out" "$vd"; return 1; fi
    has_row "$vd" UNVERIFIED vendor.corpus || { printf 'no UNVERIFIED vendor.corpus row\n'; show "$out" "$vd"; return 1; }
    detail="$(detail_of "$vd" vendor.corpus)"
    t_contains "$detail" 'returned NOTHING' || { printf 'the refusal does not say git ls-files returned nothing: %s\n' "$detail"; return 1; }
    return 0
}
t_check vendor.census.nothing \
    "a repository with no tracked file at all: exit 2 and UNVERIFIED vendor.corpus saying ls-files returned NOTHING" \
    nothing_refused "$FLOW_DIR"

# The fault: that refusal becomes a skip. MEASURED WHEN THIS PROOF WAS
# VERIFIED, and worth recording: the mutant still exits 2, because the
# zero-READABLE refusal immediately below catches the same empty repository on
# its way past. The two guards overlap, which is a good property of the
# checker and a trap for a proof - one that accepted any non-zero exit would
# have passed here with the guard it was aimed at fully deleted. It goes red on
# the REASON instead: the verdict row now says "nothing tracked", which is the
# planted skip, and not what ls-files returned. This is the README's rule
# ("assert on the message, not just the exit status") earning its place.
M="$(t_mutant "$SB" census-zero-tracked-skip)"
if t_replace_line "$M" "$CHK_REL" \
       '        vc_refuse vendor.corpus "git ls-files returned NOTHING - this scan measured nothing at all"' \
       '        ci_skip vendor.corpus "nothing tracked"'; then
    t_proof vendor.census.nothing.mutation \
        "with that refusal turned into a skip, the assertion goes red" \
        nothing_refused "$M"
else
    t_skip vendor.census.nothing.mutation "could not plant the fault: the 'git ls-files returned NOTHING' refusal in $CHK_REL has changed shape"
fi

## binnote_said <toolkit>
## A file in the text corpus by name that turns out to be binary is not read,
## and the census SAYS so: "N binary and judged by path alone". This is the
## checker doing the right thing for the one skip it detects, and it is
## asserted here so that the known defects below have something to be
## measured against.
binnote_said() {
    local vd out rc detail
    vd="$(vd_new)"; out="$(scan "$1" "$R_BIN" "$vd")"; rc="$(exit_of "$out")"
    if [ "$rc" != 0 ]; then printf 'r-bin exited %s, expected 0\n' "$rc"; show "$out" "$vd"; return 1; fi
    detail="$(detail_of "$vd" vendor.corpus)"
    case "$detail" in
        *'1 of them read for content, 1 binary and judged by path alone'*) return 0 ;;
    esac
    printf 'the census does not say one file was binary and unread: %s\n' "$detail"; show "$out" "$vd"; return 1
}
t_check vendor.census.binary \
    "an extensionless file holding NUL bytes is counted and announced as 'binary and judged by path alone'" \
    binnote_said "$FLOW_DIR"

M="$(t_mutant "$SB" census-binary-unsaid)"
if t_replace_line "$M" "$CHK_REL" \
       '[ "${n_bin:-0}" -gt 0 ] && _binnote=", $n_bin binary and judged by path alone"' \
       'false && _binnote=", $n_bin binary and judged by path alone"'; then
    t_proof vendor.census.binary.mutation \
        "with the binary note suppressed, the unread file vanishes from the census and the assertion goes red" \
        binnote_said "$M"
else
    t_skip vendor.census.binary.mutation "could not plant the fault: the _binnote line in $CHK_REL has changed shape"
fi

#=============================================================================
# 8. --fast: THE HOOK MODE - SILENT WHEN CLEAN, DATA WHEN NOT
#
# hooks/lib-hook.sh reads VENDOR_CHECK_FINDINGS_OUT to name the files in a
# bypass record. It must carry the finding as rule/path/line, not as prose.
#=============================================================================
t_head "--fast - findings go out as data on the hook's channel; a clean run prints nothing"

## fast_findings_channel <toolkit>
fast_findings_channel() {
    local vd out rc fo
    vd="$(vd_new)"; fo="$vd/findings.tsv"
    SCAN_ENV=("VENDOR_CHECK_FINDINGS_OUT=$fo")
    out="$(scan "$1" "$R_PLANT" "$vd" --rev "$PLANT_B" --fast)"; rc="$(exit_of "$out")"
    SCAN_ENV=()
    if [ "$rc" != 1 ]; then printf -- '--rev B --fast exited %s, expected 1\n' "$rc"; show "$out" "$vd"; return 1; fi
    t_contains "$out" 'BLOCKED' || { printf 'no BLOCKED line\n'; show "$out" "$vd"; return 1; }
    t_contains "$out" 'ip/core.v:2' || { printf 'the terse report does not name ip/core.v:2\n'; show "$out" "$vd"; return 1; }
    [ -f "$fo" ] || { printf 'VENDOR_CHECK_FINDINGS_OUT was not written\n'; return 1; }
    awk -F'\t' '$1 == "ipenc" && $2 == "ip/core.v" && $3 == "2" { f = 1 } END { exit !f }' "$fo" && return 0
    printf 'the findings channel does not carry "ipenc <TAB> ip/core.v <TAB> 2"; it holds:\n%s\n' "$(cat "$fo")"
    return 1
}
t_check vendor.fast.channel \
    "--rev B --fast: BLOCKED, ip/core.v:2 in the terse report, and the same finding as data in VENDOR_CHECK_FINDINGS_OUT" \
    fast_findings_channel "$FLOW_DIR"

M="$(t_mutant "$SB" fast-empty-channel)"
if t_replace_line "$M" "$CHK_REL" \
       '        cp "$SCRATCH/fast.tsv" "$VENDOR_CHECK_FINDINGS_OUT" 2>/dev/null || true' \
       '        : > "$VENDOR_CHECK_FINDINGS_OUT"'; then
    t_proof vendor.fast.channel.mutation \
        "with the findings channel written empty, the hook would record a bypass naming nothing and the assertion goes red" \
        fast_findings_channel "$M"
else
    t_skip vendor.fast.channel.mutation "could not plant the fault: the cp of fast.tsv to VENDOR_CHECK_FINDINGS_OUT in $CHK_REL has changed shape"
fi

## fast_silent_clean <toolkit>
## Silence, AND a corpus row - so "printed nothing" is distinguishable from
## "did nothing".
fast_silent_clean() {
    local vd out rc body
    vd="$(vd_new)"; out="$(scan "$1" "$R_PLANT" "$vd" --rev "$PLANT_A" --fast)"; rc="$(exit_of "$out")"
    if [ "$rc" != 0 ]; then printf -- '--rev A --fast exited %s, expected 0\n' "$rc"; show "$out" "$vd"; return 1; fi
    body="$(printf '%s\n' "$out" | grep -v '^EXIT=')"
    if [ -n "${body//[$' \t\n']/}" ]; then printf 'a clean --fast run printed something:\n%s\n' "$body"; return 1; fi
    has_row "$vd" PASS vendor.corpus.rev || { printf 'silent, but no PASS vendor.corpus.rev row - nothing says a tree was read\n'; show "$out" "$vd"; return 1; }
    return 0
}
t_check vendor.fast.silent \
    "--rev A --fast: exit 0, NOTHING printed, and a PASS vendor.corpus.rev row proving a tree was read" \
    fast_silent_clean "$FLOW_DIR"

M="$(t_mutant "$SB" fast-chatty)"
if t_replace_line "$M" "$CHK_REL" \
       '    ci_exit() { [ "$CI_FAIL" -gt 0 ] && return 1; return 0; }' \
       '    ci_exit() { printf "vendor: clean\n"; [ "$CI_FAIL" -gt 0 ] && return 1; return 0; }'; then
    t_proof vendor.fast.silent.mutation \
        "with a tick printed on every clean run, the assertion goes red" \
        fast_silent_clean "$M"
else
    t_skip vendor.fast.silent.mutation "could not plant the fault: the --fast ci_exit override in $CHK_REL has changed shape"
fi

#=============================================================================
# 9. A FILE THE SCANNER COULD NOT READ
#
# The property the brief asks for: a file it could not open is reported as
# unscanned, and the run is NOT clean. What was measured is in two halves.
#
# THE HALF THAT WORKS: when the unreadable file is ALONE in its size batch,
# `wc` prints nothing for it, the size table has no entry, and the checker
# reports "this file could not be measured, so the size rule did not run on
# it" and exits 1. Asserted, with a proof that removes the report.
#
# THE HALF THAT DOES NOT, carried as KNOWN-DEFECT markers (measured
# 2026-09-17, gawk 4.2.1):
#   - the content scan is one awk process per batch of 400 files, its stderr
#     and exit status discarded. gawk treats an unreadable operand as FATAL,
#     so every file that sorts AFTER the unreadable one in its batch is never
#     read. Nothing says so; the census still reports them as "read for
#     content"; the run exits 0. A mode-000 README hides a core.
#   - the size pass associates `wc -c` output lines with its argument list BY
#     POSITION, and wc emits no line for a file it cannot open. Every file
#     after it is credited with its neighbour's size and the last one with the
#     batch total - so the file that is actually over the limit is missed and
#     two innocent files are named. The "could not be measured" report above
#     cannot fire, because the table has an entry for the unreadable file: the
#     wrong one.
# Neither half is reachable through --staged (blobs are materialised from the
# index) or --rev (an archive is extracted); both are reachable through the
# default worktree scan CI runs and through --untracked-only, which the
# pre-push hook runs. The markers go RED when either is fixed.
#=============================================================================
t_head "unreadable file - said when it can be, and the KNOWN DEFECTS where it cannot"

if [ "$MODE_BITES" != 1 ]; then
    _why="mode 000 does not stop uid $(id -u) on $SB, so an 'unreadable' fixture is a readable one and nothing below would measure what it claims"
    t_skip vendor.unreadable.single "$_why"
    t_skip vendor.unreadable.single.mutation "not attempted: its assertion was skipped because $_why"
    t_skip vendor.unreadable.named "$_why"
    t_skip vendor.unreadable.neighbour "$_why"
    t_skip vendor.unreadable.size "$_why"
else
    ## single_unreadable_said <toolkit>
    ## --untracked-only --fast (the push hook's shape) over ONE untracked,
    ## unreadable file: exit 1, and the file named as not measured.
    single_unreadable_said() {
        local vd out rc
        vd="$(vd_new)"; out="$(scan "$1" "$R_LOCK1" "$vd" --untracked-only --fast)"; rc="$(exit_of "$out")"
        if [ "$rc" != 1 ]; then printf 'one unreadable untracked file exited %s, expected 1\n' "$rc"; show "$out" "$vd"; return 1; fi
        has_row "$vd" FAIL vendor.file.size || { printf 'no FAIL vendor.file.size row\n'; show "$out" "$vd"; return 1; }
        t_matches "$out" 'scratch/core\.v .*could not be measured' && return 0
        printf 'scratch/core.v is not reported as not measured\n'; show "$out" "$vd"; return 1
    }
    t_check vendor.unreadable.single \
        "one unreadable untracked file, alone in its batch: exit 1 and 'could not be measured' naming it" \
        single_unreadable_said "$FLOW_DIR"

    M="$(t_mutant "$SB" unreadable-unsaid)"
    if t_replace_line "$M" "$CHK_REL" \
           "        printf 'file.size\\t%s\\t0\\tthis file could not be measured, so the size rule did not run on it\\n' \\" \
           '        : \'; then
        t_proof vendor.unreadable.single.mutation \
            "with the 'could not be measured' report removed, the file is skipped in silence and the assertion goes red" \
            single_unreadable_said "$M"
    else
        t_skip vendor.unreadable.single.mutation "could not plant the fault: the 'could not be measured' printf in $CHK_REL has changed shape"
    fi

    ## unreadable_named <toolkit> - aa/readme.md (mode 000) is named, and the
    ## run does not exit 0.
    unreadable_named() {
        local vd out rc
        vd="$(vd_new)"; out="$(scan "$1" "$R_LOCK2" "$vd")"; rc="$(exit_of "$out")"
        if [ "$rc" = 0 ]; then printf 'a tree with an unreadable tracked file exited 0\n'; show "$out" "$vd"; return 1; fi
        t_contains "$out" 'aa/readme.md' && return 0
        printf 'the unreadable aa/readme.md is not named anywhere\n'; show "$out" "$vd"; return 1
    }
    t_known_defect vendor.unreadable.named \
        "an unreadable tracked file is named as unscanned and the run is not clean (today: unnamed, exit 0, census says 'read')" \
        unreadable_named "$FLOW_DIR"

    ## unreadable_neighbour <toolkit> - zz/core.v, readable, carrying the
    ## directive, sorted after the unreadable file: still found.
    unreadable_neighbour() {
        local vd out rc
        vd="$(vd_new)"; out="$(scan "$1" "$R_LOCK2" "$vd")"; rc="$(exit_of "$out")"
        if [ "$rc" != 1 ]; then printf 'the core beside an unreadable file: exit %s, expected 1\n' "$rc"; show "$out" "$vd"; return 1; fi
        has_row "$vd" FAIL vendor.tracked.ipenc || { printf 'no FAIL vendor.tracked.ipenc row - the core was not read\n'; show "$out" "$vd"; return 1; }
        t_contains "$out" 'zz/core.v:2' && return 0
        printf 'zz/core.v:2 is not named\n'; show "$out" "$vd"; return 1
    }
    t_known_defect vendor.unreadable.neighbour \
        "a readable core that sorts after an unreadable file is still found (today: awk aborts the batch, exit 0)" \
        unreadable_neighbour "$FLOW_DIR"

    ## unreadable_size <toolkit> - data/big.csv is the one file over the limit.
    ## file.size must name IT, and not the small zz/core.v beside it.
    unreadable_size() {
        local vd out rc
        vd="$(vd_new)"; out="$(scan "$1" "$R_LOCK3" "$vd" --fast)"; rc="$(exit_of "$out")"
        if [ "$rc" != 1 ]; then printf 'r-lock3 exited %s, expected 1 (one file is over the limit)\n' "$rc"; show "$out" "$vd"; return 1; fi
        t_matches "$out" 'data/big\.csv +file\.size' || { printf 'data/big.csv, the file over the limit, is not named under file.size\n'; show "$out" "$vd"; return 1; }
        if t_matches "$out" 'zz/core\.v +file\.size'; then printf 'zz/core.v, which is 40 bytes, is named under file.size - a neighbour'"'"'s size\n'; show "$out" "$vd"; return 1; fi
        return 0
    }
    t_known_defect vendor.unreadable.size \
        "with an unreadable file in the batch, file.size names the file that is over the limit and not its neighbour (today: sizes shift by one)" \
        unreadable_size "$FLOW_DIR"
fi

#=============================================================================
# 10. A DOTFILE IS A DATA FILE - KNOWN DEFECT
#
# vc_is_text_path admits every extensionless file, on the stated grounds that
# "LICENSE, CHANGELOG and every extensionless DATA file are read, and a data
# file is the likelier of the two to be a dump of something". Its test for
# "has an extension" is the glob `*.*`, which `.envrc`, `.gitmodules` and
# `.bashrc` all match - so a dotfile is treated as having the extension
# "envrc" and is never read. A dotfile is exactly where a licence-server
# export lands. Measured 2026-09-17; the marker goes red when the corpus
# admits it.
#=============================================================================
t_head "dotfiles - a data file whose name starts with a dot is in the text corpus (KNOWN DEFECT)"

## dotfile_scanned <toolkit>
dotfile_scanned() {
    local vd out rc
    vd="$(vd_new)"; out="$(scan "$1" "$R_DOT" "$vd" --fast)"; rc="$(exit_of "$out")"
    if [ "$rc" != 1 ]; then printf 'a tracked .envrc with a licence-server line exited %s, expected 1\n' "$rc"; show "$out" "$vd"; return 1; fi
    t_matches "$out" '\.envrc:1 +licence' && return 0
    printf '.envrc:1 is not named under the licence rule\n'; show "$out" "$vd"; return 1
}
t_known_defect vendor.corpus.dotfile \
    "a tracked .envrc carrying a port-at-host licence line is found (today: '*.*' treats the dotfile as having an extension and it is never read)" \
    dotfile_scanned "$FLOW_DIR"

#=============================================================================
# 11. THE FIXTURES SURVIVED THE RUN
#
# Last, because it is the assertion that decides what everything above was
# worth. Every green line in this file is a statement about a scanner reading
# a repository; if the repository stopped existing part-way through, the lines
# after that point are statements about nothing. This suite has seen exactly
# that (see t_proof's header), so the condition is asserted rather than
# assumed, at the end, where it covers the whole run.
#=============================================================================
t_head "the fixtures survived the run"

t_check vendor.fixtures.intact \
    "every fixture repository built at the top is still on disk, so every assertion above measured a real corpus" \
    fixtures_intact

## fixtures_intact_with <extra path> - the same check over the list plus one
## more entry, restoring the list afterwards. The proof below needs the check
## to be given something that is not there WITHOUT disturbing the fixtures the
## other proofs are still standing on.
fixtures_intact_with() {
    local extra="$1" rc=0
    local save=("${FIXTURES[@]}")
    FIXTURES+=("$extra")
    fixtures_intact || rc=$?
    FIXTURES=("${save[@]}")
    return $rc
}
t_proof vendor.fixtures.intact.mutation \
    "with a repository in the list that is not on disk, the integrity check goes red - so a green line above is not its default answer" \
    fixtures_intact_with "$SB/r-this-was-never-built"

# Unlock what was locked, so the sandbox's own removal never depends on it.
chmod 644 "$R_LOCK1/scratch/core.v" "$R_LOCK2/aa/readme.md" "$R_LOCK3/aa/readme.md" 2>/dev/null

t_summary
