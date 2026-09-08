################################################################################
# fpga/hooks/post_impl.tcl - IS WHAT YOU EXPECTED ACTUALLY IN THE IMPLEMENTED
#                            DESIGN, AND HOW MANY OF IT?
#
# A WORKING CHECK, NOT AN ILLUSTRATION. It asserts nothing until this project
# declares UTIL_ASSERT_TABLE, and until then it REFUSES THE STAGE and says how
# to fix that - every run, in the log, in words. A hook that runs, finds no
# expectations and prints nothing is indistinguishable from one that checked
# everything and was happy.
#
# If @BLOCK@ has nothing to assert about the routed design, DELETE THIS FILE.
# That is the honest way to say so and nothing else breaks.
#
# ------------------------------------------------------------------------------
# WHERE THIS RUNS
# ------------------------------------------------------------------------------
#   Sourced by `flow_hook post_impl`, whose machinery is
#   $(FPGA_FLOW_DIR)/flow/common/flow_utils.tcl - `proc flow_hook`, line 492
#   when this template was written; line 505 sources this file inside a catch
#   that names it and re-raises, line 517 records `post_impl(<n>s)` in the
#   stage manifest.
#
#   THE CALL SITE IS flow/vivado/5_impl.tcl AND AT THE TIME OF WRITING THAT
#   FILE DOES NOT EXIST. This toolkit is at phase 1: the contract layer is
#   built and no EDA tool is launched by anything in it, so flow/vivado/ is an
#   empty directory and `make impl` fails with "stage 'impl' has no script".
#   The seam is contracted; the stage that fires it is not written:
#
#       grep -n 'flow_hook post_impl' $(FPGA_FLOW_DIR)/flow/vivado/*.tcl
#
#   WHAT HAS HAPPENED BY THEN:
#     - opt, place and route have run. The database is placed and routed and
#       every question below can be asked of it.
#     - XDC_POST_ROUTE has been `source`d, if the project set it. That is where
#       a DRC waiver has to live: Vivado REJECTS procedural Tcl inside an XDC,
#       so `create_waiver` cannot be read_xdc'd at all.
#     - flow_boot ran long ago: the packs are loaded, $REPORT_DIR exists.
#
#   WHAT HAS NOT HAPPENED:
#     - write_bitstream. This is the LAST SEAM AT WHICH A CHANGE CAN STILL
#       REACH WHAT SHIPS - see the trap below.
#
#   AND ONE ORDERING THIS FILE WILL NOT GUESS AT: whether the routed checkpoint
#   is written BEFORE or AFTER this seam. Read the stage script before adding
#   anything here that CHANGES the design. If the checkpoint is already
#   written, a change made here reaches the bitstream and not the checkpoint,
#   the two disagree, and nothing says so.
#
# ------------------------------------------------------------------------------
# TRAP: post_bitstream IS ONE SEAM TOO LATE, AND THE PRECEDENT IS REAL
# ------------------------------------------------------------------------------
#   The bitstream is already written when post_bitstream fires, so a hook there
#   cannot change the design - only report on it.
#
#   The reference ASIC toolkit's post_route seam has the same property (it
#   fires after write_stream, write_netlist and write_sdf). A project placed
#   its bond-pad ring there. Every stage completed, every gate passed, and the
#   run streamed A GDS WITH NO PAD RING: the pads existed in the tool's
#   database and in none of the files the run shipped. That route stage now
#   dies on a post_route hook that changes the instance count.
#
#   So: measurements and exports at post_bitstream. Anything that must be IN
#   the bitstream, here, at post_impl, with the checkpoint ordering checked.
#
# ------------------------------------------------------------------------------
# WHY THIS EXISTS - THE OTHER HALF OF THE pre_synth DEFECT
# ------------------------------------------------------------------------------
#   fpga/hooks/pre_synth.tcl asserts that a declared parameter or macro reached
#   the fileset the tool was about to synthesise. This asserts the CONSEQUENCE:
#   that the primitives the opt-in was supposed to produce are in the design
#   that was actually routed.
#
#   The measured defect both come from: an `ifdef` opt-in in this codebase was
#   false in EVERY FPGA build for months, because ipx::package_project drops
#   fileset defines by three separate routes and none of them warn. It was
#   found by building both arms and discovering the "off" bitstream was
#   BYTE-IDENTICAL to the "on" one. A single row here -
#
#       {ref <THE PRIMITIVE> min 1 why "the opt-in is only real if this exists"}
#
#   - would have turned months of silence into a red run the first time.
#
#   AND IT IS NOT THE SAME QUESTION THE FLOW'S OWN GATES ASK. EXPECT_LUT_MAX,
#   EXPECT_FF_MAX, EXPECT_BRAM_MAX and EXPECT_DSP_MAX are AGGREGATE budgets:
#   they answer "does it fit". Every one of them can be green on a design whose
#   one load-bearing primitive is absent, because absence makes a design
#   smaller. This hook is the per-primitive question, and it is the one nobody
#   asks until after the bench.
#
# ------------------------------------------------------------------------------
# HOW TO CONFIGURE IT
# ------------------------------------------------------------------------------
#   Declare UTIL_ASSERT_TABLE - either as an exported make variable in
#   fpga/design.mk (beside the other gates in section 12), or as a Tcl global
#   set by an earlier hook or a step override. The global wins; both spellings
#   are UTIL_ASSERT_TABLE.
#
#   ONE ROW PER EXPECTATION. Fill in the markers below and delete this
#   commented block once the real declaration is in design.mk - `make check`
#   greps for the markers and they are how a fresh scaffold reports that this
#   decision is still outstanding.
#
#     export UTIL_ASSERT_TABLE := \
#         {ref <<FILL IN: the REF_NAME as the netlist spells it>> \
#          min <<FILL IN: how many must exist, at least>> \
#          why "what is silently broken if this count is wrong"}
#
#   KEYS. An UNKNOWN KEY IS FATAL, not ignored: an expectation nothing reads is
#   worse than no expectation at all, because it looks like cover.
#
#     ref      REQUIRED  the REF_NAME, as the netlist spells it
#     count    an EXACT number. Mutually exclusive with min/max
#     min      at least this many
#     max      at most this many
#     inst_re  a REGEXP every matching instance's name must satisfy. It is a
#              regexp and not a glob: {^u_soc/u_.*_phy$}, not u_soc/*
#     why      free text. Printed and recorded. Write it: a row whose reason is
#              not written down is a row the next person deletes to get a build
#
#   A row must declare at least one of count/min/max. A row that names a ref
#   and asserts no quantity CANNOT FAIL, and a check that cannot fail is not a
#   check - so it is refused rather than counted as coverage.
#
#   THE TABLE IS A LIST, NOT A SCRIPT. `{ref [part idelay_primitive] min 1}` is
#   the literal eleven-character text `[part idelay...`, not the part pack's
#   answer: nothing here evaluates a row. If you want the pack to name the
#   primitive - which is where a primitive's name belongs, since it is a fact
#   about silicon and not about your design - set the Tcl global from an
#   earlier hook, where it IS a script:
#
#       set UTIL_ASSERT_TABLE [list [list ref [part idelay_primitive] min 1]]
#
# ------------------------------------------------------------------------------
# WHAT THIS DELIBERATELY DOES NOT CHECK
# ------------------------------------------------------------------------------
#   * TIMING. Not one row here says anything about whether the design closes.
#     That is EXPECT_WNS_MIN / EXPECT_WHS_MIN and the stage's own verdict file,
#     $REPORT_DIR/impl_gate.txt.
#   * THAT A COUNT MATCHES report_utilization. IT WILL NOT, AND THAT IS NOT A
#     BUG. This counts CELL OBJECTS whose REF_NAME is the declared string; the
#     utilisation report groups by site type and can account for several cells
#     in one row or one site. A budget copied out of that report into this
#     table is a number about a different quantity - measure the count you mean
#     with the reproduction recipe below, once, and write THAT down.
#   * THAT THE PRIMITIVE DOES ANYTHING. Presence is not function: a cell can be
#     instantiated, placed, routed and driven by nothing that matters.
#   * ANYTHING NOT DECLARED. This is not a full census - it never invents an
#     expectation from what it happens to find, because a census that checked
#     whatever it found would agree with itself on every design, including the
#     one that lost its primitive.
#   * A FULL PER-REF HISTOGRAM, deliberately. Reading a property off every cell
#     in a routed database of any size costs minutes inside the tool's licence,
#     and this seam has one job.
#
# ------------------------------------------------------------------------------
# HOW TO REPRODUCE THE MEASUREMENT WITHOUT RUNNING A STAGE
# ------------------------------------------------------------------------------
#   The routed checkpoint is a complete database. One licence, no run:
#
#       vivado -mode batch -source /dev/stdin <<'EOF'
#       open_checkpoint build/<run tag>/outputs/@BLOCK@_routed.dcp
#       set n [llength [get_cells -hierarchical -quiet -filter {REF_NAME == <REF>}]]
#       puts "<REF>: $n"
#       EOF
#
#   That is also how to SET a row's number honestly: measure it on a run you
#   believe in, then write the number and the date and the run tag beside the
#   row. A budget with no measurement beside it is a number somebody guessed.
#
#   And the record this hook leaves, which is collected with the run:
#
#       $REPORT_DIR/util_assert_post_impl.txt
#
#   Copyright (C) 2026, SoC Labs (www.soclabs.org)
################################################################################

