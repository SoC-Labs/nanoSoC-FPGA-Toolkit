################################################################################
# provenance.tcl - WHAT DESIGN DID THIS STAGE MEASURE, AND WHAT DID IT NOT?
#
# Sourced by flow_boot (flow/common/flow_utils.tcl, section 9) immediately after
# this run's four directories exist and BEFORE the packs are loaded. It defines
# procs and nothing else runs at source time: flow_boot is not finished when this
# file loads, so a collector that touched `part` or `board` here would read a
# pack that has not been loaded yet.
#
# WHY THIS FILE EXISTS
#
# Three wrong conclusions were drawn in one week on the reference project by
# comparing two stage reports that described DIFFERENT DESIGNS, and noticing
# nothing. Every one of them was cheap to prevent and expensive to unpick: a
# netlist that had silently lost all 34 supply pads scored BETTER than one that
# had them (the gate was an upper bound on unrouted nets, and fewer pads means
# fewer nets); a build against stale boot ROMs was compared against one built
# from rebuilt ones and the difference read as a placement effect; a floorplan
# with one macro moved 20 nm was compared against one without and the four new
# rail shorts attributed to a routing knob.
#
# In each case the two reports were internally consistent. Nothing in either file
# said which DESIGN it was about, so nothing could refuse the comparison.
#
# The FPGA flow has the same hole in a cheaper-to-hit form. Two bitstreams built
# an hour apart from the same working tree differ if the flist regenerated, if a
# submodule moved, if the board pack changed a clock, or if somebody set a knob
# on the command line - and a `.bit` carries none of that. `compare-runs`
# refuses a pair whose provenance blocks disagree; this file is what it reads.
#
#
# THE THREE RULES THIS FILE IMPLEMENTS
#
# 1. EVERY FIELD IS A VALUE OR AN `UNVERIFIED:<reason>` STRING. There is no third
#    state and no silent omission. A field this file could not measure says so,
#    in the manifest, with the reason; a field that is simply absent from a
#    manifest and a field that could not be measured must not look the same to a
#    reader or to `compare-runs`.
#
# 2. A NUMBER THAT WAS NOT MEASURED IS THE LITERAL TOKEN `unmeasured`, NEVER `0`.
#    `0` is a legitimate measurement - zero unrouted nets, zero critical warnings
#    - and a flow that writes `0` for "did not look" makes its best result and
#    its blindest one identical. CONTRACT.md rule 2.
#
# 3. ANY SITE PATH IS RECORDED AS A `sha256:` DIGEST, NEVER AS THE RAW PATH.
#    A manifest gets pasted into bug reports, issue trackers and vendor support
#    tickets, and a vendor mount point plus a revision-coded release directory is
#    inventory-shaped disclosure: it says which IP this site licences and which
#    release of it. The DIGEST answers the only question provenance ever asks of
#    such a path - "is this the same one?" - and discloses nothing.
#
#    A path INSIDE the project, the toolkit or this run is not a site path: it is
#    relative information the reader needs and the repository already publishes.
#    Those are rewritten to a `<project>/...`, `<toolkit>/...` or `<run>/...`
#    label - which as a bonus makes two runs under different build roots compare
#    equal instead of differing in every path field. prov_site_path is the ONE
#    place that decision is made; nothing else in the flow may write a path into
#    a manifest.
#
#    Variable NAMES are recorded in clear. A name is not a purchase order.
#
#
# THE MANIFEST BLOCK ORDER IS FIXED BY CONTRACT.md SECTION 5 and is implemented
# in exactly one place, prov_manifest, in this order:
#
#   1 header        date runtime_s stage run_tag host user tool tool_version
#                   log_file
#   2 provenance    prov.design.git_*, one path/sha256/bytes triple per input
#                   file, prov.part.*, prov.board.*
#   3 directories   work_dir in_work_dir log_dir report_dir out_dir part board
#   4 both git shas project_git_sha/_dirty and toolkit_git_sha/_dirty
#   5 step_files    synth_setup=toolkit impl_setup=PROJECT OVERRIDE ...
#   6 hooks_run     pre_synth(2s) ...   or (none)
#   7 knobs         EVERY registered knob and its resolved value
#
# ...and then ONE MORE, written by the stage rather than by prov_manifest:
#
#   8 measurements  what THIS stage measured - file_count, vlnv, lut/ff/bram,
#                   wns/whs/unrouted_nets, bin_style/bit_bytes ...
#
# BLOCK 8 IS NOT PART OF THE PROVENANCE BLOCK, and the distinction is the reason
# it has its own accumulator instead of going through prov_set. ci/assert-stage.
# sh reads those keys with `awk '$1 == key'`, so each has to be a TOP-LEVEL key;
# prov_set would prefix them `prov.`, which is the namespace `compare-runs`
# treats as design IDENTITY. A utilisation figure is a RESULT of building a
# design, not a statement of WHICH design it is - two runs that differ in LUT
# count are not two different designs, and a comparison that refused them would
# refuse every A/B experiment anyone would want to run. So a stage records its
# numbers with prov_stage_field and prov_stage_fields appends them AFTER
# prov_manifest has closed the file.
#
# THE VERDICT ARTEFACT, $REPORT_DIR/<stem>_gate.txt, is prov_gate. Section 5
# fixes its four classes and section 12.3 makes `HARD FAILURES: none` load-
# bearing punctuation.
#
# Both of those procs were written SIX TIMES before they were written here -
# once in each stage script, by two sessions working in parallel that each hit
# the same hole independently and each invented the same workaround. That is the
# toolkit's own founding complaint (75 copies of bit2bin.py, 179 of
# build_design.tcl) reproduced inside the toolkit in an afternoon. If you are
# about to write a seventh copy: don't. Extend these.
#
# Block 7 IS ENUMERATED, NEVER WRITTEN DOWN. `opt` registers a knob by the act of
# reading it (flow_utils.tcl section 3), so ::flow(knobs) is the resolved set and
# flow_knob_scan is the declared set, and this file emits both - the resolved
# value where the stage read one, and `UNVERIFIED:declared-in-<file>-not-sourced`
# where a step file declaring the knob was never sourced by this stage. The
# reference toolkit's hand-maintained list had already silently dropped three
# effort knobs, every one of which changes QoR, so two runs that differed in
# placement effort produced manifests that agreed.
#
# LOADS IN BARE tclsh. Nothing here calls a Vivado command unguarded; the phase-1
# harness runs every stage script under tclsh, and a collector that assumed a
# tool would take the whole test suite with it.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
################################################################################

if {[info exists ::fpga_provenance_loaded]} { return }
set ::fpga_provenance_loaded 1

if {![info exists ::flow_utils_loaded]} {
    error "provenance.tcl: source flow/common/flow_utils.tcl first - this file\
           builds on say/warn/die/flow_env/mf and on ::flow(knobs)."
}

# `proc` silently REPLACES an existing command of the same name, and this file is
# sourced into every Vivado stage. Assert the names are free rather than discover
# a shadowed built-in an hour into an implementation run - the equivalent guard
# in flow_utils.tcl has already fired in anger on the reference toolkit.
foreach __c {
    prov_reset prov_set prov_get prov_has prov_unverified prov_unmeasured
    prov_sha256 prov_sha256_string prov_resolve prov_site_path prov_pin
    prov_file prov_git prov_collect_common prov_collect_packs prov_collect_all
    prov_emit prov_write prov_knobs prov_manifest prov_tool prov_value
    prov_path_value prov_knob_value prov_stage_reset prov_stage_field
    prov_stage_get prov_stage_measured prov_stage_fields prov_gate
} {
    if {[llength [info commands $__c]]} {
        error "provenance.tcl: '$__c' is already a command in this tool - it\
               would be shadowed. Rename the helper and its callers."
    }
}
unset __c

# The schema version. BUMP IT when a field is renamed or its meaning changes:
# `compare-runs` refuses to compare two manifests written under different schema
# versions, which is the correct answer - a field that has changed meaning
# compares equal for the wrong reason, and that is indistinguishable from
# agreement.
set ::PROV_SCHEMA 1

# key -> value, plus the declaration order, so a manifest is diffable line by
# line rather than at the mercy of Tcl's array hashing.
array set ::prov       {}
set       ::prov_order {}

# key -> {resolved-path sha256 bytes epoch label}, recorded AT THE MOMENT the
# stage read the file rather than at stage end. See prov_pin.
array set ::prov_pinned {}

# key -> list of {label epoch sha256 bytes} for every LATER observation that
# disagreed with the pin. Non-empty means the file changed while the run using
# it was still running.
array set ::prov_mutated {}

proc prov_reset {} {
    array unset ::prov
    array set   ::prov {}
    set ::prov_order {}
    array unset ::prov_pinned
    array set   ::prov_pinned {}
    array unset ::prov_mutated
    array set   ::prov_mutated {}
    prov_stage_reset
}

proc prov_set {key value} {
    if {![info exists ::prov($key)]} { lappend ::prov_order $key }
    set ::prov($key) $value
}

