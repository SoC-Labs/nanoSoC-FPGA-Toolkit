#-----------------------------------------------------------------------------
# mk/deploy.mk - take a finished bitstream to a real board, and back again
#
# The post-stage tier. Everything above this file builds a file; this is the
# only part of the toolkit that touches a physical object somebody else can be
# using, and every design decision in it follows from that one fact.
#
# THE SHAPE:  preflight -> lease -> program -> verify -> test -> collect -> release
#
# It is wired into BITSTREAM_POST_TARGETS (CONTRACT.md section 4), DEFAULT OFF,
# because a toolkit that reaches for hardware the first time somebody types
# `make bitstream` is a toolkit that interrupts a colleague's measurement on the
# day they install it.
#
#-----------------------------------------------------------------------------
# THE FIVE THINGS THAT SHAPE THIS TIER
#
# All five were measured against the live fpgahub daemon. Each one is a defect
# that produces a WRONG-LOOKING SYMPTOM rather than an error, which is why each
# one is written down here rather than left to be rediscovered.
#
#   1. THE BOARD GROUP AND THE TARGET ARE DIFFERENT NAMESPACES, and they do not
#      overlap. Leases, queues and reservations address the board GROUP
#      (FPGAHUB_BOARD); program, reset, debug and actions address a TARGET
#      (FPGAHUB_TARGET). Asking for actions on a group returns 404. A 404 reads
#      as "the board is down" or as a route-skew bug in the hub, and it is
#      neither - so BOTH identifiers are required, separately, and the
#      preflight refuses a run that has only one of them.
#
#   2. `lease acquire --pid $$` IS SILENTLY INERT FROM THIS HOST. The daemon's
#      dead-PID reaper skips any lease whose holder host is not the daemon's
#      own, and the client defaults the holder to the CLIENT's hostname. So the
#      one flag that exists for "a make step frees the board when its process
#      dies" is accepted, stored, and never acted on. The working discipline is
#      a DISTINCTIVE holder, a SHORT TTL, a HEARTBEAT, and a trap - and it lives
#      in scripts/fpga-flow-deploy, not here, because make cannot hold a trap
#      across a recipe line.
#
#   3. PROGRAM AND ACTION DISPATCH ARE NOT LEASE-GATED. Neither handler checks
#      holdership. The lease is ADVISORY and THIS TOOLKIT IS THE ENFORCER: the
#      driver refuses to program a board it does not hold. That check exists
#      nowhere else, so removing it does not produce an error - it produces two
#      people programming one board and two sets of results that disagree.
#
#   4. ACTION DISPATCH IS SYNCHRONOUS BEHIND A 202. The run id only comes back
#      when the action has already finished, so in-flight visibility needs the
#      event stream subscribed BEFORE the POST. The stock client's timeout is
#      30 s with no override; whether that actually breaks a long action is
#      UNMEASURED. The driver calls REST directly with its own timeout for that
#      reason. See docs/DEPLOY.md - this needs measuring on the rig.
#
#   5. BITSTREAMS ARE SERVER-SIDE ABSOLUTE PATHS. There is no upload endpoint.
#      Cross-host CI needs a shared mount or an scp staging step, and STAGING IS
#      THIS TOOLKIT'S JOB, not the operator's - a path that happens to resolve
#      on the developer's workstation and not on the runner is the failure this
#      tier is most likely to hit and least likely to explain itself for.
#
#-----------------------------------------------------------------------------
# NON-FATAL TO THE BUILD, FATAL TO THE CLAIM (CONTRACT.md section 4)
#
# A ninety-minute implementation must not be destroyed because a board was
# leased by somebody else. mk/flow.mk's post_stage_targets already turns a
# failed post-stage target into a loud warning and keeps the build - so this
# file does NOT swallow its own failures on top of that. `make deploy` typed by
# hand, and ci/tier.sh's t_deploy, both get a non-zero status, which is what
# they are for. Double-swallowing would make the CI tier structurally unable to
# go red, and a deploy tier that cannot fail is not a deploy tier.
#
# What this file DOES owe the rule is the other half of it: the run must not be
# CALLED deployed. So the failure path prints a banner naming the claim that has
# not been earned, and the deploy gate artefact records it. A build whose
# bitstream never reached a board is not a bad build; it is a build that has not
# been tested, and those are different sentences.
#
#-----------------------------------------------------------------------------
# WHY DEPLOY_EXECUTE DEFAULTS TO 0 AS WELL AS DEPLOY_AFTER_BITSTREAM
#
# Two switches for what looks like one decision, and they are genuinely two:
#
#   DEPLOY_AFTER_BITSTREAM   does the BUILD reach for hardware unattended?
#   DEPLOY_EXECUTE           does an INVOCATION mutate a board, or describe
#                            what it would mutate?
#
# The second is the dry-run default CONTRACT.md section 10 asks of every
# destructive path, and it is not redundant with the first: the interesting
# failure is somebody running `make deploy` by hand on the wrong host, with a
# board group inherited from a shell they opened yesterday. With
# DEPLOY_EXECUTE=0 that prints a plan naming the board it would have taken, and
# the person reads the name and stops. With a single switch it takes it.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------

