################################################################################
# flow_utils.tcl - the boot and helper layer every stage script goes through
#
# Tool-agnostic Tcl. Nothing here calls a Vivado command unguarded: the knob
# census, the stage-stub harness and `read_flist.tcl` all load this file under a
# bare tclsh, and a helper that assumed a tool would silently take the whole
# phase-1 test suite with it. Anything Vivado-specific belongs in the stage
# script or the step file that needs it.
#
# READ THIS BEFORE USING try_step
# ------------------------------
# try_step catches the error and carries on. That is right for OPTIONAL work -
# reports, censuses, tuning - and wrong for anything the run's result depends
# on. CONTRACT.md rule 0 is the reason: Vivado exits 0 on a failed route, on
# unmet timing and on a constraint file that matched nothing, so a try_step
# wrapped round a core step converts a real failure into a passing run with a
# missing artefact. That is the failure mode the whole toolkit exists to stamp
# out. Leave the core flow unwrapped and let it stop.
#
# Per-script configuration:
#     flow_config prefix SYNTH   ;# tags messages "SYNTH: ...", "SYNTH-FAIL: ..."
#     flow_config strict 1       ;# make `flow_fail` fatal rather than advisory
#
#
# ENVIRONMENT THIS LAYER READS
# ===========================================================================
# mk/flow.mk DID NOT EXIST when this file was written (the repository held
# CONTRACT.md, LICENSE and flow/common/seams.txt and nothing else), so the
# export set below is DECLARED HERE and must be reconciled against mk/flow.mk
# the moment that file lands. If the two disagree, one of them is a bug - say
# which, do not silently pick. CONTRACT.md, first paragraph.
#
# The naming rule: every make variable in CONTRACT.md section 3 is exported with
# an `FPGA_` prefix, EXCEPT the two that already carry it (`FPGA_FLOW_DIR`,
# `FPGA_DIR`), which are exported under their own names. So `BLOCK` arrives as
# `FPGA_BLOCK`, `OVERRIDES_DIR` as `FPGA_OVERRIDES_DIR`.
#
# REQUIRED - flow_boot dies naming the variable and what it locates:
#   FPGA_FLOW_DIR      this repository's root. Locates flow/, part/, steps
#   FPGA_DIR           the project's fpga/ directory - the one holding design.mk
#   FPGA_BLOCK         BLOCK. The design's short name, stem of every artefact
#   FPGA_RUN_DIR       $(BUILD_DIR)/$(RUN_TAG). This run's output tree
#   FPGA_PART_DIR      PART_DIR. The part pack directory (toolkit-side)
#   FPGA_BOARD_DIR     BOARD_DIR. The board pack directory (PROJECT-side)
#
# OPTIONAL - read through flow_env, with the default shown:
#   FPGA_RUN_TAG       default            identity of this run
#   FPGA_IN_RUN_TAG    = FPGA_RUN_TAG     which run's databases this stage READS
#   FPGA_WORK_DIR      $RUN_DIR/work      projects, checkpoints, tool cwd
#   FPGA_LOG_DIR       $RUN_DIR/logs
#   FPGA_REPORT_DIR    $RUN_DIR/reports   manifests, gates, .rpt
#   FPGA_OUT_DIR       $RUN_DIR/outputs   .bit .bin .xsa .hwh .dcp
#   FPGA_IN_WORK_DIR   $WORK_DIR          where a resumed stage reads from
#   FPGA_SYNTH_OUT_DIR $OUT_DIR           where impl finds the synth checkpoint
#   FPGA_HOOKS_DIR     ""                 project hooks. "" disables hooks
#   FPGA_OVERRIDES_DIR ""                 project step overrides
#   FPGA_PROJECT_ROOT  $FPGA_DIR/..       git provenance only
#   FPGA_BOARD         ""                 board name, for the manifest
#   FPGA_PART          ""                 device. A project override wins over
#                                         the board pack - see flow_boot
#   FPGA_TARGET        ""                 target name
#   FPGA_TARGET_DIR    ""                 target collateral (board top, XDC, BD)
#   FPGA_TOP           ""                 the BOARD-LEVEL top module
#   FPGA_DESIGN_NAME   $FPGA_BLOCK        block-design name, when a BD is used
#   FPGA_FLOW_MODE     project            project | direct | dfx | protocompiler
#   FPGA_PLATFORM      bare               bare | pynq
#   FPGA_SYS_CLK_FREQ_HZ ""               ALSO compiled into firmware (sec 3.4)
#   FPGA_RTL_FLIST     ""                 the master flist
#   FPGA_SV_FILES      ""                 files forced to SystemVerilog
#   FPGA_XDC_PINS      ""                 read in synth AND impl
#   FPGA_XDC_TIMING    ""                 implementation only
#   FPGA_XDC_DRC       ""                 implementation only
#   FPGA_XDC_EXTRA     ""                 a LIST, order preserved
#   FPGA_XDC_POST_ROUTE ""                `source`d after route_design (sec 9.4)
#   FPGA_NUM_JOBS      8                  parallel jobs
#   FPGA_VIVADO_VER    ""                 when set it is ASSERTED, not assumed
#   FPGA_TOOL_HINT     unknown            what launched this stage, for the log
#   FPGA_LOG_FILE      ""                 this stage's log, for the manifest
#   FPGA_STAGE_T0      ""                 epoch seconds at stage launch. When
#                                         unset, runtime is measured from boot,
#                                         which UNDER-reports; the manifest says
#                                         which of the two it got.
# ===========================================================================
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
################################################################################

# Idempotent: this file can be re-sourced (interactively, by read_flist.tcl, or
# by a helper) without tripping the collision check below.
if {[info exists ::flow_utils_loaded]} { return }
set ::flow_utils_loaded 1

# Where this file lives. Captured AT SOURCE TIME because `info script` is only
# meaningful here, and used so the seam list and the step directory are found
# relative to the code reading them rather than to a cwd nobody controls
# (CONTRACT.md section 10: an addressable artefact resolves its own location).
set ::flow_common_dir [file dirname [file normalize [info script]]]