# The seam is THIS FILE'S OWN NAME, so `cp post_impl.tcl post_synth.tcl` runs
# the same census one stage earlier - on the synthesised netlist, where a
# missing primitive costs minutes instead of an implementation run - and every
# message it prints names post_synth. Captured at file scope: `info script` is
# only meaningful while the file is being sourced.
set _util_assert_seam [file rootname [file tail [info script]]]
if {$_util_assert_seam eq ""} { set _util_assert_seam hook }

# Every proc is prefixed util_assert_ for the reason flow_utils.tcl gives at its
# top: a short generic name once shadowed a tool builtin and killed a stage two
# and a half hours in.

# How many hits to re-verify literally. See util_assert_hits.
set _util_assert_verify_cap 256

# --- 1. WHAT THE PROJECT DECLARED --------------------------------------------
#
# A Tcl global wins over the environment. `opt` is called either way so the
# resolved table lands in the run manifest with every other knob: the manifest
# then records WHAT THIS RUN WAS GRADED AGAINST, not merely that it was graded.
proc util_assert_declared {} {
    set saved ""
    set have 0
    if {[info exists ::UTIL_ASSERT_TABLE]} {
        set saved $::UTIL_ASSERT_TABLE
        set have 1
    }
    opt UTIL_ASSERT_TABLE ""
    if {$have && [string trim $saved] ne ""} { set ::UTIL_ASSERT_TABLE $saved }
    return [string trim $::UTIL_ASSERT_TABLE]
}

