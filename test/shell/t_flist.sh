#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# t_flist.sh - flow/common/read_flist.tcl: the filelist IS the configuration
#
# DEFECT CLASS: A READER THAT SILENTLY BUILDS A DIFFERENT DESIGN.
#
# CONTRACT.md section 9.1: there is no `ifdef FPGA and no `ifdef ASIC anywhere
# in this codebase, so WHICH FILES THE FLIST NAMES *IS* THE CONFIGURATION. Every
# way this reader can quietly drop, mis-dialect or fail to find one of them is a
# way to synthesise, place, route and write a bitstream for a design nobody
# asked for - and Vivado reports every one of those as a WARNING at worst.
#
# The regression that matters most is the one read_flist.tcl's own header is
# written from: THE REFERENCE ASIC TOOLKIT'S READER DROPPED ALL BUT ONE
# `+incdir+`. Measured on the compute chiplet's tapeout filelist - 41 `+incdir+`
# lines across 10 nested `-f` sub-flists, one surviving include directory,
# headers resolving by accident of flist order. Vivado's `set_property
# include_dirs` has exactly the same replace-not-append shape, so the defect
# transplants without modification. The assertion below therefore asserts on the
# COUNT, and its mutation proof plants the exact fault (`lappend` -> `set`,
# which leaves precisely the last directory standing).
#
# Everything here runs under bare `tclsh` against the reader's standalone CLI,
# which exists so that this suite can exist: a reader that can only be tested by
# launching Vivado is a reader nobody tests.
#
# Every assertion is PAIRED WITH A MUTATION PROOF: plant one fault in a
# throwaway copy, show the same assertion goes red, throw the copy away. Each
# mutation is applied with t_replace_line / t_mutate, which FAIL LOUDLY when
# they change nothing - because the failure mode of a mutation proof is that the
# edit silently did not apply, the command under test then fails for an
# unrelated reason, and t_check_fail reports `ok` on a proof that proved
# nothing. That has already happened once in this directory; see the note above
# the last proof in t_verdicts.sh. Every mutation below is therefore applied
# through the harness and its return value is honoured - a fault that could not
# be planted is a SKIP WITH THE REASON, never a silent pass.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/lib/harness.sh
. "$HERE/../lib/harness.sh"

t_sandbox; SB="$T_SANDBOX"

#-----------------------------------------------------------------------------
# WHAT MUST BE PRESENT BEFORE ANY OF THIS MEASURES ANYTHING.
#
# A missing file and a missing interpreter are SKIPS WITH THE REASON, never
# passes: several files in this repository are being written concurrently, and a
# suite that reported green against a reader that had not landed would be
# reporting on nothing.
#-----------------------------------------------------------------------------
RF="$FLOW_DIR/flow/common/read_flist.tcl"
if [ ! -f "$RF" ]; then
    t_skip flist.all "no flow/common/read_flist.tcl at $RF - nothing to test, and an absent file is not a passing one"
    t_summary; exit $?
fi
if ! command -v tclsh >/dev/null 2>&1; then
    t_skip flist.all "no tclsh on PATH - the reader's standalone CLI is the only tool-free way to drive it, so nothing here can run"
    t_summary; exit $?
fi
# The reader emits `read_verilog [list $path]`, and Tcl's `list` BRACES a path
# containing a space. Every assertion below greps for the unbraced spelling, so
# a sandbox under a path with a space in it would go red for a reason that has
# nothing to do with the reader. Say so rather than report that.
case "$SB" in
    *" "*)
        t_skip flist.all "the sandbox path '$SB' contains a space, so Tcl's list would brace every emitted path while these assertions grep for the unbraced spelling"
        t_summary; exit $? ;;
esac

#=============================================================================
# THE FIXTURE
#
# A filelist chain shaped like a real one: three levels of `-f`, one `+incdir+`
# contributed by each level (the reference defect's shape, scaled down from 41),
# all three dialects, and a `-y` library directory holding one compilation unit
# and one include fragment.
#=============================================================================
F="$SB/fl"
mkdir -p "$F/rtl" "$F/inc1" "$F/inc2" "$F/inc3" "$F/lib" "$F/deep/nested"

printf 'module a_top; endmodule\n'                 > "$F/rtl/a.v"
printf 'module b_sv; logic x; endmodule\n'         > "$F/rtl/b.sv"
printf 'entity c_vhd is end entity;\n'             > "$F/rtl/c.vhd"
printf '`define H1 1\n'                            > "$F/inc1/h1.vh"
printf '`define H2 1\n'                            > "$F/inc2/h2.vh"
printf '`define H3 1\n'                            > "$F/inc3/h3.vh"
printf 'module lib_unit; endmodule\n'              > "$F/lib/lib_unit.v"
# NO module/package/interface/entity: an `include fragment of the kind every
# vendor -y deliverable ships. Reading one as a source is a syntax error.
printf '`define LIB_FRAGMENT 1\n`undef  LIB_FRAGMENT\n' > "$F/lib/frag_defs.v"
printf 'module deep_unit; endmodule\n'             > "$F/deep/nested/d.v"

# top -> sub -> subsub, one +incdir+ per level.
cat > "$F/top.f" <<EOF
# a whole-line comment, and a trailing one below
+incdir+inc1
rtl/a.v            // trailing comment after whitespace
-f sub.f
EOF
cat > "$F/sub.f" <<EOF
+incdir+inc2
rtl/b.sv
-f subsub.f
EOF
cat > "$F/subsub.f" <<EOF
+incdir+inc3
rtl/c.vhd
-y lib
EOF

# A nested flist in ANOTHER directory, naming its source relative to ITSELF.
# mk/flow.mk cd's every stage to WORK_DIR, so cwd-relative resolution alone
# reads a directory that holds nothing.
printf 'nested/d.v\n' > "$F/deep/deep.f"
printf 'rtl/a.v\n-f deep/deep.f\n' > "$F/nest.f"

# ${VAR}, $(VAR) and $VAR, all three spellings, in one file.
printf '${RT}/a.v\n$(RT)/b.sv\n$RT/c.vhd\n' > "$F/vars.f"

printf 'rtl/a.v\n${FLIST_TEST_UNSET_VAR}/nowhere.v\n' > "$F/unsetvar.f"
printf 'rtl/a.v\nrtl/does_not_exist.v\n'              > "$F/missing.f"
printf -- '-f cyc_b.f\n' > "$F/cyc_a.f"
printf -- '-f cyc_a.f\n' > "$F/cyc_b.f"
printf 'rtl/a.v\n+notimingcheck\n'                    > "$F/unknownopt.f"
printf 'rtl/a.v\n-timescale 1ns/1ps\n'                > "$F/simopt.f"
printf '+incdir+rtl/a.v\nrtl/a.v\n'                   > "$F/incdir_is_a_file.f"

