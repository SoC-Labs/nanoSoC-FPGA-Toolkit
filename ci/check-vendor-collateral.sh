#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# ci/check-vendor-collateral.sh - keep AMD/XILINX COLLATERAL out of a repository
# that is about to be published
#
#   ci/check-vendor-collateral.sh                 scan the tracked tree AND the
#                                                 untracked-not-ignored files one
#                                                 `git add -A` would publish
#   ci/check-vendor-collateral.sh --staged        scan the INDEX - the content
#                                                 `git commit` is about to write
#   ci/check-vendor-collateral.sh --rev <commit>  scan the tree AT <commit> - what
#                                                 pushing that ref would publish
#   ci/check-vendor-collateral.sh --since <commit>  --rev only: the commit the push
#                                                 is measured AGAINST
#   ci/check-vendor-collateral.sh --new-lines-only  charge the change for the lines
#                                                 it ADDS, not the files it touches
#   ci/check-vendor-collateral.sh --untracked-only  ONLY the untracked-not-ignored
#                                                 files
#   ci/check-vendor-collateral.sh --no-untracked  tracked files only
#   ci/check-vendor-collateral.sh --fast          terse, silent when clean. The
#                                                 mode the GIT hooks run in
#   ci/check-vendor-collateral.sh --arm-only      prove every rule fires on its own
#                                                 specimen and stays silent on its
#                                                 counter-specimen. Scans nothing
#   ci/check-vendor-collateral.sh --list          print the allowlist and exit
#
# Exit: 0 clean, 1 found collateral, 2 refused or could not measure. It launches
# no tool, reads no licence, and opens nothing under a vendor install.
#
#-----------------------------------------------------------------------------
# THIS IS THE SCANNER BEHIND THE **GIT HOOKS**, NOT A FLOW HOOK. Two unrelated
# things in this toolkit are called hooks and only one of them is this:
#
#   FLOW HOOK   $(HOOKS_DIR)/<seam>.tcl, project Tcl sourced by a build stage at
#               a seam named in flow/common/seams.txt. Runs during a build,
#               affects the bitstream. Nothing here is one.
#   GIT HOOK    hooks/pre-commit and friends, run by git, which call THIS FILE.
#               Runs when you type a git command, affects no build ever.
#
# WHY THIS EXISTS
#
# README.md's "What this toolkit does not do" ends: *it ships no vendor
# collateral - no encrypted IP, no board files, no bitstreams, no .dcp*. That is
# a claim about every future commit, made by a repository that is going public,
# and until this file existed nothing measured it. A promise with no check
# behind it is a promise about the day somebody is in a hurry.
#
# THE FAILURE MODE THIS IS SHAPED AROUND is not "nobody wrote a check". It is
# "somebody wrote a check that could not fail". The reference ASIC toolkit
# inherited exactly that: a guard which iterated `git ls-files -- '*.lef'` over a
# tree that tracked no .lef, matched nothing, and printed OK - for months, while
# the categories that were ACTUALLY breached sat one glob away. A guard whose
# corpus can be empty is a green light with no bulb.
#
# So this file does two things before it is entitled to report anything:
#
#   SECTION 1 ARMS EVERY RULE. Each rule in the table below carries its own
#   INVENTED specimen, which it must match, and a near-miss COUNTER-SPECIMEN,
#   which no rule may match. A pattern that has rotted - somebody edited it, awk
#   on this runner reads an interval expression differently, a variable went
#   unset - fails HERE, loudly, instead of contributing a silent zero to a green
#   total. A rule that has stopped matching reports zero findings over a tree
#   full of them, and the only symptom is silence.
#
#   SECTION 2 CENSUSES THE CORPUS. Zero files scanned is UNVERIFIED and exits 2.
#   It is never OK. "We looked at nothing and found nothing" is the best possible
#   result produced from no measurement at all, which is the sentence CONTRACT.md
#   §0 rule two exists to forbid.
#
# WHAT COUNTS AS COLLATERAL HERE, AND WHY THE FPGA LIST IS NOT THE ASIC LIST
#
# The reference toolkit hunts foundry data: LEF dimensions, Liberty tables, layer
# maps. None of that is what an FPGA flow is handed. What arrives here instead:
#
#   1. ENCRYPTED IP. An AMD/Xilinx core delivered as `pragma protect` blocks, or
#      as a .edn/.edf netlist. The envelope is not a licence to redistribute it:
#      it is a licence to USE it, on a machine whose Vivado holds the key. A
#      committed protected file is redistribution with an extra step.
#   2. CATALOGUE CUSTOMISATIONS. .xci/.xcix. They are generated from the vendor's
#      IP catalogue, they are version-locked to the tool that made them, and they
#      are the vendor's expression of the vendor's core.
#   3. BOARD FILES. board.xml, part0_pins.xml, preset.xml, board_files/. These
#      are the board vendor's, they describe hardware this repository does not
#      own, and CONTRACT.md §11.8 forbids naming a board here at all.
#   4. BUILD OUTPUT THAT IS ALSO A LARGE BINARY. .bit, .bin, .mcs, .dcp, .ltx.
#      A checkpoint carries the vendor's netlist database; a bitstream is the
#      compiled form of everything upstream of it. Neither is source, and a
#      source tree that carries them stops being reviewable in a diff.
#   5. HANDOFF ARCHIVES. .xsa/.hwh, which carry the block design and every IP in
#      it, and which README.md says this toolkit STOPS at.
#   6. SITE FACTS. An absolute path into a vendor install (/opt/Xilinx and its
#      family), a licence server, a captured licence table. Name the ENVIRONMENT
#      VARIABLE and let each site fill it in - which is the pattern the whole
#      toolkit is built on and the one VENDOR_COLLATERAL.md points at.
#   7. VENDOR TEXT. A EULA, a confidentiality header, a copyright block from a
#      file somebody licensed. Not ours to redistribute under Apache-2.0.
#
# THERE IS NO file.sha RULE, AND THE ABSENCE IS DELIBERATE. The reference keys
# two known vendor files by content digest. Doing that here would mean shipping
# the digest of a file this project does not have and may not lawfully obtain a
# copy of to hash - a table with no rows, a rule that cannot fire, and a line in
# the summary implying a check that is not happening. An unarmable rule is worse
# than an absent one, because only one of them is honest about its coverage.
#
# WHAT A CLEAN RESULT DOES NOT MEAN. It means no rule below matched. A core
# committed as plaintext RTL with its header stripped matches nothing here and is
# still a breach; so is a paraphrase of a vendor user guide. The rules catch what
# the mistake actually LOOKS LIKE, and the mistake is nearly always a file
# somebody did not realise was collateral.
#
# THE MODES, AND WHY THE HOOKS NEED MORE THAN ONE CORPUS
#
#   --staged  reads the INDEX. `git add core.edn && printf '' > core.edn` leaves
#             a clean working tree and a commit that publishes a netlist. The
#             working tree is what the developer sees; the index is what git is
#             about to write, and only one of those is being published.
#   --rev     reads the tree at a COMMIT. `git push origin work:main` publishes a
#             ref that may not be HEAD, and a file added in one commit of a pushed
#             range and deleted in the next is published by the push while
#             appearing in no working tree anywhere.
#   --fast    is about the HUMAN, not the corpus: the same rules, four lines of
#             output, and SILENCE when clean. A hook that prints on every commit
#             is a hook whose output stops being read, and the run it stops being
#             read on is the one that said something different.
#
# THE RULES DO NOT CHANGE BETWEEN MODES. A hook with its own private pattern list
# drifts from the CI gate, and two guards that disagree about the same file are
# worse than one - the disagreement teaches everybody that a red hook is noise.
#
# --new-lines-only, AND WHAT IT REPAIRS
#
# A whole-file verdict on a changed file charges this commit for every line the
# other 399 already carried. On a repository with any backlog that is not a
# strict gate, it is an UNPASSABLE one, and an unpassable gate is spent through
# its own escape hatch: the bypass becomes routine and the bypass log stops being
# a record of exceptions. So this flag keeps the corpus and the rules exactly as
# they are and filters the FINDINGS to lines the change ADDS. A file-shaped
# finding has no line to be new and is NOT filtered, so `git add core.edn` still
# fails at the commit. Copying a line is an added line and fails. Moving a file
# re-adds every line and fails.
#
# NO BACKSLASH APPEARS IN ANY PATTERN IN THE TABLE BELOW, and that is a rule
# about portability rather than taste. `\t` inside a bracket expression is a gawk
# extension; POSIX leaves it undefined, and on a runner with mawk it silently
# means "the letters backslash and t". A pattern that quietly stops matching on
# somebody else's CI is the exact defect this file exists to prevent, one level
# down. POSIX classes - [[:space:]], [[:blank:]] - and bracketed literals - [(]
# for a paren - mean the same thing everywhere.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOW_DIR="$(cd "$HERE/.." && pwd)"
# shellcheck source=ci/lib.sh
. "$HERE/lib.sh"

