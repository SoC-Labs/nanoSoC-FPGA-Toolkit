################################################################################
# fpga/hooks/pre_synth.tcl - DID THE PARAMETER YOU DECLARED ACTUALLY REACH THE
#                            DESIGN THE TOOL IS ABOUT TO SYNTHESISE?
#
# A WORKING CHECK, NOT AN ILLUSTRATION. It asserts nothing until this project
# declares RTL_ASSERT_TABLE, and until then it REFUSES THE STAGE and says how to
# fix that - every run, in the log, in words. "We did not check" and "we checked
# and it was clean" must never read alike, and an unconfigured hook that passed
# quietly would be the second one wearing the first one's face.
#
# If @BLOCK@ has nothing to assert here, DELETE THIS FILE. That is the honest
# way to say so and nothing else breaks.
#
# ------------------------------------------------------------------------------
# WHERE THIS RUNS
# ------------------------------------------------------------------------------
#   Sourced by `flow_hook pre_synth`, whose machinery is
#   $(FPGA_FLOW_DIR)/flow/common/flow_utils.tcl - `proc flow_hook`, line 492
#   when this template was written; line 505 sources this file inside a catch
#   that names it and re-raises, line 517 records `pre_synth(<n>s)` in the
#   stage manifest.
#
#   THE CALL SITE IS flow/vivado/4_synth.tcl AND AT THE TIME OF WRITING THAT
#   FILE DOES NOT EXIST. This toolkit is at phase 1: the contract layer is
#   built and no EDA tool is launched by anything in it, so flow/vivado/ is an
#   empty directory and `make synth` fails with "stage 'synth' has no script".
#   The seam is contracted; the stage that fires it is not written. Do not take
#   the ordering below on trust - when the stage lands, read it:
#
#       grep -n 'flow_hook pre_synth' $(FPGA_FLOW_DIR)/flow/vivado/*.tcl
#
#   WHAT HAS HAPPENED BY THEN, and what this check depends on:
#     - flow_boot has run. The part and board packs are loaded, the four run
#       directories exist, $REPORT_DIR is writable, $block_name is set.
#     - the sources are READ - the flist stage wrote $WORK_DIR/sources.tcl and
#       the synth stage has consumed it - so the fileset carries whatever
#       generics and defines the flow applied to it.
#     - IP packaging, if this design packages IP, is ALREADY DONE. It is an
#       earlier stage (package-ip) and it is where the defect below happens.
#
#   WHAT HAS NOT HAPPENED:
#     - nothing is elaborated. There is no netlist, no cell, no primitive, and
#       no question about them can be asked here. That is `post_synth`.
#     - synth_design has not run. Everything this hook reads is INPUT.
#
# ------------------------------------------------------------------------------
# WHY THIS EXISTS - A MEASURED DEFECT, WITH THE NUMBER THAT PROVED IT
# ------------------------------------------------------------------------------
#   `ipx::package_project` DROPS FILESET DEFINES, by three separate routes, and
#   none of them warn. In this codebase an `ifdef TIDELINK_USE_IDELAY` opt-in
#   was therefore false in EVERY FPGA build - the builds that opted in and the
#   builds that did not. It was found by building both and discovering the
#   "IDELAY-off" bitstream was BYTE-IDENTICAL to the "IDELAY-on" one: the
#   primitive was absent from every build that believed it had it, for months,
#   with the tool reporting nothing, ever.
#
#   Two consequences, and this file is the first of them:
#
#     RTL_PARAMS IS THE PRIMARY MECHANISM. Parameters survive packaging as
#     CONFIG.* properties on the IP; defines do not. Prefer a module parameter
#     over a macro for anything that selects behaviour.
#
#     AND THE SECOND HALF OF THE SAME LESSON: this codebase has ZERO
#     occurrences of `ifdef FPGA` and `ifdef ASIC` across 13,524 RTL files,
#     along with XILINX, VIVADO, SIMULATION and FPGA_ONLY. A flow that
#     configures the build with +define+FPGA CONFIGURES NOTHING. Selection here
#     is by FLIST FILE-SWAP (same module name, opposite directory) and by
#     MODULE PARAMETER.
#
#   So the question this hook answers is not "did I write it in design.mk" -
#   you can read that. It is "is it still there, in the tool, on the fileset
#   that is about to be synthesised, AFTER everything the flow did to get here".
#
#   ITS OTHER HALF IS fpga/hooks/post_impl.tcl, which counts the primitives the
#   opt-in was supposed to produce. This one proves the tool was TOLD. That one
#   proves it HAPPENED. Neither substitutes for the other: a define can reach
#   the fileset and be read by no file, and a primitive can appear for a reason
#   nobody declared.
#
# ------------------------------------------------------------------------------
# HOW TO CONFIGURE IT
# ------------------------------------------------------------------------------
#   Declare RTL_ASSERT_TABLE - either as an exported make variable in
#   fpga/design.mk (beside the other gates in section 12), or as a Tcl global
#   set by an earlier hook or a step override. The global wins; both spellings
#   are RTL_ASSERT_TABLE, so a message can name one variable and mean both.
#
#   ONE ROW PER EXPECTATION. Fill in the two markers below and delete this
#   commented block once the real declaration is in design.mk - `make check`
#   greps for the markers and they are how a fresh scaffold reports that this
#   decision is still outstanding.
#
#     export RTL_ASSERT_TABLE := \
#         {name <<FILL IN: the parameter or macro, as the RTL spells it>> \
#          kind param \
#          value <<FILL IN: the value it must have in this build>> \
#          why "what breaks silently if this is wrong"}
#
#   KEYS. An UNKNOWN KEY IS FATAL, not ignored: an expectation nothing reads is
#   worse than no expectation at all, because it looks like cover.
#
#     name    REQUIRED  the parameter or macro name, as the RTL spells it
#     kind    param | define                                  (default param)
#     value   the value it must hold. Omit to assert PRESENCE ONLY, which is a
#             weaker claim and is reported as such
#     expect  present | absent                              (default present)
#             `absent` is how RTL_DEFINES_NEVER is enforced - an ASIC-only
#             macro reaching an FPGA build swaps a memory wrapper for one that
#             instantiates a foundry macro the fabric does not have, and the
#             failure is a black box in the netlist rather than an error
#     ip      an IP instance name. Reads CONFIG.<name> on that IP instead of
#             the fileset property - the mechanism that SURVIVES packaging, so
#             this is the strong form of the assertion in a packaged flow
#     why     free text. Printed and recorded. Write it: a row whose reason is
#             not written down is a row the next person deletes to get a build
#
#   Two rows for one (kind, name) are fatal - the second would silently win.
#
# ------------------------------------------------------------------------------
# WHAT THIS DELIBERATELY DOES NOT CHECK
# ------------------------------------------------------------------------------
#   * THAT ANY RTL FILE READS THE MACRO. It cannot, here: nothing is elaborated
#     and a `define` is a property of the fileset, not of the design. Given
#     that this codebase has zero `ifdef` of the usual names, a green row for a
#     define means THE TOOL WAS TOLD and nothing more. The strong form of that
#     assertion is a parameter (visible in the report, in the BD, and in the
#     netlist) plus post_impl.tcl counting what it produced.
#   * THAT THE VALUE IS LEGAL for the module, or that it is the value the
#     module's own default would have been. Vivado does not normalise the
#     spelling, so `1`, `1'b1` and `32'd1` are three different strings and this
#     compares strings.
#   * PER-FILE defines, and anything applied inside a packaged IP that the row
#     did not name with `ip`.
#   * ANYTHING IN direct MODE. Non-project mode has no fileset: the generics
#     and defines are arguments to synth_design and there is nothing to query.
#     This hook refuses rather than reporting a clean sheet it did not read.
#
# ------------------------------------------------------------------------------
# HOW TO REPRODUCE THE MEASUREMENT WITHOUT RUNNING A STAGE
# ------------------------------------------------------------------------------
#   The declared side needs no tool at all:
#
#       make env | grep -E 'RTL_(PARAMS|DEFINES)'
#
#   The tool side needs a Vivado session and the project this flow built:
#
#       vivado -mode batch -source /dev/stdin <<'EOF'
#       open_project build/<run tag>/work/<project>.xpr
#       puts "generic: [get_property GENERIC        [current_fileset]]"
#       puts "define : [get_property VERILOG_DEFINE [current_fileset]]"
#       EOF
#
#   And the record this hook leaves, which is collected with the run:
#
#       $REPORT_DIR/rtl_assert_pre_synth.txt
#
#   Copyright (C) 2026, SoC Labs (www.soclabs.org)
################################################################################