# --- 2. THE LOUD REFUSAL ------------------------------------------------------
#
# flow_refuse, not die and not warn: exit 2 says NOTHING WAS MEASURED, which is
# what happened, and make and ci/lib.sh grade that differently from a design
# that came out wrong. The two need different people.
proc util_assert_unconfigured {seam} {
    util_assert_report $seam NOT-CHECKED \
        [list "# UTIL_ASSERT_TABLE is not declared in this run." \
              "# Nothing was counted. This file is the record that nothing was."]
    flow_refuse \
        "NOT CHECKING: no UTIL_ASSERT_TABLE is declared, so this hook counted NOTHING." \
        "  fpga/hooks/${seam}.tcl ran on a placed and routed design and asserted" \
        "  nothing about it. The stage's own gates are AGGREGATE budgets - they" \
        "  answer 'does it fit', and every one of them is green on a design whose" \
        "  one load-bearing primitive is missing, because absence makes a design" \
        "  smaller." \
        "" \
        "  DECLARE IT - one row per expectation, in fpga/design.mk:" \
        "      export UTIL_ASSERT_TABLE := \\" \
        "          {ref <REF_NAME> min 1 why \"what breaks silently if it is absent\"}" \
        "  Keys: ref (required), count, min, max, inst_re, why. A row must" \
        "  declare at least one of count/min/max. An unknown key is fatal." \
        "" \
        "  OR DELETE fpga/hooks/${seam}.tcl. If this design has nothing to assert" \
        "  about the routed netlist, that is the honest way to say so and nothing" \
        "  else breaks."
}

