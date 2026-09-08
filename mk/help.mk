#-----------------------------------------------------------------------------
# mk/help.mk - what a person types, in the order they will need to type it
#
# Included by mk/flow.mk. Launches no tool, reads no run directory, writes
# nothing. Four targets, and they answer four different questions:
#
#   help        WHAT DO I RUN.       Curated, hand-ordered, and deliberately
#                                    incomplete. Written for somebody who has
#                                    not built an FPGA image before.
#   help-all    WHAT EXISTS.         Generated from the `##` blocks in the make
#                                    fragments, so it cannot go stale.
#   help-knobs  WHAT CAN I CHANGE.   Read out of the flow scripts themselves.
#   help-hooks  WHERE CAN I EXTEND.  Read out of flow/common/seams.txt.
#
# WHY `help` IS HAND-WRITTEN WHEN `help-all` IS GENERATED. A generated list is
# alphabetical, or it is in file order, and both are orders in which nobody
# works. The first question a new person has is not "what targets exist", it is
# "which one do I type first and what does it need from me" - and the answer to
# that is a sequence, with the prerequisites of the sequence in front of it.
# That is a judgement, it goes stale slowly, and the cost of it going stale is a
# person reading one extra line. The cost of `help-all` going stale is a target
# nobody knows about, which is why THAT one is generated and this one is not.
#
# NOTHING HERE MAY NAME A BOARD, A PIN, A PART OR A PROJECT PATH (CONTRACT §11.8).
# Every such value on the screen below is a variable this run resolved, printed
# from the variable. If a literal ever appears in this file it is a bug in the
# file, not a convenience.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------

.PHONY: help help-all help-knobs help-hooks

# THE ENGINE PATH, RESOLVED FROM THIS FILE'S OWN LOCATION WHEN NOBODY SUPPLIED
# IT. mk/flow.mk hard-errors on an empty FPGA_FLOW_DIR (CONTRACT §2) and is the
# only file entitled to make that judgement, so this one does not repeat it -
# but `make -f mk/help.mk help` from a fresh clone, with no project anywhere, is
# a thing people do to find out what the toolkit is, and a help target that
# cannot run without a project manifest is a help target for people who already
# know. Same idiom as the shell scripts' BASH_SOURCE resolution, for the same
# reason: a file that can locate itself never needs to be told where it is.
ifeq ($(strip $(FPGA_ENGINE_DIR)),)
  ifeq ($(strip $(FPGA_FLOW_DIR)),)
    FPGA_ENGINE_DIR := $(abspath $(dir $(abspath $(lastword $(MAKEFILE_LIST))))/..)
  else
    FPGA_ENGINE_DIR := $(abspath $(FPGA_FLOW_DIR))
  endif
endif

# `(none)` RENDERED, NEVER LEFT BLANK (CONTRACT §11.2). A blank after a label
# reads as "this is fine, it just did not fit"; the literal word reads as the
# measurement it is - nobody set this.
help-none = $(if $(strip $(1)),$(strip $(1)),(none))

