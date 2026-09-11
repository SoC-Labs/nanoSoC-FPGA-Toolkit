#-----------------------------------------------------------------------------
# mk/flow.mk - the make engine
#
# A consuming project's fpga/Makefile is three lines:
#
#     FPGA_DIR := $(CURDIR)
#     include $(FPGA_DIR)/design.mk
#     include $(FPGA_FLOW_DIR)/mk/flow.mk
#
# design.mk sets FPGA_FLOW_DIR and everything else about the design. This file
# derives the rest, exports it to the Tcl layer, and owns the targets.
#
# THE RULE THIS FILE IS BUILT ON: ASSERT ON ARTEFACTS, NEVER ON EXIT STATUS.
# Vivado exits 0 on a route that did not finish, on timing it did not meet, and
# on a constraint file that matched nothing at all - the third of those has been
# measured on this codebase and only one flow in the tree gates on it
# (CONTRACT.md section 9.3). A stage "passed" means THE ARTEFACT IT WAS
# SUPPOSED TO WRITE IS ON DISK AND SAYS WHAT IT SHOULD, never that the tool
# returned 0. So every stage target below tests for the files the stage should
# have produced, and every failure message names the artefact and prints the
# exact command to run next.
#
# THE SECOND RULE: A GATE NEVER INVENTS A VERDICT FROM MISSING DATA. Where this
# file cannot measure something it says so and fails; it never treats an absent
# artefact as an empty one, and it never treats an unreadable report as a zero.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------

# -- INCLUDE GUARD -----------------------------------------------------------
# Both fpga/Makefile and fpga/design.mk legitimately include this file - the
# Makefile because it is the entry point, design.mk so that it is self-sufficient
# when included directly (CONTRACT.md section 2 requires both). Without a guard,
# doing both redefines every rule: GNU make emits one "overriding recipe for
# target" warning per target and then silently runs the SECOND definition of
# each. Harmless while the two definitions are identical; a trap the moment a
# conditional above them makes them differ, and a warning nobody reads either
# way.
ifndef FPGA_FLOW_MK_INCLUDED
FPGA_FLOW_MK_INCLUDED := 1

# help, not `all`. `all` is a multi-hour unattended build and must never be what
# a bare `make` in the wrong directory starts.
.DEFAULT_GOAL := help

# Every recipe below uses bash constructs - `[[`, PIPESTATUS, `case` fallthrough
# in the X probe. /bin/sh on a Debian-family host is dash and silently does not
# have them.
SHELL := /bin/bash

#-----------------------------------------------------------------------------
# 1. REQUIRED PROJECT VARIABLES - hard $(error) at parse time
#
# CONTRACT.md section 3.1. These three are checked HERE rather than left to
# `make check`, because without any one of them this file cannot even compose a
# path: BLOCK is the stem of every artefact name, BOARD selects the pack that
# supplies PART, and FPGA_FLOW_DIR is where the engine lives. `make check` gives
# the full report on everything else.
#
# A parse-time $(error) also means the failure happens before .DEFAULT_GOAL
# runs, so `make` with no arguments says what is wrong instead of printing a
# help page for a project that cannot build.
#-----------------------------------------------------------------------------