# The seam is THIS FILE'S OWN NAME, so `cp pre_synth.tcl pre_bd.tcl` runs the
# same assertion at another point and every message it prints names that point.
# Captured at file scope: `info script` is only meaningful while the file is
# being sourced.
set _rtl_assert_seam [file rootname [file tail [info script]]]
if {$_rtl_assert_seam eq ""} { set _rtl_assert_seam hook }

# Every proc is prefixed rtl_assert_ for the reason flow_utils.tcl gives at its
# top: a short generic name once shadowed a tool builtin and killed a stage two
# and a half hours in. Redefining these by sourcing two seam copies into one
# session is a no-op - the bodies are identical.

# --- 1. WHAT THE PROJECT DECLARED --------------------------------------------
#
# A Tcl global wins over the environment. `opt` is called either way so the
# resolved table lands in the run manifest with every other knob: the manifest
# then records WHAT THIS RUN WAS GRADED AGAINST, not merely that it was graded.
proc rtl_assert_declared {} {
    set saved ""
    set have 0
    if {[info exists ::RTL_ASSERT_TABLE]} {
        set saved $::RTL_ASSERT_TABLE
        set have 1
    }
    opt RTL_ASSERT_TABLE ""
    if {$have && [string trim $saved] ne ""} { set ::RTL_ASSERT_TABLE $saved }
    return [string trim $::RTL_ASSERT_TABLE]
}