# Resolved from this file's own location when nobody supplied FPGA_FLOW_DIR, so
# `make -f mk/deploy.mk deploy-vars` works in a bare clone with no project - the
# same idiom, for the same reason, as mk/help.mk and mk/hooks.mk. mk/flow.mk
# owns the hard error on an empty FPGA_FLOW_DIR (CONTRACT section 2); this file
# does not repeat it. Guarded so that including two of the three fragments does
# not compute the same path twice under two names.
ifeq ($(strip $(FPGA_ENGINE_DIR)),)
  ifeq ($(strip $(FPGA_FLOW_DIR)),)
    FPGA_ENGINE_DIR := $(abspath $(dir $(abspath $(lastword $(MAKEFILE_LIST))))/..)
  else
    FPGA_ENGINE_DIR := $(abspath $(FPGA_FLOW_DIR))
  endif
endif

# Addressable artefacts assigned to *_SCRIPT variables, never put on PATH
# (CONTRACT.md section 10).
DEPLOY_SCRIPT := $(FPGA_ENGINE_DIR)/scripts/fpga-flow-deploy
DEPLOY_GATES  := $(FPGA_ENGINE_DIR)/ci/deploy-gates.sh

#-----------------------------------------------------------------------------
# THE DEPLOY KNOBS
#
# FPGAHUB_BOARD, FPGAHUB_TARGET, FPGAHUB_TOML and BIN_STYLE are declared by
# mk/flow.mk (CONTRACT.md section 3.3) and are NOT redeclared here - a `?=` in
# two files is a value that changes meaning with include order. The ones below
# are this tier's own, and every one of them is `?=` so a project wins.
#
# Where a default names a CONVENTIONAL PATH it DISCOVERS with $(wildcard)
# rather than asserting (CONTRACT.md section 3.3, the 2026-09-08 corollary): a
# bare `?= <path>` is indistinguishable, by the time `make check` sees it, from
# the project having named that file, so the engine's convenience default
# becomes a required input.
#-----------------------------------------------------------------------------

## Does `make bitstream` reach for a board when it finishes? 0 = no.
DEPLOY_AFTER_BITSTREAM ?= 0

## Does an invocation MUTATE a board, or describe what it would mutate?
## 0 = --dry-run. This is the arming switch, and it is deliberately separate.
DEPLOY_EXECUTE ?= 0

# WHAT GETS PROGRAMMED. Discovered, not asserted: a project that has not built a
# bitstream yet must still be able to run `make check` and `make deploy-vars`.
DEPLOY_BITSTREAM ?= $(wildcard $(OUT_DIR)/$(BLOCK).bit)

