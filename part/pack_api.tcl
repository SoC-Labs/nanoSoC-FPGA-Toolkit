################################################################################
# part/pack_api.tcl
#
# The contract every PART pack and every BOARD pack implements, plus the loader,
# the validator, and the two accessor families the engine calls.
#
# A PART PACK is one file - part/<part>/part.tcl - that answers every question
# the flow has about a DEVICE: how many LUTs, which MMCM primitive physically
# exists, how many SLRs, whether there is an IDELAY. It ships in this toolkit,
# because every project on that device wants the same answer.
#
# A BOARD PACK is one file - fpga/board/<board>/board.tcl - that answers every
# question the flow has about a CIRCUIT BOARD: which device is soldered down,
# what the oscillator runs at, how a .bin has to be formatted for this family's
# boot ROM. It ships in the PROJECT, because a lab bench is not a shared truth.
# CONTRACT.md section 1 draws that line; this file is where it is enforced.
#
# ONE ENGINE, TWO ROLES - AND WHY
# -------------------------------
# CONTRACT.md section 8 specifies two parallel accessor sets, part_* and
# board_*, with identical semantics: unknown key errors, double-set errors,
# missing-required reports everything at once, unset-optional errors rather
# than returning "", no site path is ever defaulted, a underivable key defers
# with a reason.
#
# Identical semantics, written twice, do not stay identical. The reference
# toolkit's own tech_api.tcl is ~1,400 lines of validator; a copy-pasted second
# one would take the first bug fix and not the second, and the day the two
# disagree is the day a board pack is validated by rules a part pack is not.
# That failure is silent by construction - nobody diffs two validators.
#
# So there is ONE engine. Every command is `pack_<verb> <role> ...`, the role
# selects one of two declarative schema tables, and the two public name
# families are `interp alias` lines at the bottom of this file - section 10.
# The cost is that every message has to be written role-neutrally and stamped
# with the role at the point of printing; that is a discipline, not a
# duplication, and it is why every error below says "$role pack '<name>'".
#
# WHAT THE ROLE SELECTS. Everything that differs between a device and a board
# is a TABLE, never a code path:
#
#     ::pack_schema_spec($role)     the KEY REQUIRED TYPE GROUP {DESC} rows
#     ::pack_cascade_spec($role)    the conditional cascades
#     ::pack_enum_spec($role)       closed value sets (bin_style, platform)
#     ::pack_alias_spec($role)      accepted alternative spellings
#     ::pack_empty_ok($role)        keys where an empty list is a decision
#     ::pack_file_name($role)       part.tcl / board.tcl
#
# There are exactly two places the engine branches on the role name itself -
# where the pack root is searched (section 4) and the physical-primitive
# cross-check (section 6), which is a device concept with no board analogue.
# Both are commented as such.
#
# USAGE
#
#   from the flow engine (flow/common/flow_utils.tcl does exactly this):
#       source $FPGA_FLOW_DIR/part/pack_api.tcl
#       part_load  $PART_DIR
#       board_load $BOARD_DIR
#       set fam [part_get family]
#
#   from a script with no project and no run directory:
#       scripts/fpga-flow-part-get --part part/xck26-sfvc784-2LV-c family luts
#
#   from a pack:
#       part_set family zynquplus
#       part_note {read from the install on 2026-09-08, Vivado v2024.1}
#       board_set board_repo_paths [board_env MY_BOARD_FILES "vendor board files"]
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
################################################################################

# Idempotent: flow_utils.tcl sources this, and so does every helper script that
# a flow script may in turn source. Re-sourcing must not wipe a loaded pack.
if {[info exists ::pack_api_loaded]} { return }
set ::pack_api_loaded 1

# Captured HERE, at source time. `info script` returns whichever file is
# executing, so asking for it inside pack_load returns the CALLER's path and the
# loader then looks for packs next to a stage script. The reference toolkit
# carries the same comment because it is the same one-line trap.
set ::pack_api_dir [file dirname [file normalize [info script]]]


################################################################################
# 1. THE SCHEMA TABLES
#
# Moved to part/pack_schema.tcl - 500-odd lines of declarative rows, no control
# flow, and the thing a pack author is actually looking for. Sourced here rather
# than by each consumer so that the load order stays owned by one file: the
# tables are useless without the accessors below, and a caller that sourced only
# the schema would read ::pack_schema directly.
#
# $::pack_api_dir, not a relative path: this file is sourced from a Vivado stage
# whose cwd is the work directory, from fpga-flow-part-get, and from a test
# sandbox. An addressable artefact resolves its own location.
################################################################################

set __schema [file join $::pack_api_dir pack_schema.tcl]
if {![file exists $__schema]} {
    # Same reasoning as mk/checks.mk's script guard: without this the reader
    # gets `couldn't read file ".../pack_schema.tcl"` and goes looking for a
    # problem in their pack. There is no problem in their pack.
    error "pack_api.tcl: no schema at $__schema.\n  part/pack_schema.tcl\
           declares every key a pack may set, and the API is meaningless\
           without it. This checkout of the toolkit is incomplete."
}
source $__schema
unset __schema



################################################################################
# 2. TABLE CONSTRUCTION AND STATE
################################################################################

# key -> {required type group description}, per role
array set ::pack_schema        {}
# declaration order, per role, for readable messages
array set ::pack_schema_order  {}
# role,key -> value, as set by the pack
array set ::pack_val           {}
# role,key -> script a pack deferred, and the state of resolving it
array set ::pack_defer_script  {}
array set ::pack_defer_state   {}   ;# pending | resolved | failed
array set ::pack_defer_why     {}   ;# why it failed, verbatim from the script
array set ::pack_defer_scope   {}   ;# host (a mount will fix it) | permanent (nothing will)
array set ::pack_defer_order   {}   ;# role -> declaration order
array set ::pack_notes         {}   ;# role -> free text for the manifest
array set ::pack_env_log       {}   ;# role -> EVERY <role>_env attempt
array set ::pack_missing_env   {}   ;# role -> the ones that did not resolve
array set ::pack_dir           {}
array set ::pack_file          {}

foreach __role $::pack_roles {
    set ::pack_schema_order($__role) {}
    set ::pack_defer_order($__role)  {}
    set ::pack_notes($__role)        {}
    set ::pack_env_log($__role)      {}
    set ::pack_missing_env($__role)  {}
    set ::pack_dir($__role)          ""
    set ::pack_file($__role)         ""

    # The schema tables carry group-separator comments for readability, and a
    # Tcl LIST has no comments. Strip whole comment lines before parsing, which
    # leaves the braced descriptions balanced.
    set __clean {}
    foreach __line [split $::pack_schema_spec($__role) "\n"] {
        if {[string match "#*" [string trimleft $__line]]} { continue }
        append __clean $__line "\n"
    }

    foreach {__k __req __type __group __desc} $__clean {
        if {[info exists ::pack_schema($__role,$__k)]} {
            error "pack_api.tcl: $__role schema key '$__k' is declared twice."
        }
        if {[lsearch -exact {yes no cond} $__req] < 0} {
            error "pack_api.tcl: $__role key '$__k' has bad REQUIRED field '$__req'."
        }
        if {[lsearch -exact {str int num bool list path paths} $__type] < 0} {
            error "pack_api.tcl: $__role key '$__k' has bad TYPE field '$__type'."
        }
        set ::pack_schema($__role,$__k) \
            [list $__req $__type $__group [regsub -all {\s+} $__desc " "]]
        lappend ::pack_schema_order($__role) $__k
    }
    unset -nocomplain __clean __line __k __req __type __group __desc

    # A cascade naming a key the schema does not have is a table that has
    # drifted from the schema beside it. Catch it at source time, not on the day
    # the trigger first fires.
    foreach __row $::pack_cascade_spec($__role) {
        foreach __k [concat [list [lindex $__row 0]] [lindex $__row 2]] {
            if {![info exists ::pack_schema($__role,$__k)]} {
                error "pack_api.tcl: the $__role cascade table names '$__k',\
                       which is not a $__role schema key."
            }
        }
    }
    foreach __k [array names ::pack_enum_spec ${__role},*] {
        set __kk [string range $__k [expr {[string length $__role] + 1}] end]
        if {![info exists ::pack_schema($__role,$__kk)]} {
            error "pack_api.tcl: the enum table names $__role key '$__kk',\
                   which is not in the $__role schema."
        }
    }
    foreach __k [array names ::pack_alias_spec ${__role},*] {
        set __to $::pack_alias_spec($__k)
        if {![info exists ::pack_schema($__role,$__to)]} {
            error "pack_api.tcl: the alias table maps a $__role spelling to\
                   '$__to', which is not in the $__role schema."
        }
    }
}
foreach __k $::pack_physical_primitive_keys {
    if {![info exists ::pack_schema(part,$__k)]} {
        error "pack_api.tcl: pack_physical_primitive_keys names '$__k', which is\
               not a part schema key."
    }
}
unset -nocomplain __role __row __k __kk __to