# An unrecognised option followed on the SAME LINE by something that looks like
# a source. The absorption rule must not touch these: one is a real file and the
# other is a MISSING one, and swallowing either as an option argument is a source
# silently dropped, which is rule 0.
# A SECOND source, so that swallowing the first does not collapse the run to
# "zero source files" - which would refuse for its own reason and let the proof
# below pass while measuring something else.
printf -- 'rtl/b.sv\n-nospecify rtl/a.v\n'            > "$F/optarg_src.f"
printf -- 'rtl/a.v\n-nospecify rtl/does_not_exist.v\n' > "$F/optarg_missing.f"

# One path, named twice, in one filelist. Read ONCE and reported as absorbed.
printf 'rtl/a.v\nrtl/a.v\n'                           > "$F/dup.f"

# The chain flist_apply is driven over: three +incdir+ across three levels and a
# +define+, so "applied" and "collected" are different measurements.
cat > "$F/apply.f" <<EOF
+incdir+inc1
+define+FLIST_TEST_D1
rtl/a.v
-f sub.f
EOF

#=============================================================================
# DRIVING THE READER
#
# Every predicate takes the toolkit as its FIRST ARGUMENT, so the identical
# predicate can be pointed at $FLOW_DIR and at a mutant. That is the whole
# mechanism: a proof that ran a different command against the mutant would be
# measuring the command, not the guard.
#
# `timeout` because one of the faults planted below removes the `-f` cycle
# guard and the unguarded reader recurses. A suite that hangs is a suite that
# gets killed rather than read.
#=============================================================================
RF_OUT=""
## rf_rc <toolkit> <args...> - run, leave the output in RF_OUT, return the status
rf_rc() {
    local tk="$1"; shift
    local rc=0
    RF_OUT="$(timeout 60 tclsh "$tk/flow/common/read_flist.tcl" "$@" 2>&1)" || rc=$?
    return $rc
}

#=============================================================================
# 1. EVERY +incdir+ SURVIVES - THE REFERENCE TOOLKIT'S MEASURED DEFECT
#=============================================================================
t_head "+incdir+ across a -f chain: ALL of them survive, in ONE emission"

## incdirs_all_survive <toolkit>
incdirs_all_survive() {
    local tk="$1" line n=0 d
    if ! rf_rc "$tk" -q "$F/top.f"; then
        printf 'the reader refused a well-formed filelist:\n%s\n' "$RF_OUT"; return 1
    fi
    line="$(printf '%s\n' "$RF_OUT" | grep -m1 '^set_property include_dirs ')"
    if [ -z "$line" ]; then
        printf 'no include_dirs assignment was emitted at all:\n%s\n' "$RF_OUT"; return 1
    fi
    for d in inc1 inc2 inc3; do
        printf '%s' "$line" | grep -qF -- "$F/$d" && n=$((n + 1))
    done
    if [ "$n" -ne 3 ]; then
        printf 'only %d of 3 +incdir+ directories survived the -f chain.\n' "$n"
        printf 'That is the reference toolkit defect: 41 +incdir+ lines, ONE surviving directory.\n'
        printf '%s\n' "$line"
        return 1
    fi
    return 0
}

## incdirs_emitted_once <toolkit>
## One assignment, not one per line. `set_property include_dirs` REPLACES the
## property, so N assignments leave the Nth standing - which is how the count
## above can be right in the reader and wrong inside the tool.
incdirs_emitted_once() {
    local tk="$1" n
    rf_rc "$tk" -q "$F/top.f" || { printf '%s\n' "$RF_OUT"; return 1; }
    n="$(printf '%s\n' "$RF_OUT" | grep -c '^set_property include_dirs ')"
    [ "$n" -eq 1 ] && return 0
    printf '%s include_dirs assignments were emitted, not 1. set_property REPLACES this\n' "$n"
    printf 'property, so all but the last would be lost inside Vivado:\n%s\n' "$RF_OUT"
    return 1
}

t_check flist.incdir.all_survive \
    "three +incdir+ across three nested filelists all reach the fileset" \
    incdirs_all_survive "$FLOW_DIR"
t_check flist.incdir.one_emission \
    "and they arrive as ONE assignment, because set_property replaces the property" \
    incdirs_emitted_once "$FLOW_DIR"

# -- mutation proof: THE EXACT REFERENCE DEFECT -------------------------------
# `lappend` -> `set`. The de-duplication test in front of it still passes (a
# one-element list never contains the next directory), so each +incdir+ replaces
# the previous one and EXACTLY THE LAST survives: three collected, one emitted.
M="$(t_mutant "$SB" incdir-set)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/read_flist.tcl \
        '                        lappend ::flist_incdirs $r' \
        '                        set ::flist_incdirs $r'; then
    t_check_fail flist.incdir.all_survive.mutation \
        "with lappend weakened to set - the reference toolkit's fault - only the LAST +incdir+ survives and the assertion goes red" \
        incdirs_all_survive "$M"
else
    t_skip flist.incdir.all_survive.mutation \
        "could not plant the fault: the 'lappend ::flist_incdirs \$r' line in flist_scan() has changed shape"
fi

#=============================================================================
# 2. NESTED -f, AND WHAT A RELATIVE PATH IS RELATIVE TO
#=============================================================================
t_head "nested -f: the sub-flist is read, and its paths resolve against ITSELF"

## nested_f_read <toolkit>
nested_f_read() {
    local tk="$1"
    rf_rc "$tk" -q "$F/nest.f" || { printf 'the reader refused:\n%s\n' "$RF_OUT"; return 1; }
    printf '%s\n' "$RF_OUT" | grep -qF -- "$F/rtl/a.v" || {
        printf 'the top-level source was not read:\n%s\n' "$RF_OUT"; return 1; }
    printf '%s\n' "$RF_OUT" | grep -qF -- "$F/deep/nested/d.v" && return 0
    printf 'the -f sub-flist in another directory contributed NOTHING. Its source is\n'
    printf 'silently absent, which elaborates as a black box Vivado warns about and builds:\n%s\n' "$RF_OUT"
    return 1
}

t_check flist.nested_f \
    "a -f sub-flist in another directory is read, and its relative source resolves against that directory" \
    nested_f_read "$FLOW_DIR"

M="$(t_mutant "$SB" no-nested-f)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/read_flist.tcl \
        '                flist_sources [flist_resolve [flist_expand_env [lindex $toks $i] $where] $flist]' \
        '                set __mutation_dropped_the_sub_flist 1'; then
    t_check_fail flist.nested_f.mutation \
        "with pass 2's -f recursion removed the sub-flist's sources vanish, so the assertion goes red" \
        nested_f_read "$M"
else
    t_skip flist.nested_f.mutation \
        "could not plant the fault: the -f recursion line in flist_sources() has changed shape"
fi

