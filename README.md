# nanoSoC FPGA Toolkit

A reusable **Vivado** front-to-back flow. Add it to a design project as a git
submodule, supply the target and the files that describe it, and get a
bitstream.

The project owns the target. This repository owns the flow. If you find yourself
wanting to add a board name, a pin, or a project path *here*, the contract is
wrong — raise it, do not add the file.

```make
# <project>/fpga/Makefile — the whole of it
FPGA_DIR := $(CURDIR)
include $(FPGA_DIR)/design.mk           # everything about the DESIGN
include $(FPGA_FLOW_DIR)/mk/flow.mk     # everything about the FLOW
```

---

## Status — what has and has not been built

**Phase 1 (the contract layer) is largely built and its suite is green. Nothing
here has produced a bitstream.** No stage has been run against Vivado — the
Vivado stage scripts are not written yet, so there is nothing to run. The
phase-1 acceptance list in [`CONTRACT.md`](CONTRACT.md) §11 is **not** complete:
items 4 and 6 need a real project manifest and a real board pack, and neither
exists.

Read the table as three different claims, because they are: *written* means the
code exists, *exercised* means someone ran it and it did what it says, and
*proven* means a test would go red if it stopped.

This is a deliberate echo of the reference toolkit's own README, which draws a
hard line between *written*, *executed*, and *proven*. A toolkit that overstates
its maturity costs someone a week.

| Layer | State |
|---|---|
| `CONTRACT.md` — the interface | written |
| `mk/` — the make engine | written; guards and `help`/`env`/`check` exercised |
| `flow/common/` — boot, flist reader, manifests | written; flist reader exercised against a real 13-file, 585-source flist |
| `flow/vivado/` — the stage scripts | **not written** — no stage can run |
| `flow/steps/` — overridable steps | written, never executed |
| `part/` — part packs | written; three packs load and validate |
| `scripts/` — check, doctor, init, packs, hooks | written and exercised |
| `ci/` — gates, verdicts, tiers, scanner | written; scanner proven both directions |
| `test/` — mutation-proof harness | 63 assertions, green, every one mutation-proved |
| A real bitstream from this flow | **yes, on a fixture design** |
| A real bitstream for the KR260 eth chiplet | **NO — fails at stage 3** |

**The KR260 parity test failed, and that is the most important line in this
table.** The toolkit reaches a bitstream on a small fixture, and cannot build
the design it exists to build: a block-design-based project needs
`generate_target` (absent), a stage3->stage4 handoff that carries more than a
bare `.bd`, and the part set on the in-memory design before `read_bd`. Full
diagnosis and a ten-item fix list in the consuming project's
`fpga/PARITY_REPORT.md`. Until that passes, `tidelink/fpga` remains the only
flow that builds this chiplet, and nothing here should be described as
replacing it.

`test/run.sh` is green, and that is a claim about the contract layer only.
**No stage has been run against Vivado**, because `flow/vivado/*.tcl` does not
exist yet — `make synth` will tell you so and take no licence. Phase-1
acceptance items 4 and 6 (a real project manifest; `part-probe`/`board-probe`
against a real board pack) are not met.

---

## Why this exists

Twenty FPGA build flows across the SoC Labs tree are one pattern, copy-pasted.
Measured 2026-09-08 by walking the tree with `find` and `md5sum`:

| File | Copies on disk | Distinct contents |
|---|---|---|
| `bit2bin.py` | 75 | **1** |
| `build_design.tcl` | 179 | 8 |
| `harness/fpga.mk` | 116 | 2 |
| `package_component.tcl` | 69 | **1** |

Six of those flows already agree, without anyone having written it down, on the
same six-variable interface (`FPGA_PART`, `FPGA_PROJECT_DIR`, `FPGA_TARGET_DIR`,
`FPGA_IP_REPO`, `FPGA_OUTPUT_DIR`, `FPGA_NUM_JOBS`). A de-facto ABI exists. What
is missing is a home for it, a contract that says which side owns what, and a
verdict layer.

Copy-paste at that scale hides defects rather than spreading them. Two found in
passing, neither of which would show up in a green build:

- `nanosoc_tech/fpga/targets/*/fpga_timing.xdc` exists in all five board
  directories and is **read by nothing** — no consumer anywhere in the tree.
  Three of the five files are byte-identical. Every build in that lineage is
  timing-unconstrained beyond whatever the block design happens to emit.
- `USE_GENERATED_TIMING_XDC=1` is documented in a validator and exists in no
  Makefile or build script.

Vivado drops a constraint that matches nothing without an error. Exactly one
flow in the tree gates on that.

---

## The two rules

> **Assert on artefacts, never on exit status.** Vivado exits 0 on a failed
> route, on unmet timing, and on a constraint file that matched nothing.

> **A gate never invents a verdict from missing data.** If the evidence is
> absent or unparseable the answer is `UNVERIFIED`, which counts as a failure,
> never as a pass. An unmeasured number is the literal token `unmeasured` —
> never `0`, never omitted.

And a third, learned from a defect in the reference toolkit and therefore
binding here:

> **Never hardcode a list a directory already knows.** The hook seams live in
> `flow/common/seams.txt` and nowhere else; the step-override list is
> `ls flow/steps/`. `test/shell/t_seams.sh` fails the suite if a second copy
> appears.

---

## Part packs and board packs

The reference ASIC toolkit has one technology-pack concept. This toolkit splits
it, because the two halves have different owners:

- A **part pack** is a fact about a device — LUT count, clock regions, whether
  an `IDELAYE2` or an `IDELAYE3` primitive applies, how many SLRs. It ships
  **here**, in `part/`.
- A **board pack** is a fact about a circuit board — which pin, which IO
  standard, what the oscillator runs at, which fpgahub board group holds it. It
  ships **in the project**, in `fpga/board/`.

The reference toolkit already draws this line for pads: the tech pack states the
bond-pad cells, the project's I/O file states the pad order. We are only naming
it.

A pin number or an IO standard appearing anywhere under `part/` is a bug.

---

## Getting started

```sh
git submodule add git@github.com:SoC-Labs/nanoSoC-FPGA-Toolkit.git fpga/fpga-toolkit
fpga/fpga-toolkit/scripts/fpga-flow-init --block my_design --board my_board .
cd fpga
make doctor      # can THIS MACHINE run the flow? launches no EDA tool
make check       # is the design contract complete? costs no licence
make help        # every stage this design offers
```

`make check` is the one to run first and often. It reads file *content*, not
just existence — a fresh scaffold carries `<<FILL IN>>` markers across every
file it creates, and an existence check cannot tell a finished project from an
untouched one.

---

## What this toolkit does not do

- **It does not manage boards.** Booking, programming and resetting hardware is
  [fpgahub](https://git.soton.ac.uk/soclabs/fpgahub)'s job. This toolkit calls
  it from post-stage targets and enforces the lease discipline fpgahub leaves
  advisory; it does not reimplement it.
- **It stops at `.xsa`.** Vitis and PetaLinux consume that artefact and have
  their own lifecycle.
- **It does not do DFX or ProtoCompiler yet.** Both are real back-ends with
  stage graphs of their own; both are out of phase 1.
- **It ships no vendor collateral.** No encrypted IP, no board files, no
  bitstreams, no `.dcp`. `make hooks-install` puts a scanner in front of every
  commit, merge, patch and push to keep it that way.

---

## Layout

```
CONTRACT.md          the interface. Every file here implements part of it.
mk/                  the make engine, checks, help, git-hook wiring
flow/common/         boot, hooks, step overrides, manifests, flist reader
flow/common/seams.txt  THE list of hook seams. The only copy.
flow/steps/          overridable step files — the list IS this directory
part/                part packs (silicon facts)
scripts/             fpga-flow-* — addressable artefacts, never on PATH
ci/                  gates, verdicts, tiers, host capability
templates/           what fpga-flow-init scaffolds
test/                the harness. Every assertion has a mutation proof.
```

---

Copyright (C) 2026, SoC Labs (www.soclabs.org)