################################################################################
# 3. THE PACK-FACING API
#
# These are the only commands a part.tcl or board.tcl should need:
#
#   <role>_set  <role>_unset  <role>_note  <role>_env  <role>_defer
#   <role>_derived_dir
################################################################################

# Canonicalise a spelling through the alias table. Everything that takes a key
# goes through here, so a pack's alternative spelling is accepted identically by
# set, get, has, opt, defer and unset - which is the point of a table.
proc pack_key {role key} {
    if {[info exists ::pack_alias_spec($role,$key)]} {
        return $::pack_alias_spec($role,$key)
    }
    return $key
}

proc pack_known {role key} {
    return [info exists ::pack_schema($role,[pack_key $role $key])]
}

# Set one key. Rejects an unknown key, and rejects a second set of the same key,
# because both are copy-paste damage rather than intent.
proc pack_set {role key value} {
    set k [pack_key $role $key]
    if {![info exists ::pack_schema($role,$k)]} {
        error "${role}_set: unknown key '$key'.\
             \n  It is not in the $role schema, so nothing would ever read it -\
             \n  a setting that does nothing and says nothing is this flow's\
             \n  most expensive recurring defect.\
             \n  Nearest matches: [pack_nearest $role $key]\
             \n  Full list:       ${role}_keys, or part/README.md"
    }
    if {[info exists ::pack_val($role,$k)]} {
        error "${role}_set: '$k' is already set to '$::pack_val($role,$k)'.\
             \n  A pack sets each key exactly once. If you meant to replace a\
             \n  value computed earlier in the same file, call ${role}_unset\
             \n  first and say in a comment why the value is computed twice."
    }
    if {[info exists ::pack_defer_script($role,$k)]} {
        error "${role}_set: '$k' is already DEFERRED by this pack.\
             \n  A key is stated or deferred, never both: the deferral says the\
             \n  value could not be obtained here, and a set beside it says it\
             \n  could. Remove one."
    }
    set ::pack_val($role,$k) $value
}

# Deliberate replacement, for the rare pack that computes a key conditionally.
proc pack_unset {role key} {
    set k [pack_key $role $key]
    if {![info exists ::pack_schema($role,$k)]} {
        error "${role}_unset: unknown key '$key'. Nearest: [pack_nearest $role $key]"
    }
    unset -nocomplain ::pack_val($role,$k)
}

# Free-text note carried into the run manifest, for a fact about the device or
# the board that has no schema slot but that a reader of the manifest needs.
proc pack_note {role text} { lappend ::pack_notes($role) $text }


################################################################################
# 3a. SITE PATHS: <role>_env
#
# NO SITE PATH IS EVER DEFAULTED. A fallback to one lab's mount is a path that
# works on one machine and fails silently-looking everywhere else - and a pack
# that records a raw mount point gets pasted into a bug report, where it is
# inventory-shaped disclosure. CONTRACT.md section 5 has the manifest digesting
# these rather than printing them, for the same reason.
#
# EVERY CALL IS RECORDED, resolved or not, in a queryable structure - one dict
# per attempt, readable with <role>_env_report. ::pack_missing_env holds only
# the failures, which answers "can this pack load here"; the full log answers
# "which collateral did this run actually read", and it was the second question
# that mattered when two reports built from two different mounts were compared
# as though they described one thing.
#
# THE ESCAPE HATCH. FPGA_PACK_ALLOW_MISSING_ENV=1 - or the role-specific
# FPGA_PART_ALLOW_MISSING_ENV / FPGA_BOARD_ALLOW_MISSING_ENV - lets a pack load
# on a host with none of its site collateral: a docs build, a CI lint,
# fpga-flow-check, and above all fpga-flow-part-probe, whose entire job is to
# report what this host cannot resolve. An unresolved value becomes the literal
# marker <unset:NAME>, which is greppable, is never a valid path, and cannot be
# mistaken for a resolved value the way "" can.
################################################################################

proc pack_allow_missing {role} {
    foreach v [list FPGA_[string toupper $role]_ALLOW_MISSING_ENV \
                    FPGA_PACK_ALLOW_MISSING_ENV] {
        if {[info exists ::env($v)] && $::env($v) ne "" && $::env($v) ne "0"} {
            return 1
        }
    }
    return 0
}

proc pack_env {role name purpose} {
    if {[info exists ::env($name)] && $::env($name) ne ""} {
        lappend ::pack_env_log($role) \
            [list name $name purpose $purpose value $::env($name) status resolved]
        return $::env($name)
    }
    if {[pack_allow_missing $role]} {
        lappend ::pack_missing_env($role) [list $name $purpose]
        lappend ::pack_env_log($role) \
            [list name $name purpose $purpose value "<unset:$name>" status missing]
        return "<unset:$name>"
    }
    lappend ::pack_env_log($role) \
        [list name $name purpose $purpose value "" status error]
    error "$role pack '[pack_pack_name $role]': environment variable $name is\
           not set.\
         \n  It locates: $purpose\
         \n  NOTHING DEFAULTS IT. A guess here is a path that resolves on one\
         \n  machine and fails silently-looking on every other.\
         \n  Set it in your shell, or export it from fpga/design.mk:\
         \n      export $name ?= /path/to/it\
         \n  To load this pack WITHOUT that collateral - a docs build, a syntax\
         \n  check, or fpga-flow-part-probe reporting what is missing - set\
         \n  FPGA_PACK_ALLOW_MISSING_ENV=1 and the value becomes the literal\
         \n  marker <unset:$name>."
}

# Every resolution attempt, as a list of dicts. Queryable rather than printable
# on purpose: fpga-flow-part-probe wants the distinct VARIABLE NAMES, the
# manifest wants digests of the values, and a human wants the purposes.
proc pack_env_report {role} { return $::pack_env_log($role) }

# Where a pack writes something it derived. NEVER the source tree: derived
# vendor collateral inherits the vendor's status, and a run directory is
# already treated as disposable and already gitignored.
#
# Off a run - fpga-flow-part-get, fpga-flow-part-probe, a docs build - there is
# no run directory, and refusing there would break every tool that only wants to
# ask the pack a question. Those get a per-user scratch directory outside any
# checkout, which is the same guarantee for the same reason.
proc pack_derived_dir {role} {
    foreach {var sub} [list FPGA_WORK_DIR $role FPGA_RUN_DIR work/$role] {
        if {[info exists ::env($var)] && $::env($var) ne ""} {
            set d [file join $::env($var) {*}[file split $sub]]
            if {![catch {file mkdir $d}]} { return $d }
        }
    }
    set tmp [expr {[info exists ::env(TMPDIR)] && $::env(TMPDIR) ne ""
                   ? $::env(TMPDIR) : "/tmp"}]
    set who [expr {[info exists ::env(USER)] ? $::env(USER) : "nobody"}]
    set d [file join $tmp fpga-flow-$role-$who [pack_pack_name $role]]
    if {[catch {file mkdir $d} e]} {
        error "$role pack '[pack_pack_name $role]': nowhere to write derived\
               collateral.\
             \n  Tried \$FPGA_WORK_DIR, \$FPGA_RUN_DIR and $d ($e).\
             \n  Derived files carry vendor data, so they are never written into\
             \n  the toolkit or the project checkout."
    }
    return $d
}


