#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# t_help_hooks.sh - `make help-hooks` prints THE seam list, read from the file
#
# DEFECT CLASS: A REPORT THAT ENUMERATES THE EXTENSION POINTS FROM A COPY OF
# THE LIST, RATHER THAN FROM THE FILE THE ENGINE READS.
#
# `make help-hooks` is the answer to "where can this project extend the flow".
# It reads flow/common/seams.txt - the ONE list, CONTRACT.md section 6.1 - and
# prints every seam, which of them this project has taken up, and which files
# in HOOKS_DIR will never run because their name is not a seam. It is the page
# a person reads INSTEAD of opening seams.txt, so a wrong answer here is not a
# cosmetic defect: a seam this target omits is a seam nobody uses, and a seam it
# invents is a hook file somebody writes that never runs. Both are stable, quiet
# and wrong - the reference ASIC toolkit's five-entry whitelist against a
# seven-file directory, one level up, with a person reading the whitelist.
#
# t_seams.sh already asserts that no file in the repository CARRIES a copy of
# the list (a static scan). This suite is the functional half for this one
# consumer: whatever help.mk does, WHAT IT PRINTS must equal WHAT THE FILE SAYS
# - the same test t_seams.sh section 6 applies to fpga-flow-check. The two
# planted faults are the two directions that equality can fail in:
#
#   a seam in the file and not in the output   the target reads a stale
#                                              snapshot of the list, and a
#                                              seam added to the file is
#                                              never announced
#   a seam in the output and not in the file   the target prints a name the
#                                              engine will never source
#
# NOT COVERED HERE, AND SAID SO WHERE IT MATTERS: the step overrides. CONTRACT
# section 6.2 makes `ls flow/steps/*.tcl` the one list of overridable steps,
# and `make help-hooks` POINTS at that directory ("a file named for a step in
# flow/steps/") but ENUMERATES NOTHING from it. There is no printed step list
# to compare with the directory, so no assertion of that shape can be written
# against this target, and section 5 below records that as a skip with the
# reason rather than as a pass. `scripts/fpga-flow-hooks` is the GIT-hook
# installer, an unrelated thing (its own header, line 16), and is not touched.
#
# THE SUITE NAMES NO SEAM. Every name it needs is read from seams.txt at run
# time, exactly as the consumer under test must - a test of "this list has one
# copy" that carried a second copy would be the defect wearing a lab coat. The
# two names it PLANTS are chosen to be seams nowhere.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/lib/harness.sh
. "$HERE/../lib/harness.sh"

t_sandbox; SB="$T_SANDBOX"

SEAMS_REL="flow/common/seams.txt"
HELP_REL="mk/help.mk"
for f in "$SEAMS_REL" "$HELP_REL"; do
    if [ ! -f "$FLOW_DIR/$f" ]; then
        t_skip help_hooks.all "$f is not in this checkout - there is no list, or no target that prints it, so nothing can be compared. Not a pass"
        t_summary; exit $?
    fi
done

## seam_list <toolkit root>  - the seam names, one per line, from THE file.
## Same reader as t_seams.sh, for the same reason: this suite must not carry
## a copy of the thing it exists to check for copies of.
seam_list() { awk '!/^[[:space:]]*#/ && NF { print $1 }' "$1/$SEAMS_REL"; }

N_SEAMS="$(seam_list "$FLOW_DIR" | grep -c .)"
t_say "$N_SEAMS seams declared in $SEAMS_REL"
if [ "$N_SEAMS" -lt 2 ]; then
    t_skip help_hooks.all "only $N_SEAMS seam(s) declared; the proofs below add one and drop one, and need a list with a first and a last"
    t_summary; exit $?
fi

