#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# t_flow_utils.sh - flow/common/flow_utils.tcl, the boot and helper layer
#
# DEFECT CLASS: A HELPER THAT QUIETLY DOES NOTHING.
#
# Every Vivado stage in this toolkit goes through this file, and almost nothing
# in it produces an artefact of its own. That is what makes it dangerous: a
# guard that stopped guarding, a hook that stopped running, a knob that stopped
# registering and an exit code that collapsed into its neighbour all leave a
# run that looks exactly like a correct one. The stage still finishes. The
# bitstream still appears. Nothing in the log says which of the two designs it
# built.
#
# WHY THIS FILE EXISTS AT ALL. It did not, until 2026-09-11. The reference ASIC
# toolkit carries test/common/flow_utils.test for its equivalent of this file;
# this repository shipped 866 lines of the boot layer with no test naming it,
# while nine suites tested the things built ON it. That is backwards: an
# assertion about read_flist.tcl or provenance.tcl is only worth what the layer
# underneath it is worth, and that layer was the unmeasured one.
#
# Everything here runs under bare `tclsh`. flow_utils.tcl is deliberately
# tool-agnostic - its own header says so - and this suite is the thing that
# keeps that true: the day a helper starts calling a Vivado command unguarded,
# these drivers stop sourcing and say so, instead of the whole phase-1 suite
# quietly going with it.
#
# Every assertion is PAIRED WITH A MUTATION PROOF. Each driver below exits 0
# only when the property holds, so the same command serves both: green against
# the real toolkit, red against a copy with one guard removed. A mutation that
# cannot be planted is a SKIP WITH THE REASON, never a silent pass - t_mutate
# and t_replace_line fail loudly when their expression matches nothing, which is
# the normal consequence of somebody reformatting the line they target.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/lib/harness.sh
. "$HERE/../lib/harness.sh"

t_sandbox; SB="$T_SANDBOX"

FU_REL="flow/common/flow_utils.tcl"
FU="$FLOW_DIR/$FU_REL"

if [ ! -f "$FU" ]; then
    t_skip futils.all "no $FU_REL at $FU - nothing to test, and an absent file is not a passing one"
    t_summary; exit $?
fi
if ! command -v tclsh >/dev/null 2>&1; then
    t_skip futils.all "no tclsh on PATH - this layer is tool-agnostic by design and tclsh is the only way to drive it without a licence, so nothing here can run"
    t_summary; exit $?
fi
case "$SB" in
    *" "*)
        t_skip futils.all "the sandbox path '$SB' contains a space, which several drivers below splice into Tcl paths unbraced"
        t_summary; exit $? ;;
esac

#=============================================================================
# THE DRIVERS
#
# One file per property. Each SOURCES flow_utils.tcl from $env(TK) - so the same
# driver runs against the real toolkit and against a mutant - and exits 0 only
# when the property holds. Anything else exits non-zero and prints why.
#
# The drivers assert rather than print, on purpose. A driver that printed and
# left the grepping to the shell would put half of each property in bash and
# half in Tcl, and the half that rots is always the one you are not reading.
#=============================================================================

D="$SB/drivers"; mkdir -p "$D"
LOAD='source [file join $env(TK) flow common flow_utils.tcl]'

# --- the shadow guard --------------------------------------------------------
# `proc` REPLACES an existing command silently. The reference toolkit's guard
# has fired in anger: a helper named `fail` shadowed an Innovus builtin and
# aborted a route stage 2.5 hours in. `part` and `board` are the two names here
# most likely to collide in a future Vivado, which is why they are on the list.
cat > "$D/shadow.tcl" <<'EOF'
proc part {args} { return "I WAS HERE FIRST" }
if {[catch {source [file join $env(TK) flow common flow_utils.tcl]} msg]} {
    if {[string match "*is already a command*" $msg]} { exit 0 }
    puts "the source failed, but not with the shadow message: $msg"
    exit 3
}
puts "NO ERROR: flow_utils.tcl overwrote an existing 'part' command silently."
puts "  part now returns: [part x]"
exit 1
EOF

# --- flow_config rejects an undeclared key -----------------------------------
# `flow_config stict 1` that quietly did nothing would leave strict mode off in
# a stage whose author believed they had turned it on.
cat > "$D/config_typo.tcl" <<EOF
$LOAD
if {![catch {flow_config stict 1} msg]} {
    puts "NO ERROR: a typo'd key was accepted; ::flow now has [lsort [array names ::flow]]"
    exit 1
}
if {![string match "*unknown key*" \$msg]} { puts "wrong error: \$msg"; exit 3 }
if {[catch {flow_config strict 1} m2]} { puts "the REAL key was rejected: \$m2"; exit 3 }
if {\$::flow(strict) ne 1} { puts "strict did not take the value"; exit 3 }
exit 0
EOF

# --- exit codes 1 and 2 are distinct -----------------------------------------
# CONTRACT.md section 10. A failed check is a result about the design; a refusal
# says no result was produced at all. make and ci/lib.sh grade them differently,
# so collapsing them makes a configuration mistake indistinguishable from a
# timing failure.
cat > "$D/die.tcl"    <<EOF
$LOAD
die "planted"
EOF
cat > "$D/refuse.tcl" <<EOF
$LOAD
flow_refuse "planted"
EOF

# --- flow_assert_input: the three unusable inputs ----------------------------
cat > "$D/input_zero.tcl" <<EOF
$LOAD
set out [open \$env(SUBJECT) w] ; close \$out          ;# zero bytes, exists
flow_assert_input \$env(SUBJECT) "the master filelist" RTL_FLIST
puts "ACCEPTED a zero-byte file - the tool would read it and build from nothing"
exit 1
EOF
cat > "$D/input_absent.tcl" <<EOF
$LOAD
flow_assert_input \$env(SUBJECT) "the master filelist" RTL_FLIST
puts "ACCEPTED a path that does not exist"
exit 1
EOF
cat > "$D/input_emptydir.tcl" <<EOF
$LOAD
file mkdir \$env(SUBJECT)
flow_assert_input \$env(SUBJECT) "the IP repository" IP_REPOS
puts "ACCEPTED an empty directory - every 'test -d' in the world is satisfied by one"
exit 1
EOF

# The rc and the wording are checked together: an absent input reported as
# "ZERO BYTES" sends the reader to look for a truncated file that is not there.
cat > "$D/input_wording.sh" <<'EOF'
#!/bin/sh
# $1 = driver, $2 = subject path, $3 = expected substring, $4 = forbidden substring
out="$(TK="$TK" SUBJECT="$2" tclsh "$1" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] || { echo "exit $rc, wanted 2 (refused/unusable input)"; echo "$out"; exit 1; }
printf '%s' "$out" | grep -qF -- "$3" || { echo "no '$3' in:"; echo "$out"; exit 1; }
if [ -n "$4" ]; then
  printf '%s' "$out" | grep -qF -- "$4" && { echo "wrongly said '$4':"; echo "$out"; exit 1; }
fi
exit 0
EOF
chmod +x "$D/input_wording.sh"