################################################################################
# 3b. DERIVED VALUES: <role>_defer
#
# A vendor number is the vendor's. A pack that copies one into Tcl has taken a
# snapshot that goes stale, silently, on the next tool release - because nothing
# ever re-checks a number in a comment. So a pack that can read the value reads
# it, at load time, from the file the site already has.
#
# <role>_defer <key> <script> is what it says when it CANNOT.
#
# The script runs when the key is first READ, not when the pack loads, because
# most runs never touch most keys and a run should not fail on collateral it was
# never going to use. If the script cannot produce a value the key stays UNSET
# WITH A RECORDED REASON:
#
#     <role>_has -> 0
#     <role>_get -> an error naming the file, quoting the script's own message
#
# THE FAILURE MODE THIS PREVENTS is not a crash. It is an EMPTY value that
# validates: a primitive name nobody filled in instantiates nothing and reports
# success. A derived key is therefore either derived, or absent with a reason -
# never present and empty.
#
# A deferred key is NOT counted as missing by the validator. That is not a hole:
# the pack has said what it could not obtain and why, <role>_check_files reports
# every deferral, and a read of one is an error rather than a wrong answer.
################################################################################

proc pack_defer {role args} {
    # TWO KINDS OF DEFERRAL, AND THE PROBE'S VERDICT TURNS ON WHICH.
    #
    #   (default)    HOST-CONTINGENT. The pack tried to read something on THIS
    #                machine and could not. Another host resolves it. It is a
    #                collateral failure, <role>_check_files counts it, and
    #                fpga-flow-part-probe goes red: mounting a filesystem or
    #                exporting a variable will fix it.
    #
    #   -permanent   A GAP IN THE DATA, not in the host. Nothing anyone can
    #                mount or export will resolve it: the number is not in the
    #                source this pack reads, and saying so is the whole value of
    #                the entry. check_files REPORTS it and does not count it,
    #                and the probe stays green while enumerating it.
    #
    # WHY THE SECOND EXISTS. CONTRACT.md section 0 requires an unmeasured number
    # to be emitted as the literal token `unmeasured`, never as 0 and never
    # omitted, and section 5 requires a green run to enumerate what it did not
    # measure. A permanent deferral is the pack-level form of exactly that. If
    # it made the probe red, every pack with an honest gap in it would be red
    # for ever, `make part-probe` would be a check nobody could pass, and the
    # first response would be to delete the deferral and write a plausible
    # number - which is the defect this whole file exists to prevent.
    set scope host
    while {[llength $args] > 2} {
        set flag [lindex $args 0]
        set args [lrange $args 1 end]
        switch -- $flag {
            -permanent { set scope permanent }
            -host      { set scope host }
            default {
                error "${role}_defer: unknown option '$flag'.\
                     \n  Usage: ${role}_defer ?-permanent? <key> <script>"
            }
        }
    }
    if {[llength $args] != 2} {
        error "${role}_defer: wrong number of arguments.\
             \n  Usage: ${role}_defer ?-permanent? <key> <script>"
    }
    foreach {key script} $args break

    set k [pack_key $role $key]
    if {![info exists ::pack_schema($role,$k)]} {
        error "${role}_defer: unknown key '$key'. Nearest: [pack_nearest $role $key]"
    }
    if {[info exists ::pack_val($role,$k)]} {
        error "${role}_defer: '$k' is already set to '$::pack_val($role,$k)'.\
             \n  A key is derived or deferred, never both."
    }
    if {[info exists ::pack_defer_script($role,$k)]} {
        error "${role}_defer: '$k' is already deferred by this pack."
    }
    set ::pack_defer_script($role,$k) $script
    set ::pack_defer_state($role,$k)  pending
    set ::pack_defer_why($role,$k)    ""
    set ::pack_defer_scope($role,$k)  $scope
    lappend ::pack_defer_order($role) $k
}

# Every key this pack has declared it CANNOT obtain from anywhere, with the
# reason. A green probe still prints these, because a run that does not say what
# it did not measure has not said what it measured either.
proc pack_gaps {role} {
    set out {}
    foreach k $::pack_defer_order($role) {
        if {$::pack_defer_scope($role,$k) ne "permanent"} { continue }
        if {[pack_resolve_deferred $role $k]} { continue }
        lappend out [list $k [regsub -all {\s+} $::pack_defer_why($role,$k) " "]]
    }
    return $out
}

proc pack_is_deferred {role key} {
    return [info exists ::pack_defer_script($role,[pack_key $role $key])]
}