# `proc` silently REPLACES an existing command of the same name. These names are
# short and generic and this file is sourced into every Vivado stage, so assert
# they are free rather than discover a shadowed built-in an hour into an
# implementation run. The equivalent guard in the reference ASIC toolkit has
# already fired in anger: a helper named `fail` shadowed a tool builtin and
# aborted a route stage 2.5 hours in. `part` and `board` are the two on this
# list most likely to collide in a future Vivado; that is why they are checked
# rather than assumed.
foreach __c {
    flow_config say warn step die flow_refuse flow_fail try_step opt mf
    fresh_report flow_have flow_env flow_need_env flow_knob_dump flow_knob_scan
    flow_assert_input flow_seams flow_hook flow_hook_exists flow_hook_path
    flow_step flow_steps_available flow_boot flow_banner flow_pack_shim
    flow_pack_alias_check
    flow_pack_read part board part_have board_have
} {
    if {[llength [info commands $__c]]} {
        error "flow_utils.tcl: '$__c' is already a command in this tool - it\
               would be shadowed. Rename the helper (and its callers) before\
               sourcing."
    }
}
unset __c

# prefix : tag on every message emitted through this file
# strict : `flow_fail` is fatal when true, advisory when false
# knobs  : names registered by `opt`, in declaration order, for the manifest
# hooks  : project hooks that actually ran, for the manifest
# steps  : {name=source} for every flow_step, so an override is traceable
array set ::flow {
    prefix FLOW
    strict 0
    knobs  {}
    hooks  {}
    steps  {}
}

# Reject undeclared keys rather than quietly creating them: a typo'd
# `flow_config stict 1` that silently did nothing is exactly the class of silent
# no-op this toolkit exists to stamp out.
proc flow_config {key value} {
    if {![info exists ::flow($key)]} {
        error "flow_config: unknown key '$key' (have: [lsort [array names ::flow]])"
    }
    set ::flow($key) $value
}


################################################################################
# 1. MESSAGES AND EXIT CODES
#
# CONTRACT.md section 10 fixes the exit codes and this file is where the Tcl
# half of them lives:
#
#   0    ok
#   1    a check failed          -> die
#   2    refused / unusable input -> flow_refuse
#
# The distinction is not decoration. `make` and ci/lib.sh grade the two
# differently: a failed check is a result about the design, a refusal is a
# statement that no result was produced at all. Collapsing them makes a
# configuration mistake indistinguishable from a timing failure.
################################################################################

proc say  {args} { puts "$::flow(prefix): [join $args { }]" }
proc warn {args} { puts "$::flow(prefix)-WARN: [join $args { }]" }
proc step {text} { puts "\n==== $::flow(prefix): $text ====" }

# A check failed. Always fatal.
proc die {args} {
    foreach line $args { puts "$::flow(prefix)-FAIL: $line" }
    exit 1
}

# The input is unusable and nothing was measured. Always fatal, exit 2.
proc flow_refuse {args} {
    foreach line $args { puts "$::flow(prefix)-REFUSED: $line" }
    exit 2
}

# Fatal only under `flow_config strict 1`; advisory otherwise.
proc flow_fail {args} {
    foreach line $args { puts "$::flow(prefix)-FAIL: $line" }
    if {$::flow(strict)} { die "strict mode is set - stopping here." }
}

# Does this tool have <cmd>? Every optional query goes through it, so a stage
# that cannot ask a question SAYS SO rather than skipping in silence.
proc flow_have {cmd} { return [expr {[llength [info commands $cmd]] > 0}] }


################################################################################
# 2. OPTIONAL STEPS
################################################################################

# OPTIONAL work only - see the warning at the top of this file.
proc try_step {label body} {
    if {[catch {uplevel 1 $body} msg]} { warn "'$label' skipped: $msg" ; return 0 }
    return 1
}


################################################################################
# 3. ENVIRONMENT-OVERRIDABLE KNOBS
################################################################################

# `opt NAME default` sets global $NAME from $env(NAME) or the default, and
# records NAME in ::flow(knobs).
#
# THE REGISTRATION IS THE POINT. CONTRACT.md section 5 requires the run manifest
# to carry every knob and its resolved value, "enumerated from the `opt`
# declarations in the flow scripts - *not* a hand-maintained list, which
# drifts". The reference toolkit's hand-maintained list had already silently
# dropped three effort knobs, every one of which changes QoR, so two runs that
# differed in placement effort produced manifests that agreed.
#
# A knob is therefore registered by the ACT of reading it. There is no second
# place to keep in step.
proc opt {name default} {
    global $name
    if {[lsearch -exact $::flow(knobs) $name] < 0} { lappend ::flow(knobs) $name }
    if {[info exists ::env($name)] && [string trim $::env($name)] ne ""} {
        set $name $::env($name)
    } else {
        set $name $default
    }
}

# $env(NAME) or a default, WITHOUT registering a knob. For engine plumbing the
# Makefile always supplies; registering it would put the same value in every
# manifest twice, once as plumbing and once as configuration.
proc flow_env {name {default ""}} {
    if {[info exists ::env($name)] && [string trim $::env($name)] ne ""} {
        return $::env($name)
    }
    return $default
}

# $env(NAME) or die naming what the variable LOCATES and the design.mk variable
# that moves it. Every engine input goes through this, so a hand-run stage
# script fails in milliseconds with an actionable message instead of at some
# arbitrary later line inside a tool.
proc flow_need_env {name why} {
    set v [flow_env $name]
    if {$v eq ""} {
        die "$name is not set in the environment." \
            "  $why" \
            "  The toolkit's mk/flow.mk exports every FPGA_* variable it" \
            "  defines. If you are running this stage script by hand, use" \
            "  'make env' to print the environment and source it first." \
            "  'make check' validates the whole project contract without" \
            "  launching a tool."
    }
    return $v
}

# One line per registered knob, for a log a reader can diff against another
# run's without opening a manifest.
proc flow_knob_dump {{filter ""}} {
    foreach k $::flow(knobs) {
        if {$filter ne "" && ![string match $filter $k]} { continue }
        set v "n/a (unset)"
        catch { set v [set ::$k] }
        say [format "  knob %-26s %s" $k $v]
    }
}