#-----------------------------------------------------------------------------
# DRIVERS
#
# The target is driven the way a person types it: from a scaffolded project,
# `make help-hooks`, so mk/flow.mk resolves HOOKS_DIR and hands it to help.mk.
# The one exception is section 4, which needs the toolkit's own guard and not
# flow.mk's, and says so there.
#
# EVERY PATH IS ASKED OF MAKE. HOOKS_DIR is `$(FPGA_DIR)/hooks` today; the
# suite does not know that, because the day it changes the assertion that
# assumed it would go on passing against the wrong directory.
#-----------------------------------------------------------------------------
## help_hooks <project dir> - the target's combined output; status in $?
help_hooks() { make -C "$1" --no-print-directory help-hooks 2>&1; }

## make_var <project dir> <VAR> - the value make resolves for VAR in that project
make_var() { make -C "$1" --no-print-directory --eval="p: ; @echo \$($2)" p 2>/dev/null; }

## printed_seams <output> - the seam names help-hooks printed, in order.
##
## THE BLOCK IS FOUND BY ITS FOOTER, not by the header text or by the indent.
## The explanatory paragraph above it is indented four spaces too, and its
## lines also begin with a lower-case word, so "four spaces then a name" would
## harvest prose. The seam block is the LAST run of non-blank lines before
## "N seam(s) declared" - last, not adjacent: the target prints a blank line
## between the block and its footer, and the first draft of this reader took
## "immediately before" literally, harvested nothing, and made the good case
## FAIL while both mutation proofs passed - for the wrong reason, which is the
## one way a proof can lie. The first token of each line is the seam whether
## or not a right-hand column is printed.
printed_seams() {
    printf '%s\n' "$1" | awk '
        /seam\(s\) declared/ {
            if (n == 0) { n = m; for (i = 1; i <= m; i++) B[i] = L[i] }
            for (i = 1; i <= n; i++) print B[i]
            exit
        }
        /^[[:space:]]*$/ {
            if (n > 0) { m = n; for (i = 1; i <= n; i++) L[i] = B[i] }
            n = 0; next
        }
        { n++; B[n] = $1 }'
}

## declared_count <output> - the N in "N seam(s) declared", or nothing
declared_count() {
    printf '%s\n' "$1" | sed -n 's/^ *\([0-9][0-9]*\) seam(s) declared.*/\1/p'
}

#=============================================================================
# 1. WHAT IT PRINTS IS WHAT THE FILE SAYS
#
# Both directions, one comparison: the printed list must be the file's list,
# same names, same order, and the count line must agree with both. Order is
# part of the assertion because the file's order is the order the seams fire
# in, and a reader takes the printed order as that.
#=============================================================================
t_head "the printed seam list is exactly seams.txt"

## seams_match <project dir> <toolkit root>
seams_match() {
    local dir="$1" root="$2" out want got n rc=0
    out="$(help_hooks "$dir")" || rc=$?
    [ "$rc" -eq 0 ] || { printf 'make help-hooks exited %d:\n%s\n' "$rc" "$out"; return 1; }
    want="$(seam_list "$root")"
    got="$(printed_seams "$out")"
    if [ "$want" != "$got" ]; then
        printf 'help-hooks printed a list that is not %s:\n' "$SEAMS_REL"
        diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | sed 's/^/  /'
        printf 'left = the file the engine reads, right = what the target printed.\n'
        return 1
    fi
    n="$(declared_count "$out")"
    if [ "$n" != "$(printf '%s\n' "$want" | grep -c .)" ]; then
        printf 'the list matches but the count line says "%s seam(s) declared" for a file declaring %s\n' \
            "${n:-(no count line)}" "$(printf '%s\n' "$want" | grep -c .)"
        return 1
    fi
    return 0
}

PM="$SB/proj-good"
if ! t_project "$PM" "$FLOW_DIR"; then
    t_skip help_hooks.seams "could not scaffold a project against this checkout"
else
    t_check help_hooks.seams \
        "make help-hooks prints every seam in $SEAMS_REL, in file order, and counts them" \
        seams_match "$PM" "$FLOW_DIR"
fi