# The other half of the same behaviour: `-F` semantics applied to `-f`. Drop the
# flist-relative attempt and only the cwd attempt remains - and the cwd is a run
# directory holding nothing, because mk/flow.mk cd's the stage there.
M="$(t_mutant "$SB" cwd-relative-only)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/read_flist.tcl \
        '    set a [file normalize [file join [file dirname $fromflist] $path]]' \
        '    set a [file normalize $path]'; then
    t_check_fail flist.nested_f.mutation.relative \
        "with flist-relative resolution reduced to cwd-relative, the sub-flist's source is not found and the assertion goes red" \
        nested_f_read "$M"
else
    t_skip flist.nested_f.mutation.relative \
        "could not plant the fault: flist_resolve()'s flist-relative line has changed shape"
fi

#=============================================================================
# 3. ${VAR}, $(VAR) AND $VAR
#=============================================================================
t_head "all three variable spellings expand"

## vars_expand <toolkit> - one spelling per line, all three must be read
vars_expand() {
    local tk="$1" rc=0 p
    RF_OUT="$(RT="$F/rtl" timeout 60 tclsh "$tk/flow/common/read_flist.tcl" -q "$F/vars.f" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'the reader refused a filelist using ${VAR}, $(VAR) and $VAR (exit %d):\n%s\n' "$rc" "$RF_OUT"
        return 1
    fi
    for p in rtl/a.v rtl/b.sv rtl/c.vhd; do
        printf '%s\n' "$RF_OUT" | grep -qF -- "$F/$p" || {
            printf '%s did not survive expansion:\n%s\n' "$p" "$RF_OUT"; return 1; }
    done
    return 0
}

t_check flist.vars.expand \
    "\${VAR}, \$(VAR) and \$VAR all expand, so a generated filelist can be -f'd instead of flattened" \
    vars_expand "$FLOW_DIR"

# Kill the ${VAR} alternative ONLY. $(VAR) and $VAR still work, so a suite that
# had tested a single spelling would stay green - which is why all three are in
# one fixture file.
M="$(t_mutant "$SB" no-brace-var)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/read_flist.tcl \
        '        if {![regexp -- {^\$\{([A-Za-z_][A-Za-z0-9_]*)\}} $rest m name] &&' \
        '        if {![regexp -- {^\$ZZ_MUTATION_NEVER_MATCHES_ZZ} $rest m name] &&'; then
    t_check_fail flist.vars.expand.mutation.brace \
        "with the \${VAR} branch removed the braced spelling passes through unexpanded, so the assertion goes red" \
        vars_expand "$M"
else
    t_skip flist.vars.expand.mutation.brace \
        "could not plant the fault: the \${VAR} regexp in flist_expand_env() has changed shape"
fi

M="$(t_mutant "$SB" var-value-lost)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/read_flist.tcl \
        '        append out $::env($name)' \
        '        append out "ZZ_MUTATION_ATE_THE_VALUE_ZZ"'; then
    t_check_fail flist.vars.expand.mutation.value \
        "with the substituted value replaced by junk every expanded path misses, so the assertion goes red" \
        vars_expand "$M"
else
    t_skip flist.vars.expand.mutation.value \
        "could not plant the fault: the substitution line in flist_expand_env() has changed shape"
fi

#=============================================================================
# 4. AN UNRESOLVED ${VAR} IS A REFUSAL THAT NAMES THE VARIABLE
#
# Exit 2 SPECIFICALLY - CONTRACT.md section 10: 1 is "a check failed", 2 is "the
# input is unusable and nothing was measured" - and the variable named. A path
# that silently collapses to "/nowhere.v" is read as a missing file at the END
# of elaboration and looks like a broken link rather than a missing export.
#=============================================================================
t_head "an unset \${VAR} refuses (exit 2) and NAMES the variable"

## unset_var_named <toolkit>
unset_var_named() {
    local tk="$1" rc=0
    # Explicitly unset in the child, so this cannot pass because of the parent.
    RF_OUT="$(env -u FLIST_TEST_UNSET_VAR timeout 60 tclsh "$tk/flow/common/read_flist.tcl" -q "$F/unsetvar.f" 2>&1)" || rc=$?
    if [ "$rc" -ne 2 ]; then
        printf 'exit %d, not 2 (refused / unusable input):\n%s\n' "$rc" "$RF_OUT"; return 1
    fi
    printf '%s' "$RF_OUT" | grep -qF 'FLIST_TEST_UNSET_VAR' && return 0
    printf 'the refusal does not NAME the variable, so the reader of the log has to grep a\n'
    printf 'chain of filelists to find which one mentioned it:\n%s\n' "$RF_OUT"
    return 1
}

t_check flist.unset_var \
    "an unset \${VAR} exits 2 and names the variable, not just the collapsed path" \
    unset_var_named "$FLOW_DIR"

# THE REFERENCE DEFECT: an unset variable expands to EMPTY. Two lines, ONE
# fault - the guard and the read it protects have to move together, because
# leaving the read alone throws a raw Tcl error instead of expanding to nothing,
# which is a different and much louder failure than the one being planted.
M="$(t_mutant "$SB" unset-var-silent)"
MUT_OK=0
if [ -n "$M" ] && t_replace_line "$M" flow/common/read_flist.tcl \
        '        if {![info exists ::env($name)] || [string trim $::env($name)] eq ""} {' \
        '        if {$name eq "ZZ_MUTATION_NEVER_REFUSES_ZZ"} {'; then
    if t_replace_line "$M" flow/common/read_flist.tcl \
            '        append out $::env($name)' \
            '        if {[info exists ::env($name)]} { append out $::env($name) }'; then
        MUT_OK=1
    fi
fi
if [ "$MUT_OK" = 1 ]; then
    t_check_fail flist.unset_var.mutation \
        "with an unset variable expanding to EMPTY the refusal names a collapsed path instead of the variable, so the assertion goes red" \
        unset_var_named "$M"
else
    t_skip flist.unset_var.mutation \
        "could not plant the fault: the unset-variable guard or the substitution line in flist_expand_env() has changed shape"
fi

#=============================================================================
# 5. A MISSING SOURCE FILE IS A REFUSAL THAT NAMES THE PATH
#=============================================================================
t_head "a missing source refuses (exit 2) and NAMES the path"

## missing_file_named <toolkit>
missing_file_named() {
    local tk="$1" rc=0
    rf_rc "$tk" -q "$F/missing.f" || rc=$?
    if [ "$rc" -ne 2 ]; then
        printf 'exit %d, not 2 (refused / unusable input):\n%s\n' "$rc" "$RF_OUT"; return 1
    fi
    printf '%s' "$RF_OUT" | grep -qF 'does_not_exist.v' && return 0
    printf 'the refusal does not name the path that is missing:\n%s\n' "$RF_OUT"
    return 1
}

