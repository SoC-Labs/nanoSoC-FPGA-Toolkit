# `part/` — the pack API, and the part packs

This directory holds `pack_api.tcl` — the contract every **part pack** and every
**board pack** implements — and one directory per device that ships with the
toolkit.

```
part/
  pack_schema.tcl           the schema: WHAT a pack may declare
  pack_api.tcl              the loader, the validator, both APIs, the cross-checks
  README.md                 this file
  xc7z020clg400-1/part.tcl  Zynq-7000    XC7Z020   CLG400  -1
  xck26-sfvc784-2LV-c/      Zynq US+     XCK26     SFVC784 -2LV c
  xcku115-flvb1760-1-c/     Kintex US    XCKU115   FLVB1760 -1 c
  xcvu19p-fsva3824-2-e/     Virtex US+   XCVU19P   FSVA3824 -2 e
```

There is no list of installed packs written down anywhere, here included. The
directory is the authority: `fpga-flow-part-probe` with no argument prints what
is installed by scanning for directories holding a `part.tcl`, and `part_load`
enumerates the same way when it is given a name it cannot resolve. CONTRACT.md
section 0, third rule.

---

## 1. What a pack is

A pack is **exactly one file**, `source`d as plain Tcl. It is not parsed, so it
may compute, glob and read vendor files at load time — and then it is
**validated against a declarative schema** before anything can read a value out
of it.

| | Part pack | Board pack |
|---|---|---|
| Answers | facts about a **device** | facts about a **circuit board** |
| Ships in | this toolkit, `part/<part>/part.tcl` | the **project**, `fpga/board/<board>/board.tcl` |
| Example | how many SLRs, which MMCM primitive exists | which device is soldered down, what the oscillator runs at |
| Scaffolded by | nobody — you write it from a device census | `fpga-flow-init`, from `templates/board.tcl.in` |

The test for which side a fact belongs on: **would it still be true of a
completely different board carrying this device?** If yes it is a part fact. If
no it is a board fact, and putting it here breaks the split that lets a project
state its target without editing this repository (CONTRACT.md section 1).

### A pin, an IO standard or a board name under `part/` is a bug

Not a style preference — those three are the exact shapes that make a part pack
project-specific, and each has an obvious home:

| Fact | Belongs in |
|---|---|
| a pin number, a port-to-pin assignment | `fpga/targets/<target>/*.xdc` |
| an IOSTANDARD | the same XDC — it is a design meeting a board |
| what voltage a bank is supplied at | the board pack, `io_voltage_by_bank` |
| a board or SOM name | the board pack, `board_name` |

The device census this pack reads *does* carry an `IO_STANDARDS` property, and
it is deliberately not recorded: a list of standards the silicon can support is
one substitution away from being read as a list of standards a design may use,
and the second is a board question. What the part packs do record is
`io_bank_types` — HR, HP, HD, PSS, MGT per bank — which is the silicon fact that
actually constrains a design, because an HD bank has no IDELAY no matter what
the board does.

---

## 2. One engine, two roles

`pack_api.tcl` implements **one** schema-driven engine, over the tables in
`pack_schema.tcl`. Every command is
`pack_<verb> <role> ...`; the two public families are `interp alias` lines at
the bottom of the file:

```tcl
interp alias {} part_get  {} pack_get  part
interp alias {} board_get {} pack_get  board
```

Everything that differs between a device and a board is a **table**, never a
code path: `::pack_schema_spec(<role>)`, `::pack_cascade_spec(<role>)`,
`::pack_enum_spec`, `::pack_alias_spec`, `::pack_file_name(<role>)`. The engine
branches on the role name in exactly two places, both commented as such — where
a pack root is searched (part packs are in the toolkit, board packs are in the
project) and in the physical-primitive cross-check, which is a device concept
with no board analogue.

**Why not two files.** CONTRACT.md section 8 specifies identical semantics for
both roles. Identical semantics written twice do not stay identical: the
reference toolkit's equivalent validator is ~1,400 lines, and a copy-pasted
second one takes the first bug fix and not the second. The day they disagree, a
board pack is being validated by rules a part pack is not, and nobody finds out,
because nobody diffs two validators.

### The commands

Pack-facing — what a `part.tcl` or `board.tcl` calls:

```
<role>_set <key> <value>            state a fact
<role>_unset <key>                  withdraw one computed earlier in the file
<role>_note <text>                  free text into the run manifest
<role>_env <VAR> <purpose>          resolve a site path, recording the attempt
<role>_defer ?-permanent? <k> <s>   a value this pack cannot produce, with why
<role>_derived_dir                  where to write something derived
```