proc prov_get {key} {
    if {[info exists ::prov($key)]} { return $::prov($key) }
    return "UNVERIFIED:not-collected"
}

proc prov_has {key} { return [info exists ::prov($key)] }

# The ONE spelling of "I could not measure this". Every reader keys on the
# prefix, so it must not be written by hand anywhere else in the flow.
proc prov_unverified {key why} { prov_set $key "UNVERIFIED:$why" }

# The ONE spelling of "this is a COUNT that nobody took". Deliberately NOT
# UNVERIFIED: an unverified field is a failed measurement, this is an absent one,
# and CONTRACT.md rule 2 fixes the token because `0` is a legitimate count and
# would make "clean" and "never looked" identical.
proc prov_unmeasured {key} { prov_set $key "unmeasured" }

# Render any value for a manifest. NEVER BLANK: an empty field reads as a field
# the writer forgot, and `(none)` is the token CONTRACT.md section 11 already
# fixes for "explicitly nothing".
proc prov_value {v} {
    if {[string trim $v] eq ""} { return "(none)" }
    return $v
}


################################################################################
# 1. PATHS, DIGESTS AND THE SITE-PATH RULE
################################################################################

# Resolve a path THROUGH SYMLINKS, including the final component.
#
# `file normalize` alone is not enough, and this is measured rather than assumed:
#
#     ln -s real/f.v g.v
#     file normalize g.v        ->  <pwd>/g.v          the LINK itself
#     file normalize link/f.v   ->  <pwd>/real/f.v     an INTERMEDIATE link is
#                                                      resolved
#
# So a flow that normalises and stops will report two different names for one
# file, or one name for two different files - which is the entire failure this
# manifest exists to stop. `file link` is followed explicitly, with a hop limit
# so a symlink cycle reports rather than hangs.
proc prov_resolve {path} {
    if {$path eq ""} { return "" }
    set p [file normalize $path]
    for {set hops 0} {$hops < 32} {incr hops} {
        if {[catch {file type $p} t]} { return $p }
        if {$t ne "link"} { return $p }
        if {[catch {file link $p} target]} { return $p }
        if {[file pathtype $target] eq "relative"} {
            set target [file join [file dirname $p] $target]
        }
        set p [file normalize $target]
    }
    return "UNVERIFIED:symlink-cycle-at-[file tail $path]"
}

# sha256 of a FILE's contents.
#
# NOT `package require sha256`. tcllib is absent from the Tcl shipped inside the
# EDA tools on this host (measured on the reference toolkit: `can't find package
# sha256`), and a `catch` around a missing package that then returned "" would
# put an empty string in the manifest where a hash belongs - and two empty
# strings compare EQUAL, which turns a missing measurement into agreement. So the
# external tool is used and its absence is reported, never defaulted.
proc prov_sha256 {path} {
    if {$path eq ""}                         { return "UNVERIFIED:no-path" }
    if {[string match "UNVERIFIED:*" $path]} { return $path }
    if {![file exists $path]}                { return "UNVERIFIED:missing-file" }
    if {[file isdirectory $path]}            { return "UNVERIFIED:is-a-directory" }
    if {![file size $path]}                  { return "UNVERIFIED:zero-bytes" }
    if {[catch {exec sha256sum -- $path} out]} { return "UNVERIFIED:sha256sum-failed" }
    set h [lindex [split [string trim $out]] 0]
    if {![regexp {^[0-9a-f]{64}$} $h]} { return "UNVERIFIED:unparseable-digest" }
    return $h
}

# sha256 of a STRING, for the site-path rule. The string is fed to sha256sum with
# NO trailing newline, so `sha256sum` on the command line and this proc agree
# only via `printf %s`. That is written down because somebody will one day try to
# reproduce a digest with `echo` and get a different answer.
proc prov_sha256_string {s} {
    if {[catch {exec sha256sum << $s} out]} { return "UNVERIFIED:sha256sum-failed" }
    set h [lindex [split [string trim $out]] 0]
    if {![regexp {^[0-9a-f]{64}$} $h]} { return "UNVERIFIED:unparseable-digest" }
    return $h
}

# THE SITE-PATH RULE, IN ONE PLACE.
#
# A path that lies inside this run, this project or this toolkit is rewritten to
# a `<run>/`, `<project>/` or `<toolkit>/` label and recorded in clear: the
# reader needs it, and the repository already publishes those trees. Anything
# else is a SITE path - a vendor mount, a shared IP library, a licensed release
# directory - and is recorded as `sha256:<digest>` and never as text.
#
# Two things fall out of this that are worth having on purpose:
#
#   * two runs under different build roots, or two checkouts of the same project
#     at different paths, compare EQUAL on every path field instead of differing
#     on all of them. A comparison that refuses every pair gets switched off
#     within a day, which is worse than no comparison at all;
#   * a digest still DISCRIMINATES. If a vendor root is repointed at a different
#     release between two runs, the two manifests differ and `compare-runs`
#     refuses - which is exactly the event that has to be caught.
#
# The most specific root wins, so the run directory is tested before the project
# that contains it.
proc prov_site_path {path} {
    if {$path eq ""} { return "UNVERIFIED:no-path" }
    if {[string match "UNVERIFIED:*" $path]} { return $path }
    set p [prov_resolve $path]
    if {[string match "UNVERIFIED:*" $p]} { return $p }

    foreach {label rootvar} {
        run      FPGA_RUN_DIR
        run      FPGA_BUILD_DIR
        project  FPGA_DIR
        project  FPGA_PROJECT_ROOT
        toolkit  FPGA_FLOW_DIR
    } {
        set root [flow_env $rootvar]
        if {$root eq ""} { continue }
        set r [file normalize $root]
        if {$p eq $r} { return "<$label>" }
        # The trailing separator matters: without it "/a/bc" is inside "/a/b".
        if {[string first "${r}/" "${p}/"] == 0} {
            return "<$label>/[string range $p [expr {[string length $r] + 1}] end]"
        }
    }
    return "sha256:[prov_sha256_string $p]"
}


################################################################################
# 2. FILES: WHAT THIS STAGE READ, AND WHETHER IT STAYED THAT WAY
################################################################################

# Record what a file WAS at the moment this stage read it.
#
# WHY THIS EXISTS, with the run that proved it. On the reference project a place
# stage sourced the project's power plan at about 10:33 and logged its size on
# the way in (60,858 bytes). Another session edited that file at 11:13:27. The
# manifest was written at 11:14:27 and hashed the file THEN, so it records a
# sha256 and a byte count (64,117) for a file that did not exist while the design
# was being built. Every physical number that stage produced came out of a file
# the manifest does not name. That is not a stale record, it is a FALSE one, and
# a false record is worse than none because it reads as evidence.
#
# It is not an ASIC-only failure. `RTL_FLIST_GEN` regenerates the flist from
# inside the build, hooks are project code in the critical path, and concurrent
# sessions editing one working tree is the normal condition here - so the hash
# has to be taken at the READ.
#
# FIRST PIN WINS. A stage that reads the same file twice keeps the first
# observation as canonical and treats a later difference exactly as it treats a
# stage-end difference: recorded, never merged away.
#
# THIS PROC CANNOT FAIL A STAGE. It is called from the middle of a run that may
# be ninety minutes in, and a provenance recorder capable of killing an
# implementation gets deleted from the flow the first time it does. Everything is
# inside a catch; a recorder that could not record says so and the stage goes on.
proc prov_pin {key path {label read}} {
    if {[catch {
        set r [prov_resolve $path]
        set h [prov_sha256 $r]
        set b "UNVERIFIED:no-file"
        if {[file exists $r] && ![file isdirectory $r]} { set b [file size $r] }
        set now [clock seconds]
        if {[info exists ::prov_pinned($key)]} {
            foreach {pr ph pb pt pl} $::prov_pinned($key) break
            if {$h ne $ph} { lappend ::prov_mutated($key) [list $label $now $h $b] }
        } else {
            set ::prov_pinned($key) [list $r $h $b $now $label]
        }
        catch { say "prov: $key pinned at $label - [string range $h 0 15] ($b bytes)" }
    } __pe]} {
        catch { warn "prov_pin $key: $__pe - this file's point-of-use hash is lost" }
    }
    return
}