# --- opt registers the knob by the ACT of reading it -------------------------
# CONTRACT.md section 5 requires the manifest to enumerate knobs from the `opt`
# declarations, never from a hand-maintained list. The reference toolkit's hand
# list had silently dropped three effort knobs, every one of which changes QoR,
# so two runs that differed in placement effort produced matching manifests.
cat > "$D/opt_registers.tcl" <<EOF
$LOAD
opt FUT_KNOB_A default_a
if {[lsearch -exact \$::flow(knobs) FUT_KNOB_A] < 0} {
    puts "opt did not register the knob; knobs = \$::flow(knobs)"
    exit 1
}
if {\$::FUT_KNOB_A ne "default_a"} { puts "wrong value: \$::FUT_KNOB_A"; exit 3 }
opt FUT_KNOB_A default_a
if {[llength [lsearch -all -exact \$::flow(knobs) FUT_KNOB_A]] != 1} {
    puts "a re-read registered the knob twice: \$::flow(knobs)"
    exit 1
}
exit 0
EOF

# Environment wins - but a whitespace-only value does NOT. An exported-but-empty
# variable is how a Makefile spells "I have nothing to say about this knob", and
# treating it as a value overrides a considered default with the empty string.
cat > "$D/opt_env.tcl" <<EOF
$LOAD
opt FUT_SET   fallback
opt FUT_BLANK fallback
if {\$::FUT_SET ne "from_env"} { puts "env did not win: \$::FUT_SET"; exit 1 }
if {\$::FUT_BLANK ne "fallback"} {
    puts "a whitespace-only env value overrode the default: '\$::FUT_BLANK'"
    exit 1
}
exit 0
EOF

# flow_env is PLUMBING and must not register. Registering it would put the same
# value in every manifest twice, once as configuration and once as engine
# plumbing the Makefile always supplies.
cat > "$D/flow_env_plumbing.tcl" <<EOF
$LOAD
set before [llength \$::flow(knobs)]
set v [flow_env FUT_SET fallback]
if {\$v ne "from_env"} { puts "flow_env did not read the environment: \$v"; exit 3 }
if {[flow_env FUT_ABSENT fallback] ne "fallback"} { puts "default not honoured"; exit 3 }
if {[llength \$::flow(knobs)] != \$before} {
    puts "flow_env REGISTERED a knob: \$::flow(knobs)"
    exit 1
}
exit 0
EOF

# --- the seam list -----------------------------------------------------------
# seams.txt is the ONE copy of the seam names. These drive flow_seams against a
# mutant toolkit whose seams.txt has been corrupted in one specific way each.
cat > "$D/seams_ok.tcl" <<EOF
$LOAD
set s [flow_seams]
if {![llength \$s]} { puts "no seams"; exit 1 }
foreach n \$s {
    if {![regexp {^[a-z][a-z0-9_]*\$} \$n]} { puts "not a seam name: '\$n'"; exit 1 }
}
if {[llength \$s] != [llength [lsort -unique \$s]]} { puts "duplicate seam: \$s"; exit 1 }
exit 0
EOF
# `die` EXITS; it does not raise, so `catch` cannot trap it - the driver
# reports acceptance and the shell grades the status. (The toolkit's own
# provenance recorder was bitten by exactly this: a catch around a die.)
cat > "$D/seams_reject.tcl" <<EOF
$LOAD
set s [flow_seams]
puts "ACCEPTED a corrupt seams.txt and returned: \$s"
exit 0
EOF

# A mistyped seam at a CALL SITE is worse than a mistyped one in seams.txt: a
# probe that quietly returned 0 leaves the guard it was arming permanently
# disarmed, and nothing in any log says so.
# NO `catch` HERE. flow_seam_assert reports through `die`, and die EXITS - a
# catch around it traps nothing and the driver never resumes, so a catch-based
# driver would report success on the strength of an exit it did not observe.
# Instead: reach the line after the probe only if the guard failed to fire, and
# leave by a code that is NOT die's, so the two outcomes stay distinguishable.
cat > "$D/seam_typo.tcl" <<EOF
$LOAD
set r [flow_hook_exists post_imp]
puts "flow_hook_exists accepted 'post_imp', a seam seams.txt does not declare,"
puts "  and answered '\$r'. Every guard armed through that probe is now off."
exit 9
EOF

# --- hooks -------------------------------------------------------------------
# No hooks directory is the common case and must be silent, not an error.
cat > "$D/hook_none.tcl" <<EOF
$LOAD
if {[flow_hook_exists post_impl]} { puts "claims a hook with no HOOKS_DIR"; exit 1 }
if {[flow_hook_path   post_impl] ne ""} { puts "returned a path with no HOOKS_DIR"; exit 1 }
if {[flow_hook        post_impl] != 0}  { puts "claims to have run one"; exit 1 }
exit 0
EOF

# A hook that runs is ANNOUNCED and RECORDED - ::flow(hooks) is what carries it
# into the stage manifest, which is how a result traces back to the project code
# that shaped it.
cat > "$D/hook_records.tcl" <<EOF
$LOAD
if {![flow_hook_exists post_impl]} { puts "did not see the hook file"; exit 3 }
if {[flow_hook post_impl] != 1}    { puts "did not run the hook"; exit 1 }
if {![llength \$::flow(hooks)]}     { puts "the hook ran but was NOT recorded"; exit 1 }
if {![string match "post_impl*" [lindex \$::flow(hooks) 0]]} {
    puts "recorded under the wrong name: \$::flow(hooks)"
    exit 1
}
exit 0
EOF

# A hook is project code in the critical path. An error inside one STOPS THE
# STAGE - it is not caught and downgraded, and there is no advisory-hook mode.
cat > "$D/hook_aborts.tcl" <<EOF
$LOAD
set rc [catch {flow_hook post_impl} msg]
if {\$rc == 0} {
    puts "a hook that raised an error was DOWNGRADED to advisory and the stage carried on"
    exit 1
}
exit 0
EOF

# uplevel 1, so a hook can adjust a value the stage is about to pass to a tool.
# A hook sourced in its own scope could read the globals and nothing else, which
# rules out the commonest legitimate use.
cat > "$D/hook_uplevel.tcl" <<EOF
$LOAD
proc stage_body {} {
    set local_knob untouched
    flow_hook post_impl
    return \$local_knob
}
set got [stage_body]
if {\$got ne "TOUCHED"} {
    puts "the hook ran in its own scope - it could not reach the stage's variable (got '\$got')"
    exit 1
}
exit 0
EOF

# --- steps and project overrides ---------------------------------------------
# A project replaces a step WHOLESALE. There is no merging: the toolkit's copy
# is not sourced at all, and the log says so on the line it happens.
cat > "$D/step_override.tcl" <<EOF
$LOAD
set ::marks {}
flow_step report_setup
if {[lsearch -exact \$::marks OVERRIDE] < 0} {
    puts "the project override did NOT run; marks = \$::marks"
    exit 1
}
if {[lsearch -exact \$::marks TOOLKIT] >= 0} {
    puts "the toolkit's own step file was ALSO sourced - this is a merge, not an override"
    exit 1
}
if {[lsearch -glob \$::flow(steps) "report_setup=PROJECT OVERRIDE"] < 0} {
    puts "the override was not recorded for the manifest: \$::flow(steps)"
    exit 1
}
exit 0
EOF

