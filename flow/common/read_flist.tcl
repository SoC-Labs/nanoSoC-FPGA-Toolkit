################################################################################
# read_flist.tcl - turn a simulator-style filelist into Vivado read commands
#
# Sourced by the flist stage (flow/vivado/1_flist.tcl) after flow_boot. It reads
# $FPGA_RTL_FLIST and materialises $(WORK_DIR)/sources.tcl - the file every later
# stage sources to get the design. It also runs standalone:
#
#     tclsh flow/common/read_flist.tcl [-o <out.tcl>] [-q] <flist>
#
# which is how the phase-1 tests exercise it with no tool and no licence.
#
#
# WHY THIS FILE IS WRITTEN THE WAY IT IS: THE +incdir+ DEFECT
# ===========================================================================
# The reference ASIC toolkit's flist reader issued one search-path assignment per
# `+incdir+` line, into an attribute that SETS rather than appends. Measured on
# the compute chiplet's tapeout filelist (10 nested `-f` sub-flists): 41
# `+incdir+` lines and 27 `-y` lines produced 68 assignments and left exactly ONE
# include directory standing. Headers then resolved or not by accident of flist
# order, and a header that does not resolve is a parse error reported thousands
# of lines from its cause.
#
# VIVADO HAS THE SAME SHAPE OF PROPERTY. `set_property include_dirs <list>
# <fileset>` replaces the property; so does `set_property verilog_define`. One
# call per line loses everything but the last, in silence.
#
# So the reader walks the whole chain TWICE:
#
#     pass 1  flist_scan      collect EVERY +incdir+, -y, +libext+ in order
#             one emission    include_dirs = what was there + the whole union
#     pass 2  flist_sources   emit the file reads
#
# Two passes rather than one appending call per line, because `include is
# resolved when a file is READ: every include directory has to be in place before
# the FIRST read_verilog, not merely before the last one. Reading the filelist
# text twice costs milliseconds.
#
# The regression test for this is the multi-`+incdir+` case in the phase-1 suite,
# and it asserts on the COUNT. An assertion that only checks the last directory
# survives the exact defect it exists to catch.
#
#
# `-y` IS NOT OPTIONAL HERE - CONTRACT.md SECTION 9
# ===========================================================================
# `read_verilog` HAS NO `-y`. Vivado implements no library-directory lookup at
# all: there is nothing to hand a `-y` path to, no attribute that makes it
# searched, and no message when a module goes unresolved because of it. An
# unresolved module becomes a BLACK BOX, which Vivado reports as a warning and
# then happily synthesises, places, routes and writes a bitstream for.
#
# So this reader GLOB-EXPANDS a `-y` directory itself, against the `+libext+`
# extension set, and reads every file in it that DECLARES a compilation unit.
# A file in such a directory that declares no module is an `include fragment -
# vendor libraries ship plenty (`*_defs.v`, `*_undefs.v`, `define/`undef bodies,
# files with module-scope hierarchical references that error standalone) - and
# reading one as a source is a syntax error. Those are skipped and stay reachable
# through `+incdir+`; the reader reports the split per directory so a directory
# that contributed nothing is visible rather than assumed.
#
# FLIST_Y_EXPAND=0 turns the expansion off. It does NOT make the flow correct: it
# makes every module in those directories a black box, and the reader says so at
# maximum volume, because the failure downstream is a bitstream that configures
# and does nothing.
#
#
# WHAT A FILELIST MAY CONTAIN
# ===========================================================================
#   <path>              an HDL source. .sv/.v/.vhd dialect by extension.
#   -f <path>           another filelist, read recursively
#   -F <path>           the same. Both resolve relative paths the -F way; see
#                       "RELATIVE PATHS" below
#   +incdir+<d>[+<d>]   include search paths, plus-separated
#   +define+<D>[+<D>]   preprocessor defines, plus-separated
#   +libext+.v+.sv      library-file extensions for -y expansion. ADDS to {.v},
#                       never replaces it
#   -y <dir>            a library directory, glob-expanded - see above
#   -v <file>           a library file. Read like any other source
#   -define <D> / -d <D>  a define in the flag spelling
#   # ...  // ...       comments, whole-line or trailing after whitespace
#
# ${VAR}, $(VAR) AND $VAR ARE ALL EXPANDED. Hand-written flists in this codebase
# use ${VAR}; generator-emitted ones use the make-style $(VAR); shell-derived
# ones use bare $VAR. Supporting all three means a generated filelist can be
# `-f`-included directly instead of being flattened first and going stale.
#
# AN UNSET OR EMPTY VARIABLE IS A REFUSAL, NAMING THE VARIABLE (exit 2). A path
# that silently collapses to "/src/rtl/foo.v" is read as a missing file ten
# minutes later, at the end of elaboration, and reads as a link problem rather
# than as a missing export. An empty value counts as unset for the same reason -
# and because `flow_env` already treats empty as unset, so the two layers agree.
#
# SO IS A MISSING FILE (exit 2, naming the path and the flist line that named
# it). CONTRACT.md rule 0: a source that is silently dropped produces a design
# that elaborates, synthesises and reports clean numbers about something that is
# not the design anyone asked for.
#
# EXPANSION IS A SINGLE LEFT-TO-RIGHT SCAN, NOT regsub AND NOT string map.
# `regsub` INTERPRETS ITS REPLACEMENT: `&` means the whole match and `\1` means
# capture 1. Measured on the reference toolkit, on ordinary vendor paths:
#     V=vendor_a&b   ${V} -> a${V}b -> aa${V}bb -> ...  an infinite loop in the
#                    flist reader, before elaboration
#     V=a\1b         silently became "ab"
# `string map` fixes those but introduces its own: it is a literal substring
# replacement, so a map for bare `$FOO` also mangles `$FOOBAR`. The scan below
# has neither problem, and because it continues AFTER the substituted text, a
# value that itself contains a `$` cannot be re-expanded.
#
#
# RELATIVE PATHS
# ===========================================================================
# mk/flow.mk launches every stage with `cd "$(WORK_DIR)"` - deliberately, so
# Vivado's .Xil/, .jou and project scratch land in the run directory instead of
# the repository. The consequence is that the tool's cwd is NOT the project, so a
# cwd-relative path in a filelist resolves against a run directory that has
# nothing in it.
#
# So a relative path is resolved against THE DIRECTORY OF THE FLIST THAT NAMED IT
# first, and against the cwd second, and if neither exists the refusal names both
# attempts. That is `-F` semantics applied to `-f` as well, which is what every
# author of these files already assumes.
#
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
################################################################################