# One input file, three fields: where it is, what is in it, and how big it is.
#
# The size is not redundant with the hash. It is what a human reads first when
# two hashes differ and the question is truncated-or-different, and a zero-byte
# artefact - the shape a tool leaves when it opened its output and then died - is
# visible here and nowhere else.
#
# THE PATH IS INFORMATIONAL, THE HASH IS IDENTITY, and getting that the wrong way
# round makes `compare-runs` useless rather than strict: two runs of the same
# design read their checkpoints from <build>/<run tag>/outputs/, so the paths
# always differ, and an identity test on them refuses every A/B experiment anyone
# would want to run. Keys ending `.path` are the informational set and
# `compare-runs` keys on that suffix. The path is still worth recording, for two
# things a hash cannot do: when the hashes differ it says WHICH two files were
# read with every symlink followed, and it is the only field that shows a symlink
# repointed at a stale tree while the name in every log stayed the same.
#
# TWO FIELDS THAT ARE NEITHER A TIMESTAMP NOR AN UNVERIFIED:
#
#   <key>.hashed_at           `point-of-use` | `stage-end`
#   <key>.mutated_under_run   `no` | `yes` | `not-pinned`
#
# Both take a small closed set of values, the same for every run of a given
# stage. Every non-`.path` prov field is identity to `compare-runs`, so a field
# carrying a clock time - or carrying UNVERIFIED on every run - would refuse
# every pair of runs there is. The times and the disagreeing hashes go into
# fields that appear ONLY when something actually changed, where a refusal is the
# right outcome.
#
# `not-pinned` is not a euphemism for "clean". It says no stage code registered a
# read of this file, so the only hash available is this one, taken at stage end -
# possibly long after the tool consumed it. The manifest must not read as though
# the stage measured something it never opened.
proc prov_file {key path} {
    set r [prov_resolve $path]
    set h [prov_sha256 $r]
    set b "UNVERIFIED:no-file"
    if {[file exists $r] && ![file isdirectory $r]} { set b [file size $r] }

    if {![info exists ::prov_pinned($key)]} {
        prov_set $key.path   [prov_site_path $r]
        prov_set $key.sha256 $h
        if {[string match "UNVERIFIED:*" $b]} {
            prov_unverified $key.bytes "no-file"
        } else {
            prov_set $key.bytes $b
        }
        prov_set $key.hashed_at         stage-end
        prov_set $key.mutated_under_run not-pinned
        return
    }

    # THE PINNED VALUE GOES IN THE THREE ORIGINAL FIELDS. It is the file the
    # stage actually consumed, which is what the rest of the manifest is about.
    foreach {pr ph pb pt pl} $::prov_pinned($key) break
    prov_set $key.path   [prov_site_path $pr]
    prov_set $key.sha256 $ph
    if {[string match "UNVERIFIED:*" $pb]} {
        prov_unverified $key.bytes "no-file"
    } else {
        prov_set $key.bytes $pb
    }
    prov_set $key.hashed_at point-of-use

    set changed {}
    if {[info exists ::prov_mutated($key)]} {
        foreach m $::prov_mutated($key) {
            foreach {ml mt mh mb} $m break
            lappend changed "[clock format $mt -format {%H:%M:%S}]($ml)=[string range $mh 0 11]"
        }
    }
    if {$h ne $ph} {
        lappend changed "[clock format [clock seconds] -format {%H:%M:%S}](stage-end)=[string range $h 0 11]"
    }
    if {![llength $changed]} {
        prov_set $key.mutated_under_run no
        return
    }

    # LOUD, AND NON-DESTRUCTIVE. The fields above still say what the stage read.
    # These say the file on disk stopped being that file while the stage was
    # running, and when. Their mere presence refuses any comparison against a run
    # where it did not happen, which is correct: nothing measured against a
    # moving input is attributable to anything.
    prov_set $key.mutated_under_run   yes
    prov_set $key.sha256_at_stage_end $h
    prov_set $key.bytes_at_stage_end  $b
    prov_set $key.mutated_when        [join $changed " "]
    catch {
        warn "PROVENANCE: $key CHANGED WHILE THIS RUN WAS USING IT."
        warn "  read at [clock format $pt -format {%H:%M:%S}] ($pl): [string range $ph 0 15] ($pb bytes)"
        warn "  now:                    [string range $h 0 15] ($b bytes)"
        warn "  The manifest records what was READ. Do not attribute this stage's"
        warn "  numbers to the file that is on disk now - they are not from it."
    }
}


################################################################################
# 3. THE COLLECTORS
################################################################################

# {sha dirty describe} for a git working tree, or three UNVERIFIED strings.
#
# `--always --dirty --tags`: a repository with no tag still yields a sha, and a
# dirty tree SAYS SO IN THE SAME STRING rather than in a separate field a reader
# can skip. A describe that silently omits uncommitted work is a claim of
# reproducibility that is not there - and the reference project's shipping GDS is
# unreproducible for precisely that reason.
#
# `git status --porcelain` decides dirtiness rather than the describe suffix,
# because `--dirty` ignores untracked files: a build that consumed an untracked
# override file is not clean, and the suffix would say it was.
proc prov_git {dir why} {
    if {$dir eq "" || ![file isdirectory $dir]} {
        return [list "UNVERIFIED:$why" "UNVERIFIED:$why" "UNVERIFIED:$why"]
    }
    set sha "UNVERIFIED:git-rev-parse-failed"
    set des "UNVERIFIED:git-describe-failed"
    set drt "UNVERIFIED:git-status-failed"
    catch { set sha [string trim [exec git -C $dir rev-parse HEAD]] }
    catch { set des [string trim [exec git -C $dir describe --always --dirty --tags]] }
    if {![catch {exec git -C $dir status --porcelain} st]} {
        set drt [expr {[string trim $st] eq "" ? "clean" : "DIRTY"}]
    }
    return [list $sha $drt $des]
}

# What tool is running this, and which version of it.
#
# `version -short` exists in Vivado and in no bare tclsh, so the probe doubles as
# the tool test. VIVADO_VER, when the project set it, is ASSERTED here rather
# than assumed (CONTRACT.md section 3.3): a project that pinned a version and got
# a different one has built a bitstream nobody asked for, and the modulefiles on
# this host advertise three versions of which two are not on the filesystem
# (CONTRACT.md section 9.6), so the mismatch is a live hazard rather than a
# theoretical one.
proc prov_tool {} {
    set name "UNVERIFIED:no-version-command (not running inside a tool)"
    set ver  "UNVERIFIED:no-version-command"
    if {[flow_have version]} {
        set name "vivado"
        if {[catch {set ver [string trim [version -short]]}]} {
            set ver "UNVERIFIED:version-short-failed"
        }
    }
    set want [flow_env FPGA_VIVADO_VER]
    if {$want ne ""} {
        prov_set tool.version_expected $want
        if {[string match "UNVERIFIED:*" $ver]} {
            prov_unverified tool.version_matches "tool version could not be read"
        } elseif {$ver eq $want} {
            prov_set tool.version_matches yes
        } else {
            prov_set tool.version_matches "NO ($ver != $want)"
            catch {
                warn "VIVADO_VER is set to '$want' and the running tool is '$ver'."
                warn "  The project ASSERTED a version and did not get it. Every"
                warn "  QoR number below is from a tool the project did not ask"
                warn "  for, and the modulefiles on this host advertise versions"
                warn "  that are not installed - so 'the module loaded' is not"
                warn "  evidence of anything."
            }
        }
    }
    return [list $name $ver]
}

# Stage identity, the design repository, and the flist.
proc prov_collect_common {stage} {
    prov_set schema $::PROV_SCHEMA
    prov_set stage  $stage

    set root [flow_env FPGA_PROJECT_ROOT [flow_env FPGA_DIR]]
    foreach {sha drt des} [prov_git $root "no-project-root"] break
    prov_set design.git_describe $des
    prov_set design.git_sha      $sha
    prov_set design.git_dirty    $drt

    # The flist is the single input that decides what design gets built, and in
    # this codebase it is the ONLY thing that decides it: there is no `ifdef FPGA
    # and no `ifdef ASIC anywhere in the tree (zero hits across 13,524 RTL
    # files - CONTRACT.md section 9.1), so selection is by flist file-swap
    # between wrapper families with identical module names in opposite
    # directories. Two runs whose flist hashes differ are two different designs
    # even when every other field agrees.
    set flist [flow_env FPGA_RTL_FLIST]
    if {$flist eq ""} {
        foreach f {flist.path flist.sha256 flist.bytes} {
            prov_unverified $f "FPGA_RTL_FLIST-unset"
        }
    } else {
        prov_file flist $flist
    }

    # Anything else the stage declared as an input. ::PROV_FILES is {key path
    # key path ...}: the checkpoint a stage read, the XDC files, the firmware
    # hex. A stage adds provenance in one line rather than by duplicating a
    # collector, and four copies that drift is how the reference toolkit ended up
    # with two macro lists and a row-split running on 15 of 21 macros for months.
    if {[info exists ::PROV_FILES]} {
        foreach {k p} $::PROV_FILES { prov_file $k $p }
    }
}

