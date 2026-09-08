#-----------------------------------------------------------------------------
# mk/hooks.mk - install the vendor-collateral GIT hooks into this repository
#
# THESE ARE GIT HOOKS. THEY ARE NOT FLOW HOOKS, AND THE WORD MEANS TWO DIFFERENT
# THINGS IN THIS TOOLKIT:
#
#   FLOW HOOK   $(HOOKS_DIR)/<seam>.tcl, project Tcl, sourced by a build stage
#               at a named seam. See flow/common/seams.txt and `make help-hooks`.
#               Runs during a build. Affects the bitstream.
#
#   GIT HOOK    hooks/pre-commit and friends, run by GIT, that refuse to commit
#               or push vendor collateral. This file. Runs when you type a git
#               command. Affects nothing in any build, ever.
#
# The reference ASIC toolkit carries both meanings under one word and it is a
# live source of confusion - somebody looking for the extension seams finds the
# git-hook installer, concludes the flow has no seams, and writes a wrapper
# script instead. Every header in this layer says which kind it is in its first
# two lines, on purpose.
#
# Nothing here launches a tool, reads a part or board pack, or writes into a run
# directory. It edits ONE git config key.
#
# WHY A MAKE TARGET AND NOT A LINE IN A README. Because a step that has to be
# remembered is a step that is not taken on the day it matters, and because the
# hooks are useless on exactly the machines that never ran it. `make
# hooks-install` is the smallest thing that can go into a getting-started page,
# a CI bootstrap and a new-starter checklist and be the same thing in all three.
#
# WHAT IT DOES NOT DO: INSTALL ITSELF. No target in this file is a prerequisite
# of anything, and nothing in the flow invokes one. Setting core.hooksPath
# DISABLES whatever is in .git/hooks, and a build system that quietly turns off
# somebody else's guard while they were waiting on an implementation run is not
# a thing to be clever about. The installer refuses rather than clobbers; see
# scripts/fpga-flow-hooks for what it looks at before it writes.
#
# HOOKS_TARGET_REPO defaults to the repository this make run is in, which is the
# PROJECT and not the toolkit. The project is the one being published.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------

.PHONY: hooks-install hooks-uninstall hooks-status hooks-selftest

# Resolved from this file's own location when nobody supplied FPGA_FLOW_DIR, so
# `make -f mk/hooks.mk hooks-status` works in a bare clone. mk/flow.mk owns the
# hard error on an empty FPGA_FLOW_DIR (CONTRACT §2); this file does not repeat
# it. Guarded so that including both mk/help.mk and this one does not compute
# the same path twice under two names.
ifeq ($(strip $(FPGA_ENGINE_DIR)),)
  ifeq ($(strip $(FPGA_FLOW_DIR)),)
    FPGA_ENGINE_DIR := $(abspath $(dir $(abspath $(lastword $(MAKEFILE_LIST))))/..)
  else
    FPGA_ENGINE_DIR := $(abspath $(FPGA_FLOW_DIR))
  endif
endif

# An addressable artefact, assigned to a *_SCRIPT variable at the top of its
# fragment and never put on PATH (CONTRACT §10).
HOOKS_SCRIPT      := $(FPGA_ENGINE_DIR)/scripts/fpga-flow-hooks
HOOKS_TARGET_REPO ?= $(CURDIR)
HOOKS_FORCE       ?=

## Point this repository's git at the toolkit's tracked hooks/ directory, so a
## commit whose STAGED content matches a vendor-collateral rule is refused
## before it exists, and a push is re-scanned without trusting that the commit
## hook ever ran.
##
## Refuses rather than clobbers when core.hooksPath is already set, or when
## .git/hooks holds live hooks - setting core.hooksPath disables those SILENTLY,
## with no message from git and nothing in `git status`. HOOKS_FORCE=--force
## when replacing them is the intention.
hooks-install:
	@$(HOOKS_SCRIPT) install $(HOOKS_TARGET_REPO) $(HOOKS_FORCE)

## Unset core.hooksPath. The repository keeps NO commit-time or push-time
## vendor-collateral guard afterwards. CI still runs the same scanner - after
## the push, which for a public repository is a notification and not a gate.
hooks-uninstall:
	@$(HOOKS_SCRIPT) uninstall $(HOOKS_TARGET_REPO) $(HOOKS_FORCE)

## What is installed in this repository, whether each hook is executable,
## whether the scanner behind them is present, and how many bypasses have been
## recorded here.
hooks-status:
	@$(HOOKS_SCRIPT) status $(HOOKS_TARGET_REPO)

## Prove the INSTALLED hook can refuse. Plants an invented specimen in a
## THROWAWAY repository - never in yours - and requires four things: a clean
## tree to commit, the specimen to be BLOCKED, the bypass to work, and the
## bypass to leave a record. Then arms every rule in the scanner against its own
## invented specimen. Run it on any new machine before trusting the hooks: a
## check nobody has watched fail is not known to work, and a check that cannot
## fail is not a check.
hooks-selftest:
	@$(HOOKS_SCRIPT) selftest $(HOOKS_TARGET_REPO)