ifeq ($(strip $(FPGA_FLOW_DIR)),)
$(error FPGA_FLOW_DIR is not set. It is the path to this toolkit's checkout, \
and fpga/design.mk must set it - e.g. FPGA_FLOW_DIR := $$(FPGA_DIR)/../fpga-toolkit. \
It is set BY THE PROJECT and never defaulted here: a default would resolve to \
whichever checkout happened to sit at the guessed path)
endif
ifeq ($(strip $(BLOCK)),)
$(error BLOCK is not set in fpga/design.mk. It is the design's short name and \
the stem of every artefact the flow writes - $$(BLOCK).bit, $$(BLOCK)_routed.dcp, \
$$(BLOCK)_synth.dcp - so nothing here can name a file without it)
endif
ifeq ($(strip $(BOARD)),)
$(error BOARD is not set in fpga/design.mk. It selects the board pack at \
$$(BOARD_DIR)/board.tcl, which is what states the part, the platform, the \
system clock and the bin style. The pack lives in the PROJECT, not in this \
toolkit - `ls $$(FPGA_DIR)/board` lists the ones this project has)
endif

FPGA_DIR ?= $(CURDIR)

# -- $(abspath) SPLITS ON WHITESPACE, SO REFUSE WHITESPACE FIRST -------------
# CONTRACT.md section 2 mandates `override FPGA_FLOW_DIR := $(abspath ...)`.
# $(abspath) treats its argument as a SPACE-SEPARATED LIST and returns one
# resolved path per word, so a checkout under a directory with a space in its
# name comes back as two absolute paths joined by a space - and every path
# composed from it afterwards is nonsense, silently. Refusing here turns that
# into a named error at line 1 instead of a "no such file" forty lines into a
# Tcl script.
#
# (BUILD_DIR is handled differently, further down: spaces there are supported
# deliberately, and its relative-path test is a pure string operation for
# exactly this reason.)
ifneq ($(words $(FPGA_FLOW_DIR)),1)
$(error FPGA_FLOW_DIR '$(FPGA_FLOW_DIR)' contains whitespace. This value is \
resolved with $$(abspath), which splits its argument on spaces and would \
return two paths joined by one - every path composed from it afterwards would \
be nonsense with no error. Move the checkout, or symlink it from a path with \
no spaces)
endif
ifneq ($(words $(FPGA_DIR)),1)
$(error FPGA_DIR '$(FPGA_DIR)' contains whitespace, and it is resolved with \
$$(abspath), which splits on spaces. Move the project directory, or symlink it \
from a path with no spaces)
endif

override FPGA_DIR      := $(abspath $(FPGA_DIR))
override FPGA_FLOW_DIR := $(abspath $(FPGA_FLOW_DIR))

# -- THE EXAMPLE IS NOT A PROJECT, AND IT SITS AT THE DEFAULT PATHS ----------
# CONTRACT.md section 2 requires this refusal, and the reason is worth stating
# in full because it is this toolkit's own argument turned on itself.
#
# Everything in section 3.3 defaults relative to $(FPGA_DIR): board/$(BOARD),
# targets/$(TARGET), hooks/, overrides/, build/. An example project carries
# exactly those directories, at exactly those paths. So an FPGA_DIR pointed
# inside examples/ resolves every single default, successfully, and builds a
# bitstream.
#
# It builds the WRONG bitstream, and nothing says so. The reference toolkit
# measured this on its own example: the example's power plan was 17,227 bytes
# against the live design's 38,257, and its floorplan 15,434 against 24,504 -
# less than half the design, no error, no warning, and a full set of reports at
# the end of it. A transcribed example cannot stay current with a design that is
# still moving, and that one did not.
#
# The example stays, because it is the only filled-in reference there is. What
# it must never be is the thing the engine BUILDS.
ifneq (,$(findstring $(FPGA_FLOW_DIR)/examples/,$(FPGA_DIR)/))
$(error FPGA_DIR points inside the toolkit's own examples/ directory \
($(FPGA_DIR)). The example is reference material, not a project: it sits at \
exactly the paths every ?= in this file defaults to, so building from here \
would succeed and produce a different design without a word. Copy it somewhere \
of your own and point FPGA_DIR there, or start from \
`scripts/fpga-flow-init`, which scaffolds templates/ instead)
endif

#-----------------------------------------------------------------------------
# 2. THE RUN NAMESPACE, AND THE GUARDS ON THE PATHS THAT GET DELETED
#
# ONE FLOW, MANY RUNS. Everything a run writes lives under
#
#     $(BUILD_DIR)/$(RUN_TAG)/{work,logs,reports,outputs}
#
# so two runs are separated by DIRECTORY and nothing is ever renamed to make
# room for a second one.
#
#     make all                        -> build/default/
#     make all RUN_TAG=fast_clk       -> build/fast_clk/
#
# RESUMING FROM ANOTHER RUN. A stage reads its input from IN_RUN_TAG's work
# directory and writes its output to its own (CONTRACT.md section 5). So an
# implementation experiment that reuses an expensive synthesis is:
#
#     make impl RUN_TAG=experiment SYNTH_RUN_TAG=main
#
# The input directory is READ-ONLY for that run by construction: every path this
# file composes is built from WORK_DIR, and the three run tags are refused if
# they contain a path separator, so no stage, hook or project override can
# address anything outside the build tree.
#-----------------------------------------------------------------------------

BUILD_DIR      ?= $(FPGA_DIR)/build
RUN_TAG        ?= default
IN_RUN_TAG     ?= $(RUN_TAG)
SYNTH_RUN_TAG  ?= $(RUN_TAG)

# -- RUN_TAG IS LOAD-BEARING FOR A DESTRUCTIVE TARGET ------------------------
# `?=` sets a default when RUN_TAG is UNDEFINED. It does not protect against an
# explicitly empty one, and `make distclean RUN_TAG=` is a plausible typo:
# RUN_DIR collapses to $(BUILD_DIR)/ and `rm -rf $(RUN_DIR)` takes every run in
# the project, finished bitstreams included.
#
# The Tcl layer refuses a tag with a separator too, and that duplication is
# deliberate: the make layer is the one holding the rm, and a guard that lives
# only in the layer above the one that can do the damage is a guard that stops
# existing the moment somebody runs the target directly.
ifeq ($(strip $(RUN_TAG)),)
$(error RUN_TAG is empty. It names this run's directory under $(BUILD_DIR), so \
an empty value makes RUN_DIR the whole build tree - and `make distclean` would \
delete every run you have, finished bitstreams included. Set it to something, \
or leave it unset for 'default')
endif

# $(findstring /,...) rather than a $(words $(subst /, ,...)) component count.
# The word-count form has empty fields collapse, so it accepts '/absolute' and
# 'trailing/' and reports them as a single component - which is how a guard
# comes to pass a value that is precisely what it was written to refuse.
ifneq ($(findstring /,$(RUN_TAG)),)
$(error RUN_TAG '$(RUN_TAG)' contains a path separator. It is a directory NAME \
under $(BUILD_DIR), not a path - a tag with a '/' escapes the run tree, lets a \
stage address another run's work directory, and puts `make distclean` on a \
path nobody chose)
endif

# '.' and '..' contain no separator and pass every test above, and they are the
# ones that actually escape: RUN_TAG=.. makes RUN_DIR $(BUILD_DIR)/.., so
# `make clean` composes `rm -rf $(BUILD_DIR)/../work` - a sibling of the build
# tree, which is exactly what these guards exist to prevent. GNU rm declining to
# remove a path ending in '..' on distclean is luck, not a design, and it does
# not save the `clean` case at all.
ifneq ($(filter . ..,$(RUN_TAG)),)
$(error RUN_TAG '$(RUN_TAG)' is a relative-path element. It names a directory \
under $(BUILD_DIR); '.' and '..' escape it and make `clean` delete siblings of \
the build tree)
endif

# -- THE TWO READ-SIDE TAGS GET THE SAME THREE GUARDS ------------------------
# IN_RUN_TAG and SYNTH_RUN_TAG are not on CONTRACT.md section 3.5's guard list,
# because nothing deletes what they name. They still need guarding, and section
# 5 is what requires it: "A stage must not be able to address another run's work
# directory - enforce it by construction ... and refuse a run tag containing a
# path separator". Their whole PURPOSE is to address another run - so the
# constraint is not "no other run", it is "a directory NAME inside this build
# tree, and nothing else". IN_RUN_TAG=../../../elsewhere is a read of any path
# on the host, laundered through a variable documented as a run tag, and it ends
# up recorded in the manifest as provenance for a build that never read it.
#
# Written as a loop rather than as six copied blocks: three identical guards
# spelled out three times is three places to fix a defect, and this toolkit's
# founding complaint is a list maintained in more than one place. RUN_TAG keeps
# its own hand-written messages above because its disasters are different - it
# is the one the rm is composed from.
define fpga_run_tag_component_guard
ifeq ($$(strip $$($(1))),)
$$(error $(1) is empty. It names a directory under $$(BUILD_DIR) whose \
artefacts this run READS, so an empty value points the read at $$(BUILD_DIR) \
itself. Leave it unset to default to RUN_TAG='$$(RUN_TAG)')
endif
ifneq ($$(findstring /,$$($(1))),)
$$(error $(1) '$$($(1))' contains a path separator. It is a directory NAME \
under $$(BUILD_DIR), not a path: with a '/' in it this run would read a \
database from outside the build tree and then record it in the manifest as the \
provenance of a build that never saw it)
endif
ifneq ($$(filter . ..,$$($(1))),)
$$(error $(1) '$$($(1))' is a relative-path element. It names a directory \
under $$(BUILD_DIR); '.' and '..' resolve outside the run tree)
endif
endef
$(eval $(call fpga_run_tag_component_guard,IN_RUN_TAG))
$(eval $(call fpga_run_tag_component_guard,SYNTH_RUN_TAG))

# -- AND SO IS BUILD_DIR -----------------------------------------------------
# Every guard above protects the LAST COMPONENT of the path and none of them
# protects the path. BUILD_DIR is the more dangerous of the two: it is the
# variable the documentation tells you to set, to put runs on a scratch
# filesystem, and it prefixes the same `rm -rf`.
#
#     make distclean BUILD_DIR=      ->  rm -rf "/default"
#
# EMPTY. The same typo as RUN_TAG=, one level up, and `?=` does not catch it for
# the same reason.
ifeq ($(strip $(BUILD_DIR)),)
$(error BUILD_DIR is empty. It is the parent of every run directory, so an \
empty value makes RUN_DIR an absolute path at the filesystem root and \
`make distclean` would compose `rm -rf /$(RUN_TAG)`. Leave it unset for \
$$(FPGA_DIR)/build, or give it a real path)
endif

# RELATIVE. Not a delete hazard - a two-working-directories hazard. Every tool
# invocation below is `cd "$(WORK_DIR)" && vivado ... -log $(LOG_DIR)/...`, so a
# relative build path is resolved once against $(FPGA_DIR) by the artefact
# assertions in this file and again against the work directory by the tool. The
# run appears to succeed and writes its logs somewhere nobody looks; the
# reference toolkit's consuming project lost an hour and 38 minutes to exactly
# this shape of defect.
#
# REJECTED, not silently rewritten. The obvious fix is
# `override BUILD_DIR := $(abspath $(BUILD_DIR))` and it is wrong here, for the
# reason given at the top of this file: $(abspath) splits on spaces. A build
# directory with a space in it is supported deliberately - see the quoted rm in
# `clean` and `distclean` - so the test below is $(subst), a pure string
# operation that does not split anything. Prefixing a slash and collapsing the
# doubled one is a no-op only when the value already begins with a slash.
ifneq ($(BUILD_DIR),$(subst //,/,/$(BUILD_DIR)))
$(error BUILD_DIR '$(BUILD_DIR)' is a relative path. Every tool invocation runs \
with the working directory set to this run's work/ directory, so a relative \
build path resolves to one place for make and another for Vivado - the run \
writes its logs somewhere nobody looks and appears to have succeeded. Give an \
absolute path)
endif

# The filesystem root. Refuses the empty-string case a second time, after
# expansion, and any path that collapses to it.
ifeq ($(BUILD_DIR),/)
$(error BUILD_DIR resolves to '/'. `make distclean` would compose \
`rm -rf /$(RUN_TAG)`, and `make clean` `rm -rf /$(RUN_TAG)/work`)
endif

#-----------------------------------------------------------------------------
# 3. THE PROJECT CONTRACT - CONVENTION FIRST, EXPLICIT OVERRIDE SECOND
#
# CONTRACT.md section 3.3, in its groups and its order. Every path is `?=`, so a
# project with an existing layout points at its own files instead of moving
# them, and `fpga-flow-init` scaffolds exactly the defaults.
#
# A CONFIGURED-BUT-MISSING OPTIONAL INPUT IS AN ERROR, NOT A SHRUG. Nothing here
# enforces that - `make check` does, because it is the thing that can read the
# filesystem and report all of it at once. What this block owns is the RESOLVED
# VALUE: make is the only thing that can compute it, given `?=` chains, aliases
# and per-invocation overrides, so make computes it and hands it on.
#-----------------------------------------------------------------------------

# -- Identity ----------------------------------------------------------------
# DESIGN_NAME is the BLOCK DESIGN's name, which is not always the design's:
# write_bd_tcl names the .bd after it, and a project that renames its top module
# without renaming the BD gets a stage that writes $(WORK_DIR)/<old>.bd while
# the assertion looks for <new>.bd. Defaulting it to BLOCK makes the common case
# right and the divergent case explicit.
DESIGN_NAME     ?= $(BLOCK)
# Provenance only - the git describe/sha/dirty triple in every manifest. It is
# NOT a source root and nothing is read from it.
PROJECT_ROOT    ?= $(abspath $(FPGA_DIR)/..)

# -- Target ------------------------------------------------------------------
# The board pack is a fact about a CIRCUIT BOARD and ships in the project; the
# part pack is a fact about a DEVICE and ships in this toolkit (CONTRACT.md
# section 1). That is the whole reason BOARD_DIR points into $(FPGA_DIR) and
# PART_DIR into $(FPGA_FLOW_DIR), and it is why nothing in this repository may
# name a board.
BOARD_DIR       ?= $(FPGA_DIR)/board/$(BOARD)
TARGET          ?= $(BOARD)
TARGET_DIR      ?= $(FPGA_DIR)/targets/$(TARGET)

# PART normally arrives from the board pack, which is Tcl and which make cannot
# read. So at this layer PART is frequently EMPTY, and that is not an error.
#
# DEVIATION from CONTRACT.md section 3.3, which writes
# `PART_DIR ?= $(FPGA_FLOW_DIR)/part/$(PART)` unconditionally. Expanded with an
# empty PART that is `$(FPGA_FLOW_DIR)/part/` - a directory that EXISTS, holds
# every part pack in the toolkit, and is not a part pack. Every downstream
# existence test on it passes, and the first thing that notices is whatever
# tries to source part.tcl inside it. An unset optional key must error rather
# than resolve to something plausible (section 8), so PART_DIR stays EMPTY until
# PART is known and `make check` says which pack is expected to supply it.
PART_DIR        ?= $(if $(strip $(PART)),$(FPGA_FLOW_DIR)/part/$(strip $(PART)),)

# The vendor's board-part identifier, when the board pack declares one. Set it
# and BOARD_REPO_PATHS must be set too - a board part that is not in a repo path
# Vivado has been given is a create_project that fails naming a string, with no
# hint that the repository list is what is missing.
BOARD_PART      ?=
BOARD_REPO_PATHS?=

# -- FLOW_MODE: ONE NAME, BECAUSE ONE PATH IS IMPLEMENTED --------------------
# CONTRACT.md section 3.3 used to declare four modes - `project | direct | dfx |
# protocompiler` - and this line used to default to `project`. Here is what each
# of the four was measured to do, on 2026-09-11, by reading every consumer of
# the variable in this repository:
#
#   direct         the in-memory checkpoint flow. It is the one that runs, and
#                  it is the one every stage has always run.
#   project        CHANGED NOTHING. flow/vivado/4_synth.tcl said so in its own
#                  header: it does not implement `launch_runs synth_1`. The
#                  value reached exactly two things - the `flow_mode` line in
#                  the manifest, and a NOT-COVERED bullet in the gate saying
#                  the declaration had been ignored.
#   protocompiler  CHANGED NOTHING, and unlike `project` no stage so much as
#                  named it. Accepted by `make check`, consumed by nothing.
#   dfx            changed ONE line: flow/steps/synth_setup.tcl derived
#                  `-mode out_of_context` from it. Nothing anywhere in this
#                  repository mentions a partition, a pblock, HD.RECONFIGURABLE
#                  or a partial bitstream, so what that name selected was the
#                  single most dangerous half of DFX with none of the machinery
#                  that makes it safe: out-of-context synthesis of a BOARD-LEVEL
#                  top inserts NO IO BUFFER on any port, implementation places
#                  the result happily, and the bitstream configures a device
#                  whose pins are connected to nothing. synth_setup.tcl's own
#                  section 7 says exactly that, and README.md says DFX is out of
#                  phase 1.
#
# So the default was a SILENT SUBSTITUTION inside a toolkit written to stop
# them. Every run this repository has ever produced declared one flow and
# executed another, and the only place that was visible was a not-covered note
# in a gate file. The default is now the thing that runs, and the three names
# that named nothing are REFUSED BY NAME rather than quietly mapped onto
# `direct`: a refusal is something a reader can act on in the second it costs,
# and a substitution is something they find out about from a bitstream.
#
# REFUSING `dfx` COSTS NOTHING, which is why it is refused rather than kept as
# the one mode with a measurable effect. The out-of-context synthesis it
# selected is still reachable, by the knob that actually owns it:
# `make synth SYNTH_MODE=out_of_context` asks for precisely the same
# synth_design command, is recorded in the manifest as the explicit choice it
# is, and does not also promise a stage graph this toolkit does not have.
FLOW_MODE       ?= direct

# THE REFUSAL IS AT PARSE TIME, not in `make check`. `check` is a prerequisite
# of the stage targets and of nothing else, so a FLOW_MODE nobody implements
# would still reach `make env`, `make status`, `make vivado-shell` and any stage
# script run by hand out of `make env` - and this file exports the value into
# every one of those environments a few hundred lines below. A guard that fires
# after the value has been handed to a tool is a report, not a guard.
#
# The Tcl layer refuses the same values again in flow_boot, for the reason the
# RUN_TAG guards are duplicated there too (section 2): a guard that lives only
# in the layer above the one that can do the damage stops existing the moment
# somebody runs the stage directly.
ifneq ($(strip $(FLOW_MODE)),direct)
$(error FLOW_MODE is '$(FLOW_MODE)' and the only mode this toolkit implements is 'direct' - the in-memory checkpoint flow that every stage has always run. 'project' named the `launch_runs synth_1` path, which flow/vivado/4_synth.tcl states in its own header that it does not implement; 'protocompiler' is named by no stage at all; 'dfx' selected out-of-context synthesis and NONE of the partition, pblock or partial-bitstream handling that would make it a flow, which on a board-level top is a bitstream with no IO buffer on any pin. If out-of-context synthesis is what you want, ask for it by the knob that owns it: make synth SYNTH_MODE=out_of_context. Otherwise set FLOW_MODE=direct, or leave it unset)
endif
# The value set for PLATFORM is declared by the board pack's `platform` key and
# validated against the pack schema (CONTRACT.md section 8). It is deliberately
# NOT enumerated here: a legal-values list maintained in two places is the
# founding defect this toolkit exists to stop having - the reference toolkit
# hardcodes a five-entry step whitelist against a seven-file directory, so two
# real extension points are undocumented and warn spuriously.
PLATFORM        ?= bare

# SPECIAL - CONTRACT.md section 3.4. This value is compiled into the FIRMWARE
# and constrains the BITSTREAM. A build whose firmware and fabric disagree about
# it boots, and gets every baud rate and every timer wrong - which presents as a
# flaky UART, not as a clock error. `make check` reports it together with the
# firmware settings for that reason, and both land in every manifest.
SYS_CLK_FREQ_HZ ?=

# -- RTL ---------------------------------------------------------------------
TOP             ?=
RTL_FLIST       ?=
# A make target IN THE PROJECT that regenerates the flist. Run before `flist`,
# by the project's own prerequisite append (section 6.3) - this file does not
# invoke it, because a toolkit that runs a project target it did not define
# cannot say what that target did.
RTL_FLIST_GEN      ?=
RTL_INCDIRS        ?=
RTL_DEFINES        ?=
# BAKED INTO MATERIALISED COPIES, not passed as a fileset define, and the
# distinction is measured: ipx::package_project DROPS fileset defines by three
# separate routes (CONTRACT.md section 9.2). It failed silently here once
# already - an `ifdef`-guarded opt-in was false in EVERY FPGA build, proven by a
# byte-identical bitstream with the feature nominally on. Anything that must
# survive IP packaging goes in RTL_PARAMS or in here, never in RTL_DEFINES.
RTL_DEFINES_INBODY ?=
# Asserted ABSENT. A define that belongs to a different implementation target
# leaking into an FPGA build is not caught by anything else: there is no
# `ifdef FPGA` and no `ifdef ASIC` anywhere in this codebase (section 9.1, zero
# hits across 13,524 files), so selection is by flist file-swap and by module
# parameter, and a stray define changes the design without changing the flist.
RTL_DEFINES_NEVER  ?=
# NAME=VALUE. Parameters survive IP packaging as CONFIG.* properties; defines do
# not. This is the PRIMARY configuration mechanism for anything that crosses an
# IP boundary, for that reason and no other.
RTL_PARAMS         ?=
# Read AFTER the flist, so the board-level top can instantiate what the flist
# defined. TOP names the module; TOP_HDL names the file it lives in.
TOP_HDL            ?=
EXTRA_SRCS         ?=
# Files to force to file_type SystemVerilog. Vivado infers the type from the
# extension, so a .v holding SystemVerilog elaborates with syntax errors that
# read as design errors.
SV_FILES           ?=

# -- IP / BD -----------------------------------------------------------------
# A LIST. More than one repository is the normal case, not the exception.
IP_REPOS        ?=
IP_VENDOR       ?= soclabs.org
IP_CORE_REV     ?= 1
IP_CACHE_DIR    ?= $(BUILD_DIR)/ip_cache
PACKAGE_TCL     ?=
BD_TCL          ?=
# A LIST, applied in order over BD_TCL. Order is significant and preserved.
BD_OVERLAY_TCL  ?=
BD_GLOBAL_SYNTH ?= 0

# -- Constraints -------------------------------------------------------------
# EXPLICIT PATHS, and that is a DEVIATION from the flow this replaces, which
# discovered its XDC by a filename glob. Any file the glob did not match was
# silently invisible, and the failure was warn-only: Vivado drops a constraint
# that matches nothing without an error (CONTRACT.md section 9.3), so a
# constraint file that was never read and a constraint file that matched nothing
# produce the same silence and the same green run.
#
# `make check` therefore errors on a .xdc sitting in TARGET_DIR that no variable
# names. An unnamed constraint file is either dead collateral or a constraint
# this build is missing, and neither is something to discover after the board
# does not come up.
XDC_PINS        ?=
# Clock DEFINITIONS, read at SYNTHESIS ONLY. Not an exception, so it does not
# belong in XDC_TIMING's read window - and synthesis needs it, because
# gated-clock conversion is inert on a net Vivado has not been told is a clock.
# Implementation takes the same definitions from XDC_TIMING, so this is read
# once per stage from one file per stage and no clock is defined twice.
XDC_CLOCKS      ?=
XDC_TIMING      ?=
XDC_DRC         ?=
XDC_EXTRA       ?=
# A LIST of "COND:path" - included if and only if $(COND) is 1. The condition is
# a variable NAME, resolved by the Tcl layer at read time, so the manifest can
# record which conditional constraints were live in this run.
XDC_OPTIONAL    ?=
# `source`d after route_design, NOT read_xdc'd. Vivado REJECTS procedural Tcl in
# an XDC (section 9.4), and a DRC waiver needs procedural Tcl. Feeding this file
# to read_xdc produces an error inside constraint parsing that names the line
# rather than the mechanism, and the usual next move is to delete the waiver.
XDC_POST_ROUTE  ?=

# -- Firmware - a bitstream co-dependency, not a separate build --------------
# The memory initialisation is IN the bitstream. Rebuilding firmware without
# rebuilding the bitstream changes nothing on the board, and rebuilding the
# bitstream without rebuilding firmware silently ships the previous image.
FW_APP          ?=
FW_HEX          ?=
# byte | word. The wrong one loads a working-looking image whose every word is
# transposed.
FW_HEX_FORMAT   ?= word
# What $readmemh in the RTL resolves to. It is a path baked into the elaborated
# design, so it is recorded in the manifest with its own hash: two runs of the
# same flist with different hex are two different bitstreams.
FPGA_IMAGE_HEX  ?=

# -- Extension points --------------------------------------------------------
HOOKS_DIR       ?= $(FPGA_DIR)/hooks
OVERRIDES_DIR   ?= $(FPGA_DIR)/overrides

# -- Tools -------------------------------------------------------------------
VIVADO          ?= vivado
# When set it is ASSERTED, not assumed. `make doctor` reports what is ON THE
# FILESYSTEM and never what a modulefile claims: measured on the reference host,
# the modulefiles advertise three versions and two of them are not installed
# (CONTRACT.md section 9.6). A flow that trusts the module system reports the
# version it was told about, in a manifest, as provenance.
VIVADO_VER      ?=
NUM_JOBS        ?= 8
TCLSH           ?= tclsh

# -- Gates -------------------------------------------------------------------
# Every EXPECT_* defaults to -1, meaning MEASURE AND REPORT, DO NOT GATE. A
# project sets the ratchet after a first run, with the measurement and the
# margin written down beside it. A default budget is somebody else's number
# applied to your design, and it is either vacuous or wrong.
# EMPTY, not -1, and only for these two. A slack is in nanoseconds and a real
# budget can legitimately be -1 ns, so the -1 sentinel would make that exact
# budget inexpressible AND silently unarmed. Count budgets below cannot be
# negative, so -1 is safe there. CONTRACT.md 3.3.
EXPECT_WNS_MIN        ?=
EXPECT_WHS_MIN        ?=
EXPECT_LUT_MAX        ?= -1
EXPECT_FF_MAX         ?= -1
EXPECT_BRAM_MAX       ?= -1
EXPECT_DSP_MAX        ?= -1
# These two are NOT -1. An unrouted net and a black box are not budgets to be
# tuned - they are a design that did not finish and a module the tool could not
# find, and both are 0 or the run is broken.
EXPECT_UNROUTED_MAX   ?= 0
EXPECT_BLACKBOX_MAX   ?= 0
ALLOW_CRITICAL_WARNINGS ?= 0
XDC_BASELINE          ?=
# EMPTY, and it stays empty. A default that tolerates message IDs hands each new
# project somebody else's undiagnosed exemptions, and an exemption inherited
# without its diagnosis is indistinguishable from a bug nobody has hit yet.
# Every entry a project adds carries a paragraph of diagnosis and an owner.
MSG_GATE_ALLOWLIST    ?=

# -- Deploy - declaration only; phase 4 wires it -----------------------------
# THE BOARD GROUP AND THE TARGET ARE DIFFERENT NAMESPACES, and they do not
# overlap: leases, queues and reservations address the board group, while
# program, reset and actions address a target. Conflating them returns 404, and
# a 404 from a deploy step reads as "the board is not there" rather than "you
# asked the wrong namespace" (CONTRACT.md section 9.7).
FPGAHUB_BOARD   ?=
FPGAHUB_TARGET  ?=
# DISCOVERED, NOT ASSERTED - note the $(wildcard). This default names a
# CONVENTIONAL path, and `make check` treats a non-empty optional as something
# the project asked for and therefore requires to exist. A bare
# `?= $(FPGA_DIR)/fpgahub.toml` therefore made every project that has no deploy
# configured fail its contract check until it created an empty fpgahub.toml.
# With $(wildcard) the variable is empty when the file is absent - reported as
# `--`, not configured - and a project that names a path EXPLICITLY still gets
# the "you named it, so it must exist" treatment, which is the behaviour that
# was wanted. Any future default naming a conventional path must do the same.
FPGAHUB_TOML    ?= $(wildcard $(FPGA_DIR)/fpgahub.toml)
# The two accepted values are declared by the board pack schema (section 8) and
# are NOT enumerated here, for the same reason PLATFORM is not. They are not
# interchangeable: one needs a byte swap and the other a header strip, and using
# the wrong one produces a .bin that loads and does not run.
BIN_STYLE       ?=

#-----------------------------------------------------------------------------
# 4. ACCEPTED ALIASES
#
# The canonical names are the ones above and in CONTRACT.md section 3. The two
# below are accepted as well, and the list is deliberately CLOSED at two.
#
# Both are the spellings the ASIC toolkit accepts, and this repository's
# consuming projects run both flows out of one design vocabulary: a design that
# is taped out and also prototyped should not have to keep two names for one
# flist so that each toolkit can find it. That is the entire justification, and
# it is why no third alias is invented here - an alias with no such argument is
# just a second name to keep in sync, and `make check` and `make env` would then
# have two spellings to report.
#
# `make check` and `make env` always report the CANONICAL name, so a design.mk
# using an alias reads the same as one that does not. Which alias was actually
# consumed is exported (FPGA_ALIASES_USED) so the check can say so rather than
# leaving the reader to wonder why RTL_FLIST is set when design.mk never
# mentions it.
#-----------------------------------------------------------------------------

FPGA_ALIASES_USED :=

ifeq ($(strip $(RTL_FLIST)),)
ifneq ($(strip $(FLIST)),)
RTL_FLIST := $(FLIST)
FPGA_ALIASES_USED += RTL_FLIST=FLIST
endif
endif

ifeq ($(strip $(TOP_HDL)),)
ifneq ($(strip $(TOP_LEVEL_HDL)),)
TOP_HDL := $(TOP_LEVEL_HDL)
FPGA_ALIASES_USED += TOP_HDL=TOP_LEVEL_HDL
endif
endif

#-----------------------------------------------------------------------------
# 5. DERIVED - assigned after the project is read, and NOT SETTABLE
#
# CONTRACT.md section 3.5. Seven values, every one of them a pure function of
# BUILD_DIR and a run tag.
#
# WHY `override`, WHEN THE CONTRACT ONLY ASKS FOR A WARNING. Section 3.5 says a
# project that assigns one of these has its value "silently discarded" and that
# `make check` warns. The first half of that is true for a design.mk assignment
# and FALSE FOR A COMMAND-LINE ONE: GNU make gives command-line variables
# precedence over every file assignment unless the file says `override`. So
#
#     make clean WORK_DIR=$HOME/scratch
#
# does not get discarded and does not get warned about by anything that runs
# before the recipe. It composes `rm -rf` on a path that no guard in section 2
# ever saw, because every guard up there protects BUILD_DIR and RUN_TAG - the
# INPUTS to these seven - and WORK_DIR set directly bypasses all of them. The
# same assignment on a stage target splits the run in half: outputs/ under
# RUN_DIR, work/ somewhere else, and a manifest whose directory block records
# two trees that were never one run.
#
# `override` is the only construction that makes "NOT settable" true rather than
# aspirational. What the project attempted is captured first, in
# FPGA_DERIVED_PRESET, so `make check` can still name the variable and the value
# instead of the assignment vanishing without trace - a silent discard being the
# exact failure class this toolkit exists to end.
#
# $(origin) is read BEFORE the assignments below, because after them every one
# of these would report 'file' whatever the project did.
#-----------------------------------------------------------------------------

FPGA_DERIVED_VARS := RUN_DIR WORK_DIR LOG_DIR REPORT_DIR OUT_DIR IN_WORK_DIR SYNTH_OUT_DIR
FPGA_DERIVED_PRESET := $(strip $(foreach v,$(FPGA_DERIVED_VARS),\
    $(if $(filter-out undefined,$(origin $(v))),$(v)[$(origin $(v))])))

override RUN_DIR       := $(BUILD_DIR)/$(RUN_TAG)
override WORK_DIR      := $(RUN_DIR)/work
override LOG_DIR       := $(RUN_DIR)/logs
override REPORT_DIR    := $(RUN_DIR)/reports
override OUT_DIR       := $(RUN_DIR)/outputs

# A stage READS these and never writes them. They are composed from BUILD_DIR
# and a guarded single-component tag, so they cannot address anything outside
# the build tree - which is section 5's "enforce it by construction, not by
# convention", spelled out.
override IN_WORK_DIR   := $(BUILD_DIR)/$(IN_RUN_TAG)/work
override SYNTH_OUT_DIR := $(BUILD_DIR)/$(SYNTH_RUN_TAG)/outputs

#-----------------------------------------------------------------------------
# 6. WHAT THE TOOLS SEE - THE INTERFACE TO flow/
#
# EVERYTHING THE Tcl LAYER READS ARRIVES AS AN FPGA_* ENVIRONMENT VARIABLE, AND
# NOTHING ELSE DOES. That is the whole interface, and this block is its only
# definition. A stage script run by hand with these exported behaves identically
# to one run by make; a stage script that reads anything not in this list is
# reading something make did not resolve, and make is the only thing that CAN
# resolve it given the `?=` chains, the aliases and the per-invocation overrides
# above.
#
# It is also the interface to scripts/fpga-flow-check, deliberately - one export
# set, two consumers, no transcription. See the header of mk/checks.mk.
#
# THE SET IS ENUMERATED, NOT GENERATED. A `foreach ... export` over a name list
# would be shorter and would make the interface a thing you have to run make to
# discover. This list is meant to be READ - by whoever writes a stage script, by
# whoever writes the check, and by whoever is trying to work out where a value
# came from at two in the morning.
#
# `make env` prints the curated version of it; `make check-vars` prints all of
# it, exactly as handed over.
#-----------------------------------------------------------------------------

# -- Engine and identity --
# EXPORTED WITH `=`, NOT `:=`, THROUGHOUT THIS BLOCK.
#
# `:=` snapshots here, which is BEFORE mk/*.mk is included and before anything a
# project assigns after `include mk/flow.mk`. The exported copy and the make
# variable then disagree, and the way that shows up is the worst possible one:
# `make env` reads the MAKE variable and prints the project's value, while the
# Tcl layer reads the EXPORTED copy and gets the engine default. Measured
# 2026-09-08 - `make env` reported MSG_GATE_ALLOWLIST as {Project 1-1924} while
# the run manifest for the same invocation recorded `(none)`. A report that
# disagrees with the run it describes is worse than no report.
#
# Three exports below keep `:=` because their name IS the variable they export,
# so `=` would be an infinite self-reference. They are values the engine
# normalises in place during parsing, before any include, so a snapshot is
# correct for them specifically.

export FPGA_FLOW_DIR
export FPGA_DIR
export FPGA_PROJECT_ROOT     = $(PROJECT_ROOT)
export FPGA_BLOCK            = $(BLOCK)
export FPGA_DESIGN_NAME      = $(DESIGN_NAME)

# -- Target: board pack (project) and part pack (toolkit) --
export FPGA_BOARD            = $(BOARD)
export FPGA_BOARD_DIR        = $(BOARD_DIR)
export FPGA_TARGET           = $(TARGET)
export FPGA_TARGET_DIR       = $(TARGET_DIR)
export FPGA_PART             = $(PART)
export FPGA_PART_DIR         = $(PART_DIR)
export FPGA_BOARD_PART       = $(BOARD_PART)
export FPGA_BOARD_REPO_PATHS = $(BOARD_REPO_PATHS)
export FPGA_FLOW_MODE        = $(FLOW_MODE)
export FPGA_PLATFORM         = $(PLATFORM)
export FPGA_SYS_CLK_FREQ_HZ  = $(SYS_CLK_FREQ_HZ)

# -- Run namespace --
export FPGA_BUILD_DIR        = $(BUILD_DIR)
export FPGA_RUN_TAG          = $(RUN_TAG)
export FPGA_RUN_DIR          = $(RUN_DIR)
export FPGA_WORK_DIR         = $(WORK_DIR)
export FPGA_LOG_DIR          = $(LOG_DIR)
export FPGA_REPORT_DIR       = $(REPORT_DIR)
export FPGA_OUT_DIR          = $(OUT_DIR)
export FPGA_IN_RUN_TAG       = $(IN_RUN_TAG)
export FPGA_IN_WORK_DIR      = $(IN_WORK_DIR)
export FPGA_SYNTH_RUN_TAG    = $(SYNTH_RUN_TAG)
export FPGA_SYNTH_OUT_DIR    = $(SYNTH_OUT_DIR)

# -- RTL --
export FPGA_TOP              = $(TOP)
export FPGA_RTL_FLIST        = $(RTL_FLIST)
export FPGA_RTL_FLIST_GEN    = $(RTL_FLIST_GEN)
export FPGA_RTL_INCDIRS      = $(RTL_INCDIRS)
export FPGA_RTL_DEFINES      = $(RTL_DEFINES)
export FPGA_RTL_DEFINES_INBODY = $(RTL_DEFINES_INBODY)
export FPGA_RTL_DEFINES_NEVER  = $(RTL_DEFINES_NEVER)
export FPGA_RTL_PARAMS       = $(RTL_PARAMS)
export FPGA_TOP_HDL          = $(TOP_HDL)
export FPGA_EXTRA_SRCS       = $(EXTRA_SRCS)
export FPGA_SV_FILES         = $(SV_FILES)

# -- IP / BD --
export FPGA_IP_REPOS         = $(IP_REPOS)
export FPGA_IP_VENDOR        = $(IP_VENDOR)
export FPGA_IP_CORE_REV      = $(IP_CORE_REV)
export FPGA_IP_CACHE_DIR     = $(IP_CACHE_DIR)
export FPGA_PACKAGE_TCL      = $(PACKAGE_TCL)
export FPGA_BD_TCL           = $(BD_TCL)
export FPGA_BD_OVERLAY_TCL   = $(BD_OVERLAY_TCL)
export FPGA_BD_GLOBAL_SYNTH  = $(BD_GLOBAL_SYNTH)

# -- Constraints --
export FPGA_XDC_PINS         = $(XDC_PINS)
export FPGA_XDC_CLOCKS       = $(XDC_CLOCKS)
export FPGA_XDC_TIMING       = $(XDC_TIMING)
export FPGA_XDC_DRC          = $(XDC_DRC)
export FPGA_XDC_EXTRA        = $(XDC_EXTRA)
export FPGA_XDC_OPTIONAL     = $(XDC_OPTIONAL)
export FPGA_XDC_POST_ROUTE   = $(XDC_POST_ROUTE)
export FPGA_XDC_BASELINE     = $(XDC_BASELINE)

# -- Firmware --
export FPGA_FW_APP           = $(FW_APP)
export FPGA_FW_HEX           = $(FW_HEX)
export FPGA_FW_HEX_FORMAT    = $(FW_HEX_FORMAT)
export FPGA_IMAGE_HEX        := $(FPGA_IMAGE_HEX)

# -- Extension seams --
# The seam LIST is a file, not a variable, and the path to it is exported so
# that the flow, the check and `make help` all read THE SAME COPY. Exporting the
# list itself would create the second copy CONTRACT.md section 6.1 forbids.
export FPGA_HOOKS_DIR        = $(HOOKS_DIR)
export FPGA_OVERRIDES_DIR    = $(OVERRIDES_DIR)
export FPGA_SEAMS_FILE       = $(FPGA_FLOW_DIR)/flow/common/seams.txt
# The valid STEP list is `ls $(FPGA_STEPS_DIR)/*.tcl`, derived at run time by
# whoever needs it. Never enumerated - section 6.2.
export FPGA_STEPS_DIR        = $(FPGA_FLOW_DIR)/flow/steps
export FPGA_FLOW_TCL_DIR     = $(FPGA_FLOW_DIR)/flow

# -- Tools --
export FPGA_VIVADO           = $(VIVADO)
export FPGA_VIVADO_VER       = $(VIVADO_VER)
export FPGA_NUM_JOBS         = $(NUM_JOBS)
export TCLSH

# -- Gates --
export FPGA_EXPECT_WNS_MIN      = $(EXPECT_WNS_MIN)
export FPGA_EXPECT_WHS_MIN      = $(EXPECT_WHS_MIN)
export FPGA_EXPECT_LUT_MAX      = $(EXPECT_LUT_MAX)
export FPGA_EXPECT_FF_MAX       = $(EXPECT_FF_MAX)
export FPGA_EXPECT_BRAM_MAX     = $(EXPECT_BRAM_MAX)
export FPGA_EXPECT_DSP_MAX      = $(EXPECT_DSP_MAX)
export FPGA_EXPECT_UNROUTED_MAX = $(EXPECT_UNROUTED_MAX)
export FPGA_EXPECT_BLACKBOX_MAX = $(EXPECT_BLACKBOX_MAX)
export FPGA_ALLOW_CRITICAL_WARNINGS = $(ALLOW_CRITICAL_WARNINGS)
export FPGA_MSG_GATE_ALLOWLIST  = $(MSG_GATE_ALLOWLIST)

# -- Deploy --
export FPGA_FPGAHUB_BOARD    = $(FPGAHUB_BOARD)
export FPGA_FPGAHUB_TARGET   = $(FPGAHUB_TARGET)
export FPGA_FPGAHUB_TOML     = $(FPGAHUB_TOML)
export FPGA_BIN_STYLE        = $(BIN_STYLE)

# -- Facts that exist ONLY IN make, and therefore only get out this way ------
#
# These four are not project inputs. They are things the make layer knows and
# no other layer can find out, and each one closes a hole where a real defect
# would otherwise be invisible to the check:
#
#   FPGA_MAKE_VERSION        `all` is built out of recipe lines rather than a
#                            scoped .NOTPARALLEL because that directive is GNU
#                            Make 4.4 and the sites here run older. A check that
#                            cannot see the version cannot say whether the
#                            workaround is still needed or is now hiding a
#                            simpler correct form.
#   FPGA_ALIASES_USED        which alias absorption above actually fired.
#   FPGA_DERIVED_PRESET      which of the seven derived values the project tried
#                            to set, and from where - now that `override`
#                            discards it rather than letting it win.
#   FPGA_POST_TARGET_VARS    every *_POST_TARGETS variable DEFINED ANYWHERE in
#                            this make run, from $(.VARIABLES). A misspelt one
#                            (ROUTE_POST_TARGETS, carried over from the ASIC
#                            toolkit; BITSTREM_POST_TARGETS) is otherwise a
#                            variable nothing reads and nothing reports, and the
#                            symptom is a deploy step that never ran and never
#                            said it did not. make is the only layer that can
#                            enumerate a variable nobody named.
export FPGA_MAKE_VERSION     = $(MAKE_VERSION)
export FPGA_ALIASES_USED     := $(strip $(FPGA_ALIASES_USED))
export FPGA_DERIVED_PRESET   := $(FPGA_DERIVED_PRESET)

#-----------------------------------------------------------------------------
# 7. POST-STAGE PROJECT TARGETS
#
# A project names make targets to run AFTER a stage has exited and its own gate
# artefact has been read:
#
#     BITSTREAM_POST_TARGETS = deploy      # in the project's fpga/design.mk
#
# WHY AFTER THE STAGE AND NOT AT THE post_<stage> HOOK. The hook fires INSIDE the
# tool, before the stage has written its manifest or reached its verdict.
# Anything hooked there would have to report "verdict unknown" for every gate the
# stage owns - honest, and useless. Correct logic at the wrong point in a stage
# is a defect class this codebase has produced twice.
#
# NON-FATAL TO THE BUILD, FATAL TO THE CLAIM (CONTRACT.md section 4). A
# 90-minute implementation must not be destroyed because a board was leased by
# somebody else or an artifact store was down. So the line does not fail the
# make - and it is LOUD, and the run is not "deployed". A build whose evidence
# did not publish is not a signed-off build; it is a build that still exists.
#
# THE SIX ARE DECLARED, NOT LEFT UNDEFINED, so that `make env` can print them
# and so that $(.VARIABLES) always shows exactly six - which is what makes a
# SEVENTH one, from a typo, visible to `make check`. The stage name maps to the
# variable by upper-casing it and turning '-' into '_': package-ip becomes
# PACKAGE_IP_POST_TARGETS.
#-----------------------------------------------------------------------------

FLIST_POST_TARGETS      ?=
PACKAGE_IP_POST_TARGETS ?=
BD_POST_TARGETS         ?=
SYNTH_POST_TARGETS      ?=
IMPL_POST_TARGETS       ?=
BITSTREAM_POST_TARGETS  ?=

# DEFERRED (`=`), NOT IMMEDIATE (`:=`), AND THAT IS THE WHOLE POINT.
#
# These six lines sit ~50 lines above the first `include`, so with `:=` they
# snapshot the values as they stand BEFORE any fragment has been read. A
# fragment that appends to a stage's post-target list - which is exactly what
# mk/deploy.mk does, and what any future optional fragment would do - then
# reaches the RECIPE, because post_stage_targets expands lazily, but never
# reaches the EXPORTED copy the Tcl layer reads. The two disagree, and the
# symptom is a post-stage target that visibly runs while the manifest records
# that the stage had none.
#
# With `=` the value is expanded when make builds the recipe's environment,
# which is after every include has been read. Found by the deploy tier,
# 2026-09-08.
export FPGA_FLIST_POST_TARGETS      = $(FLIST_POST_TARGETS)
export FPGA_PACKAGE_IP_POST_TARGETS = $(PACKAGE_IP_POST_TARGETS)
export FPGA_BD_POST_TARGETS         = $(BD_POST_TARGETS)
export FPGA_SYNTH_POST_TARGETS      = $(SYNTH_POST_TARGETS)
export FPGA_IMPL_POST_TARGETS       = $(IMPL_POST_TARGETS)
export FPGA_BITSTREAM_POST_TARGETS  = $(BITSTREAM_POST_TARGETS)

# Names only, sorted. The census exists to catch a name nothing reads, so the
# NAME is the whole payload - and a name list has no quoting problem, which a
# value list carrying paths with spaces in it would.
#
# Deferred for the same reason, and more sharply: `$(.VARIABLES)` evaluated here
# cannot contain a variable a later fragment defines, so the census that exists
# to catch a MISSPELT post-target variable was structurally unable to see one
# defined anywhere but the project's design.mk.
export FPGA_POST_TARGET_VARS = $(sort $(filter %_POST_TARGETS,$(.VARIABLES)))

# $(call post_stage_targets,<stage>,<targets>). Expanded when the RECIPE runs,
# so the definition may sit above or below its uses. An empty second argument
# expands to `:` - a shell no-op - and NOT to an empty command line, which make
# would reject with a syntax error from the shell.
# THE CONDITIONAL IS IN THE SHELL, NOT IN $(if), AND IT HAS TO BE.
#
# This was written with `$(if $(strip $(2)),<run them>,:)` and was broken for
# EVERY stage on EVERY run, empty list or not. `$(if)` splits its arguments on
# commas, and the message below contains one - "been evidenced, published or
# deployed". So make ended the then-part in the middle of an `echo`, leaving an
# unbalanced double quote, and handed the remainder to the shell as the
# else-part. Both branches emitted a fragment of a sentence and `/bin/sh: line
# 0: unexpected EOF while looking for matching '"'`, so a completely correct
# stage still exited non-zero. Found 2026-09-08 by the first stage scripts to
# run under real Vivado - until then no stage existed to reach this line.
#
# Moving the test into the shell makes commas ordinary text again. The lesson
# generalises: prose inside a `$(if)` is a latent syntax error, and the only
# safe place for a sentence is inside the recipe.
define post_stage_targets
_pt='$(strip $(2))'; \
if [ -n "$$_pt" ]; then \
  $(MAKE) --no-print-directory $$_pt \
    || { echo ""; \
         echo "WARNING: post-$(1) target(s) '$$_pt' FAILED."; \
         echo "         The build is intact. The CLAIM is not: nothing here has"; \
         echo "         been evidenced, published or deployed. Do not quote this"; \
         echo "         run as complete until the post-stage targets have been"; \
         echo "         re-run - re-running them is safe and does not rebuild."; \
         echo ""; }; \
fi
endef

#-----------------------------------------------------------------------------
# 8. THE SIBLING FRAGMENTS, AND THE ORDER THEY ARE READ IN
#
# THE ORDER IS: everything above, then these three. It is load-bearing for one
# reason - `?=` is first-writer-wins, so a fragment read BEFORE the block above
# would win over it and every default in section 3 would be quietly ignored,
# with no warning of any kind. ASSIGN FIRST, INCLUDE LAST.
#
#   mk/checks.mk   check, check-quiet, doctor, part-probe, board-probe. FIRST,
#                  because check-quiet is a prerequisite of every stage target
#                  below and a reader following the graph should meet it before
#                  it is used. (make itself does not care: a prerequisite may be
#                  defined after the rule that names it.)
#   mk/help.mk     help, help-all, help-knobs. help-all is GENERATED from the
#                  `##` comment blocks in this file and in mk/checks.mk, so
#                  every target here carries one and it is the first line of the
#                  block that becomes the summary.
#   mk/hooks.mk    the repository-hook machinery. LAST, because it is the only
#                  one of the three that touches something outside the run
#                  directory and nothing else depends on it.
#
# ALL THREE ARE HARD INCLUDES, WITH A NAMED ERROR IN FRONT OF EACH. `-include`
# would be tempting - it degrades gracefully when a fragment is missing - and it
# is exactly wrong: a missing mk/help.mk under `-include` produces "No rule to
# make target 'help'", which says the target does not exist rather than that the
# TOOLKIT CHECKOUT IS INCOMPLETE, and sends the reader looking for the wrong
# thing. A gate, a target or a check that silently is not there is the failure
# this repository was written to stop having, so a broken checkout says so.
#-----------------------------------------------------------------------------

ifeq ($(wildcard $(FPGA_FLOW_DIR)/mk/checks.mk),)
$(error the toolkit checkout at $(FPGA_FLOW_DIR) has no mk/checks.mk. That file \
defines check, check-quiet, doctor, part-probe and board-probe; check-quiet is a \
prerequisite of every stage, so without it no stage can run. This is an \
incomplete or damaged checkout, not a project problem)
endif
include $(FPGA_FLOW_DIR)/mk/checks.mk

ifeq ($(wildcard $(FPGA_FLOW_DIR)/mk/help.mk),)
$(error the toolkit checkout at $(FPGA_FLOW_DIR) has no mk/help.mk. That file \
defines help, help-all and help-knobs, and `help` is .DEFAULT_GOAL - so a bare \
`make` would have nothing to run. This is an incomplete or damaged checkout, \
not a project problem)
endif
include $(FPGA_FLOW_DIR)/mk/help.mk

ifeq ($(wildcard $(FPGA_FLOW_DIR)/mk/hooks.mk),)
$(error the toolkit checkout at $(FPGA_FLOW_DIR) has no mk/hooks.mk. This is an \
incomplete or damaged checkout, not a project problem)
endif
include $(FPGA_FLOW_DIR)/mk/hooks.mk

# THE SEAM LIST IS ONE FILE AND THIS IS THE ONLY PATH TO IT. If it is missing,
# every project hook silently never runs: the flow finds no seam names, matches
# no files in hooks/, and reports nothing - a build shaped by none of the project
# code that was supposed to shape it, with a green manifest. Refused here rather
# than discovered later.
ifeq ($(wildcard $(FPGA_SEAMS_FILE)),)
$(error the toolkit checkout at $(FPGA_FLOW_DIR) has no \
flow/common/seams.txt. It is THE list of flow-hook seams and there is no second \
copy anywhere by design - without it every hook in $(HOOKS_DIR) silently never \
runs and the build is shaped by none of the project code that was meant to \
shape it)
endif

#-----------------------------------------------------------------------------
# 9. THE STAGE GRAPH
#
#     dirs -> flist -> package-ip -> bd -> synth -> impl -> bitstream
#
# Each stage runs ONE Tcl script through Vivado, in this run's work directory,
# and is then judged on the artefacts it left behind (CONTRACT.md section 4).
#
# THE INVOCATION, AND WHY EACH PART OF IT IS THERE:
#
#   cd "$(WORK_DIR)"   Vivado writes .Xil/, .jou backups, .str and project
#                      scratch into its working directory whether you ask it to
#                      or not. Run from the project root and those land in the
#                      repository.
#   -mode batch        THE DEFAULT IS THE GUI. `vivado -source x.tcl` with no
#                      -mode opens a window, or fails to and reports a display
#                      error, on a machine that was meant to run unattended.
#   -log / -journal    into $(LOG_DIR), because the default is the working
#                      directory and a per-run log that lands outside the run is
#                      not provenance.
#   no -notrace        deliberately. -notrace suppresses the echo of each
#                      sourced command, and that echo is frequently the only
#                      record of WHICH LINE the stage died on: Vivado's error
#                      text often names a Tcl proc and not the caller.
#   < /dev/null        a tool that hits an unexpected prompt with an inherited
#                      stdin sits at it, holding a licence seat, and make waits
#                      forever. Measured on this site's other toolchains
#                      repeatedly; costs nothing to prevent.
#
# THE ASSERTIONS AFTER IT ARE THE ACTUAL GATE. Vivado returns 0 for a route that
# did not converge, for timing it did not meet, and for a constraint file that
# matched nothing - so the exit status is checked (a non-zero one is still a
# fact) and then ignored as evidence of success. Each assertion names the
# artefact, says what it is FOR, and prints the exact command to run next.
#-----------------------------------------------------------------------------

FLOW_VIVADO_DIR := $(FPGA_FLOW_DIR)/flow/vivado

# $(call vivado_stage,<stage-name>,<script>). One definition, seven callers -
# so a change to the invocation cannot reach six stages and miss the seventh.
#
# THE THREE PER-STAGE EXPORTS. flow_utils.tcl's header declares FPGA_STAGE_T0,
# FPGA_LOG_FILE and FPGA_TOOL_HINT as environment it reads, and for a while this
# macro exported none of them - so provenance.tcl could only time from its own
# boot (excluding tool startup) and had to GUESS the log path it was supposed to
# record. CONTRACT.md's rule for that case is explicit: when the code and the
# contract disagree, one of them is a bug and you say which. This was the bug.
#
# They are set here rather than in the export block above because they are the
# only three values that differ PER STAGE, and this macro is the one place that
# knows which stage is starting. `date +%s` is evaluated by the shell when the
# recipe runs, not by make at parse time, so it is the real launch instant.
define vivado_stage
cd "$(WORK_DIR)" && \
FPGA_STAGE=$(1) \
FPGA_STAGE_T0=$$(date +%s) \
FPGA_LOG_FILE="$(LOG_DIR)/$(1).log" \
FPGA_TOOL_HINT="$(VIVADO)" \
$(VIVADO) -mode batch \
    -log "$(LOG_DIR)/$(1).log" -journal "$(LOG_DIR)/$(1).jou" \
    -source "$(2)" < /dev/null
endef

# $(call missing_stage_script,<stage>,<script>) - the phase-1 message. The Tcl
# layer is written by a different agent against the same CONTRACT.md, so during
# phase 1 these scripts do not exist yet. A stage invoked before its script is
# written must say THAT, and not "vivado: command not found", which sends the
# reader to the module system for a problem that has nothing to do with it.
define missing_stage_script
@test -r "$(2)" || { \
    echo "FAIL: stage '$(1)' has no script at"; \
    echo "        $(2)"; \
    echo "      That path is composed from FPGA_FLOW_DIR, so either this"; \
    echo "      toolkit checkout is incomplete or FPGA_FLOW_DIR points at the"; \
    echo "      wrong tree:"; \
    echo "        FPGA_FLOW_DIR = $(FPGA_FLOW_DIR)"; \
    echo "        ls $(FLOW_VIVADO_DIR)"; \
    echo "      No tool was launched and no licence was taken."; \
    exit 1; }
endef

.PHONY: dirs flist package-ip bd synth impl bitstream all \
        env status clean distclean vivado-shell gui

## Create this run's four directories - work, logs, reports, outputs - and
## nothing else. Everything else that appears under $(RUN_DIR) belongs to a
## stage or to the project, which is what makes an unexpected directory there
## worth looking at.
dirs: check-quiet
	@mkdir -p "$(WORK_DIR)" "$(LOG_DIR)" "$(REPORT_DIR)" "$(OUT_DIR)"
	@# mkdir -p exits 0 when it created nothing, including when the path
	@# exists as a FILE it could not replace and when a read-only mount
	@# swallowed the request. Asserting on the directories is the same rule
	@# the stages follow, applied to the cheapest stage there is.
	@for d in "$(WORK_DIR)" "$(LOG_DIR)" "$(REPORT_DIR)" "$(OUT_DIR)"; do \
	    test -d "$$d" || { \
	        echo "FAIL: could not create $$d"; \
	        echo "      mkdir -p exits 0 when the path already exists as a file"; \
	        echo "      and when the filesystem is read-only, so this is checked"; \
	        echo "      rather than assumed. Look at:"; \
	        echo "        ls -ld $(RUN_DIR) $$d"; \
	        echo "        df -h $(BUILD_DIR)"; \
	        exit 1; }; \
	done

#-----------------------------------------------------------------------------
# STAGE 1 - flist
#-----------------------------------------------------------------------------

## Read the master flist and materialise it as Tcl the rest of the flow sources.
## Writes $(WORK_DIR)/sources.tcl and a manifest of every file, with hashes.
##
## SELECTION IN THIS CODEBASE IS BY FILE-SWAP, NOT BY DEFINE. There is no
## `ifdef FPGA` and no `ifdef ASIC` anywhere in it - zero hits across 13,524 RTL
## files - so which wrapper family the flist names IS the configuration, and the
## manifest this stage writes is the only record of which one was picked.
flist: dirs check-quiet
	$(call missing_stage_script,flist,$(FLOW_VIVADO_DIR)/1_flist.tcl)
	$(call vivado_stage,flist,$(FLOW_VIVADO_DIR)/1_flist.tcl)
	@test -s "$(WORK_DIR)/sources.tcl" || { \
	    echo "FAIL: the flist stage wrote no $(WORK_DIR)/sources.tcl"; \
	    echo "      That file is what every later stage sources to get the"; \
	    echo "      design - without it synthesis reads an empty fileset and"; \
	    echo "      elaborates a black box, which Vivado reports as a warning."; \
	    echo "      Find the real error with:"; \
	    echo "        grep -nE 'ERROR|CRITICAL WARNING|no such file' $(LOG_DIR)/flist.log"; \
	    exit 1; }
	@test -s "$(REPORT_DIR)/flist_manifest.txt" || { \
	    echo "FAIL: no flist manifest at $(REPORT_DIR)/flist_manifest.txt"; \
	    echo "      The stage did not reach its final section, so sources.tcl"; \
	    echo "      above is from a partial run and nothing recorded WHICH"; \
	    echo "      files it named. Inspect the tail of the run:"; \
	    echo "        tail -40 $(LOG_DIR)/flist.log"; \
	    exit 1; }
	@echo "OK: sources  $(WORK_DIR)/sources.tcl"
	@echo "    manifest $(REPORT_DIR)/flist_manifest.txt"
	@$(call post_stage_targets,flist,$(FLIST_POST_TARGETS))

#-----------------------------------------------------------------------------
# STAGE 2 - package-ip
#
# CONDITIONAL, and the condition is read at PARSE time so `make -n` shows the
# truth. A design that packages no IP is not a broken design and this stage is
# not a gate it has to satisfy: it prints a SKIP naming the variable that would
# turn it on, writes nothing, and exits 0.
#
# THE SKIP IS PRINTED, NOT SWALLOWED, and that is the difference between this
# and a silent no-op. A tier that quietly checks nothing is how a green run comes
# to prove nothing (CONTRACT.md section 7). `make check` carries the other half:
# it holds FLOW_MODE and PACKAGE_TCL together and can say that a project
# configured to package IP has not named a script to do it with, which is a
# question this recipe cannot answer on its own.
#-----------------------------------------------------------------------------

## Package the design as IP (component.xml) for a block design to consume.
## SKIPPED, loudly, when PACKAGE_TCL is empty - a design with no IP to package
## is not a failing design.
##
## PARAMETERS SURVIVE PACKAGING; DEFINES DO NOT. ipx::package_project drops
## fileset defines by three separate routes, and it has already cost this
## codebase one silently-disabled feature that was proven off only by a
## byte-identical bitstream. Anything that must cross this boundary belongs in
## RTL_PARAMS, or in RTL_DEFINES_INBODY where it is baked into the materialised
## source before packaging ever sees it.
package-ip: dirs check-quiet
ifeq ($(strip $(PACKAGE_TCL)),)
	@echo "SKIP: package-ip - PACKAGE_TCL is empty, so this design packages no IP."
	@echo "      Nothing was written and no tool was launched. Set PACKAGE_TCL in"
	@echo "      fpga/design.mk to a packaging script to turn this stage on."
else
	$(call missing_stage_script,package-ip,$(FLOW_VIVADO_DIR)/2_package_ip.tcl)
	$(call vivado_stage,package-ip,$(FLOW_VIVADO_DIR)/2_package_ip.tcl)
	@# THE VLNV IS NOT KNOWABLE HERE. The directory under outputs/ip/ is named
	@# by the vendor:library:name:version the packaging script chose, which may
	@# be several and which this layer cannot compute without duplicating that
	@# choice - a second copy of a decision, in the layer least able to make it.
	@# So the assertion is "at least one component.xml exists below outputs/ip",
	@# which is exactly the claim make is entitled to, and the manifest below
	@# is what records WHICH.
	@test -n "$$(find "$(OUT_DIR)/ip" -name component.xml -type f -print -quit 2>/dev/null)" || { \
	    echo "FAIL: no component.xml anywhere under $(OUT_DIR)/ip"; \
	    echo "      ipx::package_project logs its refusals as warnings and the"; \
	    echo "      tool still exits 0, so this is the only place it shows."; \
	    echo "        grep -nE 'ERROR|CRITICAL WARNING|ipx::' $(LOG_DIR)/package-ip.log"; \
	    echo "        find $(OUT_DIR)/ip -maxdepth 2 -type d"; \
	    exit 1; }
	@test -s "$(REPORT_DIR)/package_ip_manifest.txt" || { \
	    echo "FAIL: no manifest at $(REPORT_DIR)/package_ip_manifest.txt"; \
	    echo "      The stage did not reach its final section, so nothing"; \
	    echo "      recorded which VLNV was packaged or which parameters"; \
	    echo "      survived into it."; \
	    exit 1; }
	@echo "OK: packaged IP under $(OUT_DIR)/ip"
	@find "$(OUT_DIR)/ip" -name component.xml -type f 2>/dev/null | sed 's|^|    |'
	@$(call post_stage_targets,package-ip,$(PACKAGE_IP_POST_TARGETS))
endif

#-----------------------------------------------------------------------------
# STAGE 3 - bd
#-----------------------------------------------------------------------------

## Build the block design, then apply BD_OVERLAY_TCL over it in order.
## SKIPPED, loudly, when BD_TCL is empty.
##
## THE OVERLAYS ARE ORDERED AND THE ORDER IS THE DESIGN. Each one edits the
## design the previous one left, so reordering two of them produces a different
## block design with no error - the list is preserved exactly as written and
## recorded in the manifest for that reason.
bd: dirs check-quiet
ifeq ($(strip $(BD_TCL)),)
	@echo "SKIP: bd - BD_TCL is empty, so this design has no block design."
	@echo "      Nothing was written and no tool was launched. Set BD_TCL in"
	@echo "      fpga/design.mk to turn this stage on."
else
	$(call missing_stage_script,bd,$(FLOW_VIVADO_DIR)/3_bd.tcl)
	$(call vivado_stage,bd,$(FLOW_VIVADO_DIR)/3_bd.tcl)
	@test -s "$(WORK_DIR)/$(DESIGN_NAME).bd" || { \
	    echo "FAIL: no block design at $(WORK_DIR)/$(DESIGN_NAME).bd"; \
	    echo "      The name comes from DESIGN_NAME (currently '$(DESIGN_NAME)',"; \
	    echo "      defaulted from BLOCK). If the BD script names it something"; \
	    echo "      else, set DESIGN_NAME to match - a BD whose file is not"; \
	    echo "      where the flow looks is a BD no later stage will find:"; \
	    echo "        find $(WORK_DIR) -name '*.bd'"; \
	    echo "        grep -nE 'ERROR|CRITICAL WARNING' $(LOG_DIR)/bd.log"; \
	    exit 1; }
	@test -s "$(REPORT_DIR)/bd_manifest.txt" || { \
	    echo "FAIL: no manifest at $(REPORT_DIR)/bd_manifest.txt"; \
	    echo "      The stage did not reach its final section, so the .bd above"; \
	    echo "      is from a partial run and nothing recorded which overlays"; \
	    echo "      were applied to it, or in what order."; \
	    exit 1; }
	@echo "OK: block design $(WORK_DIR)/$(DESIGN_NAME).bd"
	@$(call post_stage_targets,bd,$(BD_POST_TARGETS))
endif

#-----------------------------------------------------------------------------
# STAGE 4 - synth
#-----------------------------------------------------------------------------

## RTL -> a synthesised checkpoint. Reads XDC_PINS as well as the timing
## constraints, because a pin constraint changes what synthesis infers for an
## IO buffer and leaving it to implementation alone gives a different netlist.
##
## VIVADO DROPS A CONSTRAINT THAT MATCHES NOTHING WITHOUT AN ERROR. That is the
## single most expensive silent failure in this flow, it is measured on this
## codebase, and only one flow in the tree gates on it today. The utilisation
## report asserted below is the cheap half of noticing; `make xdc-lint` is the
## half that names the constraint.
synth: dirs check-quiet
	$(call missing_stage_script,synth,$(FLOW_VIVADO_DIR)/4_synth.tcl)
	$(call vivado_stage,synth,$(FLOW_VIVADO_DIR)/4_synth.tcl)
	@test -s "$(OUT_DIR)/$(BLOCK)_synth.dcp" || { \
	    echo "FAIL: synthesis produced no checkpoint at"; \
	    echo "        $(OUT_DIR)/$(BLOCK)_synth.dcp"; \
	    echo "      Vivado exits 0 after a failed synth_design, so without this"; \
	    echo "      test implementation would start on a checkpoint that was"; \
	    echo "      never written. Find the real error with:"; \
	    echo "        grep -nE '^ERROR|CRITICAL WARNING|Failed' $(LOG_DIR)/synth.log"; \
	    exit 1; }
	@test -s "$(REPORT_DIR)/utilization_synth.rpt" || { \
	    echo "FAIL: no post-synthesis utilisation at"; \
	    echo "        $(REPORT_DIR)/utilization_synth.rpt"; \
	    echo "      It is the first place a design that elaborated to almost"; \
	    echo "      nothing shows up - a black-boxed module costs no LUTs and"; \
	    echo "      raises no error. A missing report is UNVERIFIED, not a pass."; \
	    exit 1; }
	@test -s "$(REPORT_DIR)/synth_manifest.txt" || { \
	    echo "FAIL: no manifest at $(REPORT_DIR)/synth_manifest.txt"; \
	    echo "      The stage did not reach its final section, so the checkpoint"; \
	    echo "      above is from a partial run."; \
	    exit 1; }
	@echo "OK: checkpoint  $(OUT_DIR)/$(BLOCK)_synth.dcp"
	@echo "    utilisation $(REPORT_DIR)/utilization_synth.rpt"
	@$(call post_stage_targets,synth,$(SYNTH_POST_TARGETS))

#-----------------------------------------------------------------------------
# STAGE 5 - impl
#-----------------------------------------------------------------------------

## Opt, place, route, and the post-route constraints that cannot be read_xdc'd.
## Writes the routed checkpoint, the timing summary and THE STAGE VERDICT.
##
## XDC_POST_ROUTE IS SOURCED, NOT READ AS A CONSTRAINT FILE. Vivado rejects
## procedural Tcl inside an XDC, and a DRC waiver is procedural Tcl - so it runs
## after route_design or it does not run at all.
##
## THE VERDICT IS A FILE, AND THIS TARGET READS IT. impl_gate.txt has the fixed
## four-class structure in CONTRACT.md section 5: hard failures, budgets
## exceeded, delegated with a named owner, and NOT COVERED BY ANY RUN OF THIS
## FLOW. The last class is the honesty mechanism - a green run still enumerates
## what it did not measure - and the grep below only decides the first.
impl: dirs check-quiet
	$(call missing_stage_script,impl,$(FLOW_VIVADO_DIR)/5_impl.tcl)
	$(call vivado_stage,impl,$(FLOW_VIVADO_DIR)/5_impl.tcl)
	@test -s "$(OUT_DIR)/$(BLOCK)_routed.dcp" || { \
	    echo "FAIL: implementation produced no routed checkpoint at"; \
	    echo "        $(OUT_DIR)/$(BLOCK)_routed.dcp"; \
	    echo "      route_design returns 0 on a route it did not finish, so this"; \
	    echo "      is where an unrouted design is caught. Look for the real"; \
	    echo "      failure with:"; \
	    echo "        grep -nE '^ERROR|Placer could not|Router|CRITICAL WARNING' $(LOG_DIR)/impl.log"; \
	    exit 1; }
	@test -s "$(REPORT_DIR)/timing_summary.rpt" || { \
	    echo "FAIL: no timing summary at $(REPORT_DIR)/timing_summary.rpt"; \
	    echo "      An implementation with no timing report has not been timed."; \
	    echo "      That is UNVERIFIED - it is not a design that met timing."; \
	    exit 1; }
	@test -s "$(REPORT_DIR)/impl_manifest.txt" || { \
	    echo "FAIL: no manifest at $(REPORT_DIR)/impl_manifest.txt"; \
	    echo "      The stage did not reach its final section, so the checkpoint"; \
	    echo "      above is from a partial run."; \
	    exit 1; }
	@# THE GATE ARTEFACT MUST EXIST BEFORE ITS CONTENT MEANS ANYTHING. A
	@# missing verdict is not a passing verdict; it is a stage that stopped
	@# before it reached one.
	@test -s "$(REPORT_DIR)/impl_gate.txt" || { \
	    echo "FAIL: no gate verdict at $(REPORT_DIR)/impl_gate.txt"; \
	    echo "      The stage did not reach its verdict section, so nothing has"; \
	    echo "      judged this run at all. It is UNVERIFIED, not passing."; \
	    exit 1; }
	@# The exact string, anchored. An unanchored grep for 'HARD FAILURES'
	@# matches the section heading itself and passes on every run ever
	@# written - the same shape as a grep that matches a comment in the file
	@# it is checking.
	@grep -q '^HARD FAILURES: none' "$(REPORT_DIR)/impl_gate.txt" || { \
	    echo "FAIL: hard failures - see $(REPORT_DIR)/impl_gate.txt"; \
	    sed -n '/^HARD FAILURES/,/^$$/p' "$(REPORT_DIR)/impl_gate.txt"; \
	    exit 1; }
	@echo "OK: routed  $(OUT_DIR)/$(BLOCK)_routed.dcp"
	@echo "    verdict $(REPORT_DIR)/impl_gate.txt"
	@# Print what this run did NOT measure, every time, on a PASSING run. It
	@# is the section people stop reading once a build goes green, which is
	@# exactly when it matters.
	@sed -n '/^NOT covered by ANY run/,/^$$/p' "$(REPORT_DIR)/impl_gate.txt"
	@$(call post_stage_targets,impl,$(IMPL_POST_TARGETS))

#-----------------------------------------------------------------------------
# STAGE 6 - bitstream
#-----------------------------------------------------------------------------

## Write the bitstream, the .bin and the hardware handoff (.xsa).
##
## THE FIRMWARE IS INSIDE THE BITSTREAM. FPGA_IMAGE_HEX is read at elaboration
## and baked in, so a firmware change with no bitstream rebuild changes nothing
## on the board, and a bitstream rebuild with a stale hex silently ships the old
## image. Both hashes are in the manifest so the pair can be checked afterwards.
##
## .bin IS BOARD-FAMILY DEPENDENT and BIN_STYLE says which conversion to use.
## The two styles are not interchangeable - one needs a byte swap and the other
## a header strip - and the wrong one produces a file that loads and does not
## run, which is a board that comes up dead with no error anywhere.
bitstream: dirs check-quiet
	$(call missing_stage_script,bitstream,$(FLOW_VIVADO_DIR)/6_bitstream.tcl)
	$(call vivado_stage,bitstream,$(FLOW_VIVADO_DIR)/6_bitstream.tcl)
	@test -s "$(OUT_DIR)/$(BLOCK).bit" || { \
	    echo "FAIL: no bitstream at $(OUT_DIR)/$(BLOCK).bit"; \
	    echo "      write_bitstream refuses a design with unrouted nets or"; \
	    echo "      unconstrained IO and says so as a DRC, not as an exit code:"; \
	    echo "        grep -nE '^ERROR|DRC|write_bitstream' $(LOG_DIR)/bitstream.log"; \
	    exit 1; }
	@test -s "$(OUT_DIR)/$(BLOCK).bin" || { \
	    echo "FAIL: no .bin at $(OUT_DIR)/$(BLOCK).bin"; \
	    echo "      The .bin is what a running system loads, and the conversion"; \
	    echo "      is board-family dependent: BIN_STYLE is currently"; \
	    echo "      '$(if $(strip $(BIN_STYLE)),$(BIN_STYLE),(unset))', and it is a"; \
	    echo "      REQUIRED key of the board pack at $(BOARD_DIR)/board.tcl."; \
	    echo "      An unset one is not a default - it is a conversion nobody chose."; \
	    exit 1; }
	@test -s "$(OUT_DIR)/$(BLOCK).xsa" || { \
	    echo "FAIL: no hardware handoff at $(OUT_DIR)/$(BLOCK).xsa"; \
	    echo "      It is what a software build reads to learn the address map,"; \
	    echo "      so without it the firmware and the fabric agree only by"; \
	    echo "      coincidence. write_hw_platform needs a block design:"; \
	    echo "        BD_TCL      = $(if $(strip $(BD_TCL)),$(BD_TCL),(unset))"; \
	    echo "      CONTRACT.md section 4 lists .xsa as asserted for every"; \
	    echo "      bitstream. If this design genuinely cannot produce one, that"; \
	    echo "      is a contract question - raise it, do not delete the test."; \
	    exit 1; }
	@test -s "$(REPORT_DIR)/bitstream_manifest.txt" || { \
	    echo "FAIL: no manifest at $(REPORT_DIR)/bitstream_manifest.txt"; \
	    echo "      The stage did not reach its final section, so nothing"; \
	    echo "      recorded which firmware image is inside the bitstream above."; \
	    exit 1; }
	@echo "OK: bitstream $(OUT_DIR)/$(BLOCK).bit ($$(du -h "$(OUT_DIR)/$(BLOCK).bit" | cut -f1))"
	@echo "    .bin      $(OUT_DIR)/$(BLOCK).bin  (style $(if $(strip $(BIN_STYLE)),$(BIN_STYLE),(unset)))"
	@echo "    handoff   $(OUT_DIR)/$(BLOCK).xsa"
	@# DEPLOY LANDS HERE. Non-fatal to the build, fatal to the claim.
	@$(call post_stage_targets,bitstream,$(BITSTREAM_POST_TARGETS))

#-----------------------------------------------------------------------------
# THE WHOLE FLOW
#-----------------------------------------------------------------------------

## Every stage in order, unattended. Long - implementation alone is tens of
## minutes to hours on a real design.
##
## THE ORDER IS IN THE RECIPE, NOT IN A PREREQUISITE LIST, and that is the whole
## point of this target's shape.
##
## `all: dirs flist package-ip bd synth impl bitstream` states seven
## prerequisites and NO ORDERING BETWEEN THEM. Serial make happens to run them
## left to right, so it looks correct for exactly as long as nobody passes -j;
## under `make -j all` make is free to start `impl` while `synth` is still
## running, and the stages hand a checkpoint to each other through $(WORK_DIR)
## and $(OUT_DIR). They cannot overlap at all - so the ordering is not a
## preference, it is the only correct execution.
##
## Recipe lines run in sequence BY DEFINITION, in every make, at every -j. So
## the seven sub-makes below are ordered by construction, and nothing else in
## the project loses its parallelism. `$(MAKE)` marks each line recursive, so
## `make -n all` still descends into all seven with -n propagated rather than
## printing seven command lines it never enters.
##
## WHY NOT `.NOTPARALLEL: synth impl`. Scoped .NOTPARALLEL - the form that names
## the targets it applies to - is GNU Make 4.4. The sites this toolkit runs on
## are older (this run: $(MAKE_VERSION)), where `.NOTPARALLEL` takes no arguments
## and serialises THE ENTIRE MAKEFILE, costing every unrelated target its
## parallelism including a static-check lane that shares nothing with the build.
## Recipe ordering needs no version floor and takes parallelism from nothing.
##
## A stage that fails stops the chain: each line is a separate command and make
## abandons the recipe on the first non-zero status. `dirs` is included as a
## line of its own rather than left to the stages' prerequisites so that a
## failure to create the run tree is reported by itself, before a tool starts.
all:
	@$(MAKE) dirs
	@$(MAKE) flist
	@$(MAKE) package-ip
	@$(MAKE) bd
	@$(MAKE) synth
	@$(MAKE) impl
	@$(MAKE) bitstream

#-----------------------------------------------------------------------------
# 10. META TARGETS - no tool, no licence
#-----------------------------------------------------------------------------

# $(call fpga_or_none,<value>) - render an empty value as the literal string
# (none). CONTRACT.md section 11.2 requires it, and the reason is that a blank
# column and a value that happens to be blank are indistinguishable in a
# terminal: an unset optional prints as nothing, a broken lookup prints as
# nothing, and a variable whose value is a single space prints as nothing.
fpga_or_none = $(if $(strip $(1)),$(strip $(1)),(none))

## Print every variable the tools will see, in three blocks: the engine, this
## run, and the project contract. The fastest way to answer "why is it reading
## THAT file". Empty values print as (none), never as a blank column.
env:
	@echo "== engine =="
	@printf '  %-24s %s\n' FPGA_FLOW_DIR   "$(FPGA_FLOW_DIR)"
	@printf '  %-24s %s\n' FPGA_DIR        "$(FPGA_DIR)"
	@printf '  %-24s %s\n' BLOCK           "$(BLOCK)"
	@printf '  %-24s %s\n' DESIGN_NAME     "$(DESIGN_NAME)"
	@printf '  %-24s %s\n' BOARD           "$(BOARD)"
	@printf '  %-24s %s\n' BOARD_DIR       "$(BOARD_DIR)"
	@printf '  %-24s %s\n' TARGET          "$(TARGET)"
	@printf '  %-24s %s\n' TARGET_DIR      "$(TARGET_DIR)"
	@printf '  %-24s %s\n' PART            "$(call fpga_or_none,$(PART))"
	@printf '  %-24s %s\n' PART_DIR        "$(call fpga_or_none,$(PART_DIR))"
	@printf '  %-24s %s\n' PLATFORM        "$(call fpga_or_none,$(PLATFORM))"
	@printf '  %-24s %s\n' FLOW_MODE       "$(FLOW_MODE)"
	@printf '  %-24s %s\n' VIVADO          "$(VIVADO)"
	@printf '  %-24s %s\n' VIVADO_VER      "$(call fpga_or_none,$(VIVADO_VER))"
	@printf '  %-24s %s\n' NUM_JOBS        "$(NUM_JOBS)"
	@printf '  %-24s %s\n' 'seams file'    "$(FPGA_SEAMS_FILE)"
	@printf '  %-24s %s\n' 'make version'  "$(MAKE_VERSION)"
	@echo "== this run =="
	@printf '  %-24s %s\n' RUN_TAG         "$(RUN_TAG)"
	@printf '  %-24s %s\n' RUN_DIR         "$(RUN_DIR)"
	@printf '  %-24s %s\n' WORK_DIR        "$(WORK_DIR)"
	@printf '  %-24s %s\n' LOG_DIR         "$(LOG_DIR)"
	@printf '  %-24s %s\n' REPORT_DIR      "$(REPORT_DIR)"
	@printf '  %-24s %s\n' OUT_DIR         "$(OUT_DIR)"
	@printf '  %-24s %s\n' IN_RUN_TAG      "$(IN_RUN_TAG)"
	@printf '  %-24s %s\n' IN_WORK_DIR     "$(IN_WORK_DIR)"
	@printf '  %-24s %s\n' SYNTH_RUN_TAG   "$(SYNTH_RUN_TAG)"
	@printf '  %-24s %s\n' SYNTH_OUT_DIR   "$(SYNTH_OUT_DIR)"
	@printf '  %-24s %s\n' BUILD_DIR       "$(BUILD_DIR)"
	@echo "== project contract =="
	@printf '  %-24s %s\n' TOP             "$(call fpga_or_none,$(TOP))"
	@printf '  %-24s %s\n' TOP_HDL         "$(call fpga_or_none,$(TOP_HDL))"
	@printf '  %-24s %s\n' RTL_FLIST       "$(call fpga_or_none,$(RTL_FLIST))"
	@printf '  %-24s %s\n' RTL_FLIST_GEN   "$(call fpga_or_none,$(RTL_FLIST_GEN))"
	@printf '  %-24s %s\n' RTL_INCDIRS     "$(call fpga_or_none,$(RTL_INCDIRS))"
	@printf '  %-24s %s\n' RTL_DEFINES     "$(call fpga_or_none,$(RTL_DEFINES))"
	@printf '  %-24s %s\n' RTL_DEFINES_INBODY "$(call fpga_or_none,$(RTL_DEFINES_INBODY))"
	@printf '  %-24s %s\n' RTL_DEFINES_NEVER  "$(call fpga_or_none,$(RTL_DEFINES_NEVER))"
	@printf '  %-24s %s\n' RTL_PARAMS      "$(call fpga_or_none,$(RTL_PARAMS))"
	@printf '  %-24s %s\n' EXTRA_SRCS      "$(call fpga_or_none,$(EXTRA_SRCS))"
	@printf '  %-24s %s\n' SV_FILES        "$(call fpga_or_none,$(SV_FILES))"
	@printf '  %-24s %s\n' XDC_PINS        "$(call fpga_or_none,$(XDC_PINS))"
	@printf '  %-24s %s\n' XDC_TIMING      "$(call fpga_or_none,$(XDC_TIMING))"
	@printf '  %-24s %s\n' XDC_DRC         "$(call fpga_or_none,$(XDC_DRC))"
	@printf '  %-24s %s\n' XDC_EXTRA       "$(call fpga_or_none,$(XDC_EXTRA))"
	@printf '  %-24s %s\n' XDC_OPTIONAL    "$(call fpga_or_none,$(XDC_OPTIONAL))"
	@printf '  %-24s %s\n' XDC_POST_ROUTE  "$(call fpga_or_none,$(XDC_POST_ROUTE))"
	@printf '  %-24s %s\n' XDC_BASELINE    "$(call fpga_or_none,$(XDC_BASELINE))"
	@printf '  %-24s %s\n' IP_REPOS        "$(call fpga_or_none,$(IP_REPOS))"
	@printf '  %-24s %s\n' IP_VENDOR       "$(call fpga_or_none,$(IP_VENDOR))"
	@printf '  %-24s %s\n' IP_CORE_REV     "$(call fpga_or_none,$(IP_CORE_REV))"
	@printf '  %-24s %s\n' IP_CACHE_DIR    "$(call fpga_or_none,$(IP_CACHE_DIR))"
	@printf '  %-24s %s\n' PACKAGE_TCL     "$(call fpga_or_none,$(PACKAGE_TCL))"
	@printf '  %-24s %s\n' BD_TCL          "$(call fpga_or_none,$(BD_TCL))"
	@printf '  %-24s %s\n' BD_OVERLAY_TCL  "$(call fpga_or_none,$(BD_OVERLAY_TCL))"
	@printf '  %-24s %s\n' BD_GLOBAL_SYNTH "$(BD_GLOBAL_SYNTH)"
	@printf '  %-24s %s\n' BOARD_PART      "$(call fpga_or_none,$(BOARD_PART))"
	@printf '  %-24s %s\n' BOARD_REPO_PATHS "$(call fpga_or_none,$(BOARD_REPO_PATHS))"
	@printf '  %-24s %s\n' SYS_CLK_FREQ_HZ "$(call fpga_or_none,$(SYS_CLK_FREQ_HZ))"
	@printf '  %-24s %s\n' FW_APP          "$(call fpga_or_none,$(FW_APP))"
	@printf '  %-24s %s\n' FW_HEX          "$(call fpga_or_none,$(FW_HEX))"
	@printf '  %-24s %s\n' FW_HEX_FORMAT   "$(call fpga_or_none,$(FW_HEX_FORMAT))"
	@printf '  %-24s %s\n' FPGA_IMAGE_HEX  "$(call fpga_or_none,$(FPGA_IMAGE_HEX))"
	@printf '  %-24s %s\n' HOOKS_DIR       "$(HOOKS_DIR)"
	@printf '  %-24s %s\n' OVERRIDES_DIR   "$(OVERRIDES_DIR)"
	@printf '  %-24s %s\n' BIN_STYLE       "$(call fpga_or_none,$(BIN_STYLE))"
	@printf '  %-24s %s\n' FPGAHUB_BOARD   "$(call fpga_or_none,$(FPGAHUB_BOARD))"
	@printf '  %-24s %s\n' FPGAHUB_TARGET  "$(call fpga_or_none,$(FPGAHUB_TARGET))"
	@printf '  %-24s %s\n' FPGAHUB_TOML    "$(call fpga_or_none,$(FPGAHUB_TOML))"
	@echo "== gates and post-stage targets =="
	@printf '  %-24s %s\n' EXPECT_WNS_MIN  "$(EXPECT_WNS_MIN)"
	@printf '  %-24s %s\n' EXPECT_WHS_MIN  "$(EXPECT_WHS_MIN)"
	@printf '  %-24s %s\n' EXPECT_LUT_MAX  "$(EXPECT_LUT_MAX)"
	@printf '  %-24s %s\n' EXPECT_FF_MAX   "$(EXPECT_FF_MAX)"
	@printf '  %-24s %s\n' EXPECT_BRAM_MAX "$(EXPECT_BRAM_MAX)"
	@printf '  %-24s %s\n' EXPECT_DSP_MAX  "$(EXPECT_DSP_MAX)"
	@printf '  %-24s %s\n' EXPECT_UNROUTED_MAX "$(EXPECT_UNROUTED_MAX)"
	@printf '  %-24s %s\n' EXPECT_BLACKBOX_MAX "$(EXPECT_BLACKBOX_MAX)"
	@printf '  %-24s %s\n' ALLOW_CRITICAL_WARNINGS "$(ALLOW_CRITICAL_WARNINGS)"
	@printf '  %-24s %s\n' MSG_GATE_ALLOWLIST "$(call fpga_or_none,$(MSG_GATE_ALLOWLIST))"
	@printf '  %-24s %s\n' FLIST_POST_TARGETS      "$(call fpga_or_none,$(FLIST_POST_TARGETS))"
	@printf '  %-24s %s\n' PACKAGE_IP_POST_TARGETS "$(call fpga_or_none,$(PACKAGE_IP_POST_TARGETS))"
	@printf '  %-24s %s\n' BD_POST_TARGETS         "$(call fpga_or_none,$(BD_POST_TARGETS))"
	@printf '  %-24s %s\n' SYNTH_POST_TARGETS      "$(call fpga_or_none,$(SYNTH_POST_TARGETS))"
	@printf '  %-24s %s\n' IMPL_POST_TARGETS       "$(call fpga_or_none,$(IMPL_POST_TARGETS))"
	@printf '  %-24s %s\n' BITSTREAM_POST_TARGETS  "$(call fpga_or_none,$(BITSTREAM_POST_TARGETS))"
	@printf '  %-24s %s\n' 'aliases in use'   "$(call fpga_or_none,$(FPGA_ALIASES_USED))"
	@printf '  %-24s %s\n' 'derived preset'   "$(call fpga_or_none,$(FPGA_DERIVED_PRESET))"
	@printf '  %-24s %s\n' '*_POST_TARGETS'   "$(call fpga_or_none,$(FPGA_POST_TARGET_VARS))"

## Which stages have actually run, read from the artefacts on disk rather than
## from anything the flow remembers. A run whose logs say it succeeded and whose
## outputs are absent shows up here as it really is.
status:
	@echo "== $(BLOCK), run tag '$(RUN_TAG)' =="
	@printf '  %-16s %-4s %s\n' STAGE OK ARTEFACT
	@for spec in \
	    "dirs:$(RUN_DIR)" \
	    "flist:$(WORK_DIR)/sources.tcl" \
	    "flist-rep:$(REPORT_DIR)/flist_manifest.txt" \
	    "package-ip:$(REPORT_DIR)/package_ip_manifest.txt" \
	    "bd:$(WORK_DIR)/$(DESIGN_NAME).bd" \
	    "synth:$(OUT_DIR)/$(BLOCK)_synth.dcp" \
	    "synth-util:$(REPORT_DIR)/utilization_synth.rpt" \
	    "impl:$(OUT_DIR)/$(BLOCK)_routed.dcp" \
	    "impl-timing:$(REPORT_DIR)/timing_summary.rpt" \
	    "impl-gate:$(REPORT_DIR)/impl_gate.txt" \
	    "bit:$(OUT_DIR)/$(BLOCK).bit" \
	    "bin:$(OUT_DIR)/$(BLOCK).bin" \
	    "xsa:$(OUT_DIR)/$(BLOCK).xsa" ; do \
	    stage=$${spec%%:*}; path=$${spec#*:}; \
	    if [ -s "$$path" ] || [ -d "$$path" ]; then \
	        printf '  %-16s %-4s %s\n' "$$stage" "yes" "$$path"; \
	    else \
	        printf '  %-16s %-4s %s\n' "$$stage" "--" "$$path"; \
	    fi; \
	done
	@echo ""
	@# The two conditional stages have no artefact when they were skipped on
	@# purpose, so a '--' against them means one of two entirely different
	@# things. Say which, rather than leaving the reader to guess.
	@if [ -z "$(strip $(PACKAGE_TCL))" ]; then \
	    echo "  package-ip is OFF for this design (PACKAGE_TCL is empty)"; fi
	@if [ -z "$(strip $(BD_TCL))" ]; then \
	    echo "  bd is OFF for this design (BD_TCL is empty)"; fi
	@if [ -s "$(REPORT_DIR)/impl_gate.txt" ]; then \
	    echo ""; \
	    grep -m1 '^HARD FAILURES' "$(REPORT_DIR)/impl_gate.txt" | sed 's/^/  impl gate: /'; \
	fi
	@echo ""
	@echo "  runs in $(BUILD_DIR):"
	@ls -1 "$(BUILD_DIR)" 2>/dev/null | sed 's/^/    /' || echo "    (none yet)"

#-----------------------------------------------------------------------------
# INSPECTION
#-----------------------------------------------------------------------------

# What `make gui` opens. Empty means "pick the most finished thing this run has",
# which is decided in the recipe because it depends on what is on disk now.
GUI_OPEN ?=
GUI_DCP  ?= $(OUT_DIR)/$(BLOCK)_routed.dcp
GUI_XPR  ?= $(WORK_DIR)/$(BLOCK).xpr

## Vivado's GUI, with this run's project or checkpoint loaded. Override what it
## opens with GUI_OPEN=<path to an .xpr or a .dcp>.
##
## THE DISPLAY IS PROBED FOR REAL, NOT WITH `test -n "$$DISPLAY"`. A malformed
## DISPLAY - "12.0", with no leading colon - passes a non-empty test and then
## fails inside the tool, and a stale one from a closed desktop session passes it
## too. Both produce a tool that appears simply not to have started.
gui:
	@test -n "$$DISPLAY" || { \
	    echo "FAIL: DISPLAY is not set in THIS shell. A remote desktop's DISPLAY"; \
	    echo "      does not reach an ssh terminal - run make from a terminal"; \
	    echo "      inside the desktop, or 'ssh -X <host>'."; \
	    echo "      Text-mode session on purpose?   make vivado-shell"; \
	    exit 1; }
	@# xdpyinfo is the probe because it CONNECTS. `xset q` is the usual
	@# alternative and it is present on fewer minimal images; either is
	@# better than believing the variable.
	@command -v xdpyinfo >/dev/null 2>&1 || { \
	    echo "FAIL: DISPLAY='$$DISPLAY' but xdpyinfo is not installed, so this"; \
	    echo "      target cannot tell a live X server from a stale variable -"; \
	    echo "      and it will not pretend it can. Install xdpyinfo (xorg-x11-"; \
	    echo "      utils / x11-utils), or run 'make vivado-shell' instead."; \
	    exit 1; }
	@xdpyinfo >/dev/null 2>&1 || { \
	    echo "FAIL: DISPLAY='$$DISPLAY' but no X server answers there, so Vivado"; \
	    echo "      would fail to open a window and report a display error that"; \
	    echo "      names Qt rather than the session."; \
	    case "$$DISPLAY" in \
	      [0-9]*) echo "      It is missing the leading colon. Try: export DISPLAY=:$$DISPLAY" ;; \
	      *)      echo "      Check the session is alive: xdpyinfo | head -3" ;; \
	    esac; exit 1; }
	@# WHAT TO OPEN. Chosen here rather than at parse time because it depends
	@# on what exists on disk at the moment the target runs, which a parse-time
	@# $(wildcard) evaluated before any stage ran would get wrong.
	@open="$(GUI_OPEN)"; \
	if [ -z "$$open" ]; then \
	    if   [ -s "$(GUI_XPR)" ]; then open="$(GUI_XPR)"; \
	    elif [ -s "$(GUI_DCP)" ]; then open="$(GUI_DCP)"; \
	    fi; \
	fi; \
	if [ -z "$$open" ]; then \
	    echo "FAIL: this run has nothing to open."; \
	    echo "      Looked for:"; \
	    echo "        $(GUI_XPR)"; \
	    echo "        $(GUI_DCP)"; \
	    echo "      'make status' lists what has run. Pick one explicitly with"; \
	    echo "      GUI_OPEN=<path>, or point RUN_TAG at a finished run."; \
	    exit 1; \
	fi; \
	test -s "$$open" || { \
	    echo "FAIL: GUI_OPEN='$$open' does not exist or is empty."; exit 1; }; \
	mkdir -p "$(WORK_DIR)"; \
	case "$$open" in \
	  *.xpr) printf '%s\n' "open_project {$$open}" \
	                       "puts \"== $$open opened ==\"" \
	         > "$(WORK_DIR)/open_gui.tcl" ;; \
	  *)     printf '%s\n' "open_checkpoint {$$open}" \
	                       "puts \"== $$open opened ==\"" \
	         > "$(WORK_DIR)/open_gui.tcl" ;; \
	esac; \
	echo "opening $$open"; \
	cd "$(WORK_DIR)" && $(VIVADO) -mode gui \
	    -log "$(LOG_DIR)/gui.log" -journal "$(LOG_DIR)/gui.jou" \
	    -source "$(WORK_DIR)/open_gui.tcl"

## An interactive Vivado Tcl shell in this run's work directory, with the whole
## FPGA_* environment exported - so anything a stage script does can be tried by
## hand and behave identically. No design is opened and nothing is configured.
vivado-shell: dirs
	cd "$(WORK_DIR)" && $(VIVADO) -mode tcl \
	    -log "$(LOG_DIR)/shell.log" -journal "$(LOG_DIR)/shell.jou"

#-----------------------------------------------------------------------------
# HOUSEKEEPING
#
# Both quote every path. BUILD_DIR with a space in it is supported deliberately
# - it is the variable people point at a scratch filesystem, and scratch mounts
# have spaces in their names more often than anyone would like - so the relative
# path guard in section 2 is a $(subst) rather than an $(abspath), and these two
# recipes quote.
#-----------------------------------------------------------------------------

## Drop this run's rerunnable intermediates - work/ and logs/. KEEPS outputs/
## and reports/, so a finished bitstream and its manifests survive.
clean:
	@echo "removing $(WORK_DIR) and $(LOG_DIR) (outputs/ and reports/ kept)"
	rm -rf "$(WORK_DIR)" "$(LOG_DIR)"

## clean, plus outputs/ and reports/ for this run tag - DELETES THE BITSTREAM
## and every manifest that says how it was built. Prints what is about to go
## first, because a run tag is one word and the wrong one is one keystroke.
distclean:
	@echo "about to remove $(RUN_DIR) entirely, including:"
	@test -s "$(OUT_DIR)/$(BLOCK).bit" && \
	    echo "  !! $(OUT_DIR)/$(BLOCK).bit ($$(du -h "$(OUT_DIR)/$(BLOCK).bit" | cut -f1))" || true
	@du -sh "$(OUT_DIR)" "$(REPORT_DIR)" 2>/dev/null | sed 's/^/  /' || true
	rm -rf "$(RUN_DIR)"

#-----------------------------------------------------------------------------
# 11. OPTIONAL FRAGMENTS - the opt-OUT, for the fragments phase 2 and 3 add
#
# There are none to include yet. The machinery is here now, and not later, for
# the reason the reference toolkit records: its optional gates were opt-IN, so a
# project got one only by already knowing it existed, and the measured
# consequence was a FORK of a gate in a consuming project's own makefile because
# the toolkit's copy was not reachable from the one line every project writes. A
# gate nobody can reach is a gate nobody runs, and a forked gate is two gates
# that drift.
#
# So future fragments are included UNCONDITIONALLY and a project that supplies
# one itself says so, by name, in its own makefile:
#
#     FPGA_FLOW_SKIP_MK := xdc_lint     # in fpga/design.mk, before the include
#
# An opt-out is a line that has to name the thing it is overriding. An opt-in is
# a line nobody writes.
#
# TWO WAYS A FRAGMENT GETS DEFINED TWICE, AND WHAT EACH COSTS. GNU make does not
# refuse a redefinition: it prints "overriding recipe for target X" and silently
# keeps the LAST one, so the failure mode is a working gate quietly replaced.
#
#   1. THE SAME FILE READ TWICE - a fragment without its own include guard, or
#      one whose header tells a project to include it directly. fpga_flow_read
#      below skips anything make has already read.
#
#   2. A PROJECT THAT SUPPLIES THE SAME GATE ITSELF, from a file of its own,
#      under the same target names. NO INCLUDE GUARD CAN SEE THAT: the target
#      names collide, the files do not. FPGA_FLOW_SKIP_MK is the only defence,
#      and it is a manual name check redone whenever a target is added.
#-----------------------------------------------------------------------------

FPGA_FLOW_SKIP_MK ?=

# Two reasons to skip, one per line so that each can be deleted on its own - a
# guard whose removal changes nothing was never a guard, and separating them is
# what makes that testable.
#
# Both are RECURSIVELY EXPANDED on purpose. $(MAKEFILE_LIST) grows with every
# include, so the "already read" test has to be made at each call rather than
# against a snapshot taken before the first one.

# 1. The project said it supplies this one itself.
fpga_flow_skipped = $(filter $(1),$(FPGA_FLOW_SKIP_MK))

# 2. Make has already read this exact file. RESOLVED PATHS, NOT BASENAMES: a
# project that has a file of its own called xdc_lint.mk must not thereby
# suppress the toolkit's, and one that spells its include relatively, through a
# symlink, or with a '..' in it must still be recognised as the same file.
# $(realpath) settles both, and $(notdir)-style comparison settles neither.
#
# A fragment MISSING from disk resolves to an empty $(realpath), matches
# nothing, and is therefore INCLUDED - so make fails loudly on the missing file
# rather than quietly skipping a gate, which is the failure this whole block
# exists to end.
fpga_flow_read = $(filter $(realpath $(FPGA_FLOW_DIR)/mk/$(1).mk),$(realpath $(MAKEFILE_LIST)))

# Include $(FPGA_FLOW_DIR)/mk/<1>.mk unless one of the two says otherwise.
fpga_flow_optional = $(if $(call fpga_flow_skipped,$(1))$(call fpga_flow_read,$(1)),,$(eval include $(FPGA_FLOW_DIR)/mk/$(1).mk))

# No calls yet. Phase 2 adds them here, one per line, each with a comment saying
# what the fragment provides - e.g. $(call fpga_flow_optional,xdc_lint).

endif  # FPGA_FLOW_MK_INCLUDED

# Copyright (C) 2026, SoC Labs (www.soclabs.org)
