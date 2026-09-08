################################################################################
# 1_flist.tcl - STAGE 1: resolve the project's filelist into the ONE source list
#               every later stage reads
#
# Invoked by `make flist` through mk/flow.mk's `vivado_stage`. It writes
# $(WORK_DIR)/sources.tcl and $(REPORT_DIR)/flist_manifest.txt, and those two are
# what the stage is judged on - by mk/flow.mk when make ran it, and by
# ci/assert-stage.sh afterwards when it did not.
#
#
# WHY A WHOLE STAGE, AND WHY IT LAUNCHES VIVADO TO DO ALMOST NO VIVADO WORK
# ===========================================================================
# Everything below could run under a bare tclsh, and read_flist.tcl deliberately
# does. This stage exists anyway, because the failures it catches are the ones
# that are otherwise found FORTY MINUTES INTO SYNTHESIS, or not at all:
#
#   * a source path in the flist that does not resolve. Dropped silently by a
#     lesser reader; here it is a refusal in about two seconds.
#   * a top module nothing in the source list declares. CONTRACT.md section 3.2
#     says of TOP, "getting this wrong is quiet" - it is quiet because Vivado
#     synthesises the wrong module, or an empty one, and reports a WARNING.
#   * a define that RTL_DEFINES_NEVER asserts is absent and that is present.
#
# The stage runs inside the tool for one further reason: it is the first thing a
# new project runs after `make check`, so it is where "can this host actually
# launch Vivado, and which Vivado" gets answered, in seconds, with a manifest
# recording the version. A project that discovers its licence problem in stage 5
# has spent an afternoon on it.
#
#
# WHAT THIS STAGE DOES NOT DO, STATED HERE BECAUSE IT IS EASY TO ASSUME IT DOES
# ===========================================================================
# IT DOES NOT PARSE THE RTL. Nothing here elaborates. A file that exists, is
# non-empty and is unreadable garbage passes every check below - it is a SOURCE
# LIST check, not a design check. The gate file says so in as many words, because
# a green flist stage reads like a clean bill of health and is not one.
#
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
################################################################################

################################################################################
# THE BOOT LAYER IS FOUND FROM THIS FILE, NOT THROUGH FPGA_FLOW_DIR
#
# CONTRACT.md section 12.1 writes the first line of the skeleton as
#
#     source [file join $env(FPGA_FLOW_DIR) flow common flow_utils.tcl]
#
# and that spelling DISARMS THE SPLIT-INSTALL CHECK it is about to run.
# flow_boot refuses a run where FPGA_FLOW_DIR names one checkout while the
# flow_utils.tcl that is executing came out of another - the two-checkouts trap,
# which this site's projects hit repeatedly through submodules. It detects it by
# comparing ::flow_common_dir against FPGA_FLOW_DIR. Source flow_utils THROUGH
# FPGA_FLOW_DIR and both sides of that comparison come from the same variable,
# so it can never fail: half the engine would come from each checkout and the
# check written to catch exactly that would pass.
#
# Resolving it from `info script` is also the house rule for an addressable
# artefact (CONTRACT.md section 10): it resolves its own location rather than
# trusting a variable or a cwd. The check in flow_boot then means something.
################################################################################
set _stage_flow_dir [file dirname [file dirname [file normalize [info script]]]]
source [file join $_stage_flow_dir common flow_utils.tcl]

flow_config prefix FLIST
flow_boot
flow_banner flist


################################################################################
# KNOBS
#
# At the LEFT MARGIN, one per line. flow_knob_scan reads these files rather than
# executing them, so `make help-knobs` and the manifest both find a knob without
# launching Vivado - and a knob indented into a conditional is a knob neither of
# them can see.
#
# read_flist.tcl declares five more (FLIST_Y_EXPAND, FLIST_SV_DEFAULT,
# FLIST_DEFINES, FLIST_INCDIRS, FLIST_STRICT_OPTS). They are NOT repeated here:
# a second declaration would put two defaults in the tree for one knob and the
# one that is wrong is always the copy you are not reading.
################################################################################