# THE VALID STEP LIST IS THE DIRECTORY, never a literal. The reference toolkit
# hardcodes a five-entry whitelist against a seven-file directory, so two real
# extension points are undocumented and warn spuriously.
cat > "$D/steps_from_dir.tcl" <<EOF
$LOAD
set dir [file join \$env(TK) flow steps]
set want {}
foreach f [lsort [glob -nocomplain -directory \$dir *.tcl]] {
    lappend want [file rootname [file tail \$f]]
}
set got [flow_steps_available]
if {\$got ne \$want} { puts "directory says '\$want' but the proc says '\$got'"; exit 1 }
exit 0
EOF

# --- the knob census ---------------------------------------------------------
# A STATIC scan: it must READ the files, never run them. `make help-knobs` has
# to answer "what can I tune?" without launching Vivado and without executing
# project override code.
cat > "$D/knob_scan.tcl" <<EOF
$LOAD
set got [flow_knob_scan \$env(SUBJECT)]
set names {}
foreach row \$got { lappend names [lindex \$row 0] }
if {[lsearch -exact \$names REAL_KNOB] < 0} { puts "missed a declaration: \$names"; exit 1 }
if {[lsearch -exact \$names COMMENTED_KNOB] >= 0} {
    puts "counted an 'opt' inside a COMMENT as a declaration: \$names"
    exit 1
}
if {[lsearch -exact \$names INDENTED_KNOB] >= 0} {
    puts "counted an indented 'opt' as a declaration: \$names"
    exit 1
}
if {[file exists [file join \$env(SUBJECT) RAN]]} {
    puts "the scan EXECUTED the file it was meant to read"
    exit 1
}
set row [lindex \$got [lsearch -index 0 -exact \$got REAL_KNOB]]
if {[lindex \$row 1] ne "the default"} {
    puts "default mis-parsed as '[lindex \$row 1]' - a trailing ;# comment leaked in"
    exit 1
}
exit 0
EOF

# --- the part/board shim -----------------------------------------------------
# ::part_alias is THE ONLY PLACE in the engine where a pack's spelling appears.
#
# Driven over EVERY row of the shipped table rather than one spelling written
# out here. The table is the data; a driver carrying its own copy of one row
# goes quietly vacuous the day that row is deleted, and that is not
# hypothetical - this driver used to name 'name -> part_name', which was deleted
# on 2026-09-11 as a duplicate of part/pack_api.tcl's own table.
#
# The stub pack API knows the alias TARGETS AND NOTHING ELSE, so every NAME in
# the table has to arrive at its value THROUGH the alias and has no other way in.
cat > "$D/pack_alias.tcl" <<EOF
$LOAD
set ::targets {}
foreach n [array names ::part_alias] { lappend ::targets \$::part_alias(\$n) }
proc part_has  {k} { return [expr {[lsearch -exact \$::targets \$k] >= 0}] }
proc part_get  {k} { if {[part_has \$k]} { return "VALUE:\$k" } ; error "no key \$k" }
proc part_keys {}  { return \$::targets }
foreach n [array names ::part_alias] {
    if {[part \$n] ne "VALUE:\$::part_alias(\$n)"} {
        puts "'part \$n' did not resolve through the alias to \$::part_alias(\$n)"
        exit 1
    }
    if {![part_have \$n]} { puts "'part_have \$n' said no for a key the alias reaches"; exit 1 }
}
foreach t \$::targets {
    if {[part \$t] ne "VALUE:\$t"} { puts "the direct key '\$t' broke"; exit 3 }
}
exit 0
EOF

# How many rows the shipped table has. A table with none makes the driver above
# prove nothing, which is a SKIP with the reason and never a green line - and
# the shell has to be the one to decide that, because the driver cannot report
# "inapplicable" and "held" through the same exit status.
cat > "$D/alias_count.tcl" <<EOF
$LOAD
puts [array size ::part_alias]
EOF

# --- the alias tables against the real schema --------------------------------
# The whole point of flow_pack_alias_check is that it runs against the REAL
# pack schema, so this driver loads the real part/pack_api.tcl out of \$env(TK)
# rather than stubbing one. No pack is loaded and none is needed: the check
# validates the table against what the SCHEMA declares, which part/pack_api.tcl
# builds at source time, not against what any one pack happens to set.
cat > "$D/pack_shim_real.tcl" <<EOF
$LOAD
source [file join \$env(TK) part pack_api.tcl]
flow_pack_shim
exit 0
EOF

# $1 = driver, $2 = "" to require a clean bind, else a substring the refusal
# must carry. Asserting the WORDING and not just the exit status is what keeps
# these proofs honest: the good case here is a clean bind, so every planted
# fault shows up as a refusal, and a proof that accepted any non-zero exit would
# pass just as happily against a mutant whose sed merely broke the Tcl.
cat > "$D/alias_wording.sh" <<'SH_EOF'
#!/bin/sh
out="$(TK="$TK" tclsh "$1" 2>&1)"; rc=$?
if [ -z "$2" ]; then
  [ "$rc" -eq 0 ] || { echo "exit $rc, wanted 0 - the shipped tables did not validate:"; echo "$out"; exit 1; }
  printf '%s' "$out" | grep -qF -- "pack accessors bound" \
    || { echo "the shim exited 0 without reporting a bind:"; echo "$out"; exit 1; }
  for tbl in ::part_alias ::board_alias; do
    printf '%s' "$out" | grep -qF -- "$tbl: " \
      || { echo "the shim bound without $tbl reporting that it was checked:"; echo "$out"; exit 1; }
  done
  exit 0
fi
[ "$rc" -eq 1 ] || { echo "exit $rc, wanted 1 - a check ran and came out red:"; echo "$out"; exit 1; }
printf '%s' "$out" | grep -qF -- "FLOW-FAIL" || { echo "not a die - no FLOW-FAIL in:"; echo "$out"; exit 1; }
printf '%s' "$out" | grep -qF -- "$2" || { echo "refused, but not for '$2':"; echo "$out"; exit 1; }
exit 0
SH_EOF
chmod +x "$D/alias_wording.sh"

# part_have must PROBE, not die. A pack API may treat an unknown key as an
# error; the engine needs the probing form, so the native call is wrapped once
# here rather than guarded at forty call sites.
cat > "$D/pack_probe.tcl" <<EOF
$LOAD
proc part_get  {k} { error "this pack API treats an unknown key as an ERROR: \$k" }
proc part_has  {k} { error "this pack API treats an unknown key as an ERROR: \$k" }
proc part_keys {}  { return {} }
set rc [catch {part_have no_such_key} msg]
if {\$rc != 0} { puts "part_have DIED on an unknown key instead of answering 'no': \$msg"; exit 1 }
if {\$msg != 0} { puts "part_have said '\$msg' for a key the pack does not have"; exit 1 }
exit 0
EOF