t_check flist.missing_source \
    "a source named in a filelist and not on disk exits 2 and names it, rather than elaborating as a black box" \
    missing_file_named "$FLOW_DIR"

# THE HISTORICAL FAULT, PUT BACK. flist_resolve's own header records it: with
# the "" guard gone the caller's `file size` throws a raw Tcl error, so the
# reader dies with exit 1 and a stack trace instead of exit 2 and a diagnosis.
# The assertion goes red on both halves - the code and the message.
M="$(t_mutant "$SB" missing-unguarded)"
if [ -n "$M" ] && t_mutate "$M" flow/common/read_flist.tcl \
        '/^proc flist_read_source/,/^}/ s/if {\$r eq ""} {/if {0} {/'; then
    t_check_fail flist.missing_source.mutation \
        "with flist_read_source's empty-resolution guard removed the reader dies on a raw Tcl error (exit 1, no diagnosis), so the assertion goes red" \
        missing_file_named "$M"
else
    t_skip flist.missing_source.mutation \
        "could not plant the fault: the 'if {\$r eq \"\"}' guard in flist_read_source() has changed shape"
fi

#=============================================================================
# 6. -y IS GLOB-EXPANDED BY THIS READER - CONTRACT.md SECTION 9 IS BINDING
#
# `read_verilog` HAS NO `-y`. Vivado implements no library-directory lookup at
# all: nothing to hand the path to, no attribute that makes it searched, and no
# message when a module goes unresolved because of it. The module becomes a
# BLACK BOX, which Vivado reports as a warning and then synthesises, places,
# routes and writes a bitstream for. So if this reader does not expand the
# directory itself, NOTHING DOES.
#=============================================================================
t_head "-y is expanded HERE, because read_verilog has no -y (CONTRACT.md section 9)"

## y_dir_expanded <toolkit>
y_dir_expanded() {
    local tk="$1"
    rf_rc "$tk" -q "$F/top.f" || { printf 'the reader refused:\n%s\n' "$RF_OUT"; return 1; }
    printf '%s\n' "$RF_OUT" | grep -qF -- "$F/lib/lib_unit.v" && return 0
    printf 'the -y library directory contributed no compilation unit. read_verilog has no\n'
    printf -- '-y, so nothing downstream reads it either and lib_unit is now a BLACK BOX:\n%s\n' "$RF_OUT"
    return 1
}

## y_fragment_skipped <toolkit>
## A file in a -y directory that declares no compilation unit is an `include
## fragment. Reading one as a source is a syntax error; it stays reachable
## through +incdir+.
y_fragment_skipped() {
    local tk="$1"
    rf_rc "$tk" -q "$F/top.f" || { printf 'the reader refused:\n%s\n' "$RF_OUT"; return 1; }
    printf '%s\n' "$RF_OUT" | grep -qF -- "$F/lib/frag_defs.v" || return 0
    printf 'an `include fragment in a -y directory was handed to read_verilog as a source.\n'
    printf 'That is a syntax error inside the tool, thousands of lines from its cause:\n%s\n' "$RF_OUT"
    return 1
}

t_check flist.y.expanded \
    "a -y directory is glob-expanded and its compilation unit is read" \
    y_dir_expanded "$FLOW_DIR"
t_check flist.y.fragment_skipped \
    "and a file in it declaring no compilation unit is NOT read as a source" \
    y_fragment_skipped "$FLOW_DIR"

M="$(t_mutant "$SB" y-not-expanded)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/read_flist.tcl \
        '                if {$FLIST_Y_EXPAND} {' \
        '                if {0} {'; then
    t_check_fail flist.y.expanded.mutation \
        "with -y expansion switched off nothing reads the library directory, so the assertion goes red" \
        y_dir_expanded "$M"
else
    t_skip flist.y.expanded.mutation \
        "could not plant the fault: the FLIST_Y_EXPAND test in flist_sources() has changed shape"
fi

M="$(t_mutant "$SB" y-reads-fragments)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/read_flist.tcl \
        '            if {![flist_declares_unit $f]} { incr skipped ; continue }' \
        '            if {0} { incr skipped ; continue }'; then
    t_check_fail flist.y.fragment_skipped.mutation \
        "with the compilation-unit test removed every fragment in the directory is read as a source, so the assertion goes red" \
        y_fragment_skipped "$M"
else
    t_skip flist.y.fragment_skipped.mutation \
        "could not plant the fault: the flist_declares_unit test in flist_expand_y() has changed shape"
fi

#=============================================================================
# 7. DIALECT BY EXTENSION - .sv, .v, .vhd
#
# NOT "everything is SystemVerilog". `read_verilog -sv` on a Verilog-2001 file
# makes every SV keyword a reserved word, and `logic`, `bit`, `do`, `final`,
# `ref`, `packed` and `global` are all ordinary Verilog-2001 identifiers. A
# vendor library with a net named `logic` parses fine without -sv and fails with
# it, so the failure is not symmetric and the default matters.
#=============================================================================
t_head ".sv gets -sv, .v does NOT, .vhd goes to read_vhdl"

## dialects_by_extension <toolkit>
dialects_by_extension() {
    local tk="$1" out
    rf_rc "$tk" -q "$F/top.f" || { printf 'the reader refused:\n%s\n' "$RF_OUT"; return 1; }
    out="$RF_OUT"
    printf '%s\n' "$out" | grep -qxF -- "read_verilog $F/rtl/a.v" || {
        printf '.v was not read as plain Verilog. -sv makes `logic`, `bit`, `do`, `final`,\n'
        printf '`ref` and `global` reserved words, and a vendor net named `logic` then fails to parse:\n%s\n' "$out"
        return 1; }
    printf '%s\n' "$out" | grep -qxF -- "read_verilog -sv $F/rtl/b.sv" || {
        printf '.sv was not read as SystemVerilog:\n%s\n' "$out"; return 1; }
    printf '%s\n' "$out" | grep -qxF -- "read_vhdl $F/rtl/c.vhd" || {
        printf '.vhd did not go to read_vhdl - handed to a Verilog parser it is a syntax error:\n%s\n' "$out"
        return 1; }
    return 0
}

t_check flist.dialect \
    "the extension decides: .v plain, .sv with -sv, .vhd to read_vhdl" \
    dialects_by_extension "$FLOW_DIR"

# The ASIC reader's default, transplanted: every file is SystemVerilog.
M="$(t_mutant "$SB" sv-by-default)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/read_flist.tcl \
        '    if {$FLIST_SV_DEFAULT} { return sv }' \
        '    return sv'; then
    t_check_fail flist.dialect.mutation.sv \
        "with every .v forced to SystemVerilog - the ASIC reader's default - the assertion goes red" \
        dialects_by_extension "$M"
else
    t_skip flist.dialect.mutation.sv \
        "could not plant the fault: the FLIST_SV_DEFAULT line in flist_dialect() has changed shape"