usage() { sed -n '3,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

#-----------------------------------------------------------------------------
# OPTIONS. CORPUS is `worktree` (the CI default), `staged`, `rev` or `untracked`;
# exactly one, and a second is an ERROR rather than a silent last-wins. "--staged
# --rev abc" has no meaning, and honouring whichever came last is how a hook
# comes to scan the wrong thing while reporting that it scanned.
#-----------------------------------------------------------------------------
MODE_FAST=0
MODE_ARM_ONLY=0
MODE_LIST=0
MODE_UNTRACKED=1
MODE_NEWLINES=0
CORPUS=worktree
MODE_REV=""
MODE_SINCE=""
_want_rev=0
_want_since=0
for a in "$@"; do
    if [ "$_want_rev" = 1 ];   then MODE_REV="$a";   _want_rev=0;   continue; fi
    if [ "$_want_since" = 1 ]; then MODE_SINCE="$a"; _want_since=0; continue; fi
    case "$a" in
        --fast)     MODE_FAST=1 ;;
        --arm-only) MODE_ARM_ONLY=1 ;;
        --list)     MODE_LIST=1 ;;
        --no-untracked) MODE_UNTRACKED=0 ;;
        --new-lines-only) MODE_NEWLINES=1 ;;
        --staged)
            [ "$CORPUS" = worktree ] || { printf 'check-vendor-collateral: --staged conflicts with --%s\n' "$CORPUS" >&2; exit 2; }
            CORPUS=staged ;;
        --rev)
            [ "$CORPUS" = worktree ] || { printf 'check-vendor-collateral: --rev conflicts with --%s\n' "$CORPUS" >&2; exit 2; }
            CORPUS=rev; _want_rev=1 ;;
        --rev=*)
            [ "$CORPUS" = worktree ] || { printf 'check-vendor-collateral: --rev conflicts with --%s\n' "$CORPUS" >&2; exit 2; }
            CORPUS=rev; MODE_REV="${a#--rev=}" ;;
        --untracked-only)
            [ "$CORPUS" = worktree ] || { printf 'check-vendor-collateral: --untracked-only conflicts with --%s\n' "$CORPUS" >&2; exit 2; }
            CORPUS=untracked ;;
        --since)    _want_since=1 ;;
        --since=*)  MODE_SINCE="${a#--since=}" ;;
        -h|--help)  usage; exit 0 ;;
        *) printf 'check-vendor-collateral: unknown argument %s\n' "$a" >&2; usage >&2; exit 2 ;;
    esac
done
if [ "$_want_rev" = 1 ] || { [ "$CORPUS" = rev ] && [ -z "$MODE_REV" ]; }; then
    printf 'check-vendor-collateral: --rev needs a commit\n' >&2; exit 2
fi
if [ "$_want_since" = 1 ]; then
    printf 'check-vendor-collateral: --since needs a commit\n' >&2; exit 2
fi
# Refused rather than ignored, throughout. A flag that silently does nothing is
# how a narrowing gets believed in a mode that never applied it.
if [ -n "$MODE_SINCE" ] && [ "$CORPUS" != rev ]; then
    printf 'check-vendor-collateral: --since measures a --rev against a base (asked for --%s)\n' "$CORPUS" >&2; exit 2
fi
if [ -n "$MODE_SINCE" ] && [ "$MODE_NEWLINES" != 1 ]; then
    printf 'check-vendor-collateral: --since narrows nothing on its own - add --new-lines-only\n' >&2; exit 2
fi
if [ "$MODE_NEWLINES" = 1 ] && [ "$CORPUS" != staged ] \
   && { [ "$CORPUS" != rev ] || [ -z "$MODE_SINCE" ]; }; then
    printf 'check-vendor-collateral: --new-lines-only needs a base - use --staged, or --rev with --since <commit> (asked for --%s)\n' "$CORPUS" >&2; exit 2
fi

# Never truncate a caller's verdict file: ci/tier.sh owns $CI_VERDICT_DIR for a
# whole tier and this script is one subprocess in it, so it writes into a
# subdirectory of that - or into a temp directory when run by hand, so that a
# `./ci-verdicts` never appears in somebody's working tree because they ran a
# check.
_VC_TMP=""
if [ -n "${CI_VERDICT_DIR:-}" ]; then
    CI_VERDICT_DIR="$CI_VERDICT_DIR/vendor"
else
    _VC_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vendor-collateral.XXXXXX")" || exit 2
    CI_VERDICT_DIR="$_VC_TMP"
fi
# shellcheck disable=SC2034  # read by ci_init as ${CI_APPEND:-0}, in ci/lib.sh
CI_APPEND=0
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/vc-scan.XXXXXX")" || exit 2
cleanup() { rm -rf "$SCRATCH" "$_VC_TMP"; }
trap cleanup EXIT

ci_init

#=============================================================================
# --fast: THE SAME RULES, SAID IN FOUR LINES INSTEAD OF FORTY
#
# The PRINTERS are replaced, not the checks. Every ci_pass and ci_warn still
# runs, still increments its counter and still writes its row into verdicts.tsv,
# so the exit status and the machine-readable trail are byte-for-byte what the CI
# mode produces. What goes is the part a person cannot act on while their hand is
# still on the return key.
#=============================================================================
if [ "$MODE_FAST" = 1 ]; then
    ci_head() { :; }
    ci_say()  { :; }
    ci_pass() { CI_PASS=$((CI_PASS + 1)); _ci_record PASS "$1" "${*:2}"; }
    ci_warn() { CI_WARN=$((CI_WARN + 1)); _ci_record WARN "$1" "${*:2}"; }
    ci_skip() { CI_SKIP=$((CI_SKIP + 1)); _ci_record SKIP "$1" "${*:2}"; }
    ci_fail() { CI_FAIL=$((CI_FAIL + 1))
                printf '%s  %s%s  %s\n' "$_C_RED" "$1" "$_C_OFF" "${*:2}" >&2
                _ci_record FAIL "$1" "${*:2}"; }
    ci_unverified() { CI_FAIL=$((CI_FAIL + 1))
                printf '%s  %s%s  CANNOT VERIFY: %s\n' "$_C_RED" "$1" "$_C_OFF" "${*:2}" >&2
                _ci_record UNVERIFIED "$1" "${*:2}"; }
    ci_summary_table() { :; }
    ci_exit() { [ "$CI_FAIL" -gt 0 ] && return 1; return 0; }
fi

#=============================================================================
# THE RULE TABLE. IT IS DATA, AND IT IS HERE RATHER THAN INLINE IN THE LOGIC.
#
# Every pattern this script matches is one row below and nowhere else. Scattering
# regexes through the scanning code costs three things that matter more than the
# tidiness: a reviewer cannot see the whole policy on one screen, the arming
# block cannot enumerate what it is supposed to arm, and a rule can be added
# without a specimen - at which point the table grows a row that has never been
# observed to fire, which is indistinguishable from a row that cannot.
#
# So a row cannot be added without its own proof. `vc_text_rule` takes SEVEN
# fields and refuses on any other count:
#
#   <id>       what a finding is called. Stable; it is grepped and it is waived.
#   <case>     raw  - matched against the line as it is, for a literal that
#                     carries meaning in its own case
#              fold - matched against the case-folded line. awk's ~ is case
#                     sensitive, and an upper-case pattern table is a scanner
#                     that reads half a file.
#   <pattern>  POSIX ERE. NO BACKSLASHES - see the header.
#   <except>   a narrowing, or "". A line matching this does not fire the rule.
#              A NARROWING IS A RULE TOO: it is as easy to break, it breaks in
#              the direction that produces thousands of findings and a guard
#              somebody switches off, and so it is armed by the same block.
#   <specimen> an INVENTED line the rule MUST match.
#   <counter>  a near-miss line NO rule may match.
#   <why>      what the finding means, printed to the person who has to act.
#
# EVERY VALUE IN EVERY SPECIMEN IS INVENTED. 9999 / 7777 / SPECIMEN / INVENTED.
# A detector whose fixtures contained real vendor content would be the
# disclosure it exists to prevent, with a gate wrapped round it. The rules key on
# SHAPE, and shape is all a specimen needs.
#=============================================================================
VC_T_ID=(); VC_T_CASE=(); VC_T_PAT=(); VC_T_EXC=(); VC_T_SPEC=(); VC_T_CTR=(); VC_T_WHY=()
vc_text_rule() {
    if [ "$#" -ne 7 ]; then
        printf 'check-vendor-collateral: text rule "%s" was declared with %s fields, not 7 - a rule without a specimen and a counter-specimen cannot be armed\n' "${1:-?}" "$#" >&2
        exit 2
    fi
    VC_T_ID+=("$1"); VC_T_CASE+=("$2"); VC_T_PAT+=("$3"); VC_T_EXC+=("$4")
    VC_T_SPEC+=("$5"); VC_T_CTR+=("$6"); VC_T_WHY+=("$7")
}

# ONE ROW PER **FORM**, NOT PER CATEGORY, AND THE IDS REPEAT ON PURPOSE.
#
# This table was written the obvious way first - one row per category, with the
# forms as branches of one alternation - and a mutation proof took it apart. The
# ipenc pattern was rotted deliberately (`protect` -> `protekt`) and the arming
# block stayed GREEN, because the rule's specimen also carried `begin_protected`
# and the surviving branch matched it. Arming a rule ID is not arming a rule; a
# three-branch pattern with one dead branch goes on reporting its id forever,
# from the branches that still work, over a repository full of the shape the dead
# one was for.
#
# So each FORM is its own row with its own specimen, and rows share an id when
# they are the same finding to the reader. `ipenc` is three rows and one message.
# The arming block requires row N to fire at line N of the specimen file, so a
# rotted branch now costs a red run, which is what the proof asks for.

vc_text_rule ipenc fold \
    'pragma[[:space:]]+protect' '' \
    'SPECIMEN: `pragma protect  -- INVENTED directive, nothing after it' \
    'this toolkit protects nothing by copying it - a protected core stays at the vendor path it came from' \
    'an encrypted-IP envelope directive. The encryption licenses you to USE the core on a machine holding the key, not to redistribute it'

vc_text_rule ipenc fold \
    '(^|[^a-z0-9_])(begin|end)_protected([^a-z0-9_]|$)' '' \
    'SPECIMEN: begin_protected then end_protected -- INVENTED markers with nothing between them' \
    'a protected core does not become redistributable by being committed; leave it where the tool found it' \
    'the begin/end markers of an encrypted-IP block, which survive when the directive above is spelled some other way'

vc_text_rule ipenc fold \
    '(key|data)_(keyowner|keyname|method)[[:space:]]*=' '' \
    'SPECIMEN: key_keyowner = "SPECIMEN VENDOR", data_method = "invented-9999"' \
    'the key and the data stay on the machine that licensed them; point FPGA_IP_REPO at them instead' \
    'the key/data header of an encrypted-IP block - the part that names whose key opens it'

vc_text_rule edif fold \
    '[(]edif[[:space:]]+[a-z_]' '' \
    'SPECIMEN: (edif SPECIMENCORE -- INVENTED, no cells' \
    'an .edn is a netlist and this flow READS one from IP_REPO at build time - it never commits one' \
    'an EDIF netlist opener. This is the shape a delivered core keeps when its .edn is committed under some other name'

