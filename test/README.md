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

## What these suites do **not** cover yet

- **`ci/assert-stage.sh` has no suite of its own.** It has been exercised by hand
  against fixture run directories — a clean run, a stale manifest, an exceeded
  budget, a delegation with no owner, a missing verdict, both `--optional`
  paths — but by hand is not by CI, and this file is where that gap is recorded
  rather than in somebody's memory. A `t_assert_stage.sh` is the obvious next
  suite, and the fixtures it needs are a manifest and a gate file in a
  `mktemp -d`.
- **`test/python/` and `test/fixtures/` are empty.** `scripts/fpga-flow-check`
  is only exercised here through its seam and step reporting.
- **Nothing here runs a stage.** These suites judge the contract and the
  verdict layer. What a stage produces is judged by `ci/assert-stage.sh`, on the
  artefacts, after the fact.

Copyright (C) 2026, SoC Labs (www.soclabs.org)
