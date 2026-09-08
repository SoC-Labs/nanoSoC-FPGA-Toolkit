################################################################################
# 3_bd.tcl - STAGE 3: build the block design, apply the overlays, wrap it
#
# Invoked by `make bd` through mk/flow.mk's `vivado_stage`, and ONLY when the
# project set BD_TCL. It writes $(WORK_DIR)/$(DESIGN_NAME).bd and
# $(REPORT_DIR)/bd_manifest.txt, and those are what the stage is judged on.
#
#
# THE ORDER OF THE OVERLAYS IS THE DESIGN
# ===========================================================================
# BD_OVERLAY_TCL is a LIST and it is applied IN ORDER. Each overlay edits the
# design the previous one left, so swapping two of them produces a DIFFERENT
# block design with no error, no warning and no difference in any artefact
# except the .bd itself. That is a configuration that silently changes what
# ships, which is the class of failure this toolkit exists to make impossible,
# so the list is preserved exactly as written, each entry is announced with its
# runtime as it runs, and the whole sequence lands in the manifest. Two runs
# whose block designs differ can then be told apart by reading two files rather
# than by opening two GUIs.
#
#
# WHY THE .bd IS COPIED RATHER THAN WRITTEN WHERE THE CONTRACT ASKS
# ===========================================================================
# CONTRACT.md section 4 asserts $(WORK_DIR)/$(DESIGN_NAME).bd. Vivado does not
# put it there: `create_bd_design` in a project puts the .bd under
# <project>.srcs/sources_1/bd/<name>/<name>.bd, and there is no switch that
# moves it - the path is composed by the tool from the project layout.
#
# So the canonical file stays where the tool owns it, and a COPY is placed at
# the contract path. The manifest records BOTH, because they answer different
# questions: the copy is what make and ci/assert-stage.sh assert on, and the
# in-project path is the one a later stage or a GUI has to open. A flow that
# recorded only the copy would send the next reader to a file that cannot be
# edited, and one that recorded only the original would fail an assertion it
# had actually satisfied.
#
#
# THE NAME IS NOT NEGOTIABLE, AND A MISMATCH IS NOT RENAMED AWAY
# ===========================================================================
# If BD_TCL creates a design called something other than DESIGN_NAME, this stage
# FAILS and says so. It does not copy <whatever>.bd to <DESIGN_NAME>.bd: the
# file's own contents name the block design, so the copy would satisfy every
# assertion in the flow while every tool that opened it disagreed with the name
# it was opened under. An artefact that lies to the checker is worse than a
# missing one, and the fix - set DESIGN_NAME, or rename the design in BD_TCL -
# takes one line in the project.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
################################################################################

# THE BOOT LAYER IS FOUND FROM THIS FILE, NOT THROUGH FPGA_FLOW_DIR. Sourcing it
# through the variable makes flow_boot's split-install check compare a value
# against itself - see the long note in 1_flist.tcl.
set _stage_flow_dir [file dirname [file dirname [file normalize [info script]]]]
source [file join $_stage_flow_dir common flow_utils.tcl]

flow_config prefix BD
flow_boot
flow_banner bd


################################################################################
# KNOBS - at the left margin, so flow_knob_scan and `make help-knobs` find them
# without executing this file.
#
# BD_TCL, BD_OVERLAY_TCL and BD_GLOBAL_SYNTH are NOT here. They are contract
# variables from design.mk (CONTRACT.md section 3.3), arrive as FPGA_*, and are
# read with flow_env - registering them as knobs would put the same value in
# every manifest twice, once as configuration and once as plumbing. Their values
# land in the stage-measurement block at the bottom instead.
################################################################################

opt BD_CREATE_PROJECT   1    ;# 1 = this stage creates the project the BD is built in
opt BD_READ_SOURCES     1    ;# 1 = source the flist stage's sources.tcl first (module refs)
opt BD_VALIDATE         1    ;# 1 = validate_bd_design. See the note where it runs
opt BD_WRAPPER          1    ;# 1 = generate the HDL wrapper round the finished BD
opt BD_WRAPPER_IMPORT   1    ;# 1 = add the wrapper to the project as well as writing it
opt BD_WRITE_TCL        1    ;# 1 = also write a regenerating .tcl beside the .bd
opt BD_UPGRADE_IP       1    ;# 1 = upgrade_ip on the BD's IP before validating
opt BD_ALLOW_ZERO_CELLS 0    ;# 1 = an EMPTY block design is not a hard failure
opt BD_ADD_HEADERS      1    ;# 1 = add the include path's headers to the project. See section 3.1
opt BD_GENERATE_TARGET  all  ;# generate_target <this> on the .bd. "" = do not generate. See section 6.5
opt BD_GENERATE_JOBS    0    ;# >0 = -jobs N on generate_target (0 = let Vivado decide)


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
# 1. IS THIS STAGE CONFIGURED AT ALL? (CONTRACT.md section 12.2 rule 7)
#
# A design with no block design is not a failing design. It writes a manifest
# saying it was switched off, and exits 0 - so that ci/assert-stage.sh can tell
# "switched off" from "ran and died before writing anything", which from disk
# alone are the same empty reports directory.
#
# The stale gate is deleted for the reason given in 2_package_ip.tcl: run tags
# are reused, and a verdict left by an earlier run when the stage WAS configured
# would be read as this run's.
################################################################################

set DESIGN_NAME [flow_env FPGA_DESIGN_NAME $block_name]
set BD_TCL      [flow_env FPGA_BD_TCL]

