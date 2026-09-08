# shellcheck shell=bash
#-----------------------------------------------------------------------------
# hooks/lib-hook.sh - what every GIT hook in this directory has to get right
#
# THIS DIRECTORY HOLDS GIT HOOKS. IT IS NOT THE FLOW-HOOK DIRECTORY, and the word
# means two unrelated things in this toolkit:
#
#   FLOW HOOK   $(HOOKS_DIR)/<seam>.tcl in the PROJECT, sourced by a build stage
#               at a seam named in flow/common/seams.txt. Runs during a build and
#               affects the bitstream. Nothing in this directory is one.
#   GIT HOOK    this directory. Run by git when somebody types a git command.
#               Refuses to commit or push vendor collateral. Affects no build,
#               ever, and touches nothing in a run directory.
#
# Sourced, never executed.
#
# WHY THERE ARE HOOKS AT ALL, WHEN CI RUNS THE SAME SCANNER
#
# CI runs it AFTER the push. For a repository that is going public that is not a
# gate, it is a notification: the bytes are being served by the time the job goes
# red, any fork or mirror has them, and a redaction commit does not unpublish
# anything. The shape that breaches is always the same - a vendor file untracked
# in a directory .gitignore does not cover, `git add -A`, push - and in that
# sequence the scanner that would have found it exists, is correct, and is asked
# too late.
#
# So these hooks are NOT a second scanner. They are the SAME scanner, asked
# earlier: ci/check-vendor-collateral.sh --staged --fast at commit, and --rev
# --since --fast at push. A hook with its own rules would drift from the CI gate,
# and two guards that disagree about the same file are worse than one - the
# disagreement teaches everybody that a red hook is probably noise.
#
# THE FOUR PROPERTIES THIS FILE EXISTS TO HOLD
#
#  1. FAIL CLOSED. Scanner missing, unreadable, crashed, killed, or exiting a
#     status nobody has seen before: BLOCK, and say which. A guard that passes
#     when it could not run is the vacuous green the scanner itself was written
#     to correct, moved to the one place nobody reads the output.
#
#  2. QUIET WHEN CLEAN. Nothing on success. Not a tick, not a timing, not a count
#     of what was scanned. A hook that prints on every commit is a hook whose
#     output stops being read, and the run it stops being read on is the one that
#     said something different.
#
#  3. A BYPASS THAT IS LOUD. `git commit --no-verify` is silent, leaves no trace,
#     and will still work - nothing in a hook can prevent it, because it is git
#     declining to run the hook at all. What this file provides is the
#     alternative a person can choose ON PURPOSE: VENDOR_CHECK_BYPASS with a
#     reason in it, which lets the operation through, prints a banner naming the
#     user and the files, and appends to a log nothing here ever rewrites. The
#     point is not to make bypassing hard. It is to make it a DECISION with a
#     name attached instead of a reflex with no record.
#
#  4. NO SURPRISES ABOUT WHAT WAS CHECKED. Every message says which corpus was
#     read. "Clean" over the index and "clean" over a pushed range are different
#     sentences, and this file never lets them share a word.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------

[ -n "${_VC_HOOK_SOURCED:-}" ] && return 0
_VC_HOOK_SOURCED=1

# WHERE THE SCANNER IS. Derived from this file's own location, so the hooks work
# through core.hooksPath from a repository that is NOT the toolkit - which is the
# whole deployment: the toolkit is a submodule of the project being protected.
# VENDOR_CHECK_SCANNER overrides it, and exists so a test can point the hooks at
# a broken copy and watch them block rather than pass.
_VC_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
VC_SCANNER="${VENDOR_CHECK_SCANNER:-$_VC_HOOK_DIR/../ci/check-vendor-collateral.sh}"

if [ -t 2 ] && [ "${VENDOR_CHECK_COLOUR:-1}" = 1 ]; then
    _H_RED=$'\033[31m'; _H_YEL=$'\033[33m'; _H_OFF=$'\033[0m'
else
    _H_RED=""; _H_YEL=""; _H_OFF=""
fi

vc_hook_say() { printf '%s\n' "$*" >&2; }

## vc_hook_block <gate> <what to do about it...>
## The one place a hook says no. Every refusal goes through here so that every
## refusal names both the reason AND the escape - a block with no stated way past
## it is how `--no-verify` becomes the first thing anybody tries.
vc_hook_block() {
    local gate="$1"; shift
    printf '\n%s%s%s  %s\n' "$_H_RED" "$gate" "$_H_OFF" "$*" >&2
    vc_hook_bypass_hint
    return 1
}

