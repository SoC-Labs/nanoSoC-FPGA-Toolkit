# The deploy tier

Everything above this tier builds a file. This is the only part of the toolkit
that touches a physical object somebody else can be using, and every design
decision in it follows from that.

```
preflight -> lease -> program -> verify -> test -> collect -> release
```

| File | What it is |
|---|---|
| `mk/deploy.mk` | the targets, and the variables make resolves for them |
| `scripts/fpga-flow-deploy` | the driver. Holds the lease, talks to the hub |
| `ci/deploy-gates.sh` | the six verdicts, graded from what the driver recorded |
| `ci/capability.conf.example` | the `fpga-flow-deploy` capability tier - a board is a RUNTIME dependency |

Nothing here is wired on by default. `make bitstream` does not reach for
hardware until a project sets `DEPLOY_AFTER_BITSTREAM=1`, and even then an
invocation does not mutate a board until `DEPLOY_EXECUTE=1`. Two switches,
because they answer two different questions - see `mk/deploy.mk`.

---

## The five things that shape this tier

All five were measured against the live daemon. Each one fails **quietly**:
none of them produces an error that says what is wrong, and four of them
produce a symptom that points somewhere else entirely. That is why they are
written down here rather than left to be rediscovered.

### 1. The board GROUP and the TARGET are different namespaces

They do not overlap.

| Scope | Namespace | Examples |
|---|---|---|
| leases, queues, reservations | `/api/v1/boards/<group>/...` | `pynq_z2_02` |
| program, reset, debug, actions | `/api/v1/targets/<target>/...` | `pynq_z2_02_pl` |

A group name on a target route returns **404**, and a 404 reads as "the board is
down" or as a route-skew bug in the hub. It is neither. On this hub a target is
its group's name plus `_pl`, `_ps` or `_mcc`, so the wrong one is a typo away:

```
pynq_z2_02      -> pynq_z2_02_ps (ps), pynq_z2_02_pl (pl)
kr260_01        -> kr260_01_pl (pl), kr260_01
```

Note the KR260 shape: the group contains a target **with the same name as the
group**. So "group equals target" is not by itself proof of the mistake, which
is why `deploy.preflight.namespace` is a warning and not a failure.

`FPGAHUB_BOARD` and `FPGAHUB_TARGET` are both required, separately. The
preflight refuses a run that has only one.

### 2. `lease acquire --pid` is silently inert from this host

The daemon's dead-PID reaper skips any lease whose holder string is not the
daemon's own hostname (`daemon.py:288-296`), and the client defaults the holder
to the *client's* hostname. So the one flag that exists precisely for "a
makeflow step frees the board when its process dies" is accepted, stored, and
never acted on.

The driver therefore **does not send a pid at all**. Putting one in the lease
record would advertise a safety net that is not there, to the next person who
reads it while trying to work out why a board is stuck.

What works instead, and it is the whole of the discipline:

* a **distinctive holder** - `fpga-flow-<block>-<runtag>-<host>-<pid>-<epoch>`.
  The `user` field is `dam1n19` for everybody who works here, so it identifies
  nothing; the holder string is the only handle anyone has.
* a **short TTL** - `FPGAHUB_LEASE_TTL_S`, default 600 s. Since the reaper
  cannot free this lease, the TTL is the only thing that will.
* a **heartbeat** at TTL/3 in a sidecar process. TTL/3 rather than TTL/2 so a
  single lost heartbeat is survivable.
* `trap release EXIT INT TERM`, **armed before the acquire**.

**The residual window, stated rather than papered over.** Between the acquire
request going out and its token being parsed, the daemon may have granted a
lease this process does not yet know the token for. Arming the trap first does
not close that window; it shrinks it to one round-trip. `SIGKILL` closes nothing
at all. Both are covered by the same two things: the token is written to
`work/deploy_lease.env` (mode 0600) the instant it is parsed, so
`make deploy-release` can give the board back after a `kill -9`; and failing
that, the TTL expires.

**Never revoke.** Revoke is an admin force-release, final for the holder, and
every lease on this hub carries the same `user` - so it cannot tell your own
stale lease from a colleague's live one. The driver never constructs the
endpoint. If a board is stuck: wait for the TTL, or go and ask.

### 3. Program and action dispatch are not lease-gated

