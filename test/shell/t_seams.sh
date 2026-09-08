#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# t_seams.sh - the extension seams have ONE list, and it is a file
#
# DEFECT CLASS: A SECOND COPY OF A LIST THAT A DIRECTORY OR A FILE ALREADY KNOWS.
#
# This is CONTRACT.md's third rule, and unlike the other two it was not derived
# from first principles - it was measured. The reference ASIC toolkit hardcodes
# a FIVE-entry step-override whitelist against a directory holding SEVEN .tcl
# files. The consequences are the reason this suite exists and the reason it is
# the most important of the three:
#
#   - two real extension points are UNDOCUMENTED. Nothing lists them, so nobody
#     knows they can be overridden.
#   - and if somebody finds them anyway and drops the file in, the checker calls
#     it UNRECOGNISED. A correct override is reported as a mistake, and the file
#     silently never runs.
#
# Neither symptom is an error. Both are stable, quiet and wrong, and they stay
# that way until somebody counts the directory by hand.
#
# WHAT THIS FILE ASSERTS
#   1. flow/common/seams.txt parses, and holds each seam exactly once.
#   2. NO OTHER FILE IN THE REPOSITORY HARDCODES A SEAM LIST. Two shapes are
#      refused: a file naming five or more of the seams (a copy - five is the
#      historical number), and three or more within a three-line window (an
#      enumeration). A file MENTIONING one or two seams in prose is not a copy
#      and is not refused; that is what the documentation is for.
#   3. CONTRACT.md's own copy AGREES with the file. The specification is the one
#      place a second listing is legitimate, and a specification that has drifted
#      from the thing it specifies is this same defect wearing a suit.
#   4. Every seam named in templates/ exists in seams.txt - a template offering a
#      hook at a seam that does not exist ships a file that never runs.
#   5. The engine refuses to run at all without seams.txt.
#   6. The consumers READ the list rather than carrying one: a hook named after
#      the LAST seam in the file is recognised, and a step override is matched
#      against `ls flow/steps/` at run time.
#
# Every one of these is paired with a mutation proof, and two of them plant the
# reference toolkit's exact defect - a five-entry hardcoded list against a
# seven-entry directory - and require this toolkit's checker to be caught by it.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/lib/harness.sh
. "$HERE/../lib/harness.sh"

t_sandbox; SB="$T_SANDBOX"

SEAMS_REL="flow/common/seams.txt"
if [ ! -f "$FLOW_DIR/$SEAMS_REL" ]; then
    t_skip seams.all "$SEAMS_REL is not in this checkout - the one list is absent, so there is nothing to compare anything against. Not a pass"
    t_summary; exit $?
fi

## seam_list <toolkit root>  - the seam names, one per line, from THE file.
## Read here for the same reason every other consumer reads it: writing them out
## in this file would make the anti-drift test the thing that drifted.
seam_list() { awk '!/^[[:space:]]*#/ && NF { print $1 }' "$1/$SEAMS_REL"; }

N_SEAMS="$(seam_list "$FLOW_DIR" | grep -c .)"
t_say "$N_SEAMS seams declared in $SEAMS_REL"

#=============================================================================
# 1. THE FILE ITSELF
#=============================================================================
t_head "the one list parses and declares each seam once"

## seams_wellformed <root>
seams_wellformed() {
    local root="$1" names dups bad
    names="$(seam_list "$root")"
    [ -n "$names" ] || { echo "no seam names in $root/$SEAMS_REL"; return 1; }
    dups="$(printf '%s\n' "$names" | sort | uniq -d)"
    if [ -n "$dups" ]; then
        printf 'declared more than once: %s\n' "$(printf '%s ' $dups)"
        printf 'a duplicate is how a seam comes to run twice, or to be removed once and stay.\n'
        return 1
    fi
    bad="$(printf '%s\n' "$names" | grep -vE '^[a-z][a-z0-9_]*$')"
    if [ -n "$bad" ]; then
        printf 'not a seam name (lower case, underscores, CONTRACT.md 6.1): %s\n' "$bad"
        return 1
    fi
    return 0
}