# --- 3. THE TABLE -------------------------------------------------------------
proc util_assert_parse {table} {
    set known {ref count min max inst_re why}
    set rows {}
    set seen {}
    set n 0
    foreach row $table {
        incr n
        if {[catch {llength $row} len]} {
            die "UTIL_ASSERT_TABLE row $n is not a Tcl list: $row" \
                "  Each row is key/value pairs in braces, e.g. {ref MY_PRIM min 1}."
        }
        if {$len == 0} { continue }
        if {$len % 2} {
            die "UTIL_ASSERT_TABLE row $n has an odd number of words: $row" \
                "  Each row is key/value pairs. Known keys: $known" \
                "  A value containing spaces needs its own braces or quotes."
        }
        array unset r
        array set r {ref "" count "" min "" max "" inst_re "" why ""}
        foreach {k v} $row {
            if {[lsearch -exact $known $k] < 0} {
                die "UTIL_ASSERT_TABLE row $n names an unknown key '$k'." \
                    "  Known keys: $known" \
                    "  A key this hook does not read is an expectation NOTHING" \
                    "  checks, which is worse than no expectation at all: it" \
                    "  looks like cover. Fix the row."
            }
            set r($k) $v
        }
        if {[string trim $r(ref)] eq ""} {
            die "UTIL_ASSERT_TABLE row $n declares no 'ref'." \
                "  Row: $row" \
                "  ref is the REF_NAME as the NETLIST spells it - the cell type in" \
                "  the implemented design, not the RTL module or the wrapper you" \
                "  wrote around it."
        }
        foreach k {count min max} {
            if {[string trim $r($k)] eq ""} { continue }
            if {![string is integer -strict $r($k)] || $r($k) < 0} {
                die "UTIL_ASSERT_TABLE row $n: $k '$r($k)' is not a whole number." \
                    "  Counts are whole numbers and a negative bound is not an" \
                    "  expectation anything could satisfy."
            }
        }
        if {[string trim $r(count)] ne "" &&
            ([string trim $r(min)] ne "" || [string trim $r(max)] ne "")} {
            die "UTIL_ASSERT_TABLE row $n declares count AND min/max for '$r(ref)'." \
                "  count is an EXACT expectation; min/max is a range. Declaring" \
                "  both leaves it ambiguous which one this row means, and this" \
                "  hook will not pick. Use one."
        }
        if {[string trim $r(count)] eq "" && [string trim $r(min)] eq ""
            && [string trim $r(max)] eq ""} {
            die "UTIL_ASSERT_TABLE row $n names ref '$r(ref)' and asserts no quantity." \
                "  Declare count, or min, or max. A row with no bound CANNOT FAIL," \
                "  and a check that cannot fail is not a check - it is a line in a" \
                "  table that makes a run look inspected."
        }
        if {[string trim $r(min)] ne "" && [string trim $r(max)] ne ""
            && $r(min) > $r(max)} {
            die "UTIL_ASSERT_TABLE row $n: min $r(min) is greater than max $r(max)." \
                "  No count satisfies that row, so every run would fail it and the" \
                "  failure would say nothing about the design."
        }
        # A malformed regexp would otherwise raise from inside the census, as a
        # Tcl error naming a line in a file the stage has never heard of, AFTER
        # the counts were taken. Rejected here instead, by name.
        if {[string trim $r(inst_re)] ne ""
            && [catch {regexp -- $r(inst_re) ""} msg]} {
            die "UTIL_ASSERT_TABLE row $n: inst_re '$r(inst_re)' is not a valid regexp." \
                "  $msg" \
                "  It is a REGEXP, not a glob: use {^u_soc/u_phy$}, not u_soc/*."
        }
        if {[lsearch -exact $seen $r(ref)] >= 0} {
            die "UTIL_ASSERT_TABLE declares ref '$r(ref)' twice." \
                "  Two rows for one ref cannot both be checked - the second would" \
                "  silently win. Merge them."
        }
        lappend seen $r(ref)
        lappend rows [array get r]
    }
    if {![llength $rows]} {
        die "UTIL_ASSERT_TABLE is set and declares no row." \
            "  An empty table is not 'nothing to check' - it is a check that" \
            "  CANNOT FAIL, which passes every design including the broken one." \
            "  Write the rows, or unset it and delete this hook."
    }
    return $rows
}

