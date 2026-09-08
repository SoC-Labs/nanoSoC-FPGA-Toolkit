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
# 10. THREE KNOWN DEFECTS
#
# This suite does not own read_flist.tcl, so it RECORDS these rather than fixing
# them. Each is a t_known_defect: the assertion is correct, the reader does not
# satisfy it today, and if any of them starts passing the suite goes RED, so the
# marker cannot outlive the bug it documents.
#=============================================================================
t_head "known defects in read_flist.tcl"

# --- 10a. flist_apply() reads the files and applies NEITHER the include dirs
# NOR the defines.
#
# ::flist_cmds holds read_verilog/read_vhdl and nothing else - the include_dirs
# and verilog_define assignments exist only in the TEXT that flist_write_sources
# generates. So the file's whole reason for existing survives in sources.tcl and
# is dropped on the floor by the other entry point, the one its own docstring
# offers to non-project flows: "Execute the reads in the running tool." An
# `include is resolved when a file is READ, so in that path every header in
# every +incdir+ is unreachable and every +define+ is undefined. That is the
# header's defect one layer down - not "all but one survive" but "none do".
cat > "$SB/apply_drive.tcl" <<'TCL'
# Drive flist_apply with the tool commands stubbed, and report whether the
# include dirs reached the fileset. Exits 0 only if they did.
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
if {[lsearch -glob $::applied "set_property include_dirs*"] >= 0} { exit 0 }
puts "flist_apply executed [llength $::applied] command(s) and applied NONE of the"
puts "[llength $::flist_incdirs] include director(ies) it collected, nor any of the"
puts "[llength $::flist_defines] define(s). `include is resolved when a file is READ."
exit 1
TCL

## apply_applies_incdirs <toolkit>
apply_applies_incdirs() {
    local tk="$1" rc=0
    RF_OUT="$(FPGA_RTL_FLIST="$F/top.f" timeout 60 tclsh "$SB/apply_drive.tcl" "$tk" 2>&1)" || rc=$?
    [ "$rc" -eq 0 ] && return 0
    printf '%s\n' "$RF_OUT"
    return 1
}

t_known_defect flist.apply.incdirs \
    "flist_apply() runs the reads and applies NO include_dirs and NO verilog_define - the header's own defect, in the in-tool path" \
    apply_applies_incdirs "$FLOW_DIR"

# --- 10b. `+incdir+` accepts a REGULAR FILE.
#
# flist_scan checks that the resolved path EXISTS. The `-y` branch beside it
# also checks `file isdirectory`; this one does not. A file therefore lands in
# include_dirs, Vivado searches nothing, and the headers that were supposed to
# be there fail to resolve with no message naming the line that caused it -
# which is word for word the failure the +incdir+ refusal exists to prevent,
# reached by a different route.
## incdir_file_refused <toolkit>
incdir_file_refused() {
    local tk="$1" rc=0
    rf_rc "$tk" -q "$F/incdir_is_a_file.f" || rc=$?
    [ "$rc" -ne 0 ] && return 0
    printf '+incdir+ naming a regular file was ACCEPTED and put into include_dirs:\n%s\n' "$RF_OUT"
    return 1
}

t_known_defect flist.incdir.isdirectory \
    "+incdir+ naming a regular file is accepted (the -y branch checks isdirectory, the +incdir+ branch only checks exists)" \
    incdir_file_refused "$FLOW_DIR"

# --- 10c. An unrecognised option's ARGUMENT is read as a source path.
#
# The reader's own warning text names `-timescale` as one of the simulator-only
# options that are "fine" - and `-timescale 1ns/1ps`, the ordinary two-token
# spelling, refuses the whole run with "source file not found: 1ns/1ps". The
# option is never even reported as unrecognised, and the diagnosis sends the
# reader looking for a file rather than at the option that produced it. Note
# that FLIST_STRICT_OPTS is not the issue: this refuses at the DEFAULT setting.
## simulator_opt_with_arg_survives <toolkit>
simulator_opt_with_arg_survives() {
    local tk="$1" rc=0
    rf_rc "$tk" -q "$F/simopt.f" || rc=$?
    [ "$rc" -eq 0 ] && return 0
    printf 'a two-token simulator option refused the run (exit %d) at the DEFAULT setting, and\n' "$rc"
    printf 'the message names its ARGUMENT as a missing source rather than naming the option:\n%s\n' "$RF_OUT"
    return 1
}

t_known_defect flist.unknown_opt.argument \
    "'-timescale 1ns/1ps' - named in the reader's own warning as harmless - refuses the run, diagnosed as a missing source called '1ns/1ps'" \
    simulator_opt_with_arg_survives "$FLOW_DIR"

t_summary