# The shim binds over a pack API that must already be loaded. When it is not,
# say which command is missing - not "invalid command name" forty lines later.
# exit 9, not 1: `die` already exits 1, so a driver that also left by 1 would
# make the correct refusal and the silent binding look identical to the shell.
cat > "$D/pack_shim_missing.tcl" <<EOF
$LOAD
flow_pack_shim
puts "flow_pack_shim bound accessors over a pack API THAT DOES NOT EXIST"
exit 9
EOF

# --- try_step ----------------------------------------------------------------
# For OPTIONAL work only. It reports 0 on failure so the caller can tell, and
# carries on. Its own header warns what happens when it wraps a core step.
cat > "$D/try_step.tcl" <<EOF
$LOAD
set ::reached 0
if {[try_step "a step that fails" { error "planted" }] != 0} {
    puts "try_step reported SUCCESS for a body that raised an error"
    exit 1
}
set ::reached 1
if {[try_step "a step that works" { set ::x 1 }] != 1} {
    puts "try_step reported failure for a body that worked"
    exit 3
}
if {!\$::reached} { puts "try_step did not carry on"; exit 3 }
exit 0
EOF

# --- idempotent re-source ----------------------------------------------------
# read_flist.tcl and several helpers source this file; a second source must be a
# no-op rather than tripping the shadow guard against the file's own procs.
cat > "$D/idempotent.tcl" <<EOF
$LOAD
$LOAD
if {[llength [info commands flow_boot]] != 1} { puts "flow_boot vanished"; exit 3 }
exit 0
EOF

#=============================================================================
# FIXTURES
#=============================================================================

# A hooks directory with three post_impl hooks, used one at a time.
HK_OK="$SB/hooks_ok";     mkdir -p "$HK_OK"
HK_BAD="$SB/hooks_bad";   mkdir -p "$HK_BAD"
HK_UP="$SB/hooks_uplevel"; mkdir -p "$HK_UP"
printf 'set ::hook_ran 1\n'                          > "$HK_OK/post_impl.tcl"
printf 'error "this hook is broken on purpose"\n'    > "$HK_BAD/post_impl.tcl"
printf 'set local_knob TOUCHED\n'                    > "$HK_UP/post_impl.tcl"

# A knob-census fixture: one real declaration, one commented out, one indented,
# and a side effect that proves whether the file was read or run.
KS="$SB/knobscan"; mkdir -p "$KS"
cat > "$KS/steps.tcl" <<'EOF'
# A knob census must READ this file, not run it.
set fh [open [file join [file dirname [info script]] RAN] w]; close $fh
opt REAL_KNOB {the default}   ;# a trailing comment the scan has to strip
# opt COMMENTED_KNOB never
    opt INDENTED_KNOB also_never
EOF

#=============================================================================
# ASSERTIONS
#=============================================================================
#-----------------------------------------------------------------------------
# ONE MUTANT PER PROOF.
#
# A shared mutant ACCUMULATES faults, and the proof that runs fifteenth then
# passes or fails for the first proof's reason. That is the same "this proved
# nothing" failure the proofs exist to catch, wearing the costume of a green
# line - and it happened here on the first run of this file: the seam-assertion
# proof and the pack-shim proof both reported red against a mutant carrying
# eleven unrelated faults, and both were correct in isolation.
#
# Mutants are cheap - this repository is well under a megabyte of text - so each
# proof gets a clean one. y_mut dies loudly rather than returning an empty path,
# because `t_mutate ""` would go on to edit nothing and skip.
#-----------------------------------------------------------------------------
y_mut() {
    local m; m="$(t_mutant "$SB" "$1")"
    [ -n "$m" ] && [ -d "$m" ] || { echo "could not copy the toolkit for '$1'" >&2; return 2; }
    printf '%s' "$m"
}

t_head "the shadow guard: proc REPLACES a command, silently"
t_check futils.shadow "sourcing into an interpreter that already defines 'part' is an ERROR, naming the collision" \
    env TK="$FLOW_DIR" tclsh "$D/shadow.tcl"
M="$(y_mut shadow)" || M=""
if t_mutate "$M" "$FU_REL" 's/^    flow_pack_read part board part_have board_have$/    flow_pack_read/'; then
    t_check_fail futils.shadow.mutation "with part/board dropped from the guard list, flow_utils.tcl overwrites them in silence" \
        env TK="$M" tclsh "$D/shadow.tcl"
else
    t_skip futils.shadow.mutation "the guard's name list has been reformatted - the sed expression no longer matches, so no fault could be planted"
fi

t_head "flow_config rejects a key it does not declare"
t_check futils.config.typo "'flow_config stict 1' is an error, and the real key still works" \
    env TK="$FLOW_DIR" tclsh "$D/config_typo.tcl"
M="$(y_mut config-typo)" || M=""
if t_mutate "$M" "$FU_REL" 's/if {!\[info exists ::flow($key)\]} {/if {0} {/'; then
    t_check_fail futils.config.typo.mutation "without the declared-key check a typo silently creates a key nothing reads" \
        env TK="$M" tclsh "$D/config_typo.tcl"
else
    t_skip futils.config.typo.mutation "flow_config's guard has been rewritten - the sed expression no longer matches"
fi

t_head "exit 1 and exit 2 are different answers (CONTRACT.md section 10)"
t_check futils.exit.die "die exits 1 - a check ran and came out red" \
    sh -c 'TK="$1" tclsh "$2"; [ $? -eq 1 ]' _ "$FLOW_DIR" "$D/die.tcl"
t_check futils.exit.refuse "flow_refuse exits 2 - nothing was measured at all" \
    sh -c 'TK="$1" tclsh "$2"; [ $? -eq 2 ]' _ "$FLOW_DIR" "$D/refuse.tcl"
M="$(y_mut exit-die)" || M=""
if t_mutate "$M" "$FU_REL" '/^proc die/,/^}/s/^    exit 1$/    exit 0/'; then
    t_check_fail futils.exit.die.mutation "with die exiting 0 a failed check reports success and the stage graph carries on to the next stage" \
        sh -c 'TK="$1" tclsh "$2"; [ $? -eq 1 ]' _ "$M" "$D/die.tcl"
else
    t_skip futils.exit.die.mutation "die no longer contains a bare 'exit 1' line"
fi
M="$(y_mut exit-refuse)" || M=""
if t_mutate "$M" "$FU_REL" '/^proc flow_refuse/,/^}/s/^    exit 2$/    exit 1/'; then
    t_check_fail futils.exit.refuse.mutation "with flow_refuse exiting 1, a broken contract is indistinguishable from a failed check" \
        sh -c 'TK="$1" tclsh "$2"; [ $? -eq 2 ]' _ "$M" "$D/refuse.tcl"
else
    t_skip futils.exit.refuse.mutation "flow_refuse no longer contains a bare 'exit 2' line"
fi