vc_text_rule edif fold \
    'edifversion|edif[[:space:]]*level' '' \
    'SPECIMEN: (edifVersion 9 9 9) (edifLevel 0) -- INVENTED' \
    'EDIF is a format and not a secret; what it usually CARRIES is somebody else s netlist' \
    'an EDIF header keyword - the same file when the opener has been reformatted away'

vc_text_rule xci fold \
    '"xci_name"|"core_container"' '' \
    'SPECIMEN: "xci_name": "specimen_core_9999", "core_container": ""' \
    'create_ip -vlnv <vendor>:ip:<name>:<version> is how a PROJECT asks the catalogue for one at build time' \
    'an IP-catalogue instance document (.xci). Generated from the vendor catalogue, locked to the tool version that made it, and the vendor expression of the vendor core'

vc_text_rule xci fold \
    '<spirit:component|<spirit:vendor>' '' \
    'SPECIMEN: <spirit:component> <spirit:vendor>specimen-vendor</spirit:vendor>' \
    'the packaging metadata a run PRODUCES is output; the Tcl that produces it is the source' \
    'the IP-XACT form of the same document, which is what an older catalogue writes and what a packaged core carries inside it'

vc_text_rule board fold \
    '<board[[:space:]][^>]*schema_version' '' \
    'SPECIMEN: <board schema_version="9.9" vendor="specimen" name="specimen9999">' \
    'BOARD and BOARD_DIR are the project side of the contract; nothing in this toolkit holds a board file' \
    'a board-file document. It describes hardware this repository does not own, and CONTRACT.md 11.8 forbids naming a board here at all'

vc_text_rule board fold \
    '<part0_pins|<board_part[[:space:]]' '' \
    'SPECIMEN: <part0_pins> <part0_pin index="9999" iostandard="INVENTED"/>' \
    'a part pack states silicon facts about a device; it never lists a board s connections' \
    'the pin map out of a board file - the half that is a wiring list for hardware somebody else designed'

vc_text_rule board fold \
    '<preset[[:space:]][^>]*preset_proj' '' \
    'SPECIMEN: <preset preset_proj="specimen9999"> -- INVENTED' \
    'presets belong to whoever shipped the board; a project board pack states its own facts instead' \
    'a board preset file - the vendor s pre-canned IP configuration for a board'

vc_text_rule eula fold \
    '(^|[^a-z0-9])(xilinx|amd)[^a-z0-9]{1,12}(inc[.,]|confidential|proprietary)' '' \
    'SPECIMEN: AMD Confidential -- INVENTED header, quoting no vendor text' \
    'Vivado comes from AMD and is not shipped here - name XILINX_VIVADO and let each site fill it in' \
    'a vendor name beside a confidentiality or ownership claim - the first line of a licensed file. Apache-2.0 on this repository grants nothing over it'

vc_text_rule eula fold \
    'confidential[[:space:]]+and[[:space:]]+proprietary' '' \
    'SPECIMEN VENDOR, Inc. -- Confidential and Proprietary -- INVENTED' \
    'anything carrying a Xilinx or AMD EULA or a Confidential header stays out of this repository' \
    'the standard confidentiality header, which survives when the vendor name has been edited off the line'

vc_text_rule eula fold \
    'end[ -]user[[:space:]]+licen[sc]e[[:space:]]+agreement' '' \
    'SPECIMEN: End User License Agreement -- INVENTED, quoting nobody' \
    'read your own licence agreement; this page deliberately reproduces nobody s' \
    'the text of a licence agreement. Whoever wrote it did not license you to republish it'

vc_text_rule eula fold \
    'this[[:space:]]+(file|core|design|ip)[[:space:]]+is[[:space:]]+(the[[:space:]]+)?(confidential|proprietary)' '' \
    'SPECIMEN: This file is proprietary to SPECIMEN VENDOR -- INVENTED' \
    'this file is the detector, and it is ours, and it is Apache-2.0' \
    'a file asserting in prose that it is somebody else s. Believe it'

vc_text_rule path fold \
    '/(apps|opt|tools|eda|usr/local)/xilinx([^a-z0-9]|$)' '' \
    'SPECIMEN: set specimen_root /opt/Xilinx/9999.9/specimen -- INVENTED site path' \
    'there is no default install root here - fpga-flow-doctor enumerates what is on THIS filesystem and names no path in the repository' \
    'an absolute path into a vendor install. It is a site fact, it is wrong on every other machine, and it states what this site holds'

vc_text_rule path fold \
    '/(apps|opt|tools|eda)/(vivado|vitis|petalinux)([^a-z0-9]|$)' '' \
    'SPECIMEN: source /tools/vivado/9999.9/specimen/settings -- INVENTED site path' \
    'name the variable instead - XILINX_VIVADO - and let each site fill it in' \
    'the same site fact under the tool s own name rather than the vendor s - the spelling a settings script usually has'

# THE ONE NARROWING IN THE TABLE, AND THE MEASUREMENT BEHIND IT.
#
# `port@host` is how a licence variable is DOCUMENTED, and this toolkit documents
# it: scripts/fpga-flow-doctor prints `27070@server` and `27070@a:27070@b` as the
# two shapes XILINXD_LICENSE_FILE accepts. Measured 2026-09-08 - those two lines
# are the only port@host in the entire repository, and without this narrowing the
# scanner's first run over its own toolkit would be red on the file that exists
# to teach people not to hardcode a server.
#
# A NARROWING IS A RULE TOO, so its counter-specimen IS that line, verbatim.
#
# WHAT IT GIVES UP, stated rather than discovered: the narrowing is LINE-shaped,
# so a real server sharing a line with a documented placeholder is missed. That
# is the safe direction to be wrong in only because the alternative - a rule
# somebody switches off - finds nothing at all.
vc_text_rule licence fold \
    '[0-9]{4,5}@[a-z0-9][a-z0-9._-]*' \
    'port@host|[0-9]{4,5}@(server|host|hostname|yourhost|your-host|a|b)([^a-z0-9._-]|$)' \
    'SPECIMEN: 9999@licsrv9999.invented-site.test -- INVENTED, resolves nowhere' \
    '27070@server              port@host          the SHAPE of the variable, not a site server' \
    'a licence-server host:port. A site fact, and a statement of what this site is entitled to run'

vc_text_rule licence fold \
    'users[[:space:]]+of[[:space:]]+[a-z0-9_]+:[[:space:]]*[(]total[[:space:]]+of[[:space:]]+[0-9]+[[:space:]]+licen' '' \
    'SPECIMEN: Users of specimen_feature:  (Total of 99 licenses issued; Total of 7 in use)' \
    'how many seats a site holds is a fact about the site; run the licence tool yourself and read your own' \
    'a captured licence-manager table. It states this site s entitlement and who was using it'

#-----------------------------------------------------------------------------
# THE PATH RULES. Same discipline, one row per category:
#
#   <id> <globs...> <specimens...> <counters...> <why>
#
# A GLOB AND A SPECIMEN PER GLOB, counts checked at arming time, because the
# reference toolkit's measured hole was inside a glob LIST: `gds` was there and
# `gds2` was not, so a real stream committed under the commoner of the two
# suffixes was invisible to the rule whose entire job was to notice a stream. An
# extension list with a hole in it is worse than no extension list, because it
# reports a number. Requiring one specimen per glob makes that hole cost a red
# arming block instead of a quiet zero.
#
# A glob is matched against the FULL REPOSITORY PATH and against the BASENAME, so
# `board.xml` catches it at any depth and `*/board_files/*` can speak about a
# directory. Binary content is never read by the text rules - a .bit has no lines
# - which is exactly why these rules need no content at all.
#-----------------------------------------------------------------------------
VC_P_ID=(); VC_P_GLOB=(); VC_P_SPEC=(); VC_P_CTR=(); VC_P_WHY=()
vc_path_rule() {
    if [ "$#" -ne 5 ]; then
        printf 'check-vendor-collateral: path rule "%s" was declared with %s fields, not 5\n' "${1:-?}" "$#" >&2
        exit 2
    fi
    VC_P_ID+=("$1"); VC_P_GLOB+=("$2"); VC_P_SPEC+=("$3"); VC_P_CTR+=("$4"); VC_P_WHY+=("$5")
}

vc_path_rule file.bitstream '*.bit *.bin *.mcs *.rbt' \
    'out/invented9999.bit out/invented9999.bin out/invented9999.mcs out/invented9999.rbt' \
    'docs/what-a-bitstream-is.md flow/steps/write_bitstream.tcl' \
    'a bitstream. Build OUTPUT, not source: it is the compiled form of every input above it, it is unreviewable in a diff, and it belongs in a release rather than in a tree'

vc_path_rule file.checkpoint '*.dcp' \
    'out/invented9999.dcp' \
    'docs/checkpoints.md' \
    'a design checkpoint. It carries the vendor netlist database for every IP in the design, and it is the largest thing a flow writes'

vc_path_rule file.probes '*.ltx' \
    'out/invented9999.ltx' \
    'docs/debug-probes.md' \
    'a debug-probe file. It is emitted beside a bitstream, it is meaningless without it, and it is one of the pair that turns a source tree into an artefact store'

vc_path_rule file.handoff '*.xsa *.hwh *.hdf' \
    'out/invented9999.xsa out/invented9999.hwh out/invented9999.hdf' \
    'docs/handoff.md' \
    'a hardware handoff archive. It packages the block design and every IP in it, and README.md says this toolkit STOPS at the .xsa - the consumer has its own lifecycle and its own repository'

vc_path_rule file.ipcatalog '*.xci *.xcix' \
    'ip/invented9999.xci ip/invented9999.xcix' \
    'docs/ip-catalogue.md' \
    'a vendor IP-catalogue customisation. Generated by the tool from the vendor catalogue, and the vendor expression of the vendor core'