# -- proof 1: a seam in the FILE and not in the OUTPUT -----------------------
# THE PLANTED FAULT IS A SNAPSHOT. The target's loop is pointed at a frozen
# copy of seams.txt taken now, then a seam is added to the live file. That is
# the drift a hardcoded list produces, in the shape it actually arrives in: not
# a wrong name, but a name that is missing because the copy predates it.
M="$(t_mutant "$SB" help-hooks-snapshot)"
PM="$SB/proj-snapshot"
if t_project "$PM" "$M" \
   && cp "$M/$SEAMS_REL" "$M/$SEAMS_REL.snapshot" \
   && t_mutate "$M" "$HELP_REL" "s|done < '\\\$(SEAMS_FILE)';|done < '\$(SEAMS_FILE).snapshot';|" \
   && printf 't_help_hooks_planted\n' >> "$M/$SEAMS_REL"; then
    t_check_fail help_hooks.seams.mutation.file_not_output \
        "with help.mk reading a snapshot of the list and a seam added to the file, the assertion goes red" \
        seams_match "$PM" "$M"
else
    t_skip help_hooks.seams.mutation.file_not_output "could not plant the fault: the \"done < '\$(SEAMS_FILE)'\" line in $HELP_REL has changed shape"
fi

# -- proof 2: a seam in the OUTPUT and not in the FILE -----------------------
# One extra name echoed into the block, at a spelling that is a seam nowhere.
M="$(t_mutant "$SB" help-hooks-extra)"
PM="$SB/proj-extra"
if seam_list "$M" | grep -qx planted_by_t_help_hooks; then
    t_skip help_hooks.seams.mutation.output_not_file "the planted name is a declared seam in this checkout, so printing it would not be a fault"
elif t_project "$PM" "$M" \
   && t_mutate "$M" "$HELP_REL" "s|n=0; taken=0;|n=0; taken=0; echo '    planted_by_t_help_hooks';|"; then
    t_check_fail help_hooks.seams.mutation.output_not_file \
        "with help.mk printing a seam the file does not declare, the assertion goes red" \
        seams_match "$PM" "$M"
else
    t_skip help_hooks.seams.mutation.output_not_file "could not plant the fault: the 'n=0; taken=0;' line in $HELP_REL has changed shape"
fi

#=============================================================================
# 2. A HOOK THIS PROJECT HAS TAKEN UP IS REPORTED AS TAKEN
#
# The right-hand column is the half of the page a project reads about ITSELF.
# The hook is planted at the LAST declared seam - the one a truncated list
# loses first - and the assertion wants the path in the row AND the count in
# the footer, because a row that says "-" beside a count that says 1 is the
# kind of output nobody notices is wrong.
#=============================================================================
t_head "a hook at a declared seam is reported as taken, with its path"

LAST_SEAM="$(seam_list "$FLOW_DIR" | tail -1)"

## hook_reported <project dir> <toolkit root>
hook_reported() {
    local dir="$1" root="$2" hd out seam rc=0
    seam="$(seam_list "$root" | tail -1)"
    hd="$(make_var "$dir" HOOKS_DIR)"
    [ -n "$hd" ] || { echo "make resolved HOOKS_DIR to nothing in $dir"; return 1; }
    mkdir -p "$hd" && printf '# planted by t_help_hooks.sh\n' > "$hd/$seam.tcl" || return 1
    out="$(help_hooks "$dir")" || rc=$?
    [ "$rc" -eq 0 ] || { printf 'make help-hooks exited %d:\n%s\n' "$rc" "$out"; return 1; }
    if ! printf '%s\n' "$out" | awk -v s="$seam" -v p="$hd/$seam.tcl" '$1 == s && $2 == p { f = 1 } END { exit !f }'; then
        printf 'no row "%s  %s" in the output:\n' "$seam" "$hd/$seam.tcl"
        printf '%s\n' "$out" | grep -E "^    $seam( |$)|seam\(s\) declared" | sed 's/^/  /'
        return 1
    fi
    if ! printf '%s\n' "$out" | grep -qE 'seam\(s\) declared, 1 with a hook'; then
        printf 'the row is right and the footer is not:\n'
        printf '%s\n' "$out" | grep -E 'seam\(s\) declared' | sed 's/^/  /'
        return 1
    fi
    return 0
}