t_head "flow_assert_input: the three shapes of an unusable input"
t_check futils.input.zero "a ZERO-BYTE file is refused, and named as truncated" \
    env TK="$FLOW_DIR" "$D/input_wording.sh" "$D/input_zero.tcl" "$SB/subject_zero.f" "ZERO BYTES" ""
t_check futils.input.absent "an ABSENT file is refused, and is NOT called zero bytes" \
    env TK="$FLOW_DIR" "$D/input_wording.sh" "$D/input_absent.tcl" "$SB/no_such.f" "no file at" "ZERO BYTES"
t_check futils.input.emptydir "an EMPTY DIRECTORY is refused - every 'test -d' is satisfied by one" \
    env TK="$FLOW_DIR" "$D/input_wording.sh" "$D/input_emptydir.tcl" "$SB/subject_empty" "EMPTY" ""
M="$(y_mut input-zero)" || M=""
if t_mutate "$M" "$FU_REL" 's/    if {!\[file size $path\]} {/    if {0} {/'; then
    t_check_fail futils.input.zero.mutation "with the size test removed a truncated flist is accepted, and the tool builds from nothing" \
        env TK="$M" "$D/input_wording.sh" "$D/input_zero.tcl" "$SB/subject_zero2.f" "ZERO BYTES" ""
else
    t_skip futils.input.zero.mutation "the zero-byte test has been rewritten - the sed expression no longer matches"
fi
M="$(y_mut input-absent)" || M=""
if t_mutate "$M" "$FU_REL" 's/^    if {!\[file exists $path\]} {$/    if {0} {/'; then
    t_check_fail futils.input.absent.mutation "with the existence test removed an absent file is reported as ZERO BYTES, sending the reader after a file that is not there" \
        env TK="$M" "$D/input_wording.sh" "$D/input_absent.tcl" "$SB/no_such2.f" "no file at" "ZERO BYTES"
else
    t_skip futils.input.absent.mutation "the existence test has been rewritten - the sed expression no longer matches"
fi
M="$(y_mut input-emptydir)" || M=""
if t_mutate "$M" "$FU_REL" 's/        if {!\[llength \[glob -nocomplain -directory $path \*\]\]} {/        if {0} {/'; then
    t_check_fail futils.input.emptydir.mutation "with the glob removed an empty autofs mount point passes as a populated IP repository" \
        env TK="$M" "$D/input_wording.sh" "$D/input_emptydir.tcl" "$SB/subject_empty2" "EMPTY" ""
else
    t_skip futils.input.emptydir.mutation "the empty-directory test has been rewritten - the sed expression no longer matches"
fi

t_head "opt: a knob is registered by the ACT of reading it"
t_check futils.opt.registers "opt records the name once, however often it is read" \
    env TK="$FLOW_DIR" tclsh "$D/opt_registers.tcl"
t_check futils.opt.env "the environment wins, but a whitespace-only value does not" \
    env TK="$FLOW_DIR" FUT_SET=from_env FUT_BLANK="   " tclsh "$D/opt_env.tcl"
t_check futils.opt.plumbing "flow_env reads the environment WITHOUT registering a knob" \
    env TK="$FLOW_DIR" FUT_SET=from_env tclsh "$D/flow_env_plumbing.tcl"
M="$(y_mut opt-registers)" || M=""
if t_mutate "$M" "$FU_REL" 's/    if {\[lsearch -exact $::flow(knobs) $name\] < 0} { lappend ::flow(knobs) $name }//'; then
    t_check_fail futils.opt.registers.mutation "with the registration dropped, a tuned knob never reaches the run manifest" \
        env TK="$M" tclsh "$D/opt_registers.tcl"
else
    t_skip futils.opt.registers.mutation "opt's registration line has been rewritten - the sed expression no longer matches"
fi
M="$(y_mut opt-env)" || M=""
if t_mutate "$M" "$FU_REL" 's/\[string trim $::env($name)\] ne ""/1/g'; then
    t_check_fail futils.opt.env.mutation "without the trim, an exported-but-empty variable overrides a considered default with nothing" \
        env TK="$M" FUT_SET=from_env FUT_BLANK="   " tclsh "$D/opt_env.tcl"
else
    t_skip futils.opt.env.mutation "the whitespace test has been rewritten - the sed expression no longer matches"
fi
M="$(y_mut opt-plumbing)" || M=""
if t_mutate "$M" "$FU_REL" 's/^proc flow_env {name {default ""}} {$/proc flow_env {name {default ""}} { lappend ::flow(knobs) $name/'; then
    t_check_fail futils.opt.plumbing.mutation "with flow_env registering too, engine plumbing appears in the manifest as configuration" \
        env TK="$M" FUT_SET=from_env tclsh "$D/flow_env_plumbing.tcl"
else
    t_skip futils.opt.plumbing.mutation "flow_env's signature has changed - the sed expression no longer matches"
fi

t_head "the seam list is data, and it is validated"
t_check futils.seams.ok "the shipped seams.txt parses: names well formed, no duplicates, not empty" \
    env TK="$FLOW_DIR" tclsh "$D/seams_ok.tcl"

S_DUP="$(t_mutant "$SB" seams-dup)"
S_BAD="$(t_mutant "$SB" seams-bad)"
S_NIL="$(t_mutant "$SB" seams-nil)"
SEAMS_REL="flow/common/seams.txt"
FIRST_SEAM="$(grep -m1 -E '^[a-z][a-z0-9_]*$' "$FLOW_DIR/$SEAMS_REL" 2>/dev/null)"
if [ -n "$FIRST_SEAM" ]; then
    printf '%s\n' "$FIRST_SEAM" >> "$S_DUP/$SEAMS_REL"
    t_check futils.seams.duplicate "a seam declared twice is refused - it makes the census disagree with the list" \
        sh -c 'TK="$1" tclsh "$2"; [ $? -eq 1 ]' _ "$S_DUP" "$D/seams_reject.tcl"
else
    t_skip futils.seams.duplicate "no well-formed seam name in $SEAMS_REL to duplicate"
fi
printf 'Post-Route\n' >> "$S_BAD/$SEAMS_REL"
t_check futils.seams.badname "a name no shell glob could match is refused, with the line number" \
    sh -c 'TK="$1" tclsh "$2"; [ $? -eq 1 ]' _ "$S_BAD" "$D/seams_reject.tcl"
printf '# every seam commented out\n' > "$S_NIL/$SEAMS_REL"
t_check futils.seams.empty "an empty seam list is refused - it disables every project hook silently" \
    sh -c 'TK="$1" tclsh "$2"; [ $? -eq 1 ]' _ "$S_NIL" "$D/seams_reject.tcl"

if t_mutate "$S_DUP" "$FU_REL" 's/        if {\[lsearch -exact $out $line\] >= 0} {/        if {0} {/'; then
    t_check_fail futils.seams.duplicate.mutation "with the duplicate check removed the second declaration is accepted" \
        sh -c 'TK="$1" tclsh "$2"; [ $? -eq 1 ]' _ "$S_DUP" "$D/seams_reject.tcl"
else
    t_skip futils.seams.duplicate.mutation "the duplicate check has been rewritten - the sed expression no longer matches"