# The two packs, by NAME and by CONTENT.
#
# A name alone does not identify a pack: two checkouts can both call themselves
# the same device and differ in every derived key in them. The hash is what
# identifies it, and `.dir` is a path and therefore informational.
#
# THE PACK FILE IS FOUND, NOT ASSUMED. If the pack API records which file it
# loaded, that is used; otherwise the conventional name is tried and, failing
# that, the field is UNVERIFIED with the reason. A hash of the wrong file is
# worse than no hash.
proc prov_collect_packs {} {
    foreach {domain envvar conventional} {
        part  FPGA_PART_DIR  part.tcl
        board FPGA_BOARD_DIR board.tcl
    } {
        set dir [flow_env $envvar]
        if {$dir eq ""} {
            prov_unverified $domain.name        "$envvar-unset"
            prov_unverified $domain.pack_sha256 "$envvar-unset"
            continue
        }
        prov_set $domain.dir.path [prov_site_path $dir]

        # THE DEFAULT-ARGUMENT FORM, NOT A `catch`. `part <key>` with no default
        # calls `die` when the pack does not declare the key, and `die` is
        # `exit 1` - which no catch can trap. The first version of this line was
        # `catch {prov_set $domain.name [$domain ${domain}_name]}`, and the
        # phase-1 manifest harness killed the stage on it: the recorder took the
        # run down while writing the record of it. A provenance collector that
        # can kill a stage gets deleted from the flow the first time it does.
        prov_set $domain.name \
            [$domain ${domain}_name "UNVERIFIED:pack-declares-no-${domain}_name"]

        # THE PACK FILE IS FOUND, NOT ASSUMED, AND THE API IS ASKED FIRST.
        # part/pack_api.tcl records the file it actually loaded in
        # ::pack_file(<role>) - a pack may compute its own location, and a
        # conventional filename guessed here would hash a file the run did not
        # read. The older ::<domain>_pack_file spelling is still accepted, and
        # the conventional name is the last resort rather than the first guess.
        set f ""
        if {[info exists ::pack_file($domain)] && $::pack_file($domain) ne ""} {
            set f $::pack_file($domain)
        } elseif {[info exists ::${domain}_pack_file]} {
            set f [set ::${domain}_pack_file]
        }
        if {$f eq "" && [info exists ::pack_file_name($domain)]} {
            set f [file join $dir $::pack_file_name($domain)]
        }
        if {$f eq ""} { set f [file join $dir $conventional] }
        if {![file exists $f]} {
            prov_unverified $domain.pack_sha256 \
                "the pack API records no pack file and there is none at [prov_site_path $f]"
            continue
        }
        prov_set $domain.pack.path   [prov_site_path $f]
        prov_set $domain.pack_sha256 [prov_sha256 [prov_resolve $f]]
    }

    # Every site variable a pack resolved, DIGESTED. `part_env NAME purpose`
    # records every resolution attempt, resolved or not (CONTRACT.md section 8),
    # and a variable that was NOT resolved is the interesting case: it is how a
    # pack silently loses an optional vendor input and the design comes out
    # missing a primitive. An older pack API that keeps no such list is reported
    # as keeping none, never as "no variables".
    foreach domain {part board} {
        # TWO SHAPES, ONE READER. part/pack_api.tcl keeps ::pack_env_log(<role>)
        # as a list of {name N purpose P value V status resolved|missing|error}
        # dicts; the older spelling was ::<domain>_env_resolved as a list of
        # {name value} pairs. Both are read here rather than at every call site,
        # and a pack API that keeps NEITHER is reported as keeping none - never
        # as "this pack resolved no site variables", which is a different claim
        # and would be a false one.
        set entries {}
        set have 0
        if {[info exists ::pack_env_log($domain)]} {
            set have 1
            foreach e $::pack_env_log($domain) {
                array unset __e ; array set __e $e
                set st "resolved"
                if {[info exists __e(status)]} { set st $__e(status) }
                lappend entries [list $__e(name) $__e(value) $st]
            }
            array unset __e
        } elseif {[info exists ::${domain}_env_resolved]} {
            set have 1
            foreach pair [set ::${domain}_env_resolved] {
                foreach {n0 v0} $pair break
                lappend entries [list $n0 $v0 resolved]
            }
        }
        if {!$have} {
            prov_unverified ${domain}_env.census \
                "the pack API does not record ${domain}_env calls"
            continue
        }
        set n 0
        foreach ent [lsort -index 0 $entries] {
            foreach {name value status} $ent break
            incr n
            if {$status ne "resolved" || $value eq "" || [string match "<unset*" $value]} {
                # THE INTERESTING CASE. A site variable a pack asked for and did
                # not get is how a pack silently loses an optional vendor input
                # and the design comes out missing a primitive. The STATUS is
                # recorded, not flattened to "unset", because `missing` (the
                # pack was allowed to continue without it) and `error` (it was
                # not) are different runs.
                prov_unverified ${domain}_env.$name "$status-in-environment"
                continue
            }
            # sha256 OF THE STRING, not of a file: the variable names a
            # directory, and hashing a directory tree is neither cheap nor
            # stable. See the site-path rule in the header.
            prov_set ${domain}_env.$name "sha256:[prov_sha256_string $value]"
        }
        prov_set ${domain}_env.census $n
    }
}

# THE ONE CALL A STAGE MAKES to fill the provenance block.
#
# EACH COLLECTOR IS CAUGHT SEPARATELY, and a collector that failed leaves an
# UNVERIFIED field naming the error rather than taking the stage with it. This is
# called at the end of a run that may be ninety minutes in; a recorder capable of
# killing an implementation is a recorder somebody deletes. It is also why
# nothing in here calls a pack accessor without a default - see prov_collect_packs.
proc prov_collect_all {stage} {
    foreach c [list [list prov_collect_common $stage] [list prov_collect_packs]] {
        if {[catch {{*}$c} e]} {
            prov_unverified collector.[lindex $c 0] "raised: $e"
            catch { warn "provenance collector [lindex $c 0] failed: $e" }
        }
    }
    return [llength $::prov_order]
}


################################################################################
# 4. EMISSION
#
# Every line goes through `mf` (flow_utils.tcl section 4). That is the whole
# reason `mf` has one definition: seven blocks written by seven `format` calls
# drift into seven column widths, and a manifest whose columns move is one no
# `diff` can read.
################################################################################

# Block 2: the provenance block, in declaration order. The `prov.` prefix is what
# `compare-runs` keys on, so it is applied HERE and never written into a key by a
# caller.
proc prov_emit {fh} {
    foreach k $::prov_order {
        mf $fh prov.$k [prov_value $::prov($k)]
    }
    return [llength $::prov_order]
}

# ...and as a file of its own, so a stage that dies before its manifest still
# leaves behind what it was working on.
proc prov_write {path} {
    set fh [open $path w]
    puts $fh "# provenance - what design this stage measured. schema $::PROV_SCHEMA"
    puts $fh "# UNVERIFIED:<reason> means the field could not be measured. It is"
    puts $fh "# NOT a value: any comparison involving one must be refused."
    puts $fh "# 'unmeasured' means a COUNT nobody took. It is not 0."
    prov_emit $fh
    close $fh
    return $path
}

# Block 7: every knob, resolved and declared.
#
# TWO SETS, AND THE DIFFERENCE BETWEEN THEM IS THE POINT.
#
#   ::flow(knobs)     what this stage actually READ, in declaration order. `opt`
#                     registers a knob by the act of reading it, so this set
#                     cannot drift from the code.
#   flow_knob_scan    what the step files DECLARE, found by reading the files
#                     without executing them.
#
# A knob in the second set and not the first was declared by a step file this
# stage never sourced - impl_setup's directives during a synthesis run, say. It
# is emitted as UNVERIFIED naming the file, NOT omitted and NOT given its
# default: a manifest that printed the default would claim this run used a value
# it never read, and a manifest that omitted it would let a reader diff two
# stages and conclude they agreed about a knob neither of them saw.
#
# The override directory is scanned too, and LAST, so an overridden step's knobs
# are reported from the file that would actually be sourced.

## prov_path_value <value>
## A value that LOOKS like a path is put through the site-path rule; one that
## does not is passed through unchanged. THE ONE RULE, APPLIED TO ANY VALUE a
## caller hands the manifest - block 7's knobs and block 8's measurements both
## go through here, because both hold paths by design and the file header's rule
## ("prov_site_path is the ONE place that decision is made; nothing else in the
## flow may write a path into a manifest") does not have a knobs-only clause.
##
## Deliberately conservative about what "looks like a path" means: a token
## starting with / or ~, or containing a / with no whitespace around it. A value
## holding a LIST of paths is handled token by token, because FLIST_INCDIRS and
## the bd stage's overlay_order are exactly that and digesting the whole list as
## one string would destroy a value a reader legitimately needs. An effort level,
## a directive name or a number is untouched - digesting those would make the
## manifest unreadable for no gain.
##
## IDEMPOTENT, AND THAT IS LOAD-BEARING RATHER THAN TIDY. `<run>/work/sources.tcl`
## and `sha256:<digest>` are what prov_site_path RETURNS, and a stage that called
## it at the point of measurement - which three of the six do, for values that
## are a path or an UNVERIFIED depending on a branch - would otherwise have its
## answer digested a second time. `<run>/work/sources.tcl` is not a path that
## resolves anywhere, so the second pass would fall through to the site branch
## and emit a digest of a label: the reader loses the only field that tells them
## WHICH file was read, and two runs under different build roots start differing
## again - the exact failure the labels exist to prevent. Measured on the six
## stage scripts: twelve fields in three manifests take this branch.
proc prov_path_value {v} {
    if {[string first "UNVERIFIED:" $v] == 0} { return $v }
    if {$v eq ""} { return [prov_value $v] }
    set out {}
    set changed 0
    foreach tok [split $v " "] {
        if {$tok eq ""} { continue }
        # ALREADY THROUGH THE RULE. See the idempotence note above.
        if {[string index $tok 0] eq "<" || [string first "sha256:" $tok] == 0} {
            lappend out $tok
            continue
        }
        if {[string index $tok 0] eq "/" || [string index $tok 0] eq "~" \
            || ([string first "/" $tok] > 0)} {
            set d [prov_site_path $tok]
            if {$d ne $tok} { set changed 1 }
            lappend out $d
        } else {
            lappend out $tok
        }
    }
    if {!$changed && [llength $out] == 0} { return [prov_value $v] }
    return [join $out " "]
}