vc_path_rule file.netlist '*.edn *.edf *.edif' \
    'ip/invented9999.edn ip/invented9999.edf ip/invented9999.edif' \
    'docs/netlists.md' \
    'an EDIF netlist, which is how a delivered core arrives when it is not delivered as encrypted RTL'

vc_path_rule file.boardfile 'board.xml part0_pins.xml preset.xml *.bxml */board_files/*' \
    'some/dir/board.xml some/dir/part0_pins.xml some/dir/preset.xml some/dir/invented9999.bxml vendor/board_files/invented9999/anything.txt' \
    'templates/board.tcl.in board/README.md' \
    'a board file. It is the board vendor collateral Vivado reads to know a board exists; the project supplies a board PACK that names its own facts instead'

# Any tracked file this large is worth a human look whatever its extension - and
# every category above that this file cannot name by suffix is large. The biggest
# thing this toolkit legitimately carries is an 86 kB make fragment.
VC_SIZE_LIMIT=262144

#-----------------------------------------------------------------------------
# THE TEXT CORPUS - which files the value rules are allowed to READ.
#
# A file the corpus does not admit is a file no rule can fire on, so this list is
# as load-bearing as the patterns and is armed alongside them. The COLLATERAL
# EXTENSIONS ARE IN HERE TOO, deliberately: `file.ipcatalog` says a tracked .xci
# is collateral, and the text rules then ask what is actually IN it - so a
# fixture may exist and may not quietly acquire real vendor content.
#-----------------------------------------------------------------------------
VC_TEXT_GLOBS=('*.tcl' '*.tcl.in' '*.md' '*.sh' '*.py' '*.mk' '*.in' '*.txt'
               '*.rst' '*.yml' '*.yaml' '*.json' '*.xml' '*.xdc' '*.sdc'
               '*.v' '*.sv' '*.vh' '*.svh' '*.vhd' '*.vhdl' '*.f' '*.flist'
               '*.example' '*.conf' '*.cfg' '*.csv' '*.log' '*.rpt' '*.template'
               '*.xci' '*.xcix' '*.edn' '*.edf' '*.edif' '*.bxml' '*.hwh' '*.xsa')

## vc_is_text_path <path> - true when the path is in the value-scan corpus.
## ONE definition, read by every mode. Two copies drift, and a rule enforced in
## one mode and not another is the same defect as a rule that is not enforced at
## all, only harder to notice.
vc_is_text_path() {
    local base="${1##*/}" g
    for g in "${VC_TEXT_GLOBS[@]}"; do
        # shellcheck disable=SC2254
        case "$base" in $g) return 0 ;; esac
    done
    # Extensionless, all of them - not just the ones with a shebang. LICENSE,
    # CHANGELOG and every extensionless DATA file are read, and a data file is
    # the likelier of the two to be a dump of something. Binary content is
    # filtered at read time, not here.
    case "$base" in *.*) return 1 ;; esac
    return 0
}

## vc_is_binary <path> - true when the first 4 kB holds a NUL byte.
## Feeding a .bit to awk produces line numbers against a file that has no lines.
## A binary that IS collateral is caught by a path rule, which needs no content,
## so nothing is lost by declining to read it - but the census COUNTS it, because
## "we did not read this one" is the sentence this script exists to make
## impossible to leave out.
vc_is_binary() {
    local n_nul
    n_nul=$(head -c 4096 "$1" 2>/dev/null | LC_ALL=C tr -dc '\000' | wc -c | tr -d ' ')
    [ "${n_nul:-0}" -gt 0 ]
}

#=============================================================================
# THE ALLOWLIST
#
# A waiver is a standing permission for a named path to hold what a named rule
# finds. Four fields: <path glob>|<rules>|<why>|<owner>. It is checked for
# structure on every run, in every mode, and a malformed table STOPS the run:
# the string is double-quoted, so a backtick or a $ in any field is expanded when
# it is assigned and what every waiver decision is then made against is the
# RESULT. That is harmless in a reason and total in the first field, where an
# expansion leaving a glob reading `*` waives its rules over the whole
# repository - a silent, complete hole produced by a typo in a comment.
#=============================================================================
VC_ALLOW="\
ci/check-vendor-collateral.sh|ipenc,edif,xci,board,eula,path,licence|THIS FILE IS THE DETECTOR. Every rule above carries its own INVENTED specimen and its own counter-specimen as table data, which is the only way the arming block can prove the rule fires. A scanner that fails on its own fixtures is a scanner nobody can run. Nothing in those specimens came from a vendor file.|toolkit maintainers
scripts/fpga-flow-hooks|ipenc|the GIT-hook installer's selftest plants an INVENTED encrypted-IP envelope in a THROWAWAY repository and requires the installed hook to refuse the commit. Three words of syntax, no vendor payload, and the specimen never touches the repository being protected.|toolkit maintainers
hooks/pre-push|ipenc|names the envelope keyword in a comment explaining what the push-time scan is looking for. A comment that cannot name the thing it is about is a comment nobody can act on.|toolkit maintainers
test/shell/t_package_ip.sh|xci|the package-ip suite's own fixture WRITES a synthetic IP-XACT component.xml - it invents the vendor, library, name and version elements line by line - so that the stage under test has a core to read. The xci rule fires on those markers, which is correct behaviour on a document that is the TEST's and not a vendor's. Measured: the two findings are at :382-383, both inside the stub_core writer. A suite that cannot build the artefact its stage consumes is a suite nobody can run.|toolkit maintainers
VENDOR_COLLATERAL.md|ipenc,eula,path|THE POLICY PAGE MUST NAME THE SHAPES IT FORBIDS. A page saying 'do not commit an encrypted-IP envelope, and do not hardcode an install root' without showing what either looks like leaves the reader to guess, and the guess is what this whole layer exists to remove. Measured: the path rule fires on :46, which is the bullet telling people not to write that path.|toolkit maintainers
"

VC_KNOWN_RULES=""
vc_known_rules() {
    local i
    [ -n "$VC_KNOWN_RULES" ] && { printf '%s' "$VC_KNOWN_RULES"; return 0; }
    for i in "${!VC_T_ID[@]}"; do VC_KNOWN_RULES="$VC_KNOWN_RULES ${VC_T_ID[$i]}"; done
    for i in "${!VC_P_ID[@]}"; do VC_KNOWN_RULES="$VC_KNOWN_RULES ${VC_P_ID[$i]}"; done
    VC_KNOWN_RULES="$VC_KNOWN_RULES file.size"
    printf '%s' "$VC_KNOWN_RULES"
}

vc_print_allowlist() {
    ci_head "allowlist"
    if [ -z "${VC_ALLOW//[$' \t\n']/}" ]; then
        ci_say "(empty - nothing in this repository is permitted to hold vendor collateral)"
        return 0
    fi
    printf '%s' "$VC_ALLOW" | while IFS='|' read -r glob rules reason owner; do
        [ -n "$glob" ] || continue
        printf '   %-38s %s\n' "$glob" "[$rules]"
        printf '   %-38s owner: %s\n' "" "$owner"
        printf '   %-38s why:   %s\n' "" "$reason"
    done
}

## vc_allowed <path> <rule> - true when this path is exempted from this rule
vc_allowed() {
    local path="$1" rule="$2" glob rules reason owner
    while IFS='|' read -r glob rules reason owner; do
        [ -n "$glob" ] || continue
        # shellcheck disable=SC2254
        case "$path" in $glob) ;; *) continue ;; esac
        case ",$rules," in *",$rule,"*) return 0 ;; esac
    done <<< "$VC_ALLOW"
    return 1
}

#=============================================================================
# THE SCANNER. ONE awk program, driven by the table above through a file - so
# the arming block, the staged scan, the tree scan and the history of every
# future mode read the SAME rows. If a rule is edited it is edited for all of
# them, and the arming block notices if the edit stopped it matching.
#
# It emits one tab-separated record per finding:  rule <TAB> path <TAB> line
# <TAB> why - and it NEVER emits the offending text. A guard that prints what it
# found has copied it into a log, an artefact and a job summary.
#=============================================================================
VC_RULEFILE="$SCRATCH/rules.tsv"
: > "$VC_RULEFILE"
for _i in "${!VC_T_ID[@]}"; do
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "${VC_T_ID[$_i]}" "${VC_T_CASE[$_i]}" "${VC_T_PAT[$_i]}" "${VC_T_EXC[$_i]}" "${VC_T_WHY[$_i]}" \
        >> "$VC_RULEFILE"
done

VC_AWK='
BEGIN {
    nr = 0
    while ((getline line < RULES) > 0) {
        if (split(line, f, "\t") < 5) continue
        nr++
        rid[nr] = f[1]; rcase[nr] = f[2]; rpat[nr] = f[3]; rexc[nr] = f[4]; rwhy[nr] = f[5]
    }
    close(RULES)
}
FNR == 1 { name = (FORCENAME != "" ? FORCENAME : FILENAME) }
{
    L = $0; LC = tolower($0)
    for (i = 1; i <= nr; i++) {
        s = (rcase[i] == "fold") ? LC : L
        if (rexc[i] != "" && s ~ rexc[i]) continue
        if (s ~ rpat[i]) printf "%s\t%s\t%d\t%s\n", rid[i], name, FNR, rwhy[i]
    }
}
'
vc_scan() {
    local out="$1"; shift
    [ "$#" -gt 0 ] || { : > "$out"; return 0; }
    awk -v "RULES=$VC_RULEFILE" -v FORCENAME="" "$VC_AWK" "$@" > "$out" 2>/dev/null
}