fi
if t_mutate "$S_BAD" "$FU_REL" 's/regexp {\^\[a-z\]\[a-z0-9_\]\*\$} $line/regexp {^.*$} $line/'; then
    t_check_fail futils.seams.badname.mutation "with the name pattern loosened, 'Post-Route' is accepted as a seam no hook file can ever match" \
        sh -c 'TK="$1" tclsh "$2"; [ $? -eq 1 ]' _ "$S_BAD" "$D/seams_reject.tcl"
else
    t_skip futils.seams.badname.mutation "the seam-name pattern has been rewritten - the sed expression no longer matches"
fi
if t_mutate "$S_NIL" "$FU_REL" 's/^    if {!\[llength $out\]} {$/    if {0} {/'; then
    t_check_fail futils.seams.empty.mutation "with the emptiness check removed, a commented-out seams.txt disables every hook and says nothing" \
        sh -c 'TK="$1" tclsh "$2"; [ $? -eq 1 ]' _ "$S_NIL" "$D/seams_reject.tcl"
else
    t_skip futils.seams.empty.mutation "the emptiness check has been rewritten - the sed expression no longer matches"
fi

t_head "a mistyped seam at a CALL SITE disarms a guard permanently"
t_check futils.seam.typo "flow_hook_exists dies on a seam seams.txt does not declare" \
    sh -c 'TK="$1" FPGA_HOOKS_DIR="$2" tclsh "$3"; [ $? -eq 1 ]' _ "$FLOW_DIR" "$HK_OK" "$D/seam_typo.tcl"
M="$(y_mut seam-typo)" || M=""
if t_mutate "$M" "$FU_REL" 's/    if {\[lsearch -exact $seams $name\] >= 0} { return 1 }/    return 1/'; then
    t_check_fail futils.seam.typo.mutation "with the seam assertion neutered a typo'd probe answers 'no hook' forever, in silence" \
        sh -c 'TK="$1" FPGA_HOOKS_DIR="$2" tclsh "$3"; [ $? -eq 1 ]' _ "$M" "$HK_OK" "$D/seam_typo.tcl"
else
    t_skip futils.seam.typo.mutation "flow_seam_assert has been rewritten - the sed expression no longer matches"
fi

t_head "hooks: optional, announced, recorded, and able to abort"
t_check futils.hook.none "no HOOKS_DIR is the common case: 0, no path, no error" \
    env TK="$FLOW_DIR" tclsh "$D/hook_none.tcl"
t_check futils.hook.records "a hook that runs lands in the manifest record under its seam name" \
    env TK="$FLOW_DIR" FPGA_HOOKS_DIR="$HK_OK" tclsh "$D/hook_records.tcl"
t_check futils.hook.aborts "a hook that raises an error STOPS the stage - there is no advisory-hook mode" \
    env TK="$FLOW_DIR" FPGA_HOOKS_DIR="$HK_BAD" tclsh "$D/hook_aborts.tcl"
t_check futils.hook.uplevel "a hook runs in the CALLER's scope, so it can adjust what the stage is about to use" \
    env TK="$FLOW_DIR" FPGA_HOOKS_DIR="$HK_UP" tclsh "$D/hook_uplevel.tcl"
M="$(y_mut hook-records)" || M=""
if t_mutate "$M" "$FU_REL" 's/^    lappend ::flow(hooks) "${name}(${dt}s)"$//'; then
    t_check_fail futils.hook.records.mutation "with the record dropped, a result no longer traces to the project code that shaped it" \
        env TK="$M" FPGA_HOOKS_DIR="$HK_OK" tclsh "$D/hook_records.tcl"
else
    t_skip futils.hook.records.mutation "the hook record line has been rewritten - the sed expression no longer matches"
fi
M="$(y_mut hook-aborts)" || M=""
if t_mutate "$M" "$FU_REL" 's/^        return -options $opts $msg$/        return 0/'; then
    t_check_fail futils.hook.aborts.mutation "with the re-raise removed a broken hook is downgraded to a warning and the stage ships anyway" \
        env TK="$M" FPGA_HOOKS_DIR="$HK_BAD" tclsh "$D/hook_aborts.tcl"
else
    t_skip futils.hook.aborts.mutation "the hook abort path has been rewritten - the sed expression no longer matches"
fi
M="$(y_mut hook-uplevel)" || M=""
if t_mutate "$M" "$FU_REL" 's/    if {\[catch {uplevel 1 \[list source $path\]} msg opts\]} {/    if {[catch {source $path} msg opts]} {/'; then
    t_check_fail futils.hook.uplevel.mutation "sourced in its own scope a hook can read the globals and nothing else" \
        env TK="$M" FPGA_HOOKS_DIR="$HK_UP" tclsh "$D/hook_uplevel.tcl"
else
    t_skip futils.hook.uplevel.mutation "flow_hook's source call has been rewritten - the sed expression no longer matches"
fi

t_head "steps: a project override replaces the file WHOLESALE"
OV="$SB/overrides"; mkdir -p "$OV"
S_OVR="$(t_mutant "$SB" step-override)"
printf 'lappend ::marks OVERRIDE\n' > "$OV/report_setup.tcl"
# The toolkit's own copy gets a marker too, so "was it also sourced?" is a
# question this suite can answer rather than assume.
printf '\nlappend ::marks TOOLKIT\n' >> "$S_OVR/flow/steps/report_setup.tcl"
t_check futils.step.override "the override runs, the toolkit's copy does not, and the manifest records which" \
    env TK="$S_OVR" FPGA_OVERRIDES_DIR="$OV" tclsh "$D/step_override.tcl"
if t_mutate "$S_OVR" "$FU_REL" 's/    if {$ovr ne "" && \[file exists \[file join $ovr ${name}.tcl\]\]} {/    if {0} {/'; then
    t_check_fail futils.step.override.mutation "with the override branch removed the project's file is ignored and the toolkit's runs instead" \
        env TK="$S_OVR" FPGA_OVERRIDES_DIR="$OV" tclsh "$D/step_override.tcl"
else
    t_skip futils.step.override.mutation "flow_step's override branch has been rewritten - the sed expression no longer matches"
fi
t_check futils.steps.from_dir "flow_steps_available is derived from the directory, not from a literal list" \
    env TK="$FLOW_DIR" tclsh "$D/steps_from_dir.tcl"

t_head "the knob census READS the files; it does not run them"
t_check futils.knobscan "one declaration found, a commented and an indented one ignored, the trailing ;# stripped, nothing executed" \
    env TK="$FLOW_DIR" SUBJECT="$KS" tclsh "$D/knob_scan.tcl"
rm -f "$KS/RAN"
M="$(y_mut knobscan)" || M=""
if t_mutate "$M" "$FU_REL" 's/{\^opt\[/{opt[/'; then
    t_check_fail futils.knobscan.mutation "with the left-margin anchor dropped, an 'opt' inside a comment is reported as a tunable knob" \
        env TK="$M" SUBJECT="$KS" tclsh "$D/knob_scan.tcl"
