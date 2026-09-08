################################################################################
# 2_package_ip.tcl - STAGE 2: package the design's RTL as an IP-XACT core
#
# Invoked by `make package-ip` through mk/flow.mk's `vivado_stage`, and ONLY when
# the project set PACKAGE_TCL. It writes a component.xml under $(OUT_DIR)/ip and
# $(REPORT_DIR)/package_ip_manifest.txt, and those are what the stage is judged
# on - by make when make ran it, by ci/assert-stage.sh afterwards when it did not.
#
#
# THE ONE HARD PROBLEM IN THIS FILE: ipx::package_project DROPS DEFINES
# ===========================================================================
# CONTRACT.md section 9.2, measured on this codebase and binding here:
#
#     Fileset defines do not survive IP packaging, by three separate routes.
#     PARAMETERS do, as CONFIG.* properties. Defines do not.
#
# It failed SILENTLY once already. An `ifdef TIDELINK_USE_IDELAY opt-in was
# false in EVERY FPGA build for as long as anyone had been running them, and the
# proof was a byte-identical bitstream between "IDELAY on" and "IDELAY off". No
# error, no warning, no difference in any report - the define was simply not
# there by the time the RTL was read out of the packaged core.
#
# So this stage delivers RTL_DEFINES_INBODY the only way that survives:
#
#     IT MATERIALISES MODIFIED COPIES OF THE AFFECTED RTL INTO $(WORK_DIR),
#     WITH THE DEFINE WRITTEN INTO THE FILE, AND PACKAGES THOSE.
#
# CONTRACT.md section 12.2 rule 8, in as many words: "never by set_property
# verilog_define". This file therefore does not contain that command at all -
# not even as a fallback, because a fallback that runs on the day the
# materialiser cannot find a file is a silent return to the failure above.
#
# AND IT RECORDS EXACTLY WHAT IT DID. Every materialised file, its origin, the
# defines baked into it and the sha256 of both copies land in
# $(REPORT_DIR)/package_ip_inbody.txt and are counted in the manifest. A
# packaged core is an opaque artefact: once component.xml exists, nothing
# downstream can tell an `ifdef that was taken from one that was not. That
# record is the only way anyone ever answers "what is actually in this IP".
#
#
# WHAT THIS STAGE OWNS, AND WHAT PACKAGE_TCL OWNS
# ===========================================================================
# The toolkit owns the RUN: the project, the part, the source list, the
# materialised copies, where the output goes, the record. PACKAGE_TCL owns the
# PACKAGING DECISIONS: the VLNV, the bus interfaces, the address maps, the GUI.
# The division is the same one CONTRACT.md section 1 draws everywhere else, and
# it is why this file does not contain an ipx::package_project call of its own:
# a toolkit that packaged the core itself would be making decisions it cannot
# know, and a project that set up its own run would be reimplementing the run
# namespace.
#
# The stage publishes these globals before sourcing PACKAGE_TCL, and they are
# the interface:
#
#   ::IP_OUT_DIR        $(OUT_DIR)/ip - a component.xml MUST end up under here
#   ::IP_ROOT_DIR       the suggested -root_dir for this core, under IP_OUT_DIR
#   ::IP_VENDOR         IP_VENDOR
#   ::IP_LIBRARY        PACKAGE_IP_LIBRARY
#   ::IP_CORE_NAME      PACKAGE_IP_CORE_NAME, defaulted from BLOCK
#   ::IP_CORE_REV       IP_CORE_REV
#   ::IP_TAXONOMY       PACKAGE_IP_TAXONOMY
#   ::PACKAGE_IP_TOP    the top module the core is packaged around
#   ::RTL_INBODY_FILES  {original materialised original materialised ...}
#   ::RTL_PARAMS_LIST   {NAME=VALUE ...}
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
################################################################################

# THE BOOT LAYER IS FOUND FROM THIS FILE, NOT THROUGH FPGA_FLOW_DIR. Sourcing it
# through the variable makes flow_boot's split-install check compare a value
# against itself - see the long note in 1_flist.tcl.
set _stage_flow_dir [file dirname [file dirname [file normalize [info script]]]]
source [file join $_stage_flow_dir common flow_utils.tcl]

flow_config prefix PACKAGE-IP
flow_boot
flow_banner package-ip

################################################################################
# THIS STAGE HAS TWO NAMES AND BOTH ARE LOAD-BEARING
#
# The stage is called `package-ip` - that is the make target, it is what
# mk/flow.mk exports as FPGA_STAGE, and it is what ci/assert-stage.sh is invoked
# with. Its ARTEFACTS are called `package_ip_*`: CONTRACT.md section 4 fixes
# `package_ip_manifest.txt`, mk/flow.mk asserts that exact filename, and
# ci/assert-stage.sh reads it.
#
# prov_manifest derives the FILENAME from the stage name it is given AND writes
# that same string into the manifest's `stage` field, so one call cannot satisfy
# both. MEASURED, both ways, on 2026-09-08:
#
#   prov_manifest package_ip -> assert-stage FAILS the run: "the manifest says
#                               stage 'package_ip', not 'package-ip' - it is not
#                               this stage's manifest"
#   prov_manifest package-ip -> the file lands at package-ip_manifest.txt, where
#                               neither make nor assert-stage looks for it
#
# So the manifest is written under the stage's REAL NAME - which is what the
# `stage` field must carry, since identifying the stage is that field's whole
# job - and then renamed to the artefact name the contract fixes. The durable
# fix is for prov_manifest to take the two separately; provenance.tcl is not
# this file's to change and this is recorded in the handback.
################################################################################
set STAGE_NAME package-ip     ;# the stage: FPGA_STAGE, the make target, assert-stage
set STAGE_STEM package_ip     ;# the artefact stem, fixed by CONTRACT.md section 4