## vc_path_hits <path> - every path rule this path trips, as `id<TAB>why`
##
## THE GLOB LIST IS SPLIT WITH GLOBBING OFF, and that is not defensive style, it
## is a bug this rule table had and the arming block found. `for g in
## ${VC_P_GLOB[$i]}` is an UNQUOTED expansion, so bash applies word splitting AND
## PATHNAME EXPANSION to it: run from a repository that actually contains a
## `board_files/` directory, the pattern `*/board_files/*` expanded into the list
## of files it matched on disk, the pattern itself ceased to exist, and the rule
## stopped matching anything else. Measured: file.boardfile armed green from the
## toolkit's own directory and went red the moment the specimen tree existed in
## the cwd - a rule that works everywhere except in the repositories it is for.
## `read -r -a` splits on whitespace and does NO pathname expansion, so the
## pattern stays a pattern. `case` patterns are never pathname-expanded either,
## so the match itself was always fine; it was the loop that was wrong. The
## arming block is what found it, from a cwd that happened to contain the
## specimen tree - which is the only reason this is a comment and not a hole.
vc_path_hits() {
    # SPLIT, and not `local p="$1" base="${p##*/}"`. `local` is a builtin, so its
    # arguments are expanded in the CALLER's scope before it runs - where `p` is
    # unset, and under `set -u` that is a fatal error on the very first call. It
    # reads as one assignment and is two.
    local p="$1" base i g globs
    base="${p##*/}"
    for i in "${!VC_P_ID[@]}"; do
        read -r -a globs <<< "${VC_P_GLOB[$i]}"
        for g in "${globs[@]}"; do
            # shellcheck disable=SC2254
            case "$p"    in $g) printf '%s\t%s\n' "${VC_P_ID[$i]}" "${VC_P_WHY[$i]}"; continue 2 ;; esac
            # shellcheck disable=SC2254
            case "$base" in $g) printf '%s\t%s\n' "${VC_P_ID[$i]}" "${VC_P_WHY[$i]}"; continue 2 ;; esac
        done
    done
}

## vc_refuse <gate> <why> - the one exit for "this run measured nothing"
##
## EXIT 2, NOT 1, and the difference is the contract. CONTRACT.md 10: 1 is a
## check that FAILED, 2 is refused or unusable input. "We found collateral" and
## "we could not look" are different sentences and hooks/lib-hook.sh acts on them
## differently - the first names files, the second says nothing has been checked.
## Merging them is how a guard that could not run comes to look like a guard that
## passed.
vc_refuse() {
    ci_unverified "$1" "$2"
    [ "$MODE_FAST" = 1 ] || vc_print_allowlist
    ci_exit vendor-collateral
    exit 2
}

#=============================================================================
# SECTION 1. ARM EVERY RULE.
#
# Each rule fires on its own invented specimen AND stays silent on its
# counter-specimen, before this script is entitled to say anything at all about a
# repository. This is the section that makes a vacuous pass structurally
# impossible.
#
# THE SPECIMEN FILE IS ONE LINE PER RULE, IN TABLE ORDER, and rule N is required
# to fire AT LINE N. "The rule id appeared somewhere in the output" is the weaker
# test and it is the one that hides a half-dead rule: a two-branch pattern whose
# second branch has rotted goes on reporting its id from the first branch
# forever. Line-keying costs nothing and asks the right question.
#=============================================================================
ci_head "arming - every rule fires on an invented specimen, and none fires on a near miss"

: > "$SCRATCH/specimen.txt"
for _i in "${!VC_T_ID[@]}"; do printf '%s\n' "${VC_T_SPEC[$_i]}" >> "$SCRATCH/specimen.txt"; done
vc_scan "$SCRATCH/arm.tsv" "$SCRATCH/specimen.txt"

unarmed=""
for _i in "${!VC_T_ID[@]}"; do
    _ln=$((_i + 1))
    awk -F'\t' -v r="${VC_T_ID[$_i]}" -v l="$_ln" \
        '$1 == r && $3 == l { found = 1 } END { exit !found }' "$SCRATCH/arm.tsv" \
        || unarmed="$unarmed ${VC_T_ID[$_i]}(row $_ln: $(printf '%.44s' "${VC_T_PAT[$_i]}"))"
done

# THE COUNTER-SPECIMENS, AND WHY THEY ARE HALF THE TABLE.
#
# A rule is broken in two directions and only one of them is loud. Over-matching
# produces a wall of findings, a guard somebody switches off, and a repository
# with no guard at all - which is why every near miss below is a line that a
# correct file in this toolkit actually contains, or would. Two of them are
# verbatim from fpga-flow-doctor and VENDOR_COLLATERAL.md: the pages that teach
# people not to hardcode a licence server and not to commit an encrypted core
# must be able to SAY so without the scanner refusing them.
: > "$SCRATCH/counter.txt"
for _i in "${!VC_T_ID[@]}"; do printf '%s\n' "${VC_T_CTR[$_i]}" >> "$SCRATCH/counter.txt"; done
cat >> "$SCRATCH/counter.txt" <<'COUNTER'
AMD/Xilinx encrypted IP, board files, bitstreams and .dcp are what this refuses
anything carrying a Xilinx or AMD EULA or a Confidential header
the flow writes build/<RUN_TAG>/<top>.bit and never asks anybody to commit it
set XILINX_VIVADO to your own install; this repository names no install root
COUNTER
vc_scan "$SCRATCH/counter.tsv" "$SCRATCH/counter.txt"
if [ -s "$SCRATCH/counter.tsv" ]; then
    unarmed="$unarmed narrowing(over-matches:$(cut -f1 "$SCRATCH/counter.tsv" | sort -u | tr '\n' ',' | sed 's/,$//'))"
fi

# THE PATH RULES, GLOB BY GLOB. Not rule by rule: one specimen per rule would
# arm the first glob in the list and leave every later one untested, which is the
# hole shape the header describes.
for _i in "${!VC_P_ID[@]}"; do
    read -r -a _globs <<< "${VC_P_GLOB[$_i]}"
    read -r -a _specs <<< "${VC_P_SPEC[$_i]}"
    if [ "${#_globs[@]}" -ne "${#_specs[@]}" ]; then
        unarmed="$unarmed ${VC_P_ID[$_i]}(${#_globs[@]} glob(s), ${#_specs[@]} specimen(s) - every glob needs its own)"
        continue
    fi
    for _j in "${!_globs[@]}"; do
        vc_path_hits "${_specs[$_j]}" | awk -F'\t' -v r="${VC_P_ID[$_i]}" \
            '$1 == r { found = 1 } END { exit !found }' \
            || unarmed="$unarmed ${VC_P_ID[$_i]}(${_globs[$_j]})"
    done
    read -r -a _ctrs <<< "${VC_P_CTR[$_i]}"
    for _j in "${!_ctrs[@]}"; do
        _hit="$(vc_path_hits "${_ctrs[$_j]}")"
        [ -z "$_hit" ] || unarmed="$unarmed ${VC_P_ID[$_i]}(over-matches ${_ctrs[$_j]})"
    done
done

# THE TEXT CORPUS IS A RULE. A file the corpus does not admit is a file no rule
# can fire on. Named one by one, because "the glob list is non-empty" is the test
# that was already passing when the hole was open.
for _p in specimen.tcl specimen.md specimen.v specimen.xdc specimen.xci specimen.edn \
          specimen.xml specimen.json specimen.mk specimen.in EXTENSIONLESS_DATA; do
    vc_is_text_path "some/dir/$_p" || unarmed="$unarmed corpus($_p)"
done
# ...and it must still refuse what it never reads. A corpus that admits
# everything is not a corpus, and a text rule reporting line 4,100,000 of a .bit
# is a finding nobody can act on.
for _p in specimen.png specimen.o specimen.tar.gz specimen.dcp specimen.bit; do
    vc_is_text_path "some/dir/$_p" && unarmed="$unarmed corpus($_p over-matches)"
done

# file.size, BOTH WAYS, over invented sizes. One-sided would pass with the
# threshold unset - `[ "" -gt "" ]` is an error, not a match - and an unset
# threshold is the shape that makes this rule silently never fire.
[ -n "${VC_SIZE_LIMIT:-}" ] && [ "$((VC_SIZE_LIMIT + 1))" -gt "$VC_SIZE_LIMIT" ] \
    || unarmed="$unarmed file.size"
[ "$((VC_SIZE_LIMIT - 1))" -gt "$VC_SIZE_LIMIT" ] \
    && unarmed="$unarmed file.size(over-matches)"

#-----------------------------------------------------------------------------
# AND THE ALLOWLIST MUST BE WELL FORMED. See the table's header for why a
# malformed entry is a hole rather than a mess.
#-----------------------------------------------------------------------------
malformed=""
_n_allow=0
while IFS='|' read -r _g _r _why _own _extra; do
    [ -n "${_g//[$' \t']/}" ] || continue
    _n_allow=$((_n_allow + 1))
    [ -n "$_extra" ] && malformed="$malformed
    entry $_n_allow ($_g): more than four |-separated fields - a stray | in the reason truncates the owner"
    [ -n "${_r//[$' \t']/}" ] || malformed="$malformed
    entry $_n_allow ($_g): waives no rule - either a typo or a subtraction somebody did not finish"
    [ -n "${_own//[$' \t']/}" ] || malformed="$malformed
    entry $_n_allow ($_g): no owner - a waiver nobody owns is a waiver nobody prunes"
    [ "${#_why}" -lt 20 ] && malformed="$malformed
    entry $_n_allow ($_g): the reason is ${#_why} characters. This is a standing permission to hold vendor collateral at a path; it needs a justification a reviewer can disagree with"
    case "${_g//[$' \t']/}" in
        '*'|'*/*'|'/*') malformed="$malformed
    entry $_n_allow: the path glob is '$_g', which matches the ENTIRE repository. No waiver is that broad on purpose" ;;
    esac
    while IFS= read -r _rule; do
        [ -n "${_rule//[$' \t']/}" ] || continue
        case " $(vc_known_rules) " in
            *" $_rule "*) ;;
            *) malformed="$malformed
    entry $_n_allow ($_g): waives '$_rule', which is not a rule this script has. A waiver for a rule that does not exist suppresses nothing and hides that it suppresses nothing" ;;
        esac
    done < <(printf '%s\n' "$_r" | tr ',' '\n')
done <<< "$VC_ALLOW"

if [ -n "$malformed" ]; then
    ci_say "The table is a double-quoted string: a backtick or a \$ in ANY field is"
    ci_say "expanded when it is assigned. Write reasons in plain prose."
    vc_refuse vendor.allowlist.malformed \
        "the allowlist is not well formed, so no waiver decision this run made can be trusted:$malformed"