# --- 4. THE CONTROL -----------------------------------------------------------
#
# WHY THIS EXISTS. `get_cells -quiet -filter {REF_NAME == X}` returns an empty
# list for a cell type that is not in the design AND for a filter this tool
# version cannot evaluate AND for a database that was never opened. Read as a
# count, all three are the same zero - and one of them is the defect this hook
# hunts while the others are a census that measured nothing and would report
# that defect on a perfectly good design.
#
# So nothing is counted until the query mechanism has answered a question whose
# answer is KNOWN, taken from this very database: a REF_NAME read off a real
# cell moments earlier must be findable by the filter that will be used for
# every row. A filter that cannot match a name the database just handed back
# cannot be trusted to report zero of anything.
proc util_assert_probe {{sample 32}} {
    foreach c {get_cells get_property} {
        if {![flow_have $c]} {
            flow_refuse "this tool has no '$c', so this hook cannot see the design at all." \
                "  It belongs at a Vivado stage seam. Nothing was checked." \
                "  (Sourcing it under a bare tclsh reaches exactly this message.)"
        }
    }
    set cells {}
    if {[catch {set cells [get_cells -hierarchical -quiet]} msg]} {
        flow_refuse "the cell query failed: $msg" \
            "  Nothing was counted. This is a tool or database problem, not a" \
            "  verdict on the design."
    }
    set total [llength $cells]
    if {$total == 0} {
        flow_refuse "the database holds NO cells at all." \
            "  A census over an empty database is not a clean census. Either no" \
            "  design is open in this session, or implementation produced" \
            "  nothing - and Vivado exits 0 on both."
    }
    set probe [lrange $cells 0 [expr {$sample - 1}]]
    set named 0
    set witness ""
    foreach c $probe {
        set rn ""
        catch { set rn [get_property -quiet REF_NAME $c] }
        if {[string trim $rn] ne ""} {
            incr named
            if {$witness eq ""} { set witness $rn }
        }
    }
    if {!$named} {
        flow_refuse "CONTROL FAILED: $total cell(s) are in the database and NOT ONE of" \
            "  the [llength $probe] sampled resolves a REF_NAME." \
            "  Every count this hook could produce would therefore be zero, and a" \
            "  zero that measured nothing reads exactly like a missing primitive." \
            "  The run is stopped rather than reporting it."
    }
    set back 0
    catch { set back [llength [get_cells -hierarchical -quiet \
                                  -filter "REF_NAME == $witness"]] }
    if {$back == 0} {
        flow_refuse "CONTROL FAILED: the filtered cell query returns NOTHING for REF_NAME" \
            "  '$witness', which was read out of this same database moments ago." \
            "  Every count this hook could produce would be zero, and a zero that" \
            "  measured nothing reads exactly like a missing primitive." \
            "  The run is stopped rather than reporting it."
    }
    return [list $total $named [llength $probe] $witness]
}