# --- 2. THE LOUD REFUSAL ------------------------------------------------------
#
# THIS IS THE POINT OF THE WHOLE FILE. flow_refuse, not die and not warn: exit 2
# says NOTHING WAS MEASURED, which is what happened, and it is graded
# differently from exit 1 by make and by ci/lib.sh. A configuration that is
# missing and a design that is wrong need different people.
proc rtl_assert_unconfigured {seam} {
    rtl_assert_report $seam NOT-CHECKED \
        [list "# RTL_ASSERT_TABLE is not declared in this run." \
              "# Nothing was compared. This file is the record that nothing was."]
    flow_refuse \
        "NOT CHECKING: no RTL_ASSERT_TABLE is declared, so this hook asserted NOTHING." \
        "  fpga/hooks/${seam}.tcl ran and found no table, and a hook that finds no" \
        "  expectations and passes quietly reads exactly like a hook that checked" \
        "  everything and was happy. So it refuses instead." \
        "" \
        "  DECLARE IT - one row per expectation, in fpga/design.mk:" \
        "      export RTL_ASSERT_TABLE := \\" \
        "          {name <PARAM> kind param value <VALUE> why \"what breaks if wrong\"}" \
        "  Keys: name (required), kind (param|define), value, expect" \
        "  (present|absent), ip, why. An unknown key is fatal." \
        "" \
        "  OR DELETE fpga/hooks/${seam}.tcl. If this design has nothing to assert" \
        "  before synthesis, that is the honest way to say so and nothing else" \
        "  breaks. There is no third option that leaves a green run behind an" \
        "  unasked question."
}

# --- 3. THE TABLE -------------------------------------------------------------
#
# Every malformed row is diagnosed by name. An unknown key is fatal for the same
# reason flow_config rejects one: the typo is not the defect, the SILENT NO-OP
# is.
proc rtl_assert_parse {table} {
    set known {name kind value expect ip why}
    set rows {}
    set seen {}
    set n 0
    foreach row $table {
        incr n
        if {[catch {llength $row} len]} {
            die "RTL_ASSERT_TABLE row $n is not a Tcl list: $row" \
                "  Each row is key/value pairs in braces, e.g." \
                "      {name MY_PARAM kind param value 1}"
        }
        if {$len == 0} { continue }
        if {$len % 2} {
            die "RTL_ASSERT_TABLE row $n has an odd number of words: $row" \
                "  Each row is key/value pairs. Known keys: $known" \
                "  A value containing spaces needs its own braces or quotes."
        }
        array unset r
        array set r {kind param expect present value "" ip "" why ""}
        foreach {k v} $row {
            if {[lsearch -exact $known $k] < 0} {
                die "RTL_ASSERT_TABLE row $n names an unknown key '$k'." \
                    "  Known keys: $known" \
                    "  A key this hook does not read is an expectation NOTHING" \
                    "  checks, which is worse than no expectation at all: it" \
                    "  looks like cover. Fix the row."
            }
            set r($k) $v
        }
        if {[string trim $r(name)] eq ""} {
            die "RTL_ASSERT_TABLE row $n declares no 'name'." \
                "  Row: $row" \
                "  name is the parameter or macro AS THE RTL SPELLS IT - not the" \
                "  design.mk variable that carries it."
        }
        if {[lsearch -exact {param define} $r(kind)] < 0} {
            die "RTL_ASSERT_TABLE row $n: kind '$r(kind)' is not param or define." \
                "  They are read from two different tool properties and they" \
                "  survive IP packaging differently - see the header. Guessing" \
                "  between them would be guessing which defect you are testing for."
        }
        if {[lsearch -exact {present absent} $r(expect)] < 0} {
            die "RTL_ASSERT_TABLE row $n: expect '$r(expect)' is not present or absent."
        }
        if {$r(expect) eq "absent" && [string trim $r(value)] ne ""} {
            die "RTL_ASSERT_TABLE row $n asserts '$r(name)' is ABSENT and also" \
                "  declares value '$r(value)'." \
                "  Those cannot both be checked. An absent name has no value, so" \
                "  one of the two is a leftover and this hook will not pick which."
        }
        set key "$r(kind)/$r(name)"
        if {[lsearch -exact $seen $key] >= 0} {
            die "RTL_ASSERT_TABLE declares $key twice." \
                "  Two rows for one name cannot both be checked - the second would" \
                "  silently win. Merge them."
        }
        lappend seen $key
        lappend rows [array get r]
    }
    if {![llength $rows]} {
        die "RTL_ASSERT_TABLE is set and declares no row." \
            "  An empty table is not 'nothing to check' - it is a check that" \
            "  CANNOT FAIL, which passes every design including the broken one." \
            "  Write the rows, or unset it and delete this hook."
    }
    return $rows
}

