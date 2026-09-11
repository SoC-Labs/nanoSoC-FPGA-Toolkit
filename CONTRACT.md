# The contract

**This file is the interface. Every other file in this repository implements
part of it. If your code and this file disagree, one of them is a bug — say
which, do not silently pick.**

Written 2026-09-08 for phase 1 (the contract layer: no EDA tool is launched by
anything described here). Modelled on `nanoSoC-ASIC-Toolkit` @ `4de7860`, whose
separation of concerns is proven; every deviation from it below is deliberate
and is marked **DEVIATION** with the reason.

---

## 0. The two rules everything else serves

> **ASSERT ON ARTEFACTS, NEVER ON EXIT STATUS.** Vivado exits 0 on a failed
> route, on unmet timing, and on a constraint file that matched nothing. A stage
> "passed" means *the artefact it was supposed to write is on disk and says what
> it should*, never *the tool returned 0*.

> **A GATE NEVER INVENTS A VERDICT FROM MISSING DATA.** If the evidence is
> absent or unparseable the answer is `UNVERIFIED`, which counts as a failure,
> never as a pass. An unmeasured number is emitted as the literal token
> `unmeasured` — never as `0`, never omitted.

A third rule, learned from a defect in the reference toolkit and therefore
binding here:

> **NEVER HARDCODE A LIST THAT A DIRECTORY ALREADY KNOWS.** The reference
> toolkit hardcodes a five-entry step-override whitelist while the directory
> holds seven, so two real override points are undocumented and warn spuriously.
> Every whitelist in this repository is derived at run time from its directory
> or from a single declared list — see §6.

---

## 1. Ownership: what lives where

| | Toolkit (this repo) | Project (the consuming design) |
|---|---|---|
| Flow logic | `mk/`, `flow/`, `scripts/`, `ci/` | — |
| Facts about **silicon** | `part/<part>/part.tcl` | — |
| Facts about a **PCB** | — | `fpga/board/<board>/board.tcl` |
| Target collateral | — | `fpga/targets/<target>/` (board top, XDCs, BD) |
| Design manifest | `templates/design.mk.in` | `fpga/design.mk` |
| Extension | seam + override *machinery* | `fpga/hooks/`, `fpga/overrides/` |
| Deploy declaration | hook machinery | `fpga/fpgahub.toml` |

**DEVIATION from the ASIC toolkit:** it has one `tech/` concept. We split it in
two. A *part pack* is a fact about a device (LUT count, whether an IDELAY
primitive exists, how many SLRs) and ships **in the toolkit**. A *board pack* is
a fact about a circuit board (which pin, which IO standard, what the oscillator
runs at) and ships **in the project**. The reference toolkit already draws this
line for pads — the tech pack states the bond-pad cells, the project's `.io`
file states the pad order — we are only naming it.

The project must be able to state its target without editing this repository.
That is the whole requirement; if an agent finds itself wanting to add a
board name, a pin, or an XDC path to this repo, that is the signal the contract
is wrong. Raise it, do not add the file.

### 1.1 This repository ships FLOW, never COLLATERAL

Normative, and enforced by `ci/check-vendor-collateral.sh` in front of every
commit, merge, patch and push. Nothing may be committed here that is: encrypted
or licensed vendor IP, a vendor-catalogue `.xci`/`.xcix`, a board file, a
bitstream, a `.dcp`/`.ltx`/`.xsa`/`.hwh`, a file copied out of a vendor install
tree, or anything carrying a vendor EULA or confidentiality header.

The mechanism for needing one anyway is a **path in a variable, resolved on the
host** — never a vendored file. `VENDOR_COLLATERAL.md` holds the detail.

The rule extends to `.gitignore`: a path that might be collateral must NOT be
ignored, because the scanner reads the untracked corpus too, and that is the
half which catches the file that sits in a working tree for three weeks and then
goes in under `git add -A`.

---

## 2. The entry contract

A consuming project's `fpga/Makefile` is three lines and nothing else:

```make
FPGA_DIR := $(CURDIR)
include $(FPGA_DIR)/design.mk
include $(FPGA_FLOW_DIR)/mk/flow.mk
```

`design.mk` also ends with the same `include`, so it is self-sufficient when
included directly. `mk/flow.mk` therefore **must** carry an include guard
(`ifndef FPGA_FLOW_MK_INCLUDED`) — without it GNU make emits an "overriding
recipe" warning per target and silently runs the *second* definition of each.

`FPGA_FLOW_DIR` is set **by the project**. `mk/flow.mk` hard-errors if it is
empty and then does `override FPGA_FLOW_DIR := $(abspath $(FPGA_FLOW_DIR))`.

`mk/flow.mk` must also refuse to run when `FPGA_DIR` resolves inside
`$(FPGA_FLOW_DIR)/examples/` — the example sits at exactly the paths every `?=`
defaults to, so building from there would succeed and produce a different design
without a word.

---

## 3. The variable surface

Canonical names only. Aliases are accepted where noted, and `make check` and
`make env` always report the **canonical** name.

### 3.1 REQUIRED — hard `$(error)` at make parse time

| Variable | Meaning |
|---|---|
| `FPGA_FLOW_DIR` | This repository's root |
| `BLOCK` | The design's short name. Stem of every artefact |
| `BOARD` | Selects `$(BOARD_DIR)/board.tcl` |

### 3.2 REQUIRED — reported by `make check`, not by make