# --- 5. INSTANCES OF ONE REF --------------------------------------------------
#
# Two numbers, deliberately. In Vivado `==` inside -filter is an exact string
# match and `=~` is the glob form, so the two SHOULD agree - and they are both
# reported because the day they do not is the day the filter stopped meaning
# what it looks like, and because this table gets copied to tools where `==` is
# itself a pattern. A disagreement stops the run rather than being averaged
# into a count.
#
# The literal re-verification is capped: reading a property off every hit of a
# common primitive would cost minutes inside the tool's licence. The cap is
# reported with the count, so nobody reads a sampled control as a full one.
proc util_assert_hits {ref cap} {
    set raw {}
    if {[catch {set raw [get_cells -hierarchical -quiet \
                             -filter "REF_NAME == $ref"]} msg]} {
        die "the cell query for REF_NAME '$ref' failed: $msg" \
            "  Nothing was counted for this row."
    }
    set n [llength $raw]
    set checked 0
    foreach c $raw {
        if {$checked >= $cap} { break }
        incr checked
        set rn ""
        catch { set rn [get_property -quiet REF_NAME $c] }
        if {$rn ne $ref} {
            flow_refuse "CONTROL FAILED: the filter for REF_NAME '$ref' returned a cell" \
                "  whose REF_NAME is '$rn'." \
                "  The filter is matching more than it names, so every count in" \
                "  this census is a count of something else. The run is stopped" \
                "  rather than reporting it."
        }
    }
    return [list $raw $n $checked]
}

# --- 6. THE RECORD ------------------------------------------------------------
#
# A verdict that exists only in a stage log is a verdict nobody collects.
# Written under $REPORT_DIR, which the run already gathers - and written on the
# NOT-CHECKED path too, so the absence of a check is an artefact rather than an
# absence of artefacts. NEVER into the source tree: a hook that writes into
# fpga/ makes the next run's inputs depend on the last run's outputs, and
# `make clean` stops returning the project to a known state.
proc util_assert_report {seam verdict lines} {
    global REPORT_DIR
    if {![info exists REPORT_DIR] || ![file isdirectory $REPORT_DIR]} {
        warn "no REPORT_DIR: this census is in the log only, and a log is not a"
        warn "  collected artefact."
        return ""
    }
    set p [file join $REPORT_DIR util_assert_${seam}.txt]
    if {[catch {set fh [open $p w]} msg]} {
        warn "could not write $p: $msg"
        return ""
    }
    puts $fh "# primitive census - seam $seam"
    puts $fh [format "%-24s %s" verdict $verdict]
    foreach l $lines { puts $fh $l }
    puts $fh ""
    puts $fh "# NOT COVERED BY THIS CHECK, AT ANY SETTING:"
    puts $fh "#   - timing. Nothing here says whether the design closes; that is"
    puts $fh "#     EXPECT_WNS_MIN/EXPECT_WHS_MIN and impl_gate.txt."
    puts $fh "#   - agreement with report_utilization. This counts CELL OBJECTS by"
    puts $fh "#     REF_NAME; that report groups by site type. Different quantities."
    puts $fh "#   - function. A cell can be present, placed, routed and useless."
    puts $fh "#   - anything no row declared. This is not a full census, on purpose."
    puts $fh "#   - the bitstream. write_bitstream has not run at this seam."
    close $fh
    say "census written to $p"
    return $p
}