fi

M="$(t_mutant "$SB" vhdl-as-verilog)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/read_flist.tcl \
        '        .vhdl   { return vhdl }' \
        '        .vhdl   { return v }'; then
    t_check_fail flist.dialect.mutation.vhdl \
        "with the VHDL arm returning Verilog, .vhd goes to read_verilog and the assertion goes red" \
        dialects_by_extension "$M"
else
    t_skip flist.dialect.mutation.vhdl \
        "could not plant the fault: the .vhd/.vhdl arm of flist_dialect()'s switch has changed shape"
fi

#=============================================================================
# 8. A -f CYCLE IS REFUSED, NOT FOLLOWED
#=============================================================================
t_head "a -f cycle is refused by name, rather than recursing until the interpreter dies"

## cycle_refused <toolkit>
cycle_refused() {
    local tk="$1" rc=0
    rf_rc "$tk" -q "$F/cyc_a.f" || rc=$?
    if [ "$rc" -ne 2 ]; then
        printf 'exit %d, not 2. A cycle that is not refused recurses until the interpreter\n' "$rc"
        printf 'runs out of stack, which reports as a Tcl crash inside Vivado and says nothing\n'
        printf 'about filelists:\n%s\n' "$RF_OUT"
        return 1
    fi
    printf '%s' "$RF_OUT" | grep -qF 'CYCLE' && return 0
    printf 'exit 2, but the refusal does not say it was a cycle:\n%s\n' "$RF_OUT"
    return 1
}

t_check flist.cycle \
    "two filelists including each other exit 2, naming the cycle and the stack" \
    cycle_refused "$FLOW_DIR"

M="$(t_mutant "$SB" no-cycle-guard)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/read_flist.tcl \
        '    if {[lsearch -exact $::flist_stack $norm] >= 0} {' \
        '    if {0} {'; then
    t_check_fail flist.cycle.mutation \
        "with the cycle guard removed the reader recurses to a Tcl stack error (exit 1, no diagnosis), so the assertion goes red" \
        cycle_refused "$M"
else
    t_skip flist.cycle.mutation \
        "could not plant the fault: the cycle test at the head of flist_scan() has changed shape"
fi

#=============================================================================
# 9. AN UNKNOWN OPTION IS NOT SILENTLY DROPPED
#
# Most unrecognised flist options are simulator-only and harmless. ONE that was
# meant to change the build is a silent misconfiguration, so the reader
# enumerates every one it ignored, and FLIST_STRICT_OPTS=1 makes them fatal.
#=============================================================================
t_head "an unrecognised option is enumerated, and fatal under FLIST_STRICT_OPTS"

## unknown_opt_reported <toolkit>
unknown_opt_reported() {
    local tk="$1" rc=0
    rf_rc "$tk" "$F/unknownopt.f" || rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'a simulator-only option made the reader fail (exit %d):\n%s\n' "$rc" "$RF_OUT"; return 1
    fi
    printf '%s' "$RF_OUT" | grep -qF '+notimingcheck' && return 0
    printf 'the ignored option is nowhere in the output. An option that was meant to change\n'
    printf 'the build and had no effect is a silent misconfiguration:\n%s\n' "$RF_OUT"
    return 1
}

## unknown_opt_strict_fatal <toolkit>
unknown_opt_strict_fatal() {
    local tk="$1" rc=0
    RF_OUT="$(FLIST_STRICT_OPTS=1 timeout 60 tclsh "$tk/flow/common/read_flist.tcl" -q "$F/unknownopt.f" 2>&1)" || rc=$?
    if [ "$rc" -ne 2 ]; then
        printf 'FLIST_STRICT_OPTS=1 did not make an unrecognised option fatal (exit %d):\n%s\n' "$rc" "$RF_OUT"
        return 1
    fi
    printf '%s' "$RF_OUT" | grep -qF '+notimingcheck' && return 0
    printf 'it refused, but without naming the option that caused it:\n%s\n' "$RF_OUT"
    return 1
}

t_check flist.unknown_opt.reported \
    "an unrecognised option is enumerated in the output rather than dropped in silence" \
    unknown_opt_reported "$FLOW_DIR"
t_check flist.unknown_opt.strict \
    "and FLIST_STRICT_OPTS=1 makes it exit 2, naming it" \
    unknown_opt_strict_fatal "$FLOW_DIR"

M="$(t_mutant "$SB" opt-dropped-silently)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/read_flist.tcl \
        '    lappend ::flist_ignored "$tok ($where)"' \
        '    set __mutation_swallowed_the_option "$tok ($where)"'; then
    t_check_fail flist.unknown_opt.reported.mutation \
        "with the ignored-option census not recorded the option vanishes from the output, so the assertion goes red" \
        unknown_opt_reported "$M"
else
    t_skip flist.unknown_opt.reported.mutation \
        "could not plant the fault: the census line in flist_note_ignored() has changed shape"
fi

M="$(t_mutant "$SB" strict-inert)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/read_flist.tcl \
        '    if {$FLIST_STRICT_OPTS} {' \
        '    if {0} {'; then
    t_check_fail flist.unknown_opt.strict.mutation \
        "with FLIST_STRICT_OPTS made inert the knob stops rejecting anything, so the assertion goes red" \
        unknown_opt_strict_fatal "$M"
else
    t_skip flist.unknown_opt.strict.mutation \
        "could not plant the fault: the FLIST_STRICT_OPTS test in flist_note_ignored() has changed shape"
fi


#=============================================================================
# 10. THE FOUR DEFECTS THIS SECTION USED TO RECORD
#
# Three of these were `t_known_defect` markers here until 2026-09-08, and the
# fourth was not covered at all. read_flist.tcl has been fixed, so they are
# ORDINARY ASSERTIONS now: a defect marker that outlives its defect is how a
# suite starts lying about what it covers, and the harness makes a stale marker
# go RED for exactly that reason.
#
# Every one is paired with a mutation proof that PUTS THE ORIGINAL DEFECT BACK -
# not an approximation of it. The `+incdir+` proof drops the `isdirectory` test;
# the flist_apply proof drops the property assignment; the option-argument proof
# stops absorbing the argument; the summary proof restores the arithmetic that
# was structurally zero. Each is one literal line through t_replace_line, whose
# return value is honoured: a fault that could not be planted is a SKIP naming
# the line that moved, never a silent pass.
#=============================================================================
t_head "10a. flist_apply() APPLIES the include dirs and the defines, before the reads"