fi

if [ -n "$unarmed" ]; then
    ci_say "A rule that cannot match its own invented specimen reports zero findings"
    ci_say "over a repository full of them, and the only symptom is silence. Fix the"
    ci_say "pattern before reading anything else this script says."
    vc_refuse vendor.arm "rule(s) that failed their own specimen or counter-specimen:$unarmed"
fi
# FORMS, and separately IDS. The number that matters is the number of ROWS -
# each is one pattern that had to fire - and the number people recognise is the
# number of finding names. Printing only the second would report 7 where 18 were
# proved, which is the arithmetic that let a rotted branch hide.
_n_tids=$(printf '%s\n' "${VC_T_ID[@]}" | sort -u | wc -l | tr -d ' ')
_n_pids=$(printf '%s\n' "${VC_P_ID[@]}" | sort -u | wc -l | tr -d ' ')
ci_pass vendor.arm \
    "${#VC_T_ID[@]} content rule form(s) under $_n_tids finding name(s), and ${#VC_P_ID[@]} path rule(s) under $_n_pids, each firing on its own invented specimen; none fires on a counter-specimen; the text corpus admits what it must and refuses what it must not; file.size answers both ways"

if [ "$MODE_ARM_ONLY" = 1 ]; then
    [ "$MODE_FAST" = 1 ] || vc_print_allowlist
    ci_exit vendor-collateral
    exit $?
fi
if [ "$MODE_LIST" = 1 ]; then
    vc_print_allowlist
    exit 0
fi

#=============================================================================
# SECTION 2. CENSUS THE CORPUS.
#
# The reference guard's failure in one line: it never asked how many files it had
# looked at. So before any verdict, count - and refuse if the count is zero.
#=============================================================================
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
    vc_refuse vendor.corpus "not inside a git work tree - there is no tracked-file list to scan"
fi
cd "$ROOT" || exit 2

ci_head "corpus - $ROOT"

VC_PREFIX=""
n_untracked=0
: > "$SCRATCH/untracked.txt"
: > "$SCRATCH/tracked.txt"

## vc_materialise - write the blobs named on stdin under $SCRATCH/corpus
##
## `--staged` and `--rev` name content that may exist NOWHERE on disk. Every
## finding is still reported under its REPOSITORY path: a committer told to look
## at /tmp/vc-scan.a1b2/corpus/flow/steps/synth.tcl has been told nothing.
vc_materialise() {
    local mode sha status path dest
    mkdir -p "$SCRATCH/corpus" || return 1
    while IFS=$'\t' read -r mode sha status path; do
        [ -n "$path" ] || continue
        case "$status" in D) continue ;; esac
        # 120000 is a symlink and 160000 a submodule gitlink. Neither has file
        # content in this repository - the gitlink's "blob" is a commit id in
        # another one - and `git cat-file blob` on it fails, which would be
        # indistinguishable from a corpus we could not read.
        case "$mode" in 100644|100755) ;; *) continue ;; esac
        case "$sha" in *[!0-9a-f]*|"") continue ;; esac
        case "$sha" in 0000000000000000000000000000000000000000)
            ci_unverified vendor.corpus.unmerged \
                "$path is unmerged - there is no single staged blob to read, so this scan could not see what the commit would write. Resolve the conflict and try again"
            return 1 ;;
        esac
        dest="$SCRATCH/corpus/$path"
        mkdir -p "${dest%/*}" 2>/dev/null
        git cat-file blob "$sha" > "$dest" 2>/dev/null || {
            ci_unverified vendor.corpus.unreadable \
                "could not read the staged blob for $path - this scan did not see it"
            return 1
        }
        printf '%s\n' "$path"
    done
    return 0
}

## vc_addedlines <base> [<tip>] - `path<TAB>lineno`, one per line the change ADDS
##
## -U0 so a hunk header brackets added lines and nothing else; three lines of
## context would enrol six untouched neighbours per hunk and quietly restore most
## of the over-charging this narrowing exists to remove.
##
## --no-renames because with rename detection on, --raw puts two paths on one
## record and a parser takes the source as the destination - scanning the file
## that is going away instead of the one arriving.
##
## -c core.quotePath=false so a non-ASCII path arrives as itself rather than as
## octal escapes, which would never match the scan's path and would drop every
## finding in that file - a narrowing that fails OPEN, silently.
vc_addedlines() {
    git -c core.quotePath=false diff --unified=0 --no-renames --no-color \
            --diff-filter=ACMRTU "$@" 2>/dev/null \
        | awk '
            /^[+][+][+] / { p = substr($0, 7); if (p == "ev/null") p = ""; next }
            /^@@ /        { if (p == "") next
                            s = $0; sub(/^@@[^+]*[+]/, "", s); sub(/ .*$/, "", s)
                            n = index(s, ",")
                            if (n) { c = substr(s, 1, n - 1) + 0; d = substr(s, n + 1) + 0 }
                            else   { c = s + 0;                   d = 1 }
                            for (i = 0; i < d; i++) printf "%s\t%d\n", p, c + i }'
}

if [ "$CORPUS" = staged ]; then
    VC_PREFIX="$SCRATCH/corpus/"
    # The empty tree, so the FIRST commit in a repository - which has no HEAD to
    # diff against - is scanned rather than skipped. A fresh import plus `git add
    # -A` is not a special case worth being blind to.
    _against="$(git rev-parse --verify -q HEAD 2>/dev/null || true)"
    [ -n "$_against" ] || _against="$(git hash-object -t tree /dev/null 2>/dev/null)"
    [ -n "$_against" ] || vc_refuse vendor.corpus "could not resolve anything to diff the index against"
    if ! git diff --cached --raw --no-renames --abbrev=40 "$_against" 2>/dev/null \
        | awk -F'\t' '{ split($1, a, " "); printf "%s\t%s\t%s\t%s\n", a[2], a[4], a[5], $2 }' \
        > "$SCRATCH/staged.raw"; then
        vc_refuse vendor.corpus "git diff --cached failed - the index could not be read"
    fi
    vc_materialise < "$SCRATCH/staged.raw" > "$SCRATCH/tracked.txt" \
        || vc_refuse vendor.corpus "the index could not be materialised - nothing was scanned"
    if [ "$MODE_NEWLINES" = 1 ]; then
        : > "$SCRATCH/changedfiles.txt"
        # Fail CLOSED. An unreadable diff means the narrowing cannot be
        # justified, and the honest response is to charge the whole file rather
        # than let an unknown set of lines through unexamined.
        vc_addedlines "$_against" > "$SCRATCH/addedlines.tsv" || {
            ci_warn vendor.newlines.unavailable \
                "could not read the staged diff, so --new-lines-only was dropped and every changed file is scanned whole"
            MODE_NEWLINES=0
        }
    fi

elif [ "$CORPUS" = rev ]; then
    VC_PREFIX="$SCRATCH/corpus/"
    if ! _revsha="$(git rev-parse --verify -q "$MODE_REV^{commit}" 2>/dev/null)" || [ -z "$_revsha" ]; then
        vc_refuse vendor.corpus "$MODE_REV does not resolve to a commit in this repository - nothing was scanned"
    fi
    mkdir -p "$SCRATCH/corpus"
    # ONE process for the whole tree. ls-tree plus a cat-file per path is a
    # subprocess per file, and a pre-push hook that takes a minute is a pre-push
    # hook people disable.
    if ! git archive --format=tar "$_revsha" 2>/dev/null | tar -x -C "$SCRATCH/corpus" 2>/dev/null; then
        vc_refuse vendor.corpus "could not extract the tree at $MODE_REV - this scan measured nothing"
    fi
    git ls-tree -r --name-only "$_revsha" 2>/dev/null > "$SCRATCH/tracked.txt"
    if [ "$MODE_NEWLINES" = 1 ]; then
        if ! _sincesha="$(git rev-parse --verify -q "$MODE_SINCE^{commit}" 2>/dev/null)" || [ -z "$_sincesha" ]; then
            # NOT a warning. The caller asked for the push to be measured against
            # a base and the base does not exist here, so a narrowed verdict
            # would answer a question nobody asked.
            vc_refuse vendor.corpus \
                "--since $MODE_SINCE does not resolve to a commit here - what this push ADDS could not be established, so nothing was narrowed and nothing is claimed"
        fi
        _ok=1
        vc_addedlines "$_sincesha" "$_revsha" > "$SCRATCH/addedlines.tsv" || _ok=0
        # A CHANGED-FILE SET, which --staged does not need. Under --staged the
        # corpus IS the files the index changes. Under --rev the corpus is the
        # WHOLE tree, so keeping every line-0 finding would charge this push for
        # every collateral FILE the branch merely inherited - the entire defect
        # this narrowing exists to remove, surviving in the one shape the line
        # filter cannot see.
        git -c core.quotePath=false diff --name-only --no-renames --no-color \
            --diff-filter=ACMRTU "$_sincesha" "$_revsha" 2>/dev/null \
            > "$SCRATCH/changedfiles.txt" || _ok=0
        if [ "$_ok" = 0 ]; then
            ci_warn vendor.newlines.unavailable \
                "could not read the diff $MODE_SINCE..$MODE_REV, so --new-lines-only was dropped and the whole tree at $MODE_REV is charged"
            MODE_NEWLINES=0
        fi
    fi

elif [ "$CORPUS" = untracked ]; then
    # THE HALF OF THE WORKTREE CORPUS THAT --rev CANNOT COVER. hooks/pre-push
    # scans each pushed COMMIT, which is the tracked content being published.
    # What no commit can show is the file that is in NO commit: untracked,
    # non-ignored, one `git add -A` from being published.
    git ls-files --others --exclude-standard > "$SCRATCH/untracked.txt" 2>/dev/null
    n_untracked=$(wc -l < "$SCRATCH/untracked.txt" | tr -d ' ')
else
    git ls-files > "$SCRATCH/tracked.txt" 2>/dev/null