if {$BD_TCL eq ""} {
    step "bd is NOT CONFIGURED"
    say "BD_TCL is empty, so this design has no block design."
    say "  Nothing was built and nothing is expected to have been. This manifest"
    say "  exists so that 'switched off' is a FACT on disk rather than an"
    say "  inference from an absence of output."
    set stale [file join $REPORT_DIR bd_gate.txt]
    set removed no
    if {[file exists $stale]} {
        file delete -force $stale
        set removed yes
        warn "removed a bd_gate.txt left by an EARLIER run of run tag '$RUN_TAG',"
        warn "  when this stage was configured. A verdict about a stage that did"
        warn "  not run is worse than no verdict."
    }
    set manifest [prov_manifest bd]
    prov_stage_fields $manifest [list \
        stage_configured   no \
        not_configured_why "BD_TCL is empty in the project's design.mk" \
        bd_tcl             "(none)" \
        design_name        $DESIGN_NAME \
        bd_cells           unmeasured \
        overlays_applied   unmeasured \
        bd_file            "(none)" \
        stale_gate_removed $removed \
        hard_failures      0 ]
    say "bd: not configured. Nothing measured, nothing claimed. Exit 0."
    exit 0
}


################################################################################
# 2. THE SEAM, THEN THE INPUTS
################################################################################

flow_hook pre_bd

flow_assert_input $BD_TCL \
    "the project's block-design script. It creates the block design this stage\
     then overlays, validates, wraps and records" \
    BD_TCL

set overlays {}
foreach o [split [flow_env FPGA_BD_OVERLAY_TCL]] {
    set o [string trim $o]
    if {$o eq ""} { continue }
    flow_assert_input $o \
        "an overlay applied over the base block design, IN THE ORDER LISTED -\
         each one edits the design the previous one left" \
        BD_OVERLAY_TCL
    lappend overlays [file normalize $o]
}

set SOURCES_TCL [file join $WORK_DIR sources.tcl]
if {$BD_READ_SOURCES && (![file exists $SOURCES_TCL] || ![file size $SOURCES_TCL])} {
    flow_refuse "no source list at $SOURCES_TCL" \
        "  That file is written by the flist stage and is how the RTL gets into" \
        "  this one - a BD that instantiates a module reference needs it, and" \
        "  Vivado's answer to a module reference it cannot resolve is a BLACK" \
        "  BOX and a warning. Run 'make flist' first, in this run tag." \
        "  Set BD_READ_SOURCES=0 if this BD instantiates only packaged IP."
}

# THE INPUTS THIS STAGE'S RESULT DEPENDS ON, PINNED AT THE MOMENT THEY ARE READ.
# ::PROV_FILES is the declared mechanism (provenance.tcl section 3): one line per
# input rather than a second collector that drifts.
set ::PROV_FILES [list bd_tcl $BD_TCL]
prov_pin bd_tcl $BD_TCL bd-stage-read
set i 0
foreach o $overlays {
    incr i
    lappend ::PROV_FILES bd_overlay_$i $o
    prov_pin bd_overlay_$i $o bd-stage-read
}
if {$BD_READ_SOURCES} {
    lappend ::PROV_FILES sources_tcl $SOURCES_TCL
    prov_pin sources_tcl $SOURCES_TCL bd-stage-read
}

# THE ORDER IS RECORDED THROUGH prov_site_path, LIKE EVERY OTHER PATH IN A
# MANIFEST. CONTRACT.md section 5: a raw path outside the project, the toolkit or
# the run is inventory-shaped disclosure, and manifests get pasted into bug
# reports. prov_site_path is the one place that decision is made.
set overlay_labels {}
foreach o $overlays { lappend overlay_labels [prov_site_path $o] }

set BD_GLOBAL_SYNTH [flow_env FPGA_BD_GLOBAL_SYNTH 0]


################################################################################
# 3. THE PROJECT THE BLOCK DESIGN IS BUILT IN
################################################################################

set PROJ_DIR  [file join $WORK_DIR bd_project]
set PROJ_NAME "${block_name}_bd"
set part_for_project [flow_env FPGA_PART [part part_name]]

# DECLARED AT THE TOP LEVEL, not inside the BD_CREATE_PROJECT branch: the
# handoff written in section 7.5 records the repositories the block design was
# assembled from, and with BD_CREATE_PROJECT=0 that branch never runs. An
# undefined variable there would be a Tcl error AFTER the block design was
# built - the most expensive possible place for one.
set repos {}

