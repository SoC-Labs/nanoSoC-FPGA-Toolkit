# `test/` — the toolkit's own tests

```sh
test/run.sh                 # every suite
test/run.sh t_seams         # one of them (prefix match)
test/run.sh --list          # name them, run nothing
T_KEEP=1 test/run.sh        # keep the sandboxes and print where they are
```

No EDA tool, no licence, no PDK, no board, no `pip install`. Everything here
runs on a laptop in a few seconds, and every filesystem mutation happens under
`mktemp -d`.

These are `CONTRACT.md` §11.7 — one of the eight things phase 1 is done when.

---

## The one rule

> **A CHECK THAT CANNOT FAIL IS NOT A CHECK.**

So every assertion in these suites is paired with a **mutation proof**: plant the
fault in a throwaway copy of the toolkit, show the same assertion goes red,
throw the copy away. The proof is a test in its own right and runs every time,
rather than being a claim in a comment that was true once.

A test file that only asserted the good case would pass just as happily against
a guard that had been deleted. That is not hypothetical here — this toolkit's
own third rule comes from a five-entry whitelist in the reference toolkit that
had been wrong for months while every test around it stayed green.

The proofs are visible in the output as `*.mutation` gate ids, and they are
worth reading when one fails: a mutation proof going red means **the check
accepted a planted fault**, which is a much worse finding than a broken feature.

---

## Statuses

| | |
|---|---|
| `ok` | the assertion held |
| `FAIL` | it did not — the suite goes red |
| `SKIP` | it did not apply here, **with the reason recorded** |
| `DEFECT` | a `KNOWN-DEFECT`: the assertion is correct and the code does not satisfy it today. Recorded, not red — but if it starts **passing**, the suite goes **RED**, so the marker cannot outlive the bug |

**A skip always carries its reason, and a reasonless skip fails the suite.** A
file that has not landed yet, a tool that is not installed, a directory that is
still empty — those are exactly what the reader needed to know, and a silent
skip reads like a pass. Several files in this repository are being written
concurrently, so "not there yet" is a normal answer and it is never a green one.

An empty run is also a failure: zero suites executed measures nothing, it does
not measure zero defects.

---

## The suites

Discovered by **glob** — `test/shell/t_*.sh` — never from a list in `run.sh`.
That is the same rule the seam list and the step list follow, for the same
reason: a hardcoded suite list would fail silently, a new file would simply
never run, and the summary would say everything passed.

### `t_contract.sh` — `mk/flow.mk`'s parse-time guards

The guards protect an `rm -rf` and a build that would otherwise succeed while
producing the wrong design. Each is a make conditional wrapping an `$(error)`,
and a conditional that stops matching **fails open**: no warning, the build just
proceeds. Covered: the three required variables; `RUN_TAG` empty, with a
separator, and `..`; `BUILD_DIR` empty, relative and `/`; the refusal to build
from inside the toolkit's own `examples/`; that the DERIVED variables cannot be
set from the command line and that the attempt is still reported; and that a
well-formed project parses and `make env` prints its blocks with `(none)`
rendered explicitly.

Every guard's own conditional line is then replaced, in a copy, with one that
can never be true — and the same command must be **accepted**.

### `t_flow_utils.sh` — the boot layer everything else stands on

`flow/common/flow_utils.tcl` is sourced by every Vivado stage and produces
almost no artefact of its own, which is what makes it dangerous: a guard that
stopped guarding, a hook that stopped running, a knob that stopped registering
and an exit code that collapsed into its neighbour all leave a run that looks
exactly like a correct one. The stage finishes, the bitstream appears, and
nothing says which of the two designs it built.

28 properties, 25 of them with a paired planted-fault proof — 32 proofs in all,
because the alias-table check carries eight on its own (the three properties
without a proof are proved from the other side, and the file says which and
why): the **shadow guard** (`proc`
silently replaces a command — the reference toolkit's equivalent has fired in
anger, on a helper that shadowed a builtin and aborted a route stage 2.5 hours
in); `flow_config` rejecting a typo'd key; **exit 1 and exit 2 staying
distinct**; `flow_assert_input` telling *absent*, *zero-byte* and *empty
directory* apart; `opt` registering a knob by the act of reading it, and
`flow_env` deliberately not; the seam list's four validations; a mistyped seam
at a **call site**, which otherwise disarms the guard it was arming, silently
and forever; hooks being optional, recorded, run in the caller's scope, and able
to **abort the stage**; a project step override replacing the toolkit's file
wholesale; the knob census reading files rather than running them; the pack
alias table, **validated against the pack schema** so that a row which can never
fire is refused rather than read past; and `try_step`.