# THE TEST. The name of an fpgahub action to dispatch against FPGAHUB_TARGET
# once the board is programmed. Empty means "programmed and verified, nothing
# run on it" - which is a legitimate deploy and is reported as such, NOT as a
# pass with no test. A tier that silently tests nothing is how a green run comes
# to prove nothing (CONTRACT.md section 7).
DEPLOY_ACTION ?=

# Our own timeout on the dispatch, in seconds. See shaping fact 4: the stock
# client's 30 s is not overridable and its effect on a long action is
# UNMEASURED, so the driver calls REST itself and this is the number it uses.
DEPLOY_ACTION_TIMEOUT_S ?= 900

# THE LEASE. Short TTL plus heartbeat is the ONLY working discipline here (fact
# 2): the reaper cannot free a lease held from this host, so the TTL is the sole
# thing standing between a crashed run and a board nobody can book. 600 s means
# a dead run blocks the board for at most ten minutes. Raise it only with a
# heartbeat you have watched work.
FPGAHUB_LEASE_TTL_S ?= 600

# How long to wait for a busy board, in seconds. 0 = do not queue, fail fast
# with EX_TEMPFAIL. Fast failure is the right default for a post-stage target:
# a build that has finished should not sit on a runner for three hours holding
# a queue slot it did not tell anybody about.
FPGAHUB_LEASE_WAIT_S ?= 0

# The hub. Empty means "whatever the client resolves from its own config" -
# fpgahub.toml, its environment, its default. Set it to pin one.
FPGAHUB_URL ?=

# STAGING (fact 5). The daemon opens the bitstream BY ABSOLUTE PATH ON ITS OWN
# FILESYSTEM; there is no upload. `auto` resolves to `local` when the hub is on
# this host and refuses otherwise, naming the two ways out.
#   auto    decide from where the hub is
#   local   the daemon is on this host; OUT_DIR is already its filesystem
#   shared  a mount both hosts see. FPGAHUB_STAGE_DIR is the path ON THE DAEMON
#   scp     copy there first. FPGAHUB_STAGE_HOST:FPGAHUB_STAGE_DIR
FPGAHUB_STAGE_MODE ?= auto
FPGAHUB_STAGE_DIR  ?=
FPGAHUB_STAGE_HOST ?=

# WHERE THE EVIDENCE LANDS. CONTRACT.md section 5 says a run directory holds
# EXACTLY FOUR directories - work logs reports outputs - and that anything else
# in it belongs to the project. So this tier creates no fifth directory: its
# manifest and verdict are reports, its logs are logs, and what it collects off
# the board goes in a SUBDIRECTORY OF outputs, which the rule permits and which
# keeps a board's artefacts from being mistaken for the build's.
#
# EACH ONE IS GUARDED ON ITS PARENT BEING SET, and that guard is not
# defensiveness about a case that cannot happen. mk/flow.mk derives REPORT_DIR
# from BUILD_DIR and RUN_TAG (CONTRACT.md section 3.5); read STANDALONE - `make
# -f mk/deploy.mk deploy-vars` in a bare clone, which is a thing people do -
# every one of those is empty, and a bare `$(REPORT_DIR)/deploy_gate.txt`
# collapses to the absolute path `/deploy_gate.txt`. That is a path in the root
# filesystem, printed by a target whose whole promise is that it is safe, and
# offered to a reader as where their evidence will land. An unset parent means
# there is NO path, and the empty value renders as `(none)`.
DEPLOY_MANIFEST := $(if $(strip $(REPORT_DIR)),$(REPORT_DIR)/deploy_manifest.txt)
DEPLOY_GATE     := $(if $(strip $(REPORT_DIR)),$(REPORT_DIR)/deploy_gate.txt)
DEPLOY_LOG      := $(if $(strip $(LOG_DIR)),$(LOG_DIR)/deploy.log)
DEPLOY_SSE_LOG  := $(if $(strip $(LOG_DIR)),$(LOG_DIR)/deploy_sse.jsonl)
DEPLOY_OUT_DIR  := $(if $(strip $(OUT_DIR)),$(OUT_DIR)/deploy)
DEPLOY_LEASE    := $(if $(strip $(WORK_DIR)),$(WORK_DIR)/deploy_lease.env)