opt FLIST_ASSERT_TOP    1   ;# 1 = require TOP to be declared by a file that was read
opt FLIST_HASH_SOURCES  1   ;# 1 = sha256 every source into the census. 0 = list them unhashed
opt FLIST_APPLY         0   ;# 1 = also read the sources into THIS session (see below)
opt FLIST_TOP_IN_SOURCES 0  ;# 1 = append TOP_HDL and EXTRA_SRCS to sources.tcl. See section 3


################################################################################
# THE GATE AND THE STAGE-MEASUREMENT BLOCK LIVE IN provenance.tcl
#
# They were written here, and in the five other stage scripts, because
# prov_manifest wrote CONTRACT.md section 5's seven blocks and closed the file
# with no slot for a stage's own measurements - while ci/assert-stage.sh
# REQUIRES those measurements as top-level manifest keys. Two sessions hit that
# independently and each invented the same workaround, so there were six copies
# of a local block-8 emitter and six of a gate writer.
#
# They are now `prov_stage_field` / `prov_stage_fields` and `prov_gate` in
# flow/common/provenance.tcl, which owns manifest emission and already owned the
# site-path rule the measurements have to go through. flow_boot sources that
# file, so nothing here has to.
################################################################################


################################################################################
# 1. THE SEAM, THEN THE INPUTS
################################################################################

flow_hook pre_flist

# WHY THIS IS ASSERTED HERE AND NOT LEFT TO read_flist.tcl. read_flist refuses a
# missing flist too, and its message is good - but it refuses from inside a
# `source` at the point it needs the file, and this stage wants the refusal
# BEFORE it has claimed to be doing anything. flow_assert_input also
# distinguishes zero bytes from absent, which is the shape a flist generator
# leaves when it opened its output and then died.
# THERE IS NO "NOT CONFIGURED" PATH FOR THIS STAGE, and that is not an omission.
# CONTRACT.md section 12.2 rule 7 is about a stage a project may legitimately
# switch off - package-ip and bd, selected by PACKAGE_TCL and BD_TCL. The flist
# is not optional: RTL_FLIST is a REQUIRED input (section 3.2) and a design with
# no source list is not a design with a smaller scope, it is no design at all. So
# an absent flist is a REFUSAL - exit 2, nothing measured - and not a manifest
# recording that this run built nothing on purpose.
set RTL_FLIST [flow_env FPGA_RTL_FLIST]
flow_assert_input $RTL_FLIST \
    "the master RTL filelist. In THIS codebase the filelist IS the\
     configuration: there is no `ifdef FPGA and no `ifdef ASIC anywhere in the\
     tree, so which wrapper family the flist names is the whole selection\
     mechanism (CONTRACT.md section 9.1)" \
    RTL_FLIST

################################################################################
# RTL_FLIST_GEN - THE GENERATOR HAS ALREADY RUN, AND THIS IS WHERE THAT IS
# CHECKED RATHER THAN ASSUMED
#
# RTL_FLIST_GEN names a make target IN THE PROJECT that regenerates the flist.
# mk/flow.mk deliberately does not invoke it - "a toolkit that runs a project
# target it did not define cannot say what that target did" - so the project
# runs it with a prerequisite append (CONTRACT.md section 6.3) and by the time
# this stage starts it has either run or been forgotten.
#
# Those two look identical from here, and this stage cannot tell them apart:
# nothing records when the target ran, and a timestamp comparison against the
# flist would be wrong the moment the generator is a no-op on an up-to-date
# file. So what is done is what CAN be done honestly: the OUTPUT is asserted to
# exist and to be non-empty, the generator's NAME is recorded in the manifest,
# and the manifest's flist hash is the thing that proves which file this run
# actually read. A stale flist and a fresh one differ there and nowhere else.
################################################################################
set RTL_FLIST_GEN [flow_env FPGA_RTL_FLIST_GEN]
if {$RTL_FLIST_GEN ne ""} {
    say "RTL_FLIST_GEN is '$RTL_FLIST_GEN' - the project regenerates this flist."
    say "  Its output is asserted above; whether the target ran for THIS build"
    say "  is not knowable from here, and the flist sha256 in the manifest is"
    say "  what tells two versions of it apart."
}