Engine-facing — what the flow and the scripts call:

```
<role>_load <spec> ?<root>?         source it and validate it
<role>_validate                     collect and report EVERY problem
<role>_get <key>                    the value, or an error. Never ""
<role>_has <key>                    1 / 0
<role>_opt <key> <default>          for genuinely optional behaviour only
<role>_require <keys> ?<who>?       a stage asserts what it needs, up front
<role>_keys ?<group>?               declared keys, optionally by group
<role>_summary ?<fh>?               the manifest block
<role>_check_files ?<strict>?       can THIS HOST resolve everything?
<role>_gaps                         what the pack says it cannot obtain anywhere
<role>_env_report                   every <role>_env attempt, queryable
<role>_primitive_status <prim>      physical | retargeted <to> | rejected | unknown
<role>_is_deferred / _deferral_note / _nearest / _pack_name / _pack_file / _reset
```

`flow/common/flow_utils.tcl` wraps `part_get`/`part_has` in its own
engine-facing shim (`part`, `part_have`, `board`, `board_have`) with a second
alias table. That table is for what a *stage script* asks for; the one in
`pack_api.tcl` is for what a *pack* writes. They are different questions and are
deliberately not shared.

> **They are not shared, and no *spelling* may stand in both.** The sharp edge
> that used to be recorded here — `::part_alias` mapping `device` → `part_name`,
> a row that could never fire because this schema declares `device` as a key in
> its own right — is closed. `flow_pack_alias_check` now validates that table
> against `<role>_keys` when the shim binds, which is the first moment in the
> boot path where both the table and this schema exist, and refuses four shapes:
> a target this schema does not declare, a name that *is* a key here, a name
> mapped to itself, and a name `::pack_alias_spec` below already canonicalises.
>
> That last one is why the engine-facing table is now one row long. Five of its
> six rows were spellings this file already resolved, and deleting them changed
> nothing any stage can observe. **If you add a row to `::pack_alias_spec` for a
> spelling `flow_utils.tcl` also carries, the flow will refuse to boot until one
> of the two is deleted** — and the refusal says which file to edit. That is the
> intended behaviour: two places to read a spelling, one of them doing nothing,
> is how the `device` row survived.

---

## 3. The rules, and what each one prevents

All six are from CONTRACT.md section 8, and each is carried from the reference
toolkit because it prevented a measured failure there.

| Rule | What it stops |
|---|---|
| an unknown key is an **error**, with a nearest-match suggestion | `part_set mmcm_primitve MMCME4_ADV` silently setting nothing. A setting that does nothing and says nothing is this flow's most expensive recurring defect |
| setting a key **twice** is an error | copy-paste damage reading as intent |
| a missing required key reports **every** problem at once, each with its description | five edit-and-rerun cycles, which is where people give up and start guessing |
| reading an **unset optional** errors rather than returning `""` | an empty primitive name instantiating nothing; an empty path concatenating into a plausible wrong one |
| an empty string in a `str` key is an error | a blank value being *read as a value* rather than erroring like an absent one |
| **no site path is ever defaulted** | a fallback to one lab's mount: a path that works on one machine and fails silently-looking everywhere else |

### Site paths: `<role>_env`

```tcl
board_set board_repo_paths [board_env MY_BOARD_FILES "the vendor board files"]
```

Every call is recorded — resolved or not — in a queryable structure
(`<role>_env_report`), because "can this pack load here" and "which collateral
did this run actually read" are different questions and it was the second that
mattered when two reports built from two different mounts were compared as
though they described one thing.

With `FPGA_PACK_ALLOW_MISSING_ENV=1` (or the role-specific
`FPGA_PART_ALLOW_MISSING_ENV` / `FPGA_BOARD_ALLOW_MISSING_ENV`) an unresolved
variable becomes the literal marker `<unset:VAR>` instead of aborting the load.
That marker is greppable, is never a valid path, and cannot be mistaken for a
resolved value the way `""` can. It exists so `fpga-flow-part-probe` can *report*
a missing mount instead of just failing to load.

### Deferrals: `<role>_defer`

A pack that can read a vendor number reads it, at load time, from the file the
site already has — shipping the transform rather than the result, because a
number copied into Tcl goes stale on the next tool release and nothing ever
re-checks a number in a comment. `<role>_defer` is what a pack says when it
**cannot**:

```tcl
board_defer board_repo_paths {
    set root [board_env MY_BOARD_FILES "the vendor board files"]
    if {![file isdirectory $root]} { error "not a directory: $root" }
    return $root
}
```