#-----------------------------------------------------------------------------
# THE ARGUMENT VECTOR, BUILT ONCE
#
# Make resolves the variables; the script does the work. Exactly the division of
# labour mk/checks.mk settled on, and for the same reason: a contract value is
# the end of a `?=` chain running project -> engine -> command line, and only
# make has all three. A driver that re-derived them by reading design.mk would
# be a second, wronger implementation of make's own expansion.
#
# Values are single-quoted for the shell. KNOWN LIMIT, the same one mk/checks.mk
# carries: a value containing a literal single quote breaks the quoting. No
# board name, target name, action name or path in this contract can legitimately
# contain one, and a shell syntax error is a loud failure rather than a silent
# mis-parse - but it is a limit, so it is written down.
#-----------------------------------------------------------------------------

# The dry-run flag is chosen HERE, in make, so that every call site and
# `deploy-vars` agree by construction rather than by each remembering.
DEPLOY_ARM := $(if $(filter 1 yes true,$(DEPLOY_EXECUTE)),--execute,--dry-run)

# THE LOG THE BANNER POINTS AT MUST EXIST.
#
# The failure message names a log file, and a message that sends somebody to a
# path with nothing at it is worse than one that names no path at all - they go
# looking, find nothing, and conclude the run never happened.
#
# TEED HERE IN make RATHER THAN INSIDE THE DRIVER, deliberately. The obvious
# alternative is `exec > >(tee ...)` in the script, and it is the wrong one: a
# process substitution makes tee a child holding the shell's stdout, and this
# driver exits from SIGNAL HANDLERS - so the shell can be gone before tee has
# flushed, and the last lines written are exactly the ones about releasing the
# board. A pipeline is waited for by make, so nothing is lost.
#
# `set -o pipefail` is what keeps the driver's exit status rather than tee's,
# which is always 0. Without it every deploy would look successful.
ifeq ($(strip $(LOG_DIR)),)
  DEPLOY_TEE :=
else
  DEPLOY_TEE := 2>&1 | tee -a $(DEPLOY_LOG)
endif

DEPLOY_ARGS = \
	--board '$(FPGAHUB_BOARD)' \
	--target '$(FPGAHUB_TARGET)' \
	--toml '$(FPGAHUB_TOML)' \
	--url '$(FPGAHUB_URL)' \
	--bitstream '$(DEPLOY_BITSTREAM)' \
	--bin-style '$(BIN_STYLE)' \
	--action '$(DEPLOY_ACTION)' \
	--action-timeout '$(DEPLOY_ACTION_TIMEOUT_S)' \
	--ttl '$(FPGAHUB_LEASE_TTL_S)' \
	--wait '$(FPGAHUB_LEASE_WAIT_S)' \
	--stage-mode '$(FPGAHUB_STAGE_MODE)' \
	--stage-dir '$(FPGAHUB_STAGE_DIR)' \
	--stage-host '$(FPGAHUB_STAGE_HOST)' \
	--block '$(BLOCK)' \
	--run-tag '$(RUN_TAG)' \
	--report-dir '$(REPORT_DIR)' \
	--log-dir '$(LOG_DIR)' \
	--out-dir '$(DEPLOY_OUT_DIR)' \
	--work-dir '$(WORK_DIR)' \
	--lease-file '$(DEPLOY_LEASE)' \
	$(DEPLOY_ARM)