else
    t_skip futils.knobscan.mutation "the declaration pattern has been rewritten - the sed expression no longer matches"
fi
rm -f "$KS/RAN"

t_head "the pack shim: one alias table, and a probe that never dies"
# EVERY row of the shipped table, or a skip saying there were none. A table with
# no rows leaves nothing for the alias path to resolve, and a green line under
# that would report a property that was never exercised.
N_ALIAS="$(env TK="$FLOW_DIR" tclsh "$D/alias_count.tcl" 2>/dev/null | tail -1)"
case "${N_ALIAS:-x}" in
    ''|*[!0-9]*) N_ALIAS=-1 ;;
esac
if [ "$N_ALIAS" -gt 0 ]; then
    t_check futils.pack.alias "every spelling in ::part_alias resolves to its target's value, and the targets still resolve directly" \
        env TK="$FLOW_DIR" tclsh "$D/pack_alias.tcl"
else
    t_skip futils.pack.alias "::part_alias holds no rows (count reported: ${N_ALIAS}), so there is no aliased spelling to resolve - the property is unexercised, not satisfied"
fi
t_check futils.pack.probe "part_have answers 'no' for a pack API that treats an unknown key as an error" \
    env TK="$FLOW_DIR" tclsh "$D/pack_probe.tcl"
t_check futils.pack.shim_missing "flow_pack_shim names the missing accessor instead of failing later inside a stage" \
    sh -c 'TK="$1" tclsh "$2"; [ $? -eq 1 ]' _ "$FLOW_DIR" "$D/pack_shim_missing.tcl"
M="$(y_mut pack-alias)" || M=""
if t_mutate "$M" "$FU_REL" 's/    if {\[info exists tbl($key)\] && $tbl($key) ne $key} { lappend names $tbl($key) }//'; then
    t_check_fail futils.pack.alias.mutation "without the alias lookup the engine dies on a pack that spells the key its own way" \
        env TK="$M" tclsh "$D/pack_alias.tcl"
else
    t_skip futils.pack.alias.mutation "the alias lookup has been rewritten - the sed expression no longer matches"
fi
M="$(y_mut pack-probe)" || M=""
if t_mutate "$M" "$FU_REL" 's/^    if {$mode eq "have"} { return 0 }$//'; then
    t_check_fail futils.pack.probe.mutation "without the probe's early return, asking whether a key exists KILLS the stage" \
        env TK="$M" tclsh "$D/pack_probe.tcl"
else
    t_skip futils.pack.probe.mutation "flow_pack_read's probe return has been rewritten - the sed expression no longer matches"
fi
# ALL FOUR of the shim's refusals go at once, and they have to: with only the
# _get and _has tests neutered the shim reaches flow_pack_alias_check, which
# calls ${domain}_keys on a pack API that is not there and leaves by a raw Tcl
# error - also exit 1. The proof would then pass for a reason it did not
# measure. One fault per copy still holds; the fault is "this shim refuses
# nothing", and it now takes four edits to express.
M="$(y_mut pack-shim_missing)" || M=""
if t_mutate "$M" "$FU_REL" -e 's/        if {!\[flow_have ${domain}_get\]} {/        if {0} {/' \
                                 -e 's/        if {!\[flow_have ${domain}_has\]} {/        if {0} {/' \
                                 -e 's/        if {!\[flow_have ${domain}_keys\]} {/        if {0} {/' \
                                 -e 's/^        flow_pack_alias_check $domain$//'; then
    t_check_fail futils.pack.shim_missing.mutation "with every one of the shim's refusals removed it reports success over a pack API that was never loaded" \
        sh -c 'TK="$1" tclsh "$2"; [ $? -eq 1 ]' _ "$M" "$D/pack_shim_missing.tcl"
else
    t_skip futils.pack.shim_missing.mutation "flow_pack_shim's accessor checks have been rewritten - the sed expressions no longer match"
fi

t_head "the alias tables are CHECKED against the pack schema, not merely read"
#-----------------------------------------------------------------------------
# WHY THESE PROOFS USE t_check AND NOT t_check_fail.
#
# Everywhere else in this file the good case is a REFUSAL and the planted fault
# makes the toolkit accept, so "the assertion went non-zero" is the whole
# property. Here it runs the other way round: the good case is a CLEAN BIND and
# the planted fault is a bad row in the alias table, so the fault shows up AS
# the refusal. A t_check_fail would then go green against any non-zero exit -
# including a mutant whose sed merely broke the Tcl, which is a proof that
# cannot tell the fault it planted from a typo. So each mutant below is asserted
# to exit 1 AND to name the row it rejected and why. The ids still carry
# `.mutation`, which is what test/MUTATION_COVERAGE counts.
#
# `device -> part_name` is not an invented fault. It is the row that stood in
# ::part_alias until 2026-09-08, reproduced character for character: it was
# found by reading, and the check below is what would have found it instead.
#-----------------------------------------------------------------------------

# Plant ONE extra row in ::part_alias, in its own copy of the toolkit. Prints
# the mutant path, or nothing when the sed no longer matches - which the caller
# turns into a SKIP with the reason, never a silent pass.
y_part_row() {
    local m; m="$(y_mut "$1")" || return 1
    [ -n "$m" ] || return 1
    t_mutate "$m" "$FU_REL" \
        "s/^array set ::part_alias {\$/array set ::part_alias {\\n    $2/" || return 1
    printf '%s' "$m"
}

t_check futils.pack.alias_schema "the SHIPPED ::part_alias and ::board_alias validate against the real pack schema, and the shim SAYS it checked them" \
    env TK="$FLOW_DIR" "$D/alias_wording.sh" "$D/pack_shim_real.tcl" ""

M="$(y_part_row alias-dead 'device      part_name')"
if [ -n "$M" ]; then
    t_check futils.pack.alias_schema.mutation.dead "the 2026-09-08 row put back - 'device -> part_name' - is refused as one that can NEVER FIRE, because 'device' is a schema key in its own right" \
        env TK="$M" "$D/alias_wording.sh" "$D/pack_shim_real.tcl" "'device' IS A part SCHEMA KEY"
else
    t_skip futils.pack.alias_schema.mutation.dead "could not plant the row: the 'array set ::part_alias {' line in $FU_REL has changed shape, so the sed expression no longer matches"
fi

M="$(y_part_row alias-target 'widget      no_such_key')"
if [ -n "$M" ]; then
    t_check futils.pack.alias_schema.mutation.target "a row whose TARGET is not a schema key is refused, naming the target rather than the key a stage would have asked for" \
        env TK="$M" "$D/alias_wording.sh" "$D/pack_shim_real.tcl" "'no_such_key' is not a part schema key"
else
    t_skip futils.pack.alias_schema.mutation.target "could not plant the row: the 'array set ::part_alias {' line in $FU_REL has changed shape"
fi