The script runs when the key is first **read**, not when the pack loads — most
runs never touch most keys. If it cannot produce a value the key stays **unset
with a recorded reason**: `<role>_has` answers 0, `<role>_get` raises an error
quoting the script's own message, and no stage ever receives a fabricated value.
A deferred key is not counted as missing by the validator; it is reported by
`<role>_check_files` and by the probe.

**Two scopes, and the probe's verdict turns on which:**

* *(default)* **host-contingent** — this machine could not read something.
  Another host can. The probe goes red; a mount or an export fixes it.
* `-permanent` — a gap in the **data**, not in the host. Nothing anyone can
  mount will resolve it. The probe **prints it and stays green**.

The second exists because CONTRACT.md section 0 requires an unmeasured number to
be emitted as `unmeasured` rather than as 0 or nothing, and section 5 requires a
green verdict to enumerate what it did not measure. Without it, every honest
pack would be red for ever, `make part-probe` would be a check nobody could
pass, and the first thing anybody reached for would be deleting the deferral and
writing a plausible number — which is the defect this whole file exists to
prevent.

---

## 4. THE POINT OF THE PART PACK: physical vs accepted primitives

**Vivado silently retargets legacy 7-series primitives on UltraScale and
UltraScale+.** Measured on this host with Vivado v2024.1, `create_cell` on a
linked design:

| You ask for | on `xc7z020` (zynq) | on `xck26` (zynquplus) | on `xcku115` (kintexu) |
|---|---|---|---|
| `MMCME2_ADV` | **physical** | → `MMCME4_ADV` | → `MMCME3_ADV` |
| `PLLE2_ADV` | **physical** | → **`MMCME4_ADV`** | → **`MMCME3_ADV`** |
| `IDELAYE2` | **physical** | → `IDELAYE3` | → `IDELAYE3` |
| `BUFHCE` | **physical** | → `BUFGCTRL` † | → `BUFGCTRL` † |
| `RAMB36E1` | **physical** | → `RAMB36E2` | → `RAMB36E2` |
| `DSP48E1` | **physical** | → `DSP48E2` | → `DSP48E2` |
| `ISERDESE2` | **physical** | *rejected* | *rejected* |
| `IOBUFE3` | *rejected* | **physical** | **physical** |

The fourth pack, `xcvu19p-fsva3824-2-e` (virtexuplus), was read on **2026-09-17**
and agrees with the `xck26` column on every row above **except the two marked
†** — see the next section, which is no longer about one anomaly.

Every retarget succeeds and prints one `[Coretcl 2-1024]` warning into a log
with thousands of lines. Two of them are not renames at all:

* **`PLLE2_ADV` does not become the local PLL — it becomes the MMCM.** On
  `xck26` there are 8 PLLs and 4 MMCMs, so a design that believes it is spending
  one of eight is spending one of four, and never touches the resource it
  thought it was using. On `xcku115` the same primitive lands on `MMCME3_ADV`:
  a design moved between the two parts is silently retargeted to a *different*
  wrong cell each time.
* **`BUFHCE` becomes `BUFGCTRL`, which has no clock enable.** The gating the
  design asked for is gone, and nothing downstream reports a missing enable —
  as far as the netlist is concerned there was never one.

So the schema encodes the distinction rather than trusting the author:

```tcl
part_set mmcm_primitive MMCME4_ADV                 ;# the PHYSICAL one
part_set primitives_retargeted {MMCME2_ADV MMCME4_ADV  PLLE2_ADV MMCME4_ADV ...}
part_set primitives_rejected   {BUFR BUFMR PS7 ISERDESE2 OSERDESE2 XADC}
part_set primitive_sites       {BUFGCE 96 BUFGCTRL 32 ...}   ;# the evidence
```

`::pack_physical_primitive_keys` lists every key whose value must name a real
site or BEL — `global_buffer`, `clock_buffer_ce`, `clock_buffer_div`,
`mmcm_primitive`, `pll_primitive`, `idelay_primitive`,
`idelay_control_primitive`, `io_buffer_primitive`, `serdes_primitive`,
`bram_primitive`, `dsp_primitive`, `uram_primitive`, `sysmon_primitive`,
`gt_primitive`, `ps_type` — and the validator **refuses a pack that names a
merely-accepted or a rejected primitive in one of them**, saying what the design
would really get. One list, so adding a primitive key to the schema and
forgetting to protect it is one omission rather than a silent one.

`part_primitive_status <prim>` answers the same question at run time:
`physical`, `{retargeted <what-it-becomes>}`, `rejected`, or `unknown`.