| Variable | Meaning |
|---|---|
| `TOP` | The **board-level** top module. Not the SoC top — getting this wrong is quiet |
| `RTL_FLIST` | The master flist |
| `XDC_PINS` | Pin/placement constraints. Read in synthesis **and** implementation |
| `PART` | The device. Normally supplied by the board pack; a project override wins |

### 3.3 Optional-with-default, by group

Defaults are shown as `?=`. A project override always wins. **A configured-but-
missing optional input is an error, not a shrug** — if the project named a file,
`make check` requires it to exist and be non-empty.

**Corollary, found by integration testing on 2026-09-08 and binding on every
future default: a default that names a CONVENTIONAL path must DISCOVER, not
ASSERT.** Write it `?= $(wildcard <path>)`. A bare `?= <path>` is
indistinguishable, by the time the checker sees it, from the project having
named that file — so the engine's own convenience default becomes a required
input, and a project with no deploy configured cannot pass `make check` until it
creates an empty file it never asked for. With `$(wildcard)` an absent file
leaves the variable empty and it reports as `--`; a project that names a path
explicitly still gets the "you named it, so it must exist" treatment, which is
the behaviour that was wanted in the first place.

**Identity**
```
DESIGN_NAME     ?= $(BLOCK)          # block-design name, when a BD is used
PROJECT_ROOT    ?= $(FPGA_DIR)/..    # git provenance only
```

**Target**
```
BOARD_DIR       ?= $(FPGA_DIR)/board/$(BOARD)
TARGET          ?= $(BOARD)
TARGET_DIR      ?= $(FPGA_DIR)/targets/$(TARGET)
PART_DIR        ?= $(FPGA_FLOW_DIR)/part/$(PART)
BOARD_PART      ?=                    # e.g. xilinx.com:kr260_som:part0:1.1
BOARD_REPO_PATHS?=
FLOW_MODE       ?= project            # project | direct | dfx | protocompiler
PLATFORM        ?= bare               # bare | pynq
SYS_CLK_FREQ_HZ ?=                    # ALSO compiled into firmware. See §3.4
```

**RTL**
```
RTL_FLIST_GEN      ?=                 # a make target in the PROJECT that
                                      # regenerates the flist. Run before flist.
RTL_INCDIRS        ?=
RTL_DEFINES        ?=                 # reach the tools normally
RTL_DEFINES_INBODY ?=                 # MUST be baked into materialised copies:
                                      # ipx::package_project DROPS fileset
                                      # defines. See §9.
RTL_DEFINES_NEVER  ?=                 # asserted ABSENT. e.g. ASIC_TSMC65
RTL_PARAMS         ?=                 # NAME=VALUE. Survive IP packaging as
                                      # CONFIG.*; defines do not.
TOP_HDL            ?=                 # read AFTER the flist — board top goes here
EXTRA_SRCS         ?=
SV_FILES           ?=                 # force file_type SystemVerilog per file
```

**IP / BD**
```
IP_REPOS        ?=                    # a LIST. tidelink needs three.
IP_VENDOR       ?= soclabs.org
IP_CORE_REV     ?= 1
IP_CACHE_DIR    ?= $(BUILD_DIR)/ip_cache
PACKAGE_TCL     ?=                    # project-supplied packaging script
BD_TCL          ?=
BD_OVERLAY_TCL  ?=                    # a LIST; applied in order over BD_TCL
BD_GLOBAL_SYNTH ?= 0
```

**Constraints** — explicit paths. **DEVIATION:** the existing flow discovers
XDC by the glob `*_tidelink*.xdc`, so any other naming is silently invisible and
warn-only. We take explicit paths, and `make check` errors on a `.xdc` present
in `TARGET_DIR` that no variable names.
```
XDC_CLOCKS      ?=                    # SYNTHESIS ONLY. create_clock and
                                      # create_generated_clock. Not an
                                      # exception, so not XDC_TIMING's window;
                                      # implementation takes the same
                                      # definitions from XDC_TIMING, so each
                                      # stage defines each clock exactly once.
XDC_TIMING      ?=                    # implementation only
XDC_DRC         ?=                    # implementation only
XDC_EXTRA       ?=                    # a LIST, order preserved
XDC_OPTIONAL    ?=                    # a LIST of "COND:path" — included iff
                                      #   $(COND) is 1. e.g. USE_IDELAY:...
XDC_POST_ROUTE  ?=                    # `source`d AFTER route_design, NOT
                                      # read_xdc'd. Vivado rejects procedural
                                      # Tcl in an XDC; a DRC waiver needs it.
```

**A CLOCK DEFINITION IS NOT AN EXCEPTION, AND THE READ WINDOW COSTS SOMETHING.**
Added 2026-09-09. The rule below withholds `XDC_TIMING` from synthesis because an
*exception* read at synthesis changes what synthesis builds. Clock
**definitions** are not exceptions — and in every project shipped so far they
live in the same file, so synthesis does not see them either.

That is not free. `synth_design -gated_clock_conversion auto` converts an RTL
clock gate into a clock enable **only on a net Vivado knows is a clock**, so with
the definitions withheld it converts nothing — silently, with no warning and a
byte-identical netlist. Measured on xc7z020: with `create_clock`, `auto` removes
the LUT from the clock path, adds a BUFG and drives the flops' CE; without it,
nothing changes. The first real design has 1 of 7 clock definitions in its
synthesis-visible constraints and 6 implementation-only.