PM="$SB/proj-taken"
if t_project "$PM" "$FLOW_DIR"; then
    t_check help_hooks.taken \
        "a $LAST_SEAM.tcl in HOOKS_DIR is reported beside its seam, with its path, and counted" \
        hook_reported "$PM" "$FLOW_DIR"
else
    t_skip help_hooks.taken "could not scaffold a project against this checkout"
fi

M="$(t_mutant "$SB" help-hooks-never-taken)"
PM="$SB/proj-never-taken"
if t_project "$PM" "$M" \
   && t_mutate "$M" "$HELP_REL" 's|seam\.tcl" \]; then|seam.tcl.never" ]; then|'; then
    t_check_fail help_hooks.taken.mutation \
        "with the file test looking for a name no hook has, the taken-up assertion goes red" \
        hook_reported "$PM" "$M"
else
    t_skip help_hooks.taken.mutation "could not plant the fault: the '[ -f \"\$\$hd/\$\$seam.tcl\" ]' test in $HELP_REL has changed shape"
fi

#=============================================================================
# 3. A FILE THAT WILL NEVER RUN IS NAMED
#
# The other half of the page a project reads about itself, and the more
# important half: a hook file whose name is not a seam is silently never
# sourced. The target says so and names the file. The planted file's name is
# checked against the file first - if a future seams.txt ever declares it,
# planting it would not be a fault and the proof is skipped rather than made
# to pass on a coincidence.
#=============================================================================
t_head "a file in HOOKS_DIR whose name is not a seam is named as never running"

STRAY=not_a_seam

## stray_named <project dir> <toolkit root>
stray_named() {
    local dir="$1" root="$2" hd out rc=0
    hd="$(make_var "$dir" HOOKS_DIR)"
    [ -n "$hd" ] || { echo "make resolved HOOKS_DIR to nothing in $dir"; return 1; }
    mkdir -p "$hd" && printf '# planted by t_help_hooks.sh\n' > "$hd/$STRAY.tcl" || return 1
    out="$(help_hooks "$dir")" || rc=$?
    [ "$rc" -eq 0 ] || { printf 'make help-hooks exited %d:\n%s\n' "$rc" "$out"; return 1; }
    if ! printf '%s\n' "$out" | grep -qF 'WILL NEVER RUN'; then
        printf 'the output carries no WILL NEVER RUN block for %s.tcl:\n' "$STRAY"
        printf '%s\n' "$out" | grep -iE 'never|stray|hooks_dir' | sed 's/^/  /'
        return 1
    fi
    if ! printf '%s\n' "$out" | grep -qE "^ +$STRAY\.tcl\$"; then
        printf 'the block is there and does not name %s.tcl:\n' "$STRAY"
        printf '%s\n' "$out" | sed -n '/WILL NEVER RUN/,$p' | head -6 | sed 's/^/  /'
        return 1
    fi
    return 0
}

if seam_list "$FLOW_DIR" | grep -qx "$STRAY"; then
    t_skip help_hooks.stray "'$STRAY' is a declared seam in this checkout, so a file of that name is not stray"
    t_skip help_hooks.stray.mutation "'$STRAY' is a declared seam in this checkout, so a file of that name is not stray"