# The point-of-use hash of the flist, taken NOW rather than at manifest time.
# Concurrent sessions editing one working tree is the normal condition here, and
# a generator that reruns mid-stage is exactly what RTL_FLIST_GEN is for.
prov_pin flist $RTL_FLIST flist-stage-read


################################################################################
# 2. READ THE FILELIST
#
# read_flist.tcl does the work at SOURCE time and writes sources.tcl itself -
# that is its documented interface and it is deliberate, so a stage cannot read
# the flist and then forget to record it. This file does not reimplement any of
# it; everything below reads the state it leaves behind:
#
#   ::flist_files       source count          ::flist_chain    every -f file read
#   ::flist_files_read  every source path     ::flist_incdirs  the include union
#   ::flist_defines     every define          ::flist_ydirs    -y dirs
#   ::flist_headers     headers listed as sources
#   ::flist_ignored     options it did not recognise
################################################################################

step "read the filelist"
source [file join $_stage_flow_dir common read_flist.tcl]

set SOURCES_TCL [file join $WORK_DIR sources.tcl]
if {![file exists $SOURCES_TCL] || ![file size $SOURCES_TCL]} {
    die "read_flist.tcl did not write $SOURCES_TCL" \
        "  It parsed the filelist and reported [set ::flist_files] source" \
        "  file(s), so the read itself worked and the WRITE did not. Check the" \
        "  work directory is writable:" \
        "    ls -ld $WORK_DIR"
}


################################################################################
# 3. TOP_HDL AND EXTRA_SRCS - READ AFTER THE FLIST, APPENDED TO THE SAME FILE
#
# CONTRACT.md section 3.3: TOP_HDL is "read AFTER the flist - board top goes
# here", because the board-level top instantiates what the flist defined.
#
# OFF BY DEFAULT, AND THE DEFAULT IS A MEASUREMENT RATHER THAN A PREFERENCE.
#
# There are exactly two coherent designs here and only one of them can be live:
#
#   A  sources.tcl IS THE WHOLE DESIGN. The board top is in it, every stage that
#      sources it gets a complete design, and no stage can forget the second
#      half of the read. The failure it prevents is the silent one - TOP
#      elaborates as a black box, Vivado warns, and the design routes and
#      configures and does nothing.
#   B  sources.tcl IS THE FLIST, and each stage that needs the board top reads
#      TOP_HDL itself.
#
# flow/vivado/4_synth.tcl - written against the same CONTRACT.md, committed
# 2026-09-08 - implements B: it sources sources.tcl and then reads TOP_HDL and
# EXTRA_SRCS itself, under the same section 3.3 sentence. Running A and B
# together reads every TOP_HDL file TWICE, which is a duplicate module
# definition at elaboration.
#
# CONTRACT.md 3.3 says only "read AFTER the flist" and does not say by whom, so
# neither file is wrong and both cannot be on. This one yields: the knob stays,
# because A is the better design and a project driving its own flow may want it,
# and the DEFAULT is B, because that is what the stage which actually consumes
# the result already does. Turning this on requires turning 4_synth.tcl's own
# read off. Recorded in the handback; the durable fix is one sentence in
# CONTRACT.md 3.3 naming the owner.
#
# THE CONSEQUENCE IS ALSO STATED IN THE GENERATED FILE, in the banner below, so
# that a reader who turns this on meets the hazard where they will hit it.
################################################################################

set TOP_HDL    [flow_env FPGA_TOP_HDL]
set EXTRA_SRCS [flow_env FPGA_EXTRA_SRCS]

