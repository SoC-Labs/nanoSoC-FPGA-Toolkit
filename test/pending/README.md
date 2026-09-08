# test/pending — verification that exists but is not yet in the suite

A script here was written by whoever built the code it checks, was RUN, and
passed. It is not in `test/shell/` because it is not yet in the harness idiom:
no `t_ok`/`t_check_fail`, and — the part that matters — **no mutation proof**.
So it demonstrates that the code worked once; it does not demonstrate that the
check would go red if the code broke.

That is a real distinction and the reason this directory is not called
`test/extra`. `test/run.sh` does NOT discover these. Converting one is a
contained job: wrap each assertion in `t_check`, add the paired
`t_check_fail` + `t_mutant`/`t_replace_line`, move it to `test/shell/`.

**Why they are here at all:** each was originally left in a session scratchpad,
which is deleted. Work that was genuinely verified and then became unreachable
is a recurring and expensive failure in this lab — the verification gets redone,
or worse, is cited from memory as though it still ran. Committing the script
unconverted is strictly better than losing it.

| Script | Checks | Status when written |
|---|---|---|
| `pack_api_verify.sh` | `part/pack_api.tcl` + the three part packs: schema validation, unknown key, double-set, missing required key, violated conditional cascade, both role families | **37/38** here |

### The one failure, and why it is not a defect

`probe relative path from wrong cwd (rc=0 want 2)`. The assertion is that
probing a RELATIVE pack path from a directory the pack is not under must be
refused. It depends on the current working directory being wrong — and moving
the script out of the scratchpad and into the repository made that directory no
longer wrong, so the relative path now resolves and the probe correctly returns
0. The check is cwd-dependent, not `pack_api.tcl`.

That is worth fixing when this is converted (pin the cwd explicitly), and it is
worth reading twice: the assertion passed for a reason that had nothing to do
with what it claimed to test, and only moving the file exposed it. Which is the
argument for conversion — a mutation proof would have caught it on day one.

### What rescuing this cost, and what it proves

Recovered 2026-09-08 from a session scratchpad, where it had been reported as
**38/38**. On first re-run from the repository it scored **30/38**: eight
failures, all from fixtures that had been left behind in the scratchpad. The
result was real when it was reported and unreproducible an hour later.
A verification that cannot be re-run is a claim, not evidence.

Copyright (C) 2026, SoC Labs (www.soclabs.org)
