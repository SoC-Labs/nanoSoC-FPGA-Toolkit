#-----------------------------------------------------------------------------
# mk/checks.mk - check, check-quiet, doctor, part-probe, board-probe
#
# The division of labour here is the whole point of the file, and it is the one
# the reference ASIC toolkit arrived at after getting it wrong twice:
#
#   MAKE RESOLVES THE VARIABLES. It is the only thing that can. A contract
#   value is the end of a `?=` chain that runs project design.mk -> engine
#   default -> command-line override, and only make has all three. A script
#   that re-derived them by parsing design.mk would be a second, wronger
#   implementation of make's own variable expansion.
#
#   THE SCRIPT DOES THE CHECKING AND THE REPORTING. One implementation of each
#   check, one place each message lives. Make is a bad language for a report
#   and a worse one for a near-miss suggestion.
#
# So: make hands over ~70 already-resolved NAME=VALUE pairs, and
# scripts/fpga-flow-check decides what they mean.
#
# WHY check-quiet EXISTS SEPARATELY: it is a prerequisite of every stage target
# (flow.mk:952 onward), so it runs before every build. On a complete contract it
# must print NOTHING - a prerequisite that prints forty lines of `ok` before
# each of six stages trains the reader to skip the output, and the one run where
# it says something different scrolls past unread.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------

CHECK_SCRIPT      := $(FPGA_FLOW_DIR)/scripts/fpga-flow-check
DOCTOR_SCRIPT     := $(FPGA_FLOW_DIR)/scripts/fpga-flow-doctor
PART_PROBE_SCRIPT := $(FPGA_FLOW_DIR)/scripts/fpga-flow-part-probe

#-----------------------------------------------------------------------------
# INTERFACE TO fpga-flow-check
#
#   $(CHECK_SCRIPT) [--quiet] --var NAME=VALUE ...
#
# NAME is the CANONICAL contract name from CONTRACT.md §3 - `TOP`, `RTL_FLIST`,
# `XDC_PINS` - never the FPGA_-prefixed spelling flow.mk exports to the Tcl
# layer, and never an alias. An empty VALUE is legal and means "not configured";
# that is how an optional gets reported as `--` rather than being confused with
# one make forgot to pass.
#
# WHY --var AND NOT --vars-file, WHICH THE SCRIPT ALSO ACCEPTS: a vars file has
# to be written somewhere before the script runs, and `$(file >...)` is expanded
# when make expands the RECIPE - that is, before the recipe's own `mkdir -p` has
# run - so the target directory would have to be created at PARSE time. That
# would mean a bare `make help` silently creating build/. The measured reason to
# have used a file at all was ARG_MAX; the actual figure here is ~70 pairs at
# well under 100 bytes each, so ~7 kB against a 2 MB limit. There is no problem
# to solve, and a temp file with a lifecycle is a worse answer than a long
# command line. `--vars-file` stays available for a caller that needs it.
#
# KNOWN LIMIT: each pair is single-quoted for the shell, so a contract value
# containing a literal single quote would break the quoting. No path, module
# name, parameter or define in this contract can legitimately contain one, and
# `make check` reporting a shell error is a loud failure rather than a silent
# mis-parse - but it is a limit, so it is written down.
#-----------------------------------------------------------------------------

# Every canonical name in CONTRACT.md §3, in the order §3 introduces them. This
# list is what make PASSES; scripts/fpga-flow-check's own KNOWN_VARS is what it
# RECOGNISES. They are deliberately two lists in two files: passing a name the
# script does not know is reported rather than rejected, so a drift between them
# shows up as a line in the report instead of as silence on the check that
# stopped running. test/shell/t_contract.sh asserts they agree.
CHECK_VAR_NAMES := \
	FPGA_FLOW_DIR FPGA_DIR BLOCK BOARD \
	TOP RTL_FLIST XDC_PINS PART \
	DESIGN_NAME PROJECT_ROOT \
	BOARD_DIR TARGET TARGET_DIR PART_DIR BOARD_PART \
	BOARD_REPO_PATHS FLOW_MODE PLATFORM SYS_CLK_FREQ_HZ \
	RTL_FLIST_GEN RTL_INCDIRS RTL_DEFINES RTL_DEFINES_INBODY \
	RTL_DEFINES_NEVER RTL_PARAMS TOP_HDL EXTRA_SRCS SV_FILES \
	IP_REPOS IP_VENDOR IP_CORE_REV IP_CACHE_DIR PACKAGE_TCL \
	BD_TCL BD_OVERLAY_TCL BD_GLOBAL_SYNTH \
	XDC_TIMING XDC_DRC XDC_EXTRA XDC_OPTIONAL XDC_POST_ROUTE \
	FW_APP FW_HEX FW_HEX_FORMAT FPGA_IMAGE_HEX \
	HOOKS_DIR OVERRIDES_DIR \
	BUILD_DIR RUN_TAG IN_RUN_TAG SYNTH_RUN_TAG \
	VIVADO VIVADO_VER NUM_JOBS TCLSH \
	EXPECT_WNS_MIN EXPECT_WHS_MIN EXPECT_LUT_MAX EXPECT_FF_MAX \
	EXPECT_BRAM_MAX EXPECT_DSP_MAX EXPECT_UNROUTED_MAX \
	EXPECT_BLACKBOX_MAX ALLOW_CRITICAL_WARNINGS XDC_BASELINE \
	MSG_GATE_ALLOWLIST \
	FPGAHUB_BOARD FPGAHUB_TARGET FPGAHUB_TOML BIN_STYLE \
	RUN_DIR WORK_DIR LOG_DIR REPORT_DIR OUT_DIR IN_WORK_DIR SYNTH_OUT_DIR