# THE FILES ARE RESOLVED WHATEVER THE KNOB SAYS, and that is not tidiness.
#
# The knob decides who READS these files - this stage, or the synthesis stage.
# It does not decide whether they are PART OF THE DESIGN: they are, either way.
# The first version of this file resolved them only inside the append branch, so
# with the knob off the TOP-declaration check below could not see a board top
# that lived in TOP_HDL and reported it as declared nowhere. That is a FALSE HARD
# FAILURE on the commonest configuration there is, and it was found by running
# both settings rather than by reading the code.
#
# Resolving them here also means the "you named it, so it must exist" assertion
# (CONTRACT.md 3.3) fires on every run, in the stage that exists to find a
# source-list problem in seconds, instead of forty minutes later.
set tophdl_files {}
set sv {}
foreach x [split [flow_env FPGA_SV_FILES]] {
    if {[string trim $x] ne ""} { lappend sv [file normalize [string trim $x]] }
}
foreach {var val} [list TOP_HDL $TOP_HDL EXTRA_SRCS $EXTRA_SRCS] {
    foreach f [split $val] {
        set f [string trim $f]
        if {$f eq ""} { continue }
        flow_assert_input $f "a source named by $var, read after the flist" $var
        set n [file normalize $f]
        set ext [string tolower [file extension $n]]
        if {$ext eq ".vhd" || $ext eq ".vhdl"} {
            set cmd "read_vhdl [list $n]"
        } elseif {$ext eq ".sv" || $ext eq ".svh" || [lsearch -exact $sv $n] >= 0} {
            set cmd "read_verilog -sv [list $n]"
        } else {
            set cmd "read_verilog [list $n]"
        }
        lappend tophdl_files [list $var $n $cmd]
    }
}

set appended {}
if {$FLIST_TOP_IN_SOURCES && [llength $tophdl_files]} {
    step "append TOP_HDL and EXTRA_SRCS to sources.tcl"
    set fh [open $SOURCES_TCL a]
    puts $fh ""
    puts $fh "################################################################################"
    puts $fh "# TOP_HDL and EXTRA_SRCS, appended by flow/vivado/1_flist.tcl"
    puts $fh "# because FLIST_TOP_IN_SOURCES=1."
    puts $fh "#"
    puts $fh "# A STAGE THAT SOURCES THIS FILE MUST NOT ALSO READ TOP_HDL OR EXTRA_SRCS."
    puts $fh "# They are here, so reading them again is the same file read twice and a"
    puts $fh "# duplicate module definition at elaboration. flow/vivado/4_synth.tcl"
    puts $fh "# READS THEM ITSELF, so turning this knob on means turning that read off."
    puts $fh "################################################################################"
    foreach t $tophdl_files {
        foreach {var n cmd} $t break
        puts $fh $cmd
        lappend appended $n
        say "  $var: $cmd"
    }
    close $fh
} elseif {[llength $tophdl_files]} {
    say "[llength $tophdl_files] TOP_HDL/EXTRA_SRCS file(s) resolved and NOT appended"
    say "  to sources.tcl (FLIST_TOP_IN_SOURCES=0). flow/vivado/4_synth.tcl reads"
    say "  them itself; they are still checked for TOP below and recorded in the"
    say "  manifest, because they are part of the design either way."
}


################################################################################
# 4. THE CHECKS THIS STAGE CAN HONESTLY MAKE
#
# Every one of them is about the SOURCE LIST. None of them is about the RTL: see
# the header, and the gate file's NOT-covered section.
################################################################################

set hard {}