fi
n_tracked=$(wc -l < "$SCRATCH/tracked.txt" | tr -d ' ')

# UNTRACKED AND NOT IGNORED - what the next `git add -A` would publish. Only in
# the worktree corpus: that is a question about the FILESYSTEM, and --staged and
# --rev are questions about content git has already been handed. Folding them
# into a --staged run would block a commit over a file that commit does not
# contain, which is the fastest way to teach somebody the hook is wrong.
# `--exclude-standard` is what keeps this off a build tree: an ignored file is a
# decision somebody wrote down.
if [ "$CORPUS" = worktree ] && [ "$MODE_UNTRACKED" = 1 ]; then
    git ls-files --others --exclude-standard > "$SCRATCH/untracked.txt" 2>/dev/null
    n_untracked=$(wc -l < "$SCRATCH/untracked.txt" | tr -d ' ')
fi
cat "$SCRATCH/tracked.txt" "$SCRATCH/untracked.txt" > "$SCRATCH/scanlist.txt"

: > "$SCRATCH/textlist.txt"
: > "$SCRATCH/binlist.txt"
while IFS= read -r f; do
    [ -n "$f" ] || continue
    vc_is_text_path "$f" || continue
    # $_p is where the bytes are, $f is what a finding is reported under. Same
    # string in the worktree corpus, different in the other two, and every read
    # below must use the first and every message the second.
    _p="$VC_PREFIX$f"
    [ -f "$_p" ] || continue
    if vc_is_binary "$_p"; then printf '%s\n' "$f" >> "$SCRATCH/binlist.txt"
    else                        printf '%s\n' "$f" >> "$SCRATCH/textlist.txt"
    fi
done < "$SCRATCH/scanlist.txt"
sort -u "$SCRATCH/textlist.txt" -o "$SCRATCH/textlist.txt"
n_text=$(wc -l < "$SCRATCH/textlist.txt" | tr -d ' ')
n_bin=$(wc -l < "$SCRATCH/binlist.txt" | tr -d ' ')
# Rendered only when there IS one. `, 0 binary and judged by path alone` is a
# clause about nothing, and a census line people skim is a census line that
# stops being read on the run where the number is not zero.
_binnote=""
[ "${n_bin:-0}" -gt 0 ] && _binnote=", $n_bin binary and judged by path alone"

# THE TRACKED HALF OF THE TEXT CORPUS, COUNTED SEPARATELY. The vacuity gate is
# about what publishing exposes, which is a statement about TRACKED content. A
# repository whose entire text corpus is untracked scratch has still had its HEAD
# measured by nothing.
n_text_tracked=$n_text
if [ "${n_untracked:-0}" -gt 0 ]; then
    n_text_tracked=$(grep -vxF -f "$SCRATCH/untracked.txt" "$SCRATCH/textlist.txt" 2>/dev/null | wc -l | tr -d ' ')
fi

# ZERO FILES SCANNED IS UNVERIFIED, NEVER OK - and it means two different things
# in the two kinds of run, so it is answered twice:
#
#   worktree: a repository with no tracked file, or none the text rules can read,
#             has had NOTHING measured. Refused, exit 2.
#   staged:   a commit of one PNG has an empty text corpus and is an ORDINARY
#             commit. The text rules had nothing of that kind to read - not a
#             failure - and the path rules and file.size DID run on it. Failing
#             here would make the hook wrong on a routine commit, and a hook that
#             is wrong on routine commits is a hook bypassed on the one that
#             matters. What must not differ is the arming block, which has
#             already run: that is what keeps the quiet case honest.
if [ "$CORPUS" = worktree ]; then
    if [ "${n_tracked:-0}" -eq 0 ]; then
        vc_refuse vendor.corpus "git ls-files returned NOTHING - this scan measured nothing at all"
    fi
    if [ "${n_text_tracked:-0}" -eq 0 ]; then
        vc_refuse vendor.corpus \
            "$n_tracked tracked file(s) but NOT ONE matched the text corpus - the content rules scanned nothing that is actually committed"
    fi
    ci_pass vendor.corpus \
        "$n_tracked tracked file(s) + $n_untracked untracked-not-ignored, $n_text of them read for content$_binnote"
    [ "$MODE_UNTRACKED" = 1 ] || ci_warn vendor.corpus.untracked \
        "--no-untracked: files not yet in the index were NOT scanned, and a file one \`git add\` away from publication is a shape that has breached before"
elif [ "$CORPUS" = untracked ]; then
    ci_pass vendor.corpus.untracked \
        "$n_untracked untracked-not-ignored file(s), $n_text of them read for content$_binnote"
else
    if [ "$CORPUS" = staged ]; then
        _srcname="the index"; _emptywhy="the index holds no added or modified file - there is nothing for a commit to publish"
    else
        _srcname="the tree at $MODE_REV"; _emptywhy="the tree at $MODE_REV is empty"
    fi
    if [ "${n_tracked:-0}" -eq 0 ]; then
        ci_skip "vendor.corpus.$CORPUS" "nothing to scan - $_emptywhy"
    else
        ci_pass "vendor.corpus.$CORPUS" \
            "$n_tracked file(s) from $_srcname, $n_text read for content$_binnote"
    fi
fi

#=============================================================================
# SECTION 3. FILE-SHAPED COLLATERAL - the path rules and file.size.
#
# The sizes are taken in BATCHES rather than one `wc` per file. This loop is
# where the runtime of a hook actually goes: it is not awk and it is not the
# rules, it is fork and exec. `wc` emits its results in ARGUMENT ORDER, which is
# what makes the association safe for paths containing spaces - it is positional
# and never parsed out of the output - and it adds a `total` line when given more
# than one file, dropped by COUNT rather than by matching the word, because a
# repository is allowed to contain a file called `total`.
#=============================================================================
: > "$SCRATCH/file_raw.tsv"
declare -A VC_SIZE=()
_meta_batch=()
vc_meta_flush() {
    local n="${#_meta_batch[@]}" i=0 line
    [ "$n" -gt 0 ] || return 0
    while IFS= read -r line; do
        [ "$i" -lt "$n" ] || break
        line="${line#"${line%%[![:space:]]*}"}"
        VC_SIZE["${_meta_batch[$i]}"]="${line%% *}"
        i=$((i + 1))
    done < <(wc -c -- "${_meta_batch[@]}" 2>/dev/null)
    _meta_batch=()
}
while IFS= read -r f; do
    [ -n "$f" ] || continue
    _p="$VC_PREFIX$f"
    [ -f "$_p" ] || continue
    _meta_batch+=("$_p")
    [ "${#_meta_batch[@]}" -ge 400 ] && vc_meta_flush
done < "$SCRATCH/scanlist.txt"
vc_meta_flush

while IFS= read -r f; do
    [ -n "$f" ] || continue
    _p="$VC_PREFIX$f"
    [ -f "$_p" ] || continue
    while IFS=$'\t' read -r _rid _rwhy; do
        [ -n "$_rid" ] || continue
        printf '%s\t%s\t0\t%s\n' "$_rid" "$f" "$_rwhy" >> "$SCRATCH/file_raw.tsv"
    done < <(vc_path_hits "$f")
    _size="${VC_SIZE[$_p]:-}"
    if [ -z "$_size" ]; then
        # A file the size pass could not read is NOT silently skipped. "We did
        # not measure this one" is the sentence this script exists to make
        # impossible to omit.
        printf 'file.size\t%s\t0\tthis file could not be measured, so the size rule did not run on it\n' \
            "$f" >> "$SCRATCH/file_raw.tsv"
    elif [ "$_size" -gt "$VC_SIZE_LIMIT" ]; then
        printf 'file.size\t%s\t0\t%s bytes, over the %s byte threshold - a source tree does not carry files this large, and every category the path rules cannot name by suffix is large\n' \
            "$f" "$_size" "$VC_SIZE_LIMIT" >> "$SCRATCH/file_raw.tsv"
    fi
done < "$SCRATCH/scanlist.txt"

#=============================================================================
# SECTION 4. CONTENT-SHAPED COLLATERAL.
#
# In batches, so a corpus larger than ARG_MAX is scanned rather than silently
# truncated - which would be this script's own failure mode, one level down.
#=============================================================================
: > "$SCRATCH/raw.tsv"
mapfile -t _textfiles < "$SCRATCH/textlist.txt"
_batch=()
for f in ${_textfiles[@]+"${_textfiles[@]}"}; do
    _batch+=("$VC_PREFIX$f")
    if [ "${#_batch[@]}" -ge 400 ]; then
        vc_scan "$SCRATCH/batch.tsv" "${_batch[@]}"
        cat "$SCRATCH/batch.tsv" >> "$SCRATCH/raw.tsv"
        _batch=()
    fi
done
if [ "${#_batch[@]}" -gt 0 ]; then
    vc_scan "$SCRATCH/batch.tsv" "${_batch[@]}"
    cat "$SCRATCH/batch.tsv" >> "$SCRATCH/raw.tsv"
fi

# STRIP THE SCRATCH PREFIX BACK OFF, by exact string LENGTH rather than by a
# regex. The prefix is an mktemp path and carries a `.`; building a pattern out
# of it means escaping a path this script did not choose, and getting that wrong
# fails in the direction where the prefix is NOT removed and every finding names
# a directory that will not exist by the time anybody reads the message.
if [ -n "$VC_PREFIX" ] && [ -s "$SCRATCH/raw.tsv" ]; then
    awk -F'\t' -v p="$VC_PREFIX" 'BEGIN { n = length(p) }
        { if (substr($2, 1, n) == p) $2 = substr($2, n + 1)
          printf "%s\t%s\t%s\t%s\n", $1, $2, $3, $4 }' \
        "$SCRATCH/raw.tsv" > "$SCRATCH/raw.stripped" \
        && mv "$SCRATCH/raw.stripped" "$SCRATCH/raw.tsv"
fi