################################################################################
# KNOBS - at the left margin, so flow_knob_scan and `make help-knobs` find them
# without executing this file.
################################################################################

opt PACKAGE_IP_LIBRARY       user      ;# the L of the V:L:N:V. IP_VENDOR supplies the V
opt PACKAGE_IP_CORE_NAME     ""        ;# "" = BLOCK. The N of the V:L:N:V
opt PACKAGE_IP_TAXONOMY      /UserIP   ;# where the core appears in the IP catalogue
opt PACKAGE_IP_CREATE_PROJECT 1        ;# 1 = this stage creates the project PACKAGE_TCL runs in
opt PACKAGE_IP_READ_SOURCES  1         ;# 1 = source the flist stage's sources.tcl into it
opt PACKAGE_IP_INBODY_UNDEF  1         ;# 1 = `undef a baked define at the end of a SOURCE copy
opt PACKAGE_IP_SCAN_HEADERS  1         ;# 1 = also materialise headers on the include path
opt PACKAGE_IP_REQUIRE_PARAMS 1        ;# 1 = an RTL_PARAM the packaged core does not carry is a HARD failure


################################################################################
# THE GATE AND THE STAGE-MEASUREMENT BLOCK
#
# DUPLICATED, IDENTICALLY, IN ALL THREE FRONT-HALF STAGE SCRIPTS. Their right
# home is flow/common/provenance.tcl as `prov_gate` and `prov_stage_fields`, and
# these three files may not create it. See the long note in 1_flist.tcl for the
# two reasons: prov_manifest closes the file with no seam for a stage's own
# measurements, and nothing in flow/common writes a gate file at all - while
# ci/assert-stage.sh requires both.
################################################################################

# THESE NAMES MUST BE FREE. `proc` silently REPLACES an existing command, and
# this file is sourced into a tool with several thousand of them. The equivalent
# guard in flow_utils.tcl has already fired in anger on the reference toolkit - a
# helper named `fail` shadowed a builtin and aborted a route stage 2.5 hours in.
foreach __c {stage_fields gate_write inbody_mentions inbody_materialise find_component} {
    if {[llength [info commands $__c]]} {
        error "[file tail [info script]]: '$__c' is already a command in this\
               tool - defining it here would shadow it. Rename the helper and\
               its callers."
    }
}
unset __c

proc stage_fields {path fields} {
    set fh [open $path a]
    puts $fh ""
    puts $fh "# 8. what this stage MEASURED. ci/assert-stage.sh reads these keys."
    foreach {k v} $fields {
        if {$v eq ""} { set v "(none)" }
        mf $fh $k $v
    }
    close $fh
    return $path
}

proc gate_write {stage what hard budgets delegated notcovered} {
    global REPORT_DIR block_name RUN_TAG board_name part_name
    set path [file join $REPORT_DIR ${stage}_gate.txt]
    set fh [open $path w]
    puts $fh "[string toupper [string map {_ -} $stage]] gate, [clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%S%z}]"
    puts $fh "design $block_name, run tag $RUN_TAG, board $board_name, part $part_name"
    puts $fh ""
    foreach line $what { puts $fh $line }
    puts $fh ""
    if {[llength $hard]} {
        puts $fh "HARD FAILURES: [llength $hard]"
        foreach h $hard { puts $fh "  - $h" }
    } else {
        puts $fh "HARD FAILURES: none"
    }
    puts $fh ""
    puts $fh "BUDGETS EXCEEDED"
    foreach b $budgets { puts $fh "  - $b" }
    puts $fh ""
    puts $fh "DECLARED ELSEWHERE - MEASURED HERE, OWNED BY SOMEBODY ELSE"
    foreach d $delegated { puts $fh "  - $d" }
    puts $fh ""
    puts $fh "NOT covered by ANY run of this flow, at any setting:"
    foreach n $notcovered { puts $fh "  - $n" }
    puts $fh ""
    puts $fh "# Copyright (C) 2026, SoC Labs (www.soclabs.org)"
    close $fh
    say "gate: $path"
    return $path
}


################################################################################
# 1. IS THIS STAGE CONFIGURED AT ALL?
#
# CONTRACT.md section 12.2 rule 7: a stage that is not configured WRITES A
# MANIFEST SAYING SO and exits 0.
#
# THE REASON IS ci/assert-stage.sh, AND IT IS WORTH STATING. From disk alone, a
# stage that was switched off and a stage that ran and died before writing
# anything look identical - an empty reports/ either way. assert-stage resolves
# that today by reading the project's contract, and its own header says the
# durable fix is for every stage to leave a record. This is that record.
#
# THE STALE GATE IS DELETED, and that is not tidying. Run tags are reused; a
# package_ip_gate.txt left by an earlier run of this same tag, when the stage
# WAS configured, would be read by assert-stage as this run's verdict. A verdict
# about a stage that did not run is worse than no verdict.
################################################################################

set PACKAGE_TCL [flow_env FPGA_PACKAGE_TCL]