if {![info exists ::flow_utils_loaded]} {
    # Standalone use: find flow_utils beside this file. Sourced from a stage it
    # is already loaded and this branch never runs.
    source [file join [file dirname [file normalize [info script]]] flow_utils.tcl]
}

if {[info exists ::fpga_read_flist_loaded]} { return }
set ::fpga_read_flist_loaded 1

foreach __c {
    flist_expand_env flist_resolve flist_scan flist_sources flist_tokens
    flist_declares_unit flist_expand_y flist_dialect flist_emit flist_read
    flist_write_sources flist_apply flist_summary flist_note_ignored
    flist_read_source flist_tried
} {
    if {[llength [info commands $__c]]} {
        error "read_flist.tcl: '$__c' is already a command in this tool - it\
               would be shadowed. Rename the helper and its callers."
    }
}
unset __c


################################################################################
# KNOBS
#
# Declared at the left margin, one per line, `opt NAME default ;# what it does`.
# That is not a style preference: flow_knob_scan reads these files rather than
# executing them, and `make help-knobs` and the stage manifest both depend on the
# declaration being findable without running Vivado.
################################################################################

opt FLIST_Y_EXPAND    1   ;# 1 = glob-expand -y dirs. 0 = every module in them is a BLACK BOX
opt FLIST_SV_DEFAULT  0   ;# 1 = read .v as SystemVerilog too. See flist_dialect
opt FLIST_DEFINES     ""  ;# extra +define+ names applied to every file
opt FLIST_INCDIRS     ""  ;# extra include dirs, prepended to the flist's own
opt FLIST_STRICT_OPTS 0   ;# 1 = an unrecognised flist option is fatal, not a warning


################################################################################
# STATE
#
# All reset by flist_read, so the reader can be run twice in one session (the
# tests do exactly that) without the second run inheriting the first's paths.
################################################################################

set ::flist_incdirs     {}     ;# +incdir+ dirs, first-seen order, de-duplicated
set ::flist_ydirs       {}     ;# -y library dirs, first-seen order
set ::flist_libext      {.v}   ;# +libext+ extensions, union over the whole chain
set ::flist_defines     {}     ;# +define+ / -define, in order
set ::flist_files_read  {}     ;# every source path handed to the tool
set ::flist_headers     {}     ;# .vh/.svh listed as sources - see flist_sources
set ::flist_cmds        {}     ;# the emitted Vivado commands, in order
set ::flist_ignored     {}     ;# options this reader did not recognise
set ::flist_stack       {}     ;# the -f include stack, for the cycle guard
set ::flist_chain       {}     ;# every flist file read, for the manifest
set ::flist_files       0      ;# source count


################################################################################
# 1. EXPANSION AND PATH RESOLUTION
################################################################################