## prov_knob_value <value> - block 7's spelling of prov_path_value. Kept as a
## name of its own because prov_knobs is the caller a reader arrives from, and
## because it is what the suite's mutation proof for the knob path rule plants.
proc prov_knob_value {v} { return [prov_path_value $v] }

proc prov_knobs {fh} {
    set resolved {}
    foreach k $::flow(knobs) {
        set v "UNVERIFIED:registered-but-unset"
        catch { set v [set ::$k] }
        # A KNOB VALUE CAN BE A PATH, so it goes through the site-path rule like
        # every other path in this file.
        #
        # It did not, until 2026-09-08, and this file's own header said it must:
        # "prov_site_path is the ONE place that decision is made; nothing else in
        # the flow may write a path into a manifest." Block 7 wrote knob values
        # raw. Several toolkit knobs hold paths by design - FLIST_INCDIRS,
        # FLIST_DEFINES, SYNTH_EXTRA_ARGS, IMPL_INCREMENTAL_DCP - so with
        # FLIST_INCDIRS pointing at a vendor mount, that mount point appeared in
        # clear about forty lines below a block that had carefully digested
        # exactly the same shape of path. Found by t_provenance.sh.
        mf $fh knob.$k [prov_knob_value $v]
        lappend resolved $k
    }

    set dirs {}
    foreach d [list [file join [file dirname $::flow_common_dir] steps] \
                    $::flow_common_dir \
                    [flow_env FPGA_OVERRIDES_DIR]] {
        if {$d ne "" && [file isdirectory $d]} { lappend dirs $d }
    }
    array set declared {}
    foreach d $dirs {
        foreach decl [flow_knob_scan $d] {
            foreach {n dflt src} $decl break
            set declared($n) $src
        }
    }
    set n_unsourced 0
    foreach n [lsort [array names declared]] {
        if {[lsearch -exact $resolved $n] >= 0} { continue }
        mf $fh knob.$n "UNVERIFIED:declared-in-$declared($n)-not-sourced-by-this-stage"
        incr n_unsourced
    }
    mf $fh knob.count_resolved  [llength $resolved]
    mf $fh knob.count_unsourced $n_unsourced
    return [llength $resolved]
}

# THE STAGE MANIFEST. One writer, seven blocks, the order fixed by CONTRACT.md
# section 5 and implemented nowhere else.
#
# Returns the path, so a stage's own assertion can be `if {![file size [prov_
# manifest synth]]}` rather than a second spelling of the filename.
#
# TWO NAMES, TAKEN SEPARATELY, BECAUSE ONE STAGE CANNOT SATISFY BOTH WITH ONE.
#
#   <stage>  the stage's NAME. It is the make target, it is what mk/flow.mk
#            exports as FPGA_STAGE, it is what ci/assert-stage.sh is invoked
#            with, and it is what goes in the `stage` FIELD - identifying the
#            stage is that field's entire job.
#   <stem>   the ARTEFACT stem, fixed by CONTRACT.md section 4. It decides the
#            FILENAME and nothing else. It defaults to the stage name, which is
#            correct for five of the six stages.
#
# This took one string until 2026-09-08, and package-ip could not satisfy it.
# MEASURED, both ways, on the real assert-stage:
#
#   prov_manifest package_ip -> assert-stage FAILS the run: "the manifest at
#                               .../package_ip_manifest.txt says stage
#                               'package_ip', not 'package-ip' - it is not this
#                               stage's manifest, so nothing read out of it
#                               describes this stage"
#   prov_manifest package-ip -> the file lands at package-ip_manifest.txt, where
#                               neither mk/flow.mk nor assert-stage looks
#
# The stage script worked around it by writing under one name and renaming the
# file afterwards, which put a filename decision in a stage script and left the
# next hyphenated stage to rediscover the whole thing.
#
# THE STEM IS NOT DERIVED FROM THE STAGE NAME. `package-ip` -> `package_ip`
# happens to be a `-`-to-`_` map, but the artefact names are a list CONTRACT.md
# section 4 fixes, not a function of the stage names, and a proc that guessed
# would be a second place that list lives - which is rule three of this toolkit.
# A hyphenated stage that does NOT pass a stem is warned about by name, because
# the resulting filename is one nothing looks for and the failure is otherwise
# an absent-artefact error two stages later.
proc prov_manifest {stage {stem ""}} {
    global REPORT_DIR WORK_DIR LOG_DIR OUT_DIR IN_WORK_DIR FLOW_T0

    if {![info exists REPORT_DIR]} {
        die "prov_manifest: REPORT_DIR is not set, so there is nowhere to write" \
            "  the manifest for stage '$stage'. flow_boot publishes it; a stage" \
            "  that skipped flow_boot has also skipped every input assertion."
    }
    if {$stem eq ""} {
        set stem $stage
        if {[string first "-" $stage] >= 0} {
            catch {
                warn "prov_manifest '$stage': no artefact stem given, so this"
                warn "  manifest lands at ${stage}_manifest.txt. CONTRACT.md"
                warn "  section 4 fixes the artefact names and none of them"
                warn "  carries a '-'. Call prov_manifest <stage> <stem>."
            }
        }
    }
    set path [file join $REPORT_DIR ${stem}_manifest.txt]
    set fh [open $path w]

    puts $fh "# $stage manifest - schema $::PROV_SCHEMA"
    puts $fh "# UNVERIFIED:<reason> is NOT a value. A comparison involving one"
    puts $fh "# must be refused, and a gate reading one has not passed."
    puts $fh "# 'unmeasured' is a count nobody took. It is not 0."
    puts $fh "# '(none)' is an explicitly empty value. A blank field is a bug."

    # --- 1. HEADER -----------------------------------------------------------
    # Seeded BEFORE prov_tool, which is called from the header block and writes
    # prov.tool.* fields. ::prov_order is declaration order, so without this the
    # two tool fields would sort ahead of prov.schema and a reader diffing two
    # manifests would meet the version assertion before the thing it is a
    # version of.
    prov_set schema $::PROV_SCHEMA
    prov_set stage  $stage

    puts $fh ""
    puts $fh "# 1. header"
    mf $fh date [clock format [clock seconds] -format "%Y-%m-%dT%H:%M:%S%z"]

    # RUNTIME IS MEASURED FROM STAGE LAUNCH WHEN make SAYS WHEN THAT WAS, AND
    # FROM flow_boot OTHERWISE - and the manifest says WHICH, because the second
    # under-reports by however long the tool took to start, which on a licence
    # server is minutes. Two runs whose runtimes were measured on different
    # bases are not comparable and a reader has to be able to see that.
    set basis "flow-boot (FPGA_STAGE_T0 unset: EXCLUDES tool startup)"
    if {[flow_env FPGA_STAGE_T0] ne ""} { set basis "stage-launch" }
    if {[info exists FLOW_T0]} {
        mf $fh runtime_s [expr {[clock seconds] - $FLOW_T0}]
    } else {
        mf $fh runtime_s "unmeasured"
        set basis "UNVERIFIED:flow_boot-did-not-run"
    }
    mf $fh runtime_basis $basis
    mf $fh stage   $stage
    mf $fh run_tag [prov_value [flow_env FPGA_RUN_TAG default]]

    set host "UNVERIFIED:info-hostname-failed"
    catch { set host [info hostname] }
    mf $fh host $host
    mf $fh user [prov_value [flow_env USER [flow_env LOGNAME "UNVERIFIED:USER-and-LOGNAME-unset"]]]

    foreach {toolname toolver} [prov_tool] break
    mf $fh tool         $toolname
    mf $fh tool_version $toolver

    # THE LOG IS FOUND, NOT ASSUMED. mk/flow.mk composes it as
    # $(LOG_DIR)/<stage>.log but does not export the name, so it is derived and
    # then CHECKED: a manifest naming a log that is not there sends the reader to
    # a file that cannot answer them.
    set log [flow_env FPGA_LOG_FILE]
    if {$log eq "" && [info exists LOG_DIR]} { set log [file join $LOG_DIR ${stage}.log] }
    if {$log eq ""} {
        mf $fh log_file "UNVERIFIED:FPGA_LOG_FILE-unset-and-no-LOG_DIR"
    } elseif {![file exists $log]} {
        mf $fh log_file "UNVERIFIED:no-log-at-[prov_site_path $log]"
    } else {
        mf $fh log_file [prov_site_path $log]
    }

    # --- 2. PROVENANCE -------------------------------------------------------
    puts $fh ""
    puts $fh "# 2. provenance - what design is this? Any site path is a sha256:"
    puts $fh "#    digest, never the raw path (a mount point is inventory-shaped"
    puts $fh "#    disclosure and manifests get pasted into bug reports)."
    prov_collect_all $stage
    prov_emit $fh

    # --- 3. DIRECTORIES ------------------------------------------------------
    puts $fh ""
    puts $fh "# 3. directories"
    foreach {k v} [list \
        work_dir     [expr {[info exists WORK_DIR]    ? $WORK_DIR    : ""}] \
        in_work_dir  [expr {[info exists IN_WORK_DIR] ? $IN_WORK_DIR : ""}] \
        log_dir      [expr {[info exists LOG_DIR]     ? $LOG_DIR     : ""}] \
        report_dir   [expr {[info exists REPORT_DIR]  ? $REPORT_DIR  : ""}] \
        out_dir      [expr {[info exists OUT_DIR]     ? $OUT_DIR     : ""}] \
    ] {
        if {$v eq ""} {
            mf $fh $k "UNVERIFIED:not-published-by-flow_boot"
        } else {
            mf $fh $k [prov_site_path $v]
        }
    }
    mf $fh part  [prov_value [flow_env FPGA_PART  "UNVERIFIED:FPGA_PART-unset"]]
    mf $fh board [prov_value [flow_env FPGA_BOARD "UNVERIFIED:FPGA_BOARD-unset"]]

    # --- 4. BOTH GIT SHAS ----------------------------------------------------
    #
    # BOTH, and that is the whole point of the block. A run is the product of two
    # repositories - the design and the engine that built it - and a manifest
    # carrying only the design's sha cannot tell "the RTL changed" from "the flow
    # changed". The reference project shipped a GDS that is unreproducible for
    # exactly that reason: synthesis ran at a toolkit commit nothing recorded.
    puts $fh ""
    puts $fh "# 4. both git shas - the design AND the engine that built it"
    foreach {label dirvar why} {
        project  FPGA_PROJECT_ROOT no-project-root
        toolkit  FPGA_FLOW_DIR     no-toolkit-root
    } {
        foreach {sha drt des} [prov_git [flow_env $dirvar] $why] break
        mf $fh ${label}_git_sha      $sha
        mf $fh ${label}_git_dirty    $drt
        mf $fh ${label}_git_describe $des
    }

    # --- 5. STEP FILES -------------------------------------------------------
    #
    # Which of flow/steps/*.tcl the toolkit supplied and which the project
    # replaced. `make check` also warns when an override is active; this is the
    # record that survives into the artefact, so a QoR difference nobody can
    # explain has one place to look first.
    puts $fh ""
    puts $fh "# 5. step files - 'toolkit' or 'PROJECT OVERRIDE', per step sourced"
    if {[llength $::flow(steps)]} {
        mf $fh step_files [join $::flow(steps) " "]
    } else {
        mf $fh step_files "(none)"
    }
    mf $fh steps_available [join [flow_steps_available] " "]

    # --- 6. HOOKS ------------------------------------------------------------
    puts $fh ""
    puts $fh "# 6. hooks that ran, with their runtimes"
    if {[llength $::flow(hooks)]} {
        mf $fh hooks_run [join $::flow(hooks) " "]
    } else {
        mf $fh hooks_run "(none)"
    }

    # --- 7. KNOBS ------------------------------------------------------------
    puts $fh ""
    puts $fh "# 7. every registered knob, enumerated from the 'opt' declarations."
    puts $fh "#    A knob declared by a step file this stage did not source is"
    puts $fh "#    UNVERIFIED, not defaulted: this run never read it."
    prov_knobs $fh

    close $fh
    say "manifest: $path"
    return $path
}