if {$PACKAGE_TCL eq ""} {
    step "package-ip is NOT CONFIGURED"
    say "PACKAGE_TCL is empty, so this design packages no IP."
    say "  Nothing was packaged and nothing is expected to have been. This"
    say "  manifest exists so that 'switched off' is a FACT on disk rather than"
    say "  an inference from an absence of output."
    set stale [file join $REPORT_DIR ${STAGE_STEM}_gate.txt]
    set removed no
    if {[file exists $stale]} {
        file delete -force $stale
        set removed yes
        warn "removed a package_ip_gate.txt left by an EARLIER run of run tag"
        warn "  '$RUN_TAG', when this stage was configured. A verdict about a"
        warn "  stage that did not run is worse than no verdict."
    }
    set manifest [prov_manifest $STAGE_NAME]
    set wanted [file join $REPORT_DIR ${STAGE_STEM}_manifest.txt]
    if {$manifest ne $wanted} { file rename -force $manifest $wanted ; set manifest $wanted }
    stage_fields $manifest [list \
        stage_configured   no \
        not_configured_why "PACKAGE_TCL is empty in the project's design.mk" \
        package_tcl        "(none)" \
        vlnv               unmeasured \
        params_packaged    unmeasured \
        inbody_defines     unmeasured \
        inbody_files       unmeasured \
        component_xml      "(none)" \
        stale_gate_removed $removed \
        hard_failures      0 ]
    say "package-ip: not configured. Nothing measured, nothing claimed. Exit 0."
    exit 0
}


################################################################################
# 2. THE SEAM, THEN THE INPUTS
################################################################################

flow_hook pre_package_ip

flow_assert_input $PACKAGE_TCL \
    "the project's IP packaging script. It owns the packaging DECISIONS - the\
     VLNV, the bus interfaces, the address maps - and is sourced into a project\
     this stage sets up" \
    PACKAGE_TCL

set SOURCES_TCL [file join $WORK_DIR sources.tcl]
if {$PACKAGE_IP_READ_SOURCES && (![file exists $SOURCES_TCL] || ![file size $SOURCES_TCL])} {
    flow_refuse "no source list at $SOURCES_TCL" \
        "  That file is written by the flist stage and is how the design gets" \
        "  into this one. Run 'make flist' first, in this run tag." \
        "  Set PACKAGE_IP_READ_SOURCES=0 only if PACKAGE_TCL reads its own" \
        "  sources - and then nothing here can tell you what it packaged."
}
prov_pin package_tcl $PACKAGE_TCL package-ip-source
if {$PACKAGE_IP_READ_SOURCES} { prov_pin sources_tcl $SOURCES_TCL package-ip-read }
set ::PROV_FILES [list package_tcl $PACKAGE_TCL]
if {$PACKAGE_IP_READ_SOURCES} { lappend ::PROV_FILES sources_tcl $SOURCES_TCL }

set PACKAGE_IP_TOP [flow_env FPGA_TOP]
set IP_VENDOR   [flow_env FPGA_IP_VENDOR soclabs.org]
set IP_CORE_REV [flow_env FPGA_IP_CORE_REV 1]
set IP_LIBRARY  $PACKAGE_IP_LIBRARY
set IP_CORE_NAME [expr {$PACKAGE_IP_CORE_NAME ne "" ? $PACKAGE_IP_CORE_NAME : $block_name}]
set IP_TAXONOMY $PACKAGE_IP_TAXONOMY

# THE OUTPUT LOCATION IS THE TOOLKIT'S TO CHOOSE, because it is a fact about the
# run namespace and not about the core. CONTRACT.md section 4 asserts
# $(OUT_DIR)/ip/<vlnv>/component.xml, and mk/flow.mk deliberately asserts only
# "at least one component.xml below outputs/ip" - the VLNV is PACKAGE_TCL's
# decision and computing it here would be a second copy of it.
set IP_OUT_DIR  [file join $OUT_DIR ip]
set IP_ROOT_DIR [file join $IP_OUT_DIR "${IP_VENDOR}_${IP_LIBRARY}_${IP_CORE_NAME}_${IP_CORE_REV}"]
file mkdir $IP_ROOT_DIR


################################################################################
# 3. RTL_DEFINES_INBODY - THE MATERIALISER
#
# See the header for why this exists at all. What follows is how, and why each
# decision in it is the way it is.
#
# WHICH FILES ARE AFFECTED: the ones that MENTION the name. A textual scan, not a
# preprocessor - and its limits are recorded rather than hidden. It finds
# `ifdef NAME, `ifndef NAME, `elsif NAME and a bare `NAME macro use, because all
# four change meaning when the define arrives. It cannot find a name assembled by
# another macro, and it does not try.
#
# A DEFINE THAT MATCHES NOTHING IS A HARD FAILURE. That is the whole defect class
# in one line: a define nobody reads is indistinguishable, from every artefact
# downstream, from a define that was read and taken. The measured instance cost
# this codebase an entire build generation of a feature that was never on.
#
# SOURCE FILES GET `define AT THE TOP AND `undef AT THE BOTTOM. Verilog macros
# are compilation-unit scoped and Vivado's unit is effectively the read order, so
# a define left standing at the end of one file leaks into every file read after
# it - which is a different design from the one asked for, arrived at silently.
# The `undef confines it to the file that needed it. PACKAGE_IP_INBODY_UNDEF
# turns that off for the rare file whose macro must outlive it.
#
# HEADERS GET `define AND NO `undef, and are shadowed onto the FRONT of the
# include path. An `ifdef inside a header has to be true while the includer is
# being compiled, so undefining it at the end of the header would undo the thing
# it was asked to do.
#
# THE COPIES GO IN $(WORK_DIR), never over the original. CONTRACT.md section 1
# and this site's standing rule: the toolkit does not edit the project's or the
# vendor's sources. A materialised copy is also the only version of this that two
# concurrent runs can both do at once.
################################################################################