# THE ALLOWLIST IS APPLIED HERE, after collection, not at the point of discovery:
# a waiver that suppresses something invisible leaves no trace that it suppressed
# anything, and cannot then be tested for staleness.
: > "$SCRATCH/all.tsv"
cat "$SCRATCH/file_raw.tsv" "$SCRATCH/raw.tsv" > "$SCRATCH/raw_all.tsv"
while IFS=$'\t' read -r rule path line why; do
    [ -n "$rule" ] || continue
    vc_allowed "$path" "$rule" && continue
    printf '%s\t%s\t%s\t%s\n' "$rule" "$path" "$line" "$why" >> "$SCRATCH/all.tsv"
done < "$SCRATCH/raw_all.tsv"

#=============================================================================
# SECTION 5. THE VERDICT.
#=============================================================================
# --new-lines-only: DROP THE FINDINGS THIS CHANGE DID NOT WRITE. Here, and not
# earlier, because the rules have already run over the whole file and because
# narrowing the INPUT would change what a rule can see rather than what it is
# charged for.
if [ "$MODE_NEWLINES" = 1 ] && [ -s "$SCRATCH/all.tsv" ]; then
    _before=$(wc -l < "$SCRATCH/all.tsv" | tr -d ' ')
    _needchg=0
    [ "$CORPUS" = rev ] && _needchg=1
    # Both created up front: awk's `print > file` never creates a file it does
    # not write to, and an absent keep-file would `mv` nothing over all.tsv and
    # leave every finding in place - a filter that fails OPEN on the clean case.
    : > "$SCRATCH/all.keep"; : > "$SCRATCH/all.drop"
    awk -F'\t' -v map="$SCRATCH/addedlines.tsv" -v chg="$SCRATCH/changedfiles.txt" \
        -v needchg="$_needchg" -v keep="$SCRATCH/all.keep" -v drop="$SCRATCH/all.drop" '
        BEGIN { while ((getline l < map) > 0) new[l] = 1
                if (needchg == "1") while ((getline f < chg) > 0) touched[f] = 1 }
        { if ($3 + 0 == 0) { if (needchg != "1" || ($2 in touched)) print > keep; else print > drop }
          else if (($2 "\t" $3) in new)                            print > keep
          else                                                     print > drop }
    ' "$SCRATCH/all.tsv"
    mv "$SCRATCH/all.keep" "$SCRATCH/all.tsv"
    _after=$(wc -l < "$SCRATCH/all.tsv" | tr -d ' ')
    # THE BACKLOG, AS DATA. What this filter sets aside is not noise - it is the
    # pre-existing disclosure the repository still carries, and the caller has to
    # be able to say how much of it there is. It goes out on its own channel,
    # because --fast silences the prose.
    if [ -n "${VENDOR_CHECK_BACKLOG_OUT:-}" ]; then
        cp "$SCRATCH/all.drop" "$VENDOR_CHECK_BACKLOG_OUT" 2>/dev/null || : > "$VENDOR_CHECK_BACKLOG_OUT"
    fi
    # Say what was set aside, every time. A filter that removes findings in
    # silence is indistinguishable from a clean tree, and the whole argument for
    # this mode is that the difference matters.
    [ "${_before:-0}" -ne "${_after:-0}" ] && ci_say \
        "$((_before - _after)) pre-existing finding(s) on lines this change does not add - not charged here; run without --new-lines-only for the tree's own total"
elif [ -n "${VENDOR_CHECK_BACKLOG_OUT:-}" ]; then
    # Written anyway, so the file is never a stale answer to an older question.
    : > "$VENDOR_CHECK_BACKLOG_OUT"
fi

# TWO PILES, NOT ONE. "What publishing exposes today" is a different question
# from "what one careless `git add` would publish", and merging them lets an
# untracked-file finding hide inside a tracked total.
: > "$SCRATCH/head.tsv"; : > "$SCRATCH/untracked.tsv"
while IFS=$'\t' read -r rule path line why; do
    [ -n "$rule" ] || continue
    if grep -qxF "$path" "$SCRATCH/untracked.txt" 2>/dev/null; then
        printf '%s\t%s\t%s\t%s\n' "$rule" "$path" "$line" "$why" >> "$SCRATCH/untracked.tsv"
    else
        printf '%s\t%s\t%s\t%s\n' "$rule" "$path" "$line" "$why" >> "$SCRATCH/head.tsv"
    fi
done < "$SCRATCH/all.tsv"

if [ "$MODE_FAST" = 1 ]; then
    cat "$SCRATCH/head.tsv" "$SCRATCH/untracked.tsv" > "$SCRATCH/fast.tsv" 2>/dev/null
    # THE MACHINE-READABLE CHANNEL. A caller needing the findings as DATA -
    # hooks/lib-hook.sh does, to name the files in a bypass record - gets the
    # tsv, not this function's human output. Scraping a terse report back into
    # fields would make the message format a wire protocol, and the first person
    # to align a column would break the audit log with no test failing. Written
    # on every fast run, including clean ones, so it is never a stale answer.
    if [ -n "${VENDOR_CHECK_FINDINGS_OUT:-}" ]; then
        cp "$SCRATCH/fast.tsv" "$VENDOR_CHECK_FINDINGS_OUT" 2>/dev/null || true
    fi
    if [ ! -s "$SCRATCH/fast.tsv" ]; then
        ci_exit vendor-collateral   # silence. Not a tick, not a count.
        exit $?
    fi
    _n=$(wc -l < "$SCRATCH/fast.tsv" | tr -d ' ')
    case "$CORPUS" in
        staged) _what="the staged content this commit would write" ;;
        rev)    if [ "$MODE_NEWLINES" = 1 ]; then
                    _what="what $MODE_REV ADDS since $MODE_SINCE - the rest of that tree is not charged here"
                else
                    _what="the tree at $MODE_REV - what pushing that ref would publish"
                fi ;;
        untracked) _what="the untracked files one \`git add -A\` would publish" ;;
        *)      _what="the tracked tree and the untracked files one \`git add -A\` would publish" ;;
    esac
    printf '\n%sBLOCKED%s  %s finding(s) in %s\n\n' "$_C_RED" "$_C_OFF" "$_n" "$_what" >&2
    # The gate ids go into verdicts.tsv and into the counters - so the exit status
    # and the trail match every other mode - but they are NOT printed. A gate
    # line immediately above the findings themselves is the same information
    # twice, and a hook's whole budget is four lines of the reader's attention.
    while IFS= read -r _r; do
        [ -n "$_r" ] || continue
        _c=$(awk -F'\t' -v r="$_r" '$1 == r' "$SCRATCH/fast.tsv" | wc -l | tr -d ' ')
        CI_FAIL=$((CI_FAIL + 1))
        _ci_record FAIL "vendor.$_r" "$_c finding(s)"
    done < <(cut -f1 "$SCRATCH/fast.tsv" | sort -u)
    awk -F'\t' '{ printf "  %-40s %-14s %s\n", $2 ($3 > 0 ? ":" $3 : ""), $1, $4 }' \
        "$SCRATCH/fast.tsv" | sort -u | head -20 >&2
    [ "$_n" -gt 20 ] && printf '  ... and %d more\n' "$((_n - 20))" >&2
    _paths="$(awk -F'\t' '{ print $2 }' "$SCRATCH/fast.tsv" | sort -u | head -20 \
        | awk '{ printf "%s%s", sep, $0; sep = " " }')"
    printf '\n' >&2
    case "$CORPUS" in
        staged) printf '  fix   git restore --staged -- %s\n' "$_paths" >&2 ;;
        rev)    printf '  fix   this is in a COMMIT, not just in your tree. `git log --oneline %s` and rewrite,\n        or push a branch that does not contain it. An edit at the tip does not remove it.\n' "$MODE_REV" >&2 ;;
        *)      printf '  fix   %s     # the full report, and what to do about each kind\n' "${BASH_SOURCE[0]}" >&2 ;;
    esac
    ci_exit vendor-collateral
    exit $?
fi

vc_report() {   # <tsv> <gate prefix> <label>
    local tsv="$1" pfx="$2" label="$3" rule n
    local total; total=$(wc -l < "$tsv" | tr -d ' ')
    ci_head "$label"
    if [ "${total:-0}" -eq 0 ]; then
        ci_pass "$pfx" "no finding in any rule"
        return 0
    fi
    while IFS= read -r rule; do
        [ -n "$rule" ] || continue
        n=$(awk -F'\t' -v r="$rule" '$1 == r' "$tsv" | wc -l | tr -d ' ')
        ci_fail "$pfx.$rule" "$n finding(s)"
        awk -F'\t' -v r="$rule" '$1 == r {
            printf "        %s%s   %s\n", $2, ($3 > 0 ? ":" $3 : ""), $4 }' "$tsv" \
            | sort -u | head -40 >&2
        [ "$n" -gt 40 ] && printf '        ... and %d more\n' "$((n - 40))" >&2
    done < <(cut -f1 "$tsv" | sort -u)
    return 1
}

vc_report "$SCRATCH/head.tsv" vendor.tracked "tracked - what publishing exposes today"

if [ "$CORPUS" = worktree ] && [ "$MODE_UNTRACKED" = 1 ]; then
    ci_head "untracked - what the next \`git add -A\` would publish"
    if [ "${n_untracked:-0}" -eq 0 ]; then
        ci_pass vendor.untracked "no untracked, non-ignored file in the tree"
    else
        vc_report "$SCRATCH/untracked.tsv" vendor.untracked \
            "$n_untracked untracked file(s), none of them ignored"
    fi
fi

vc_print_allowlist

ci_head "what a clean result here does not mean"
ci_say "It means no rule in the table matched. A vendor core committed as plain RTL"
ci_say "with its header stripped matches nothing here and is still a breach, and so"
ci_say "is a paraphrase of a vendor document. Read VENDOR_COLLATERAL.md; the rules"
ci_say "catch the shapes the MISTAKE takes, which is nearly always a file somebody"
ci_say "did not know was collateral."
ci_say ""
ci_say "The rule, as opposed to the check:  $FLOW_DIR/VENDOR_COLLATERAL.md"

ci_summary_table "No vendor collateral (ci/check-vendor-collateral.sh)"
ci_exit vendor-collateral
exit $?