# Every `opt` declaration in a directory of Tcl, found by READING THE FILES
# rather than by running them. `make help-knobs` has to answer "what can I
# tune?" without launching Vivado and without executing project override code,
# and a stage that sourced only three of the five step files would otherwise
# report three fifths of the knobs as though the rest did not exist.
#
# This is a static scan, so it reports what is DECLARED. flow_knob_dump reports
# what was RESOLVED. They answer different questions and neither substitutes for
# the other; the manifest carries the resolved set, because that is what the run
# actually used.
proc flow_knob_scan {dir} {
    set out {}
    foreach f [lsort [glob -nocomplain -directory $dir *.tcl]] {
        set fh [open $f r]
        set body [read $fh]
        close $fh
        foreach line [split $body "\n"] {
            # Leading whitespace only: an `opt` inside a comment or a string is
            # not a declaration, and a regex cannot tell the difference. A
            # declaration lives at the left margin by convention in this
            # toolkit, and the scan says so rather than pretending to parse Tcl.
            if {[regexp {^opt[ \t]+([A-Za-z_][A-Za-z0-9_]*)[ \t]+(.*)$} $line -> n rest]} {
                # Strip a trailing ;# comment, then the surrounding braces or
                # quotes Tcl would have removed.
                regsub {[ \t]*;#.*$} $rest "" rest
                set rest [string trim $rest]
                if {[string match "\{*\}" $rest] || [string match "\"*\"" $rest]} {
                    set rest [string range $rest 1 end-1]
                }
                lappend out [list $n $rest [file tail $f]]
            }
        }
    }
    return $out
}


################################################################################
# 4. SMALL REPORT HELPERS
################################################################################

# One key/value line of a manifest. ONE definition, so the eight blocks of a
# manifest cannot drift into eight column widths.
proc mf {fh k v} { puts $fh [format "%-28s %s" $k $v] }

# Create/truncate a report and return its path, for the reports that have to be
# built by appending.
proc fresh_report {name} {
    global REPORT_DIR
    close [open [file join $REPORT_DIR $name] w]
    return [file join $REPORT_DIR $name]
}


################################################################################
# 5. THE INPUT CONTRACT
#
# Every REQUIRED project path is asserted before a licence-hour is spent on it.
# A bare "file not found" costs the reader ten minutes; this says what the file
# is FOR and which design.mk variable moves it.
################################################################################

# Refuse if <path> is missing, empty, or a zero-byte file. <what> says what the
# file is for; <var> is the design.mk variable that points at it.
#
# EXIT 2, NOT 1. Nothing was measured: this is an unusable input, not a check
# that ran and came out red. CONTRACT.md section 10.
proc flow_assert_input {path what var} {
    if {$path eq ""} {
        flow_refuse "no path configured for $what." \
            "  Set $var in the project's design.mk." \
            "  'make check' lists every required path and its purpose."
    }
    if {[file isdirectory $path]} {
        if {![llength [glob -nocomplain -directory $path *]]} {
            flow_refuse "$path exists but is EMPTY." \
                "  It should hold: $what" \
                "  Overridden by $var in the project's design.mk."
        }
        say "ok: $path (directory)"
        return 1
    }
    if {![file exists $path]} {
        flow_refuse "no file at $path" \
            "  Expected: $what" \
            "  Override the location with $var in the project's design.mk." \
            "  'make check' lists every required path and its purpose."
    }
    if {![file size $path]} {
        flow_refuse "$path is ZERO BYTES." \
            "  Expected: $what" \
            "  A truncated input is worse than a missing one - the tool would" \
            "  read it happily and produce a design built from nothing, and" \
            "  every 'test -e' in the world is satisfied by it."
    }
    say "ok: $path ([file size $path] bytes)"
    return 1
}


################################################################################
# 6. PROJECT HOOKS
#
# A hook is an OPTIONAL project Tcl file sourced at a named point in a stage:
# $(HOOKS_DIR)/<seam>.tcl, lower case, underscores, `.tcl`, exact.
#
# CONTRACT.md section 6.1 fixes four properties, all of them deliberate:
#
#   optional        an absent hook is not an error and is not mentioned.
#   announced       a hook that runs prints its PATH and its RUNTIME. A hook
#                   that runs invisibly is a debugging nightmare, and every
#                   "why does this run differ" question starts here.
#   able to abort   a hook is project code in the critical path. An error raised
#                   inside one STOPS THE STAGE - it is not caught and downgraded
#                   and there is no advisory-hook mode. A hook that does
#                   something genuinely optional wraps THAT PART itself, in its
#                   own catch, and says why. `die` from a hook works too and is
#                   the right way to express "this design must not proceed".
#   recorded        every hook that ran lands in ::flow(hooks) and therefore in
#                   the stage manifest, so a result traces to the project code
#                   that shaped it.
#
# The abort path names WHICH hook failed before re-raising, because a bare Tcl
# error from a sourced file names a line number in a file the stage script has
# never heard of.
#
# THE SEAM LIST IS NOT IN THIS FILE. It is flow/common/seams.txt, one name per
# line, and CONTRACT.md's third rule is what put it there: the reference ASIC
# toolkit hardcodes a five-entry step whitelist against a seven-file directory,
# so two real extension points are undocumented and warn spuriously. A second
# copy of a list is a second thing to be wrong, and the copy that is wrong is
# always the one you are not reading.
#
# post_bitstream carries the reference toolkit's post_route trap: the bitstream
# is already written when it fires, so a hook there cannot change what the run
# ships. The template says so; this layer cannot enforce it.
################################################################################

# The seam names, read from the one file that holds them.
#
# DELIBERATELY NOT CACHED, for the same reason flow_hook_exists is not memoised
# and one more: seams.txt is toolkit data, so a change to it mid-run means the
# engine was edited under a running flow, and answering that from a cache hides
# it. The cost is a 700-byte read per hook call.
proc flow_seams {} {
    set f [file join $::flow_common_dir seams.txt]
    if {![file exists $f]} {
        die "no seam list at $f" \
            "  flow/common/seams.txt is THE list of flow-hook seams and the only" \
            "  copy of it. This checkout of the toolkit is incomplete."
    }
    set out {}
    set fh [open $f r]
    set n 0
    while {[gets $fh line] >= 0} {
        incr n
        set line [string trim $line]
        if {$line eq "" || [string match "#*" $line]} { continue }
        if {![regexp {^[a-z][a-z0-9_]*$} $line]} {
            close $fh
            die "seams.txt:$n is not a seam name: '$line'" \
                "  A seam is lower case, digits and underscores, one per line." \
                "  Anything else would name a hook file no shell glob can match."
        }
        if {[lsearch -exact $out $line] >= 0} {
            close $fh
            die "seams.txt:$n declares '$line' twice." \
                "  A duplicate is copy-paste damage, not intent, and it makes" \
                "  the seam census disagree with the seam list."
        }
        lappend out $line
    }
    close $fh
    if {![llength $out]} {
        die "$f names no seams." \
            "  An empty seam list disables every project hook silently, which" \
            "  reads exactly like a project that has no hooks."
    }
    return $out
}

# A seam name, or die. Called by BOTH flow_hook and flow_hook_exists: a
# mistyped probe that quietly returned 0 would leave the guard it was arming
# permanently disarmed, and that failure is invisible in every log.
proc flow_seam_assert {name where} {
    set seams [flow_seams]
    if {[lsearch -exact $seams $name] >= 0} { return 1 }
    die "$where: '$name' is not a flow-hook seam." \
        "  This is a bug in the FLOW, not in the project: a stage script asked" \
        "  for a seam that flow/common/seams.txt does not declare, so no" \
        "  project could ever have written a hook for it and no warning would" \
        "  ever have been printed." \
        "  Declared seams: [join $seams { }]" \
        "  Either add the seam to flow/common/seams.txt (and to the hook" \
        "  template), or fix the spelling at the call site."
}

# Is there a hook file for <name>, without sourcing it?
#
# WHY THIS IS SEPARATE FROM flow_hook. A stage that has to ARM A GUARD around a
# hook needs to know a hook is coming BEFORE it runs, so it can take a "before"
# measurement - and it needs to not pay for that measurement on the runs where
# no hook exists, which is most of them. flow_hook's return value answers the
# question one call too late.
#
# DELIBERATELY NOT MEMOISED. A hook file that appears mid-run is a project doing
# something strange, and answering from a cache would hide it.
proc flow_hook_exists {name} {
    flow_seam_assert $name flow_hook_exists
    set dir [flow_env FPGA_HOOKS_DIR]
    if {$dir eq ""} { return 0 }
    return [file exists [file join $dir ${name}.tcl]]
}

# The resolved path of a hook, or "" when there is none. Used by the guards that
# have to NAME the file they are refusing - a diagnosis that says "a hook" and
# not which one costs the reader the ten minutes the message was written to
# save.
proc flow_hook_path {name} {
    flow_seam_assert $name flow_hook_path
    set dir [flow_env FPGA_HOOKS_DIR]
    if {$dir eq ""} { return "" }
    set path [file join $dir ${name}.tcl]
    if {![file exists $path]} { return "" }
    return $path
}

proc flow_hook {name} {
    flow_seam_assert $name flow_hook
    set dir [flow_env FPGA_HOOKS_DIR]
    if {$dir eq ""} { return 0 }
    set path [file join $dir ${name}.tcl]
    if {![file exists $path]} { return 0 }

    say "hook: $name -> $path"
    set t0 [clock seconds]
    # uplevel 1, so the hook sees the stage script's own variables and can set
    # them. A hook sourced in its own scope could read the globals and nothing
    # else, which rules out the commonest legitimate use: adjusting a value the
    # stage is about to pass to a tool command.
    if {[catch {uplevel 1 [list source $path]} msg opts]} {
        puts "$::flow(prefix)-FAIL: hook '$name' raised an error and the stage is stopping."
        puts "$::flow(prefix)-FAIL:   file:  $path"
        puts "$::flow(prefix)-FAIL:   error: $msg"
        puts "$::flow(prefix)-FAIL: Hooks are project code in the critical path, so an"
        puts "$::flow(prefix)-FAIL: error in one aborts the run deliberately. If this hook"
        puts "$::flow(prefix)-FAIL: is advisory, wrap its body in your own catch and say why."
        return -options $opts $msg
    }
    set dt [expr {[clock seconds] - $t0}]
    # ${name}, not $name: "$name(...)" would be parsed as an ARRAY ELEMENT
    # reference, not as the variable followed by a bracket.
    lappend ::flow(hooks) "${name}(${dt}s)"
    say "hook: $name done (${dt}s)"
    return 1
}


################################################################################
# 7. TUNABLE STEPS AND PROJECT OVERRIDES
#
# flow/steps/<name>.tcl holds the tunable part of a stage - synthesis strategy,
# implementation directives, bitstream properties, which reports get written. A
# project replaces one WHOLESALE by dropping a file of the same name into
# $(OVERRIDES_DIR). There is no merging and no partial override: the toolkit's
# copy is not sourced at all.
#
# That is a deliberate choice over a patch/append mechanism. These files set
# tool properties in an order that matters, and a half-overridden one is a
# design nobody can reason about. Replacing the file makes the project own the
# whole decision, and the log says so on the line it happens. Every step file
# therefore carries a header saying what an override MUST still do.
#
# THE VALID STEP LIST IS THE DIRECTORY. Never a literal - see the seam comment
# above for the defect that rule comes from.
################################################################################

# Every step name the toolkit ships, derived from the directory at run time.
proc flow_steps_available {} {
    set dir [file join [file dirname $::flow_common_dir] steps]
    set out {}
    foreach f [lsort [glob -nocomplain -directory $dir *.tcl]] {
        lappend out [file rootname [file tail $f]]
    }
    return $out
}

proc flow_step {name} {
    set dir [file join [file dirname $::flow_common_dir] steps]
    set ovr [flow_env FPGA_OVERRIDES_DIR]
    set path [file join $dir ${name}.tcl]
    set src  "toolkit"
    if {$ovr ne "" && [file exists [file join $ovr ${name}.tcl]]} {
        set path [file join $ovr ${name}.tcl]
        set src  "PROJECT OVERRIDE"
    }
    if {![file exists $path]} {
        die "no step file for '$name' at $path" \
            "  Steps this toolkit ships: [join [flow_steps_available] { }]" \
            "  If this is a project override, check that the file parses and" \
            "  that its name matches one of those exactly."
    }
    say "step file: $name ($src) -> $path"
    lappend ::flow(steps) "$name=$src"
    if {$src eq "PROJECT OVERRIDE"} {
        warn "step '$name' is OVERRIDDEN by the project. The toolkit's own"
        warn "  flow/steps/${name}.tcl is NOT sourced. Read its header for what"
        warn "  an override must still do."
    }
    uplevel 1 [list source $path]
}


################################################################################
# 8. THE PART/BOARD ACCESSOR SHIM
#
# CONTRACT.md section 1 splits the reference toolkit's single `tech` concept in
# two, and section 8 requires the engine to reach BOTH through one shim owning
# one alias table:
#
#   a PART PACK  is a fact about a device  (LUTs, whether an IDELAY primitive
#                exists, how many SLRs) and ships in the TOOLKIT.
#   a BOARD PACK is a fact about a circuit board (which pin, which IO standard,
#                what the oscillator runs at) and ships in the PROJECT.
#
# The engine reads every pack value through exactly four commands:
#
#     part  <key> ?default?     the value, or die if the pack lacks it
#     part_have <key>           1 if the pack has it, else 0
#     board <key> ?default?
#     board_have <key>
#
# and the pack API (part/pack_api.tcl, owned elsewhere) supplies the storage and
# the underlying part_get / part_has / board_get / board_has.
#
# WHY AN ALIAS TABLE. A pack that calls the device `part_name` and one that
# calls it `device_name` are both right; the engine should not care, and it must
# not grow forty guarded call sites the day a second pack spells one key
# differently. The table below is THE ONLY PLACE a pack's spelling appears in
# this engine. Adding a pack that spells something a third way is a table entry.
#
# WHY NOTHING IS RENAMED. The reference shim `rename`s the pack API's own
# tech_has out from under it. That works there because the engine wants the same
# NAME; here the engine's names (`part`, `board`, `part_have`, `board_have`) are
# free, so the pack API keeps every command it defined and can call itself
# without discovering that one of its own commands has moved. Renaming a
# command inside somebody else's API is a trap that only springs later.
#
# The tables start close to empty ON PURPOSE. They are seeded only from the key
# names CONTRACT.md section 8 declares; an entry is EVIDENCE that a real pack
# spelled something differently, not a guess about one that might.
################################################################################

# AN ALIAS WHOSE NAME IS ALSO A REAL SCHEMA KEY NEVER FIRES, AND IS WORSE THAN
# NO ALIAS. `device` was here, mapping to `part_name`. But the pack schema
# declares `device` as a key in its own right - the DIE (`xc7z020`) as opposed
# to the full part string (`xc7z020clg400-1`) - so the alias was dead code that
# read, to anyone scanning this table, as a promise that `part device` returns
# the full part string. It returns the die. Two names for two different things,
# one of which silently loses a package and a speed grade, is exactly the class
# of confusion an alias table is supposed to remove. Removed 2026-09-08, found
# BY READING - which is why it survived as long as it did, and why
# flow_pack_alias_check below exists.
#
# WHAT MAY STAND IN THESE TABLES, now that something checks. Every row is
# `<what a stage asks for>   <what the schema calls it>`, and four shapes are
# refused at boot, each of them a row that LOOKS like a mapping and is not:
#
#   the target is not a schema key   the alias resolves to nothing, and the
#                                    eventual failure names the key the stage
#                                    asked for rather than the row that is wrong
#   the NAME is a schema key         it can never fire - flow_pack_read probes
#                                    the raw key first and the pack answers it.
#                                    This is the `device` row above, verbatim
#   the name maps to itself          flow_pack_read skips it by construction, so
#                                    it does nothing at all
#   part/pack_api.tcl already
#   canonicalises the name           the pack API's own table answers the raw
#                                    probe, so this row is never consulted - and
#                                    if the two tables disagree, the pack API
#                                    wins and this one documents a value the
#                                    engine does not return
#
# THE FOURTH SHAPE IS WHAT EMPTIED THESE TABLES ON 2026-09-11, and it is the
# "there should not be two" half of the defect. Five of the six rows that stood
# here were already answered elsewhere: `name`, `min_vivado`, `clk_freq_hz` and
# board `name` are all in part/pack_api.tcl's own alias table, mapping to the
# same targets; `platform -> platform` was a self-map whose name is a board
# schema key in its own right. Deleting all five changed NOTHING a stage can
# observe - every one of those six spellings still resolves, four through the
# pack API and two because they were always schema keys - which is the
# demonstration that they were duplicates rather than the load-bearing rows they
# read as.
#
# The alternative fix was to delete this table outright and move its rows into
# part/pack_api.tcl. It was not taken, for two reasons. CONTRACT.md section 8
# requires the engine to reach both packs "through one shim that owns an alias
# table", so deleting it is a contract change; and part/pack_schema.tcl section
# 1e states that the pack-facing table canonicalises WHAT A PACK WRITES while
# this one canonicalises WHAT A STAGE ASKS FOR. Moving `buffer` across would
# make `part_set buffer BUFG` a legal thing for a pack to write, widening the
# pack-facing surface for the engine's convenience. Enforcing that no SPELLING
# appears in both tables gets the same guarantee without either cost.
#
# `buffer -> global_buffer` is the one row that earns its place: nothing else in
# this toolkit resolves it, so deleting it would break `part buffer` today.
array set ::part_alias {
    buffer      global_buffer
}

# EMPTY, AND THAT IS A FINDING RATHER THAN AN OMISSION - see above. It is still
# declared, because flow_pack_read reads it through `info exists tbl($key)`,
# which answers "no entry" just as happily for an array that does not exist:
# deleting the line would turn every future board alias off in silence, so
# flow_pack_alias_check refuses an absent table rather than an empty one.
array set ::board_alias {}


# Validate one domain's alias table against the pack schema: the four shapes of
# dead row documented above, plus the two ways this check's own inputs can be
# missing, which it refuses rather than passes.
#
# WHY IT RUNS FROM flow_pack_shim AND NOT AT SOURCE TIME. This file is sourced
# BEFORE the pack API - flow_boot sources part/pack_api.tcl, in section 9 below
# - so at the moment these tables are defined there is no schema to check them
# against. part/pack_api.tcl validates its OWN alias table at source time
# precisely because it owns the schema by then; this one cannot, and that
# asymmetry is the whole reason the second table went unchecked for as long as
# it did. The shim is the first point in the boot path where the table and the
# schema both exist, and the last point before a stage can read a pack value,
# which makes it the only place the check is both possible and early. A check
# that ran later - on first use, say - would validate only the rows something
# happened to ask for, and a dead row is dead exactly because nothing asks.
#
# IT READS THE SCHEMA THROUGH ${domain}_keys, the accessor CONTRACT.md section 8
# publishes, rather than through ::pack_schema. part/pack_schema.tcl's own
# header says that a consumer reaching past the accessors into the tables is the
# coupling the accessors exist to prevent, and a validator is not exempt from
# that.
#
# IT REPORTS EVERY PROBLEM AT ONCE, each with what to do about it. A validator
# that stops at the first costs an edit-and-rerun cycle per row, and the cycles
# are where people stop reading the message and start guessing - the same rule
# pack_validate follows for missing keys, for the same reason.
proc flow_pack_alias_check {domain} {
    upvar #0 ${domain}_alias tbl

    # THE TABLE ITSELF CAN GO MISSING AND NOTHING DOWNSTREAM WOULD SAY SO.
    # flow_pack_read asks `info exists tbl($key)`, which is 0 both for "no such
    # entry" and for "no such array", so deleting the declaration switches every
    # alias in that domain off without a word. Check the array, not only its
    # contents.
    if {![array exists tbl]} {
        die "there is no ::${domain}_alias array." \
            "  flow_pack_read reads every $domain spelling through it and asks" \
            "  'info exists', which answers 'no entry' for an array that is not" \
            "  there - so every $domain alias would be off and the only symptom" \
            "  would be a stage dying on a key the pack does declare." \
            "  Declare it in flow/common/flow_utils.tcl section 8. An EMPTY" \
            "  table is legitimate and is spelled: array set ::${domain}_alias {}"
    }

    # The schema this table has to agree with. An empty listing is NOT a clean
    # table - it is a check with nothing to check against, and reporting a pass
    # from it would be the gate inventing a verdict from missing data.
    set keys [${domain}_keys]
    if {![llength $keys]} {
        die "the $domain pack API listed no schema keys at all." \
            "  ${domain}_keys is what ::${domain}_alias is validated against, so" \
            "  an empty listing means the table was NOT checked - and a check" \
            "  that measured nothing must not come out green." \
            "  Either part/pack_schema.tcl did not parse into the $domain" \
            "  schema, or ${domain}_keys is not part/pack_api.tcl's own." \
            "  scripts/fpga-flow-part-probe --role $domain says which."
    }

    # part/pack_api.tcl's canonicaliser, which is the only way to ask whether
    # the OTHER table already answers a spelling. Guarded rather than assumed:
    # pack_key is not one of the accessors CONTRACT.md section 8 publishes, so a
    # different pack API may not offer it - and in that case this check SAYS it
    # did not run rather than passing three checks and implying four.
    set can_ask_api [flow_have pack_key]
    if {!$can_ask_api} {
        warn "this pack API offers no 'pack_key', so ::${domain}_alias was NOT"
        warn "  checked for spellings the pack API's own table already resolves."
        warn "  The other three checks in flow_pack_alias_check did run."
    }

    set problems {}
    foreach name [lsort [array names tbl]] {
        set to $tbl($name)

        # (1) A SELF-MAP IS A NO-OP WEARING THE COSTUME OF A MAPPING.
        # flow_pack_read skips a row whose target equals its name - deliberately,
        # so a pack API that raises on an unknown key is not asked the same
        # question twice - so the row does nothing whatsoever, while reading as
        # though the engine's spelling were being translated.
        if {$to eq $name} {
            lappend problems \
                "  $name -> $to : AN ALIAS FROM A NAME TO ITSELF." \
                "      flow_pack_read skips a row whose target is its own name," \
                "      so this one does nothing at all." \
                "      If '$name' is already a $domain schema key, delete the" \
                "      row - the key resolves without it. If it is not, the row" \
                "      has lost its real target and needs it back."
            continue
        }

        # (2) THE 2026-09-08 DEFECT, AND THE ONE THIS PROC WAS WRITTEN FOR. A
        # row whose NAME is a schema key in its own right CAN NEVER FIRE:
        # flow_pack_read probes the raw key first, the pack answers it, and the
        # alias is never reached. Nothing about the row looks wrong - it is
        # invisible - and it reads as a promise about what `<domain> <name>`
        # returns. `device -> part_name` stood here claiming `part device` gave
        # the full part string; it gave the die, one package and one speed grade
        # short, and every reader of this table was told otherwise.
        if {[lsearch -exact $keys $name] >= 0} {
            lappend problems \
                "  $name -> $to : '$name' IS A $domain SCHEMA KEY." \
                "      The row can NEVER FIRE. flow_pack_read probes the raw" \
                "      key first and the pack answers it, so '$domain $name'" \
                "      returns $name's own value, never '$to'." \
                "      Delete the row. A stage that wants '$to' has to ask for" \
                "      '$to': the two are different facts, and a row saying" \
                "      otherwise is read as a promise the engine does not keep."
            continue
        }

        # (3) A target the schema does not declare resolves to nothing. The
        # alias probe fails exactly as the raw probe did, so the engine dies
        # naming the key the STAGE asked for - not the row that is wrong.
        if {[lsearch -exact $keys $to] < 0} {
            lappend problems \
                "  $name -> $to : '$to' is not a $domain schema key." \
                "      Nothing declares it, so the row resolves to nothing and" \
                "      the failure it eventually causes names '$name' rather" \
                "      than this row." \
                "      Fix the target's spelling, or add the key to" \
                "      part/pack_schema.tcl if it is a fact a pack should state."
            continue
        }

        # (4) THE SECOND TABLE. part/pack_api.tcl owns a pack-facing alias table
        # and canonicalises through it INSIDE ${domain}_has, which
        # flow_pack_read calls on the raw key before it ever consults this one.
        # So a spelling that table resolves is answered there and this row is
        # inert; and where the two disagree, the pack API wins while this table
        # documents a target the engine never returns.
        if {$can_ask_api} {
            set canon [pack_key $domain $name]
            if {$canon eq $to} {
                lappend problems \
                    "  $name -> $to : part/pack_api.tcl ALREADY resolves '$name'." \
                    "      Its own table maps it to the same '$to', and" \
                    "      flow_pack_read probes the raw key first, so this row" \
                    "      is never consulted." \
                    "      Delete it here. A spelling standing in both tables is" \
                    "      the 'there should not be two' hazard: two places to" \
                    "      read, one of which is doing nothing."
            } elseif {$canon ne $name} {
                lappend problems \
                    "  $name -> $to : part/pack_api.tcl resolves '$name' to '$canon'," \
                    "      AND IT WINS. flow_pack_read probes the raw key first" \
                    "      and the pack API canonicalises it there, so the" \
                    "      engine returns '$canon' while this row says '$to'." \
                    "      Delete whichever of the two rows is wrong. They" \
                    "      answer the same question and only one is ever used."
            }
        }
    }

    if {[llength $problems]} {
        die "::${domain}_alias does not agree with the $domain pack schema." \
            {*}$problems \
            "  This table is the ONLY place in the engine where a pack's" \
            "  spelling appears (flow/common/flow_utils.tcl section 8), which is" \
            "  why a row that cannot fire is invisible rather than wrong-looking," \
            "  and why it is checked here rather than read." \
            "  Checked against the [llength $keys] keys ${domain}_keys lists."
    }

    # SAID BY THE CHECK ITSELF, not by its caller. A confirmation printed
    # alongside the call site survives the call site being deleted, and a log
    # line claiming a check that no longer runs is the defect class this whole
    # file is written against - it is how the `device` row stayed invisible.
    # Delete the call and this line goes with it.
    say "::${domain}_alias: [array size tbl] row(s) checked against the\
         [llength $keys] keys ${domain}_keys lists"
}

# Build `part`/`part_have` over part_get/part_has, and the same for board. One
# body, two domains, so the two can never drift apart - and the same loop
# validates that domain's alias table, because this proc is the one moment in
# the boot path where the table and the schema it has to agree with both exist
# (see flow_pack_alias_check's header for why that is not source time).
proc flow_pack_shim {} {
    foreach domain {part board} {
        if {![flow_have ${domain}_get]} {
            die "the pack API defines no '${domain}_get'." \
                "  The engine reads every $domain value through it. See" \
                "  CONTRACT.md section 8, 'Accessors'."
        }
        if {![flow_have ${domain}_has]} {
            die "the pack API defines no '${domain}_has'." \
                "  Without it the engine cannot tell a value the pack chose not" \
                "  to declare from one it declared as empty, and every" \
                "  conditional feature would have to guess."
        }
        if {![flow_have ${domain}_keys]} {
            die "the pack API defines no '${domain}_keys'." \
                "  CONTRACT.md section 8 lists it among the engine-facing" \
                "  accessors, and it is the schema listing ::${domain}_alias is" \
                "  validated against. Without it the table would be bound" \
                "  UNCHECKED, and an alias that can never fire is invisible" \
                "  rather than wrong-looking - which is the whole reason the" \
                "  check exists."
        }
        flow_pack_alias_check $domain
    }
    say "pack accessors bound: part/part_have over part_get, board/board_have over board_get"
}

# Does <domain> have <key>, directly or under its alias?
#
# A pack API may treat an unknown key as an ERROR rather than as "no". Both are
# defensible - one catches typos in a pack, the other lets a consumer probe -
# and the engine needs the probing form, so the native call is wrapped ONCE
# here rather than guarded at forty call sites.
proc flow_pack_read {domain key mode args} {
    set names [list $key]
    upvar #0 ${domain}_alias tbl
    if {[info exists tbl($key)] && $tbl($key) ne $key} { lappend names $tbl($key) }

    foreach n $names {
        set present 0
        if {[catch {set present [${domain}_has $n]}]} { set present 0 }
        if {$present} {
            if {$mode eq "have"} { return 1 }
            return [${domain}_get $n]
        }
    }
    if {$mode eq "have"} { return 0 }
    if {[llength $args]} { return [lindex $args 0] }

    set known "(the pack API offers no key listing)"
    catch { set known [join [lsort [${domain}_keys]] " "] }
    die "the $domain pack does not declare '$key'." \
        "  The engine needs it here. Either the pack is incomplete, or this" \
        "  spelling needs an entry in ::${domain}_alias in" \
        "  flow/common/flow_utils.tcl - which is the only place in the engine" \
        "  where a pack's spelling appears." \
        "  Declared keys: $known"
}

proc part       {key args} { return [flow_pack_read part  $key get {*}$args] }
proc board      {key args} { return [flow_pack_read board $key get {*}$args] }
proc part_have  {key}      { return [flow_pack_read part  $key have] }
proc board_have {key}      { return [flow_pack_read board $key have] }


################################################################################
# 9. BOOT
#
# Turns the exported FPGA_* environment into the globals every stage relies on,
# loads the part pack and the board pack, and creates this run's four output
# directories - and only those four (CONTRACT.md section 5).
#
# Everything it does is cheap and file-local: NO VIVADO COMMAND RUNS, so a
# mis-configured project fails in milliseconds rather than after twenty minutes
# of elaboration. That is the fail-early rule and this proc is where it lives.
#
# Globals it publishes, which stage scripts and project Tcl may rely on:
#
#   FLOW_DIR FPGA_DIR PART_DIR BOARD_DIR       locations
#   block_name RUN_TAG IN_RUN_TAG board_name part_name   identity
#   WORK_DIR LOG_DIR REPORT_DIR OUT_DIR        this run's output tree
#   IN_WORK_DIR SYNTH_OUT_DIR                  where this stage READS from
#   FLOW_MODE PLATFORM                         how to drive the tool
#   FLOW_T0                                    epoch seconds, for runtime_s
################################################################################

proc flow_boot {} {
    global FLOW_DIR FPGA_DIR PART_DIR BOARD_DIR
    global block_name RUN_TAG IN_RUN_TAG board_name part_name
    global WORK_DIR LOG_DIR REPORT_DIR OUT_DIR IN_WORK_DIR SYNTH_OUT_DIR
    global FLOW_MODE PLATFORM FLOW_T0

    set FLOW_DIR [flow_need_env FPGA_FLOW_DIR \
        "It is the root of this toolkit's checkout and locates the whole engine\
         - flow/, part/, scripts/. The PROJECT sets FPGA_FLOW_DIR."]
    set FPGA_DIR [flow_need_env FPGA_DIR \
        "It is the project's fpga/ directory - the one holding design.mk."]

    # A SPLIT INSTALL IS A REAL FAILURE AND IT IS SILENT. If FPGA_FLOW_DIR names
    # one checkout while this file was sourced out of another, half the engine
    # comes from each and the manifest's toolkit sha describes only one of them.
    # The reference project has hit the two-checkouts trap repeatedly with
    # submodules; it costs nothing to refuse it here.
    set here [file dirname $::flow_common_dir]
    set claimed [file join [file normalize $FLOW_DIR] flow]
    if {[file normalize $here] ne $claimed} {
        die "FPGA_FLOW_DIR does not contain the flow_utils.tcl that is running." \
            "  running from: $here" \
            "  FPGA_FLOW_DIR: $claimed" \
            "  Half this engine would come from each checkout and the manifest" \
            "  would name only one of them. Fix FPGA_FLOW_DIR, or run the stage" \
            "  from the checkout it names."
    }

    set block_name [flow_need_env FPGA_BLOCK \
        "It is the design's short name and the stem of every artefact this run\
         writes. design.mk sets BLOCK."]
    set RUN_TAG    [flow_env FPGA_RUN_TAG default]
    set IN_RUN_TAG [flow_env FPGA_IN_RUN_TAG $RUN_TAG]

    # A run tag containing a path separator would let a stage address ANOTHER
    # RUN's work directory. CONTRACT.md section 5 requires that to be impossible
    # by construction rather than by convention, and this is the construction:
    # every run path below is composed from a tag that cannot escape.
    foreach {tagname tagval} [list FPGA_RUN_TAG $RUN_TAG FPGA_IN_RUN_TAG $IN_RUN_TAG] {
        if {[string match "*/*" $tagval] || $tagval eq "." || $tagval eq ".."} {
            flow_refuse "$tagname is '$tagval'." \
                "  A run tag may not contain '/' and may not be '.' or '..'." \
                "  Either would let this stage read or overwrite another run's" \
                "  work directory, and the handoff contract is that a stage" \
                "  touches exactly one."
        }
    }

    set run_dir [flow_need_env FPGA_RUN_DIR \
        "It is this run's output tree, \$(BUILD_DIR)/\$(RUN_TAG). design.mk sets\
         BUILD_DIR; RUN_TAG is a per-invocation variable."]

    set WORK_DIR   [flow_env FPGA_WORK_DIR   [file join $run_dir work]]
    set LOG_DIR    [flow_env FPGA_LOG_DIR    [file join $run_dir logs]]
    set REPORT_DIR [flow_env FPGA_REPORT_DIR [file join $run_dir reports]]
    set OUT_DIR    [flow_env FPGA_OUT_DIR    [file join $run_dir outputs]]
    # Where a resumed or downstream stage reads its input database from.
    # Defaults to this run's own work directory, i.e. "continue what I started".
    set IN_WORK_DIR    [flow_env FPGA_IN_WORK_DIR   $WORK_DIR]
    set SYNTH_OUT_DIR  [flow_env FPGA_SYNTH_OUT_DIR $OUT_DIR]

    set FLOW_MODE [flow_env FPGA_FLOW_MODE project]
    set PLATFORM  [flow_env FPGA_PLATFORM  bare]

    # Runtime is measured from stage LAUNCH when make tells us when that was,
    # and from boot otherwise. The manifest records which, because the second
    # under-reports by however long the tool took to start - which on a licence
    # server can be minutes.
    set FLOW_T0 [flow_env FPGA_STAGE_T0 ""]
    if {![string is integer -strict $FLOW_T0]} { set FLOW_T0 [clock seconds] }

    # EXACTLY FOUR DIRECTORIES. Anything else in a run directory is the
    # project's, not ours.
    foreach d [list $WORK_DIR $LOG_DIR $REPORT_DIR $OUT_DIR] {
        if {[catch {file mkdir $d} e]} { die "cannot create $d: $e" }
    }

    source [file join $::flow_common_dir provenance.tcl]

    # --- the packs ------------------------------------------------------------
    set PART_DIR [flow_need_env FPGA_PART_DIR \
        "It is the part pack directory, \$(FPGA_FLOW_DIR)/part/\$(PART). It\
         holds facts about the DEVICE and ships with this toolkit."]
    set BOARD_DIR [flow_need_env FPGA_BOARD_DIR \
        "It is the board pack directory, normally \$(FPGA_DIR)/board/\$(BOARD).\
         It holds facts about the CIRCUIT BOARD and ships with the PROJECT."]

    set api [file join $FLOW_DIR part pack_api.tcl]
    if {![file exists $api]} {
        die "no pack API at $api" \
            "  part/pack_api.tcl defines the contract every part pack and every" \
            "  board pack implements, and is what loads one. This checkout of" \
            "  the toolkit is incomplete."
    }
    source $api
    foreach c {part_load board_load} {
        if {![flow_have $c]} {
            die "$api does not define '$c'." \
                "  The engine loads a pack through it. See CONTRACT.md section" \
                "  8, 'Accessors'."
        }
    }
    part_load  $PART_DIR
    board_load $BOARD_DIR
    flow_pack_shim

    set part_name  [part  part_name]
    set board_name [board board_name]
    say "part pack:  $part_name from $PART_DIR"
    say "board pack: $board_name from $BOARD_DIR"

    # THE BOARD PACK NAMES THE PART, AND A PROJECT OVERRIDE WINS (section 3.2).
    # A legitimate override and a stale one look identical, so the divergence is
    # announced every run rather than discovered from a bitstream that will not
    # load. This is a warn, not a die: overriding is allowed.
    set env_part [flow_env FPGA_PART]
    set pack_part [board part "UNVERIFIED:board-pack-declares-no-part"]
    if {$env_part ne "" && $env_part ne $pack_part} {
        warn "PART OVERRIDE IS ACTIVE: the board pack names '$pack_part', the"
        warn "  project set PART='$env_part'. The project wins. A bitstream"
        warn "  built for the wrong device does not load and says almost"
        warn "  nothing about why."
    }

    say "block=$block_name run_tag=$RUN_TAG in_run_tag=$IN_RUN_TAG mode=$FLOW_MODE"
    say "work=$WORK_DIR  in_work=$IN_WORK_DIR"
    say "reports=$REPORT_DIR  outputs=$OUT_DIR  logs=$LOG_DIR"
    return
}


# The banner every stage prints once it knows what it is doing. Kept here so the
# stages cannot drift into one format each.
proc flow_banner {stage} {
    global block_name RUN_TAG board_name part_name
    say "=============================================================="
    say " design   : $block_name"
    say " stage    : $stage"
    say " run tag  : $RUN_TAG"
    say " board    : [expr {[info exists board_name] ? $board_name : {(not loaded)}}]"
    say " part     : [expr {[info exists part_name]  ? $part_name  : {(not loaded)}}]"
    say " tool     : [flow_env FPGA_TOOL_HINT unknown]"
    say "=============================================================="
}

# Copyright (C) 2026, SoC Labs (www.soclabs.org)