if {$BD_CREATE_PROJECT} {
    step "create the block-design project"
    if {![flow_have create_project]} {
        flow_refuse "this tool has no create_project." \
            "  This stage must run inside Vivado. mk/flow.mk launches it through" \
            "  'vivado -mode batch'."
    }
    # -force, because a re-run of one run tag must not fail on its own leftovers,
    # and because reusing whatever is there would build the overlays onto a block
    # design assembled by an earlier and possibly different configuration - which
    # is the one failure mode an ordered overlay list cannot survive.
    create_project -force $PROJ_NAME $PROJ_DIR -part $part_for_project
    say "project: $PROJ_DIR ($part_for_project)"

    # THE BOARD PART, WHEN THERE IS ONE. It is what makes a PS preset, a DDR
    # configuration and the board's own interfaces available to the BD, and it is
    # a PROJECT fact (CONTRACT.md section 1: a board pack ships in the project).
    set board_part [flow_env FPGA_BOARD_PART]
    set board_repos {}
    foreach r [split [flow_env FPGA_BOARD_REPO_PATHS]] {
        if {[string trim $r] ne ""} { lappend board_repos [file normalize [string trim $r]] }
    }
    if {[llength $board_repos]} {
        set_property board_part_repo_paths $board_repos [current_project]
        say "board_part_repo_paths: [join $board_repos { }]"
    }
    if {$board_part ne ""} {
        if {[catch {set_property board_part $board_part [current_project]} e]} {
            flow_refuse "the board part '$board_part' is not installed." \
                "  Vivado: $e" \
                "  A board part is vendor collateral and is NEVER committed to" \
                "  this toolkit (CONTRACT.md section 1.1). It is resolved on the" \
                "  host, through BOARD_REPO_PATHS." \
                "  Board repo paths tried: [expr {[llength $board_repos] ? [join $board_repos { }] : {(none set)}}]"
        }
        say "board_part: $board_part"
    }

    # THE IP THIS BD MAY INSTANTIATE. The packaged core from stage 2 goes on the
    # path FIRST: a project that packages its own core and also has it in a
    # shared repository must get the one this run just built, or the block design
    # is assembled from an IP nothing in this run produced.
    if {[file isdirectory [file join $OUT_DIR ip]]} { lappend repos [file join $OUT_DIR ip] }
    foreach r [split [flow_env FPGA_IP_REPOS]] {
        if {[string trim $r] eq ""} { continue }
        flow_assert_input [string trim $r] "an IP repository named by IP_REPOS" IP_REPOS
        lappend repos [file normalize [string trim $r]]
    }
    if {[llength $repos]} {
        # ONE assignment. set_property REPLACES ip_repo_paths, so one call per
        # repository leaves exactly the last one standing.
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

if {$BD_READ_SOURCES} {
    step "read the source list the flist stage wrote"
    source $SOURCES_TCL
    say "fileset holds [llength [get_files -quiet]] file(s)"

    # AUTOMATIC COMPILE ORDER, THEN AN EXPLICIT update_compile_order. MEASURED
    # 2026-09-08, and it is the difference between a BD that builds and one that
    # black-boxes half of itself:
    #
    #     CRITICAL WARNING: [filemgmt 56-176] Module references are not supported
    #                       in manual compile order mode and will be ignored.
    #     CRITICAL WARNING: [BD 41-1726] Unable to resolve module-source for
    #                       block '/phy_clk_div2_0'.
    #
    # `create_bd_cell -type module -reference <mod>` re-parses the module out of
    # the project's file list, and Vivado will only do that in AUTOMATIC
    # compile-order mode against a file already in sources_1. sources.tcl issues
    # read_verilog/read_vhdl, which in a project can leave the fileset in manual
    # mode, and Vivado's answer to a module reference it cannot resolve is a
    # BLACK BOX and a warning - not an error.
    #
    # The legacy reference flow does the same thing in the same place and says so
    # (build_design.tcl:250-253: "Module references only resolve in
    # automatic-compile-order mode against a file already in sources_1").
    if {[flow_have current_fileset]} {
        try_step "automatic compile order" {
            set_property source_mgmt_mode All [current_project]
            update_compile_order -fileset [current_fileset]
            say "source_mgmt_mode All; compile order updated - a BD module reference"
            say "  re-parses out of the project file list and needs both"
        }
    }
}


################################################################################
# 3.1 THE HEADERS A MODULE REFERENCE NEEDS
#
# MEASURED HERE, 2026-09-08, and it stops a block design dead:
#
#     ERROR: [filemgmt 56-591] Given include File '<path>/foo.vh' needs to be
#     added to the project in order to use it as an RTL module.
#     ERROR: [Common 17-39] 'create_bd_cell' failed due to earlier errors.
#
# `create_bd_cell -type module -reference <mod>` re-parses the module OUT OF THE
# PROJECT'S FILE LIST, and for that it requires every header the module includes
# to be a FILE IN THE PROJECT. An include DIRECTORY is not enough here, though it
# is enough for synthesis - which is why a design synthesises perfectly and its
# block design will not build.
#
# read_flist.tcl deliberately does not hand a header to read_verilog: Vivado
# compiles a header given to read_verilog as a compilation unit, which is a
# syntax error or a duplicate macro. It puts the header's DIRECTORY on the
# include path instead, which is correct for every other stage.
#
# So the headers are added HERE, with FILE_TYPE "Verilog Header" - which is the
# type that means "available to `include, never compiled on its own". Nothing
# else in the flow changes, and the count lands in the manifest.
#
# EVERY DESIGN IN THIS CODEBASE USES `include, so this is not a corner case. Set
# BD_ADD_HEADERS=0 if the include path is enormous and the BD instantiates only
# packaged IP - a packaged core carries its own headers and needs none of this.
################################################################################

set headers_added 0
if {$BD_ADD_HEADERS && [flow_have current_fileset]} {
    set fs [current_fileset]
    set incdirs {}
    catch { set incdirs [get_property include_dirs $fs] }
    set have {}
    foreach f [get_files -quiet] { lappend have [file normalize $f] }
    foreach d $incdirs {
        foreach h [lsort [concat [glob -nocomplain -directory $d *.vh] \
                                 [glob -nocomplain -directory $d *.svh] \
                                 [glob -nocomplain -directory $d *.h]]] {
            set n [file normalize $h]
            if {[lsearch -exact $have $n] >= 0} { continue }
            if {[catch {add_files -norecurse -fileset $fs $n} e]} {
                warn "could not add header $n: $e"
                continue
            }
            # THE TYPE IS THE POINT. Left as Verilog, the file is compiled as a
            # compilation unit of its own - a syntax error, or a macro redefined
            # in every unit that includes it.
            catch { set_property FILE_TYPE "Verilog Header" [get_files $n] }
            lappend have $n
            incr headers_added
        }
    }
    if {$headers_added} {
        say "added $headers_added header(s) as FILE_TYPE 'Verilog Header' - a module"
        say "  reference re-parses out of the project file list and needs them there"
    }
}


################################################################################
# 4. THE BASE BLOCK DESIGN, THEN THE OVERLAYS IN ORDER
################################################################################

step "build the base block design"
say "BD_TCL: $BD_TCL"
say "  it may read: DESIGN_NAME (currently '$DESIGN_NAME'), and every global"
say "  flow_boot publishes - WORK_DIR, OUT_DIR, part_name, board_name."
# NOT WRAPPED IN try_step: this is the one command the stage exists to run, and a
# catch round it turns a real failure into a passing run with a missing artefact
# (flow_utils.tcl, the warning at the top of it).
source $BD_TCL

set bd_designs {}
if {[flow_have get_bd_designs]} { set bd_designs [get_bd_designs -quiet] }
set hard {}

if {![llength $bd_designs]} {
    # NOT a die: the manifest and the gate are written below and a stage that
    # dies here leaves neither, so the reader gets an exit code and no evidence.
    lappend hard "BD_TCL ran and NO block design exists afterwards. Vivado reports a\
                  failed create_bd_design as an ERROR and still exits 0, so the exit\
                  status said nothing. Check that BD_TCL calls create_bd_design, and\
                  that nothing in it caught the error."
} else {
    say "block design(s) after BD_TCL: [join $bd_designs { }]"
    if {[lsearch -exact $bd_designs $DESIGN_NAME] < 0} {
        # NOT RENAMED AWAY. See the header: the .bd file's own contents name the
        # design, so copying it to <DESIGN_NAME>.bd would satisfy every assertion
        # in the flow while every tool that opened it disagreed.
        lappend hard "BD_TCL created [join $bd_designs {, }] and DESIGN_NAME is\
                      '$DESIGN_NAME'. mk/flow.mk asserts \$(WORK_DIR)/$DESIGN_NAME.bd and\
                      ci/assert-stage.sh reads the same path, so nothing downstream will\
                      find this design. The .bd is NOT renamed to match: the file names the\
                      block design internally, so a renamed copy would pass every check\
                      here and be opened under the wrong name everywhere else. Set\
                      DESIGN_NAME in design.mk, or rename the design in BD_TCL."
    } else {
        current_bd_design [get_bd_designs $DESIGN_NAME]
    }
}

set overlays_applied 0
if {[llength $overlays] && ![llength $hard]} {
    step "apply [llength $overlays] overlay(s), in order"
    foreach o $overlays {
        set t0 [clock seconds]
        say "overlay [expr {$overlays_applied + 1}]/[llength $overlays]: $o"
        source $o
        incr overlays_applied
        say "  done ([expr {[clock seconds] - $t0}]s)"
    }
}


################################################################################
# 5. WHAT IS IN IT
################################################################################

set bd_cells "unmeasured"
set bd_ports "unmeasured"
set bd_intf  "unmeasured"
if {[flow_have get_bd_cells] && ![llength $hard]} {
    set bd_cells [llength [get_bd_cells -quiet]]
    set bd_ports [llength [get_bd_ports -quiet]]
    set bd_intf  [llength [get_bd_intf_ports -quiet]]
    say "cells=$bd_cells ports=$bd_ports interface-ports=$bd_intf"
    # AN EMPTY BLOCK DESIGN IS A REAL RESULT AND IT IS ALMOST NEVER THE INTENDED
    # ONE. It builds, validates, wraps, synthesises to nothing and costs no LUTs -
    # so every utilisation budget in the flow passes. Same shape as a black box,
    # one layer up.
    if {$bd_cells == 0 && !$BD_ALLOW_ZERO_CELLS} {
        lappend hard "the block design '$DESIGN_NAME' contains NO cells. It will validate,\
                      wrap, synthesise to nothing and pass every utilisation budget in\
                      this flow, because a design that instantiates nothing uses nothing.\
                      If that is genuinely intended, set BD_ALLOW_ZERO_CELLS=1 and say in\
                      design.mk why."
    }
}

# UPGRADE BEFORE VALIDATING, not after: an out-of-date IP can fail validation for
# a reason that has already been fixed upstream, and a project that pins a
# version deliberately has its own reason to set BD_UPGRADE_IP=0.
if {$BD_UPGRADE_IP && ![llength $hard] && [flow_have upgrade_ip]} {
    try_step "upgrade_ip" {
        set ips [get_ips -quiet]
        if {[llength $ips]} {
            upgrade_ip $ips
            say "upgrade_ip: [llength $ips] IP checked"
        }
    }
}

# VALIDATION IS NOT WRAPPED. validate_bd_design raises a Tcl error on a design
# with an unconnected required pin, an address-map conflict or an incompatible
# interface, and that error must stop the stage: every one of those is a design
# that will not work, and the alternative - a warning and a .bd - is the shape
# this whole toolkit exists to stop.
if {$BD_VALIDATE && ![llength $hard]} {
    step "validate_bd_design"
    validate_bd_design -force
    say "validated"
}


################################################################################
# 6. GLOBAL VERSUS OUT-OF-CONTEXT SYNTHESIS
#
# BD_GLOBAL_SYNTH selects how the block design's IP is synthesised, and the two
# answers produce different netlists, different runtimes and different debug:
#
#   0 (default)  synth_checkpoint_mode Hybrid/Singular - each IP is synthesised
#                OUT OF CONTEXT into its own checkpoint and re-used. Faster on a
#                re-run, and the IP's internals are opaque to the top-level
#                timing report and to an ILA probe.
#   1            synth_checkpoint_mode None - the whole thing is synthesised in
#                one pass with the rest of the design. Slower, and everything is
#                visible and optimisable across the IP boundary.
#
# IT IS SET ON THE .bd FILE OBJECT, not on the project, and that is why it is
# here rather than in flow/steps/synth_setup.tcl: the property belongs to the
# file, so it must be set while this stage still owns it. Setting it in the
# synthesis stage would be setting it on a file that has already been read.
################################################################################

set bd_file ""
set synth_mode "unmeasured"
if {![llength $hard] && [flow_have get_files]} {
    set f [get_files -quiet "$DESIGN_NAME.bd"]
    if {[llength $f]} {
        set bd_obj [lindex $f 0]
        # format %s: get_files returns a design OBJECT whose text form is
        # generated from the live object, and this path is recorded and
        # compared long after. See the note in 2_package_ip.tcl - the same
        # class cost that stage a record naming <run>/work/null.
        set bd_file [format %s [file normalize $bd_obj]]
        if {$BD_GLOBAL_SYNTH == 1} {
            set_property synth_checkpoint_mode None $bd_obj
            say "BD_GLOBAL_SYNTH=1: synth_checkpoint_mode None (one global synthesis pass)"
        }
        catch { set synth_mode [get_property synth_checkpoint_mode $bd_obj] }
        say "synth_checkpoint_mode: $synth_mode"
    }
}


################################################################################
# 7. THE SEAM, THEN THE WRITES (CONTRACT.md section 6.1.3)
#
# post_bd fires HERE: after the overlays and before save_bd_design. It is the
# only placement at which a hook can add a cell, retime a clock or fix an address
# map and have it survive - the next stage reads the .bd from disk, so a hook
# firing after the save would edit an in-memory design nothing reads again. It
# would appear in hooks_run, take time, and change nothing.
################################################################################

flow_hook post_bd

set wrapper ""
set bd_tcl_out ""
set bd_copy ""
set bd_synth_hdl ""
set bd_generated_target "(none)"

if {![llength $hard]} {
    step "save, wrap and record"

    save_bd_design
    if {$bd_file eq "" && [flow_have get_files]} {
        set f [get_files -quiet "$DESIGN_NAME.bd"]
        if {[llength $f]} { set bd_file [format %s [file normalize [lindex $f 0]]] }
    }

    # THE CONTRACT PATH IS A COPY. See the header for why the original cannot be
    # moved: Vivado composes the in-project path from the project layout.
    if {$bd_file ne "" && [file exists $bd_file]} {
        set bd_copy [file join $WORK_DIR "$DESIGN_NAME.bd"]
        if {[file normalize $bd_copy] ne $bd_file} {
            file copy -force $bd_file $bd_copy
            say "bd: $bd_file"
            say "  copied to the contract path: $bd_copy"
        } else {
            say "bd: $bd_file (already at the contract path)"
        }
    }

    ############################################################################
    # 6.5 THE OUTPUT PRODUCTS - WITHOUT THESE THE .bd IS NOT SYNTHESISABLE
    #
    # MEASURED 2026-09-08 ON THIS PROJECT, and it is the defect that stopped the
    # first real BD design this toolkit was pointed at:
    #
    #     ERROR: [Synth 8-439] module 'tidelink_design' not found
    #            [.../tidelink_design_wrapper.v:90]
    #     ERROR: [Synth 8-6156] failed synthesizing module 'tidelink_design_wrapper'
    #
    # A .bd IS NOT HDL. It is a description of a design from which Vivado
    # GENERATES the HDL, the IP instances, the simulation model and the
    # instantiation template - and it generates none of them until it is asked.
    # `generate_target` appeared NOWHERE in this toolkit before this line; the
    # legacy reference flow calls it (build_design.tcl:455,
    # `generate_target all [get_files ${design_name}.bd]`) and its project
    # therefore carries
    #
    #     <proj>.gen/sources_1/bd/<name>/synth/<name>.v
    #
    # which is the module the board-level top instantiates. Without it that
    # instance is an unresolved module, which Vivado reports as an error at the
    # TOP - a very long way from the stage that failed to produce the file.
    #
    # IT HAS TO HAPPEN HERE AND IT CANNOT HAPPEN IN STAGE 4. Generation resolves
    # the BD's IP against the ip_repo_paths, the board part, the IP cache and the
    # module-reference sources - every one of which is set up in THIS stage's
    # project. Doing it in an in-memory synthesis session was tried and measured:
    # the design has no part yet, so `zynq_ultra_ps_e:3.5 does not support the
    # current part 'xc7vx485tffg1157-1'` and every IP in the design fails to
    # resolve.
    #
    # AFTER save_bd_design AND AFTER THE synth_checkpoint_mode IN SECTION 6.
    # Generation reads that property: with `None` it writes the whole design out
    # as RTL for one global synthesis pass, and with Hybrid/Singular it writes
    # per-IP output products for out-of-context synthesis. Generating first and
    # setting the property afterwards produces output products for the other
    # mode, silently.
    #
    # NOT WRAPPED IN try_step. A BD whose output products failed to generate is
    # a BD nothing downstream can synthesise, and `generate_target` is one of
    # the commands that reports an ERROR and lets the script continue.
    ############################################################################
    if {$BD_GENERATE_TARGET ne "" && $bd_file ne "" && [flow_have generate_target]} {
        step "generate_target $BD_GENERATE_TARGET - the BD's output products"
        set gen_args [list $BD_GENERATE_TARGET [get_files "$DESIGN_NAME.bd"]]
        if {[string is integer -strict $BD_GENERATE_JOBS] && $BD_GENERATE_JOBS > 0} {
            lappend gen_args -jobs $BD_GENERATE_JOBS
        }
        set t0 [clock seconds]
        if {[catch {generate_target {*}$gen_args} e]} {
            lappend hard "generate_target $BD_GENERATE_TARGET failed on '$DESIGN_NAME': $e.\
                          The .bd would still be written and would still satisfy every\
                          file assertion in this flow, and synthesis would then fail at\
                          the BOARD TOP with 'module $DESIGN_NAME not found' - a long way\
                          from here. A .bd is not HDL; this is the command that makes it\
                          into some."
        } else {
            say "generated ([expr {[clock seconds] - $t0}]s)"
        }

        # THE ARTEFACT THAT PROVES IT. `generate_target` returns nothing useful
        # and exits 0 on a design whose IP did not resolve, so the question is
        # asked of the FILESYSTEM: is there a synthesisable HDL file named after
        # this block design?
        #
        # Vivado composes that path from the project layout and the answer moved
        # between releases (<proj>.srcs before 2019.2, <proj>.gen after), so it
        # is SEARCHED for rather than spelled out - and searched under the
        # project directory only, which is inside this run's work tree.
        foreach ext {v vhd} {
            if {$bd_synth_hdl ne ""} { break }
            foreach c [lsort [glob -nocomplain -directory $PROJ_DIR \
                          */sources_1/bd/$DESIGN_NAME/synth/$DESIGN_NAME.$ext \
                          */bd/$DESIGN_NAME/synth/$DESIGN_NAME.$ext]] {
                if {[file exists $c] && [file size $c]} { set bd_synth_hdl [file normalize $c] ; break }
            }
        }
        if {$bd_synth_hdl eq "" && ![llength $hard]} {
            lappend hard "generate_target $BD_GENERATE_TARGET reported no error and NO\
                          synthesisable HDL for '$DESIGN_NAME' exists under [prov_site_path $PROJ_DIR].\
                          Looked for */bd/$DESIGN_NAME/synth/$DESIGN_NAME.{v,vhd}. That file is\
                          what the board-level top instantiates; without it the next stage\
                          fails at elaboration with 'module $DESIGN_NAME not found' and the\
                          cause is two stages upstream."
        } elseif {$bd_synth_hdl ne ""} {
            set bd_generated_target $BD_GENERATE_TARGET
            say "synthesisable HDL: $bd_synth_hdl ([file size $bd_synth_hdl] bytes)"
        }
    } elseif {$BD_GENERATE_TARGET eq ""} {
        warn "BD_GENERATE_TARGET is empty: the block design's output products were"
        warn "  NOT generated. A .bd is not HDL. Unless something else in this"
        warn "  project generates them, the next stage cannot synthesise this"
        warn "  design and will fail at the board-level top."
    }

    # THE WRAPPER. A block design is not an HDL module; the wrapper is what the
    # board-level top instantiates, and without it TOP has nothing to hook to.
    if {$BD_WRAPPER && [flow_have make_wrapper] && $bd_file ne ""} {
        set args [list -files [get_files "$DESIGN_NAME.bd"] -top -force]
        if {$BD_WRAPPER_IMPORT} { lappend args -import }
        if {[catch {set wrapper [make_wrapper {*}$args]} e]} {
            lappend hard "make_wrapper failed on '$DESIGN_NAME': $e. The wrapper is the\
                          HDL module the board-level top instantiates; without it the block\
                          design is unreachable from the RTL and TOP elaborates with an\
                          unresolved instance - which Vivado reports as a black box and a\
                          warning."
        } else {
            set wrapper [format %s [lindex $wrapper 0]]
            say "wrapper: $wrapper"
        }
    }

    # A REGENERATING SCRIPT BESIDE THE .bd. A .bd is a generated file that no
    # human reads and no review can diff; write_bd_tcl produces the script that
    # rebuilds it, and THAT is diffable between two runs. It is the only artefact
    # in this stage a reviewer can actually read.
    if {$BD_WRITE_TCL && [flow_have write_bd_tcl]} {
        set bd_tcl_out [file join $WORK_DIR "${DESIGN_NAME}_bd.tcl"]
        try_step "write_bd_tcl" {
            write_bd_tcl -force -no_ip_version $bd_tcl_out
            say "regenerating script: $bd_tcl_out"
        }
    }
}


################################################################################
# 7.5 THE HANDOFF - work/bd_handoff.tcl
#
# CONTRACT.md section 5: "Handoff is by artefact name inside work/, never
# renamed." For a block design the NAME IS NOT ENOUGH, and this file is the
# artefact that makes the contract satisfiable rather than the sentence that
# breaks it.
#
# WHY A BARE .bd CANNOT BE THE HANDOFF. Measured: stage 4 read
# work/<DESIGN_NAME>.bd - a byte copy of the real file, at the path section 4
# asserts - and got a design with no IP in it. A .bd names its IP by VLNV and
# its output products by RELATIVE LOCATION inside the project that owns them.
# Copied away from that project it is a manifest pointing at nothing: the
# generated synth/<name>.v, the per-IP directories and the .xci files are all
# left behind. The copy satisfies `test -s` and every assertion in the flow, and
# the design it describes is not reachable from it. That is the exact shape of
# failure this toolkit exists to refuse.
#
# THE TWO ANSWERS, AND WHY THIS ONE.
#
#   (a) COPY THE PRODUCTS. Carry synth/<name>.v plus every IP output product
#       into work/ and have stage 4 read them as plain sources. Rejected: the
#       set is not knowable from outside the tool. It differs with
#       synth_checkpoint_mode (RTL for None, .dcp stubs plus .xci for
#       Hybrid/Singular), it includes per-IP constraint files that must be read
#       with their scope, and a list that is short by one file produces a BLACK
#       BOX - no error, no LUTs, every budget green. Reproducing Vivado's own
#       file resolution in Tcl is a second implementation of it, and the copy
#       that is wrong is always the one you are not reading.
#
#   (b) HAND OVER THE PROJECT, WHICH IS WHAT THIS DOES. The canonical .bd stays
#       where the tool owns it - inside this stage's project, inside this run's
#       work directory - with its output products beside it, and the handoff
#       artefact is a small generated SCRIPT naming it. Stage 4 sources that
#       script and Vivado does its own file resolution, which is the only
#       implementation of it that is guaranteed to agree with itself.
#
# THE COPY AT THE CONTRACT PATH STAYS, and is now honestly labelled. make and
# ci/assert-stage.sh assert on work/<DESIGN_NAME>.bd; it remains the stage's
# named artefact and it remains a real, openable .bd. What it is NOT is the
# thing the next stage reads, and the manifest records both paths so nobody has
# to infer which is which.
#
# EVERYTHING THE SCRIPT NAMES IS INSIDE THIS RUN'S WORK DIRECTORY. Section 5
# forbids a stage addressing another run's work dir, and the paths written here
# are composed from $WORK_DIR by construction. They are ABSOLUTE because stage 4
# runs with its cwd set to its own work directory, which is a different
# directory when IN_RUN_TAG differs from RUN_TAG - and that case is the whole
# reason IN_RUN_TAG exists.
################################################################################

set bd_handoff ""
if {![llength $hard] && $bd_file ne ""} {
    set bd_handoff [file join $WORK_DIR bd_handoff.tcl]
    set fh [open $bd_handoff w]
    puts $fh "################################################################################"
    puts $fh "# bd_handoff.tcl - GENERATED by flow/vivado/3_bd.tcl. Do not edit."
    puts $fh "#"
    puts $fh "# The stage-3 -> stage-4 handoff for a block design. Sourced by"
    puts $fh "# flow/vivado/4_synth.tcl at global scope, INSTEAD of read_bd on the copy at"
    puts $fh "# the contract path - that copy is separated from its output products and"
    puts $fh "# reading it yields a design with no IP in it."
    puts $fh "#"
    puts $fh "# Read the long note in 3_bd.tcl section 7.5 before changing anything here."
    puts $fh "################################################################################"
    puts $fh ""
    puts $fh "set ::BD_HANDOFF(design_name)      [list $DESIGN_NAME]"
    puts $fh "set ::BD_HANDOFF(bd)               [list $bd_file]"
    puts $fh "set ::BD_HANDOFF(bd_contract_copy) [list $bd_copy]"
    puts $fh "set ::BD_HANDOFF(project)          [list $PROJ_DIR]"
    puts $fh "set ::BD_HANDOFF(synth_hdl)        [list $bd_synth_hdl]"
    puts $fh "set ::BD_HANDOFF(generated_target) [list $bd_generated_target]"
    puts $fh "set ::BD_HANDOFF(synth_checkpoint_mode) [list $synth_mode]"
    puts $fh "set ::BD_HANDOFF(wrapper)          [list $wrapper]"
    puts $fh ""
    puts $fh "# The IP repositories the block design was ASSEMBLED from. Re-declared here"
    puts $fh "# because the reading stage resolves the same VLNVs again, and a repository"
    puts $fh "# that was on the path when the BD was built and is not on the path when it"
    puts $fh "# is read gives an unresolved IP - which is a black box, a warning, and no"
    puts $fh "# error at all."
    puts $fh "set ::BD_HANDOFF(ip_repo_paths) [list $repos]"
    puts $fh ""
    puts $fh "# NO `info commands read_bd` GUARD, AND THAT IS MEASURED, NOT AN OMISSION."
    puts $fh "# Vivado 2024.1 does not list read_bd in `info commands` - it is resolved"
    puts $fh "# through the tool's own autoload path, not registered up front - so a guard"
    puts $fh "# written that way refuses inside the very tool that implements the command."
    puts $fh "# Measured 2026-09-08: the guard fired in a live Vivado synthesis session."
    puts $fh "# A tool that really has no read_bd fails on the call below, naming it."
    puts $fh "if {!\[file exists \$::BD_HANDOFF(bd)\]} {"
    puts $fh "    error \"the block design named by this handoff is gone: \$::BD_HANDOFF(bd)\""
    puts $fh "}"
    puts $fh "read_bd \$::BD_HANDOFF(bd)"
    close $fh
    say "handoff: $bd_handoff"
    say "  it names the .bd INSIDE the project, where its output products are."
}

# --- THE ARTEFACT ASSERTION --------------------------------------------------
#
# ON THE ARTEFACT, NEVER ON EXIT STATUS (CONTRACT.md rule 0).
if {![llength $hard]} {
    set want [file join $WORK_DIR "$DESIGN_NAME.bd"]
    if {![file exists $want] || ![file size $want]} {
        lappend hard "no block design at [prov_site_path $want] after save_bd_design.\
                      That is the path mk/flow.mk asserts and ci/assert-stage.sh reads.\
                      Vivado exits 0 after an error here, so this is the only place it\
                      shows."
    }
}


################################################################################
# 8. THE VERDICT, THEN THE MANIFEST
################################################################################

set delegated {}
lappend delegated "the block design's own CORRECTNESS, owner=the project that wrote\
                   [prov_site_path $BD_TCL]: validate_bd_design checks connectivity,\
                   address-map consistency and interface compatibility, and nothing\
                   more. A design that is wired correctly to the wrong thing passes it"
if {$overlays_applied} {
    lappend delegated "$overlays_applied overlay(s), owner=the project: each edits the\
                       design the previous one left, so their ORDER is part of the\
                       design. The sequence is recorded in the manifest; whether it is\
                       the intended one is not checked here"
}
if {$bd_synth_hdl ne ""} {
    lappend delegated "the CONTENT of the generated HDL, owner=Vivado's own IP\
                       generators: the '$bd_generated_target' target produced\
                       [prov_site_path $bd_synth_hdl] and this stage checked that it\
                       exists and is non-empty. Nothing here elaborates it, and an IP\
                       that generated a stub because its licence or its part was wrong\
                       produces a file of exactly this shape"
}
if {$synth_mode ne "unmeasured"} {
    lappend delegated "synth_checkpoint_mode '$synth_mode', owner=synth: it decides whether\
                       the BD's IP is synthesised out of context or in one global pass, and\
                       the two produce different netlists, runtimes and probe visibility.\
                       The consequence is measured in the synthesis stage, not here"
}

prov_gate bd bd \
    [list \
        "WHAT THIS CHECK IS: an assertion that a block design named DESIGN_NAME" \
        "exists, that it is not empty, that every overlay was applied in the order" \
        "the project listed them, that Vivado's own validation passed, and that the" \
        ".bd and its wrapper are on disk where the rest of the flow looks." \
        "" \
        "WHAT IT IS NOT: any statement that the block design is the RIGHT one." \
        "Nothing here synthesises it, and validate_bd_design has never had an" \
        "opinion about whether a correctly-wired design does the intended thing." ] \
    $hard \
    {} \
    $delegated \
    [list \
        "whether the block design SYNTHESISES. It is not synthesised here; an IP that\
         fails out-of-context synthesis fails in stage 4" \
        "whether the ADDRESS MAP is the one the firmware expects. validate_bd_design\
         checks a map for internal consistency - overlaps, unmapped masters - and\
         cannot know what any software thinks the addresses are" \
        "whether the OVERLAY ORDER is right. The list is applied and recorded exactly\
         as written; reordering two overlays produces a different design with no\
         error anywhere" \
        "whether the BD's IP is LICENSED for bitstream generation. A core can be\
         instantiated, validated and synthesised and still refuse at write_bitstream" \
        "whether the wrapper is what TOP instantiates. The wrapper's module name is\
         recorded here; nothing checks that the board-level top names it" \
        "whether the .bd COPY at the contract path is usable on its own. It is not,\
         and it is not meant to be: a .bd names its IP and its output products by\
         location inside the project that owns them, so the copy is an assertion\
         target and work/bd_handoff.tcl is the handoff. Section 7.5" \
        "whether the generated HDL MATCHES the .bd. generate_target ran against the\
         design in memory and save_bd_design wrote the same design, but nothing\
         here re-reads the file and compares" ]

set manifest [prov_manifest bd]
prov_stage_fields $manifest [list \
    stage_configured   yes \
    bd_tcl             [prov_site_path $BD_TCL] \
    design_name        $DESIGN_NAME \
    bd_designs         [expr {[llength $bd_designs] ? [join $bd_designs " "] : "(none)"}] \
    bd_cells           $bd_cells \
    bd_ports           $bd_ports \
    bd_intf_ports      $bd_intf \
    overlays_requested [llength $overlays] \
    overlays_applied   $overlays_applied \
    overlay_order      [expr {[llength $overlay_labels] ? [join $overlay_labels " "] : "(none)"}] \
    bd_file            [expr {$bd_copy eq "" ? "UNVERIFIED:no-bd-written" : [prov_site_path $bd_copy]}] \
    bd_file_bytes      [expr {($bd_copy ne "" && [file exists $bd_copy]) ? [file size $bd_copy] : "unmeasured"}] \
    bd_source_path     [expr {$bd_file eq "" ? "UNVERIFIED:not-in-the-project" : [prov_site_path $bd_file]}] \
    bd_global_synth    $BD_GLOBAL_SYNTH \
    synth_checkpoint_mode $synth_mode \
    bd_wrapper         [expr {$wrapper eq "" ? "(none)" : [prov_site_path $wrapper]}] \
    bd_generate_target $bd_generated_target \
    bd_synth_hdl       [expr {$bd_synth_hdl eq "" ? "UNVERIFIED:no-synthesisable-hdl-generated" : [prov_site_path $bd_synth_hdl]}] \
    bd_synth_hdl_bytes [expr {($bd_synth_hdl ne "" && [file exists $bd_synth_hdl]) ? [file size $bd_synth_hdl] : "unmeasured"}] \
    bd_handoff         [expr {($bd_handoff ne "" && [file exists $bd_handoff]) ? [prov_site_path $bd_handoff] : "UNVERIFIED:no-handoff-written"}] \
    bd_regen_tcl       [expr {($bd_tcl_out ne "" && [file exists $bd_tcl_out]) ? [prov_site_path $bd_tcl_out] : "(none)"}] \
    validated          [expr {$BD_VALIDATE ? "yes" : "no (BD_VALIDATE=0)"}] \
    sources_read       [expr {$BD_READ_SOURCES ? "yes" : "no"}] \
    headers_added      $headers_added \
    hard_failures      [llength $hard] ]

if {[llength $hard]} {
    die "the bd stage found [llength $hard] hard failure(s)." \
        "  The manifest and the gate file were written first, so the evidence is" \
        "  on disk and this run is judged rather than lost:" \
        "    [file join $REPORT_DIR bd_gate.txt]" \
        "    $manifest"
}
say "bd complete: '$DESIGN_NAME', $bd_cells cell(s), $overlays_applied overlay(s) applied"
say "  bd      [expr {$bd_copy eq "" ? "(none)" : $bd_copy}]"
say "  wrapper [expr {$wrapper eq "" ? "(none)" : $wrapper}]"
say "  hdl     [expr {$bd_synth_hdl eq "" ? "(none)" : $bd_synth_hdl}]"
say "  handoff [expr {$bd_handoff eq "" ? "(none)" : $bd_handoff}]"

# Copyright (C) 2026, SoC Labs (www.soclabs.org)