### The anomaly, recorded rather than smoothed over — and then NOT REPRODUCED

On 2026-09-08, on `xck26` and `xcku115`, the two measurements disagreed about
`BUFGCE`:

```
create_cell -reference BUFGCE            ->  warning, retargeted to BUFGCTRL
get_sites -filter {SITE_TYPE == BUFGCE}  ->  96 sites (576 on xcku115)
```

A device with 96 `BUFGCE` sites has a physical `BUFGCE`; the retarget message
describes Coretcl's netlist cell-type list for a linked design with no netlist,
not the site census, and the site census is what "physical" means here. So
`clock_buffer_ce` is `BUFGCE`, `BUFGCE` is **not** in `primitives_retargeted` —
listing it would make the validator reject the correct value — and both packs
carry a `part_note` saying exactly this. Neither measurement has been dropped.

**On 2026-09-17 the anomaly did not reproduce, and the `BUFHCE` row went with
it.** The `xcvu19p` census ran the same probe, and then re-ran it against
`xck26` in the same hour as a calibration — which reproduced every *other*
number in that pack exactly, properties, sites and BELs:

| `create_cell -reference` | 2026-09-08, `xck26`/`xcku115` | 2026-09-17, `xcvu19p` **and** `xck26` |
|---|---|---|
| `BUFGCE` | → `BUFGCTRL` (the anomaly) | **physical**, no warning |
| `BUFG` `BUFH` `BUFHCE` `BUFIO` | → `BUFGCTRL` | → **`BUFGCE`** |
| `BUFGMUX` | → `BUFGCTRL` | → `BUFGCTRL` (agrees) |

Both sessions used Vivado v2024.1, SW Build 5076996. What differed between them
is **not recorded in either `facts_source`** and the 2026-09-08 raw output was
not kept, so this is written down rather than resolved. It matters because the
two readings disagree about the sharpest claim in this file: under the 09-08
reading a `BUFHCE` loses its clock enable silently, and under the 09-17 reading
it keeps one. The safe instruction is unchanged either way — **name `BUFGCE`**,
which is a site on every UltraScale(+) part here under both readings — and that
is what every pack's `clock_buffer_ce` says.

The shipped packs have **not** been rewritten to the newer reading. Each states
what its own session measured, with its own date, which is the only way the
disagreement stays visible; the `xcvu19p` pack's section 5 carries the same
comparison from the other side.

---

## 5. Three keys CONTRACT.md lists that the shipped packs leave unset

CONTRACT.md section 8 lists `cfgbvs`, `config_voltage` and `bitstream_compress`
among the part-pack keys. All three are registered in the schema — the contract
is the interface — and all three are **deliberately unset in every pack here**:

* `cfgbvs` and `config_voltage` follow how **bank 0 is wired on the board**.
  XC7Z020 supports a 3.3 V and a 1.8 V bank-0 supply; which one is in front of
  you is a PCB fact. A part pack stating it would be stating something it cannot
  know, and by the test in section 1 it is a board fact.
* `bitstream_compress` changes the **file**, not the silicon. It is a build
  setting and belongs to the project.

Reading any of them errors and names the key, which is a better outcome than
reading a default somebody assumed. **This is a disagreement between the code
and CONTRACT.md and it is being named rather than silently picked** (the rule at
the top of CONTRACT.md): if the contract intends these as part-pack keys, the
two voltage ones should move to the board pack alongside `io_voltage_by_bank`,
and `bitstream_compress` should become a `design.mk` knob.

---

## 6. Writing a new part pack

1. **Get the facts from the install, not from a datasheet.** No licence is
   needed and nothing is built. What the shipped packs were read with, on
   2026-09-08, Vivado v2024.1:

   ```tcl
   # device properties
   foreach p [list_property [lindex [get_parts <part>] 0]] {
       puts "$p = [get_property $p [lindex [get_parts <part>] 0]]"
   }
   # site / BEL / bank census - in memory, no project
   link_design -part <part> -name probe
   llength [get_clock_regions] ; get_iobanks ; llength [get_slrs]
   get_sites -filter {SITE_TYPE == BUFGCE}
   get_bels  -of_objects [get_sites ...]
   # primitive acceptance: does this name survive, and as what?
   create_cell -reference MMCME2_ADV probe_cell
   ```

   `link_design` costs about 35 seconds per part. Do all three queries in one
   session and keep the raw output — the pack's `facts_source` key names the
   tool, the build and the date so the run can be repeated.