# --- 4.1 IS TOP DECLARED BY ANYTHING WE READ? --------------------------------
#
# CONTRACT.md section 3.2 on TOP: "The board-level top module. Not the SoC top -
# getting this wrong is quiet." This is where it stops being quiet. Vivado's
# answer to a top module that does not exist is to pick one by its own
# heuristic, synthesise it, and warn; the run then produces a full set of
# numbers about a design nobody asked for.
#
# A TEXT SCAN, AND ITS LIMITS ARE STATED. It looks for a `module <TOP>` or an
# `entity <TOP>` declaration in a file the flist actually read. It does not
# preprocess, so a top wrapped in an `ifdef reads as declared when it may not be,
# and a top produced by a generate or a macro is invisible to it. Those are why
# the finding is one-directional: FOUND is not a proof, NOT FOUND is a fact -
# nothing that was read declares it under that name.
set TOP [flow_env FPGA_TOP]
set top_in ""
if {$FLIST_ASSERT_TOP && $TOP ne ""} {
    step "is TOP='$TOP' declared by a file this flist reads?"
    set pat_v "^\[ \t\]*(module|macromodule)\[ \t\]+$TOP\[ \t\]*(\[#(;\]|$)"
    set pat_h "^\[ \t\]*(entity|architecture)\[ \t\]+$TOP\[ \t\]"
    set top_candidates $::flist_files_read
    foreach t $tophdl_files { lappend top_candidates [lindex $t 1] }
    foreach f $top_candidates {
        if {[catch {open $f r} fh]} { continue }
        set body [read $fh]
        close $fh
        foreach line [split $body "\n"] {
            if {[regexp $pat_v $line] || [regexp -nocase $pat_h $line]} {
                set top_in $f
                break
            }
        }
        if {$top_in ne ""} { break }
    }
    if {$top_in ne ""} {
        say "TOP '$TOP' is declared in [prov_site_path $top_in]"
    } else {
        lappend hard "TOP='$TOP' is declared by NONE of the [llength $::flist_files_read]\
                      source file(s) this flist reads, and none of the\
                      [llength $tophdl_files] file(s) named by TOP_HDL/EXTRA_SRCS.\
                      Vivado's answer to a missing top is to pick one by its own\
                      heuristic and warn, so the run would produce a complete set\
                      of numbers about a different design. Either TOP names the\
                      SoC top rather than the BOARD top (CONTRACT.md 3.2), or the\
                      file holding it is missing from the flist and from TOP_HDL."
        warn "TOP '$TOP' is declared by nothing that was read. See the gate file."
    }
}

# --- 4.2 RTL_DEFINES_NEVER, ASSERTED ABSENT ----------------------------------
#
# flow/steps/synth_setup.tcl makes the same assertion at synth_design, over the
# defines it is about to pass. It is made HERE as well, and over a WIDER set,
# for two reasons that are not redundancy:
#
#   * it fires in seconds rather than at the start of synthesis;
#   * RTL_DEFINES_INBODY NEVER REACHES synth_setup's LIST AT ALL. Those defines
#     are baked into materialised copies of the RTL by stage 2 (CONTRACT.md
#     9.2), so they are never passed as a define and synth_setup's check cannot
#     see them. A name asserted absent and then delivered in-body would pass
#     every check in the flow but this one.
set never {}
foreach n [split [flow_env FPGA_RTL_DEFINES_NEVER]] {
    if {[string trim $n] ne ""} { lappend never [string trim $n] }
}
if {[llength $never]} {
    step "RTL_DEFINES_NEVER: [join $never { }]"
    foreach {srcname srclist} [list \
        "the flist / RTL_DEFINES" $::flist_defines \
        "RTL_DEFINES_INBODY"      [split [flow_env FPGA_RTL_DEFINES_INBODY]] \
    ] {
        foreach d $srclist {
            set d [string trim $d]
            if {$d eq ""} { continue }
            set name [lindex [split $d =] 0]
            if {[lsearch -exact $never $name] >= 0} {
                lappend hard "RTL_DEFINES_NEVER asserts '$name' is ABSENT, and it is\
                              present in $srcname as '$d'. Nothing downstream can tell\
                              a design built with it from one built without."
            }
        }
    }
}