# ${VAR} / $(VAR) / $VAR from the environment. See the header for why this is a
# hand-written scan and not regsub or string map.
#
# <where> names the flist and line the string came from, because a refusal that
# says only "FOO is not set" leaves the reader grepping a chain of ten filelists
# for which one mentioned it.
proc flist_expand_env {str where} {
    set out ""
    set i 0
    set n [string length $str]
    while {$i < $n} {
        if {[string index $str $i] ne "\$"} {
            append out [string index $str $i]
            incr i
            continue
        }
        set rest [string range $str $i end]
        set name ""
        set m ""
        if {![regexp -- {^\$\{([A-Za-z_][A-Za-z0-9_]*)\}} $rest m name] &&
            ![regexp -- {^\$\(([A-Za-z_][A-Za-z0-9_]*)\)} $rest m name] &&
            ![regexp -- {^\$([A-Za-z_][A-Za-z0-9_]*)}     $rest m name]} {
            # A lone '$' that is not a reference. Pass it through rather than
            # guess: it is legal in a filename and this reader is not a shell.
            append out "\$"
            incr i
            continue
        }
        if {![info exists ::env($name)] || [string trim $::env($name)] eq ""} {
            set why "is not set in the environment"
            if {[info exists ::env($name)]} { set why "is set but EMPTY" }
            flow_refuse "the filelist needs \$$name and it $why." \
                "  wanted by: $where" \
                "  in:        $str" \
                "  An empty expansion would silently produce a path like" \
                "  '/src/rtl/foo.v', which is read as a missing file at the END" \
                "  of elaboration and looks like a broken link rather than a" \
                "  missing export - so this stops here instead." \
                "  mk/flow.mk exports every FPGA_* variable it defines, but a" \
                "  filelist may reference project variables it does not know:" \
                "  export it, or add it to the project's design.mk."
        }
        append out $::env($name)
        # Continue AFTER the substituted text, so a value containing a '$'
        # cannot be re-expanded. That is the infinite loop in the header.
        incr i [string length $m]
    }
    return $out
}

# Resolve a path named INSIDE a flist. Relative paths go against the naming
# flist's directory first and the cwd second - see RELATIVE PATHS in the header.
#
# RETURNS "" WHENEVER NOTHING IS THERE, ABSOLUTE PATHS INCLUDED. The first
# version of this proc returned an absolute path unchecked, on the reasoning that
# an absolute path needs no searching - and the phase-1 test for "a missing file
# must be a non-zero exit naming the path" caught it immediately: the caller's
# `file size` threw a raw Tcl error, so the reader died with exit 1 and a stack
# trace instead of exit 2 and a diagnosis. Every caller refuses on "", because
# only the caller knows whether the thing was meant to be a file, a directory or
# a sub-flist.
proc flist_resolve {path fromflist} {
    if {[file pathtype $path] eq "absolute"} {
        set a [file normalize $path]
        if {[file exists $a]} { return $a }
        return ""
    }
    set a [file normalize [file join [file dirname $fromflist] $path]]
    if {[file exists $a]} { return $a }
    set b [file normalize $path]
    if {[file exists $b]} { return $b }
    return ""
}

# The "where did I look" lines of a refusal. An absolute path was looked for in
# exactly one place and saying "tried, cwd-relative: <the same path>" twice reads
# as a reader that does not know what it did.
proc flist_tried {path fromflist} {
    if {[file pathtype $path] eq "absolute"} {
        return [list "  tried:                 [file normalize $path]"]
    }
    return [list \
        "  tried, flist-relative: [file normalize [file join [file dirname $fromflist] $path]]" \
        "  tried, cwd-relative:   [file normalize $path]"]
}


################################################################################
# 2. TOKENISING A FILELIST LINE
#
# TOKENS, NOT `string range $line 3 end`. The reference reader slices a fixed
# offset off the front of a line, so `-f  <path>` with two spaces yields a path
# with a leading space, and a line carrying two `+incdir+` tokens contributes
# one. Both are silent. Splitting on whitespace costs nothing and cannot do
# either.
#
# A trailing comment is stripped only when it is PRECEDED BY WHITESPACE. `//`
# appears inside paths ("a//b" is a legal, if ugly, path) and stripping it
# unconditionally deletes half of one.
################################################################################