################################################################################
# 5. BLOCK 8 - WHAT THE STAGE ITSELF MEASURED
#
# THE SEAM prov_manifest DOES NOT HAVE. prov_manifest writes CONTRACT.md section
# 5's seven blocks and closes the file; nothing in them is a place for a stage's
# own numbers, and ci/assert-stage.sh REQUIRES those numbers as top-level
# manifest keys - file_count for flist, vlnv and params_packaged for package-ip,
# bd_cells and overlays_applied for bd, lut/ff/bram/dsp for synth,
# wns/whs/unrouted_nets for impl, bin_style/bit_bytes for bitstream. So block 8
# is appended after prov_manifest returns, and this is the sanctioned way to do
# it. Six stage scripts wrote their own emitter first; see the file header.
#
# WHY NOT prov_set. `prov_set` puts a key in the `prov.` namespace, which
# `compare-runs` treats as design IDENTITY: a difference there means the two
# runs are not the same design and the comparison is REFUSED. A stage result is
# not identity. Two runs of one design that differ in LUT count are the normal
# case - that is what an A/B experiment IS - and routing every measurement
# through prov_set would make `compare-runs` refuse every pair anyone would
# actually want to compare, at which point it gets switched off.
#
# THE THREE RULES OF SECTION 5 APPLY HERE UNCHANGED, and each is implemented
# once rather than at each of the ~90 call sites in the six stage scripts:
#
#   * a value that was never taken is the literal token `unmeasured`, NEVER `0`
#     and NEVER blank. `0` is a legitimate measurement - zero unrouted nets,
#     zero blackboxes - and ci/lib.sh's CI_UNMEASURED_RE keys on the token, so a
#     stage that wrote a blank or a `0` for "did not look" would be GRADED GREEN
#     by assert-stage on a number nobody took;
#   * a value that was looked for and could not be read is `UNVERIFIED:<reason>`,
#     passed in by the caller, which knows the reason;
#   * a value that IS a path goes through the site-path rule, exactly like every
#     other path in this file. Measurements hold paths routinely - sources_tcl,
#     component_xml, bd_wrapper, inbody_record - and the file header's rule has
#     no measurements-only exemption.
#
# NOTE `(none)` IS NOT `unmeasured`, and the two must not be collapsed.
# CONTRACT.md section 11 fixes `(none)` for "explicitly nothing" - a design with
# no defines, an overlay list that is empty on purpose - and ci_is_measured
# treats it as a MEASUREMENT, correctly: somebody looked, and the answer was
# nothing. Only the CALLER can tell those apart, so the caller passes `(none)`
# and a blank arriving here is treated as the thing the caller could not supply.
################################################################################

# key -> value, plus declaration order, so block 8 is diffable line by line.
# SEPARATE FROM ::prov, which is block 2. See above.
array set ::prov_stage       {}
set       ::prov_stage_order {}

proc prov_stage_reset {} {
    array unset ::prov_stage
    array set   ::prov_stage {}
    set ::prov_stage_order {}
}

## prov_stage_field <key> <value>
## Record ONE measurement. FIRST DECLARATION FIXES THE ORDER; a later write to
## the same key replaces the value and does not move it, so a stage that refines
## a number does not shuffle its manifest under a reader's diff.
##
## The blank-to-`unmeasured` conversion happens HERE, at record time, and not at
## emission: prov_stage_measured and the gate paragraphs read these values back
## while the stage is still deciding its verdict, and a blank read back as ""
## would compare, format and concatenate as though it were a number.
proc prov_stage_field {key value} {
    if {[string trim $value] eq ""} { set value "unmeasured" }
    if {![info exists ::prov_stage($key)]} { lappend ::prov_stage_order $key }
    set ::prov_stage($key) $value
}

## prov_stage_get <key> - the recorded value, or `unmeasured` when nothing
## recorded one. NEVER "" and never an error: this is called from inside gate
## paragraphs and `expr` comparisons a hundred lines from the record.
proc prov_stage_get {key} {
    if {[info exists ::prov_stage($key)]} { return $::prov_stage($key) }
    return "unmeasured"
}

## prov_stage_measured <key> - true only when a REAL measurement is recorded.
## This is the guard that has to go in front of every arithmetic use of a
## measurement, because `expr {"unmeasured" > 0}` is not a comparison, it is an
## error that aborts a stage at its verdict - after the work is done.
proc prov_stage_measured {key} {
    set v [prov_stage_get $key]
    return [expr {$v ne "unmeasured" && ![string match "UNVERIFIED*" $v]}]
}

## prov_stage_fields <manifest path> ?<key value key value ...>?
##
## Append block 8 to a manifest prov_manifest has already closed, and return the
## path. The optional list is recorded first, so a stage that measures
## everything at the end writes ONE call and a stage that accumulates as it goes
## calls prov_stage_field and passes nothing here.
##
## APPEND, NOT REWRITE. prov_manifest is called last for a reason (CONTRACT.md
## section 5): its existence is the evidence that the stage reached its final
## section. Re-opening it "w" to insert an eighth block would destroy the seven
## that are already on disk if the stage died between the two calls, which is
## precisely the window this ordering exists to make safe.
proc prov_stage_fields {path {fields {}}} {
    foreach {k v} $fields { prov_stage_field $k $v }
    set fh [open $path a]
    puts $fh ""
    puts $fh "# 8. what this stage MEASURED, read back out of the reports and"
    puts $fh "#    artefacts it wrote. ci/assert-stage.sh reads these keys."
    puts $fh "#    'unmeasured' is a count nobody took. It is not 0."
    foreach k $::prov_stage_order {
        mf $fh $k [prov_path_value $::prov_stage($k)]
    }
    close $fh
    return $path
}