# THE SAME VECTOR, SAFE TO PRINT INSIDE A SINGLE-QUOTED printf ARGUMENT.
#
# DEPLOY_ARGS carries its own single quotes, so `printf '%s' '$(DEPLOY_ARGS)'`
# lets every one of them CLOSE the printf argument and reopen it - the shell
# concatenates the pieces, the quotes vanish from the output, and deploy-vars
# then advertises a command line that is not the one make runs. A value with a
# space in it (a staging directory, an action name) would be displayed as two
# arguments. So the display copy escapes each quote in the POSIX way, `'\''`,
# and is DERIVED from DEPLOY_ARGS rather than written out a second time: two
# hand-maintained copies of an argument vector drift, and the one that drifts is
# always the one people read instead of the one that runs.
DEPLOY_SQUOTE  := '
DEPLOY_SQ_ESC  := '\''
DEPLOY_ARGS_SHOW = $(subst $(DEPLOY_SQUOTE),$(DEPLOY_SQ_ESC),$(DEPLOY_ARGS))

#-----------------------------------------------------------------------------
# WIRING INTO THE BITSTREAM STAGE
#
# `+=`, not `=`, so a project that already names its own post-bitstream target
# keeps it. Guarded on DEPLOY_AFTER_BITSTREAM, default 0.
#
# AND THE EXPORT IS REDONE, which is not decoration. mk/flow.mk assigns
# `export FPGA_BITSTREAM_POST_TARGETS := $(BITSTREAM_POST_TARGETS)` with `:=`,
# at parse time, in its section 7 - which runs BEFORE the fpga_flow_optional
# calls that read this file. The append below therefore reaches the RECIPE
# (post_stage_targets expands when the recipe runs) but NOT the exported copy
# that scripts and manifests read. The two would disagree, and the symptom would
# be a deploy that ran while every record of the run said no deploy was
# configured. One line closes it; see docs/DEPLOY.md, which raises the ordering
# as a contract question rather than leaving it patched here.
ifeq ($(strip $(DEPLOY_AFTER_BITSTREAM)),1)
  BITSTREAM_POST_TARGETS += deploy
  export FPGA_BITSTREAM_POST_TARGETS := $(BITSTREAM_POST_TARGETS)
endif

#-----------------------------------------------------------------------------
# TARGETS
#-----------------------------------------------------------------------------

.PHONY: deploy deploy-program deploy-test deploy-collect deploy-release \
        deploy-status deploy-vars deploy-selftest deploy-script-present

# THE RUN DIRECTORIES, AND WHY THIS TIER DOES NOT DEPEND ON `dirs`.
#
# It writes a manifest and a verdict into reports/ and a log into logs/ - two of
# the four directories CONTRACT.md section 5 permits, so creating them breaks no
# rule; the rule is about WHICH directories exist in a run, not about which
# target makes them.
#
# DEPENDING ON `dirs` WAS TRIED AND IS WRONG. `dirs` has `check-quiet` as a
# prerequisite, like every stage target, so a deploy would then require a
# COMPLETE BUILD CONTRACT - TOP, RTL_FLIST, XDC_PINS - to put an already-built
# bitstream on a board. On the host this tier is most useful, a runner that
# fetched a .bit as an artefact and never built anything, none of those three is
# set and none of them is needed. A deploy would be refused for the absence of
# inputs it does not read.
#
# So the directories are made here, immediately before they are written, and
# nothing else about a run is assumed to exist.
DEPLOY_MKDIRS = @mkdir -p $(if $(strip $(REPORT_DIR)),$(REPORT_DIR)) \
                         $(if $(strip $(LOG_DIR)),$(LOG_DIR)) 2>/dev/null || true