## What to type, in the order you will need to type it. The curated list; see
## `make help-all` for every target and `make help-knobs` for every setting.
help:
	@echo "$(call help-none,$(BLOCK)) - FPGA image build (Vivado), board $(call help-none,$(BOARD))"
	@echo ""
	@echo "  THE FLOW, in order. Each stage reads what the last one wrote."
	@echo "    make flist        the source list Vivado will read      (no tool)"
	@echo "    make package-ip   RTL -> a packaged IP, when one is used"
	@echo "    make bd           the block design, when one is used"
	@echo "    make synth        RTL -> a synthesised checkpoint"
	@echo "    make impl         place + route -> a routed checkpoint"
	@echo "    make bitstream    the routed checkpoint -> .bit .bin .xsa"
	@echo "    make all          all of them, unattended. TENS OF MINUTES TO HOURS."
	@echo ""
	@echo "    package-ip and bd are skipped when the project configures neither."
	@echo "    Every stage writes into build/<RUN_TAG>/ and reads the stage before"
	@echo "    it from there, so they MUST run in order. To resume a part-finished"
	@echo "    build, invoke the stage you stopped at - not 'all'."
	@echo "    'make status' says which stages have artefacts on disk."
	@echo ""
	@echo "  BEFORE THE FIRST BUILD - none of these starts a tool"
	@echo "    make check        is this project's contract complete?     (<1s)"
	@echo "    make doctor       can THIS MACHINE run the flow?           (<5s)"
	@echo "    make env          every variable the tools will be given"
	@echo "    make part-probe   load and validate the part pack   (toolkit-owned)"
	@echo "    make board-probe  load and validate the board pack  (project-owned)"
	@echo "    make hooks-install  refuse to COMMIT vendor collateral. Once per"
	@echo "                        clone; nothing in the build depends on it."
	@echo ""
	@echo "    'make check' is the one to run after every edit to design.mk. It"
	@echo "    reports the CANONICAL name of every input, so a value that arrived"
	@echo "    through an alias still shows up under the name the flow uses."
	@echo ""
	@echo "  COMPARING TWO BUILDS. Everything a build writes lives under"
	@echo "  build/<RUN_TAG>/, so two builds never collide. A stage reads its"
	@echo "  input from IN_RUN_TAG's directory, which is how you re-run one stage"
	@echo "  against another build's output without repeating the hours before it."
	@echo "    make all    RUN_TAG=baseline"
	@echo "    make impl   RUN_TAG=trial IN_RUN_TAG=baseline SYNTH_RUN_TAG=baseline"
	@echo "    make compare-runs RUN_TAG=trial IN_RUN_TAG=baseline"
	@echo ""
	@echo "    compare-runs REFUSES (exit 2) when either side is UNVERIFIED or"
	@echo "    when the two manifests say they are not the same design. Two"
	@echo "    numbers that came from different designs are not a comparison."
	@echo ""
	@echo "  VERIFICATION - separate targets, not part of 'make all'"
	@echo "    make xdc-lint       did every constraint MATCH something?"
	@echo "    make util-census    LUT/FF/BRAM/DSP against the budgets"
	@echo "    make timing-census  WNS/WHS against the budgets"
	@echo "    make msg-gate       the tool messages, against the allowlist"
	@echo ""
	@echo "    Vivado exits 0 on a failed route, on unmet timing, and on a"
	@echo "    constraint file that matched NOTHING. Every target above reads an"
	@echo "    artefact and reaches its own verdict; none of them trusts an exit"
	@echo "    status, and none reports a number it did not measure."
	@echo ""
	@echo "  WHEN SOMETHING IS WRONG"
	@echo "    make status       which stages have run, from the artefacts on disk"
	@echo "    make flow-state   the same question, in one machine-readable line"
	@echo "    make gui          Vivado's GUI on this run's project"
	@echo "    make vivado-shell an interactive Tcl shell with this run's setup"
	@echo "    make help-knobs   every setting, read out of the flow scripts"
	@echo "    make help-hooks   where this project can extend the flow"
	@echo "    make help-all     every target"
	@echo ""
	@echo "  HOUSEKEEPING"
	@echo "    make clean        drop work/ and logs/ for this run  (KEEPS outputs)"
	@echo "    make distclean    drop the whole run tag             (DELETES the .bit)"
	@echo "    make hooks-status what the git hooks are doing in this repository"
	@echo ""
	@echo "  This run:  RUN_TAG=$(call help-none,$(RUN_TAG))  ->  $(call help-none,$(RUN_DIR))"
	@echo "  Board   :  $(call help-none,$(BOARD))"
	@echo "  Part    :  $(call help-none,$(PART))"
	@echo "  Mode    :  FLOW_MODE=$(call help-none,$(FLOW_MODE))"
	@echo "  Engine  :  $(call help-none,$(FPGA_ENGINE_DIR))"

# THE FIXED FILE LIST `help-all` READS.
#
# Fixed, and not a glob, because this list is a CLAIM about which fragments
# carry documented targets - and a glob would quietly start reporting on a
# fragment somebody dropped into mk/ without `##` blocks, or quietly stop
# reporting when one was renamed. A missing entry here is reported by the recipe
# rather than skipped: an omission that prints nothing is the failure this whole
# target exists to prevent.
HELP_DOC_FILES := \
    $(FPGA_ENGINE_DIR)/mk/flow.mk \
    $(FPGA_ENGINE_DIR)/mk/checks.mk \
    $(FPGA_ENGINE_DIR)/mk/help.mk \
    $(FPGA_ENGINE_DIR)/mk/hooks.mk \
    $(FPGA_ENGINE_DIR)/mk/deploy.mk