`flow/steps/synth_setup.tcl` therefore **refuses** when conversion is enabled and
any clock definition is implementation-only, rather than letting the knob lie.
**`XDC_CLOCKS` is the way out** — a synthesis-only constraint file holding
`create_clock`/`create_generated_clock` and nothing else. It is read at
synthesis and marked `USED_IN_IMPLEMENTATION false`, because implementation
takes the same definitions from `XDC_TIMING`; marking rather than merely not
reading matters in project mode, where the file joins a fileset later stages
also open, and without the property every clock would be defined twice. **This
generalises beyond clock gating:** any synthesis decision that depends on knowing
what a clock is inherits the same blindness, so a project keeping all its clock
definitions implementation-only should expect more than one such surprise.

**THE ENGINE SETS THE READ WINDOW, FROM THE VARIABLE THAT NAMED THE FILE.**
Settled 2026-09-08. `XDC_PINS` gets `USED_IN_SYNTHESIS true` and
`USED_IN_IMPLEMENTATION true`; `XDC_TIMING` and `XDC_DRC` get
`USED_IN_SYNTHESIS false`. The project does not set those properties and must
not need to — the whole point of naming a file in a role-specific variable is
that the role is then known. `flow/vivado/*.tcl` must match this when it lands;
if it does not, one of the two is a bug and this line says which.

**Firmware** — a bitstream co-dependency, not a separate build.
```
FW_APP          ?=
FW_HEX          ?=
FW_HEX_FORMAT   ?= word               # byte | word
FPGA_IMAGE_HEX  ?=                    # what $readmemh resolves to
```

**Extension points**
```
HOOKS_DIR       ?= $(FPGA_DIR)/hooks
OVERRIDES_DIR   ?= $(FPGA_DIR)/overrides
```

**Run namespace**
```
BUILD_DIR       ?= $(FPGA_DIR)/build
RUN_TAG         ?= default
IN_RUN_TAG      ?= $(RUN_TAG)         # which run's databases this stage READS
SYNTH_RUN_TAG   ?= $(RUN_TAG)
```

**Tools**
```
VIVADO          ?= vivado
VIVADO_VER      ?=                    # when set it is ASSERTED, not assumed
NUM_JOBS        ?= 8
TCLSH           ?= tclsh
```

**Gates** — every `EXPECT_*` defaults to `-1`, meaning *measure and report, do
not gate*, **except the timing budgets, whose unarmed sentinel is EMPTY.**

`EXPECT_WNS_MIN` and `EXPECT_WHS_MIN` are slacks in nanoseconds and a real
budget can legitimately be negative, so `-1` as "unarmed" makes a budget of
exactly -1 ns inexpressible — and, worse, silently unarmed. A count budget
(LUT, FF, BRAM, unrouted nets) cannot be negative, so `-1` is a safe sentinel
there and stays. Found 2026-09-08 by the implementation stage. A project sets the ratchet after a first run, with the measurement
and the margin written down beside it.
```
EXPECT_WNS_MIN        ?=              # EMPTY = unarmed. A slack can be negative,
EXPECT_WHS_MIN        ?=              # so -1 would hide a real -1 ns budget.
EXPECT_LUT_MAX        ?= -1
EXPECT_FF_MAX         ?= -1
EXPECT_BRAM_MAX       ?= -1
EXPECT_DSP_MAX        ?= -1
EXPECT_UNROUTED_MAX   ?= 0
EXPECT_BLACKBOX_MAX   ?= 0
ALLOW_CRITICAL_WARNINGS ?= 0
XDC_BASELINE          ?=              # a ratcheted baseline file
MSG_GATE_ALLOWLIST    ?=              # EMPTY default. See §7.
```

**Deploy** — declaration only; phase 4 wires it.
```
FPGAHUB_BOARD   ?=                    # the board GROUP  (lease scope)
FPGAHUB_TARGET  ?=                    # the TARGET       (program scope)
FPGAHUB_TOML    ?= $(wildcard $(FPGA_DIR)/fpgahub.toml)   # discovered, see below
BIN_STYLE       ?=                    # zynq7 | zynqmp — NOT interchangeable
```

### 3.4 `SYS_CLK_FREQ_HZ` is special

It is compiled into the firmware (`-DNANOSOC_SYS_CLK_FREQ_HZ`) *and* constrains
the bitstream. A build whose firmware and fabric disagree about it produces a
board that boots and gets every baud rate and timer wrong. When both
`SYS_CLK_FREQ_HZ` and a firmware build are configured, `make check` reports them
together.

### 3.5 DERIVED — assigned `:=` after the project is read, NOT settable

```
RUN_DIR       := $(BUILD_DIR)/$(RUN_TAG)
WORK_DIR      := $(RUN_DIR)/work        # projects, checkpoints, tool cwd
LOG_DIR       := $(RUN_DIR)/logs
REPORT_DIR    := $(RUN_DIR)/reports     # manifests, gates, .rpt
OUT_DIR       := $(RUN_DIR)/outputs     # .bit .bin .xsa .hwh .dcp
IN_WORK_DIR   := $(BUILD_DIR)/$(IN_RUN_TAG)/work
SYNTH_OUT_DIR := $(BUILD_DIR)/$(SYNTH_RUN_TAG)/outputs
```

`make check` **warns** if the project assigned any of these — the reference
toolkit's own shipped example does exactly that and the values are silently
discarded.

`mk/flow.mk` must guard the destructive paths before any recipe can run:
`RUN_TAG` empty, containing `/`, or equal to `.` or `..`; `BUILD_DIR` empty,
relative, or `/`. Each `$(error)` names the specific disaster it prevents.

---

## 4. Stage graph and target names

`.DEFAULT_GOAL := help`. `SHELL := /bin/bash`.