# THE HEADLINE DEFECT, AND IT WAS WORSE THAN THE ONE THE FILE WAS WRITTEN TO
# AVOID. ::flist_cmds held read_verilog/read_vhdl and nothing else - the
# include_dirs and verilog_define assignments existed only in the TEXT that
# flist_write_sources generates. So the reader's whole reason for existing
# survived into sources.tcl and was dropped on the floor by the other entry
# point, the one its own docstring offers to non-project flows: "Execute the
# reads in the running tool." Measured on this fixture: 3 include directories
# collected, 0 applied. The header's defect is "41 collected, ONE survives";
# this one left none.
#
# The drive script DECIDES NOTHING. It stubs the tool commands, runs
# flist_apply, and prints what was applied in order; the assertions below read
# that list. A drive script that graded itself would be a place for a mutant to
# pass by making the grader lenient.
cat > "$SB/apply_drive.tcl" <<'TCL'
set tk [lindex $::argv 0]
source [file join $tk flow common flow_utils.tcl]
flow_config prefix FLIST
set ::applied {}
proc read_verilog    {args} { lappend ::applied "read_verilog $args" }
proc read_vhdl       {args} { lappend ::applied "read_vhdl $args" }
proc set_property    {args} { lappend ::applied "set_property $args" }
proc get_property    {args} { return {} }
proc current_fileset {args} { return sources_1 }
source [file join $tk flow common read_flist.tcl]
flist_apply
foreach c $::applied { puts "APPLIED: $c" }
TCL

## apply_run <toolkit> - drive flist_apply over apply.f, leaving the APPLIED
## lines in RF_OUT. Non-zero only when flist_apply itself failed.
apply_run() {
    local tk="$1" rc=0
    RF_OUT="$(FPGA_RTL_FLIST="$F/apply.f" timeout 60 tclsh "$SB/apply_drive.tcl" "$tk" 2>&1)" || rc=$?
    return $rc
}

## apply_applies_incdirs <toolkit>
apply_applies_incdirs() {
    local tk="$1" line n=0 d
    apply_run "$tk" || { printf 'flist_apply failed:\n%s\n' "$RF_OUT"; return 1; }
    line="$(printf '%s\n' "$RF_OUT" | grep -m1 '^APPLIED: set_property include_dirs ')"
    if [ -z "$line" ]; then
        printf 'flist_apply ran the reads and applied NO include_dirs at all. The union it\n'
        printf 'collected reaches the fileset only through the text of sources.tcl, so in this\n'
        printf 'path every header in every +incdir+ is unreachable:\n%s\n' "$RF_OUT"
        return 1
    fi
    for d in inc1 inc2 inc3; do
        printf '%s' "$line" | grep -qF -- "$F/$d" && n=$((n + 1))
    done
    [ "$n" -eq 3 ] && return 0
    printf 'only %d of 3 collected include directories were APPLIED:\n%s\n' "$n" "$line"
    return 1
}

## apply_applies_defines <toolkit>
apply_applies_defines() {
    local tk="$1" line
    apply_run "$tk" || { printf 'flist_apply failed:\n%s\n' "$RF_OUT"; return 1; }
    line="$(printf '%s\n' "$RF_OUT" | grep -m1 '^APPLIED: set_property verilog_define ')"
    if [ -z "$line" ]; then
        printf 'flist_apply applied NO verilog_define. An undefined `ifdef is silent - it\n'
        printf 'builds the other arm and says nothing, which is CONTRACT.md section 9.2:\n'
        printf 'an `ifdef opt-in was false in EVERY FPGA build and a byte-identical bitstream\n'
        printf 'was the only thing that proved it:\n%s\n' "$RF_OUT"
        return 1
    fi
    printf '%s' "$line" | grep -qF 'FLIST_TEST_D1' && return 0
    printf 'verilog_define was applied without the define the filelist named:\n%s\n' "$line"
    return 1
}

## apply_before_reads <toolkit>
## ORDER, not merely presence. The two-pass scan at the top of read_flist.tcl
## exists so that every search path is in place before the FIRST read rather
## than merely before the last one; applying them afterwards would be betting
## that the tool defers include resolution, which is the bet the header refuses.
apply_before_reads() {
    local tk="$1" prop read
    apply_run "$tk" || { printf 'flist_apply failed:\n%s\n' "$RF_OUT"; return 1; }
    prop="$(printf '%s\n' "$RF_OUT" | grep -n '^APPLIED: set_property ' | head -1 | cut -d: -f1)"
    read="$(printf '%s\n' "$RF_OUT" | grep -n '^APPLIED: read_' | head -1 | cut -d: -f1)"
    [ -n "$prop" ] || { printf 'nothing was applied at all:\n%s\n' "$RF_OUT"; return 1; }
    [ -n "$read" ] || { printf 'nothing was READ at all, so there is no order to measure:\n%s\n' "$RF_OUT"; return 1; }
    [ "$prop" -lt "$read" ] && return 0
    printf 'the search paths were applied at position %s, AFTER the first read at %s:\n%s\n' \
        "$prop" "$read" "$RF_OUT"
    return 1
}

t_check flist.apply.incdirs \
    "flist_apply() applies the whole +incdir+ union to the fileset, not just collects it" \
    apply_applies_incdirs "$FLOW_DIR"
t_check flist.apply.defines \
    "and the +define+ list too - an undefined \`ifdef builds the other arm in silence" \
    apply_applies_defines "$FLOW_DIR"
t_check flist.apply.before_reads \
    "and both BEFORE the first read command, which is what the two-pass scan is for" \
    apply_before_reads "$FLOW_DIR"

# -- mutation proof: THE ORIGINAL DEFECT, one line ----------------------------
M="$(t_mutant "$SB" apply-no-incdirs)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/read_flist.tcl \
        '        set_property include_dirs [concat $have $::flist_incdirs] $__fs' \
        '        set __mutation_dropped_the_include_dirs $::flist_incdirs'; then
    t_check_fail flist.apply.incdirs.mutation \
        "with the include_dirs assignment removed from flist_apply_search, the in-tool path reads every source with ZERO include directories and the assertion goes red" \
        apply_applies_incdirs "$M"
else
    t_skip flist.apply.incdirs.mutation \
        "could not plant the fault: the include_dirs assignment in flist_apply_search() has changed shape"
fi

M="$(t_mutant "$SB" apply-no-defines)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/read_flist.tcl \
        '        set_property verilog_define [concat $have $::flist_defines] $__fs' \
        '        set __mutation_dropped_the_defines $::flist_defines'; then
    t_check_fail flist.apply.defines.mutation \
        "with the verilog_define assignment removed, every +define+ is undefined in the in-tool path and the assertion goes red" \
        apply_applies_defines "$M"
else
    t_skip flist.apply.defines.mutation \
        "could not plant the fault: the verilog_define assignment in flist_apply_search() has changed shape"
fi