################################################################################
# 6. THE STAGE VERDICT ARTEFACT
################################################################################

## prov_gate <stage> <stem> <paragraph> <hard> <budgets> <delegated> <notcovered>
##
## Writes $REPORT_DIR/<stem>_gate.txt in the structure CONTRACT.md section 5
## fixes, and returns the path. <stage> and <stem> split for the same reason
## they split in prov_manifest: the TITLE names the stage (`PACKAGE-IP gate`)
## and the FILENAME is the artefact stem (`package_ip_gate.txt`). Unlike
## prov_manifest the stem is required, because every caller of this proc is a
## stage script written after the split and there is no one-argument form in the
## field to keep working.
##
## The four lists are the four verdict classes, in the order they are written:
##   <hard>       the run is BROKEN. Anything here makes the stage fail.
##   <budgets>    a measurement passed an EXPECT_* knob the project armed.
##   <delegated>  measured here, owned by somebody else - and EVERY entry must
##                carry `owner=<who>`. assert-stage FAILS an entry without one,
##                because "somebody else measures this" with no somebody is how
##                a thing comes to be measured by nobody.
##   <notcovered> what NO run of this flow measures, at any setting. The honesty
##                mechanism: a green run still enumerates what it did not look at.
##
## `HARD FAILURES: none` IS THE EXACT STRING, AND IT IS PUNCTUATION, NOT PROSE.
## mk/flow.mk greps for it and ci/assert-stage.sh greps for it ANCHORED
## (`^HARD FAILURES: none`) - anchored because an unanchored grep for
## `HARD FAILURES` also matches the section HEADING and therefore passes on every
## gate file ever written, including one listing nine of them. So: capitals, one
## space after the colon, `none` in lower case, at the left margin, and the
## count - never the word - when there are any. Change any of that and every
## gate in the flow silently starts passing.
##
## EVERY SECTION IS ALWAYS WRITTEN, INCLUDING THE EMPTY ONES. An absent section
## is not an empty one: a reader cannot tell "no budget was exceeded" from
## "budgets were never checked", and assert-stage calls a missing heading
## UNVERIFIED for exactly that reason. That is why the four lists are positional
## and required rather than optional arguments with empty defaults - a stage
## that has nothing in a class has to say `{}` and mean it.
##
## BULLETS ARE FLATTENED TO ONE LINE EACH. assert-stage reads a section with
## `awk '/^HEADING/{s=1;next} s&&/^[A-Z]/{exit} s&&/^  - /{print}'`, so a bullet
## carrying an embedded newline ENDS THE SECTION at its second line if that line
## starts with a capital - silently dropping every later bullet, including the
## ones a reader most needs. Stage scripts write these as Tcl continuation
## strings, which already collapse to single spaces, but a bullet that
## interpolates a report line or a tool message does not, and that is the one
## that matters. `regsub` costs nothing and closes the class.
proc prov_gate {stage stem paragraph hard budgets delegated notcovered} {
    global REPORT_DIR block_name RUN_TAG board_name part_name

    if {![info exists REPORT_DIR]} {
        die "prov_gate: REPORT_DIR is not set, so there is nowhere to write the" \
            "  verdict for stage '$stage'. flow_boot publishes it; a stage that" \
            "  skipped flow_boot has also skipped every input assertion."
    }
    set path [file join $REPORT_DIR ${stem}_gate.txt]

    # THE IDENTITY LINE IS ASSEMBLED DEFENSIVELY. These four are flow_boot
    # globals and every stage has them, but this proc is also reachable from a
    # refusal path and from a harness, and a verdict writer that throws because
    # the board pack did not load leaves NO verdict at all - which assert-stage
    # reads as "the stage did not reach its verdict section". A gate naming an
    # unknown board is worth more than no gate.
    set ident {}
    foreach {label var} {design block_name {run tag} RUN_TAG
                         board board_name part part_name} {
        upvar #0 $var v
        lappend ident "$label [expr {[info exists v] ? $v : "(not loaded)"}]"
    }

    set fh [open $path w]
    puts $fh "[string toupper $stage] gate, [clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%S%z}]"
    puts $fh [join $ident ", "]
    puts $fh ""
    foreach line $paragraph { puts $fh $line }
    puts $fh ""
    if {[llength $hard]} {
        puts $fh "HARD FAILURES: [llength $hard]"
        foreach h $hard { puts $fh "  - [regsub -all {\s+} $h { }]" }
    } else {
        puts $fh "HARD FAILURES: none"
    }
    puts $fh ""
    puts $fh "BUDGETS EXCEEDED"
    foreach b $budgets { puts $fh "  - [regsub -all {\s+} $b { }]" }
    puts $fh ""
    puts $fh "DECLARED ELSEWHERE - MEASURED HERE, OWNED BY SOMEBODY ELSE"
    foreach d $delegated { puts $fh "  - [regsub -all {\s+} $d { }]" }
    puts $fh ""
    puts $fh "NOT covered by ANY run of this flow, at any setting:"
    foreach n $notcovered { puts $fh "  - [regsub -all {\s+} $n { }]" }
    puts $fh ""
    puts $fh "# Copyright (C) 2026, SoC Labs (www.soclabs.org)"
    close $fh
    catch { say "gate: $path" }
    return $path
}

################################################################################
# 7. THE READERS BLOCK 8 IS MADE OF, AND THE VERDICT THEY FEED
#
#   prov_util_number   is this cell a utilisation count?
#   prov_util_row      one row of a utilisation table
#   prov_msg_criticals the stage's critical-warning census
#   prov_msg_verdict   may this run carry the messages the census found?
#
# Block 8 is made of numbers read back off disk, and two of those readers were
# written out longhand in more than one stage script - `util_row` in 4_synth.tcl
# and 5_impl.tcl, `msg_criticals` in 4_synth.tcl, 5_impl.tcl and 6_bitstream.tcl.
# That is the same duplication section 5's header describes for the emitters, at
# the same cost: BOTH copies of `util_row` carried the same defect, and neither
# reader can be fixed in a way the other stage inherits. So they live here,
# beside the field they feed. 4_synth.tcl and 5_impl.tcl now read through these;
# 6_bitstream.tcl still carries its own `msg_criticals` and its own copy of the
# gate chain, and is the one place the defect below is still live.
#
# THE DEFECT, with the numbers. `util_row` tested the used column with
# `string is integer -strict`, and a 7-series utilisation report counts block RAM
# in HALF tiles:
#
#   | Block RAM Tile | 32.5 |     0 |    140 |  23.21 |
#
# `string is integer -strict 32.5` is FALSE, so the row was skipped, the proc
# returned "" and prov_stage_field wrote `bram unmeasured` - in the synth AND the
# impl manifest - for a design whose BRAM count the tool had reported perfectly
# well. That made `ci/assert-stage.sh synth` red on a correct run, and it made
# EXPECT_BRAM_MAX structurally unarmable: budget_max returns 0 for a value that
# is not a double, so the budget nobody could compare against never fired.
#
# CONTRACT.md rule 2 says `unmeasured` means WE COULD NOT MEASURE. A parser that
# turns a good number into `unmeasured` is lying in the direction the rule exists
# to prevent, and it is the worse direction of the two: it spends the token that
# is supposed to stop a run on a number that was there all along.
################################################################################

## prov_util_number <string> - true when the string is a utilisation COUNT as
## Vivado writes one: digits, optionally with a decimal fraction.
##
## NOT `string is double`, which also accepts `1e5`, `Inf`, `NaN` and a leading
## `+`, none of which a utilisation column ever holds, and all of which would
## sail into `budget_max` and be compared. And not `string is integer` either -
## that is the defect above. The shape of the field is the check.
proc prov_util_number {s} {
    return [regexp {^[0-9]+(?:\.[0-9]+)?$} $s]
}

## prov_util_row <report> <list of row names> -> the "Used" cell, or "" when no
## row matched.
##
## The name is matched against a LIST of spellings because the tables are
## architecture dependent - 7-series says "Slice LUTs*", UltraScale says
## "CLB LUTs" - and a parser that knew only one of them would return `unmeasured`
## on every other device and call that a measurement. The trailing `*` is part of
## the name, not a wildcard: `string equal` is exact, deliberately.
##
## "" IS THE ONLY FAILURE VALUE, and the caller hands it to prov_stage_field,
## which spells it `unmeasured`. This proc never returns 0 for a row it could not
## find: a zero in a utilisation column is indistinguishable from an empty
## design, and both look like good news.
proc prov_util_row {file names} {
    if {![file exists $file] || ![file size $file]} { return "" }
    set fh [open $file r]
    set data [read $fh]
    close $fh
    foreach line [split $data "\n"] {
        if {![string match "|*" $line]} { continue }
        set cells [split $line "|"]
        if {[llength $cells] < 4} { continue }
        set name [string trim [lindex $cells 1]]
        set used [string trim [lindex $cells 2]]
        foreach want $names {
            if {[string equal -nocase $name $want] && [prov_util_number $used]} {
                return $used
            }
        }
    }
    return ""
}