# Run a pending deferral exactly once. Returns 1 when the key now has a value.
proc pack_resolve_deferred {role key} {
    set k [pack_key $role $key]
    if {![info exists ::pack_defer_script($role,$k)]} { return 0 }
    switch -- $::pack_defer_state($role,$k) {
        resolved { return 1 }
        failed   { return 0 }
    }
    set ::pack_defer_state($role,$k) failed   ;# in case the script itself throws
    # A DEFERRAL SCRIPT ENDS IN `return`, because that is how the template tells
    # a pack author to write one - and `return` inside an uplevel'd script comes
    # back from catch as code 2 (TCL_RETURN), not code 0. Testing `[catch ...]`
    # for truth therefore reads EVERY successful deferral as a failure, and the
    # "reason" it then records is the value the script returned: the probe
    # reported a perfectly resolved vendor path as UNRESOLVED, with the path
    # itself as the explanation. Measured here on 2026-09-08, and the reason
    # this compares the code rather than testing it.
    set code [catch {uplevel #0 $::pack_defer_script($role,$k)} out]
    if {$code == 1} {                            ;# TCL_ERROR - the intended failure
        set ::pack_defer_why($role,$k) $out
        return 0
    }
    if {$code != 0 && $code != 2} {              ;# break / continue at top level
        set ::pack_defer_why($role,$k) \
            "the deferred script exited with Tcl code $code (break, continue or\
             a custom code) rather than returning a value or raising an error.\
             A deferral either produces a value or says why it cannot."
        return 0
    }
    if {[string trim $out] eq ""} {
        set ::pack_defer_why($role,$k) \
            "the deferred script returned an EMPTY value. An empty value is not\
             a value: it propagates, it concatenates into a path, and it\
             satisfies a truth test in the wrong direction. The script must\
             return a value or raise."
        return 0
    }
    set ::pack_val($role,$k)         $out
    set ::pack_defer_state($role,$k) resolved
    set ::pack_defer_why($role,$k)   ""
    return 1
}

# The deferral record as a printable sentence. Empty when the key is not
# deferred or resolved cleanly.
proc pack_deferral_note {role key} {
    set k [pack_key $role $key]
    if {![info exists ::pack_defer_script($role,$k)]} { return "" }
    if {$::pack_defer_state($role,$k) eq "resolved"} { return "" }
    set why [regsub -all {\s+} $::pack_defer_why($role,$k) " "]
    if {[string trim $why] eq ""} { set why "(not yet resolved)" }
    if {$::pack_defer_scope($role,$k) eq "permanent"} {
        return "The pack declares this value NOT OBTAINABLE - not here and not\
                on any other host - and says why:\
              \n      $why\
              \n  This is a recorded gap, not a broken machine: mounting\
              \n  something or exporting a variable will not change it. Either\
              \n  the value is a decision the DESIGN has to make, or somebody\
              \n  has to measure it and extend the pack."
    }
    return "It is DERIVED, and on this host it could not be obtained, so the\
            pack left it UNSET rather than guess:\
          \n      $why\
          \n  The pack does not carry a copy of that value on purpose - a copy\
          \n  goes stale against the source and nothing ever re-checks it.\
          \n  Another host with that collateral mounted resolves it."
}


################################################################################
# 3c. READING
#
# <role>_get errors rather than returning "". CONTRACT.md section 8 requires it
# and the reason is specific: an empty primitive name silently instantiates
# nothing, an empty frequency constrains nothing, and an empty path concatenates
# into a plausible wrong one. Every one of those is a run that finishes and is
# wrong. An error is a run that stops.
################################################################################

proc pack_get {role key} {
    set k [pack_key $role $key]
    if {![info exists ::pack_schema($role,$k)]} {
        error "${role}_get: unknown key '$key'. Nearest: [pack_nearest $role $key]"
    }
    if {![info exists ::pack_val($role,$k)]} { pack_resolve_deferred $role $k }
    if {[info exists ::pack_val($role,$k)]} { return $::pack_val($role,$k) }

    foreach {req type group desc} $::pack_schema($role,$k) break
    set note [pack_deferral_note $role $k]
    if {$note ne ""} {
        error "${role}_get: '$k' is not set by $role pack\
               '[pack_pack_name $role]'.\
             \n  What it is for: $desc\
             \n  $note"
    }
    error "${role}_get: '$k' is not set by $role pack '[pack_pack_name $role]'.\
         \n  What it is for: $desc\
         \n  It is an OPTIONAL key, and an unset optional is an ERROR here\
         \n  rather than an empty string - an empty value would flow onward and\
         \n  configure something to do nothing.\
         \n  Test it with '${role}_has $k', or supply your own default with\
         \n  '${role}_opt $k <default>', and say at that call site why a default\
         \n  is defensible.\
         \n  pack file: $::pack_file($role)"
}

proc pack_has {role key} {
    set k [pack_key $role $key]
    if {![info exists ::pack_schema($role,$k)]} {
        error "${role}_has: unknown key '$key'. Nearest: [pack_nearest $role $key]"
    }
    if {[info exists ::pack_val($role,$k)]} { return 1 }
    return [pack_resolve_deferred $role $k]
}

# Read with a fallback. For genuinely optional behaviour only - never to paper
# over a key the caller actually depends on.
proc pack_opt {role key default} {
    if {[pack_has $role $key]} { return [pack_get $role $key] }
    return $default
}

# "Absent" means the pack neither states this key nor explains why it could not
# derive it. A deferred key is absent from ::pack_val too, but it is absent WITH
# A REASON and check_files reports every one, so the validator does not report
# it a second time as an omission.
proc pack_absent {role key} {
    set k [pack_key $role $key]
    return [expr {![info exists ::pack_val($role,$k)]
                  && ![info exists ::pack_defer_script($role,$k)]}]
}

proc pack_keys {role {group ""}} {
    set out {}
    foreach k $::pack_schema_order($role) {
        foreach {req type g desc} $::pack_schema($role,$k) break
        if {$group eq "" || $g eq $group} { lappend out $k }
    }
    return $out
}

proc pack_pack_name {role} {
    foreach k [list ${role}_name part_name board_name] {
        if {[info exists ::pack_val($role,$k)]} { return $::pack_val($role,$k) }
    }
    if {$::pack_dir($role) ne ""} { return [file tail $::pack_dir($role)] }
    return "<no $role pack loaded>"
}
proc pack_pack_file {role} { return $::pack_file($role) }

# Suggest what the author probably meant. A typo is only useful as an error if
# it points at the right key.
proc pack_nearest {role key} {
    set hits {}
    foreach k $::pack_schema_order($role) {
        if {[string match "*$key*" $k] || [string match "*$k*" $key]} {
            lappend hits $k
        }
    }
    if {![llength $hits]} {
        # A shared prefix catches a truncated or mistyped tail, which is what a
        # copy-paste error usually leaves behind.
        set stem [string range $key 0 3]
        foreach k $::pack_schema_order($role) {
            if {[string match "$stem*" $k]} { lappend hits $k }
        }
    }
    if {![llength $hits]} {
        # Last resort: the aliases, so a pack using a spelling this API does not
        # know is told which spellings it does.
        foreach a [array names ::pack_alias_spec ${role},*] {
            set spelling [string range $a [expr {[string length $role] + 1}] end]
            if {[string match "*$stem*" $spelling]} {
                lappend hits "$spelling (alias for $::pack_alias_spec($a))"
            }
        }
    }
    if {![llength $hits]} { return "(none - see ${role}_keys)" }
    return [join [lrange [lsort $hits] 0 5] ", "]
}


################################################################################
# 4. THE LOADER
#
# <role>_load takes a pack directory, a pack file, or a bare pack name resolved
# against the role's root. It sources the pack as plain Tcl - packs may compute,
# glob and read vendor files at load time - and then validates. It never returns
# on an invalid pack.
#
# AN UNKNOWN PACK IS A HARD ERROR THAT ENUMERATES WHAT IS INSTALLED, by scanning
# for directories containing the role's file. CONTRACT.md section 0 makes that
# binding: never hardcode a list a directory already knows. The reference
# toolkit hardcodes a five-entry whitelist over a seven-entry directory and has
# two undocumented override points as a result.
################################################################################

# Where packs of this role live. ONE OF THE TWO PLACES the engine branches on
# the role name, because the answer is structural: part packs ship in the
# toolkit, board packs ship in the project, and CONTRACT.md section 1 is that
# split. Returns a de-duplicated list; all of them are scanned for the error
# message, and the first one holding the pack wins.
proc pack_roots {role spec} {
    set roots {}
    switch -- $role {
        part {
            if {[info exists ::env(FPGA_FLOW_DIR)]} {
                lappend roots [file join $::env(FPGA_FLOW_DIR) part]
            }
            lappend roots $::pack_api_dir
        }
        board {
            if {[info exists ::env(FPGA_DIR)]} {
                lappend roots [file join $::env(FPGA_DIR) board]
            }
            if {[info exists ::env(FPGA_BOARD_DIR)]} {
                lappend roots [file dirname $::env(FPGA_BOARD_DIR)]
            }
            # A board pack given as a path tells us where its siblings are, and
            # a project's board directory is not somewhere this toolkit may
            # assume - it must never reach into a project it was not pointed at.
            if {$spec ne "" && [file dirname $spec] ne "."} {
                lappend roots [file dirname [file normalize $spec]]
            }
        }
    }
    set out {}
    foreach r $roots {
        if {[lsearch -exact $out $r] < 0 && [file isdirectory $r]} { lappend out $r }
    }
    return $out
}

# Every installed pack under a root: a directory containing the role's file.
# Listing the root itself would offer README.md and pack_api.tcl as things to
# choose between.
proc pack_installed {role root} {
    set have {}
    foreach d [lsort [glob -nocomplain -directory $root -type d *]] {
        if {[file isfile [file join $d $::pack_file_name($role)]]} {
            lappend have [file tail $d]
        }
    }
    return $have
}

proc pack_load {role spec {root ""}} {
    set fname $::pack_file_name($role)
    if {$root ne ""} {
        set roots [list $root]
    } else {
        set roots [pack_roots $role $spec]
    }

    # Resolve, most specific first.
    set file ""
    if {[file isfile $spec]} {
        set file [file normalize $spec]
    } elseif {[file isdirectory $spec] && [file isfile [file join $spec $fname]]} {
        set file [file normalize [file join $spec $fname]]
    } else {
        foreach r $roots {
            if {[file isfile [file join $r $spec $fname]]} {
                set file [file normalize [file join $r $spec $fname]]
                break
            }
        }
    }

    if {$file eq ""} {
        set msg "${role}_load: no $role pack '$spec'.\
               \n  Looked for:\
               \n      $spec\
               \n      [file join $spec $fname]"
        foreach r $roots { append msg "\n      [file join $r $spec $fname]" }
        if {![llength $roots]} {
            append msg "\n  NO PACK ROOT EXISTS ON THIS HOST. For a $role pack the\
                        \n  roots are [expr {$role eq {part}
                            ? {$FPGA_FLOW_DIR/part and the directory holding this API}
                            : {$FPGA_DIR/board, $FPGA_BOARD_DIR's parent, and the\
                               directory the spec names}}]."
        }
        foreach r $roots {
            set have [pack_installed $role $r]
            append msg "\n  Installed under $r:\
                        \n      [expr {[llength $have] ? [join $have {, }] : {(none)}}]"
        }
        append msg "\n  Nothing is guessed here. Name one of those, or point at a\
                    \n  pack directory of your own; part/README.md is the\
                    \n  checklist for writing one."
        error $msg
    }

    set ::pack_file($role) $file
    set ::pack_dir($role)  [file dirname $file]

    # A pack is plain Tcl and may compute values, so source it rather than parse
    # it. Any error inside is reported with the pack path attached - a sourced
    # file otherwise reports a bare line number against no file name.
    if {[catch {uplevel #0 [list source $file]} m]} {
        error "${role}_load: $role pack '$spec' failed to load.\
             \n  file:  $file\
             \n  error: $m"
    }

    pack_validate $role
    return $::pack_dir($role)
}


################################################################################
# 5. THE VALIDATOR
#
# COLLECTS EVERY PROBLEM AND REPORTS THEM TOGETHER. One-at-a-time validation
# turns a five-key mistake into five edit-and-rerun cycles, and the cycles are
# where people give up and start guessing. CONTRACT.md section 8 requires it.
#
# Four passes, in this order because each depends on the last having been
# collected rather than raised:
#
#   5a  required keys, types, closed value sets
#   5b  conditional cascades - keys required only in a given configuration
#   5c  cross-checks - values individually well-formed but inconsistent with
#       each other. ALL of them run; none returns early. A pack with three
#       inconsistencies is told about three, because the second is very often
#       the explanation for the first.
#   5d  the report
################################################################################

proc pack_cascade_holds {role key op} {
    set k [pack_key $role $key]
    if {![info exists ::pack_val($role,$k)]} { return 0 }
    set v $::pack_val($role,$k)
    if {$op eq "set"} { return 1 }
    if {$op eq "true"} {
        return [expr {[string is boolean -strict $v] && $v}]
    }
    if {[string index $op 0] eq ">"} {
        set n [string range $op 1 end]
        return [expr {[string is double -strict $v] && $v > $n}]
    }
    error "pack_api.tcl: cascade operator '$op' is not one of: set, true, >N"
}

proc pack_validate {role} {
    set problems {}
    set name [pack_pack_name $role]

    # --- 5a. required keys, types, enums -------------------------------------
    foreach k $::pack_schema_order($role) {
        foreach {req type group desc} $::pack_schema($role,$k) break

        if {![info exists ::pack_val($role,$k)]} {
            if {$req eq "yes" && ![pack_is_deferred $role $k]} {
                lappend problems "MISSING required key '$k' ($group)\
                                \n         what it is for: $desc"
            }
            continue
        }

        set v $::pack_val($role,$k)
        switch -- $type {
            str {
                if {[string trim $v] eq ""} {
                    lappend problems "EMPTY '$k' - a blank value is not the same\
                        as omitting the key. An omitted key errors when read; a\
                        \n         blank one is READ AS A VALUE and configures\
                                   something to do nothing. Unset it, or give it\
                        \n         a value. ($desc)"
                }
            }
            int {
                if {![string is integer -strict $v]} {
                    lappend problems "BAD TYPE '$k' = '$v' - expected an integer."
                }
            }
            num {
                if {![string is double -strict $v]} {
                    lappend problems "BAD TYPE '$k' = '$v' - expected a number."
                }
            }
            bool {
                if {![string is boolean -strict $v]} {
                    lappend problems "BAD TYPE '$k' = '$v' - expected a boolean\
                                      (0/1/true/false)."
                }
            }
            list - paths {
                if {[catch {llength $v} n]} {
                    lappend problems "BAD TYPE '$k' - not a well-formed Tcl list: $n"
                } elseif {$n == 0
                          && [lsearch -exact $::pack_empty_ok($role) $k] < 0} {
                    lappend problems "EMPTY LIST '$k' - an empty list is a silent\
                        no-op downstream. If 'none' is the answer, say so in a\
                        \n         ${role}_note and leave the key unset. ($desc)"
                }
            }
            path {
                if {[string trim $v] eq ""} {
                    lappend problems "EMPTY PATH '$k'. ($desc)"
                }
            }
        }

        if {[info exists ::pack_enum_spec($role,$k)]} {
            if {[lsearch -exact $::pack_enum_spec($role,$k) $v] < 0} {
                lappend problems "BAD VALUE '$k' = '$v'.\
                    \n         It must be one of: $::pack_enum_spec($role,$k)\
                    \n         This is a CLOSED set: a value outside it is not a\
                               new option, it is a typo that reaches a tool as\
                    \n         something else. ($desc)"
            }
        }
    }

    # --- 5b. conditional cascades --------------------------------------------
    foreach row $::pack_cascade_spec($role) {
        foreach {trig op needs why} $row break
        if {![pack_cascade_holds $role $trig $op]} { continue }
        set shown [expr {$op eq "set" ? "is set" :
                        ($op eq "true" ? "is true" : "is $op")}]
        foreach k $needs {
            if {![pack_absent $role $k]} { continue }
            foreach {req type group desc} $::pack_schema($role,$k) break
            lappend problems "MISSING '$k', which '$trig' $shown makes required.\
                \n         what it is for: $desc\
                \n         why the pairing: [regsub -all {\s+} $why { }]"
        }
    }

    # --- 5c. cross-checks ----------------------------------------------------
    if {$role eq "part"}  { pack_crosscheck_part  problems }
    if {$role eq "board"} { pack_crosscheck_board problems }

    # --- 5d. report ----------------------------------------------------------
    if {[llength $problems]} {
        set n [llength $problems]
        set msg "$role pack '$name' is INCOMPLETE or INCONSISTENT -\
                 $n problem[expr {$n == 1 ? {} : {s}}].\n"
        append msg "  pack file: $::pack_file($role)\n"
        set i 0
        foreach p $problems {
            incr i
            append msg "\n  [format %2d $i]. $p"
        }
        append msg "\n\n  EVERY problem found is listed above, not just the first:\
                    \n  fixing them one run at a time is where people give up and\
                    \n  start guessing. Nothing has been run.\
                    \n  part/README.md is the checklist."
        error $msg
    }
    return 1
}


################################################################################
# 6. THE TRAP THIS PACK EXISTS TO MAKE EXPRESSIBLE
#
# VIVADO SILENTLY RETARGETS LEGACY PRIMITIVES. Measured on this host with
# Vivado v2024.1, create_cell on a linked design:
#
#   on zynquplus (xck26)   MMCME2_ADV -> MMCME4_ADV      PLLE2_ADV -> MMCME4_ADV
#                          IDELAYE2   -> IDELAYE3        BUFHCE    -> BUFGCTRL
#                          RAMB36E1   -> RAMB36E2        DSP48E1   -> DSP48E2
#   on kintexu  (xcku115)  MMCME2_ADV -> MMCME3_ADV      PLLE2_ADV -> MMCME3_ADV
#
# Each of those succeeds. Each prints one [Coretcl 2-1024] warning into a log
# with thousands of lines. Two of them are worse than a rename:
#
#   * PLLE2_ADV does not become the local PLL. It becomes the MMCM. A design
#     that believes it is spending one of eight PLLs on xck26 is spending one of
#     four MMCMs, and the resource it thought it was saving was never touched.
#   * BUFHCE becomes BUFGCTRL, which HAS NO CLOCK ENABLE. The clock gating the
#     design asked for is silently gone.
#
# A part pack that names a legacy primitive therefore describes a device that
# does not exist, and every consumer of that pack inherits the error. So:
#
#   * every *_primitive key states the PHYSICAL primitive - the one with a real
#     site or BEL, per the census in primitive_sites / primitive_bels
#   * primitives_retargeted lists what is merely ACCEPTED, as {requested actual}
#   * the cross-check below refuses a pack that names a merely-accepted or a
#     rejected primitive in a physical key, and says what it would really get
#
# That is the check. It is cheap, it runs at load, and it is the difference
# between a pack that is wrong and a pack that says so.
################################################################################

proc pack_crosscheck_part {problems_var} {
    upvar 1 $problems_var problems
    set role part

    # ---- the physical / accepted distinction --------------------------------
    array set retarget {}
    if {[info exists ::pack_val(part,primitives_retargeted)]} {
        set pairs $::pack_val(part,primitives_retargeted)
        if {[llength $pairs] % 2} {
            lappend problems "primitives_retargeted has [llength $pairs] element(s),\
                which is not an even number.\
                \n         It is {requested actual} PAIRS: the name a design asks\
                           for, and the cell it silently becomes. A flat list of\
                \n         names would record that something was retargeted and\
                           lose the only part that matters - what to."
        } else {
            foreach {from to} $pairs {
                if {$from eq $to} {
                    lappend problems "primitives_retargeted says '$from' retargets\
                        to itself. A primitive that resolves to its own name is\
                        \n         not retargeted; it is physical, and listing it\
                                   here would make the validator reject every key\
                        \n         that correctly names it."
                    continue
                }
                set retarget($from) $to
            }
        }
    }
    set rejected [pack_opt part primitives_rejected {}]

    foreach k $::pack_physical_primitive_keys {
        if {![info exists ::pack_val(part,$k)]} { continue }
        foreach {req type group desc} $::pack_schema(part,$k) break
        foreach prim $::pack_val(part,$k) {
            if {[info exists retarget($prim)]} {
                lappend problems "'$k' names '$prim', which this pack's own\
                    primitives_retargeted says is only ACCEPTED here - Vivado\
                    \n         silently turns it into '$retarget($prim)'.\
                    \n         There is no $prim site or BEL on this device. A\
                               *_primitive key states the PHYSICAL primitive, so\
                    \n         this should be '$retarget($prim)' - or, if that is\
                               genuinely not what this key means, the pack is\
                    \n         wrong about the retarget.\
                    \n         what the key is for: $desc"
            }
            if {[lsearch -exact $rejected $prim] >= 0} {
                lappend problems "'$k' names '$prim', which this pack's own\
                    primitives_rejected says this architecture REFUSES\
                    \n         (\[Coretcl 2-1475\], 'not supported in the current\
                               architecture'). A design built on this pack would\
                    \n         fail at elaboration, which is the good outcome and\
                               still the wrong pack.\
                    \n         what the key is for: $desc"
            }
        }
    }
    foreach prim $rejected {
        if {[info exists retarget($prim)]} {
            lappend problems "'$prim' is in BOTH primitives_rejected and\
                primitives_retargeted. It cannot be both refused and silently\
                \n         accepted; one of the two measurements is of a\
                           different part."
        }
    }

    # A census is evidence, so it has to be shaped like one.
    foreach k {primitive_sites primitive_bels io_bank_types} {
        if {![info exists ::pack_val(part,$k)]} { continue }
        set v $::pack_val(part,$k)
        if {[llength $v] % 2} {
            lappend problems "'$k' has [llength $v] element(s), which is not an\
                even number - it is {name count} pairs."
            continue
        }
        if {$k eq "io_bank_types"} { continue }
        foreach {n c} $v {
            if {![string is integer -strict $c] || $c < 0} {
                lappend problems "'$k' gives '$n' a count of '$c'. A census\
                    entry is a non-negative integer; a count that is not a\
                    \n         number is a census that was transcribed, not read."
            }
        }
    }

    # ---- the part string ----------------------------------------------------
    # A PART STRING MISSING ITS SPEED GRADE selects a different part, or none,
    # and "none" arrives as an elaboration failure minutes into a run. The three
    # pieces are stated separately AND together, so they can be checked against
    # each other - which is the only reason to state a thing twice.
    if {[info exists ::pack_val(part,part_name)]} {
        set pn $::pack_val(part,part_name)
        foreach {k what} {device {the device} package {the package}} {
            if {[info exists ::pack_val(part,$k)]
                && [string first $::pack_val(part,$k) $pn] < 0} {
                lappend problems "part_name '$pn' does not contain $what\
                    '$::pack_val(part,$k)' that '$k' states.\
                    \n         One of the two is wrong, and the part string is\
                               what reaches the tool."
            }
        }
        if {[info exists ::pack_val(part,device)]
            && ![string match "$::pack_val(part,device)*" $pn]} {
            lappend problems "part_name '$pn' does not START with the device\
                '$::pack_val(part,device)'."
        }
        if {[info exists ::pack_val(part,speed_grade)]} {
            set sg $::pack_val(part,speed_grade)
            if {[string index $sg 0] ne "-"} {
                lappend problems "speed_grade '$sg' does not begin with a dash.\
                    \n         It is stated as it appears in the part string,\
                               e.g. -1 or -2LV, so that the two can be compared\
                    \n         at all."
            } elseif {[string first $sg $pn] < 0} {
                lappend problems "part_name '$pn' does not contain the speed\
                    grade '$sg'.\
                    \n         A part string missing its speed grade resolves to\
                               a DIFFERENT part or to none, and none is reported\
                    \n         as an elaboration failure several minutes in."
            }
        }
        if {[info exists ::pack_val(part,temp_grade)]} {
            set tg $::pack_val(part,temp_grade)
            if {![string match -nocase "*-$tg" $pn]} {
                lappend problems "temp_grade '$tg' is stated but part_name '$pn'\
                    does not end with '-$tg'.\
                    \n         A device whose part string carries no temperature\
                               grade must leave the key UNSET, not blank and not\
                    \n         guessed: an absent grade and a commercial grade\
                               are different claims about the same silicon."
            }
        }
    }

    # ---- capacity consistency ----------------------------------------------
    # Each 36Kb block RAM is two 18Kb halves on every architecture this toolkit
    # addresses. Utilisation is reported in both units and the two numbers get
    # compared without anyone noticing the denominators differ, so a pack that
    # states both has to state them consistently.
    if {[info exists ::pack_val(part,brams)] && [info exists ::pack_val(part,bram18s)]
        && [string is integer -strict $::pack_val(part,brams)]
        && [string is integer -strict $::pack_val(part,bram18s)]
        && $::pack_val(part,bram18s) != 2 * $::pack_val(part,brams)} {
        lappend problems "bram18s ($::pack_val(part,bram18s)) is not twice brams\
            ($::pack_val(part,brams)).\
            \n         A 36Kb block is two 18Kb halves. If this device really\
                       breaks that, say so in a part_note and this check is the\
            \n         thing to change - do not adjust a number to satisfy it."
    }

    if {[info exists ::pack_val(part,slrs)] && [info exists ::pack_val(part,slr_topology)]
        && [string is integer -strict $::pack_val(part,slrs)]
        && [llength $::pack_val(part,slr_topology)] != $::pack_val(part,slrs)} {
        lappend problems "slr_topology lists\
            [llength $::pack_val(part,slr_topology)] SLR(s)\
            ($::pack_val(part,slr_topology)) but slrs says\
            $::pack_val(part,slrs).\
            \n         A floorplan written against the shorter list silently\
                       leaves a region of the device unaddressed."
    }

    foreach {flag countk what} {
        has_mmcm         mmcm_count   {an MMCM}
        idelay_available idelay_count {an input delay element}
    } {
        if {[info exists ::pack_val(part,$flag)]
            && [string is boolean -strict $::pack_val(part,$flag)]
            && $::pack_val(part,$flag)
            && [info exists ::pack_val(part,$countk)]
            && [string is integer -strict $::pack_val(part,$countk)]
            && $::pack_val(part,$countk) == 0} {
            lappend problems "'$flag' is true but '$countk' is 0.\
                \n         The pack says the device has $what and then says there\
                           are none of them. A design gated on the flag would ask\
                \n         for a resource the same pack says does not exist."
        }
    }

    # IO bank numbers: silicon. IO bank VOLTAGES: a board fact, and not here.
    if {[info exists ::pack_val(part,io_banks)]} {
        set seen {}
        foreach b $::pack_val(part,io_banks) {
            if {![string is integer -strict $b]} {
                lappend problems "io_banks contains '$b', which is not a bank\
                    NUMBER.\
                    \n         Bank numbers are silicon and belong here; bank\
                               voltages are a PCB fact and belong in the board\
                    \n         pack's io_voltage_by_bank."
            } elseif {[lsearch -exact $seen $b] >= 0} {
                lappend problems "io_banks lists bank $b twice."
            } else {
                lappend seen $b
            }
        }
        if {[info exists ::pack_val(part,ps_io_banks)]} {
            foreach b $::pack_val(part,ps_io_banks) {
                if {[lsearch -exact $seen $b] < 0} {
                    lappend problems "ps_io_banks names bank $b, which is not in\
                        io_banks. io_banks is every bank the device has, PS\
                        \n         included; ps_io_banks says which of them the\
                                   PS owns."
                }
            }
        }
        if {[info exists ::pack_val(part,io_bank_types)]
            && [llength $::pack_val(part,io_bank_types)] % 2 == 0} {
            foreach {b t} $::pack_val(part,io_bank_types) {
                if {[lsearch -exact $seen $b] < 0} {
                    lappend problems "io_bank_types describes bank $b, which is\
                        not in io_banks."
                }
            }
        }
    }

    # ---- the IDELAY reference clock ----------------------------------------
    # The range is what the install actually states; the single figure is what a
    # design must drive. Where a pack has both, the second has to be inside the
    # first - a reference clock outside the model's own legal range is a
    # calibration that is wrong by construction and reports nothing.
    set ranges [pack_opt part idelay_ref_freq_range_hz {}]
    if {[llength $ranges]} {
        if {[llength $ranges] % 2} {
            lappend problems "idelay_ref_freq_range_hz has [llength $ranges]\
                element(s); it is {min max} PAIRS in Hz. On 7-series the legal\
                \n         set is three disjoint bands, which is exactly why this\
                           is a list of pairs and not two numbers."
        } else {
            foreach {lo hi} $ranges {
                if {![string is double -strict $lo] || ![string is double -strict $hi]} {
                    lappend problems "idelay_ref_freq_range_hz has a non-numeric\
                        bound: {$lo $hi}."
                } elseif {$lo > $hi} {
                    lappend problems "idelay_ref_freq_range_hz has a band whose\
                        minimum $lo is above its maximum $hi."
                } elseif {$hi < 1000000} {
                    lappend problems "idelay_ref_freq_range_hz band {$lo $hi}\
                        looks like MHz, not Hz.\
                        \n         Every frequency in these packs is in Hz. A\
                                   megahertz number in a hertz key is off by a\
                        \n         million and every check downstream passes."
                }
            }
            foreach k {idelay_ref_freq_hz idelay_ref_freq_default_hz} {
                if {![info exists ::pack_val(part,$k)]} { continue }
                set f $::pack_val(part,$k)
                if {![string is double -strict $f]} { continue }
                set ok 0
                foreach {lo hi} $ranges {
                    if {[string is double -strict $lo] && [string is double -strict $hi]
                        && $f >= $lo && $f <= $hi} { set ok 1 }
                }
                if {!$ok} {
                    lappend problems "'$k' is $f Hz, which is outside every band\
                        in idelay_ref_freq_range_hz ($ranges).\
                        \n         The ranges are read from the primitive model's\
                                   own check, so a frequency outside them is one\
                        \n         the primitive itself rejects."
                }
            }
        }
    }
}

proc pack_crosscheck_board {problems_var} {
    upvar 1 $problems_var problems

    # A frequency in the wrong unit passes every other check in this flow. It is
    # compiled into the firmware AND constrains the fabric, so both halves are
    # consistently wrong and the board simply misbehaves.
    foreach k {sys_clk_freq_hz oscillator_hz} {
        if {![info exists ::pack_val(board,$k)]} { continue }
        set v $::pack_val(board,$k)
        if {![string is integer -strict $v]} { continue }
        if {$v > 0 && $v < 100000} {
            lappend problems "'$k' is $v, which is far too small to be HERTZ -\
                it looks like MHz or kHz.\
                \n         This key is in Hz. 50 MHz is 50000000. The firmware is\
                           compiled with this number and the fabric is\
                \n         constrained with it, so both agree and both are wrong,\
                           and the symptom is every baud rate and timer being off\
                \n         by the same factor."
        }
        if {$v <= 0} {
            lappend problems "'$k' is $v. A clock frequency is positive."
        }
    }

    # The oscillator is what is on the PCB; the system clock is what the design
    # is closed at. They may differ by any ratio an MMCM can make - but a system
    # clock BELOW the oscillator with no MMCM is worth saying out loud, and one
    # EQUAL to it is worth recording as deliberate.
    if {[info exists ::pack_val(board,sys_clk_freq_hz)]
        && [info exists ::pack_val(board,oscillator_hz)]
        && [string is integer -strict $::pack_val(board,sys_clk_freq_hz)]
        && [string is integer -strict $::pack_val(board,oscillator_hz)]
        && $::pack_val(board,oscillator_hz) > 0
        && $::pack_val(board,sys_clk_freq_hz) == $::pack_val(board,oscillator_hz)} {
        # Not a problem - but the pack should have said so. A note is enough.
        if {![llength $::pack_notes(board)]} {
            lappend problems "sys_clk_freq_hz equals oscillator_hz\
                ($::pack_val(board,oscillator_hz)) and the pack carries no note.\
                \n         Driving the design straight from the crystal is a\
                           legitimate choice and an easy mistake, and the two keys\
                \n         are recorded separately precisely so a reader can tell\
                           which it was. Add a board_note saying it is deliberate."
        }
    }

    # The two fpgahub namespaces do not overlap. Identical names are the shape
    # of somebody filling in the second field from the first.
    if {[info exists ::pack_val(board,fpgahub_board)]
        && [info exists ::pack_val(board,fpgahub_target)]
        && $::pack_val(board,fpgahub_board) eq $::pack_val(board,fpgahub_target)} {
        lappend problems "fpgahub_board and fpgahub_target are both\
            '$::pack_val(board,fpgahub_board)'.\
            \n         THEY ARE DIFFERENT NAMESPACES: one is the LEASE scope\
                       (leases, queues, reservations) and the other is the\
            \n         PROGRAM scope (program, reset, actions). They do not\
                       overlap, and using one where the other is expected returns\
            \n         a 404 that does not say which was wrong."
    }

    # {bank volts} pairs, and a volt figure that is really volts.
    if {[info exists ::pack_val(board,io_voltage_by_bank)]} {
        set v $::pack_val(board,io_voltage_by_bank)
        if {[llength $v] % 2} {
            lappend problems "io_voltage_by_bank has [llength $v] element(s) -\
                it is {bank volts} pairs."
        } else {
            foreach {b volts} $v {
                if {![string is integer -strict $b]} {
                    lappend problems "io_voltage_by_bank names bank '$b', which\
                        is not a bank number."
                }
                if {![string is double -strict $volts]} {
                    lappend problems "io_voltage_by_bank gives bank $b the\
                        voltage '$volts', which is not a number."
                } elseif {$volts <= 0 || $volts > 5} {
                    lappend problems "io_voltage_by_bank gives bank $b\
                        $volts V. IO bank supplies here are volts (3.3, 1.8,\
                        \n         1.2), not millivolts and not a rail name."
                }
            }
        }
    }
    if {[info exists ::pack_val(board,connectors)]
        && [llength $::pack_val(board,connectors)] % 2} {
        lappend problems "connectors has\
            [llength $::pack_val(board,connectors)] element(s) - it is\
            {name description} pairs."
    }

    # The pack names a device; a board pack that does not spell the part the way
    # the toolkit's part packs do cannot be matched to one.
    if {[info exists ::pack_val(board,part)]
        && [string first " " $::pack_val(board,part)] >= 0} {
        lappend problems "part '$::pack_val(board,part)' contains a space. It is\
            ONE Vivado part string."
    }
}


################################################################################
# 7. USE-SITE ASSERTIONS
################################################################################

# A stage declares what it is about to use, at the top, before it does anything.
# Failing here costs a second; failing at the point of use costs whatever the
# stage had already run - which for an implementation stage is ninety minutes.
proc pack_require {role keys {who ""}} {
    if {$who eq ""} { set who [file tail [info script]] }
    set missing {}
    foreach key $keys {
        set k [pack_key $role $key]
        if {![info exists ::pack_schema($role,$k)]} {
            error "${role}_require: '$who' asks for unknown key '$key'.\
                   Nearest: [pack_nearest $role $key]"
        }
        if {![pack_has $role $k]} { lappend missing $k }
    }
    if {[llength $missing]} {
        set msg "$role pack '[pack_pack_name $role]' does not supply what '$who'\
                 needs.\n"
        foreach k $missing {
            foreach {req type group desc} $::pack_schema($role,$k) break
            append msg "\n  $k ($group, $req)\n      $desc"
            set note [pack_deferral_note $role $k]
            if {$note ne ""} { append msg "\n      $note" }
        }
        append msg "\n\n  Add these to $::pack_file($role), or run a stage that\
                    \n  does not need them."
        error $msg
    }
    return 1
}

# Can this host actually read everything the pack declares? Separate from
# validation because a pack is routinely loaded where its collateral is not
# mounted - a docs build, a lint, a CI syntax check. Call it once at the start
# of a real run, before a licence-hour is spent.
#
# It is also what fpga-flow-part-probe runs, which is why it reports rather than
# guesses: a missing file, an unresolved site variable and a deferral that
# cannot resolve are the SAME PROBLEM to whoever has to fix it, and they are
# reported in one list.
proc pack_check_files {role {strict 1}} {
    set missing {}
    set unresolved {}

    foreach k $::pack_schema_order($role) {
        if {![info exists ::pack_val($role,$k)]} { continue }
        foreach {req type group desc} $::pack_schema($role,$k) break
        # The <unset:VAR> marker can reach ANY key, not only a path one - a
        # string key built by concatenation carries it just the same, and a
        # value with a marker in it is not a value.
        # A value a pack COMPUTED may not be a well-formed Tcl list, and this
        # is a reporting path: it must not itself raise. Fall back to scanning
        # the whole value when it will not split.
        set parts $::pack_val($role,$k)
        if {[catch {llength $parts}]} { set parts [list $::pack_val($role,$k)] }
        foreach p $parts {
            if {[string match "*<unset:*" $p]} {
                lappend unresolved [list $k $p]
                continue
            }
            if {$type ne "path" && $type ne "paths"} { continue }
            if {![file exists $p]} { lappend missing [list $k $p $desc] }
        }
    }

    foreach pair $::pack_missing_env($role) {
        foreach {n purpose} $pair break
        lappend unresolved [list "env($n)" "<unset:$n> - $purpose"]
    }

    # A DEFERRAL is exactly as much of a collateral problem as a path that does
    # not exist, and it is invisible everywhere else: ::pack_val has no entry for
    # it at all. Resolve every one now - this is the call whose job is to find
    # out - and report the ones that cannot.
    set gaps {}
    foreach k $::pack_defer_order($role) {
        if {[pack_resolve_deferred $role $k]} { continue }
        set why [regsub -all {\s+} $::pack_defer_why($role,$k) " "]
        if {$::pack_defer_scope($role,$k) eq "permanent"} {
            lappend gaps [list $k $why]
        } else {
            lappend unresolved [list "$k (derived)" $why]
        }
    }

    # A PERMANENT GAP IS NOT A HOST FAILURE. It is reported - always, and beside
    # the failures when there are any - and it does not make this return false.
    # See pack_defer for why that distinction is load-bearing.
    if {![llength $missing] && ![llength $unresolved]} { return 1 }

    set msg "$role pack '[pack_pack_name $role]': [llength $missing] file(s) the\
             pack names do not exist"
    if {[llength $unresolved]} {
        append msg ", and [llength $unresolved] value(s) are unresolved"
    }
    append msg ".\n"
    foreach m $missing {
        foreach {k p desc} $m break
        append msg "\n  $k\n      $p\n      ($desc)"
    }
    foreach u $unresolved {
        foreach {k p} $u break
        append msg "\n  $k\n      $p  -- UNRESOLVED"
    }
    if {[llength $gaps]} {
        append msg "\n\n  AND [llength $gaps] value(s) this pack declares it cannot\
                    obtain from\n  ANY host - recorded gaps, not host problems,\
                    listed so that a\n  reader of this message does not go looking\
                    for a mount:"
        foreach g $gaps {
            foreach {k p} $g break
            append msg "\n  $k\n      $p  -- NOT OBTAINABLE"
        }
    }
    append msg "\n\n  These are SITE facts. A pack that is correct for the device\
                \n  can still be unreadable on this machine: check the environment\
                \n  variables the pack reads (${role}_env records every attempt)\
                \n  and see the pack's own README for what each one locates."
    if {$strict} { error $msg }
    puts stderr "WARNING: $msg"
    return 0
}


################################################################################
# 8. MANIFEST
#
# Every run records which packs it used and what they said, so a report can be
# re-read a year later without guessing which device produced it. CONTRACT.md
# section 5 requires prov.part.* and prov.board.* in every stage manifest; this
# is what fills them.
#
# DEFERRALS AND NOTES ARE PART OF THE RECORD, not decoration. A report that does
# not say which values this run actually had is a report that cannot be
# compared with another.
################################################################################

proc pack_summary {role {fh ""}} {
    set lines {}
    lappend lines [format "%-26s %s" ${role}_pack      [pack_pack_name $role]]
    lappend lines [format "%-26s %s" ${role}_pack_file $::pack_file($role)]

    set headline(part)  {part_name family device package speed_grade temp_grade
                         vendor min_vivado_version global_buffer mmcm_primitive
                         pll_primitive idelay_primitive slrs}
    set headline(board) {board_name part platform sys_clk_freq_hz bin_style
                         board_part fpgahub_board fpgahub_target}
    foreach k $headline($role) {
        if {[info exists ::pack_val($role,$k)]} {
            lappend lines [format "%-26s %s" $k $::pack_val($role,$k)]
        }
    }
    # A MANIFEST STATES WHAT THIS RUN ACTUALLY HAD, so every pending deferral is
    # resolved here rather than recorded as "not yet asked". A deferral whose
    # script has never run has no reason to print, and a manifest line saying
    # NOT DERIVED with an empty reason is exactly the shape of evidence this
    # toolkit refuses everywhere else.
    foreach k $::pack_defer_order($role) {
        if {[pack_resolve_deferred $role $k]} { continue }
        lappend lines [format "%-26s %s %s: %s" ${role}_deferred $k \
            [expr {$::pack_defer_scope($role,$k) eq "permanent"
                   ? "NOT OBTAINABLE ON ANY HOST" : "NOT DERIVED HERE"}] \
            [regsub -all {\s+} $::pack_defer_why($role,$k) " "]]
    }
    foreach e $::pack_env_log($role) {
        array set a $e
        lappend lines [format "%-26s %s (%s) %s" ${role}_env $a(name) \
            $a(status) $a(purpose)]
        array unset a
    }
    foreach n $::pack_notes($role) {
        lappend lines [format "%-26s %s" ${role}_note [regsub -all {\s+} $n " "]]
    }
    set text [join $lines "\n"]
    if {$fh ne ""} { puts $fh $text }
    return $text
}

# What a device says about a primitive name: physical, retargeted (with what it
# really becomes), rejected, or unknown to this pack. The engine asks this
# rather than pattern-matching primitive names in a stage script.
proc pack_primitive_status {role prim} {
    if {$role ne "part"} { error "${role}_primitive_status: only part packs describe primitives." }
    foreach k $::pack_physical_primitive_keys {
        if {![info exists ::pack_val(part,$k)]} { continue }
        if {[lsearch -exact $::pack_val(part,$k) $prim] >= 0} { return physical }
    }
    set pairs [pack_opt part primitives_retargeted {}]
    if {[llength $pairs] % 2 == 0} {
        foreach {from to} $pairs {
            if {$from eq $prim} { return [list retargeted $to] }
        }
    }
    if {[lsearch -exact [pack_opt part primitives_rejected {}] $prim] >= 0} {
        return rejected
    }
    return unknown
}


################################################################################
# 9. THE ROLE STATE, RESET
#
# Loading a second pack of the same role into one interpreter would otherwise
# inherit the first one's keys and validate a chimera. Nothing in the flow does
# that today; fpga-flow-part-get with two --part arguments would, and a test
# harness does it constantly.
################################################################################

proc pack_reset {role} {
    foreach a {pack_val pack_defer_script pack_defer_state pack_defer_why
               pack_defer_scope} {
        foreach n [array names ::$a ${role},*] { unset ::${a}($n) }
    }
    set ::pack_defer_order($role) {}
    set ::pack_notes($role)       {}
    set ::pack_env_log($role)     {}
    set ::pack_missing_env($role) {}
    set ::pack_dir($role)         ""
    set ::pack_file($role)        ""
}


################################################################################
# 10. THE TWO NAME FAMILIES
#
# CONTRACT.md section 8 names these commands and the flow engine binds to them:
# flow/common/flow_utils.tcl requires part_load, board_load, part_get, part_has,
# board_get and board_has to exist, and dies naming the missing one otherwise.
#
# `interp alias` rather than a generated `proc` on purpose. An alias is one line
# per name, it cannot drift from the body it forwards to, and it shows up in
# `info commands` exactly as a proc does - which is what flow_utils' own
# existence check uses. A generated proc would need its body built by string
# substitution, and a validator written by string substitution is a validator
# nobody can grep.
#
# `proc` SILENTLY REPLACES an existing command, and so does `interp alias`.
# These names are short and this file is sourced into Vivado's interpreter as
# well as a bare tclsh, so assert they are free rather than discover a shadowed
# built-in three hours into a stage.
################################################################################

set ::pack_verbs {
    set unset note env defer derived_dir
    load validate get has opt require keys summary
    check_files is_deferred deferral_note nearest env_report gaps
    pack_name pack_file primitive_status reset absent
}

foreach __role $::pack_roles {
    foreach __verb $::pack_verbs {
        set __name ${__role}_${__verb}
        if {[llength [info commands $__name]]} {
            error "pack_api.tcl: '$__name' is already a command in this\
                   interpreter - binding it would shadow something. Rename that\
                   command, or this API, before sourcing."
        }
        interp alias {} $__name {} pack_$__verb $__role
    }
}
unset -nocomplain __role __verb __name

# Copyright (C) 2026, SoC Labs (www.soclabs.org)