## Every target, with its one-line description, generated from the `##` comment
## blocks in the make fragments. The FIRST `##` line of a block is the summary
## printed here; the lines under it are detail, and are read in the file.
help-all:
	@echo "All targets, from the ## blocks in mk/*.mk:"
	@echo ""
	@# A DECLARED FILE THAT IS NOT THERE IS ANNOUNCED, NOT SKIPPED. awk given a
	@# missing file prints a diagnostic to stderr and carries on with the rest,
	@# which on a terminal looks close enough to success to be believed - and the
	@# result is a target list that is missing a whole fragment while claiming to
	@# be everything.
	@missing=""; present=""; \
	 for f in $(HELP_DOC_FILES); do \
	     if [ -r "$$f" ]; then present="$$present $$f"; else missing="$$missing $$f"; fi; \
	 done; \
	 if [ -z "$$present" ]; then \
	     echo "  NOT ONE of the declared fragments could be read. This list is empty because"; \
	     echo "  nothing was scanned, which is not the same as a toolkit with no targets:"; \
	     for f in $(HELP_DOC_FILES); do echo "      $$f"; done; \
	     exit 1; \
	 fi; \
	 awk 'BEGIN{FS=":"} \
	      /^## / { if (d == "") d = substr($$0,4); next } \
	      /^[a-zA-Z0-9_.-]+:/ { if (d != "") { printf "  %-18s %s\n", $$1, d; d="" } next } \
	      /^$$/ { d="" }' $$present; \
	 if [ -n "$$missing" ]; then \
	     echo ""; \
	     echo "  NOT READ - these fragments are declared in HELP_DOC_FILES and are not"; \
	     echo "  present, so any target they define is missing from the list above:"; \
	     for f in $$missing; do echo "      $$f"; done; \
	 fi

## Every stage knob and its default, read straight out of the flow scripts, so
## the list cannot drift from the code. Set any of them on the command line for
## one build, or in the project's design.mk permanently; each one lands in that
## stage's manifest automatically.
help-knobs:
	@# THE FILE LIST IS FOUND, NOT WRITTEN DOWN. The reference ASIC toolkit
	@# hardcodes the scripts it reads here, and one of them - the flist reader,
	@# which carries the FLIST_* knobs and is sourced by the synthesis stage -
	@# was never added to the list. The consequence was not a warning: this
	@# target simply never mentioned those knobs, the manifest reader who trusted
	@# it to be complete never saw them, and nothing anywhere said a file was
	@# missing. A find over flow/ cannot have that defect: a script added there
	@# tomorrow, at any depth, is in this list tomorrow.
	@dir='$(FPGA_ENGINE_DIR)'; \
	 if [ ! -d "$$dir/flow" ]; then \
	     echo "  $$dir/flow does not exist - there are no flow scripts to read knobs out of."; \
	     echo "  This is an empty answer because nothing was scanned, not because the flow"; \
	     echo "  has no knobs."; \
	     exit 1; \
	 fi; \
	 files=$$(find "$$dir/flow" -type f -name '*.tcl' 2>/dev/null | sort); \
	 if [ -z "$$files" ]; then \
	     echo "  $$dir/flow holds no .tcl file. Nothing was scanned; this is not a"; \
	     echo "  statement that the flow has no knobs."; \
	     exit 1; \
	 fi; \
	 total=0; \
	 for f in $$files; do \
	     n=$$(sed -n 's/^opt  *\([A-Za-z_][A-Za-z_0-9]*\) .*$$/\1/p' "$$f" | wc -l); \
	     total=$$((total + n)); \
	     [ "$$n" -eq 0 ] && continue; \
	     echo ""; echo "== $${f#$$dir/} =="; \
	     sed -n 's/^opt  *\([A-Za-z_][A-Za-z_0-9]*\)  *\(.*\)$$/  \1 = \2/p' "$$f"; \
	 done; \
	 echo ""; \
	 if [ "$$total" -eq 0 ]; then \
	     echo "  NO 'opt' DECLARATION IN ANY OF THE $$(echo $$files | wc -w) FLOW SCRIPT(S) READ."; \
	     echo "  Either the flow declares no knobs yet, or it declares them in a spelling"; \
	     echo "  this target does not read - and those two look identical from here."; \
	 else \
	     echo "  $$total knob(s) in $$(echo $$files | wc -w) flow script(s)."; \
	 fi
	@echo ""
	@echo "  Set one for a single build:      make synth SYNTH_DIRECTIVE=...  "
	@echo "  or permanently, in fpga/design.mk:  export SYNTH_DIRECTIVE := ..."
	@echo ""
	@echo "  A knob left at its default is at its default because the effect of"
	@echo "  moving it has not been measured ON THIS DESIGN. Turning one up starts"
	@echo "  an experiment; the comment above it in the flow script says what the"
	@echo "  experiment is, and the resolved value lands in the stage manifest so"
	@echo "  the build that produced a number can always be told from the one"
	@echo "  that did not."

# THE SEAM LIST HAS EXACTLY ONE COPY (CONTRACT §6.1) AND THIS IS NOT IT.
SEAMS_FILE := $(FPGA_ENGINE_DIR)/flow/common/seams.txt