# --- 4.3 OPTIONALLY READ THE SOURCES INTO THIS SESSION -----------------------
#
# WHAT THIS PROVES, AND WHAT IT DOES NOT. read_verilog registers a file with the
# tool; it does NOT parse it. Vivado defers parsing to elaboration, so a syntax
# error still surfaces in stage 4 and not here. What this does catch is a file
# the tool refuses outright - an unreadable permission, a dialect Vivado will not
# accept at all - for the price of the memory. Off by default because the
# artefact this stage is judged on is sources.tcl, and reading it here proves
# nothing about the stage that will source it later.
if {$FLIST_APPLY} {
    step "read the sources into this session (FLIST_APPLY=1)"
    if {[flow_have read_verilog]} {
        say "applied [flist_apply] read command(s)"
    } else {
        warn "FLIST_APPLY=1 but this tool has no read_verilog - nothing was read."
    }
}


################################################################################
# 5. THE SOURCE CENSUS
#
# One line per source file, so the question "did this run read the file I think
# it did" has an answer that is not a 40,000-line log. It is a REPORT and not the
# manifest: the manifest's provenance block carries the filelist chain, which is
# what identifies the design; this is the expansion of it.
#
# HASHED IN BATCHES, and that is worth a line. prov_sha256 execs sha256sum once
# per file, which is right for the handful of files a manifest pins and wrong for
# a source list - the reference project's tapeout filelist resolves to thousands.
# One exec per 200 files turns half a minute into under a second. Anything the
# batch cannot account for is UNVERIFIED, never blank and never assumed equal:
# two empty strings compare equal and would turn a missing measurement into
# agreement.
################################################################################

step "source census"
set census [file join $REPORT_DIR flist_sources.txt]
set fh [open $census w]
puts $fh "# every source file this run read, in read order."
puts $fh "# Written by flow/vivado/1_flist.tcl. A path inside the run, the project"
puts $fh "# or the toolkit is labelled; anything else is a site path and appears"
puts $fh "# only as a digest (CONTRACT.md section 5)."
puts $fh "# sha256 'unhashed' means FLIST_HASH_SOURCES=0 - nobody took it. It is"
puts $fh "# not a measurement and must not be compared."
puts $fh ""
puts $fh [format "%-64s %-12s %s" "# sha256" bytes path]

array set hashof {}
if {$FLIST_HASH_SOURCES} {
    set batch {}
    foreach f $::flist_files_read {
        lappend batch $f
        if {[llength $batch] >= 200} {
            if {![catch {exec sha256sum -- {*}$batch} out]} {
                foreach line [split $out "\n"] {
                    if {[regexp {^([0-9a-f]{64})[ *]+(.*)$} [string trim $line] -> h p]} {
                        set hashof($p) $h
                    }
                }
            }
            set batch {}
        }
    }
    if {[llength $batch] && ![catch {exec sha256sum -- {*}$batch} out]} {
        foreach line [split $out "\n"] {
            if {[regexp {^([0-9a-f]{64})[ *]+(.*)$} [string trim $line] -> h p]} {
                set hashof($p) $h
            }
        }
    }
}
set n_hashed 0
foreach f $::flist_files_read {
    if {!$FLIST_HASH_SOURCES} {
        set h "unhashed(FLIST_HASH_SOURCES=0)"
    } elseif {[info exists hashof($f)]} {
        set h $hashof($f)
        incr n_hashed
    } else {
        set h "UNVERIFIED:sha256sum-did-not-account-for-this-file"
    }
    set b "UNVERIFIED:no-file"
    catch { set b [file size $f] }
    puts $fh [format "%-64s %-12s %s" $h $b [prov_site_path $f]]
}
close $fh
say "census: $census ([llength $::flist_files_read] file(s), $n_hashed hashed)"