## deploy: bitstream -> board -> result, under ONE lease, released on the way out.
##   preflight, lease, program, verify, run the action, collect, release. The
##   whole sequence holds a single lease so the board cannot change underneath
##   the test, and the lease is released by a trap armed before any of it - a
##   crash, a Ctrl-C and a kill all free the board.
##
##   Reads DEPLOY_EXECUTE. At 0 (the default) it prints the plan and touches
##   nothing. Nothing here is fatal to the BUILD - mk/flow.mk's post-stage
##   wrapper sees to that - but a failure means the run is NOT deployed, and it
##   says so in those words.
deploy: | deploy-script-present
	$(DEPLOY_MKDIRS)
	@set -o pipefail; $(DEPLOY_SCRIPT) run $(DEPLOY_ARGS) $(DEPLOY_TEE) || { \
	  echo ""; \
	  echo "NOT DEPLOYED: '$(call fpga_or_none,$(BLOCK))' run '$(call fpga_or_none,$(RUN_TAG))' did not reach a board."; \
	  echo "  The BUILD is intact and the bitstream is unchanged. What is NOT true"; \
	  echo "  is any claim that this image has run on hardware."; \
	  echo "  Tell these apart before debugging the design - they land on one exit:"; \
	  echo "    a board leased by somebody else   (retry; nothing is wrong)"; \
	  echo "    no lease, so we refused to program (the hub does NOT enforce it; we do)"; \
	  echo "    a target with no program method    (KR260 today - see docs/DEPLOY.md)"; \
	  echo "    a bitstream the daemon cannot open (staging: FPGAHUB_STAGE_MODE)"; \
	  echo "    a design that programmed and failed its action  (the only one that"; \
	  echo "                                                     is about the design)"; \
	  echo "  Verdicts: $(DEPLOY_GATE)"; \
	  echo "  Log:      $(DEPLOY_LOG)"; \
	  exit 1; }

## deploy-program: take the lease, program the board, verify DONE, release.
##   Runs no action. Use it to put an image on a board and leave it there for
##   somebody to poke at by hand - the lease is still released on the way out,
##   so the board is bookable while the image stays loaded.
deploy-program: | deploy-script-present
	$(DEPLOY_MKDIRS)
	@set -o pipefail; $(DEPLOY_SCRIPT) program $(DEPLOY_ARGS) $(DEPLOY_TEE)

## deploy-test: dispatch DEPLOY_ACTION against the target and grade the result.
##   Takes its own lease when it is not already inside one. Subscribes to the
##   event stream BEFORE the POST, because dispatch is synchronous behind a 202
##   and the run id arrives only once the action has finished.
deploy-test: | deploy-script-present
	$(DEPLOY_MKDIRS)
	@set -o pipefail; $(DEPLOY_SCRIPT) test $(DEPLOY_ARGS) $(DEPLOY_TEE)

## deploy-collect: pull this run's board artefacts into outputs/deploy/.
##   Read-only, needs no lease, and is safe to re-run. Separate from the test so
##   that a run whose action FAILED still has its evidence collected - the
##   failing run is the one whose logs are worth having.
deploy-collect: | deploy-script-present
	$(DEPLOY_MKDIRS)
	@set -o pipefail; $(DEPLOY_SCRIPT) collect $(DEPLOY_ARGS) $(DEPLOY_TEE)

## deploy-release: release the lease this run recorded, and only that one.
##   The recovery path for a run that was killed between acquiring and its trap
##   firing. Token-scoped, so it cannot touch a colleague's lease.
##
##   IT WILL NEVER REVOKE. A revoke on a shared account is indistinguishable
##   from taking a board off somebody who is using it - every lease on this hub
##   carries the same `user`, so there is nothing to tell them apart by. If the
##   board is stuck, wait for the TTL or go and ask.
deploy-release: | deploy-script-present
	@$(DEPLOY_SCRIPT) release $(DEPLOY_ARGS)

## deploy-status: what the hub says about this board group and this target, now.
##   Read-only in every mode, including DEPLOY_EXECUTE=1. Prints the group, the
##   target, who holds the lease and when it expires. Type this first when a
##   deploy has just failed.
deploy-status: | deploy-script-present
	@$(DEPLOY_SCRIPT) status $(DEPLOY_ARGS)