else
    PM="$SB/proj-stray"
    if t_project "$PM" "$FLOW_DIR"; then
        t_check help_hooks.stray \
            "a $STRAY.tcl in HOOKS_DIR is listed under WILL NEVER RUN, by name" \
            stray_named "$PM" "$FLOW_DIR"
    else
        t_skip help_hooks.stray "could not scaffold a project against this checkout"
    fi

    M="$(t_mutant "$SB" help-hooks-no-stray)"
    PM="$SB/proj-no-stray"
    if t_project "$PM" "$M" \
       && t_mutate "$M" "$HELP_REL" 's|then stray="\$\$stray \$\$b\.tcl"; fi|then :; fi|'; then
        t_check_fail help_hooks.stray.mutation \
            "with the stray-file test neutered, the never-runs assertion goes red" \
            stray_named "$PM" "$M"
    else
        t_skip help_hooks.stray.mutation "could not plant the fault: the stray= line in $HELP_REL has changed shape"
    fi
fi

#=============================================================================
# 4. WITHOUT THE FILE IT REFUSES, AND SAYS WHY
#
# Driven STANDALONE - `make -f mk/help.mk help-hooks`, the fresh-clone form the
# file's own header describes - because inside a project mk/flow.mk refuses to
# parse without seams.txt before help.mk gets a look in. t_seams.sh section 5
# proves that guard. This one is help.mk's own, and it is worth its own proof:
# a shell `while read` loop given a missing file prints one line to stderr and
# carries on, and the recipe would then print "0 seam(s) declared" and exit 0,
# which reads as a flow with no extension points rather than a flow whose
# extension points could not be read.
#=============================================================================
t_head "with seams.txt absent the target refuses and names the file"

## refuses_without_file <toolkit root>
refuses_without_file() {
    local root="$1" out rc=0
    out="$(make --no-print-directory -f "$root/$HELP_REL" help-hooks 2>&1)" || rc=$?
    if ! printf '%s\n' "$out" | grep -qF 'is missing or unreadable'; then
        printf 'no refusal in the output (exit %d):\n' "$rc"
        printf '%s\n' "$out" | head -8 | sed 's/^/  /'
        return 1
    fi
    printf '%s\n' "$out" | grep -qF "$root/$SEAMS_REL" || {
        printf 'the refusal does not name %s:\n' "$root/$SEAMS_REL"
        printf '%s\n' "$out" | head -4 | sed 's/^/  /'
        return 1
    }
    [ "$rc" -ne 0 ] || { printf 'it refused in words and exited 0:\n%s\n' "$out"; return 1; }
    return 0
}

M="$(t_mutant "$SB" help-hooks-no-file)"
rm -f "$M/$SEAMS_REL"
t_check help_hooks.missing \
    "with seams.txt deleted from a copy, the target refuses, names the file, and exits non-zero" \
    refuses_without_file "$M"

M="$(t_mutant "$SB" help-hooks-guard-dead)"
rm -f "$M/$SEAMS_REL"
if t_mutate "$M" "$HELP_REL" "s|\\[ ! -r '\\\$(SEAMS_FILE)' \\]|false|"; then
    t_check_fail help_hooks.missing.mutation \
        "with the readability guard neutered, the target prints an empty list instead and the assertion goes red" \
        refuses_without_file "$M"
else
    t_skip help_hooks.missing.mutation "could not plant the fault: the '[ ! -r \$(SEAMS_FILE) ]' guard in $HELP_REL has changed shape"
fi

#=============================================================================
# 5. THE STEP LIST - NOT PRINTED, SO NOT COMPARED
#
# Recorded as a skip with its reason and never as a pass. CONTRACT section 6.2
# makes `ls flow/steps/*.tcl` the one list of overridable steps; help-hooks
# tells the reader that directory exists and enumerates nothing from it. An
# assertion "the printed step list equals the directory" therefore has nothing
# to read on the left-hand side. If help-hooks ever grows the listing, this
# skip is the line to replace with the same two-direction proof section 1 uses.
#=============================================================================
t_head "the step overrides"

N_STEPS="$(ls "$FLOW_DIR"/flow/steps/*.tcl 2>/dev/null | grep -c .)"
t_skip help_hooks.steps "make help-hooks points at flow/steps/ ($N_STEPS step file(s) in this checkout) and prints no step list, so there is no output to compare with the directory; the engine's own derivation is proved by t_seams.sh section 6"

t_summary