################################################################################
# 6. THE SEAM, THEN THE WRITES
#
# CONTRACT.md section 6.1.3, SETTLED: every post_* seam fires BEFORE the stage
# writes its artefacts, and the gate is computed AFTER the seam.
#
# It matters here for the same reason it matters at impl. A hook at post_flist
# that adds a source - a generated package, a firmware-derived memory image - has
# to be able to put it into sources.tcl, because sources.tcl is what the next
# stage reads and nothing else crosses the boundary. Fire the seam after the
# write and the hook edits a variable nobody reads again: it would run, be
# recorded in hooks_run, and have no effect.
#
# So the hook may append to $SOURCES_TCL, or set ::FLIST_EXTRA_CMDS to a list of
# read commands, and the block below writes them.
#
# HONEST QUALIFICATION, BECAUSE THIS STAGE IS THE ONE PLACE THE RULE IS NOT
# LITERALLY SATISFIED. read_flist.tcl writes sources.tcl AT SOURCE TIME - that is
# its documented interface and a deliberate one, so that a stage cannot read a
# filelist and then forget to record it. The file therefore exists before this
# seam fires, and no reordering available to this file changes that.
#
# What matters is preserved, and it is the property the rule exists for: the
# artefact is still OPEN when the hook runs, the hook can change what the next
# stage will read, and the gate below is computed afterwards. A hook here is not
# editing a file that has already been handed on. If read_flist.tcl ever grows a
# 'parse but do not write' mode, this stage should use it and write once, after
# the seam.
################################################################################

flow_hook post_flist

if {[info exists ::FLIST_EXTRA_CMDS] && [llength $::FLIST_EXTRA_CMDS]} {
    say "post_flist contributed [llength $::FLIST_EXTRA_CMDS] read command(s)"
    set fh [open $SOURCES_TCL a]
    puts $fh ""
    puts $fh "# contributed by the project's post_flist hook"
    foreach c $::FLIST_EXTRA_CMDS { puts $fh $c ; say "  $c" }
    close $fh
}

# --- THE ARTEFACT ASSERTION --------------------------------------------------
#
# ON THE ARTEFACT, NEVER ON EXIT STATUS (CONTRACT.md rule 0). Nothing above
# returned a status worth trusting: Vivado exits 0 after printing an error and
# doing nothing, and every helper here that could fail has already refused. What
# is checked is that the file the next stage will source EXISTS, is NON-EMPTY,
# and CONTAINS READ COMMANDS - the last because a sources.tcl holding only its
# own header satisfies `test -s` perfectly and elaborates to nothing.
set n_cmds 0
if {[catch {open $SOURCES_TCL r} fh]} {
    lappend hard "sources.tcl could not be re-opened for the artefact check: $fh"
} else {
    foreach line [split [read $fh] "\n"] {
        if {[regexp {^(read_verilog|read_vhdl|add_files|import_files)\M} [string trim $line]]} {
            incr n_cmds
        }
    }
    close $fh
    say "sources.tcl carries $n_cmds read command(s), [file size $SOURCES_TCL] bytes"
    if {$n_cmds == 0} {
        lappend hard "sources.tcl exists and carries NO read command. Every later\
                      stage sources it to get the design, so synthesis would\
                      elaborate a black box - which Vivado reports as a warning,\
                      then synthesises, places, routes and writes a bitstream for."
    }
}


################################################################################
# 7. THE VERDICT, THEN THE MANIFEST
################################################################################

set delegated {}
if {[llength $::flist_ydirs] && !$::FLIST_Y_EXPAND} {
    lappend delegated "[llength $::flist_ydirs] '-y' library director(ies) were NOT read\
                       (FLIST_Y_EXPAND=0), owner=synth: every module they supply is a\
                       BLACK BOX and the count is gated by EXPECT_BLACKBOX_MAX, measured\
                       in the synthesis utilisation report, not here"
}
if {[llength $::flist_ignored]} {
    lappend delegated "[llength $::flist_ignored] filelist option(s) were not recognised and\
                       had NO effect, owner=the project that wrote the flist: most are\
                       simulator-only, one that was meant to change the build is a silent\
                       misconfiguration. They are listed in the log and in\
                       [prov_site_path $census]"
}
if {[llength $::flist_headers]} {
    lappend delegated "[llength $::flist_headers] header(s) were listed as SOURCES,\
                       owner=the project that wrote the flist: their directories joined\
                       the include path and the files themselves were not read, because\
                       Vivado compiles a header handed to read_verilog as a compilation\
                       unit"
}
if {[llength $::flist_defines]} {
    lappend delegated "[llength $::flist_defines] define(s) reached the fileset,\
                       owner=package-ip: ipx::package_project DROPS fileset defines by\
                       three separate routes (CONTRACT.md 9.2) and has already cost this\
                       codebase one silently-disabled feature. Anything load-bearing\
                       belongs in RTL_PARAMS or RTL_DEFINES_INBODY"
}