2. **Record what the census actually said**, including anything that disagrees
   with itself, in `primitive_sites` / `primitive_bels` and a `part_note`. Two
   numbers that reconcile are evidence the census was read rather than
   transcribed: on `xcku115`, 1900 `BUFCE_LEAF_X16` sites × 16 = the 30400
   `BUFCE_BUFCE_LEAF` BELs, and both are recorded.

3. **Defer everything the install does not state.** `-permanent` when no host
   would answer it. Never write a plausible number: three months later a
   plausible number is indistinguishable from a measured one.

4. **Run the probe and the getter:**

   ```
   scripts/fpga-flow-part-probe part/<your-part>
   scripts/fpga-flow-part-get --part part/<your-part> --all
   ```

5. **Plant a fault and check it goes red.** The pack API's rules are only worth
   anything if they fire — CONTRACT.md section 10. Copy the pack to `/tmp`,
   break one thing, and confirm the load fails: a typo'd key, a duplicated
   `part_set`, a deleted required key, `has_ps` true with `ps_type` removed, and
   above all a legacy primitive in a `*_primitive` key.

There is **no table of keys in this README**. The schema in `pack_schema.tcl` is
the only copy, each row carries the description the validator prints, and
`part_keys <group>` or `fpga-flow-part-get --part <p> --all` enumerates it. The
reference toolkit keeps a documentation table beside its schema and its own
comments record the cost: registering a key became "three places, not one", and
for a while a key the engine already read could not be set by a pack at all.
Groups, which are stable: `identity capacity clocking io ps primitives config`
for the part role, `identity clocking deploy vendor board` for the board role.

---

## 7. The scripts

```
scripts/fpga-flow-part-get    [--part|--board <spec>] <key> ...   |  --all
scripts/fpga-flow-part-probe  [-q] [--role part|board] [<pack>]
```

`fpga-flow-part-get` prints `<key> <value>` lines and **prints nothing at all if
any key is missing**, exiting 1. A partial answer is the dangerous shape: a
caller reading line by line takes the values it got and silently defaults the
rest, which is the "unset optional is an error" rule defeated one process
boundary away. It loads the pack and nothing else — no `flow_boot`, no run
directory, no project.

`fpga-flow-part-probe` asks the **pack** whether this host can read it, never
the filesystem. It sets the allow-missing escape hatch so an unset site variable
becomes a finding rather than a crash, and it **leads with the distinct variable
names** lifted out of the report: one unset variable explains twenty missing
paths, and in the full report those names are the least visible part of the
message. Exit 0 everything resolves (recorded gaps are printed and do not change
that), 1 a file or a site variable or a host-contingent derivation, 2 the pack is
absent or will not load.

Neither script is ever put on `PATH`; both resolve their own location and are
called as `$(FPGA_FLOW_DIR)/scripts/<name>` (CONTRACT.md section 10).

---

## 8. Where the contract is thin

Recorded here rather than resolved, per the rule at the top of CONTRACT.md.

1. **`idelay_ref_freq_hz` versus a range.** Section 8's cascade requires
   `idelay_ref_freq_hz` — a single figure — when `idelay_available` is true. No
   file in the Vivado install states a *required* reference frequency for any of
   these three devices; what exists is the primitive model's own legal **range**
   (three disjoint bands on 7-series, one on UltraScale, a different one on
   UltraScale+) and a default parameter. The schema therefore carries all three
   keys, the cascade requires the range as well as the figure, and every pack
   states the range and defers the figure. The contract's single key cannot be
   satisfied honestly on any of these parts.
2. **`ps_clk_config` is not defined.** Read here as a silicon fact — which PL
   clock ports the hard block presents — and deferred on both PS devices,
   because answering it needs a PS IP elaboration nobody has run. If it was
   meant as *which PS clock configuration this design uses*, it is a design fact
   and does not belong in a part pack at all.
3. **`cfgbvs` / `config_voltage` / `bitstream_compress`** — see section 5.
4. **`min_vivado_version` has no defined meaning.** It is treated here as an
   observation ("the oldest version these facts were read from"), not a vendor
   support statement, and every pack says so in a note. Vivado 2021.1 is
   installed on this host and was not queried.
5. **No pack-file naming rule for a board pack given as a bare name.** Part
   packs resolve against `$FPGA_FLOW_DIR/part`; a board pack resolves against
   `$FPGA_DIR/board`, `$FPGA_BOARD_DIR`'s parent, or the directory the spec
   names — deliberately, because nothing in this repository may reach up into a
   project it was not pointed at (CONTRACT.md section 9.8).

# Copyright (C) 2026, SoC Labs (www.soclabs.org)