t_check seams.file.parses "every declared seam is a legal name, declared once" \
    seams_wellformed "$FLOW_DIR"

M="$(t_mutant "$SB" seams-duplicate)"
if seam_list "$FLOW_DIR" | tail -1 >> "$M/$SEAMS_REL"; then
    t_check_fail seams.file.parses.mutation \
        "with one seam declared twice in a copy, the assertion goes red" \
        seams_wellformed "$M"
else
    t_skip seams.file.parses.mutation "could not append a duplicate to the copy's seams.txt"
fi

#=============================================================================
# 2. NO SECOND COPY ANYWHERE IN THE REPOSITORY
#
# The scan takes a ROOT, so it can be pointed at a copy with a hardcoded list
# planted in it. Two files are exempt and each for a stated reason:
#   flow/common/seams.txt  is the list.
#   CONTRACT.md            is the specification, and is cross-checked for
#                          AGREEMENT in section 3 below rather than let off.
#=============================================================================
t_head "no other file in the repository carries a copy of the list"

## _scan_for_list <root> <names> <exempt regex> <what>
##
## THE TWO SHAPES A HARDCODED LIST TAKES, AND A DELIBERATE SPLIT BETWEEN CODE
## AND DOCUMENTATION.
##
##   any file    three or more of the names inside a THREE-LINE WINDOW. That is
##               a list - a make variable, a shell array, a python literal, a
##               bullet list in a README - whatever the file extension is. It is
##               also the shape the reference toolkit's defect took: a
##               five-entry whitelist against a seven-file directory is caught
##               here even though it names fewer than all of them.
##   code only   `min(5, <how many there are>)` or more of the names anywhere in
##               one file: a whole copy. Five is the reference toolkit's
##               whitelist length, and the min() is what keeps the rule
##               meaningful for a list shorter than that - naming every step
##               there is IS a copy of the step list.
##
## The second rule is not applied to `*.md`, and that is not a loophole. The
## copy this exists to stop is THE ONE A PROGRAM READS: a whitelist a checker
## consults, which drifts from the directory in silence. A manual that names
## several seams across nine pages while explaining what each is for is
## documentation, and it fails visibly - a reader who tries to use a seam that
## is not there gets an error from the engine. A RENDERED LIST in a document is
## still caught, by the window rule, because that is the shape that drifts.
##
## MATCHING IS ON WHOLE WORDS, and the first draft of this file used a plain
## substring. One of the step files is called `ila.tcl`, and `ila` is inside
## `similar`, `available` and `Illegal` - so the substring version reported the
## LICENSE file as carrying part of the step list. A scan that cries wolf gets
## deleted, and a deleted scan protects nothing.
_scan_for_list() {
    local root="$1" names="$2" exempt="$3" what="$4"
    local f rel out found=0 whole n
    n="$(printf '%s\n' $names | grep -c .)"
    [ "$n" -gt 0 ] || { echo "no $what to compare against under $root"; return 1; }
    whole=5; [ "$n" -lt 5 ] && whole="$n"
    while IFS= read -r f; do
        rel="${f#"$root"/}"
        printf '%s' "$rel" | grep -qE -- "$exempt" && continue
        case "$rel" in
            *.md) out="$(_scan_file "$f" "$names" 0 "$whole")" ;;
            *)    out="$(_scan_file "$f" "$names" 1 "$whole")" ;;
        esac
        if [ -n "$out" ]; then
            printf '%s: %s\n' "$rel" "$out"
            found=1
        fi
    done < <(find "$root" -path "$root/.git" -prune -o -type f -print | sort)
    [ "$found" -eq 0 ] && return 0
    printf 'CONTRACT.md rule three: never hardcode a list a file or a directory already knows.\n'
    return 1
}