prov_gate flist flist \
    [list \
        "WHAT THIS CHECK IS: an assertion about the SOURCE LIST. Every path in the" \
        "filelist chain resolved, no source was zero bytes, the include and define" \
        "unions were emitted once each rather than once per line, and the module" \
        "named by TOP is declared by something that was read." \
        "" \
        "WHAT IT IS NOT: any statement whatever about the RTL. Nothing here is" \
        "parsed, elaborated or synthesised. A file that exists, is non-empty and is" \
        "unreadable garbage passes every check in this stage." ] \
    $hard \
    {} \
    $delegated \
    [list \
        "whether the RTL COMPILES. No file read here was parsed - Vivado defers that\
         to elaboration in stage 4, and a syntax error surfaces there" \
        "whether the design is CORRECT, or is the one the project meant to build.\
         The flist IS the configuration in this codebase (no `ifdef FPGA anywhere,\
         CONTRACT.md 9.1) and this stage records which one was read; it cannot know\
         whether it was the right one" \
        "whether RTL_FLIST_GEN actually ran for this build. Nothing records when a\
         project target ran. The flist's sha256 in the manifest is what distinguishes\
         two versions of it" \
        "whether a define recorded here SURVIVES to the tool that matters. Fileset\
         defines are dropped by IP packaging (9.2) and are re-passed on the\
         synth_design command line by flow/steps/synth_setup.tcl" \
        "whether a module declared under the name TOP is the RIGHT top. The scan is\
         textual and one-directional: not-found is a fact, found is not a proof" ]

set manifest [prov_manifest flist]
prov_stage_fields $manifest [list \
    file_count      $::flist_files \
    flist_chain     [llength $::flist_chain] \
    incdir_count    [llength $::flist_incdirs] \
    define_count    [llength $::flist_defines] \
    defines         [expr {[llength $::flist_defines] ? [join $::flist_defines " "] : "(none)"}] \
    ydir_count      [llength $::flist_ydirs] \
    ydirs_expanded  [expr {$::FLIST_Y_EXPAND ? "yes" : "no"}] \
    header_count    [llength $::flist_headers] \
    ignored_options [llength $::flist_ignored] \
    sources_tcl     [prov_site_path $SOURCES_TCL] \
    sources_cmds    $n_cmds \
    sources_hashed  [expr {$FLIST_HASH_SOURCES ? $n_hashed : "unmeasured"}] \
    source_census   [prov_site_path $census] \
    top             [expr {$TOP eq "" ? "UNVERIFIED:TOP-unset" : $TOP}] \
    top_declared_in [expr {$top_in eq "" ? ($FLIST_ASSERT_TOP ? "UNVERIFIED:not-declared-by-any-file-read" : "unmeasured") : [prov_site_path $top_in]}] \
    top_hdl_in_sources [expr {[llength $appended] ? "yes" : "no"}] \
    top_hdl_files   [llength $tophdl_files] \
    rtl_flist_gen   [expr {$RTL_FLIST_GEN eq "" ? "(none)" : $RTL_FLIST_GEN}] \
    hard_failures   [llength $hard] ]

if {[llength $hard]} {
    die "the flist stage found [llength $hard] hard failure(s)." \
        "  The manifest and the gate file were written first, so the evidence is" \
        "  on disk and this run is judged rather than lost:" \
        "    [file join $REPORT_DIR flist_gate.txt]" \
        "    $manifest"
}
say "flist stage complete: $::flist_files source file(s) from [llength $::flist_chain] filelist(s)"

# Copyright (C) 2026, SoC Labs (www.soclabs.org)
