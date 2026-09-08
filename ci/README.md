# `ci/` — the verdict layer

Everything in this directory exists to answer one question in a form a machine
and a person can both use: **which gate failed?**

A red CI job that says `impl.gate.budgets` sends a reader to one paragraph of
one file. A red CI job that says `make: *** [impl] Error 1` sends them to a
40,000-line log. That difference is the whole design.

Nothing here launches an EDA tool, takes a licence or needs a board — except by
running `make`, which may. `ci/lib.sh`, `ci/assert-stage.sh` and
`ci/capability.sh` are all licence-free and finish in about a second.

---

## The two rules everything here serves

> **ASSERT ON ARTEFACTS, NEVER ON EXIT STATUS.** Vivado exits 0 on a failed
> route, on unmet timing, and on a constraint file that matched nothing. "The
> stage passed" means *the artefact it was supposed to write is on disk and says
> what it should*.

> **A GATE NEVER INVENTS A VERDICT FROM MISSING DATA.** If the evidence is
> absent or unparseable the answer is `UNVERIFIED`, which **counts as a
> failure**. An unmeasured number is the token `unmeasured`, never `0` — a `0`
> in a utilisation column is indistinguishable from an empty design, and both of
> those look like good news.

Both are `CONTRACT.md` §0. A third rule comes from §7 and is the reason
`test/` exists: **a check that cannot fail is not a check.**

---

## What is in here

| File | What it is |
|---|---|
| `lib.sh` | The verdict model. Sourced, never executed. Five emitters, the assertion primitives, the summary table, `ci_exit`. |
| `assert-stage.sh` | Judges a **finished** stage from what is on disk, after the fact. One argument: the stage name. |
| `tier.sh` | Climbs the tiers cheapest-first and stops at the first one that breaks. The thing a CI job actually calls. |
| `capability.sh` | Probes a host and **derives** the runner labels it has earned, from a declaration the project owns. |
| `capability.conf.example` | That declaration, annotated. Copy it into the project; do not edit it here. |

---

## The verdict line

`$CI_VERDICT_DIR/verdicts.tsv`, append-only, **exactly four tab-separated
columns**:

```
<ISO8601 UTC>	<PASS|FAIL|UNVERIFIED|WARN|SKIP>	<gate.id>	<detail>
```

The detail is sanitised of tabs, newlines and carriage returns before it is
written. That is not fussiness: details are built from tool output and from
paths, and one tab arriving in one turns a four-column row into five, at which
point every `awk -F'\t'` downstream reads a gate id out of the wrong field and
reports a verdict against a gate that does not exist. Silently. A wrapped detail
is a cosmetic loss; a split row is a wrong answer.

**Gate ids are `<tier>.<subject>[.<detail>]`, lower case, dot separated, and
stable across runs.** They are meant to be grepped: *"`impl.gate.budgets` has
fired on eleven of the last twenty runs"* is a sentence CI should be able to
support, and it cannot if the ids are prose.

| Emitter | Counts as |
|---|---|
| `ci_pass <id> [detail]` | PASS |
| `ci_fail <id> <detail>` | FAIL |
| `ci_unverified <id> <why>` | **FAIL** — a check whose input it could not read has not passed; it has not run |
| `ci_warn <id> <detail>` | reported, never red |
| `ci_skip <id> <why>` | recorded **with its reason** — a tier silently checking nothing is how a green run comes to prove nothing |

`ci_exit` is non-zero when **any** gate failed — deliberately not the last
command's status. A tier that runs eleven gates and fails the third must still
run the other eight: a two-hour implementation's evidence is worth collecting in
full, and the last gate in a list is not the important one, it is merely the
last one.

---

## Running it

```sh
ci/tier.sh contract --fpga-dir path/to/project/fpga   # everything up to and including contract
ci/tier.sh impl --only --fpga-dir path/to/project/fpga
ci/assert-stage.sh impl --fpga-dir path/to/project/fpga
ci/capability.sh --require synth
```

`assert-stage.sh` finds the run in one of two ways, and **guesses neither**: it
prefers the `FPGA_*` variables `mk/flow.mk` exports — so a job that just ran
`make impl` already has the right values — and otherwise asks `make env` in the
project directory, which is the only thing that can resolve a `?=` chain plus
per-invocation overrides. Guessing `build/default` when the run was
`RUN_TAG=nightly` would assert against an empty directory and report a missing
bitstream for a bitstream that exists.