```
dirs → flist → package-ip → bd → synth → impl → bitstream
```

| Target | Produces (asserted on) |
|---|---|
| `dirs` | the four run directories, and only those four |
| `flist` | `$(WORK_DIR)/sources.tcl`, `$(REPORT_DIR)/flist_manifest.txt` |
| `package-ip` | `$(OUT_DIR)/ip/<vlnv>/component.xml`, `package_ip_manifest.txt` |
| `bd` | `$(WORK_DIR)/$(DESIGN_NAME).bd`, `bd_manifest.txt` |
| `synth` | `$(OUT_DIR)/$(BLOCK)_synth.dcp`, `synth_manifest.txt`, `utilization_synth.rpt` |
| `impl` | `$(OUT_DIR)/$(BLOCK)_routed.dcp`, `impl_manifest.txt`, `timing_summary.rpt`, `impl_gate.txt` |
| `bitstream` | `$(OUT_DIR)/$(BLOCK).bit`, `.bin`, `.xsa`, `bitstream_manifest.txt` |
| `all` | all of the above |

`all` is **recipe lines calling `$(MAKE)`, not prerequisites.** Prerequisites
carry no ordering, so under `-j` make may start `impl` while `synth` is running.
Scoped `.NOTPARALLEL:` is GNU Make 4.4; the sites here run 4.2.1, where bare
`.NOTPARALLEL` serialises the entire makefile.

`check-quiet` is a prerequisite of **every** stage target.

Meta and verification targets (no EDA licence, or a separate one):
`check`, `check-quiet`, `doctor`, `part-probe`, `board-probe`, `env`, `help`,
`help-all`, `help-knobs`, `status`, `clean`, `distclean`, `xdc-lint`,
`util-census`, `timing-census`, `msg-gate`, `compare-runs`, `flow-state`,
`vivado-shell`, `gui`.

**Post-stage targets.** `<STAGE>_POST_TARGETS` (e.g. `BITSTREAM_POST_TARGETS`)
runs after the stage's own verdict artefact exists. This is where deploy lands.
Failure is **non-fatal to the build, fatal to the claim**: a 90-minute
implementation must not die because a board was busy, but the message is loud
and the run is not "deployed".

Do **not** probe for a target's existence with `make -n` or `make -q` — GNU make
runs `$(MAKE)` recipe lines under both.

---

## 5. Run directory and manifests

Exactly four directories are created: `work logs reports outputs`. Anything else
in a run directory is the project's, not ours.

A stage reads `IN_WORK_DIR` and writes `WORK_DIR`. Handoff is by artefact name
inside `work/`, never renamed. A stage must not be able to address another run's
work directory — enforce it by construction (compose paths from `WORK_DIR`, and
refuse a run tag containing a path separator), not by convention.

Every stage writes `$(REPORT_DIR)/<stage>_manifest.txt`, in this order:

1. **Header** — `date runtime_s stage run_tag host user tool tool_version log_file`
2. **Provenance** — `prov.design.git_{describe,sha,dirty}`; for each input file
   `path / sha256 / bytes`, where a path INSIDE the project, the toolkit or the
   run tree is rewritten to a `<project>/...`-style label (so two runs under
   different build roots compare equal instead of differing in every path
   field) and anything OUTSIDE all three is a site path and appears only as a
   `sha256:` digest; `prov.part.name`, `prov.part.pack_sha256`,
   `prov.board.name`, `prov.board.pack_sha256`. Any site path is recorded as a
   `sha256:` digest, **never** as the raw path — a manifest gets pasted into bug
   reports and a mount point is inventory-shaped disclosure.
3. **Directories** — `work_dir in_work_dir log_dir report_dir out_dir part board`
4. **Both git shas** — `project_git_sha/_dirty` and `toolkit_git_sha/_dirty`
5. **`step_files`** — `synth_setup=toolkit impl_setup=PROJECT OVERRIDE ...`
6. **`hooks_run`** — `pre_synth(2s)` or `(none)`
7. **Every registered knob and its resolved value**, enumerated from the `opt`
   declarations in the flow scripts — *not* a hand-maintained list, which drifts.
   Knobs DECLARED but not read by this stage are emitted too, marked
   `UNVERIFIED:declared-in-<file>-not-sourced-by-this-stage`. Emitting only
   what was read would let a reader diff two stages and conclude they agreed
   about a knob neither of them saw.

Every field is a value or an `UNVERIFIED:<reason>` string. `compare-runs`
**refuses** (exit 2) a comparison where either side is UNVERIFIED, or where the
provenance blocks say the two are not the same design.

### The stage verdict artefact

`$(REPORT_DIR)/<stage>_gate.txt`, fixed section structure:

```
IMPL gate, <date>
design <block>, run tag <tag>, board <board>, part <part>
<a paragraph stating what this check IS and IS NOT>

HARD FAILURES: none            <- the exact string make greps for

BUDGETS EXCEEDED
  - <metric> <n> > budget <b> (<breakdown>)

DECLARED ELSEWHERE - MEASURED HERE, OWNED BY SOMEBODY ELSE
  - <thing>, owner=<who>: <n> ... <report path>

NOT covered by ANY run of this flow, at any setting:
  - <enumerate>
```

Four verdict classes: hard fail / budget exceeded / delegated **with a named
owner** / explicitly not covered. The last two are the honesty mechanism: a
green run still enumerates what it did not measure.

---

## 6. Extension seams

### 6.1 Flow hooks

`$(HOOKS_DIR)/<seam>.tcl` — lower case, underscores, `.tcl`, exact.