set inbody_defs {}
foreach d [split [flow_env FPGA_RTL_DEFINES_INBODY]] {
    set d [string trim $d]
    if {$d eq ""} { continue }
    set eq [string first "=" $d]
    if {$eq < 0} {
        lappend inbody_defs [list $d ""]
    } else {
        lappend inbody_defs [list [string range $d 0 [expr {$eq - 1}]] \
                                  [string range $d [expr {$eq + 1}] end]]
    }
}

# RTL_DEFINES_NEVER is asserted here as well as in 1_flist.tcl, because THIS is
# the stage that could deliver one past every other check in the flow: a name
# baked into a file is not a fileset define and flow/steps/synth_setup.tcl's
# assertion cannot see it.
set never {}
foreach n [split [flow_env FPGA_RTL_DEFINES_NEVER]] {
    if {[string trim $n] ne ""} { lappend never [string trim $n] }
}

set hard {}
foreach nv $inbody_defs {
    foreach {n v} $nv break
    if {[lsearch -exact $never $n] >= 0} {
        lappend hard "RTL_DEFINES_NEVER asserts '$n' is ABSENT and RTL_DEFINES_INBODY\
                      would have BAKED IT INTO THE RTL, where no other check in this\
                      flow can see it: it is not a fileset define, so\
                      flow/steps/synth_setup.tcl's assertion never meets it."
    }
}

# Does <file> mention <name> as a macro? See above for what this can and cannot
# see; the gate file says the same thing to the reader of the result.
proc inbody_mentions {path name} {
    if {[catch {open $path r} fh]} { return 0 }
    set body [read $fh]
    close $fh
    return [regexp "(\`(ifdef|ifndef|elsif)\[ \t\]+${name}\\M)|(\`${name}\\M)" $body]
}

# Write the modified copy. Returns the new path.
proc inbody_materialise {src dst defs undef} {
    file mkdir [file dirname $dst]
    set in [open $src r]
    set body [read $in]
    close $in
    set out [open $dst w]
    puts $out "// ---------------------------------------------------------------------------"
    puts $out "// MATERIALISED COPY - generated by flow/vivado/2_package_ip.tcl. Do not edit."
    puts $out "//"
    puts $out "// original : $src"
    puts $out "//"
    puts $out "// The defines below are written INTO this file because"
    puts $out "// ipx::package_project DROPS fileset defines (CONTRACT.md section 9.2) and"
    puts $out "// has already disabled a feature silently in this codebase for a whole"
    puts $out "// build generation. RTL_DEFINES_INBODY is delivered this way and no other."
    puts $out "// ---------------------------------------------------------------------------"
    foreach nv $defs {
        foreach {n v} $nv break
        if {$v eq ""} { puts $out "\`define $n" } else { puts $out "\`define $n $v" }
    }
    puts $out ""
    puts $out $body
    if {$undef} {
        puts $out ""
        puts $out "// Confined to this file: a macro left standing leaks into every file read"
        puts $out "// after it, which is a different design arrived at silently."
        foreach nv $defs {
            foreach {n v} $nv break
            puts $out "\`undef $n"
        }
    }
    close $out
    return $dst
}


################################################################################
# 4. THE PROJECT PACKAGE_TCL RUNS IN
################################################################################

set PROJ_DIR  [file join $WORK_DIR package_ip]
set PROJ_NAME "${block_name}_package"
set part_for_project [flow_env FPGA_PART [part part_name]]

if {$PACKAGE_IP_CREATE_PROJECT} {
    step "create the packaging project"
    if {![flow_have create_project]} {
        flow_refuse "this tool has no create_project." \
            "  This stage must run inside Vivado: ipx::package_project needs an" \
            "  open project. mk/flow.mk launches it through 'vivado -mode batch'."
    }
    # -force, because a re-run of one run tag must not fail on its own leftovers -
    # and because the alternative, reusing whatever is there, would package a
    # fileset assembled by an earlier and possibly different configuration.
    create_project -force $PROJ_NAME $PROJ_DIR -part $part_for_project
    say "project: $PROJ_DIR ($part_for_project)"

    set repos {}
    foreach r [split [flow_env FPGA_IP_REPOS]] {
        if {[string trim $r] eq ""} { continue }
        flow_assert_input [string trim $r] "an IP repository named by IP_REPOS" IP_REPOS
        lappend repos [file normalize [string trim $r]]
    }
    if {[llength $repos]} {
        # ONE assignment. set_property REPLACES ip_repo_paths, so one call per
        # repository leaves exactly the last one standing - the same shape as the
        # +incdir+ defect read_flist.tcl exists to prevent, one layer up.
        set_property ip_repo_paths $repos [current_project]
        update_ip_catalog -rebuild
        say "ip_repo_paths: [join $repos { }]"
    }
    set cache [flow_env FPGA_IP_CACHE_DIR]
    if {$cache ne ""} {
        file mkdir $cache
        config_ip_cache -use_cache_location $cache
        say "ip cache: $cache"
    }
}

if {$PACKAGE_IP_READ_SOURCES} {
    step "read the source list the flist stage wrote"
    source $SOURCES_TCL
    say "fileset holds [llength [get_files -quiet]] file(s)"
}

if {$PACKAGE_IP_TOP ne "" && [flow_have current_fileset]} {
    set_property top $PACKAGE_IP_TOP [current_fileset]
    say "top: $PACKAGE_IP_TOP"
}


################################################################################
# 5. MATERIALISE, AND SWAP THE COPIES INTO THE FILESET
#
# The swap is what makes this real. Writing the copies and leaving the originals
# in the fileset would produce a directory full of correct files that nothing
# read - which looks, in every log and every report, exactly like success.
################################################################################