# ORDER ONLY. Two lines, one fault: the properties still get applied - so the
# two assertions above stay GREEN under this mutant - but after the reads
# instead of before them. That is what proves apply_before_reads measures order
# and not presence.
M="$(t_mutant "$SB" apply-after-reads)"
MUT_OK=0
if [ -n "$M" ] && t_replace_line "$M" flow/common/read_flist.tcl \
        '    set applied [flist_apply_search]' \
        '    set applied 1'; then
    if t_replace_line "$M" flow/common/read_flist.tcl \
            '    foreach c $::flist_cmds { uplevel #0 $c }' \
            '    foreach c $::flist_cmds { uplevel #0 $c } ; flist_apply_search'; then
        MUT_OK=1
    fi
fi
if [ "$MUT_OK" = 1 ]; then
    t_check_fail flist.apply.before_reads.mutation \
        "with the search paths applied AFTER the reads instead of before them, the order assertion goes red while presence alone would still pass" \
        apply_before_reads "$M"
else
    t_skip flist.apply.before_reads.mutation \
        "could not plant the fault: flist_apply()'s call to flist_apply_search() or its read loop has changed shape"
fi

#=============================================================================
t_head "10b. +incdir+ must name a DIRECTORY, exactly as -y does"

# `file exists` alone accepted `+incdir+rtl/a.v` and put a FILE into
# include_dirs, where Vivado searches nothing and reports nothing - which is
# word for word the failure the +incdir+ refusal exists to prevent, reached by a
# different route. The `-y` branch twenty lines away had always checked
# `isdirectory`; this branch had not.

## incdir_file_refused <toolkit>
incdir_file_refused() {
    local tk="$1" rc=0
    rf_rc "$tk" -q "$F/incdir_is_a_file.f" || rc=$?
    if [ "$rc" -ne 2 ]; then
        printf 'exit %d, not 2 (refused / unusable input). A regular file in include_dirs is a\n' "$rc"
        printf 'search path with nothing under it, and no tool says so:\n%s\n' "$RF_OUT"
        return 1
    fi
    printf '%s' "$RF_OUT" | grep -qF 'rtl/a.v' || {
        printf 'it refused without naming the path that caused it:\n%s\n' "$RF_OUT"; return 1; }
    printf '%s' "$RF_OUT" | grep -qiF 'directory' && return 0
    printf 'it refused and named the path, but never says the problem is that it is not a\n'
    printf 'directory - so the reader is sent looking for a missing file instead:\n%s\n' "$RF_OUT"
    return 1
}

t_check flist.incdir.isdirectory \
    "+incdir+ naming a regular file exits 2 and says it is not a directory" \
    incdir_file_refused "$FLOW_DIR"

M="$(t_mutant "$SB" incdir-exists-only)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/read_flist.tcl \
        '                    if {![file isdirectory $r]} {' \
        '                    if {0} {'; then
    t_check_fail flist.incdir.isdirectory.mutation \
        "with the isdirectory test removed - checking only that the path exists, as the branch used to - a FILE is accepted into include_dirs and the assertion goes red" \
        incdir_file_refused "$M"
else
    t_skip flist.incdir.isdirectory.mutation \
        "could not plant the fault: the isdirectory test in flist_scan()'s +incdir+ branch has changed shape"
fi

#=============================================================================
t_head "10c. an unrecognised option takes its ARGUMENT with it"

# `-timescale 1ns/1ps` - the exact two-token spelling this reader's own census
# warning names as harmless - used to refuse the whole run AT THE DEFAULT
# SETTING with "source file not found: 1ns/1ps". The argument was read as a
# source, the option was never reported at all (the census prints at the end of
# flist_read, and the refusal happened first), and the diagnosis named the
# argument, sending the reader to look for a file that was never meant to exist.
#
# THE DESIGN CALL, recorded here because a test is where a behaviour is pinned:
# an unrecognised option is REPORTED AND NOT FATAL at the default setting, and
# its argument is absorbed and reported with it. Not fatal, because CONTRACT.md
# section 9.1 makes the filelist the configuration and these filelists are
# shared with the simulator flow - simulator-only options are their normal
# contents, and refusing them would force a second, FPGA-only copy of the one
# file that decides what design gets built. FLIST_STRICT_OPTS=1 keeps the strict
# answer and is asserted in section 9 above.

## opt_arg_absorbed <toolkit>
opt_arg_absorbed() {
    local tk="$1" rc=0
    rf_rc "$tk" "$F/simopt.f" || rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'a two-token simulator option refused the run (exit %d) at the DEFAULT setting,\n' "$rc"
        printf 'and the message names its ARGUMENT as a missing source rather than the option:\n%s\n' "$RF_OUT"
        return 1
    fi
    printf '%s\n' "$RF_OUT" | grep -qF -- '-timescale' || {
        printf 'the run survived, but -timescale was never reported as unrecognised. An option\n'
        printf 'that was meant to change the build and had no effect is a silent\n'
        printf 'misconfiguration:\n%s\n' "$RF_OUT"; return 1; }
    printf '%s\n' "$RF_OUT" | grep -qF '1ns/1ps' || {
        printf 'the option is reported without the argument that was skipped with it, so the\n'
        printf 'census does not account for every token on the line:\n%s\n' "$RF_OUT"; return 1; }
    printf '%s\n' "$RF_OUT" | grep -qE '^read_(verilog|vhdl).*1ns/1ps' || return 0
    printf 'the argument was handed to a read command as a source path:\n%s\n' "$RF_OUT"
    return 1
}

## opt_arg_keeps_sources <toolkit>
## THE BOUNDARY OF THE RULE, and the half that keeps rule 0 intact. A token that
## looks like an HDL source is NEVER absorbed - so a real source after an
## unrecognised option is still read, and a MISSING one is still refused by
## name instead of being swallowed as an option argument and built without.
opt_arg_keeps_sources() {
    local tk="$1" rc=0
    rf_rc "$tk" -q "$F/optarg_src.f" || {
        printf 'the reader refused a source that follows an unrecognised option:\n%s\n' "$RF_OUT"; return 1; }
    printf '%s\n' "$RF_OUT" | grep -qF -- "$F/rtl/a.v" || {
        printf 'a real source following an unrecognised option was SWALLOWED as that option'"'"'s\n'
        printf 'argument and never read. It elaborates as a black box Vivado warns about and\n'
        printf 'then builds:\n%s\n' "$RF_OUT"
        return 1; }
    rc=0
    rf_rc "$tk" -q "$F/optarg_missing.f" || rc=$?
    if [ "$rc" -ne 2 ]; then
        printf 'a MISSING source following an unrecognised option exited %d instead of 2: it was\n' "$rc"
        printf 'absorbed as the option'"'"'s argument, and the design builds without it in silence:\n%s\n' "$RF_OUT"
        return 1
    fi
    printf '%s' "$RF_OUT" | grep -qF 'does_not_exist.v' && return 0
    printf 'it refused, but without naming the missing source:\n%s\n' "$RF_OUT"
    return 1
}