################################################################################
# THE CRITICAL-WARNING CENSUS, AND WHY THE TOOL'S OWN COUNTER IS NOT THE ANSWER
#
# `get_msg_config -count -severity {CRITICAL WARNING}` does NOT count a stage. It
# counts the messages issued since the last command that (re)built the in-memory
# design, because every one of those commands resets Vivado's message counters as
# it starts. Measured on Vivado 2024.1, xc7z020clg400-1, by planting messages
# with send_msg_id between commands and reading the counter after each:
#
#   plant one                          counter 1
#   read_xdc (two Constraints 18-6xx)  counter 3
#   report_drc (one more)              counter 4
#   opt_design                         counter 1   <- reset, then its own message
#   plant one                          counter 2
#   place_design (two of its own)      counter 2   <- reset, then its own two
#   plant one                          counter 3
#   route_design (one of its own)      counter 1   <- reset again
#   report_timing_summary              counter 1   <- reports do NOT reset
#   write_checkpoint                   counter 1
#
# open_checkpoint resets it too (1 -> 0 across a close/open pair).
#
# So an impl stage that ends by asking the tool gets the messages issued since
# route_design began, and NOT the two `Constraints 18-611/18-612` its own
# read_xdc raised forty minutes earlier. Two failures, in opposite directions,
# both seen:
#
#   * counter 0, log 2  - the gate's own guard is `$cw > 0`, so the whole message
#     gate was SKIPPED and the run went green with two ungraded critical
#     warnings. A gate that cannot see the thing it grades is not a lenient
#     gate, it is an absent one;
#   * counter 1, log 3  - the shape the KR260 build hit. The counts disagree, so
#     the id list is declared partial and NO exemption is granted.
#     `Project 1-1924` (write_hw_platform on a design with no block design)
#     fires for every PL-only project, so with the default
#     ALLOW_CRITICAL_WARNINGS=0 such a project was permanently red with no route
#     to green, whatever it declared in MSG_GATE_ALLOWLIST.
#
# WHICH ONE THE GATE BELIEVES. The stage log, for the same reason section 9 of
# 4_synth.tcl reads its numbers off disk rather than out of the tool: the log is
# the complete record of what the stage emitted, one line per message, written as
# each was issued. The counter is kept as a CROSS-CHECK that can only make the
# gate STRICTER - every message the counter still remembers was printed to the
# log, so a log carrying FEWER than the counter is not this stage's log, or is
# truncated, and an allowlist applied to a partial reading would exempt messages
# nobody saw. That is the property `complete` carries, and it is the one the
# original count-must-equal-count test was reaching for.
#
# THE ANCHOR IS WHAT MAKES A GREP SAFE HERE, and it is not a formality. Vivado
# writes `CRITICAL WARNING: [<id>] <text>` at the left margin and nothing else in
# a log does - but an UNANCHORED grep for the same words reports 3 hits in a
# synth log that emitted NONE, measured on this repository's own fixture runs,
# because a Vivado log echoes every line of the Tcl it sources with a `# ` prefix
# and one of the lines it echoes is this proc's own regexp. That is the defect
# the old "never grep, ask the tool" comment was protecting against; the answer
# is to grep the one shape the tool guarantees, not to trust a counter that
# answers a different question.
################################################################################

## prov_msg_criticals ?<log path>? -> a dict:
##
##   total     the number to grade: the log's, or the tool's when the log could
##             not be read. "" when neither could be had.
##   log       messages counted in the stage log, "" when it could not be read
##   tool      get_msg_config's counter, "" when there is no tool
##   ids       the message ids seen, unique, in first-seen order
##   complete  1 only when `ids` accounts for every message the tool counted.
##             AN EXEMPTION REQUIRES THIS. 0 is not "a bit uncertain", it is
##             "this list is not the whole list".
##   basis     one line for the manifest saying which evidence produced `total`
##
## The log path defaults to FPGA_LOG_FILE, which mk/flow.mk's vivado_stage
## exports per stage and points at the same file it gives Vivado's own `-log`.
proc prov_msg_criticals {{log ""}} {
    set tool ""
    catch { set tool [get_msg_config -count -severity {CRITICAL WARNING}] }
    if {![string is integer -strict $tool]} { set tool "" }

    if {$log eq ""} { catch { set log [flow_env FPGA_LOG_FILE] } }

    set ids {} ; set n "" ; set why ""
    if {$log eq ""} {
        set why "FPGA_LOG_FILE is not set, so this stage does not know\
                 which file its own messages went to"
    } elseif {![file exists $log]} {
        set why "no file at the recorded log path"
    } elseif {[catch {open $log r} fh]} {
        # THE ERROR CODE, NOT THE ERROR MESSAGE. Tcl's message is
        # `couldn't open "<path>": permission denied`, and this string is a
        # manifest field - the site-path rule at the top of this file has no
        # exemption for a diagnostic, and prov_path_value does not rewrite a
        # value that begins `UNVERIFIED:`, which this one does.
        set why "the stage log could not be opened ($::errorCode)"
    } else {
        set n 0
        while {[gets $fh line] >= 0} {
            if {[regexp {^CRITICAL WARNING: \[([^\]]+)\]} $line -> id]} {
                incr n
                if {[lsearch -exact $ids $id] < 0} { lappend ids $id }
            }
        }
        close $fh
    }

    set counter_note "the tool's live counter is reset by open_checkpoint,\
                      synth_design, opt_design, place_design and route_design, so\
                      it counts only since the last of those"
    if {$n eq ""} {
        # No log, so no ids, so nothing can be exempted - and the number that
        # survives is a FLOOR, not a total. Both facts go in the manifest.
        set total    $tool
        set complete 0
        set basis    "UNVERIFIED:stage-log-unreadable - $why. The number is the\
                      tool's counter and is a LOWER BOUND: $counter_note"
    } elseif {$tool ne "" && $tool > $n} {
        # The counter remembers messages this log does not carry. The log is not
        # this stage's, or it was truncated - either way the id list is partial.
        set total    $tool
        set complete 0
        set basis    "$n message(s) in the stage log but the tool counts $tool -\
                      the log is NOT a complete record of this stage, so the id\
                      list is partial and grants no exemption"
    } else {
        set total    $n
        set complete 1
        set said [expr {$tool eq "" ? "no tool counter (no tool)" : "tool counter $tool"}]
        set basis    "$n message(s) counted in the stage log, $said:\
                      $counter_note, and every message it still counts is in\
                      the log"
    }

    return [dict create total $total log $n tool $tool ids $ids \
                        complete $complete basis [regsub -all {\s+} $basis { }]]
}


## prov_msg_verdict <allow knob> <ids> <allowlist> <complete> -> a dict:
##
##   verdict   allowed | exempt | incomplete | unlisted
##   unexempt  the ids that are not in the allowlist
##
## THE FOUR ANSWERS TO "MAY THIS RUN CARRY THESE CRITICAL WARNINGS?", in one
## place, because the chain that answers it was written out in three stage
## scripts and the completeness half of it was wrong in all three. It returns a
## verdict and NOT a sentence: the stage writes the gate bullet, in its own
## words, about its own artefacts.
##
##   allowed     ALLOW_CRITICAL_WARNINGS=1. Reported, not gated - the project
##               has said so out loud, in design.mk, where a reviewer sees it.
##   exempt      every id is allowlisted AND the id list is complete.
##   incomplete  the id list does not account for every message, so NOTHING can
##               be exempted from this run - not even an id that is on the list,
##               because an allowlist applied to a partial reading exempts
##               messages nobody saw. CONTRACT.md section 7.
##   unlisted    the list is complete and something on it is not allowlisted.
##
## `incomplete` is checked BEFORE `unlisted` deliberately: when both hold, the
## honest sentence is the one about the evidence, not the one about the ids -
## the id list a reader would go and allowlist is not known to be the whole list.
##
## An EMPTY id list never earns `exempt`. A stage that counted messages and read
## no ids has nothing to compare against the allowlist, and "no ids to object to"
## is not the same fact as "every id is allowed".
proc prov_msg_verdict {allow ids allowlist complete} {
    set unexempt {}
    foreach id $ids {
        if {[lsearch -exact $allowlist $id] < 0} { lappend unexempt $id }
    }
    if {$allow} {
        set v allowed
    } elseif {$complete && ![llength $unexempt] && [llength $ids]} {
        set v exempt
    } elseif {!$complete} {
        set v incomplete
    } else {
        set v unlisted
    }
    return [dict create verdict $v unexempt $unexempt]
}


# Copyright (C) 2026, SoC Labs (www.soclabs.org)