_scan_file() {   # <file> <names> <apply the whole-file rule?> <whole-file threshold>
    # EACH LINE IS SPLIT INTO WORD TOKENS ONCE and the tokens are looked up in a
    # hash. The obvious spelling - match(line, "(^|[^A-Za-z0-9_])" name "...")
    # per line per name - is what the first working draft did, and it took FIFTY
    # SECONDS over 23,000 lines: awk recompiles a regex built from a variable on
    # every single call, which is three quarters of a million compilations. A
    # test suite people wait a minute for is a test suite people stop running.
    awk -v NAMES="$2" -v WHOLE="$3" -v LIMIT="$4" '
        BEGIN { n = split(NAMES, S, " "); for (k = 1; k <= n; k++) IDX[S[k]] = k }
        {
            line = $0
            gsub(/[^A-Za-z0-9_]+/, " ", line)
            m = split(line, W, " ")
            s = ""; delete on
            for (t = 1; t <= m; t++)
                if (W[t] in IDX) {
                    k = IDX[W[t]]
                    if (!(k in on)) { on[k] = 1; s = s k " "; ANY[k] = 1 }
                }
            H[NR] = s
        }
        END {
            tot = 0; for (k in ANY) tot++
            max = 0
            for (i = 1; i <= NR; i++) {
                delete seen; c = 0
                for (j = i; j < i + 3 && j <= NR; j++) {
                    cnt = split(H[j], A, " ")
                    for (x = 1; x <= cnt; x++)
                        if (!(A[x] in seen)) { seen[A[x]] = 1; c++ }
                }
                if (c > max) { max = c; at = i }
            }
            if (WHOLE + 0 && tot >= LIMIT + 0)
                printf "names %d of the %d - that is a second copy of the list\n", tot, n
            else if (max >= 3)
                printf "%d of them inside three lines at line %d - that is an enumeration\n", max, at
        }' "$1" 2>/dev/null
}

## no_hardcoded_seam_list <root>
## Exempt: seams.txt is the list; CONTRACT.md is the specification, and is
## cross-checked for AGREEMENT below rather than let off.
no_hardcoded_seam_list() {
    _scan_for_list "$1" "$(seam_list "$1" | tr '\n' ' ')" \
        '^(flow/common/seams\.txt|CONTRACT\.md)$' "seams" \
        || { printf 'The flow, the checker and `make help` all read %s.\n' "$SEAMS_REL"; return 1; }
}

t_check seams.nocopy "nothing outside seams.txt and CONTRACT.md enumerates the seams" \
    no_hardcoded_seam_list "$FLOW_DIR"

# -- mutation proof 1: the whole list, copied into a make fragment ------------
M="$(t_mutant "$SB" seams-copy-full)"
{ printf '# a second copy of the seam list, planted by t_seams.sh\n'
  printf 'FPGA_SEAMS := %s\n' "$(seam_list "$FLOW_DIR" | tr '\n' ' ')"
} > "$M/mk/drift.mk"
t_check_fail seams.nocopy.mutation.full \
    "with the whole list copied into a make fragment, the scan goes red" \
    no_hardcoded_seam_list "$M"

# -- mutation proof 2: the reference toolkit's exact shape -------------------
# FIVE entries, one per line, against a list of eleven. This is the defect
# CONTRACT.md rule three was written from, and the scan has to catch it at
# exactly five - which is why the threshold is five and not "most of them".
M="$(t_mutant "$SB" seams-copy-five)"
{ printf '# a five-entry whitelist, planted by t_seams.sh\n'
  seam_list "$FLOW_DIR" | head -5 | sed 's/^/    valid_seam /'
} > "$M/scripts/drift-whitelist.sh"
t_check_fail seams.nocopy.mutation.five \
    "with a FIVE-entry whitelist planted - the reference toolkit's own number - the scan goes red" \
    no_hardcoded_seam_list "$M"