vc_hook_bypass_hint() {
    cat >&2 <<EOF

  If this is wrong, or is an emergency, say so and it is recorded rather than silent:

      VENDOR_CHECK_BYPASS="why this content is safe to publish" <your git command>

  That writes a banner here and a line in $(vc_bypass_log_path). It is not
  \`--no-verify\`, which leaves nothing behind and which pre-push will catch anyway.
EOF
}

## vc_bypass_log_path - where the record goes
##
## $GIT_DIR by default, which is LOCAL and is deliberately not in the working
## tree: a bypass record that had to be committed would need a commit, and a hook
## cannot amend the commit it is inspecting. VENDOR_CHECK_BYPASS_LOG points it
## somewhere a CI job can read - a shared filesystem, a spool directory - for
## sites that want the record to outlive the machine.
##
## `git rev-parse --git-dir` and never the string `.git`, because in a SUBMODULE
## - which is how this toolkit is deployed - `.git` is a FILE holding a redirect,
## and appending a filename to it produces a path that cannot be created and a
## bypass that is not recorded.
##
## Nothing here ever truncates it or rewrites a line. Append only.
vc_bypass_log_path() {
    if [ -n "${VENDOR_CHECK_BYPASS_LOG:-}" ]; then
        printf '%s' "$VENDOR_CHECK_BYPASS_LOG"
        return 0
    fi
    local gd
    gd="$(git rev-parse --git-dir 2>/dev/null)" || gd=".git"
    printf '%s/vendor-check-bypass.log' "${gd:-.git}"
}

## vc_bypass_reason - the reason, trimmed, or empty when there is no usable one
##
## A BYPASS NEEDS A REASON AND NOT A KEYSTROKE. `VENDOR_CHECK_BYPASS=1` is
## `--no-verify` with extra steps: it produces a log line that tells the next
## reader nothing, and a log of those is a log people stop reading. Twelve
## characters is not a quality bar, it is a speed bump - the difference between
## typing a word and writing a sentence, and the whole mechanism is about which
## of those two the person did.
VC_BYPASS_MIN=12
vc_bypass_reason() {
    local r="${VENDOR_CHECK_BYPASS:-}"
    # A reason of spaces is a reason of nothing.
    r="${r#"${r%%[![:space:]]*}"}"
    r="${r%"${r##*[![:space:]]}"}"
    printf '%s' "$r"
}
vc_bypass_offered() { [ -n "${VENDOR_CHECK_BYPASS:-}" ]; }
vc_bypass_usable()  { local r; r="$(vc_bypass_reason)"; [ "${#r}" -ge "$VC_BYPASS_MIN" ]; }

## vc_findings_file / vc_findings_init - the accumulated tsv of every scanner call
##
## The scanner writes its findings as DATA into $VENDOR_CHECK_FINDINGS_OUT; this
## is where they pile up. pre-push calls the scanner more than once, and the
## bypass record has to name every file all of those found - so each call's file
## is APPENDED here rather than replacing.
##
## vc_findings_init SETS A GLOBAL AND RETURNS NOTHING, and that shape is
## deliberate. The obvious version - `acc="$(vc_findings_file)"` with the mktemp
## inside - assigns the variable in the SUBSHELL command substitution creates,
## the parent's copy stays empty, every call makes a fresh temp file, and nothing
## ever accumulates. The visible symptom is a bypass banner reading "no finding
## list - the scanner did not run" on a run where the scanner had just found
## three things: a record that misreports what it permitted.
VC_FINDINGS=""
vc_findings_init() {
    [ -n "$VC_FINDINGS" ] && return 0
    VC_FINDINGS="$(mktemp "${TMPDIR:-/tmp}/vc-findings.XXXXXX" 2>/dev/null)" || VC_FINDINGS=""
    [ -n "$VC_FINDINGS" ] && : > "$VC_FINDINGS"
    return 0
}

## vc_bypass_record <hook> <corpus> <scanner rc>
##
## The banner and the log line. Both name the same four things - who, when, why,
## and WHAT WAS LET THROUGH - because a bypass record that does not list the
## files is a record of a mood.
vc_bypass_record() {
    local hook="$1" corpus="$2" rc="$3"
    local reason when who email host repo log findings nf flat

    # The tsv the scanner wrote, rendered as `path:line  rule`. NOT the scanner's
    # human output, which carries a banner and a fix line and would put both into
    # the audit log where the file list is supposed to be.
    findings="$(mktemp "${TMPDIR:-/tmp}/vc-bypasslist.XXXXXX")" || findings=/dev/null
    if [ -n "$VC_FINDINGS" ] && [ -s "$VC_FINDINGS" ]; then
        awk -F'\t' '{ printf "%s%s\t%s\n", $2, ($3 > 0 ? ":" $3 : ""), $1 }' "$VC_FINDINGS" \
            | sort -u > "$findings"
    fi
    reason="$(vc_bypass_reason)"
    when="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    who="$(git config user.name 2>/dev/null || true)"; who="${who:-${USER:-unknown}}"
    email="$(git config user.email 2>/dev/null || true)"
    [ -n "$email" ] && who="$who <$email>"
    host="$(hostname 2>/dev/null || printf 'unknown')"
    repo="$(git rev-parse --show-toplevel 2>/dev/null || printf '?')"
    log="$(vc_bypass_log_path)"

    {
        printf '\n%s' "$_H_YEL"
        printf '===============================================================================\n'
        printf ' VENDOR COLLATERAL CHECK BYPASSED - %s\n' "$hook"
        printf '===============================================================================%s\n' "$_H_OFF"
        printf '   who      %s (%s@%s)\n' "$who" "${USER:-unknown}" "$host"
        printf '   when     %s\n' "$when"
        printf '   repo     %s\n' "$repo"
        printf '   corpus   %s\n' "$corpus"
        printf '   reason   %s\n' "$reason"
        if [ -s "$findings" ]; then
            printf '   let through:\n'
            awk -F'\t' 'NR<=20 { printf "       %-46s %s\n", $1, $2 }' "$findings"
            nf=$(wc -l < "$findings" | tr -d ' ')
            [ "${nf:-0}" -gt 20 ] && printf '       ... and %d more\n' "$((nf - 20))"
        else
            printf '   let through:\n       (the scanner exited %s and produced NO finding list - it did not run, so\n        what this bypass permitted is unknown and was never measured)\n' "$rc"
        fi
        printf '   recorded %s\n' "$log"
        printf '\n   This is on the record and CI will still fail on this content. If the\n'
        printf '   reason above is not one you would want quoted back to you, stop here.\n'
        printf '===============================================================================\n\n'
    } >&2

    # THE LOG. One line, tab separated, appended and never rewritten. The findings
    # are flattened onto it so the line is self-contained: a record that points at
    # a scan nobody kept is not a record.
    flat="$(awk -F'\t' 'NR<=40 { printf "%s[%s] ", $1, $2 }' "$findings" 2>/dev/null)"
    [ -n "$flat" ] || flat="(no finding list - the scanner exited $rc without running)"
    mkdir -p "$(dirname "$log")" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\t%s\t%s\trc=%s\t%s\t%s\n' \
        "$when" "$hook" "$corpus" "${USER:-unknown}" "$host" "$who" "$rc" "$reason" "$flat" \
        >> "$log" 2>/dev/null \
        || vc_hook_say "  warning: could not append to $log - the bypass happened and was NOT recorded"
    rm -f "$findings" 2>/dev/null
}

## vc_run_scanner <output file> <scanner args...>
##   returns the scanner's exit status, or 127 when it could not be run at all.
##
## FAIL CLOSED LIVES HERE. The caller never sees "no findings" from a scanner that
## did not run, because the two cases produce different return codes and this is
## the only function that knows the difference.
vc_run_scanner() {
    local out="$1"; shift
    : > "$out"
    if [ ! -f "$VC_SCANNER" ]; then
        printf 'the scanner is not at %s\n' "$VC_SCANNER" > "$out"; return 127
    fi
    if [ ! -r "$VC_SCANNER" ]; then
        printf 'the scanner at %s is not readable\n' "$VC_SCANNER" > "$out"; return 127
    fi
    local one rc=0
    vc_findings_init
    one="$(mktemp "${TMPDIR:-/tmp}/vc-findings1.XXXXXX" 2>/dev/null)" || one=""
    # `bash <script>` rather than executing it: a checkout that lost its exec bits
    # - which happens on export, on a zip round-trip and on some filesystem copies
    # - would otherwise make the guard VANISH rather than complain.
    #
    # < /dev/null, and it is load-bearing in pre-push: that hook's ref list
    # arrives on stdin, and a child inheriting it would eat the rest of it.
    VENDOR_CHECK_FINDINGS_OUT="$one" bash "$VC_SCANNER" "$@" < /dev/null > "$out" 2>&1 || rc=$?
    if [ -n "$one" ]; then
        [ -n "$VC_FINDINGS" ] && [ -s "$one" ] && cat "$one" >> "$VC_FINDINGS"
        rm -f "$one"
    fi
    return $rc
}

## vc_hook_verdict <hook> <corpus label> <scanner rc> <output file>
##   0 to let the operation proceed, 1 to block.
##
## The whole decision, in one place, so that no two hooks can come to different
## conclusions about the same exit status.
vc_hook_verdict() {
    local hook="$1" corpus="$2" rc="$3" out="$4" kind

    if [ "$rc" -eq 0 ]; then
        # A bypass offered and not needed still gets a word, because the failure
        # mode of this mechanism is somebody exporting it in their shell profile
        # in March and finding out in November.
        if vc_bypass_offered; then
            vc_hook_say "${_H_YEL}note${_H_OFF}  VENDOR_CHECK_BYPASS is set and nothing needed bypassing ($corpus was clean)."
            vc_hook_say "      Unset it. A standing bypass is a bypass nobody will notice using."
        fi
        return 0
    fi

    # 1 is "the scanner ran and found something" - the ONLY status that means the
    # guard worked. EVERYTHING ELSE is the guard failing to answer, and is treated
    # as worse rather than as absent. 2 is the scanner's own "refused or could not
    # measure" (CONTRACT.md 10), 126/127 are "could not execute", 130/137/143 are
    # a signal, and an unrecognised status is by definition one nobody here has
    # reasoned about.
    case "$rc" in
        1)       kind=finding ;;
        2)       kind=unmeasured ;;
        126|127) kind=missing ;;
        *)       kind=broken ;;
    esac

    if [ "$kind" != finding ]; then
        printf '\n%sBLOCKED%s  the vendor-collateral guard could not run, so nothing about %s has been checked.\n' \
            "$_H_RED" "$_H_OFF" "$corpus" >&2
        case "$kind" in
            unmeasured) vc_hook_say "        $VC_SCANNER refused, or could not measure its corpus (exit 2)." ;;
            missing)    vc_hook_say "        $VC_SCANNER could not be executed (exit $rc)." ;;
            broken)     vc_hook_say "        $VC_SCANNER exited $rc - a crash, a signal, or a status this hook has no rule for." ;;
        esac
        vc_hook_say ""
        sed -n '1,15p' "$out" | sed 's/^/        /' >&2
        vc_hook_say ""
        vc_hook_say "        This is NOT a pass. A guard that cannot read its input has checked"
        vc_hook_say "        nothing, and letting the operation through on that basis is the exact"
        vc_hook_say "        defect the guard exists to correct."
    else
        # The scanner's --fast output is already the terse report: file, rule and
        # the one command. Reformatting it here would be the second copy this
        # whole design is trying not to have.
        cat "$out" >&2
    fi

    if vc_bypass_offered; then
        if vc_bypass_usable; then
            vc_bypass_record "$hook" "$corpus" "$rc"
            return 0
        fi
        printf '\n%sVENDOR_CHECK_BYPASS is set to %s characters and a bypass needs a REASON.%s\n' \
            "$_H_RED" "${#VENDOR_CHECK_BYPASS}" "$_H_OFF" >&2
        vc_hook_say "  Whoever reads the log next has to be able to tell why this was allowed."
        vc_hook_say "  At least $VC_BYPASS_MIN characters, and a sentence rather than a word:"
        vc_hook_say ""
        vc_hook_say "      VENDOR_CHECK_BYPASS=\"invented fixture for the hook self-test, not a vendor file\""
        vc_hook_say ""
        return 1
    fi

    vc_hook_bypass_hint
    return 1
}

## vc_hook_index_main <hook name> - the whole of an index-checking hook
##
## THREE HOOKS SHARE THIS, and they share it because git fires a DIFFERENT one
## depending on how the commit is being made. Measured with stub hooks:
##
##     git commit                 pre-commit
##     git merge --no-ff          pre-merge-commit      (NOT pre-commit)
##     git am                     pre-applypatch        (NOT pre-commit)
##     git merge --ff-only        nothing at all
##     git cherry-pick            nothing at all
##     git rebase                 nothing at all
##     git revert                 nothing at all
##
## Installing only pre-commit therefore leaves a guard that a merge walks straight
## past. The three hooks that CAN be installed ask the same question about the
## same corpus, so they are the same code under a different name in the log. The
## four that fire nothing are not fixable from here at all, and they are the
## reason hooks/pre-push re-scans and trusts none of them.
vc_hook_index_main() {
    local hook="$1" out rc=0 verdict

    if ! command -v git >/dev/null 2>&1; then
        vc_hook_block "$hook" "no git on PATH - this hook cannot read the index it is supposed to check."
        return 1
    fi

    out="$(mktemp "${TMPDIR:-/tmp}/vc-hook.XXXXXX")" || {
        printf '\n%s: BLOCKED - could not create a temporary file, so the scan did not run.\n' "$hook" >&2
        return 1
    }
    # --new-lines-only: charge this commit for the lines it ADDS, not for every
    # line of every file it happens to touch. Without it, a one-line edit to an
    # existing flow script inherits that script's whole pre-existing finding
    # count - a hook that cannot be passed, only bypassed. A file-shaped finding
    # has no line to be new and is not narrowed, so `git add core.edn` still fails
    # here. The tree-wide question stays with hooks/pre-push.
    vc_run_scanner "$out" --staged --fast --new-lines-only || rc=$?
    vc_hook_verdict "$hook" "the lines this commit adds" "$rc" "$out"
    verdict=$?
    rm -f "$out" ${VC_FINDINGS:+"$VC_FINDINGS"}
    return $verdict
}
