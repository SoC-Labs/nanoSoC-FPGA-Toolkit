# Vendor collateral — what may and may not be committed here

**Read this before your first pull request.** It is one page, it is not
negotiable, and the mistake it exists to prevent does not look like a mistake
while you are making it.

`make hooks-install` puts the check in front of every commit, merge, patch and
push. `make hooks-selftest` proves it can still refuse. Both are **git** hooks
and have nothing to do with the flow hooks in `flow/common/seams.txt` — see
`make help-hooks` for those.

## The boundary

**This toolkit ships FLOW, not vendor collateral.** The stage scripts, the part
packs, the checks and the make engine are SoC Labs' own work, licensed to you
under [`LICENSE`](LICENSE) (Apache-2.0). Everything the flow *builds with* — the
tool, the IP catalogue, the board files, the licence — is **yours**, obtained
under your own agreement, reached at **runtime** through a path or a variable
*you* supply.

That is the whole design. A part pack holds *silicon facts about a device*, a
board pack holds *the project's own description of its target*, and neither
holds a file somebody else wrote. Nothing under Apache-2.0 here grants any right
to AMD/Xilinx IP, to a board vendor's board files, or to a tool installation.

## Never commit

- **Encrypted IP.** Anything carrying a `pragma protect` envelope, in any
  language. The encryption is a licence to *use* the core on a machine holding
  the key; it is not a licence to redistribute it, and the envelope does not
  become one by being committed.
- **Delivered netlists.** `.edn`, `.edf`, `.edif`. Same file, no envelope.
- **IP-catalogue customisations.** `.xci`, `.xcix`. They are generated from the
  vendor's catalogue, they are version-locked to the tool that made them, and
  they are the vendor's expression of the vendor's core. Commit the *Tcl that
  asks for one* instead: a `create_ip` call is reviewable, re-runnable and ours.
- **Board files.** `board.xml`, `part0_pins.xml`, `preset.xml`, anything under a
  `board_files/` tree. They describe hardware this repository does not own.
  CONTRACT.md §11.8 additionally forbids naming a board *anywhere* in this
  toolkit at all — the project supplies its own board pack.
- **Build output.** `.bit`, `.bin`, `.mcs`, `.dcp`, `.ltx`, `.xsa`, `.hwh`.
  A checkpoint carries the vendor netlist database for every IP in the design; a
  bitstream is the compiled form of everything upstream of it. None of it is
  source, none of it is reviewable in a diff, and a tree that carries it has
  become an artefact store with a `Makefile` in it. Publish a *release*.
- **Site facts.** Absolute paths into a tool install (`/opt/Xilinx/...` and its
  family), licence-server `port@host` strings, captured licence tables, internal
  hostnames, absolute paths under somebody's home directory. Name the
  **environment variable** — `XILINX_VIVADO`, `XILINXD_LICENSE_FILE` — and let
  each site fill it in.
- **Vendor text.** A EULA, a confidentiality or copyright header, datasheet or
  user-guide prose, release notes, a support-case reply. Not ours to
  redistribute, and paraphrasing it does not change that.

## Fine to commit

- **The names of things.** A part number in a part pack, an IP's VLNV in a
  `create_ip` call, a rule name, a Vivado message id. A name says *which* thing;
  only the thing itself is the vendor's.
- **This toolkit's own measurements on its own designs.** Runtimes, LUT/FF/BRAM
  counts, WNS/TNS, utilisation, how many constraints matched. Facts about SoC
  Labs' design, not about anybody's IP.
- **Explanations.** What a tool does, why a stage fails, which file the reader
  should open *on their own installation*, and how to get the tool to print a
  value. Teaching somebody where to look discloses nothing.

## What to do instead: a path in a variable, resolved on the host

This is the pattern, and it is not new here — it is the reference ASIC toolkit's,
which solves the same problem one process node down. There, every metal width
and spacing the flow uses is read at runtime from a PDK the licensee supplies at
a path they supply, and the repository holds only *keys and paths*. The reference
encodes it two ways, and both transfer directly:

1. **The generator is committed; its output is ignored.** A script that *reads*
   a vendor file and emits something derived from it is pure structure, holds no
   vendor content, and is reviewable in a diff. Its output inherits the vendor's
   status and is `.gitignore`d. When you need vendor data, write a program that
   reads it at build time — never a file that contains it.
2. **The rule is tested, not merely stated.** The reference asserts in its test
   suite that its generator carries no hardcoded value and no baked vendor path.
   A policy nobody can enforce is a policy nobody keeps.

Here that becomes: `FPGA_IP_REPO` points at an IP repository on *your* disk,
`fpga-flow-doctor` enumerates the tool installs it finds on *this* filesystem and
hardcodes no path, and the board pack that names your hardware lives in the
project, not in this repository. If you find yourself wanting to add a board
name, a pin, a part path or an install root *here*, the contract is wrong —
raise it, do not add the file.

## If a fix seems to need an edit inside a vendor tree

It does not. Vendor and IP-library trees are shared, read-only, and depended on
by other people and by CI; editing one corrupts builds silently across everybody
who uses it. Copy the affected file into the **project** tree, re-point the
project's own configuration at your copy, and record why in a comment. Never
touch the upstream.

## If you think something already committed crosses the line

Say so before you push anything further — raise it on the pull request or
contact the maintainers. Removing content from `HEAD` does not remove it from
the history, so the fix gets harder every commit.

**"It is only a generated file" is how encumbrance enters a repository.**

## What the check does and does not do

`ci/check-vendor-collateral.sh` holds every rule as a table of data, and every
rule in it carries an invented specimen it must match and a near-miss it must
not. It arms all of them on every run, before it reports anything, and it
refuses outright if the corpus it scanned was empty — because the guard this one
replaces was a loop over a glob that matched nothing, printing OK.

It still only catches what the mistake usually **looks like**. A core committed
as plain RTL with its header stripped matches nothing in the table and is still a
breach. The check is a floor, not a ceiling, and this page is the actual rule.

Copyright (C) 2026, SoC Labs (www.soclabs.org)