# --- 4. THE CONTROL -----------------------------------------------------------
#
# WHY THIS EXISTS. `get_property FOO $obj` returns the empty string for a
# property that is unset AND for one this Vivado does not have on that object.
# Read as an answer, those are the same "" - and one of them is the defect this
# hook hunts while the other is a hook that measured nothing and would report a
# clean sheet on a design that had lost every define it declared.
#
# So nothing is compared until the query mechanism has answered a question whose
# answer is KNOWN: a fileset's NAME property, which is never empty on a fileset
# that exists.
proc rtl_assert_fileset {} {
    foreach c {get_property get_filesets} {
        if {![flow_have $c]} {
            flow_refuse "this tool has no '$c', so this hook cannot see the design at all." \
                "  It belongs at a Vivado stage seam. Nothing was checked." \
                "  (Sourcing it under a bare tclsh reaches exactly this message.)"
        }
    }
    set fs ""
    catch { set fs [current_fileset] }
    if {$fs eq ""} { catch { set fs [get_filesets -quiet sources_1] } }
    if {$fs eq ""} {
        flow_refuse "no source fileset in this session." \
            "  In FLOW_MODE=direct there is no project and no fileset: generics" \
            "  and defines are arguments to synth_design and NOTHING HERE CAN" \
            "  READ THEM. A clean sheet would be a sheet this hook never read," \
            "  so it refuses." \
            "  Either assert this at post_synth on the elaborated design, or" \
            "  delete this hook file. FLOW_MODE is in `make env`."
    }
    set nm ""
    catch { set nm [get_property -quiet NAME $fs] }
    if {[string trim $nm] eq ""} {
        flow_refuse "CONTROL FAILED: get_property NAME on the source fileset returned" \
            "  nothing, on an object this session just handed back. Every property" \
            "  this hook could read would then be empty, and an empty property" \
            "  reads exactly like a dropped define." \
            "  The run is stopped rather than reporting it."
    }
    return [list $fs $nm]
}

# NAME=VALUE entries from a fileset property, as a flat {name value ...} dict.
# A bare entry (a define with no value) maps to the empty string, which is
# DIFFERENT from being absent - the two are distinguished by the caller.
proc rtl_assert_pairs {fs prop} {
    set raw ""
    catch { set raw [get_property -quiet $prop $fs] }
    set out {}
    foreach e $raw {
        set e [string trim $e]
        if {$e eq ""} { continue }
        set i [string first "=" $e]
        if {$i < 0} {
            lappend out $e ""
        } else {
            lappend out [string range $e 0 [expr {$i - 1}]] \
                        [string range $e [expr {$i + 1}] end]
        }
    }
    return [list $raw $out]
}