set inbody_records {}
set inbody_headers 0
set INBODY_DIR [file join $WORK_DIR inbody]

if {[llength $inbody_defs]} {
    step "RTL_DEFINES_INBODY: [llength $inbody_defs] define(s) to bake in"
    foreach nv $inbody_defs {
        foreach {n v} $nv break
        say "  [expr {$v eq "" ? "\`define $n" : "\`define $n $v"}]"
    }
    file mkdir $INBODY_DIR

    # --- 5.1 the design files -------------------------------------------------
    set candidates {}
    if {[flow_have get_files]} {
        foreach f [get_files -quiet] { lappend candidates [file normalize $f] }
    }
    if {![llength $candidates] && [info exists ::flist_files_read]} {
        set candidates $::flist_files_read
    }

    array set hit {}
    foreach f $candidates {
        set mine {}
        foreach nv $inbody_defs {
            foreach {n v} $nv break
            if {[inbody_mentions $f $n]} {
                lappend mine $nv
                lappend hit($n) $f
            }
        }
        if {![llength $mine]} { continue }
        set dst [file join $INBODY_DIR [file tail $f]]
        # A flat directory would collide two same-named files from opposite
        # wrapper directories - which is EXACTLY how this codebase selects
        # between an FPGA and an ASIC memory wrapper (CONTRACT.md 9.1), so the
        # collision is not hypothetical. The parent directory name disambiguates.
        if {[file exists $dst]} {
            set dst [file join $INBODY_DIR "[file tail [file dirname $f]]__[file tail $f]"]
        }
        inbody_materialise $f $dst $mine $PACKAGE_IP_INBODY_UNDEF
        set names {}
        foreach nv $mine { lappend names [lindex $nv 0] }
        lappend inbody_records [list source $f $dst $names]
        say "  materialised [file tail $f] <- [join $names {,}]"

        if {[flow_have get_files]} {
            set orig [get_files -quiet $f]
            set ftype ""
            if {[llength $orig]} {
                catch { set ftype [get_property FILE_TYPE [lindex $orig 0]] }
                remove_files $orig
            }
            add_files -norecurse -fileset [current_fileset] $dst
            if {$ftype ne ""} {
                catch { set_property FILE_TYPE $ftype [get_files $dst] }
            }
        }
    }

    # --- 5.2 the headers ------------------------------------------------------
    #
    # An `ifdef inside a HEADER is invisible to the scan above, because the
    # header is not a source: read_flist.tcl deliberately does not hand a header
    # to read_verilog (Vivado compiles it as a compilation unit, which is a
    # syntax error or a duplicate macro) - it puts the header's DIRECTORY on the
    # include path. So the header is found here, on that path, and the modified
    # copy shadows it by going on the FRONT of the path.
    if {$PACKAGE_IP_SCAN_HEADERS} {
        set incdirs {}
        if {[flow_have current_fileset]} {
            catch { set incdirs [get_property include_dirs [current_fileset]] }
        }
        if {![llength $incdirs] && [info exists ::flist_incdirs]} { set incdirs $::flist_incdirs }
        set shadow [file join $INBODY_DIR include]
        foreach d $incdirs {
            foreach h [lsort [concat [glob -nocomplain -directory $d *.vh] \
                                     [glob -nocomplain -directory $d *.svh] \
                                     [glob -nocomplain -directory $d *.h]]] {
                set mine {}
                foreach nv $inbody_defs {
                    foreach {n v} $nv break
                    if {[inbody_mentions $h $n]} { lappend mine $nv ; lappend hit($n) $h }
                }
                if {![llength $mine]} { continue }
                # NO `undef on a header: the includer has to still see the macro.
                set dst [file join $shadow [file tail $h]]
                inbody_materialise $h $dst $mine 0
                set names {}
                foreach nv $mine { lappend names [lindex $nv 0] }
                lappend inbody_records [list header $h $dst $names]
                incr inbody_headers
                say "  materialised header [file tail $h] <- [join $names {,}]"
            }
        }
        if {$inbody_headers && [flow_have current_fileset]} {
            set fs [current_fileset]
            set_property include_dirs \
                [concat [list $shadow] [get_property include_dirs $fs]] $fs
            say "  shadow include dir FIRST on the path: $shadow"
        }
    }

    # --- 5.3 a define that matched nothing ------------------------------------
    foreach nv $inbody_defs {
        foreach {n v} $nv break
        if {![info exists hit($n)]} {
            lappend hard "RTL_DEFINES_INBODY names '$n' and NO file this stage can see\
                          mentions it - not one of [llength $candidates] source file(s),\
                          not a header on the include path. Nothing was baked in, so the\
                          define does nothing and NOTHING DOWNSTREAM CAN TELL: a packaged\
                          core carries no record of an `ifdef that was not taken. That is\
                          the exact shape of the defect this mechanism exists to prevent\
                          (CONTRACT.md 9.2). Either the name is misspelt, or the file that\
                          reads it is not in the flist."
        }
    }
}


################################################################################
# 6. RTL_PARAMS - THE MECHANISM THAT DOES SURVIVE
################################################################################

set params {}
foreach p [split [flow_env FPGA_RTL_PARAMS]] {
    set p [string trim $p]
    if {$p eq ""} { continue }
    if {[string first "=" $p] < 0} {
        flow_refuse "RTL_PARAMS entry '$p' has no '='." \
            "  The form is NAME=VALUE. A bare name cannot be applied to anything" \
            "  and would silently do nothing, which is the failure mode this" \
            "  whole stage is written around."
    }
    lappend params $p
}
set ::RTL_PARAMS_LIST $params


################################################################################
# 7. HAND OVER TO THE PROJECT'S PACKAGING SCRIPT
################################################################################

set ::IP_OUT_DIR       $IP_OUT_DIR
set ::IP_ROOT_DIR      $IP_ROOT_DIR
set ::IP_VENDOR        $IP_VENDOR
set ::IP_LIBRARY       $IP_LIBRARY
set ::IP_CORE_NAME     $IP_CORE_NAME
set ::IP_CORE_REV      $IP_CORE_REV
set ::IP_TAXONOMY      $IP_TAXONOMY
set ::PACKAGE_IP_TOP   $PACKAGE_IP_TOP
set ::RTL_INBODY_FILES {}
foreach r $inbody_records { lappend ::RTL_INBODY_FILES [lindex $r 1] [lindex $r 2] }

step "source the project's packaging script"
say "PACKAGE_TCL: $PACKAGE_TCL"
say "  it may read: IP_OUT_DIR IP_ROOT_DIR IP_VENDOR IP_LIBRARY IP_CORE_NAME"
say "               IP_CORE_REV IP_TAXONOMY PACKAGE_IP_TOP RTL_INBODY_FILES"
say "               RTL_PARAMS_LIST"
# NOT WRAPPED IN try_step. flow_utils.tcl's own header says why: try_step is for
# OPTIONAL work, and a catch round the one command the stage exists to run turns
# a real failure into a passing run with a missing artefact.
source $PACKAGE_TCL


################################################################################
# 8. WHAT CAME OUT - MEASURED FROM THE TOOL AND FROM THE DISK, NOT FROM THE
#    SCRIPT'S SAY-SO
################################################################################

# --- 8.1 the core ------------------------------------------------------------
set core ""
set vlnv "UNVERIFIED:no-core-and-no-component.xml"
if {[flow_have ipx::current_core]} {
    catch { set core [ipx::current_core] }
}
# THE COMPONENT IS FOUND ON DISK, NOT ASKED OF THE TOOL. `get_property core_file`
# is not a property of a component object in Vivado 2024.1 - it raises "Unknown
# property 'core_file' on component", and a catch swallows that into an empty
# answer that reads exactly like "no core was written". Searching the two
# directories a core can legitimately land in answers the same question from the
# ARTEFACT, which is the rule this toolkit applies everywhere else.
#
# DEPTH-BOUNDED. $(WORK_DIR) holds a Vivado project, and an unbounded walk of one
# is thousands of directories for a file that is at most three levels down.
proc find_component {roots} {
    foreach root $roots {
        if {$root eq "" || ![file isdirectory $root]} { continue }
        set frontier [list $root]
        for {set depth 0} {$depth < 4} {incr depth} {
            set next {}
            foreach d $frontier {
                set c [file join $d component.xml]
                if {[file exists $c] && [file size $c]} { return [file normalize $c] }
                foreach s [glob -nocomplain -directory $d -types d *] { lappend next $s }
            }
            if {![llength $next]} { break }
            set frontier $next
        }
    }
    return ""
}
set component [find_component [list $IP_OUT_DIR $WORK_DIR]]

if {$core ne ""} {
    catch { set vlnv [get_property vlnv $core] }
} elseif {$component ne "" && [file exists $component]} {
    # The core object is gone - the packaging script closed it. The VLNV is still
    # a fact and it is IN THE FILE, so it is read from there rather than
    # reported as unmeasured. A digest of the four fields, in IP-XACT order.
    set fh [open $component r]
    set xml [read $fh]
    close $fh
    set parts {}
    foreach tag {vendor library name version} {
        if {[regexp "<spirit:$tag>(\[^<\]*)</spirit:$tag>" $xml -> m] ||
            [regexp "<xilinx:$tag>(\[^<\]*)</xilinx:$tag>" $xml -> m] ||
            [regexp "<ipxact:$tag>(\[^<\]*)</ipxact:$tag>" $xml -> m]} {
            lappend parts $m
        }
    }
    if {[llength $parts] == 4} { set vlnv [join $parts ":"] }
}

# --- 8.2 the parameters that survived ----------------------------------------
#
# CONTRACT.md section 9.2: parameters survive packaging as CONFIG.*; defines do
# not. "Survive" is a claim, so it is MEASURED: each NAME in RTL_PARAMS is looked
# for on the packaged core and the value is set there. A parameter the core does
# not carry is not a smaller version of a parameter that works - it is a
# configuration value that reaches nothing, and the consumer of the core sees no
# sign of it.
set params_packaged 0
set params_missing {}
if {[llength $params] && $core ne ""} {
    step "apply RTL_PARAMS to the packaged core"
    foreach p $params {
        set eq [string first "=" $p]
        set n [string range $p 0 [expr {$eq - 1}]]
        set v [string range $p [expr {$eq + 1}] end]
        set done 0
        foreach getter {ipx::get_user_parameters ipx::get_hdl_parameters} {
            if {$done} { break }
            set objs {}
            catch { set objs [$getter $n -of_objects $core] }
            foreach o $objs {
                catch { set_property value $v $o ; set done 1 }
                catch { set_property value_format long $o }
            }
        }
        if {$done} {
            incr params_packaged
            say "  $n = $v"
        } else {
            lappend params_missing $n
            warn "  RTL_PARAMS names '$n' and the packaged core has no such parameter."
        }
    }
} elseif {[llength $params]} {
    warn "[llength $params] RTL_PARAM(s) could not be applied: no core object is"
    warn "  open after PACKAGE_TCL. Whether they reached the core is UNMEASURED."
}
foreach n $params_missing {
    if {$PACKAGE_IP_REQUIRE_PARAMS} {
        lappend hard "RTL_PARAMS names '$n' and the packaged core carries no parameter of\
                      that name, so the value reaches nothing. Parameters are the ONLY\
                      configuration that survives IP packaging (CONTRACT.md 9.2) - a\
                      parameter that is not on the PACKAGED TOP does not survive either,\
                      it just fails more quietly. Expose it on $PACKAGE_IP_TOP, or move\
                      the configuration to RTL_DEFINES_INBODY."
    }
}


################################################################################
# 9. THE SEAM, THEN THE WRITES (CONTRACT.md section 6.1.3)
#
# post_package_ip fires HERE: after the core exists and before it is saved. That
# is the only placement at which a hook can do the thing hooks at this seam are
# for - adding a bus interface, fixing an inferred clock, correcting an address
# map - and have it survive. Fire it after ipx::save_core and the component.xml
# on disk predates the edit, every consumer reads that file, and the hook would
# appear in hooks_run having changed nothing.
################################################################################

flow_hook post_package_ip

step "save the core"
if {$core ne ""} {
    if {[flow_have ipx::check_integrity]} { catch { ipx::check_integrity $core } }
    ipx::save_core $core
}
# RE-FOUND AFTER THE SAVE, never carried over from before it. The packaging
# script may have relocated the core, and the pre-seam search above ran before
# post_package_ip had a chance to change anything.
set component [find_component [list $IP_OUT_DIR $WORK_DIR]]

# THE ARTEFACT MUST BE WHERE THE CONTRACT SAYS. mk/flow.mk and ci/assert-stage.sh
# both look for a component.xml under $(OUT_DIR)/ip. If the packaging script put
# it somewhere else - its own working directory is the common case - the core is
# COPIED there rather than the assertion being relaxed, and the manifest records
# that it was copied and from where.
set component_relocated no
if {$component ne "" && [file exists $component]} {
    set c [file normalize $component]
    set under_out [expr {[string first "[file normalize $IP_OUT_DIR]/" "$c/"] == 0}]
    if {!$under_out} {
        set src [file dirname $c]
        set dst [file join $IP_OUT_DIR [regsub -all {[^A-Za-z0-9._-]} $vlnv "_"]]
        file mkdir $dst
        foreach f [glob -nocomplain -directory $src *] {
            file copy -force $f $dst
        }
        set component [file join $dst component.xml]
        set component_relocated yes
        warn "PACKAGE_TCL wrote the core outside \$(OUT_DIR)/ip; it was COPIED to"
        warn "  $dst"
        warn "  The original at $src is left alone. Point PACKAGE_TCL at"
        warn "  \$IP_ROOT_DIR to avoid the copy."
    }
}

if {$component eq "" || ![file exists $component] || ![file size $component]} {
    lappend hard "no component.xml exists after PACKAGE_TCL ran.\
                  ipx::package_project logs its refusals as WARNINGS and the tool still\
                  exits 0, so the exit status said nothing and this is the only place it\
                  shows. Looked under [prov_site_path $IP_OUT_DIR] and\
                  [prov_site_path $WORK_DIR]."
    set component ""
}


################################################################################
# 10. THE IN-BODY RECORD
#
# "The record is the only way anyone can later tell what the packaged IP actually
# contains" - the reason this file exists at all. It is a REPORT, not the
# manifest: the manifest carries the counts, this carries the list.
################################################################################

set inbody_report [file join $REPORT_DIR package_ip_inbody.txt]
set fh [open $inbody_report w]
puts $fh "# RTL_DEFINES_INBODY - what was baked into what, for this run."
puts $fh "#"
puts $fh "# ipx::package_project DROPS fileset defines (CONTRACT.md section 9.2), so a"
puts $fh "# define that has to survive packaging is written INTO a copy of the file"
puts $fh "# that reads it and the copy is what gets packaged. Once component.xml"
puts $fh "# exists nothing downstream can tell an `ifdef that was taken from one that"
puts $fh "# was not; this file is the only record that answers it."
puts $fh "#"
puts $fh "# kind: 'source' = the copy replaced the original in the fileset."
puts $fh "#       'header' = the copy shadows the original, FIRST on the include path,"
puts $fh "#                  and carries no \`undef - the includer must still see it."
puts $fh ""
if {![llength $inbody_defs]} {
    puts $fh "RTL_DEFINES_INBODY is empty. Nothing was materialised and nothing was baked in."
} else {
    puts $fh "defines requested : [llength $inbody_defs]"
    foreach nv $inbody_defs {
        foreach {n v} $nv break
        puts $fh "  [expr {$v eq "" ? "\`define $n" : "\`define $n $v"}]"
    }
    puts $fh ""
    puts $fh "files materialised: [llength $inbody_records]"
    foreach r $inbody_records {
        foreach {kind src dst names} $r break
        puts $fh ""
        puts $fh "  kind        $kind"
        puts $fh "  original    [prov_site_path $src]"
        puts $fh "  sha256      [prov_sha256 [prov_resolve $src]]"
        puts $fh "  materialised [prov_site_path $dst]"
        puts $fh "  sha256      [prov_sha256 [prov_resolve $dst]]"
        puts $fh "  baked in    [join $names { }]"
        puts $fh "  undef       [expr {$kind eq "header" ? "no (a header's macro must outlive it)" : ($PACKAGE_IP_INBODY_UNDEF ? "yes" : "no (PACKAGE_IP_INBODY_UNDEF=0)")}]"
    }
}
puts $fh ""
puts $fh "# Copyright (C) 2026, SoC Labs (www.soclabs.org)"
close $fh
say "in-body record: $inbody_report"


################################################################################
# 11. THE VERDICT, THEN THE MANIFEST
################################################################################

set delegated {}
lappend delegated "every fileset define this design carries, owner=synth: they are\
                   DROPPED by packaging and are re-passed on the synth_design command\
                   line by flow/steps/synth_setup.tcl. Nothing measured here says\
                   whether a consumer of this core sees them, because no consumer does"
if {[llength $inbody_records]} {
    lappend delegated "[llength $inbody_records] materialised file(s), owner=the reader of\
                       [prov_site_path $inbody_report]: that the baked define produces the\
                       INTENDED design is not checked here - only that the file that reads\
                       the name got the define"
}
if {[llength $params]} {
    lappend delegated "[llength $params] RTL_PARAM(s), owner=the consumer of this core: they\
                       are set as CONFIG.* defaults on the core, and a block design that\
                       instantiates it may override every one of them"
}

gate_write $STAGE_STEM \
    [list \
        "WHAT THIS CHECK IS: an assertion that a core came out, that the defines" \
        "RTL_DEFINES_INBODY names were written into files that actually read them," \
        "and that every RTL_PARAM is carried by the packaged core. Those three are" \
        "the ways configuration crosses the IP boundary, and two of them fail" \
        "silently (CONTRACT.md section 9.2)." \
        "" \
        "WHAT IT IS NOT: any statement that the core is CORRECT. Nothing here" \
        "elaborates, synthesises or instantiates it. Bus interfaces, address maps" \
        "and clock/reset inference are ipx's guesses and this stage does not audit" \
        "them." ] \
    $hard \
    {} \
    $delegated \
    [list \
        "whether the packaged core ELABORATES. It is not synthesised here; the first\
         stage that finds a broken core is the one that instantiates it" \
        "whether ipx's INFERRED bus interfaces, address maps and clock associations\
         are right. They are inferences from port names and this stage does not\
         audit them - the WARNING list in the log is the only signal there is" \
        "whether an `ifdef inside the packaged RTL was actually TAKEN. A textual scan\
         found the files that mention each name; nothing preprocesses them, and a\
         name assembled by another macro is invisible to it" \
        "whether a consumer of this core will pass a different value for an RTL_PARAM.\
         The values here are the core's DEFAULTS, which any block design may override" \
        "whether the ORIGINAL file and its materialised copy differ in any way beyond\
         the define block. The copy is generated from the original in one pass, and\
         both sha256s are recorded, but nothing diffs them" ]

# WRITTEN UNDER THE STAGE'S NAME, THEN RENAMED TO THE ARTEFACT NAME. See the note
# at the top of this file: prov_manifest uses one string for both, and the two
# consumers of this file disagree about which it should be.
set manifest [prov_manifest $STAGE_NAME]
set wanted [file join $REPORT_DIR ${STAGE_STEM}_manifest.txt]
if {$manifest ne $wanted} {
    file rename -force $manifest $wanted
    set manifest $wanted
    say "manifest renamed to the artefact name CONTRACT.md section 4 fixes: $manifest"
}
stage_fields $manifest [list \
    stage_configured   yes \
    package_tcl        [prov_site_path $PACKAGE_TCL] \
    vlnv               $vlnv \
    ip_out_dir         [prov_site_path $IP_OUT_DIR] \
    component_xml      [expr {$component eq "" ? "UNVERIFIED:no-component.xml" : [prov_site_path $component]}] \
    component_bytes    [expr {$component eq "" ? "unmeasured" : [file size $component]}] \
    component_sha256   [expr {$component eq "" ? "UNVERIFIED:no-component.xml" : [prov_sha256 [prov_resolve $component]]}] \
    component_relocated $component_relocated \
    params_requested   [llength $params] \
    params_packaged    [expr {[llength $params] && $core eq "" ? "unmeasured" : $params_packaged}] \
    params_missing     [expr {[llength $params_missing] ? [join $params_missing " "] : "(none)"}] \
    inbody_defines     [llength $inbody_defs] \
    inbody_files       [llength $inbody_records] \
    inbody_headers     $inbody_headers \
    inbody_record      [prov_site_path $inbody_report] \
    inbody_dir         [expr {[llength $inbody_records] ? [prov_site_path $INBODY_DIR] : "(none)"}] \
    top                [expr {$PACKAGE_IP_TOP eq "" ? "UNVERIFIED:TOP-unset" : $PACKAGE_IP_TOP}] \
    sources_read       [expr {$PACKAGE_IP_READ_SOURCES ? "yes" : "no"}] \
    hard_failures      [llength $hard] ]

if {[llength $hard]} {
    die "the package-ip stage found [llength $hard] hard failure(s)." \
        "  The manifest, the gate file and the in-body record were written" \
        "  first, so the evidence is on disk and this run is judged rather" \
        "  than lost:" \
        "    [file join $REPORT_DIR ${STAGE_STEM}_gate.txt]" \
        "    $manifest" \
        "    $inbody_report"
}
say "package-ip complete: $vlnv"
say "  component.xml   [expr {$component eq "" ? "(none)" : $component}]"
say "  params packaged $params_packaged of [llength $params]"
say "  files baked     [llength $inbody_records] for [llength $inbody_defs] define(s)"

# Copyright (C) 2026, SoC Labs (www.soclabs.org)