# The derived seven are passed too, deliberately: the script warns when a
# project ASSIGNED one, and it can only see that by comparing what arrived
# against what the engine would have computed. See CONTRACT.md §3.5 - the
# reference toolkit's own shipped example sets four of them and they are
# silently discarded.

CHECK_ARGS = $(foreach v,$(CHECK_VAR_NAMES),--var '$(v)=$($(v))')

#-----------------------------------------------------------------------------
# Targets
#-----------------------------------------------------------------------------

## check: validate the design contract. No licence, no tool, under a second.
##   Run this first, and run it whenever a build fails for a reason you do not
##   recognise. It reads file CONTENT, not just existence: a scaffolded project
##   carries <<FILL IN>> markers that an `ls` cannot distinguish from a finished
##   one.
.PHONY: check
check:
	@$(CHECK_SCRIPT) $(CHECK_ARGS)

## check-quiet: check, silent on success. Prerequisite of every stage.
##   Not a target you need to type. It is why a stage refuses to start against
##   an incomplete contract instead of failing forty minutes in.
.PHONY: check-quiet
check-quiet:
	@$(CHECK_SCRIPT) --quiet $(CHECK_ARGS)

## doctor: can THIS MACHINE run the flow? No project, no licence, no tool run.
##   Reports what is installed on the filesystem - which is not always what a
##   modulefile advertises. Run it on any new host before trusting a result.
.PHONY: doctor
doctor:
	@$(DOCTOR_SCRIPT)

## part-probe: can this host READ the part pack this design selects?
##   check and doctor CANNOT answer this: neither loads the pack, so both go
##   green on a host where no stage can start. Ask the pack, never the
##   filesystem - an empty autofs mount point passes every `test -d`.
.PHONY: part-probe
part-probe:
	@$(PART_PROBE_SCRIPT) --role part $(PART_DIR)

## board-probe: the same question for the project's board pack.
##   A board pack is project-side by design (CONTRACT.md §1), so this is the
##   only probe that can fail because of something the project owns.
.PHONY: board-probe
board-probe:
	@$(PART_PROBE_SCRIPT) --role board $(BOARD_DIR)

#-----------------------------------------------------------------------------
# A missing script is a BROKEN CHECKOUT, and says so
#
# Same reasoning as flow.mk's hard includes. Without this, a toolkit checkout
# with no scripts/ produces `/bin/sh: .../fpga-flow-check: No such file or
# directory` and exit 127, which reads as a PATH problem in the project. It is
# not: it is an incomplete clone, and one line can say so.
#-----------------------------------------------------------------------------
check check-quiet: | check-script-present
doctor: | doctor-script-present
part-probe board-probe: | part-probe-script-present

.PHONY: check-script-present doctor-script-present part-probe-script-present
check-script-present:
	@test -x $(CHECK_SCRIPT) || { \
	  echo "fpga-flow: $(CHECK_SCRIPT) is missing or not executable." >&2; \
	  echo "           The toolkit checkout at $(FPGA_FLOW_DIR) is incomplete;" >&2; \
	  echo "           this is not a problem with your design." >&2; \
	  echo "           Try: git -C $(FPGA_FLOW_DIR) status" >&2; exit 2; }
doctor-script-present:
	@test -x $(DOCTOR_SCRIPT) || { \
	  echo "fpga-flow: $(DOCTOR_SCRIPT) is missing or not executable." >&2; \
	  echo "           The toolkit checkout at $(FPGA_FLOW_DIR) is incomplete." >&2; \
	  exit 2; }
part-probe-script-present:
	@test -x $(PART_PROBE_SCRIPT) || { \
	  echo "fpga-flow: $(PART_PROBE_SCRIPT) is missing or not executable." >&2; \
	  echo "           The toolkit checkout at $(FPGA_FLOW_DIR) is incomplete." >&2; \
	  exit 2; }

## check-vars: what `make check` would hand the checker, without checking.
##   The debugging target for "the checker says X is empty and my design.mk
##   plainly sets it" - it shows the value AFTER every ?= chain and override
##   has resolved, which is the value that actually matters.
.PHONY: check-vars
check-vars:
	@printf '%-24s %s\n' 'VARIABLE' 'RESOLVED VALUE'
	@printf '%-24s %s\n' '------------------------' '--------------'
	@$(foreach v,$(CHECK_VAR_NAMES),printf '%-24s %s\n' '$(v)' '$($(v))';)