**The seam list lives in exactly one place: `flow/common/seams.txt`, one name
per line.** The flow reads it, `fpga-flow-check` reads it, `make help` reads it.
No file may contain a second copy. Phase-1 seams:

```
pre_flist  post_flist
pre_package_ip  post_package_ip
pre_bd  post_bd
pre_synth  post_synth
pre_impl  post_impl
post_bitstream
```

Four required properties:

- **optional** — absent is silent, not an error
- **announced** — print the path and the runtime; a hook that runs invisibly is
  a debugging nightmare
- **able to abort** — an error stops the stage. It is *not* caught and
  downgraded. There is no advisory-hook mode; a hook that does something
  genuinely optional wraps *that part* itself and says why
- **recorded** — the name and runtime land in `hooks_run` in the manifest, so a
  result traces to the project code that shaped it

A file in `hooks/` whose name is not a seam **never runs**. `make check` warns,
naming the file and listing the valid seams — except for plain documentation
(`README*`, a licence, a dotfile, an editor turd), which is skipped. A warning
that fires on every scaffolded project from its first run is worse than no
warning: it teaches the reader to skim the block, and the run where that block
says something real scrolls past unread.

### 6.1.1 A shipped check that is not yet configured

Settled 2026-09-08. A hook the toolkit *scaffolds* carries a declaration table
the project must fill in. Until it is filled in, the hook **refuses** — exit 2,
"nothing was measured" — and says so on every run. It must not pass quietly, and
it must not fail as though it had measured something and found it wrong. The
three honest ways out are stated in the hook itself: declare the expectation,
move the file to a seam you do use, or delete it. Deleting it is a legitimate
answer and the template says so.

An **unknown key** in such a declaration table is **fatal**, not ignored: an
expectation nothing reads is worse than no expectation, because it looks like
cover.

### 6.1.2 Hook configuration lives in the manifest

A project's hook expectations are declared in `design.mk` like any other
contract value, exported to the Tcl layer, and registered through `opt` so they
land in the run manifest. A hook configured by an environment variable nobody
recorded produces a result nobody can reproduce.

### 6.1.3 Intra-stage seam ordering — SETTLED 2026-09-08

**Every `post_*` seam fires BEFORE the stage writes its artefacts, and the
stage's gate is computed AFTER the seam.** The one exception is
`post_bitstream`, which is terminal by definition and may not change the design.

The reasoning, and it is forced rather than chosen:

- A stage hands off to the next one **through a file** — `impl` writes a routed
  checkpoint, `bitstream` reads it. If `post_impl` fired *after*
  `write_checkpoint`, a hook that changed the design would change nothing that
  survives: the checkpoint on disk predates the edit, the next stage reads that
  checkpoint, and the edit is silently discarded. The hook would appear to run,
  be recorded in `hooks_run`, and have no effect.
- Firing before the write gives the opposite and correct property: the
  checkpoint **records what the hook did**, and every downstream stage inherits
  it because it inherits the checkpoint.
- The gate must then be computed after the seam, or it grades a design that no
  longer exists. A verdict on the pre-hook netlist attached to a post-hook
  artefact is exactly the artefact-and-record disagreement this rule exists to
  prevent.

The ASIC toolkit gets this wrong in the one place it matters and documents the
cost: its `post_route` fires after stream-out, a project added pads there, and
it streamed a GDS with no pad ring while every gate passed. Same failure, other
direction — there the hook changed the design and the artefact did not follow;
here it would be the artefact and the hook's effect vanishing. Both come from a
seam on the wrong side of a write.

`post_bitstream` keeps the ASIC trap, explicitly and by design: the `.bit` is
already written, a hook there cannot change what ships, and
`templates/hooks/README.md` says so. It is for publishing, recording and
notifying.

`post_bitstream` carries the reference toolkit's `post_route` trap: the
bitstream is already written. A hook there cannot change the design. Say so in
the template.

### 6.2 Step overrides

`$(OVERRIDES_DIR)/<step>.tcl` replaces `$(FPGA_FLOW_DIR)/flow/steps/<step>.tcl`
**wholesale**. No merging, no partial override — these files set tool properties
in an order that matters and a half-overridden one is a design nobody can reason
about.

**The valid step list is `ls flow/steps/*.tcl`, derived at run time.** Never
hardcoded. Which override is active is logged and lands in `step_files` in the
manifest, and `make check` warns whenever any override is active.

### 6.3 Prerequisite append

A project appends work to a stage with a **recipe-less** rule:

```make
synth: my-project-gate
```

Documented hazards, which the templates must state:
- the fragment must be included **after** `mk/flow.mk`, or the target does not
  yet exist
- a second **recipe** silently replaces ours; make says so only as a warning
- an include guard cannot see a target collision — the only protection is a
  manual name check, redone whenever a target is added
- prerequisites of one target may run in any order under `-j`

---

## 7. Gates, verdicts and evidence

`ci/lib.sh` provides five emitters. Gate ids are `<tier>.<subject>[.<detail>]`,
lower case, dot separated, **stable across runs, meant to be grepped**.

| Helper | Counts as |
|---|---|
| `ci_pass <id> [detail]` | PASS |
| `ci_fail <id> [detail]` | FAIL |
| `ci_unverified <id> <why>` | **FAIL** — a check whose input it could not read has not passed; it has not run |
| `ci_warn <id> <detail>` | reported, never red |
| `ci_skip <id> <why>` | recorded — a tier silently checking nothing is how a green run comes to prove nothing |