## deploy-vars: what deploy WOULD do, without doing any of it.
##   CONTRACT.md section 10 requires one of these per gate. It launches nothing,
##   contacts no hub, creates no directory and reads no board.
##
##   NOT ONE COMMAND SUBSTITUTION APPEARS BELOW, and that is a rule rather than
##   a style: in the reference toolkit a backtick inside a double-quoted shell
##   word ran the entire evidence flow from the target whose only job was to
##   report what would happen. Every line here is a printf of a value make has
##   already resolved. If you find yourself wanting `$$(...)` in this recipe,
##   the thing you want belongs in `deploy-status`.
deploy-vars:
	@printf '%s\n' 'deploy - what this invocation WOULD do. Nothing below was run.'
	@printf '\n'
	@printf '  ARMING\n'
	@printf '    %-26s %s\n' 'DEPLOY_EXECUTE'         '$(call fpga_or_none,$(DEPLOY_EXECUTE))'
	@printf '    %-26s %s\n' 'mode'                   '$(DEPLOY_ARM)'
	@printf '    %-26s %s\n' 'DEPLOY_AFTER_BITSTREAM' '$(call fpga_or_none,$(DEPLOY_AFTER_BITSTREAM))'
	@printf '    %-26s %s\n' 'BITSTREAM_POST_TARGETS' '$(call fpga_or_none,$(BITSTREAM_POST_TARGETS))'
	@printf '\n'
	@printf '  THE TWO NAMESPACES - they are not interchangeable\n'
	@printf '    %-26s %s\n' 'FPGAHUB_BOARD  (lease)'  '$(call fpga_or_none,$(FPGAHUB_BOARD))'
	@printf '    %-26s %s\n' 'FPGAHUB_TARGET (program)' '$(call fpga_or_none,$(FPGAHUB_TARGET))'
	@printf '    %-26s %s\n' 'FPGAHUB_TOML'           '$(call fpga_or_none,$(FPGAHUB_TOML))'
	@printf '    %-26s %s\n' 'FPGAHUB_URL'            '$(call fpga_or_none,$(FPGAHUB_URL))'
	@printf '\n'
	@printf '  THE IMAGE\n'
	@printf '    %-26s %s\n' 'DEPLOY_BITSTREAM'       '$(call fpga_or_none,$(DEPLOY_BITSTREAM))'
	@printf '    %-26s %s\n' 'BIN_STYLE'              '$(call fpga_or_none,$(BIN_STYLE))'
	@printf '    %-26s %s\n' 'FPGAHUB_STAGE_MODE'     '$(call fpga_or_none,$(FPGAHUB_STAGE_MODE))'
	@printf '    %-26s %s\n' 'FPGAHUB_STAGE_HOST'     '$(call fpga_or_none,$(FPGAHUB_STAGE_HOST))'
	@printf '    %-26s %s\n' 'FPGAHUB_STAGE_DIR'      '$(call fpga_or_none,$(FPGAHUB_STAGE_DIR))'
	@printf '\n'
	@printf '  THE LEASE - short TTL and a heartbeat are the ONLY working discipline\n'
	@printf '    %-26s %s\n' 'FPGAHUB_LEASE_TTL_S'    '$(call fpga_or_none,$(FPGAHUB_LEASE_TTL_S))'
	@printf '    %-26s %s\n' 'FPGAHUB_LEASE_WAIT_S'   '$(call fpga_or_none,$(FPGAHUB_LEASE_WAIT_S))'
	@printf '    %-26s %s\n' 'lease state file'       '$(call fpga_or_none,$(DEPLOY_LEASE))'
	@printf '\n'
	@printf '  THE TEST\n'
	@printf '    %-26s %s\n' 'DEPLOY_ACTION'          '$(call fpga_or_none,$(DEPLOY_ACTION))'
	@printf '    %-26s %s\n' 'DEPLOY_ACTION_TIMEOUT_S' '$(call fpga_or_none,$(DEPLOY_ACTION_TIMEOUT_S))'
	@printf '\n'
	@printf '  WHERE THE EVIDENCE LANDS - no fifth run directory (CONTRACT 5)\n'
	@printf '    %-26s %s\n' 'manifest'               '$(call fpga_or_none,$(DEPLOY_MANIFEST))'
	@printf '    %-26s %s\n' 'verdict'                '$(call fpga_or_none,$(DEPLOY_GATE))'
	@printf '    %-26s %s\n' 'log'                    '$(call fpga_or_none,$(DEPLOY_LOG))'
	@printf '    %-26s %s\n' 'event stream'           '$(call fpga_or_none,$(DEPLOY_SSE_LOG))'
	@printf '    %-26s %s\n' 'collected artefacts'    '$(call fpga_or_none,$(DEPLOY_OUT_DIR))'
	@printf '\n'
	@printf '  THE COMMAND make deploy WOULD RUN - copy-pasteable, and not run here\n'
	@printf '    %s\n' '$(DEPLOY_SCRIPT) run $(DEPLOY_ARGS_SHOW)'
	@printf '\n'
	@printf '  %s\n' 'Read-only next steps: make deploy-status  /  $(DEPLOY_SCRIPT) preflight ...'