### Exit codes, everywhere in this directory

| | |
|---|---|
| `0` | every gate passed |
| `1` | at least one gate is FAIL or UNVERIFIED |
| `2` | refused: unusable input, or a run that could not be resolved |
| `75` | `EX_TEMPFAIL` — lock contention, try again |
| `130` | interrupted |

### Environment

| | |
|---|---|
| `CI_VERDICT_DIR` | Where `verdicts.tsv` and `owner` are written. Defaults to `$FPGA_RUN_DIR/ci`. |
| `CI_APPEND=1` | "Somebody upstream already started this run's verdict file." `tier.sh` sets it for everything it calls. |
| `CI_LANE` | This process's name in a collision report. |
| `CI_SUMMARY_FILE` | Markdown destination; defaults to `$GITHUB_STEP_SUMMARY`. GitLab has no equivalent — point it at a file and publish that as an artefact. |
| `CI_COLOUR=0` | Suppress ANSI (automatic when stdout is not a tty). |

**Two lanes must not share a `CI_VERDICT_DIR`.** `ci_init` truncates the verdict
file, which is right for one process owning one file and wrong for a static
check running beside a two-hour implementation — a perfectly ordinary thing to
want on an FPGA flow. Whichever starts second erases the first one's records,
and the lane that lost its evidence then reports "0 failed": the best possible
result produced from no measurement at all. Give each lane its own directory
(`CI_VERDICT_DIR=<run>/ci/<lane>`). `ci_init` enforces this — a process that
finds a **live** foreign owner refuses to truncate and fails a gate, so a
collision costs a red run with a lane name in it instead of a green run with a
hole in it.

---

## Why `assert-stage.sh` exists when `mk/flow.mk` already asserts

It is a **second, independent implementation** of the same predicates, and that
is the point rather than an oversight:

1. **make's assertions run in the same process as the stage.** A job killed by a
   timeout, a lost licence seat, a full filesystem or a rebooted runner never
   reaches them, and the artefacts left behind are then judged by nobody.
2. **A stage run by hand leaves no record a later CI job can read.** This reads
   the disk, so it does not care who ran the stage or when.
3. **make prints prose and exits 1.** CI needs a named verdict per gate.

**It does not re-derive the tool's findings.** The stage scripts have already
parsed the reports and written their numbers into `<stage>_manifest.txt` and
their verdict into `<stage>_gate.txt`. Re-scraping those reports here would be a
second, fuzzier opinion competing with the authoritative one — which is exactly
the trap the reference project's stage reporter fell into, where a
case-sensitive grep undercounted DRC by 7% for weeks and nothing disagreed with
it. **Read the manifest.** If the manifest does not say, the answer is
`UNVERIFIED` and somebody has to make the stage record it.

---

## Proving that a gate can fail

Every claim `ci/` makes about itself is tested from **outside**, on a copy, with
the fault planted:

```sh
test/run.sh                # every suite
test/run.sh t_verdicts     # just the verdict model
```

`test/shell/t_verdicts.sh` neuters `ci_unverified`'s failure counter, `ci_exit`'s
failure test, `ci_assert_file`'s `-s`, and both of `_ci_record`'s sanitisers —
one fault per copy — and requires the matching assertion to go red each time. A
self-test a library runs on itself is a claim the library makes about itself,
and a claim a mutant makes about itself is worth what any other unaudited claim
is worth.

---

## What is deliberately **not** here

- **No allowlist ships with a default entry.** A default that tolerates message
  IDs hands each new project somebody else's undiagnosed exemptions. Every entry
  carries a paragraph of diagnosis and an owner, in the project.
- **No knob demotes a gate.** A project with a known, owned, documented defect
  ratchets the budget in `design.mk`, where every run's manifest records the new
  value and a reviewer can see it. Demoting the verdict in a CI configuration
  hides the same decision somewhere no run record ever reaches, and a budget
  that is invisible is how the bug becomes the definition of pass.
- **No board, pin, part or project path is named anywhere in this repository.**
  If a change here wants one, the contract is wrong: raise it, do not add the
  file.

Copyright (C) 2026, SoC Labs (www.soclabs.org)