That last one is the defect this file was extended for. `::part_alias` is the
only place in the engine where a pack's spelling appears, and nothing checked
that the names on either side of it were real — so `device → part_name` sat
there for weeks reading as a promise that `part device` returns the full part
string, when the schema declares `device` as the bare die. It was removed by
*reading*. The eight proofs now plant that exact row back, plus a target no
schema declares, a name mapped to itself, a spelling `pack_api.tcl` already
resolves (the same way and a different way), the same fault in the board table,
a deleted table, and an empty schema listing — the last of which must make the
shim **refuse**, because a check with nothing to check against has measured
nothing.

Everything runs under bare `tclsh`. This file is also what keeps that true: the
day a helper starts calling a Vivado command unguarded, these drivers stop
sourcing and say so, instead of taking the whole tool-free suite with them.

Two of its own bugs are worth recording, because both are the defect classes the
toolkit exists to stop, found inside the thing meant to find them. A `catch`
around `flow_seam_assert` trapped nothing, because `die` **exits** — so the
driver never resumed and reported success on an exit it had not observed. And
every proof initially shared one mutant, which accumulates faults, so the
fifteenth proof passed or failed for the first proof's reason. Each proof now
gets a clean copy.

### `t_verdicts.sh` — `ci/lib.sh`

That `ci_unverified` counts as a **failure**; that `ci_exit` is non-zero when an
**early** gate failed and later ones passed; that `ci_assert_file` distinguishes
**absent** from **zero bytes**; that `verdicts.tsv` is exactly four
tab-separated columns even when a detail carries a tab, a newline and a carriage
return; and that a `SKIP` records its reason. Each is proved by neutering the
one line in a copy of the library that makes it true.

### `t_seams.sh` — the anti-drift suite

The most important of the three. `flow/common/seams.txt` is the single source of
truth for the hook seams, and `ls flow/steps/` is the single source of truth for
the step overrides. This suite asserts that no other file in the repository
carries a copy of either, that `CONTRACT.md`'s own listing **agrees** with the
file, that every seam the templates offer a hook at exists, that the engine
refuses to run without the list, and — functionally — that the checker gets the
answer from the file and the directory rather than from a whitelist of its own.

Two of its mutation proofs plant the reference toolkit's exact defect: a
**five-entry hardcoded list against a seven-entry directory**. The consumer must
then get the answer wrong, calling a real extension point unrecognised. That is
the failure this repository's third rule was written from, reproduced with the
same numbers.

### `t_init.sh` — the scaffolder, and the round trip through `make check`

A scaffolder is trusted absolutely by the person running it, because they have
nothing yet to compare its output against, so everything it gets wrong reads as
a fact about *their* project. The central assertion is **not** that `make check`
is clean on a fresh scaffold — it is deliberately not, and that refusal is the
feature. It is that `make check` names **exactly** the decisions the scaffolder
left open and nothing else. Fewer is worse than more: a decision that stops
being reported is a value nobody chose, in a build that runs.

The open set is measured, not assumed, and the suite also proves the refusal is
**clearable** — fill in what the check names and it says `Contract complete.`,
with no warnings. Also covered: every claimed `write` is on disk and non-empty
and the tally agrees; every file under `templates/` is accounted for, each at
its own path; the generated `Makefile` matches `CONTRACT.md` §2's fenced block
*read out of the contract*; `<<FILL IN>>` lands file-for-file where the templates
put it and `@PART@` is the one placeholder allowed to become one; a re-run keeps
the project's edits and `--force` is what overrides that; nothing outside
`fpga/` is touched; a refusal leaves no trace; and the part packs `--help`
offers are `find part/ -type d`, proved by planting a hardcoded list and then
adding a pack.

Two `KNOWN-DEFECT` markers come from it, both found by asserting rather than by
reading: `templates/design.mk.in`'s own instruction line contains a literal
`<<FILL IN>>`, so a project that has made every real decision still fails
`make check` until it deletes its own instructions; and `install_one`'s
empty-output guard uses `refuse` (exit 2, documented as *nothing was written*)
at the one point in the file that most certainly leaves a half-tree behind.

---

## Adding a suite

Drop a `t_<subject>.sh` into `test/shell/`. `run.sh` finds it; nothing needs
registering anywhere.

```bash
#!/usr/bin/env bash
set -uo pipefail                       # NOT -e (CONTRACT.md section 10)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/harness.sh"

t_sandbox; SB="$T_SANDBOX"

t_check   my.gate      "the good case holds"                  my_predicate "$FLOW_DIR"
M="$(t_mutant "$SB" my-fault)"
t_replace_line "$M" mk/flow.mk 'the exact line' 'the broken one'
t_check_fail my.gate.mutation "with the fault planted it goes red" my_predicate "$M"

t_summary
```

The harness (`test/lib/harness.sh`) gives you:

| | |
|---|---|
| `t_check <id> <desc> <cmd...>` | the command must exit 0 |
| `t_check_fail <id> <desc> <cmd...>` | it must exit **non-zero** — this is what a mutation proof uses |
| `t_known_defect <id> <desc> <cmd...>` | recorded, not red; **red when it starts passing** |
| `t_skip <id> <reason...>` | the reason is mandatory |
| `t_sandbox` / `t_in_sandbox` | a temporary directory, removed on exit; nothing destructive runs outside one |
| `t_mutant <sb> <name>` | a fresh copy of the toolkit you may break (never carries `.git`) |
| `t_mutate` / `t_replace_line` | plant the fault — **and fail loudly if the edit changed nothing**, because a mutation that silently did not apply turns its proof into a check that cannot fail |
| `t_project <dir> <flow dir>` | a throwaway project with the three-line entry contract |

Two conventions worth keeping:

- **One fault per copy.** When the assertion stops holding it must be because of
  *that* fault, not some other line that broke at the same time.
- **Assert on the message, not just the exit status.** `make` on a project with
  three things wrong reports the first one. A proof that accepted any non-zero
  exit would pass on all three — including on a checkout where the guard it was
  aimed at had been deleted and something unrelated was broken instead.

---

## Two ledgers, and why a number lives in a file

`run.sh` aggregates every suite's counts and prints them:

```
===== suite: 10 file(s) passed, 0 failed, 60s =====
assertions: 376 passed, 0 failed, 0 known-defect, 0 skipped
mutation:   168 planted faults rejected
```

**`MUTATION_COVERAGE`** declares how many planted faults each suite must reject.
Deleting a proof otherwise costs one `ok` line and nothing else — the suite
still exits 0, so a guard can lose the only evidence that it *can* fail while
the run stays green. The comparison is red in **both** directions: fewer than
declared means a proof was dropped, more means one was added and nobody read it.

**`KNOWN_DEFECTS`** holds two kinds of entry, and the difference is the point.
A `DEFECT` is an assertion that is correct and that the toolkit does not satisfy
— marked with `t_known_defect` where the suite can express it, so the marker
goes **red** if the bug is ever fixed. An `UNPROVEN` entry is not a failure: it
records something that may well be right and that nothing has ever demonstrated,
with what would settle it written next to it. A green suite is otherwise
indistinguishable from a complete one.

---

## Coverage is host-dependent, and the summary says so

Every suite skips rather than fails when a precondition is absent, and carries
its reason. What that hid until 2026-09-11 was the **aggregate**: on a host with
no `tclsh`, five suites skip themselves whole — 263 of 376 assertions vanish —
and the old runner still printed `10 file(s) passed, 0 failed`, because it
counted *files*.

Two gates now make that fatal:

| gate | fires when | override |
|---|---|---|
| **hole** | a suite asserted nothing at all and skipped instead | `FPGA_TEST_ALLOW_HOLES=1` |
| **skip ratio** | more than 10% of assertions skipped | `FPGA_TEST_SKIP_MAX_PCT=` |

The hole gate is the one that matters: five whole suites bailing out is only
five `SKIP` lines, so the ratio alone would have read as 4% and passed.

---

## What these suites do **not** cover yet

- **No stage script is unit-tested.** `flow/vivado/*.tcl` is 5181 lines and
  needs Vivado, so the suites reach it only through fixtures of its *output*.
  `t_measure`, `t_assert_stage` and `t_verdicts` test the graders. The stages
  themselves rest on one integration result: a bitstream that matched a
  known-good one, for one design on one part.
- **The deploy tier has never touched a board.** `scripts/fpga-flow-deploy`,
  `mk/deploy.mk` and the fpgahub hooks are exercised against fixtures and
  dry-run paths only.
- **`fpga-flow-{doctor,hooks}` are named by no test.** `doctor` is pure
  host-inspection output and could be driven from the harness today; `hooks`
  answers from `seams.txt` and the steps directory, which `t_seams.sh` already
  knows how to check. `init` was closed on 2026-09-11 by `t_init.sh` — and what
  that cost is the useful part: the round trip this bullet used to propose
  ("scaffold, then `make check` is clean") was **wrong**. A fresh scaffold is
  deliberately incomplete and `make check` is supposed to refuse it.
- **`ci/` is 4312 lines and only `ci/lib.sh` is covered** — thoroughly, by
  `t_verdicts`. `capability.sh`, `tier.sh`, `deploy-gates.sh` and
  `check-vendor-collateral.sh` are not named by any test.

Every item above is also in `KNOWN_DEFECTS`, which is the file that goes stale
if one of them is fixed and not deleted.

---

Copyright (C) 2026, SoC Labs (www.soclabs.org)