`verdicts.tsv`, append-only, tab-separated, four columns:
`<ISO8601 UTC>\t<PASS|FAIL|UNVERIFIED|WARN|SKIP>\t<gate.id>\t<detail>`

`ci_exit` is non-zero when **any** gate failed — deliberately not the last
command's status.

`ci_assert_file` distinguishes **absent** from **zero bytes**. A zero-byte
artefact is the shape a tool leaves when it opened its output and then died, and
it satisfies every `test -e` in the world.

**Every allowlist defaults EMPTY.** A default that tolerates message IDs hands
each new project someone else's undiagnosed exemptions. Every entry carries a
paragraph of diagnosis and an owner.

**A check that cannot fail is not a check.** Every gate ships a selftest that
plants the fault in a throwaway copy and requires the check to go red. See §10.

---

## 8. Part and board packs

A pack is **exactly one file**, `source`d as plain Tcl, not parsed — it may
compute, glob and read vendor files at load time. Validated against a
declarative schema table of rows `KEY REQUIRED TYPE GROUP {DESCRIPTION}`.

Rules, all carried from the reference tech pack because each prevents a measured
failure:

- an unknown key is an **error** with a nearest-match suggestion, never a
  silent default
- setting a key **twice** is an error — that is copy-paste damage, not intent
- a missing required key errors listing **every** problem at once with each
  key's description. The cycles are where people give up and start guessing
- reading an **unset optional** key errors rather than returning `""` — an empty
  primitive name silently instantiates nothing
- **no site path is ever defaulted.** Vendor roots arrive through
  `part_env NAME purpose`, which records every resolution attempt, resolved or
  not. A fallback to one lab's mount is a path that works on one machine and
  fails silently-looking everywhere else
- a derived key whose source was unreadable stays **unset with a recorded
  reason**: `part_has` → 0, `part_get` → error naming the file

### Part pack (toolkit) — `part/<part>/part.tcl`

Required: `part_name family device package speed_grade vendor global_buffer
min_vivado_version`

Optional, with **conditional cascades**:

| Trigger | Then required |
|---|---|
| `has_ps` true | `ps_type`, `ps_clk_config` |
| `idelay_available` true | `idelay_primitive`, `idelay_ref_freq_hz` |
| `slrs` > 1 | `slr_topology` |
| `has_mmcm` true | `mmcm_primitive` |

Other keys: `luts ffs brams dsps urams clock_regions io_banks clock_buffer_ce
pll_primitive io_buffer_primitive bitstream_compress`

**`cfgbvs` and `config_voltage` are BOARD keys, not part keys** — corrected
2026-09-08. They follow how config bank 0 is *wired*, which is a fact about a
PCB, not about a die. They were listed here first; all three shipped part packs
correctly declined to set them, and because an unknown key is an error, nothing
could state them at all. The DRC they satisfy (`CFGBVS-1`) is only a warning, so
the symptom would have been a permanent warning nobody could clear.

### Board pack (project) — `fpga/board/<board>/board.tcl`

Required: `board_name part platform sys_clk_freq_hz bin_style`

| Trigger | Then required |
|---|---|
| `board_part` set | `board_repo_paths` |
| `bin_style` = `zynq7` or `zynqmp` | (nothing — but they are NOT interchangeable; the wrong one corrupts the load) |
| `fpgahub_board` set | `fpgahub_target` — **the lease scope and the program scope are different namespaces** |

Other keys: `deploy_style jtag_serial oscillator_hz io_voltage_by_bank
connectors cfgbvs config_voltage`

### Accessors

Pack-facing: `part_set part_unset part_note part_env part_defer part_derived_dir`
Engine-facing: `part_load part_validate part_get part_has part_opt part_require
part_keys part_summary` — and the same set spelled `board_*`.

The engine must reach both through **one shim** that owns an alias table, so a
pack spelling a key differently is a table entry rather than forty call sites.

That table is **validated against the schema when the shim binds** — which is
the earliest moment it can be, since `flow_utils.tcl` is sourced before the pack
API and has no schema to check against when the table is declared. A row whose
target is not a key, whose *name* is a key (so it can never fire), that maps a
name to itself, or that duplicates a spelling `pack_api.tcl`'s own pack-facing
table already resolves, is refused with what to delete. **No spelling may stand
in both tables.** The two tables answer different questions — what a *pack
writes* versus what a *stage asks for* — and stay separate; what is forbidden is
the same spelling appearing twice, one copy of it doing nothing. A dead alias is
invisible rather than wrong-looking, which is how `device → part_name` survived
in that table reading as a promise that `part device` returns the full part
string when the schema declares `device` as the bare die.

---

## 9. Facts about this codebase that constrain the design

These were measured on 2026-09-08 and are not negotiable design inputs.

1. **There is no `` `ifdef FPGA `` and no `` `ifdef ASIC ``** — zero hits across
   13,524 RTL files, along with `XILINX`, `VIVADO`, `SIMULATION`, `FPGA_ONLY`.
   A flow that configures the build with `+define+FPGA` configures nothing.
   Selection is by **flist file-swap** (four wrapper families: `tidelink_sram`,
   `ethmac_sram`, `sl_ahb_sram`/`sl_ahb_rom`, `cache_ram` — same module name,
   opposite directory) and by **module parameters**.