t_check flist.unknown_opt.argument \
    "'-timescale 1ns/1ps' survives at the default setting, and BOTH tokens are named in the census" \
    opt_arg_absorbed "$FLOW_DIR"
t_check flist.unknown_opt.argument.sources_kept \
    "but a token that looks like a source is never absorbed - present it is read, missing it still refuses by name" \
    opt_arg_keeps_sources "$FLOW_DIR"

M="$(t_mutant "$SB" opt-arg-eaten)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/read_flist.tcl \
        '                if {[flist_opt_takes_arg $t $nxt]} { set arg $nxt ; incr i }' \
        '                set arg ""'; then
    t_check_fail flist.unknown_opt.argument.mutation \
        "with the argument no longer absorbed - the original defect - '1ns/1ps' is read as a source path and the run refuses, so the assertion goes red" \
        opt_arg_absorbed "$M"
else
    t_skip flist.unknown_opt.argument.mutation \
        "could not plant the fault: the argument-absorption line in flist_sources() has changed shape"
fi

# The OTHER direction, and it is the one that matters more: absorb too much and
# a missing source disappears into an option argument. That is a source silently
# dropped, which is the defect class the whole file exists to prevent.
M="$(t_mutant "$SB" opt-arg-eats-sources)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/read_flist.tcl \
        '    if {[flist_looks_like_source $next]} { return 0 }' \
        '    if {0} { return 0 }'; then
    t_check_fail flist.unknown_opt.argument.sources_kept.mutation \
        "with the looks-like-a-source guard removed, an unrecognised option swallows the source beside it and the assertion goes red" \
        opt_arg_keeps_sources "$M"
else
    t_skip flist.unknown_opt.argument.sources_kept.mutation \
        "could not plant the fault: the source-extension test in flist_opt_takes_arg() has changed shape"
fi

#=============================================================================
t_head "10d. flist_summary reports numbers that are not structurally zero"

# THIS ONE WAS NOT COVERED AT ALL, and it is the quietest of the four.
# flist_summary guarded its `commands` line with
#
#     set n [expr {[llength $::flist_cmds] - $::flist_files}]
#     if {$n > 0} { ... }
#
# and those two counters are incremented on adjacent lines of the same two
# procs. $n is STRUCTURALLY ZERO, so the line had never printed, once, in any
# run - while the comment above it explained what the number meant. A number
# that can only ever be zero is worse than no number: it reads as "no
# duplicates" to anyone who sees the guard and assumes it fired.

## summary_commands_line <toolkit>
summary_commands_line() {
    local tk="$1" cmds files
    rf_rc "$tk" "$F/top.f" || { printf 'the reader refused:\n%s\n' "$RF_OUT"; return 1; }
    cmds="$(printf '%s\n' "$RF_OUT" | sed -n 's/^FLIST: commands  *: \([0-9][0-9]*\)$/\1/p')"
    if [ -z "$cmds" ]; then
        printf 'flist_summary printed no commands line at all. It was guarded by an expression\n'
        printf 'that is structurally zero - [llength $::flist_cmds] - $::flist_files, two\n'
        printf 'counters incremented together - so the line never printed in any run:\n%s\n' "$RF_OUT"
        return 1
    fi
    files="$(printf '%s\n' "$RF_OUT" | sed -n 's/^FLIST: source files  *: \([0-9][0-9]*\)$/\1/p')"
    [ -n "$files" ] || { printf 'no source-files line to compare against:\n%s\n' "$RF_OUT"; return 1; }
    [ "$cmds" -gt 0 ] || { printf 'the commands line reports 0 for a filelist with %s sources:\n%s\n' "$files" "$RF_OUT"; return 1; }
    [ "$cmds" = "$files" ] && return 0
    printf '%s read command(s) for %s source file(s) - these are incremented together and\n' "$cmds" "$files"
    printf 'cannot legitimately differ:\n%s\n' "$RF_OUT"
    return 1
}

## summary_reports_duplicates <toolkit>
## The number the dead line's own comment described, counted where the
## de-duplication happens instead of derived from two counters that move
## together. A path named twice is two definitions of one module.
summary_reports_duplicates() {
    local tk="$1" n
    rf_rc "$tk" "$F/dup.f" || { printf 'the reader refused:\n%s\n' "$RF_OUT"; return 1; }
    printf '%s\n' "$RF_OUT" | grep -qE '^FLIST: duplicate paths: 1 ' || {
        printf 'a path named twice in one filelist was absorbed without being reported. The\n'
        printf 'summary is where a human diffs one run against another, and this is the number\n'
        printf 'the dead line was meant to carry:\n%s\n' "$RF_OUT"
        return 1; }
    printf '%s' "$RF_OUT" | grep -qF -- "$F/rtl/a.v" || {
        printf 'it reported a duplicate without naming the path:\n%s\n' "$RF_OUT"; return 1; }
    n="$(printf '%s\n' "$RF_OUT" | grep -c "^read_verilog $F/rtl/a.v\$")"
    [ "$n" -eq 1 ] && return 0
    printf 'the duplicate was reported but the file was emitted %s times. Two read commands\n' "$n"
    printf 'for one path are two definitions of one module and an elaboration error a long\n'
    printf 'way from here:\n%s\n' "$RF_OUT"
    return 1
}

t_check flist.summary.commands \
    "the summary's commands line actually prints, and agrees with the source count" \
    summary_commands_line "$FLOW_DIR"
t_check flist.summary.duplicates \
    "a path named twice is reported as absorbed, by name, and read exactly once" \
    summary_reports_duplicates "$FLOW_DIR"

# THE ORIGINAL DEFECT, restored verbatim: the same say, behind the same
# structurally-zero guard.
M="$(t_mutant "$SB" summary-dead-line)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/read_flist.tcl \
        '    say "commands       : [llength $::flist_cmds]"' \
        '    if {[llength $::flist_cmds] - $::flist_files > 0} { say "commands       : [llength $::flist_cmds]" }'; then
    t_check_fail flist.summary.commands.mutation \
        "with the line put back behind its structurally-zero guard it never prints again, so the assertion goes red" \
        summary_commands_line "$M"
else
    t_skip flist.summary.commands.mutation \
        "could not plant the fault: the commands line in flist_summary() has changed shape"
fi

M="$(t_mutant "$SB" dup-not-counted)"
if [ -n "$M" ] && t_replace_line "$M" flow/common/read_flist.tcl \
        '        lappend ::flist_dups "$r (again at $where)"' \
        '        set __mutation_swallowed_the_duplicate "$r (again at $where)"'; then
    t_check_fail flist.summary.duplicates.mutation \
        "with the duplicate not recorded where it is absorbed, the count is unreachable again and the assertion goes red" \
        summary_reports_duplicates "$M"
else
    t_skip flist.summary.duplicates.mutation \
        "could not plant the fault: the duplicate census line in flist_read_source() has changed shape"
fi

t_summary