#=============================================================================
# 3. THE SPECIFICATION'S COPY MUST AGREE WITH THE FILE
#=============================================================================
t_head "CONTRACT.md section 6.1 and seams.txt say the same thing"

## contract_seams <root> - the fenced list under 'Phase-1 seams:'
contract_seams() {
    awk '/Phase-1 seams:/ { seen = 1; next }
         seen && /^```/   { n++; if (n == 2) exit; next }
         seen && n == 1   { for (i = 1; i <= NF; i++) print $i }' "$1/CONTRACT.md"
}

## contract_agrees <root>
contract_agrees() {
    local root="$1" a b
    a="$(seam_list "$root" | sort)"
    b="$(contract_seams "$root" | sort)"
    if [ "$a" = "$b" ]; then return 0; fi
    printf 'CONTRACT.md section 6.1 and %s disagree:\n' "$SEAMS_REL"
    diff <(printf '%s\n' "$b") <(printf '%s\n' "$a") | sed 's/^/  /'
    printf 'left = the specification, right = the file the engine reads.\n'
    return 1
}

if [ -z "$(contract_seams "$FLOW_DIR")" ]; then
    t_skip seams.contract "no fenced seam list under 'Phase-1 seams:' in CONTRACT.md - the specification's copy could not be located, so agreement was NOT checked"
else
    t_check seams.contract "the specification's list is exactly the engine's list" \
        contract_agrees "$FLOW_DIR"

    M="$(t_mutant "$SB" contract-drift)"
    if t_mutate "$M" "$SEAMS_REL" '$d'; then
        t_check_fail seams.contract.mutation \
            "with one seam removed from the copy's seams.txt, the agreement check goes red" \
            contract_agrees "$M"
    else
        t_skip seams.contract.mutation "could not remove a line from the copy's seams.txt"
    fi
fi

#=============================================================================
# 4. EVERY SEAM THE TEMPLATES OFFER A HOOK AT EXISTS
#
# A template that offers a hook at a seam the engine does not declare ships a
# file that never runs - the same silent nothing as a hook misspelt by hand,
# except that the toolkit shipped it, so nobody suspects it.
#
# WHAT COUNTS AS "NAMED", precisely: a hook FILE - `<seam>.tcl` anywhere in the
# templates, and every `<name>.tcl[.in]` file sitting in templates/hooks/. Those
# are the offers. A seam mentioned in prose is not one, and the distinction is
# load-bearing rather than lenient: templates/hooks/README.md tells the story of
# the reference toolkit's `post_route` hook streaming a GDS with no pad ring,
# and that paragraph is exactly the kind of thing this repository should carry.
# `post_route.tcl` in the same file would be a different claim - that you may
# put a file there - and it would be false.
#=============================================================================
t_head "every seam the templates offer a hook AT exists"

## templates_name_real_seams <root>
templates_name_real_seams() {
    local root="$1" seams tok f bad=""
    [ -d "$root/templates" ] || { echo "no templates/ in $root"; return 1; }
    seams="$(seam_list "$root")"
    # (a) every `<seam>.tcl` token anywhere in templates/
    while IFS= read -r tok; do
        [ -n "$tok" ] || continue
        printf '%s\n' "$seams" | grep -qx -- "${tok%.tcl}" || bad="$bad $tok"
    done < <(grep -rhoE '\b(pre|post)_[a-z][a-z0-9_]*\.tcl' "$root/templates" 2>/dev/null | sort -u)
    # (b) every hook file the templates actually ship
    if [ -d "$root/templates/hooks" ]; then
        for f in "$root"/templates/hooks/*.tcl "$root"/templates/hooks/*.tcl.in; do
            [ -e "$f" ] || continue
            tok="$(basename "$f")"; tok="${tok%.in}"; tok="${tok%.tcl}"
            printf '%s\n' "$seams" | grep -qx -- "$tok" || bad="$bad $(basename "$f")"
        done
    fi
    [ -z "$bad" ] && return 0
    printf 'templates/ offers a hook at seam(s) %s does not declare:%s\n' "$SEAMS_REL" "$bad"
    printf 'A hook file at a seam the engine does not know NEVER RUNS, and nothing says so.\n'
    return 1
}

t_check seams.templates "every seam a template offers a hook at is a declared seam" \
    templates_name_real_seams "$FLOW_DIR"

# The planted name is the reference toolkit's `post_route`, which CONTRACT.md
# section 6.1 and templates/hooks/README.md both name as the trap this flow
# renamed. It is the drift that would actually happen: somebody copies a hook
# across from the ASIC toolkit, where that seam is real.
M="$(t_mutant "$SB" template-bad-seam)"
mkdir -p "$M/templates/hooks"
printf '# an example hook, offered at post_route.tcl\n' > "$M/templates/hooks/example.tcl.in"
t_check_fail seams.templates.mutation.mention \
    "with a template offering a hook at the ASIC toolkit's post_route, the assertion goes red" \
    templates_name_real_seams "$M"

M="$(t_mutant "$SB" template-bad-hook-file)"
mkdir -p "$M/templates/hooks"
printf '# a hook file at a seam this engine does not declare\n' > "$M/templates/hooks/post_route.tcl"
t_check_fail seams.templates.mutation.file \
    "and with a post_route.tcl SHIPPED in templates/hooks/, it goes red too" \
    templates_name_real_seams "$M"

#=============================================================================
# 5. THE ENGINE REFUSES WITHOUT THE FILE
#
# The planted fault here is the file's ABSENCE. If the engine ran anyway, every
# project hook would silently never run and the build would be shaped by none of
# the project code that was meant to shape it - with a green manifest.
#=============================================================================
t_head "a toolkit with no seams.txt refuses to run"

env_ok() { make -C "$1" --no-print-directory env >/dev/null 2>&1; }

M="$(t_mutant "$SB" seams-deleted)"
PM="$SB/proj-seams-deleted"
if t_project "$PM" "$M"; then
    if [ -n "$(seam_list "$FLOW_DIR")" ] && env_ok "$PM"; then
        rm -f "$M/$SEAMS_REL"
        t_check_fail seams.required \
            "with seams.txt deleted from a copy, the parse is refused rather than silently seamless" \
            env_ok "$PM"
    else
        t_skip seams.required "a well-formed project does not complete a parse in this checkout even with seams.txt present (mk/checks.mk, mk/help.mk or mk/hooks.mk missing), so deleting it would prove nothing"
    fi
else
    t_skip seams.required "could not scaffold a project against the copied toolkit"
fi

#=============================================================================
# 6. THE CONSUMERS READ THE LISTS, THEY DO NOT CARRY THEM
#
# Sections 2 and 3 are static: they look for a copy. This section is functional:
# it plants the reference toolkit's defect INSIDE a consumer and requires the
# consumer to get the answer wrong - which is what shows the passing case was
# reading the file and the directory rather than agreeing by coincidence.
#=============================================================================
t_head "the checker reads seams.txt and ls flow/steps/ at run time"

CHECK_REL="scripts/fpga-flow-check"
if ! command -v python3 >/dev/null 2>&1; then
    t_skip seams.consumer "python3 is not on this host, and $CHECK_REL is the consumer that can be driven without an EDA tool"
elif [ ! -f "$FLOW_DIR/$CHECK_REL" ]; then
    t_skip seams.consumer "$CHECK_REL is not in this checkout - the consumer that reads the list is absent"
elif [ "$N_SEAMS" -lt 6 ]; then
    t_skip seams.consumer "only $N_SEAMS seams are declared; this proof plants a five-entry hardcoded list and needs a sixth seam to be missed by it"
else
    LAST_SEAM="$(seam_list "$FLOW_DIR" | tail -1)"

    ## hook_recognised <root> - a hook named after the LAST declared seam is
    ## matched. A consumer carrying a truncated list gets this wrong.
    hook_recognised() {
        local root="$1" h="$SB/hooks.$RANDOM" out
        mkdir -p "$h"; : > "$h/$LAST_SEAM.tcl"
        out="$(python3 "$root/$CHECK_REL" --var FPGA_FLOW_DIR="$root" \
                 --var BLOCK=demo_block --var BOARD=demo_board \
                 --var HOOKS_DIR="$h" 2>&1)"
        if printf '%s\n' "$out" | grep -qF 'unrecognised file(s) in hooks/'; then
            printf 'the checker called %s.tcl unrecognised - it is declared in %s:\n' \
                "$LAST_SEAM" "$SEAMS_REL"
            printf '%s\n' "$out" | grep -iE 'hook|seam' | sed 's/^/  /'
            return 1
        fi
        printf '%s\n' "$out" | grep -qE "^  ok +hooks .*$LAST_SEAM" && return 0
        printf 'the checker did not report the hook at all:\n'
        printf '%s\n' "$out" | grep -iE 'hook|seam' | sed 's/^/  /'
        return 1
    }

    t_check seams.consumer.hook \
        "a hook named after the last declared seam is recognised" \
        hook_recognised "$FLOW_DIR"

    # THE PLANTED FAULT: read_seams returns a hardcoded five-entry list instead
    # of reading the file. Generated from seams.txt so this test file still
    # contains no seam name of its own.
    M="$(t_mutant "$SB" seams-hardcoded-consumer)"
    FIVE="$(seam_list "$FLOW_DIR" | head -5 | sed 's/.*/"&"/' | paste -sd, -)"
    if t_replace_line "$M" "$CHECK_REL" \
        '    return [s for s in meaningful_lines(text, "#")], path' \
        "    return [$FIVE], path"; then
        t_check_fail seams.consumer.hook.mutation \
            "with a five-entry seam list hardcoded in the checker, a real seam is called unrecognised" \
            hook_recognised "$M"
    else
        t_skip seams.consumer.hook.mutation "could not plant the fault: read_seams() in $CHECK_REL has changed shape"
    fi

    #-------------------------------------------------------------------------
    # STEP OVERRIDES: the list is `ls flow/steps/*.tcl`, derived at run time.
    #
    # The static half of this cannot run here: flow/steps/ holds no .tcl files
    # in this checkout, so there are no step NAMES for a scan like section 2's
    # to look for. That is reported as a skip with its reason. The functional
    # half does not depend on the directory's current contents - it plants
    # SEVEN steps and a FIVE-entry whitelist, which is the measured defect
    # exactly - so it runs either way.
    #-------------------------------------------------------------------------
    ## step_list <root> - the overridable steps, from `ls flow/steps/*.tcl`.
    ## Derived here exactly as every consumer derives it, and for the same
    ## reason: an anti-drift test that carried its own copy would be the drift.
    step_list() {
        local f
        for f in "$1"/flow/steps/*.tcl; do [ -e "$f" ] || continue
            f="$(basename "$f")"; printf '%s\n' "${f%.tcl}"
        done
    }

    ## no_hardcoded_step_list <root>
    ## Exempt: flow/steps/ itself. A step file whose header explains which other
    ## steps run either side of it is documenting an order, not maintaining a
    ## whitelist, and the directory it lives in cannot drift from itself.
    no_hardcoded_step_list() {
        _scan_for_list "$1" "$(step_list "$1" | tr '\n' ' ')" \
            '^flow/steps/' "steps" \
            || { printf 'CONTRACT section 6.2: the valid step list is `ls flow/steps/*.tcl`, derived at run time.\n'; return 1; }
    }

    N_STEPS="$(step_list "$FLOW_DIR" | grep -c .)"
    if [ "$N_STEPS" -eq 0 ]; then
        t_skip seams.steps.nocopy "flow/steps/ holds no .tcl files in this checkout, so there are no step names for a hardcoded-copy scan to search for. The functional proof below plants its own"
    else
        t_say "flow/steps/ holds $N_STEPS step file(s)"
        t_check seams.steps.nocopy \
            "nothing outside flow/steps/ enumerates the step names" \
            no_hardcoded_step_list "$FLOW_DIR"

        # The reference defect's own shape, in the step dimension: a whitelist
        # in a file that is not the directory.
        M="$(t_mutant "$SB" steps-copy)"
        { printf '# a second copy of the step list, planted by t_seams.sh\n'
          printf 'FPGA_STEPS := %s\n' "$(step_list "$FLOW_DIR" | tr '\n' ' ')"
        } > "$M/mk/step-drift.mk"
        t_check_fail seams.steps.nocopy.mutation.full \
            "with the whole step list copied into a make fragment, the scan goes red" \
            no_hardcoded_step_list "$M"

        M="$(t_mutant "$SB" steps-copy-partial)"
        { printf '# a partial whitelist, planted by t_seams.sh\n'
          step_list "$FLOW_DIR" | head -3 | sed 's/^/    valid_step /'
        } > "$M/scripts/step-drift.sh"
        t_check_fail seams.steps.nocopy.mutation.partial \
            "and with a PARTIAL whitelist - the shape that undocuments the rest - it goes red too" \
            no_hardcoded_step_list "$M"
    fi

    ## override_recognised <root> - seven steps in the directory, an override
    ## for the SEVENTH. A consumer with a five-entry whitelist calls it
    ## unrecognised and the file silently never runs.
    override_recognised() {
        local root="$1" o="$SB/ovr.$RANDOM" out s
        mkdir -p "$o"; : > "$o/step_g.tcl"
        for s in step_a step_b step_c step_d step_e step_f step_g; do
            [ -f "$root/flow/steps/$s.tcl" ] || printf '# planted step\n' > "$root/flow/steps/$s.tcl"
        done
        out="$(python3 "$root/$CHECK_REL" --var FPGA_FLOW_DIR="$root" \
                 --var BLOCK=demo_block --var BOARD=demo_board \
                 --var OVERRIDES_DIR="$o" 2>&1)"
        if printf '%s\n' "$out" | grep -qF 'unrecognised file(s) in overrides/'; then
            printf 'the checker called step_g.tcl unrecognised, against a directory holding seven steps:\n'
            printf '%s\n' "$out" | grep -iE 'override|step' | sed 's/^/  /'
            return 1
        fi
        printf '%s\n' "$out" | grep -qE '^ WARN +step overrides ACTIVE +step_g$' && return 0
        printf 'the checker did not report the override as active:\n'
        printf '%s\n' "$out" | grep -iE 'override|step' | sed 's/^/  /'
        return 1
    }

    # The seven steps are planted in a COPY - flow/steps/ in the real checkout
    # belongs to whoever is writing the stage scripts, not to this suite.
    M="$(t_mutant "$SB" steps-seven)"
    t_check seams.steps.override \
        "an override for the seventh of seven steps is recognised, because the list is the directory" \
        override_recognised "$M"

    M="$(t_mutant "$SB" steps-hardcoded)"
    if t_replace_line "$M" "$CHECK_REL" \
        '    return sorted(f[:-4] for f in os.listdir(d) if f.endswith(".tcl")), d' \
        '    return ["step_a", "step_b", "step_c", "step_d", "step_e"], d'; then
        t_check_fail seams.steps.override.mutation \
            "with a FIVE-entry step whitelist against a SEVEN-file directory - the reference toolkit's measured defect - the assertion goes red" \
            override_recognised "$M"
    else
        t_skip seams.steps.override.mutation "could not plant the fault: read_steps() in $CHECK_REL has changed shape"
    fi
fi

t_summary