# --- 7. THE CENSUS ------------------------------------------------------------
#
# Every row is counted before anything is refused, so one run tells the reader
# about every wrong expectation rather than about the first one.
proc util_assert_run {seam cap} {
    step "primitive census ($seam)"

    set table [util_assert_declared]
    if {$table eq ""} { util_assert_unconfigured $seam ; return 0 }
    set rows [util_assert_parse $table]

    lassign [util_assert_probe] total named sampled witness
    say "basis: $total cell(s) in the database; $named of $sampled sampled resolve\
         a REF_NAME; the filtered query round-trips '$witness'"

    set lines [list [format "%-24s %s" basis \
        "$total cells, $named/$sampled named, witness $witness, literal-verify cap $cap"]]
    set fails {}

    foreach row $rows {
        array unset r
        array set r $row
        lassign [util_assert_hits $r(ref) $cap] hits n checked

        set want "any"
        if {[string trim $r(count)] ne ""} {
            set want "exactly $r(count)"
        } else {
            set lo "0"
            set hi "unbounded"
            if {[string trim $r(min)] ne ""} { set lo $r(min) }
            if {[string trim $r(max)] ne ""} { set hi $r(max) }
            set want "$lo..$hi"
        }

        set verdict ok
        if {[string trim $r(count)] ne "" && $n != $r(count)} { set verdict FAIL }
        if {[string trim $r(min)] ne "" && $n < $r(min)}      { set verdict FAIL }
        if {[string trim $r(max)] ne "" && $n > $r(max)}      { set verdict FAIL }

        if {$verdict eq "FAIL"} {
            lappend fails "REF_NAME '$r(ref)': found $n, declared $want."
            if {$n == 0} {
                lappend fails "  ZERO. Nothing in the implemented design is that cell\
                               type. If it was supposed to be opted in by a macro,\
                               read fpga/hooks/pre_synth.tcl: ipx::package_project\
                               drops fileset defines and an opt-in that never\
                               reached the tool produces exactly this - a design\
                               that is smaller, quieter and wrong."
                lappend fails "  Check the spelling too: ref is the REF_NAME the\
                               NETLIST uses, which is often not the RTL module\
                               name."
            }
            if {$r(why) ne ""} { lappend fails "  why it matters: $r(why)" }
        }

        # inst_re is checked on every hit, not on a sample: a naming rule that
        # held for the first 256 instances and not the rest would be reported as
        # holding, which is the failure mode this whole file is about.
        set badnames {}
        if {[string trim $r(inst_re)] ne ""} {
            foreach c $hits {
                set nm ""
                catch { set nm [get_property -quiet NAME $c] }
                if {$nm eq ""} { set nm $c }
                if {![regexp -- $r(inst_re) $nm]} { lappend badnames $nm }
            }
            if {[llength $badnames]} {
                set verdict FAIL
                lappend fails "REF_NAME '$r(ref)': [llength $badnames] of $n\
                               instance(s) do not match inst_re '$r(inst_re)'."
                foreach nm [lrange $badnames 0 4] { lappend fails "    $nm" }
                if {[llength $badnames] > 5} {
                    lappend fails "    ... and [expr {[llength $badnames] - 5}] more"
                }
            }
        }

        say [format "  %-32s found %-8s declared %-14s %s" \
                    $r(ref) $n $want $verdict]
        lappend lines [format "%-24s ref=%s found=%s declared=%s literal_checked=%s verdict=%s" \
                              row $r(ref) $n $want $checked $verdict]
        if {$r(why) ne ""} { lappend lines [format "%-24s %s" row_why $r(why)] }
    }

    if {[llength $fails]} {
        # No lmap and no `string cat`: both are Tcl 8.6 and the tool's
        # interpreter is 8.5. A hook that only works on the newest Vivado is a
        # hook that stops working on the machine that has the licence.
        set flines [list "" "# failures:"]
        foreach f $fails { lappend flines "# $f" }
        util_assert_report $seam FAIL [concat $lines $flines]
        die "PRIMITIVE CENSUS FAILED at $seam - [llength $rows] row(s) checked:" \
            {*}$fails \
            "The bitstream is NOT written from here rather than shipping a design\
             that is missing what this project said it must contain. See the\
             census beside this run's reports."
    }

    util_assert_report $seam PASS $lines
    say "all [llength $rows] declared expectation(s) hold on the routed design."
    return 1
}

util_assert_run $_util_assert_seam $_util_assert_verify_cap
unset _util_assert_seam _util_assert_verify_cap

# Copyright (C) 2026, SoC Labs (www.soclabs.org)