proc flist_tokens {line} {
    set line [string trim $line]
    if {$line eq ""} { return {} }
    if {[string match "#*" $line] || [string match "//*" $line]} { return {} }
    regsub -- {[ \t]+(//|#).*$} $line "" line
    set out {}
    foreach t [split $line " \t"] {
        if {[string trim $t] ne ""} { lappend out [string trim $t] }
    }
    return $out
}


################################################################################
# 3. PASS 1 - SEARCH PATHS
#
# Collects +incdir+, -y and +libext+ over the WHOLE `-f` chain before a single
# file is read. See the header for the defect this ordering exists to prevent.
################################################################################

proc flist_scan {flist} {
    set norm [file normalize $flist]
    if {[lsearch -exact $::flist_stack $norm] >= 0} {
        flow_refuse "filelist include CYCLE: $norm includes itself." \
            "  stack: [join $::flist_stack { -> }]" \
            "  Without this guard the reader recurses until the interpreter" \
            "  runs out of stack, which reports as a Tcl crash inside Vivado" \
            "  and says nothing about filelists."
    }
    if {![file exists $flist]} {
        flow_refuse "no filelist at $flist" \
            "  RTL_FLIST in the project's design.mk names the top-level" \
            "  filelist. It is the single input that decides what design gets" \
            "  built: in this codebase there is no \`ifdef FPGA and no \`ifdef" \
            "  ASIC anywhere, so which wrapper family the flist names IS the" \
            "  configuration (CONTRACT.md section 9.1)."
    }
    if {![file size $flist]} {
        flow_refuse "$flist is ZERO BYTES." \
            "  An empty filelist reads as a design with no RTL, and every" \
            "  number downstream of it would be about nothing."
    }
    lappend ::flist_stack $norm
    if {[lsearch -exact $::flist_chain $norm] < 0} { lappend ::flist_chain $norm }

    set fh [open $flist r]
    set lineno 0
    while {[gets $fh line] >= 0} {
        incr lineno
        set toks [flist_tokens $line]
        set ntok [llength $toks]
        for {set i 0} {$i < $ntok} {incr i} {
            set t [lindex $toks $i]
            set where "$flist:$lineno"
            if {[string match "+incdir+*" $t]} {
                foreach d [split [string range $t 8 end] "+"] {
                    if {$d eq ""} { continue }
                    set d [flist_expand_env $d $where]
                    set r [flist_resolve $d $flist]
                    if {$r eq ""} {
                        flow_refuse "+incdir+ names a directory that does not exist: $d" \
                            "  named at: $where" \
                            "  An include path that is not there is not an" \
                            "  error in any tool - the headers in it simply" \
                            "  fail to resolve, thousands of lines later, in a" \
                            "  file that does not mention this one."
                    }
                    if {[lsearch -exact $::flist_incdirs $r] < 0} {
                        lappend ::flist_incdirs $r
                    }
                }
            } elseif {[string match "+libext+*" $t]} {
                foreach e [split [string range $t 8 end] "+"] {
                    if {$e ne "" && [lsearch -exact $::flist_libext $e] < 0} {
                        lappend ::flist_libext $e
                    }
                }
            } elseif {$t eq "-y"} {
                incr i
                set d [lindex $toks $i]
                if {$d eq ""} { flow_refuse "$where: '-y' with no directory after it." }
                set d [flist_expand_env $d $where]
                set r [flist_resolve $d $flist]
                if {$r eq "" || ![file isdirectory $r]} {
                    flow_refuse "-y names a directory that does not exist: $d" \
                        "  named at: $where" \
                        "  read_verilog has no -y, so this reader has to glob" \
                        "  the directory itself. It cannot glob one that is" \
                        "  not there, and every module it was meant to supply" \
                        "  would become a black box that Vivado reports as a" \
                        "  warning and synthesises anyway."
                }
                if {[lsearch -exact $::flist_ydirs $r] < 0} { lappend ::flist_ydirs $r }
            } elseif {$t eq "-f" || $t eq "-F"} {
                incr i
                set p [lindex $toks $i]
                if {$p eq ""} { flow_refuse "$where: '$t' with no filelist after it." }
                set p [flist_expand_env $p $where]
                set r [flist_resolve $p $flist]
                if {$r eq ""} {
                    flow_refuse "nested filelist not found: $p" \
                        "  named at:              $where" \
                        {*}[flist_tried $p $flist] \
                        "  The stage runs with cwd = the run's work directory" \
                        "  (mk/flow.mk cd's there so tool scratch stays out of" \
                        "  the repository), so a cwd-relative path in a" \
                        "  filelist resolves against a directory that holds" \
                        "  nothing. Make it absolute, or \${VAR}-rooted."
                }
                flist_scan $r
            }
        }
    }
    close $fh
    set ::flist_stack [lrange $::flist_stack 0 end-1]
}


################################################################################
# 4. PASS 2 - SOURCES
################################################################################

# .sv/.v/.vhd, by extension.
#
# BY EXTENSION, NOT "EVERYTHING IS SystemVerilog". The ASIC reader defaults every
# file to SV because a mixed codebase routinely has `.v` leaves using SV
# constructs. That reasoning does not carry to Vivado, because the failure is not
# symmetric: `read_verilog -sv` on a Verilog-2001 file makes every SystemVerilog
# keyword a reserved word, and `logic`, `bit`, `do`, `final`, `ref`, `packed` and
# `global` are all perfectly ordinary Verilog-2001 identifiers. A vendor library
# with a net named `logic` fails to parse under -sv and parses fine without it.
#
# So the extension decides, and FLIST_SV_DEFAULT=1 opts the whole flist into -sv
# when a project knows its `.v` files need it. SV_FILES in design.mk is the
# per-file form for the usual case, where three files need it and four hundred
# do not.
proc flist_dialect {path} {
    global FLIST_SV_DEFAULT
    set ext [string tolower [file extension $path]]
    switch -exact -- $ext {
        .sv     -
        .sva    -
        .svp    { return sv }
        .vhd    -
        .vhdl   { return vhdl }
        .vh     -
        .svh    { return header }
    }
    # Anything else - .v, .veo, .vp, no extension at all - is Verilog.
    if {$FLIST_SV_DEFAULT} { return sv }
    return v
}

proc flist_emit {cmd} { lappend ::flist_cmds $cmd }

# Does this file declare a compilation unit? Only asked of files found by
# globbing a `-y` directory; a file listed EXPLICITLY is read whatever is in it,
# because the flist author said so and this reader does not second-guess that.
proc flist_declares_unit {file} {
    if {[catch {open $file r} fh]} { return 1 }
    set found 0
    while {[gets $fh line] >= 0} {
        if {[regexp {^[ \t]*(module|macromodule|primitive|package|interface|program)[ \t]+[A-Za-z0-9_]} $line]} {
            set found 1
            break
        }
        if {[regexp -nocase {^[ \t]*(entity|architecture)[ \t]+[A-Za-z0-9_]} $line]} {
            set found 1
            break
        }
    }
    close $fh
    return $found
}

# Read every compilation unit in one -y directory. See the header: Vivado has no
# -y, so this is the only thing that makes those modules exist.
proc flist_expand_y {ydir} {
    set n 0
    set skipped 0
    foreach ext $::flist_libext {
        foreach f [lsort [glob -nocomplain -directory $ydir *$ext]] {
            if {[lsearch -exact $::flist_files_read $f] >= 0} { continue }
            if {![flist_declares_unit $f]} { incr skipped ; continue }
            switch -exact -- [flist_dialect $f] {
                header  { incr skipped ; continue }
                vhdl    { flist_emit "read_vhdl [list $f]" }
                sv      { flist_emit "read_verilog -sv [list $f]" }
                default { flist_emit "read_verilog [list $f]" }
            }
            lappend ::flist_files_read $f
            incr ::flist_files
            incr n
        }
    }
    say [format "  -y %-4d compilation unit(s), %d fragment(s) skipped   %s" $n $skipped $ydir]
    if {$n == 0} {
        warn "-y $ydir contributed NO compilation units (extensions:\
              [join $::flist_libext { }]). If it holds RTL this design needs,\
              every module in it is now a BLACK BOX - which Vivado reports as a\
              warning and then synthesises, places, routes and writes a\
              bitstream for. Check +libext+."
    }
}

proc flist_note_ignored {tok where} {
    global FLIST_STRICT_OPTS
    if {$FLIST_STRICT_OPTS} {
        flow_refuse "$where: unrecognised filelist option '$tok'" \
            "  FLIST_STRICT_OPTS=1 makes this fatal. Unset it to downgrade" \
            "  unrecognised options to a warning and a manifest entry."
    }
    lappend ::flist_ignored "$tok ($where)"
}

proc flist_sources {flist} {
    global FLIST_Y_EXPAND
    set fh [open $flist r]
    set lineno 0
    while {[gets $fh line] >= 0} {
        incr lineno
        set toks [flist_tokens $line]
        set ntok [llength $toks]
        for {set i 0} {$i < $ntok} {incr i} {
            set t [lindex $toks $i]
            set where "$flist:$lineno"

            if {[string match "+incdir+*" $t] || [string match "+libext+*" $t]} {
                continue                                    ;# pass 1 owns these
            } elseif {$t eq "-y"} {
                incr i
                if {$FLIST_Y_EXPAND} {
                    flist_expand_y [flist_resolve [flist_expand_env [lindex $toks $i] $where] $flist]
                }
            } elseif {[string match "+define+*" $t]} {
                foreach d [split [string range $t 8 end] "+"] {
                    if {$d ne ""} { lappend ::flist_defines [flist_expand_env $d $where] }
                }
            } elseif {$t eq "-define" || $t eq "-d"} {
                incr i
                set d [lindex $toks $i]
                if {$d eq ""} { flow_refuse "$where: '$t' with no define after it." }
                lappend ::flist_defines [flist_expand_env $d $where]
            } elseif {$t eq "-f" || $t eq "-F"} {
                incr i
                flist_sources [flist_resolve [flist_expand_env [lindex $toks $i] $where] $flist]
            } elseif {$t eq "-v"} {
                incr i
                set p [lindex $toks $i]
                if {$p eq ""} { flow_refuse "$where: '-v' with no file after it." }
                flist_read_source $p $flist $where
            } elseif {[string match "-*" $t] || [string match "+*" $t]} {
                flist_note_ignored $t $where
            } else {
                flist_read_source $t $flist $where
            }
        }
    }
    close $fh
}

# One source file: expand, resolve, refuse if absent, emit the read command.
#
# A `.vh`/`.svh` listed as a source is treated as a HEADER, not as a compilation
# unit: its directory joins the include path and the file itself is not read.
# Reading a header standalone in Vivado is a syntax error at best and a duplicate
# macro definition at worst, and a flist that lists one almost always means "make
# this reachable", which is what an include directory does.
proc flist_read_source {tok fromflist where} {
    set p [flist_expand_env $tok $where]
    set r [flist_resolve $p $fromflist]
    if {$r eq ""} {
        flow_refuse "source file not found: $p" \
            "  named at:              $where" \
            {*}[flist_tried $p $fromflist] \
            "  A source that is silently dropped elaborates as a black box," \
            "  which Vivado reports as a WARNING and then synthesises, places," \
            "  routes and writes a bitstream for. Every number about that run" \
            "  would be about a design nobody asked for, so this stops here."
    }
    if {![file size $r]} {
        flow_refuse "$r is ZERO BYTES." \
            "  named at: $where" \
            "  That is the shape a generator leaves when it opened its output" \
            "  and then died, and it satisfies every 'test -e' in the world."
    }
    if {[lsearch -exact $::flist_files_read $r] >= 0} {
        # Not fatal: reported at the end, once, with the whole list.
        return
    }
    set d [flist_dialect $r]
    if {$d eq "header"} {
        lappend ::flist_headers $r
        set dir [file dirname $r]
        if {[lsearch -exact $::flist_incdirs $dir] < 0} { lappend ::flist_incdirs $dir }
        warn "[file tail $r] is a header, listed as a source at $where."
        warn "  Its directory joins the include path and the file is NOT read:"
        warn "  Vivado compiles a header handed to read_verilog as a compilation"
        warn "  unit, which is a syntax error or a duplicate macro. Reach it"
        warn "  with \`include, as the file was written to be reached."
        return
    }
    switch -exact -- $d {
        vhdl { flist_emit "read_vhdl [list $r]" }
        sv   { flist_emit "read_verilog -sv [list $r]" }
        default {
            # SV_FILES forces a named file to SystemVerilog. CONTRACT.md section
            # 3.3: "force file_type SystemVerilog per file".
            set forced 0
            foreach s [split [flow_env FPGA_SV_FILES]] {
                if {$s ne "" && [file normalize $s] eq $r} { set forced 1 ; break }
            }
            if {$forced} {
                flist_emit "read_verilog -sv [list $r]"
            } else {
                flist_emit "read_verilog [list $r]"
            }
        }
    }
    lappend ::flist_files_read $r
    incr ::flist_files
}


################################################################################
# 5. THE PUBLIC ENTRY POINT
################################################################################

proc flist_read {flist} {
    global FLIST_Y_EXPAND FLIST_DEFINES FLIST_INCDIRS

    set ::flist_incdirs    {}
    set ::flist_ydirs      {}
    # .v is ALWAYS in the extension set: it is the Verilog default and every
    # vendor -y deliverable in this tree uses it. +libext+ ADDS to this, so a
    # flist naming only its exotic extensions does not lose the ordinary one.
    set ::flist_libext     {.v}
    set ::flist_defines    {}
    set ::flist_files_read {}
    set ::flist_headers    {}
    set ::flist_cmds       {}
    set ::flist_ignored    {}
    set ::flist_stack      {}
    set ::flist_chain      {}
    set ::flist_files      0

    # Project-wide defines apply to everything, so they are registered before the
    # first file rather than discovered inside some sub-flist.
    foreach d [split $FLIST_DEFINES] {
        if {[string trim $d] ne ""} { lappend ::flist_defines [string trim $d] }
    }
    foreach d [split [flow_env FPGA_RTL_DEFINES]] {
        if {[string trim $d] ne ""} { lappend ::flist_defines [string trim $d] }
    }

    flist_scan $flist

    # Extra include dirs go in FRONT: a project overriding a header wants its
    # copy found first, and search order is the only mechanism there is.
    set extra {}
    foreach d [concat [split $FLIST_INCDIRS] [split [flow_env FPGA_RTL_INCDIRS]]] {
        if {[string trim $d] eq ""} { continue }
        set n [file normalize [string trim $d]]
        if {![file isdirectory $n]} {
            flow_refuse "RTL_INCDIRS names a directory that does not exist: $d" \
                "  A configured-but-missing optional input is an error, not a" \
                "  shrug (CONTRACT.md section 3.3): the headers in it would" \
                "  fail to resolve with no message naming this variable."
        }
        if {[lsearch -exact $extra $n] < 0} { lappend extra $n }
    }
    set ::flist_incdirs [concat $extra $::flist_incdirs]

    flist_sources $flist

    if {$::flist_files == 0} {
        flow_refuse "the filelist resolved to ZERO source files: $flist" \
            "  Every line was a comment, an option, or a -f include that was" \
            "  itself empty. Elaboration would produce an empty design and" \
            "  every number downstream of it would be fiction."
    }

    if {!$FLIST_Y_EXPAND && [llength $::flist_ydirs]} {
        warn "[llength $::flist_ydirs] '-y' library director(ies) were NOT read,"
        warn "  because FLIST_Y_EXPAND=0. read_verilog HAS NO -y: Vivado"
        warn "  implements no library-directory lookup, so nothing else in this"
        warn "  flow will read them either. Every module they were meant to"
        warn "  supply is now a BLACK BOX - reported as a warning, synthesised,"
        warn "  placed, routed and written into a bitstream that configures and"
        warn "  does nothing. Set FLIST_Y_EXPAND=1, or gate on"
        warn "  EXPECT_BLACKBOX_MAX and read the census."
        foreach d $::flist_ydirs { warn "    -y $d" }
    }

    if {[llength $::flist_ignored]} {
        warn "[llength $::flist_ignored] filelist option(s) were not recognised"
        warn "  and had NO effect on what was read. Most are simulator-only"
        warn "  (-timescale, +notimingcheck, -sverilog) and that is fine; one"
        warn "  that was meant to change the build is a silent misconfiguration."
        warn "  Set FLIST_STRICT_OPTS=1 to make them fatal."
        foreach o $::flist_ignored { warn "    $o" }
    }
    return $::flist_files
}

# The materialised sources.tcl - what every later stage sources to get the
# design, and the artefact `make flist` asserts on.
#
# THE INCLUDE DIRS AND THE DEFINES ARE EMITTED ONCE EACH, AS A UNION, AND
# APPENDED TO WHATEVER THE FILESET ALREADY CARRIES. `set_property include_dirs`
# and `set_property verilog_define` REPLACE the property; that is the same shape
# as the defect in the header, one layer down.
#
# THE DEFINES ARE ALSO WRITTEN OUT AS A PLAIN LIST, and that is not redundant.
# `ipx::package_project` DROPS fileset defines by three separate routes
# (CONTRACT.md section 9.2). It has already failed silently here once: an opt-in
# guarded by an `ifdef was false in EVERY FPGA build, proven by a byte-identical
# "feature-off" bitstream. So the list is left in a variable a later stage can
# pass to `synth_design -verilog_define` directly, which survives, and the
# project's real mechanism for anything load-bearing is RTL_PARAMS - parameters
# survive packaging as CONFIG.*, defines do not.
proc flist_write_sources {out} {
    set fh [open $out w]
    puts $fh "################################################################################"
    puts $fh "# sources.tcl - GENERATED by flow/common/read_flist.tcl. Do not edit."
    puts $fh "# from filelist : [file normalize [lindex $::flist_chain 0]]"
    puts $fh "# filelists read : [llength $::flist_chain]"
    puts $fh "# source files   : $::flist_files"
    puts $fh "# include dirs   : [llength $::flist_incdirs]"
    puts $fh "# defines        : [llength $::flist_defines]"
    puts $fh "# written        : [clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%S%z}]"
    puts $fh "################################################################################"
    puts $fh ""
    puts $fh "set flist_incdirs [list $::flist_incdirs]"
    puts $fh "set flist_defines [list $::flist_defines]"
    puts $fh "set flist_files   $::flist_files"
    puts $fh ""
    puts $fh "# ONE assignment, appended. set_property REPLACES this property, so one"
    puts $fh "# call per +incdir+ leaves exactly the last directory standing - measured"
    puts $fh "# on the reference toolkit: 41 +incdir+ lines, one surviving directory."
    puts $fh "if {\[llength \[info commands current_fileset\]\] && !\[catch {current_fileset} __fs\]} {"
    puts $fh "    if {\[llength \$flist_incdirs\]} {"
    puts $fh "        set_property include_dirs \\"
    puts $fh "            \[concat \[get_property include_dirs \$__fs\] \$flist_incdirs\] \$__fs"
    puts $fh "    }"
    puts $fh "    if {\[llength \$flist_defines\]} {"
    puts $fh "        set_property verilog_define \\"
    puts $fh "            \[concat \[get_property verilog_define \$__fs\] \$flist_defines\] \$__fs"
    puts $fh "    }"
    puts $fh "    unset __fs"
    puts $fh "}"
    puts $fh ""
    foreach c $::flist_cmds { puts $fh $c }
    puts $fh ""
    puts $fh "# Copyright (C) 2026, SoC Labs (www.soclabs.org)"
    close $fh
    return $out
}

# Execute the reads in the running tool. Used by the flist stage when it wants
# the design in memory as well as on disk (non-project flows).
proc flist_apply {} {
    if {![flow_have read_verilog]} {
        die "flist_apply: this tool has no read_verilog." \
            "  The filelist parsed and sources.tcl was written, but nothing" \
            "  read it. Run this from Vivado, or source the generated" \
            "  sources.tcl from a stage that is."
    }
    foreach c $::flist_cmds { uplevel #0 $c }
    return $::flist_files
}

# One block a human can diff between two runs without opening a manifest.
proc flist_summary {} {
    say "filelists read : [llength $::flist_chain]"
    say "source files   : $::flist_files"
    say "include dirs   : [llength $::flist_incdirs]"
    foreach d $::flist_incdirs { say "  +incdir+ $d" }
    say "-y dirs        : [llength $::flist_ydirs]\
         [expr {$::FLIST_Y_EXPAND ? {(expanded)} : {(NOT READ)}}]"
    say "defines        : [expr {[llength $::flist_defines] ? [join $::flist_defines { }] : {(none)}}]"
    say "libext         : [join $::flist_libext { }]"
    if {[llength $::flist_headers]} {
        say "headers seen   : [llength $::flist_headers] (dirs added to +incdir+, files not read)"
    }
    # A path read twice is two definitions of one module and an elaboration error
    # a long way from here. flist_read_source already de-duplicates, so this
    # reports what it absorbed rather than letting it through.
    set n [expr {[llength $::flist_cmds] - $::flist_files}]
    if {$n > 0} { say "commands       : [llength $::flist_cmds]" }
}


################################################################################
# 6. TWO ENTRY MODES
#
# Sourced by a stage : parse $FPGA_RTL_FLIST and write $(WORK_DIR)/sources.tcl,
#                      so the whole RTL read is one `source`.
# Run under tclsh    : a CLI, so the phase-1 suite can exercise every branch
#                      with no tool and no licence. `make check` and the tests
#                      must be able to prove this file works; a reader that can
#                      only be tested by launching Vivado is a reader nobody
#                      tests.
################################################################################

if {[info exists ::argv0] &&
    [file normalize $::argv0] eq [file normalize [info script]]} {

    flow_config prefix FLIST
    set __out ""
    set __in  ""
    set __quiet 0
    for {set __i 0} {$__i < [llength $::argv]} {incr __i} {
        set __a [lindex $::argv $__i]
        switch -exact -- $__a {
            -o      { incr __i ; set __out [lindex $::argv $__i] }
            -q      { set __quiet 1 }
            --      { incr __i ; set __in [lindex $::argv $__i] }
            default {
                if {[string match "-*" $__a]} {
                    puts "usage: tclsh read_flist.tcl \[-o <out.tcl>\] \[-q\] <flist>"
                    exit 2
                }
                set __in $__a
            }
        }
    }
    if {$__in eq ""} {
        puts "usage: tclsh read_flist.tcl \[-o <out.tcl>\] \[-q\] <flist>"
        puts "  Parses <flist> and prints the Vivado commands it would issue."
        puts "  Exit 0 ok, 2 refused (unset variable, missing file, cycle)."
        exit 2
    }
    flist_read $__in
    if {!$__quiet} { flist_summary }
    if {$__out ne ""} {
        flist_write_sources $__out
        say "wrote $__out"
    } else {
        puts "# --- commands ---"
        puts "set_property include_dirs [list $::flist_incdirs] \[current_fileset\]"
        if {[llength $::flist_defines]} {
            puts "set_property verilog_define [list $::flist_defines] \[current_fileset\]"
        }
        foreach __c $::flist_cmds { puts $__c }
    }
    exit 0
}

# --- sourced by a stage --------------------------------------------------------
#
# Deliberately does the read at source time, exactly as the reference does, so a
# stage script gets the whole RTL read from one `source` line and cannot forget
# the second half of it.
set __flist [flow_need_env FPGA_RTL_FLIST \
    "It names the RTL filelist. The project's design.mk sets RTL_FLIST, and in\
     this codebase the filelist IS the configuration - selection is by file-swap\
     between wrapper families, not by define."]

step "read RTL from [file tail $__flist]"
flist_read $__flist
flist_summary

if {[info exists ::WORK_DIR]} {
    flist_write_sources [file join $::WORK_DIR sources.tcl]
    say "sources: [file join $::WORK_DIR sources.tcl]"
} else {
    warn "WORK_DIR is not set, so no sources.tcl was written. The design was"
    warn "  parsed and nothing recorded it; every later stage sources that file."
}
unset __flist

# Copyright (C) 2026, SoC Labs (www.soclabs.org)