# 'zork' is deliberately NOT a schema key. A self-map whose name IS one would be
# caught by the never-fires test too, and the proof could not then say which of
# the two checks did the work.
M="$(y_part_row alias-selfmap 'zork        zork')"
if [ -n "$M" ]; then
    t_check futils.pack.alias_schema.mutation.selfmap "a row mapping a name to ITSELF is refused as the no-op it is - flow_pack_read skips it by construction" \
        env TK="$M" "$D/alias_wording.sh" "$D/pack_shim_real.tcl" "AN ALIAS FROM A NAME TO ITSELF"
else
    t_skip futils.pack.alias_schema.mutation.selfmap "could not plant the row: the 'array set ::part_alias {' line in $FU_REL has changed shape"
fi

# part/pack_api.tcl's own table maps part,speed -> speed_grade. flow_pack_read
# probes the raw key first, so the pack API answers it and this row is inert.
M="$(y_part_row alias-shadowed 'speed       speed_grade')"
if [ -n "$M" ]; then
    t_check futils.pack.alias_schema.mutation.shadowed "a spelling part/pack_api.tcl ALREADY resolves to the same target is refused - that is the 'there should not be two' hazard, per spelling" \
        env TK="$M" "$D/alias_wording.sh" "$D/pack_shim_real.tcl" "part/pack_api.tcl ALREADY resolves 'speed'"
else
    t_skip futils.pack.alias_schema.mutation.shadowed "could not plant the row: the 'array set ::part_alias {' line in $FU_REL has changed shape"
fi

# The worse half of the same hazard: part,arch -> family in the pack API, so the
# engine returns family while this table documents device. The pack API wins.
M="$(y_part_row alias-diverted 'arch        device')"
if [ -n "$M" ]; then
    t_check futils.pack.alias_schema.mutation.diverted "a spelling the two tables resolve DIFFERENTLY is refused, and the message says which one the engine actually returns" \
        env TK="$M" "$D/alias_wording.sh" "$D/pack_shim_real.tcl" "resolves 'arch' to 'family'"
else
    t_skip futils.pack.alias_schema.mutation.diverted "could not plant the row: the 'array set ::part_alias {' line in $FU_REL has changed shape"
fi

# One body, two domains - which is only true if the board table is reached. A
# check that looped over `part` alone would pass every proof above.
M="$(y_mut alias-board)" || M=""
if t_mutate "$M" "$FU_REL" 's/^array set ::board_alias {}$/array set ::board_alias {sys_clk_freq_hz oscillator_hz}/'; then
    t_check futils.pack.alias_schema.mutation.board "the BOARD table is validated too, not only the part one" \
        env TK="$M" "$D/alias_wording.sh" "$D/pack_shim_real.tcl" "'sys_clk_freq_hz' IS A board SCHEMA KEY"
else
    t_skip futils.pack.alias_schema.mutation.board "could not plant the row: the 'array set ::board_alias {}' line in $FU_REL has changed shape"
fi

# Deleting the table is the one edit that turns every alias in a domain off in
# SILENCE: flow_pack_read asks `info exists tbl($key)`, which answers 'no entry'
# just as happily for an array that does not exist.
M="$(y_mut alias-no-table)" || M=""
if t_mutate "$M" "$FU_REL" 's/^array set ::board_alias {}$//'; then
    t_check futils.pack.alias_schema.mutation.no_table "a table that has been DELETED is refused - an absent array reads as 'no entry' for every key" \
        env TK="$M" "$D/alias_wording.sh" "$D/pack_shim_real.tcl" "there is no ::board_alias array"
else
    t_skip futils.pack.alias_schema.mutation.no_table "could not delete the table: the 'array set ::board_alias {}' line in $FU_REL has changed shape"
fi

# A GATE NEVER INVENTS A VERDICT FROM MISSING DATA. With the schema listing
# empty there is nothing to validate the table against, and a green line there
# would report a check that measured nothing.
M="$(y_mut alias-no-schema)" || M=""
if t_replace_line "$M" part/pack_api.tcl 'proc pack_keys {role {group ""}} {' 'proc pack_keys {role {group ""}} { return {} ;'; then
    t_check futils.pack.alias_schema.mutation.no_schema "with the schema listing EMPTY the shim refuses, rather than reporting a table it had nothing to check against" \
        env TK="$M" "$D/alias_wording.sh" "$D/pack_shim_real.tcl" "listed no schema keys at all"
else
    t_skip futils.pack.alias_schema.mutation.no_schema "could not empty the listing: pack_keys' proc line in part/pack_api.tcl has changed shape"
fi

t_head "try_step reports what happened, and carries on"
t_check futils.try_step "0 for a body that raised, 1 for one that worked, and the caller continues either way" \
    env TK="$FLOW_DIR" tclsh "$D/try_step.tcl"
M="$(y_mut try_step)" || M=""
if t_mutate "$M" "$FU_REL" 's/skipped: $msg" ; return 0 }/skipped: $msg" ; return 1 }/'; then
    t_check_fail futils.try_step.mutation "with try_step reporting success for a failed body, optional work that silently did nothing reads as done" \
        env TK="$M" tclsh "$D/try_step.tcl"
else
    t_skip futils.try_step.mutation "try_step's return has been rewritten - the sed expression no longer matches"
fi

t_head "the file can be sourced twice"
t_check futils.idempotent "a second source is a no-op, not a collision against this file's own procs" \
    env TK="$FLOW_DIR" tclsh "$D/idempotent.tcl"
M="$(y_mut idempotent)" || M=""
if t_mutate "$M" "$FU_REL" 's/^if {\[info exists ::flow_utils_loaded\]} { return }$//'; then
    t_check_fail futils.idempotent.mutation "without the load guard, re-sourcing trips the shadow check against flow_utils.tcl's own commands" \
        env TK="$M" tclsh "$D/idempotent.tcl"
else
    t_skip futils.idempotent.mutation "the load guard has been rewritten - the sed expression no longer matches"
fi

#-----------------------------------------------------------------------------
# WHAT IS NOT PROVED HERE, AND WHY
#
# 25 of the 28 properties above carry a paired planted-fault proof, 32 proofs in
# all - the alias-table check accounts for eight of them on its own, one per
# shape of row it refuses plus the two ways its own inputs can go missing.
# Three properties carry none, and the reason is that the fault they would plant
# is already planted elsewhere rather than that nobody got to them:
#
#   futils.seams.ok        asserts the SHIPPED seams.txt is well formed. The
#                          three seams.* proofs corrupt a copy of that file in
#                          each of the three ways it can be wrong, which is the
#                          same assertion driven from the other side.
#   futils.steps.from_dir  asserts the step list comes from the directory.
#                          t_seams.sh plants exactly this defect - a hardcoded
#                          five-entry list against a seven-entry directory, the
#                          reference toolkit's own numbers - and is the right
#                          place for it.
#   futils.hook.none       asserts an unset FPGA_HOOKS_DIR yields 0/""/0.
#                          Removing the empty-string guard leaves [file join ""
#                          post_impl.tcl], which does not exist either, so the
#                          proof would pass for the wrong reason. A proof that
#                          cannot distinguish the fault from the fix is worse
#                          than no proof, and saying so is better than shipping
#                          one.
#-----------------------------------------------------------------------------

t_summary