Neither handler checks holdership. `POST /targets/{n}/program` and
`POST /targets/{n}/actions/{id}` check that the board exists and that the caller
is admin, and nothing else. Dispatch even *extends* a lease without matching a
token (`lease.py`: `extend_for_action` is "daemon-internal - no token / holder
match required").

**The lease is advisory, and this toolkit is the enforcer.** Before it programs,
and again before it dispatches, the driver asks
`GET /boards/<group>/lease/wait?token=<ours>&timeout=1` - the only token-scoped
question the API answers. 200 means our token holds the board; 408 means it does
not, and the driver refuses. A check that does not answer is UNVERIFIED and also
refuses, because an unanswered check is not a pass.

That refusal exists nowhere else. Removing it does not produce an error; it
produces two people programming one board and two sets of results that disagree.

### 4. Action dispatch is synchronous behind a 202

The route is declared `202 ACCEPTED`, and the handler `await`s the subprocess to
completion. The response body already carries the **terminal** state. So the
`run_id` only exists once the action has finished.

Two consequences the driver is built around:

* **Subscribe to the event stream before the POST.** There is no replay buffer
  and no Last-Event-ID; a subscription opened afterwards has missed the run. The
  driver starts `GET /events?types=action.start,action.log,action.end&board=<target>&action_id=<action>`
  and **waits for the daemon's `:connected` frame** before dispatching - starting
  curl is not evidence that the subscription was registered.
* **A client timeout does not stop the action.** It keeps running on the board.
  The driver recovers the `run_id` from the stream's `action.start` event and
  polls the status route, so a timeout still yields a verdict instead of a
  shrug.

**The 30 s hazard, and it is UNMEASURED.** The stock client hard-codes a 30 s
HTTP timeout (`ipc.py:38`) and `cli._client()` never passes an override; there is
no flag and no environment variable. Whether that actually breaks a long
`actions run` or `target program` **has not been measured on the rig** - the
reasoning says it must, since the POST blocks for the action's whole duration,
but reasoning is not a measurement. This is why the driver calls REST directly
with its own `--max-time` (`DEPLOY_ACTION_TIMEOUT_S`, default 900 s) rather than
shelling out to the CLI. **Somebody should measure this on the rig** and either
confirm the hazard or delete this paragraph.

### 5. The bitstream is opened by the daemon, by absolute path, on the daemon's filesystem

`POST /targets/{n}/program` takes `{"bitstream": "<abs path>"}` and the server
opens that path itself. A path that resolves here and not there produces "file
not found" without ever saying whose filesystem was searched.

Staging is the toolkit's job, not the operator's. `FPGAHUB_STAGE_MODE`:

| mode | what it does |
|---|---|
| `auto` (default) | `local` when the hub is reached over its unix socket - which can only be a daemon on this machine - and **refuses** otherwise, naming the two ways out. It never guesses. |
| `local` | the daemon's filesystem is ours; pass the absolute path |
| `shared` | copy into `FPGAHUB_STAGE_DIR`, a path **the daemon sees** |
| `scp` | copy to `FPGAHUB_STAGE_HOST:FPGAHUB_STAGE_DIR` first |

**The bitstream is a SERVER-SIDE ABSOLUTE PATH and there is no upload.**

Checked against the daemon source on 2026-09-08, because an earlier draft of
this document claimed the opposite. `/api/v1/bitstreams` carries **three GET
routes and no POST**:

    GET /bitstreams                       list
    GET /bitstreams/{id}                  info
    GET /bitstreams/{id}/download         fetch

A repository you can read from is not a repository you can upload to. The
`bitstream_id` field on the program request selects something already in the
store; nothing in the API puts it there. `docs/PROPOSAL_BITSTREAM_REPOSITORY.md`
in the fpgahub tree is marked *"Status: design - not implemented"*.

So staging remains the toolkit's job: the `.bit` must be visible to the daemon
host before the program request, via a shared mount or an scp step. Do not build
against an upload endpoint that does not exist.

---

## What works today

Verified against a stubbed daemon, with `--dry-run`, and by unit-testing the
argument handling. Not verified on hardware - see the next section.

* the group/target split, enforced in preflight and visible in every message
* the lease discipline: distinctive holder, short TTL, heartbeat at TTL/3,
  `trap ... EXIT INT TERM` armed before the acquire, token persisted to disk
  before any work
* **holdership enforced by this toolkit** before program and before dispatch
* `--dry-run` as the default for everything destructive, and it is real: a full
  dry `run` against the stub issues four GETs and not one mutating request
* event stream subscribed, and confirmed open, before the dispatch POST
* `run_id` recovered from the stream when our own timeout fires
* `status_url` never dereferenced - the path is constructed
* `skip_if_loaded=false` sent on every program
* six gate ids, each proven to go red on a planted fault (39 selftest cases)
* SIGINT and SIGTERM release the board and exit 130 / 143
* `kill -9` leaves a recoverable token; `make deploy-release` gives the board
  back, token-scoped

### Configuring it

```make
FPGAHUB_BOARD    = pynq_z2_02          # the GROUP  - lease scope
FPGAHUB_TARGET   = pynq_z2_02_pl       # the TARGET - program scope
DEPLOY_ACTION    = my_smoke_test       # an action id from the bound manifest
BIN_STYLE        = zynq7

DEPLOY_AFTER_BITSTREAM = 1             # let `make bitstream` deploy
```

```
make deploy-vars                    what it WOULD do. Runs nothing
make deploy-status                  what the hub says now. Read-only
make deploy                         dry run
make deploy DEPLOY_EXECUTE=1        armed
make deploy-release                 give back a lease a crashed run left
make deploy-selftest                prove the gates can go red
```

Over TCP, `FPGAHUB_TOKEN` must hold an **admin** token: program, reset and
dispatch are admin-gated, only the unix socket is trusted without one, and a
`write` role is not enough. Preflight says so before the lease is taken.

### Where the evidence lands

CONTRACT.md §5 permits exactly four directories in a run, so this tier creates
no fifth:

```
reports/deploy_manifest.txt   every field, or an UNVERIFIED:<reason>
reports/deploy_gate.txt       the verdict, in §5's section structure
logs/deploy.log               the driver's output
logs/deploy_sse.jsonl         the event stream - the only in-flight record
outputs/deploy/               what was collected
work/deploy_lease.env         the live token, 0600. Removed on release
```

It does **not** depend on `dirs`, and that is deliberate: `dirs` requires
`check-quiet`, so depending on it would make deploying an already-built
bitstream require `TOP`, `RTL_FLIST` and `XDC_PINS` - none of which a
fetch-and-deploy runner has, and none of which this tier reads.

---

## What is UNPROVEN, pending hardware

Nothing in this tier has run against a real board. The following are the joints
a rig run would close, in the order they would be exercised:

1. **That the daemon accepts these request bodies.** Every payload is built from
   a reading of `schemas.py`, not from a successful call. `ttl_seconds` (not
   `ttl`), `holder` and `user` both required, `bitstream` XOR `bitstream_id`
   under `extra="forbid"` - a wrong key is a 422, not a silent default.
2. **That the group lease response shape is what is parsed.** The target route
   returns `lease.expires_at`; the group route returns a `leases[]` array and is
   a separately hand-rolled dict. The driver reads the array first and falls
   back. Only a real grant confirms it.
3. **`GET /boards/<g>/lease/wait?token=...&timeout=1` as a holdership check.**
   This is the load-bearing enforcement in the whole tier and it is inferred
   from the endpoint's semantics, not observed. If it does not behave as
   "200 = our token holds it, 408 = it does not", the enforcement is wrong.
4. **The DONE readback parse.** There is no boolean anywhere in the response.
   The driver looks for `PROGRAM_VERIFIED` in `stdout_tail`, and treats
   `exposes no DONE_PIN` as UNVERIFIED. `stdout_tail` is the **last 4000
   characters only**, so a chatty program run could push the line out of it -
   in which case the driver reports UNVERIFIED rather than a pass, which is
   safe but would be a false red. Unmeasured how close a real run comes to
   4000 characters.
5. **The 30 s client timeout hazard** (constraint 4). Reasoned, not measured.
6. **Queue cancel.** `DELETE /boards/<g>/queue` with `{"holder": ...}` in the
   body is a guess at where the CLI's `--holder` goes. If it is a query
   parameter instead, the cancel silently fails - the driver says so and prints
   `fpgahub board lease cancel <group> --holder <h>` rather than assuming it
   worked, but a left-behind queue entry takes the board the moment the current
   holder finishes.
7. **`scp` staging.** Exercised only in dry run.
8. **That an action's evidence is retrievable at all.** There is no
   artefact-download endpoint. `collect` gathers the event stream and the run
   status; anything the design produces has to be carried out by the action
   itself. Whether that is sufficient for a real bring-up is untested.
9. **The heartbeat over a long run.** Proven to be spawned and killed; never
   proven to keep a real lease alive for an hour.

Two known hub-side bugs are avoided rather than fixed, and would bite anything
that did not know about them:

* **`status_url` is a guaranteed 404.** The daemon builds it as
  `/api/v1/boards/<t>/actions/<run>`; no `/boards/.../actions` route exists.
  The driver constructs `/targets/<t>/actions/<run>` itself.
* **Heartbeat drops `tier` and `requeue_on_revoke`.** The rebuilt lease uses the
  dataclass defaults, so the first heartbeat silently promotes a `background`
  lease to `interactive` and it stops being preemptible. The driver defaults to
  `tier=interactive`, where the bug is inert. If you set `--tier background` to
  be a good citizen on a shared bench, know that it lasts until the first
  heartbeat.

---

## The KR260 gap

**No KR260 target has a program method configured.** The site config defines
`[boards.kr260_0N.reset.default]` and `[...reset.reboot]` and no `[...program.*]`
block at all. A program request is refused by the **server**, with:

```
HTTP 400  board 'kr260_02' has no program method 'default' (no [program] block configured)
```

That 400 arrives minutes into a deploy and reads as a rejected bitstream. It is
not: it is a hub configuration gap, and nothing about the design, the bitstream
or the board is wrong.

So the preflight asks `GET /targets/<t>/program` **first** and fails
`deploy.preflight` with that sentence before taking a lease or sending anything.
Measured against the stub: a no-program-method target produces **zero mutating
requests**.

One wrinkle: a KR260 with a bound manifest containing an action with
`id="program"` takes the manifest path instead and never reaches the 400. The
preflight reads the method list, which shows a synthetic
`{name: "default", plugin: "manifest:program", via_manifest: true}` entry when
that applies, so both cases are visible.

**To close the gap**, somebody has to add a `[boards.kr260_0N.program.<method>]`
block to the site config. Until then, `make deploy` against a KR260 is a
preflight failure by design, with the reason on the line.

---

## What needs changes in fpgahub

In rough order of how much they cost this tier:

1. **Lease-gate program and action dispatch**, or say in the API docs that they
   are advisory. Today every client must reimplement the enforcement in §3, and
   a client that does not is indistinguishable from one that does until two runs
   collide.
2. **Fix `status_url`** to emit `/targets/...`. It is one f-string.
3. **Make the reaper work for remote holders**, or reject `--pid` from a client
   whose holder is not the daemon host. Accepting a flag and ignoring it is
   worse than not having it.
4. **Expose a boolean for the DONE readback** on `BoardProgramRun` - `verified:
   bool | None`, where `None` means the device has no DONE property. Today it is
   a substring of a human-readable message, in a field that is truncated.
5. **Give the client an HTTP timeout override** (flag or env var), so a long
   action does not require bypassing the CLI.
6. **Preserve `tier` and `requeue_on_revoke` across a heartbeat.**
7. **Clear `bitstream_fingerprint` on reset** - see the next section.
8. **A CLI verb for the bitstream repository**, so staging can use the upload
   endpoint instead of a shared mount.

### Why every program is sent `skip_if_loaded=false`

The daemon's skip compares two things and neither of them touches hardware:

* the candidate file's sha256 against the fingerprint the daemon **recorded the
  last time it believed a program succeeded**, and
* the lease token then against the lease token now.

`reset.py` never clears either. Nor does a reboot, a power cycle, a PS-side
`fpgautil` unload, a watchdog POR, or the KR260 `kr260_jtag_por` recovery - and
the fingerprint is persisted to the state file, so it survives a daemon restart
too. The lease-token term does not save you either: the canonical
`acquire -> program -> reset -> program` sequence holds one lease throughout, so
both terms still match after the reset.

So `skip_if_loaded` asserts *"the last program I ran wrote these bytes and I
still hold the same lease"*, never *"these bytes are on the fabric right now"*.
A PL blanked by a reboot is still "already loaded".

A skip returns `ok: true` having programmed nothing, and the only thing that
betrays it is the `message` prefix - the response's `plugin` field is recomputed
from config afterwards and names the real plugin. The driver detects it and
fails `deploy.program`, because a skip we explicitly asked not to happen is a
hub-side finding, not a deploy that worked.

`skip_if_loaded=false` is preferred over `force=true`: `force` *also* bypasses
the part-mismatch refusal, which is a check worth keeping.

---

## Reading a failed deploy

The gate id is the thing to grep for. In rough order of "is this about my
design?":

| gate | if it is red, the problem is |
|---|---|
| `deploy.preflight` | configuration - a name, a missing program method, an unstageable image, no admin token. Nothing was touched |
| `deploy.lease` | the board is somebody else's (exit 75, retry), or we could not prove we held it |
| `deploy.program` | the request. 400 is usually no program method; 404 is a group name on a target route; 401/403 is the admin gate |
| `deploy.verify` | **the device**. The image reached the cable and not the fabric - or the device cannot say, which is UNVERIFIED and not a pass |
| `deploy.test` | **the design.** Every gate above this one is about getting to the board |
| `deploy.release` | the board is still held. It frees itself at the TTL. Do not revoke |

A `SKIP` is not a pass. `deploy.test` skipped means the board was programmed and
**nothing was run on it** - that is a deploy, not a test.

---

## Things CONTRACT.md does not say, that this tier had to decide

Raised here rather than settled quietly. Each is a real question the contract
leaves open.

1. **§3.3 declares `FPGAHUB_TOML` and never says what it is.** It is the
   *project's action manifest* (`<project>/fpga/fpgahub.toml`), the file
   declaring the `[[actions]]` a `DEPLOY_ACTION` names - not daemon connection
   config, which lives in `/etc/fpgahub/config.toml` and is not the project's.
   More importantly the daemon reads a manifest **it has been pointed at**, per
   target, via `manifest_path` in its own config. A project file the daemon has
   not been pointed at is a file nobody runs. This tier therefore validates
   `DEPLOY_ACTION` against `GET /targets/<t>/actions` - the hub's list - and not
   against the project's file, and does not otherwise read `FPGAHUB_TOML`.
2. **§4 does not say whether a post-stage target inherits `check-quiet`.** Stage
   targets do. Deploy deliberately does not: requiring a complete *build*
   contract to put an already-built bitstream on a board would block the host
   this tier is most useful on. If the contract wants the other answer, it
   should say so.
3. **flow.mk's `*_POST_TARGETS` export is computed before the fragments are
   read.** `export FPGA_BITSTREAM_POST_TARGETS := $(BITSTREAM_POST_TARGETS)` is
   a `:=` in flow.mk §7; the `fpga_flow_optional` calls that read this file come
   ~800 lines later. So a fragment appending to `BITSTREAM_POST_TARGETS` reaches
   the recipe - `post_stage_targets` expands at recipe time - but not the
   exported copy that scripts and manifests read, and the two disagree. The
   symptom would be a deploy that ran while every record of the run said no
   deploy was configured. `mk/deploy.mk` re-exports the variable to close it,
   but the ordering is the contract's to fix. The same hazard applies to
   `FPGA_POST_TARGET_VARS`, computed from `$(.VARIABLES)` at the same point: a
   `*_POST_TARGETS` variable **defined by a fragment** is invisible to the
   census that exists to catch a misspelt one.
4. **flow.mk has no `fpga_flow_optional` call for this fragment yet** ("No calls
   yet. Phase 2 adds them here"), and `mk/deploy.mk` is not in `help.mk`'s
   `HELP_DOC_FILES`, so `make help-all` cannot see these targets. Both are
   one-line additions in files this tier does not own. Until they land, a
   project loads the fragment itself with `$(call fpga_flow_optional,deploy)`
   after including `mk/flow.mk` - which is tested and works.
5. **§7 does not say what an emitter should do about a step that ran twice.**
   The holdership check runs before the program and again before the dispatch.
   The manifest writer here makes the last write win *in place*, because `ci_mf`
   returns the **first** match - so an appended correction would be the one
   ignored, which is exactly the wrong half.
6. **§10's exit-code table has no code for "the hardware is busy".** This tier
   uses `75` (`EX_TEMPFAIL`), which §10 lists only as "lock contention". A busy
   board is the same shape of thing and the same correct response - retry - so
   the reading is a small extension rather than a new code, but it is an
   extension.

# Copyright (C) 2026, SoC Labs (www.soclabs.org)