# CONFIG.<name> on a named IP - the form that survives ipx::package_project.
# Returns {found value} or {0 ""}.
proc rtl_assert_ip_config {ip name} {
    if {![flow_have get_ips]} {
        die "row names ip '$ip' but this tool has no get_ips." \
            "  The IP form of this assertion cannot be evaluated here."
    }
    set obj ""
    catch { set obj [get_ips -quiet $ip] }
    if {$obj eq ""} {
        die "row names ip '$ip', which is not in this project." \
            "  A row about an IP that is not there cannot pass or fail honestly," \
            "  so it stops the run. Check the instance name with: get_ips"
    }
    set v ""
    if {[catch { set v [get_property -quiet CONFIG.$name $obj] }]} { return [list 0 ""] }
    if {[string trim $v] eq ""} { return [list 0 ""] }
    return [list 1 $v]
}

# --- 5. THE RECORD ------------------------------------------------------------
#
# A verdict that exists only in a stage log is a verdict nobody collects. Written
# under $REPORT_DIR, which the run already gathers - and written on the
# NOT-CHECKED path too, so the absence of a check is an artefact rather than an
# absence of artefacts. NEVER into the source tree: a hook that writes into
# fpga/ makes the next run's inputs depend on the last run's outputs.
proc rtl_assert_report {seam verdict lines} {
    global REPORT_DIR
    if {![info exists REPORT_DIR] || ![file isdirectory $REPORT_DIR]} {
        warn "no REPORT_DIR: this census is in the log only, and a log is not a"
        warn "  collected artefact."
        return ""
    }
    set p [file join $REPORT_DIR rtl_assert_${seam}.txt]
    if {[catch {set fh [open $p w]} msg]} {
        warn "could not write $p: $msg"
        return ""
    }
    puts $fh "# RTL parameter/define assertion - seam $seam"
    puts $fh [format "%-24s %s" verdict $verdict]
    foreach l $lines { puts $fh $l }
    puts $fh ""
    puts $fh "# NOT COVERED BY THIS CHECK, AT ANY SETTING:"
    puts $fh "#   - that any RTL file READS a macro asserted here. Nothing is"
    puts $fh "#     elaborated at this seam and this codebase has zero occurrences"
    puts $fh "#     of the usual ifdef names across 13,524 files."
    puts $fh "#   - that a value is legal for the module. Strings are compared as"
    puts $fh "#     written: 1, 1'b1 and 32'd1 are three different strings."
    puts $fh "#   - per-file defines, and anything inside a packaged IP that no row"
    puts $fh "#     named with the ip key."
    puts $fh "#   - what the primitives actually became. That is post_impl.tcl."
    close $fh
    say "record written to $p"
    return $p
}