## Where this project can attach its own code to the flow, and which of those
## seams it has taken up. The seam list is READ from flow/common/seams.txt - the
## single copy - so this target cannot disagree with the flow about what a valid
## seam is.
help-hooks:
	@# WHY THIS TARGET EXISTS AT ALL. A seam nobody can enumerate is a seam
	@# nobody uses: the reference ASIC toolkit hardcodes a five-entry override
	@# whitelist against a seven-file directory, so two real extension points are
	@# undocumented AND warn spuriously when used. The fix is not a longer
	@# hardcoded list, it is not having one - the flow reads seams.txt, the
	@# checker reads seams.txt, and so does this.
	@if [ ! -r '$(SEAMS_FILE)' ]; then \
	     echo "  $(SEAMS_FILE) is missing or unreadable."; \
	     echo "  It is the ONLY list of seams, so nothing here can be answered from"; \
	     echo "  anywhere else - this is not a flow with no extension points, it is a"; \
	     echo "  flow whose extension points could not be read."; \
	     exit 1; \
	 fi; \
	 hd='$(strip $(HOOKS_DIR))'; \
	 echo "  FLOW HOOKS - a project drops <seam>.tcl into HOOKS_DIR and the flow"; \
	 echo "  sources it at that point in the build."; \
	 echo ""; \
	 if [ -z "$$hd" ]; then \
	     echo "    HOOKS_DIR is (none): no project is included in this make run, so the"; \
	     echo "    right-hand column below says only that a seam EXISTS, not whether"; \
	     echo "    anything is attached to it."; \
	 else \
	     echo "    HOOKS_DIR = $$hd"; \
	 fi; \
	 echo ""; \
	 n=0; taken=0; \
	 while IFS= read -r seam; do \
	     case "$$seam" in ''|'#'*) continue ;; esac; \
	     n=$$((n + 1)); \
	     if [ -n "$$hd" ] && [ -f "$$hd/$$seam.tcl" ]; then \
	         taken=$$((taken + 1)); \
	         printf '    %-18s %s\n' "$$seam" "$$hd/$$seam.tcl"; \
	     elif [ -n "$$hd" ]; then \
	         printf '    %-18s -\n' "$$seam"; \
	     else \
	         printf '    %s\n' "$$seam"; \
	     fi; \
	 done < '$(SEAMS_FILE)'; \
	 echo ""; \
	 echo "    $$n seam(s) declared, $$taken with a hook in this project."; \
	 if [ -n "$$hd" ] && [ -d "$$hd" ]; then \
	     stray=""; \
	     for f in "$$hd"/*.tcl; do \
	         [ -f "$$f" ] || continue; \
	         b=$${f##*/}; b=$${b%.tcl}; \
	         if ! grep -qxF "$$b" '$(SEAMS_FILE)'; then stray="$$stray $$b.tcl"; fi; \
	     done; \
	     if [ -n "$$stray" ]; then \
	         echo ""; \
	         echo "    THESE FILES ARE IN HOOKS_DIR AND WILL NEVER RUN - the flow only"; \
	         echo "    sources a file whose name is a seam above:"; \
	         for s in $$stray; do echo "        $$s"; done; \
	         echo "    'make check' is the gate that owns this; it warns and names them."; \
	     fi; \
	 fi
	@echo ""
	@echo "  Four things are true of every hook, and the last two are why they are"
	@echo "  worth using instead of a wrapper script:"
	@echo "    optional   an absent hook is silent, not an error"
	@echo "    announced  the flow prints the path and the runtime it took"
	@echo "    fatal      an error in a hook STOPS the stage. It is not caught and"
	@echo "               downgraded to a warning. There is no advisory mode: a"
	@echo "               hook doing something genuinely optional wraps that part"
	@echo "               itself, and says in the file why it is optional."
	@echo "    recorded   the name and runtime land in hooks_run in the stage"
	@echo "               manifest, so a result traces to the project code that"
	@echo "               shaped it"
	@echo ""
	@echo "  post_bitstream RUNS AFTER THE IMAGE IS WRITTEN. A hook there can"
	@echo "  publish, record or deploy the result; it cannot change the design,"
	@echo "  because there is nothing left to change. If a hook needs to affect"
	@echo "  what is built, it belongs at pre_synth or pre_impl."
	@echo ""
	@echo "  To replace a whole flow step rather than run beside it, see"
	@echo "  OVERRIDES_DIR: a file named for a step in flow/steps/ replaces that"
	@echo "  step wholesale. 'make check' warns whenever one is active."
	@echo ""
	@echo "  These are FLOW hooks - project Tcl, run by the build. They have"
	@echo "  nothing to do with the GIT hooks in 'make hooks-install', which are"
	@echo "  repository hygiene and never run during a build."