## deploy-selftest: prove the deploy gates can go RED.
##   Plants each fault in a throwaway fixture and requires the matching gate to
##   fail: a missing bitstream, a target we do not hold, a device with no DONE
##   property, a group used where a target was needed. A check nobody has
##   watched fail is not known to work (CONTRACT.md section 7).
##
##   Touches no board and needs no hub: it runs the gates against recorded
##   responses. That is also its limit, and ci/deploy-gates.sh says so - it
##   proves the gate reads a fixture correctly, not that the fixture matches
##   what the daemon really sends.
deploy-selftest: | deploy-script-present
	@$(DEPLOY_GATES) --selftest

#-----------------------------------------------------------------------------
# A missing script is a BROKEN CHECKOUT, and says so
#
# Same reasoning as mk/checks.mk. Without this, a toolkit checkout with no
# scripts/ produces `/bin/sh: .../fpga-flow-deploy: No such file or directory`
# and exit 127 - which reads as a PATH problem in the project, or worse, as the
# hub being unreachable. It is neither: it is an incomplete clone, and one line
# can say so before anybody starts looking at a board.
#-----------------------------------------------------------------------------
deploy-script-present:
	@test -x $(DEPLOY_SCRIPT) || { \
	  echo "fpga-flow: $(DEPLOY_SCRIPT) is missing or not executable." >&2; \
	  echo "           The toolkit checkout at $(FPGA_ENGINE_DIR) is incomplete;" >&2; \
	  echo "           this is not a problem with your design, your board or the hub." >&2; \
	  echo "           Try: git -C $(FPGA_ENGINE_DIR) status" >&2; exit 2; }
	@test -x $(DEPLOY_GATES) || { \
	  echo "fpga-flow: $(DEPLOY_GATES) is missing or not executable." >&2; \
	  echo "           The deploy tier would run and record no verdict, which is" >&2; \
	  echo "           worse than not running: it would look like a clean deploy." >&2; \
	  exit 2; }

# fpga_or_none is defined by mk/flow.mk. Defined here too, IDENTICALLY and only
# when absent, so `make -f mk/deploy.mk deploy-vars` in a bare clone renders
# `(none)` rather than a blank - a blank after a label reads as "this is fine,
# it just did not fit", which is the one thing it never means here.
ifeq ($(origin fpga_or_none),undefined)
fpga_or_none = $(if $(strip $(1)),$(strip $(1)),(none))
endif

# Copyright (C) 2026, SoC Labs (www.soclabs.org)