# --- 6. THE COMPARISON --------------------------------------------------------
#
# Every row is evaluated before anything is refused, so one run tells the reader
# about every wrong expectation rather than about the first one.
proc rtl_assert_run {seam} {
    step "RTL parameter/define assertion ($seam)"

    set table [rtl_assert_declared]
    if {$table eq ""} { rtl_assert_unconfigured $seam ; return 0 }
    set rows [rtl_assert_parse $table]

    lassign [rtl_assert_fileset] fs fsname
    lassign [rtl_assert_pairs $fs GENERIC]        generic_raw generic
    lassign [rtl_assert_pairs $fs VERILOG_DEFINE] define_raw  defines

    say "basis: fileset '$fsname'"
    say "  GENERIC        = $generic_raw"
    say "  VERILOG_DEFINE = $define_raw"

    set lines [list \
        [format "%-24s %s" fileset $fsname] \
        [format "%-24s %s" generic $generic_raw] \
        [format "%-24s %s" verilog_define $define_raw] \
        [format "%-24s %s" declared_rtl_params [flow_env FPGA_RTL_PARAMS "(none)"]] \
        [format "%-24s %s" declared_rtl_defines [flow_env FPGA_RTL_DEFINES "(none)"]]]

    # THE DECLARED-VERSUS-TOOL CENSUS. design.mk said one thing; the fileset
    # holds another. This is the shape the packaging defect takes, so it is
    # always reported - but it WARNS rather than failing, because a flow may
    # legitimately deliver a define by another route (per file, or as a
    # synth_design argument), and only the TABLE says what must be true.
    foreach {var pairs what} [list FPGA_RTL_PARAMS $generic parameter \
                                   FPGA_RTL_DEFINES $defines define] {
        foreach e [flow_env $var] {
            set nm [lindex [split $e =] 0]
            if {$nm eq ""} { continue }
            if {![dict exists $pairs $nm]} {
                warn "DECLARED BUT NOT ON THE FILESET: $what '$nm' is in $var and is"
                warn "  not in the tool's property. This is the exact shape of the"
                warn "  ipx::package_project define-drop: declared, applied to"
                warn "  nothing, reported by no one. It is a warning here and not a"
                warn "  failure only because RTL_ASSERT_TABLE is where this project"
                warn "  states what MUST be true. If it must be, add a row."
                lappend lines [format "%-24s %s %s" declared_not_present $what $nm]
            }
        }
    }

    set fails {}
    foreach row $rows {
        array unset r
        array set r $row

        if {$r(ip) ne ""} {
            lassign [rtl_assert_ip_config $r(ip) $r(name)] found value
            set where "CONFIG.$r(name) on ip $r(ip)"
        } elseif {$r(kind) eq "param"} {
            set found [dict exists $generic $r(name)]
            set value ""
            if {$found} { set value [dict get $generic $r(name)] }
            set where "GENERIC on $fsname"
        } else {
            set found [dict exists $defines $r(name)]
            set value ""
            if {$found} { set value [dict get $defines $r(name)] }
            set where "VERILOG_DEFINE on $fsname"
        }

        set verdict ok
        if {$r(expect) eq "absent"} {
            if {$found} {
                set verdict FAIL
                lappend fails "$r(kind) '$r(name)' is PRESENT and was declared absent\
                               (value '$value', in $where)."
                if {$r(why) ne ""} { lappend fails "  why it matters: $r(why)" }
            }
        } elseif {!$found} {
            set verdict FAIL
            lappend fails "$r(kind) '$r(name)' IS NOT THERE. Expected it in $where."
            if {$r(kind) eq "define"} {
                lappend fails "  Defines do not survive ipx::package_project - three\
                               routes through packaging drop them and none warn. If\
                               this selects behaviour, make it a PARAMETER\
                               (RTL_PARAMS) or bake it into the materialised copy\
                               (RTL_DEFINES_INBODY). A plain +define+ in a packaged\
                               flow may reach nothing."
            } else {
                lappend fails "  Check RTL_PARAMS in design.mk, and that the flow\
                               applied it to this fileset rather than to another."
            }
            if {$r(why) ne ""} { lappend fails "  why it matters: $r(why)" }
        } elseif {[string trim $r(value)] ne "" && $value ne $r(value)} {
            set verdict FAIL
            lappend fails "$r(kind) '$r(name)' is '$value', expected '$r(value)'\
                           (in $where)."
            lappend fails "  Strings are compared as written and Vivado does not\
                           normalise them: 1, 1'b1 and 32'd1 differ here. If the\
                           two are the same number spelled twice, fix the\
                           declaration to match the spelling the tool holds."
            if {$r(why) ne ""} { lappend fails "  why it matters: $r(why)" }
        } elseif {[string trim $r(value)] eq "" && $r(expect) eq "present"} {
            set verdict "ok (presence only)"
        }

        set shown "(absent)"
        if {$found} { set shown "= '$value'" }
        set want "(any)"
        if {[string trim $r(value)] ne ""} { set want $r(value) }
        set got "(absent)"
        if {$found} { set got $value }
        say [format "  %-8s %-28s %-16s %s" $r(kind) $r(name) $verdict $shown]
        lappend lines [format "%-24s kind=%s name=%s expect=%s want=%s got=%s where=%s verdict=%s" \
                              row $r(kind) $r(name) $r(expect) $want $got $where $verdict]
        if {$r(why) ne ""} { lappend lines [format "%-24s %s" row_why $r(why)] }
    }

    if {[llength $fails]} {
        # No lmap and no `string cat`: both are Tcl 8.6 and the tool's
        # interpreter is 8.5. A hook that only works on the newest Vivado is a
        # hook that stops working on the machine that has the licence.
        set flines [list "" "# failures:"]
        foreach f $fails { lappend flines "# $f" }
        rtl_assert_report $seam FAIL [concat $lines $flines]
        die "RTL ASSERTION FAILED at $seam - [llength $rows] row(s) checked:" \
            {*}$fails \
            "Synthesis is stopped here rather than producing a bitstream that\
             believes it was configured. See the record beside this run's reports."
    }

    rtl_assert_report $seam PASS $lines
    say "all [llength $rows] declared expectation(s) hold on fileset '$fsname'."
    return 1
}

rtl_assert_run $_rtl_assert_seam
unset _rtl_assert_seam

# Copyright (C) 2026, SoC Labs (www.soclabs.org)