2. **`ipx::package_project` drops fileset defines** by three separate routes. It
   failed silently once already: an `` `ifdef TIDELINK_USE_IDELAY `` opt-in was
   false in *every* FPGA build, proven by a byte-identical "IDELAY-off"
   bitstream. Parameters survive packaging as `CONFIG.*`; defines do not. Hence
   `RTL_PARAMS` is the primary mechanism and `RTL_DEFINES_INBODY` exists at all.
3. **Vivado drops a constraint that matches nothing without an error.** Only one
   flow in the tree gates on it. `xdc-lint` is not optional here.
4. **A DRC-waiver XDC cannot be `read_xdc`'d** — Vivado rejects procedural Tcl
   in an XDC. It must be `source`d after `route_design`. Hence `XDC_POST_ROUTE`.
5. **`.bin` conversion is board-family dependent** — Zynq-7000 needs a byte
   swap, ZynqMP needs a header strip. Interchanging them corrupts the load.
   Hence `BIN_STYLE` is a required board-pack key.
6. **`doctor` reports what is on the FILESYSTEM, never what a modulefile
   claims — and it must search where the modulefiles point, not a hardcoded
   root.** Corrected 2026-09-08: this clause used to name the two Vivado
   versions it believed were installed. That was wrong, and wrong in an
   instructive way — it had been written by looking in ONE vendor root while
   the other two versions lived under a second one. `fpga-flow-doctor` derives
   its search roots from the site's modulefiles and had all four right the whole
   time; the contract was the thing that had guessed.

   The literal paths that used to be in this paragraph have been removed, and
   that removal is the rule restating itself: this repository's own vendor
   scanner flagged them on the first run before publication. An absolute path
   into a vendor install is a site fact — wrong on every other machine, and a
   statement about what this site holds. Do not re-introduce one here or
   anywhere else, including in prose that is warning against them.
7. **fpgahub's board-group and target namespaces do not overlap.** Leases,
   queues and reservations address the board group; program, reset and actions
   address a target. Conflating them returns 404.
8. **The eth chiplet's FPGA flow currently lives in the `tidelink` submodule and
   reaches *up*** via `$(realpath $(TIDELINK_HOME)/..)`. Phase 2 reverses that.
   Nothing in this repository may reach up out of the project.

---

## 10. House style

**Scripts.** Named `fpga-flow-<verb>`, in `scripts/`, **never put on `PATH`** —
every call site is `$(FPGA_FLOW_DIR)/scripts/<name>` assigned to a `*_SCRIPT`
variable at the top of its fragment. They are addressable artefacts, not
commands, and each resolves its own location rather than trusting `cwd`.

Python: **stdlib only** — these run on EDA hosts with no pip. `sys.exit(main())`.
`except KeyboardInterrupt: sys.exit(130)`. Never `exit 0` on a crash.

Shell: `set -uo pipefail` (**not** `-e`), `HERE="$(cd "$(dirname
"${BASH_SOURCE[0]}")" && pwd)"`, and `usage()` printed by `sed`-ing the file's
own header comment so help cannot drift from the file.

**Exit codes.** `0` ok · `1` a check failed · `2` refused / unusable input /
crash · `75` `EX_TEMPFAIL` (lock contention) · `130` SIGINT.

**`1` and `2` are "we looked and found something" versus "we could not look",
and a caller is entitled to tell them apart.** Settled 2026-09-08. §7's verdict
model folds `UNVERIFIED` into FAIL so that a run cannot go green on evidence it
never read — that is right for a *ladder*, where the only question is whether
the run may proceed. It is not right for a *scanner*, whose caller has to decide
between refusing a commit and reporting that the guard itself is broken. So:
`ci_exit` keeps §7's model, and a gate that must distinguish the two returns `2`
for "could not measure" directly. Both are failures; only one is the author's
fault.

**Docstring shape**, universal:
```
<name> - <one-line purpose>
<usage synopsis>
WHY THIS EXISTS: <a measured defect, with real numbers>
Exit status: ...
```

**Every `<x>` gate ships an `<x>-selftest`** that plants the fault in a
throwaway copy and requires the check to go red, and an **`<x>-vars`** that
prints what it would do without doing any of it. `<x>-vars` must contain no
backticks — in the reference toolkit a backtick inside a double-quoted shell
word ran the entire evidence flow from the target whose only job was to report
what *would* happen.

**Comment style.** Headers explain *why*, with the measured defect that
motivated the code. Match the reference toolkit's density and tone; it is the
house voice and it is load-bearing documentation.

**Copyright footer on every file:**
```
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
```

---

## 11. Phase 1 acceptance

Phase 1 is done when, with **no EDA tool installed or launched**:

1. `make help` prints a curated, ordered target list.
2. `make env` prints engine / this run / project contract, with `(none)`
   rendered explicitly rather than as a blank. Those three blocks are required;
   the recipe also prints a fourth, `gates and post-stage targets`, which is
   additive and fine. The test asserts the three required ones and does not
   forbid more - a contract that pinned the exact block COUNT would make adding
   a section a breaking change for no reader's benefit.
3. `make check` on a project scaffolded by `fpga-flow-init` reports its
   `<<FILL IN>>` markers and exits non-zero.
4. `make check` on a **real** project manifest describing
   `kr260-eth-chiplet` resolves every input that today's `tidelink/fpga` build
   consumes, and exits 0.
5. `make doctor` reports host capability honestly: every Vivado the
   modulefiles advertise is checked against the filesystem, wherever it actually
   lives, and any advertised-but-absent version is named.
6. `make part-probe` / `make board-probe` load and validate the packs.
7. `test/run.sh` passes, and every assertion in it is paired with a mutation
   proof that the assertion goes red on a planted fault.
8. Nothing in this repository names a board, a pin, or a project path.

---

## 12. Stage scripts — `flow/vivado/*.tcl`

Six files, one per stage, named `1_flist 2_package_ip 3_bd 4_synth 5_impl
6_bitstream`. `mk/flow.mk` invokes them through `vivado_stage`, which exports
`FPGA_STAGE`, `FPGA_STAGE_T0`, `FPGA_LOG_FILE` and `FPGA_TOOL_HINT` on top of
the standing `FPGA_*` set.

### 12.1 The skeleton every stage follows

```tcl
source [file join $env(FPGA_FLOW_DIR) flow common flow_utils.tcl]
flow_boot                                  ;# env, part pack, board pack, config
opt STAGE_KNOB default ;# what it does     ;# knobs, at the left margin
... set up everything the stage's work needs: sources, constraints,
    generics, tool properties ...
flow_hook pre_<stage>                      ;# seam - see below
... the tool command the stage exists to run (synth_design, route_design, ...)
... the work, in flow_step units where a project may reasonably override ...
flow_hook post_<stage>                     ;# seam, BEFORE the writes (§6.1.3)
... write artefacts ...
<stage>_gate                               ;# the verdict, AFTER the seam
<stage>_gate                               ;# via prov_gate, see 12.4
prov_manifest <stage> ?<stem>?             ;# last
```

**Where `pre_<stage>` fires, corrected 2026-09-08.** An earlier draft put it
immediately after the knob declarations, before the stage had set anything up.
That makes the shipped `templates/hooks/pre_synth.tcl` impossible: its entire job
is to assert that a declared parameter or define ACTUALLY REACHED the design,
which cannot be asked before the generics and sources have been applied. So
`pre_<stage>` fires **after the stage has prepared its inputs and immediately
before the tool command it exists to run** — late enough to inspect what the
tool is about to be given, early enough to stop it.

That is the useful reading of "pre": before the work, not before the setup. A
seam that fires before anything has been configured can only see the defaults,
and a hook that can only see defaults cannot check anything a project cares
about.

### 12.2 Rules

1. **Assert on artefacts.** A stage ends by checking that what it was supposed
   to write is on disk and says what it should. Never `if {[catch ...]}` around
   a Vivado command as the only check — Vivado exits 0 on a failed route.
2. **Every knob is an `opt`**, at the left margin, so `make help-knobs` and the
   manifest both find it without a hand-maintained list.
3. **A step a project might reasonably replace goes through `flow_step`**, and
   its file goes in `flow/steps/`. The five that exist are the starting set.
4. **The engine sets the XDC read window** from the variable that named the
   file (§3.3) — the project never sets `USED_IN_SYNTHESIS`.
5. **`XDC_POST_ROUTE` is `source`d after `route_design`**, never `read_xdc`'d.
6. **Nothing reaches out of the project.** No `../..`, no `$env(HOME)`.
7. **A stage that is not configured writes a manifest saying so** and exits 0.
   `ci/assert-stage.sh` distinguishes "not configured" from "configured and
   produced nothing"; it can only do that if the first case leaves a record.
8. **`RTL_DEFINES_INBODY` is delivered by materialising modified copies** into
   `$WORK_DIR`, never by `set_property verilog_define` — see §9.2.

### 12.4 The two procs a stage records itself with

`provenance.tcl` owns both. A stage that writes its own is duplicating them —
which is how six copies of each came to exist before this was written down.

```tcl
prov_stage_field  <key> <value>      ;# one measurement. Blank -> `unmeasured`
prov_stage_get    <key>              ;# read back; `unmeasured` when absent
prov_stage_fields <manifest> ?<k v>? ;# append block 8
prov_gate <stage> <stem> <paragraph> <hard> <budgets> <delegated> <notcovered>
```

The four gate lists are **positional and required**: a stage with nothing in a
class writes `{}` and means it, because an absent section is not an empty one
and a consumer must be able to tell them apart.

**`unmeasured` is the only spelling.** `(none)` is NOT a synonym — `ci/lib.sh`'s
`CI_UNMEASURED_RE` matches the first and not the second, so a stage emitting
`(none)` for something it failed to measure is graded as having measured it. The
two halves of the flow disagreed on exactly this before they were merged, and
one of them would have passed `assert-stage` green on a number nobody took.
`(none)` stays reserved for a value a caller explicitly chose to be nothing.

**A gate bullet may not contain a newline.** `assert-stage`'s parser ends a
section at `/^[A-Z]/`, so a bullet whose continuation starts at column 0 with a
capital terminates its own section and silently drops every later bullet in it.
`prov_gate` flattens whitespace to prevent it.

### 12.5 Stage name and artefact stem are two things

`prov_manifest` and `prov_gate` take both because they cannot be derived from
each other. The `stage` FIELD carries the stage name as CONTRACT §4 spells it
(`package-ip`); the FILENAME uses the artefact stem (`package_ip_manifest.txt`).
Passing one string for both is unsatisfiable: `package_ip` makes `assert-stage`
fail ("says stage 'package_ip', not 'package-ip'") and `package-ip` puts the
file where nothing looks. The stem is not computed from the stage — the
artefact names are a list §4 fixes, and a proc that guessed would be a second
place that list lived.

### 12.3 The gate file

Each stage writes `$REPORT_DIR/<stage>_gate.txt` in the §5 structure. `impl`'s
is required; the others are written when the stage has something to grade.
`HARD FAILURES: none` is the exact string `mk/flow.mk` greps for, so it is
load-bearing punctuation.
