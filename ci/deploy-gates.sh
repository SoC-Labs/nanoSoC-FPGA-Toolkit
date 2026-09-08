#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# ci/deploy-gates.sh - the six verdicts a deploy owes, read off what it recorded
#
#   ci/deploy-gates.sh [--manifest <file>] [--gate-file <file>] [--summary]
#   ci/deploy-gates.sh --selftest
#
# Six gate ids, stable and meant to be grepped (CONTRACT.md section 7):
#
#   deploy.preflight   could this run have deployed at all - hub, group, target,
#                      a program METHOD, an image the daemon can actually open
#   deploy.lease       did we HOLD the board at the moment we programmed it
#   deploy.program     did the program request succeed
#   deploy.verify      did the DEVICE say it is configured (DONE readback)
#   deploy.test        did the action we dispatched pass
#   deploy.release     did we give the board back
#
# WHY THIS READS A MANIFEST AND DOES NOT TALK TO THE HUB.
#
# The same reason ci/assert-stage.sh reads a stage manifest rather than
# re-scraping Vivado's reports: a second, fuzzier opinion competing with the
# authoritative one is how the reference project's stage reporter undercounted
# DRC by 7% for weeks with nothing to disagree with it. Here the argument is
# stronger than tidiness, because the thing being measured MOVES.
#
# A deploy's evidence is a sequence of moments: the lease was held AT THE INSTANT
# the program request went out; DONE read high AFTER that request and BEFORE the
# next person's. Re-asking the hub afterwards recovers none of them - by the time
# CI runs, the lease has been released on purpose and the board may have been
# reprogrammed twice. A checker that asked "is the lease held now?" would go RED
# on every correctly finished deploy and GREEN on one that crashed still holding
# it. The verdict has to be graded from what was recorded at the time, or it is
# not a verdict about that deploy at all.
#
# It also means these gates run with no board, no hub, no network and no licence,
# days later, from an archived run directory.
#
# WHAT IT CANNOT DO, SAID PLAINLY: it cannot tell a deploy that recorded nothing
# from a deploy that never ran. Both leave no manifest. That case is refused
# (exit 2) with an UNVERIFIED verdict recorded - never a skip, because "we did
# not deploy" and "we deployed and lost the evidence" both have to stop somebody
# quoting the run as tested.
#
# Env:
#   FPGA_REPORT_DIR   where deploy_manifest.txt lives, when --manifest is unset
#   CI_VERDICT_DIR    where verdicts.tsv lands (ci/lib.sh resolves the default)
#
# Exit status:
#   0   every gate passed
#   1   at least one gate is FAIL or UNVERIFIED
#   2   refused: no manifest could be located or read, or unusable arguments
# 130   interrupted
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOW_DIR="$(cd "$HERE/.." && pwd)"

# shellcheck source=ci/lib.sh
. "$HERE/lib.sh"

usage() { sed -n '3,53p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

trap 'echo; echo "deploy-gates: interrupted"; exit 130' INT

MANIFEST=""
GATE_FILE=""
WANT_SUMMARY=0
SELFTEST=0
while [ $# -gt 0 ]; do
    case "$1" in
        --manifest)  MANIFEST="${2:-}";  shift 2 ;;
        --gate-file) GATE_FILE="${2:-}"; shift 2 ;;
        --summary)   WANT_SUMMARY=1; shift ;;
        --selftest)  SELFTEST=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "deploy-gates: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

#-----------------------------------------------------------------------------
# READING THE RECORD
#
# `key value` lines, the shape CONTRACT.md section 5 gives every manifest, so
# ci_mf reads it and so does a person with grep. Every field is a value or an
# `UNVERIFIED:<reason>` string, and ci_is_measured is what tells them apart -
# never a test for emptiness, because an empty field and a field saying why it
# is empty are different findings and only one of them names somebody's next job.
#-----------------------------------------------------------------------------

## mf <key> - the value, or the empty string
mf() { ci_mf "$MANIFEST" "$1" 2>/dev/null; }

## truthy <value> - the manifest's boolean spelling, and ONLY that spelling.
##
## A WHITELIST, NOT `!= no`. `!= no` makes every unreadable field a pass, which
## is the exact inversion CONTRACT.md section 7 exists to forbid: `UNVERIFIED:
## the-daemon-never-answered` is not "no", so it would have been read as yes.
truthy() { [ "${1:-}" = "yes" ] || [ "${1:-}" = "true" ] || [ "${1:-}" = "1" ]; }

#-----------------------------------------------------------------------------
# THE GATES
#-----------------------------------------------------------------------------

gate_preflight() {
    local group target method image staged mode

    group="$(mf deploy.board_group)"
    target="$(mf deploy.target)"

    # THE TWO NAMESPACES. Both required, and the failure text names the split,
    # because the symptom of getting it wrong is a 404 from a /targets/ route -
    # which reads as a dead board or a broken hub and is neither. On this hub a
    # target's group is its own name with `_pl`/`_ps`/`_mcc` stripped
    # (fpgahub grouping.py), so the two names are near-identical and the wrong
    # one is very easy to type.
    if ! ci_is_measured "$group" || ! ci_is_measured "$target"; then
        ci_fail deploy.preflight \
            "board GROUP='${group:-unset}' TARGET='${target:-unset}' - both are required and they are DIFFERENT namespaces. Leases address the group (/boards/<group>/lease); program, reset and actions address the target (/targets/<target>/...). A group name on a target route is a 404 that reads as a dead board"
        return
    fi
    if [ "$group" = "$target" ]; then
        ci_warn deploy.preflight.namespace \
            "FPGAHUB_BOARD and FPGAHUB_TARGET are both '$group'. A target normally carries a _pl/_ps/_mcc suffix its group does not; if the target routes 404, this is why"
    fi

    method="$(mf deploy.preflight.program_method)"
    if ! ci_is_measured "$method"; then
        ci_unverified deploy.preflight \
            "the program methods configured for target '$target' were not read, so nothing here knows whether a program request could have succeeded"
        return
    fi
    if [ "$method" = "none" ]; then
        ci_fail deploy.preflight \
            "target '$target' has NO program method configured on the hub. The server refuses with HTTP 400 before the board is touched - this is a hub configuration gap, not a board fault and not a bad bitstream. Every KR260 target is in this state today; see docs/DEPLOY.md"
        return
    fi

    image="$(mf deploy.bitstream.path)"
    if ! ci_is_measured "$image"; then
        ci_unverified deploy.preflight "no bitstream path was recorded"
        return
    fi
    if ! ci_is_measured "$(mf deploy.bitstream.sha256)"; then
        ci_unverified deploy.preflight \
            "bitstream '$image' was named but not hashed, so nothing can say afterwards WHICH image reached the board. The daemon reports its own fingerprint; without ours there is nothing to compare it against"
        return
    fi

    # STAGING. The daemon opens the file by absolute path ON ITS OWN FILESYSTEM.
    # A relative path is refused here rather than at the POST, because the POST's
    # error is about a file the daemon could not find and says nothing about
    # whose filesystem it looked on - which is the whole question.
    mode="$(mf deploy.stage.mode)"
    staged="$(mf deploy.stage.server_path)"
    if ! ci_is_measured "$staged"; then
        ci_unverified deploy.preflight \
            "no server-side path was resolved for the image (stage mode '${mode:-unset}'). The program endpoint takes a path on the DAEMON's filesystem; a path that resolves here and not there is the commonest way this tier fails"
        return
    fi
    case "$staged" in
        /*) ;;
        *)  ci_fail deploy.preflight \
                "server-side image path '$staged' is not absolute. The daemon resolves a relative path against ITS working directory, not this one, so it would open a different file or none"
            return ;;
    esac

    ci_pass deploy.preflight \
        "group=$group target=$target method=$method image=$staged (stage $mode)"
}

gate_lease() {
    local held holder ttl

    # A DRY RUN TOOK NO LEASE BECAUSE IT PROGRAMMED NOTHING, and a skip with its
    # reason is the honest verdict. Reporting UNVERIFIED here instead would make
    # every dry run red for the absence of a record of a thing that correctly did
    # not happen - and a gate that is red on a healthy run is a gate people learn
    # to ignore on the run where it means something.
    if [ "$(mf deploy.mode)" = "dry-run" ]; then
        ci_skip deploy.lease "DEPLOY_EXECUTE=0, so no board was taken and none was programmed"
        return
    fi

    held="$(mf deploy.lease.held_at_program)"
    holder="$(mf deploy.lease.holder)"

    if ! ci_is_measured "$held"; then
        ci_unverified deploy.lease \
            "nothing recorded whether this run held the board when it programmed it. THE HUB DOES NOT ENFORCE THIS - neither the program handler nor the action handler checks holdership - so an unrecorded lease is not a technicality. It is the only thing that would have stopped two runs programming one board"
        return
    fi
    # THE BOARD BEING BUSY IS NOT A DEFECT AND MUST NOT READ AS ONE. The run is
    # still not deployed - the gate is red, and it should be - but "somebody else
    # is using it" and "we programmed a board we did not hold" are opposite
    # findings, and only the second one is anybody's fault.
    case "$(truthy "$(mf deploy.lease.acquired)" && echo held || mf deploy.lease.why)" in
        queued*)
            ci_fail deploy.lease \
                "the board group '$(mf deploy.board_group)' is leased by somebody else ($(mf deploy.lease.why)). NOTHING WAS PROGRAMMED and nothing is wrong with this design or this bitstream - retry when the board is free. The driver exits 75 (EX_TEMPFAIL) for exactly this case"
            return ;;
    esac
    if ! truthy "$held"; then
        ci_fail deploy.lease \
            "the board was programmed WITHOUT a verified lease (held_at_program=$held). The hub permits it; this toolkit is the only enforcer. A result taken from an unheld board cannot be attributed to this run, because somebody else may have reprogrammed it in the middle"
        return
    fi
    if ! ci_is_measured "$holder"; then
        ci_unverified deploy.lease \
            "a lease was held and its holder was not recorded. Every lease on this hub carries the same 'user', so the holder string is the ONLY thing that says whose run it was"
        return
    fi

    # A HOLDER THAT IDENTIFIES NOTHING IS A FINDING, NOT A DETAIL. The dead-PID
    # reaper skips any lease whose holder is not the daemon's own hostname, so a
    # lease taken from here is freed by its TTL and by nothing else. When a board
    # is stuck, the holder string is all anybody has before they start asking
    # around - and the default holder is this host's bare hostname, which every
    # other run from this host also uses.
    case "$holder" in
        *fpga-flow*) ;;
        *) ci_warn deploy.lease.holder \
               "holder '$holder' does not name this toolkit or this run. The dead-PID reaper cannot free a lease taken from this host, so when one outlives its run the holder string is the only handle anybody has on WHOSE it is" ;;
    esac

    ttl="$(mf deploy.lease.ttl_s)"
    if ci_is_measured "$ttl" && [ "$ttl" -gt 3600 ] 2>/dev/null; then
        ci_warn deploy.lease.ttl \
            "TTL ${ttl}s. The reaper skips leases held from a non-daemon host, so the TTL is the ONLY thing that frees this board after a crash - and a long one is a board nobody can book for that long"
    fi

    ci_pass deploy.lease "held at program time by '$holder' (ttl ${ttl:-?}s)"
}

gate_program() {
    local attempted status mode skipped

    mode="$(mf deploy.mode)"
    attempted="$(mf deploy.program.attempted)"

    # A DRY RUN IS A SKIP WITH ITS REASON, NEVER A PASS - and never silent: a
    # tier quietly checking nothing is how a green run comes to prove nothing.
    if [ "$mode" = "dry-run" ]; then
        ci_skip deploy.program "DEPLOY_EXECUTE=0, so nothing was programmed. This run put no image on any board"
        return
    fi
    if ! ci_is_measured "$attempted"; then
        ci_unverified deploy.program "nothing recorded whether a program request was sent"
        return
    fi
    if ! truthy "$attempted"; then
        ci_fail deploy.program "no program request was sent - $(mf deploy.program.why)"
        return
    fi

    status="$(mf deploy.program.http_status)"
    if ! ci_is_measured "$status"; then
        ci_unverified deploy.program "the program request was sent and its result was not recorded. It may have completed"
        return
    fi
    case "$status" in
        2??) ;;
        400) ci_fail deploy.program \
                 "HTTP 400 from the program endpoint. On this hub that is what a target with NO PROGRAM METHOD returns - the server refuses before the board is touched. Detail: $(mf deploy.program.error)"
             return ;;
        404) ci_fail deploy.program \
                 "HTTP 404 from the program endpoint. Check WHICH NAME was posted: program addresses a TARGET, and a board GROUP on a target route is a 404 that reads as a dead board. Posted: $(mf deploy.target)"
             return ;;
        409) ci_fail deploy.program \
                 "HTTP 409 from the program endpoint - either the method needs confirm, or the bitstream's part does not match the device. Detail: $(mf deploy.program.error)"
             return ;;
        422) ci_fail deploy.program \
                 "HTTP 422 - the request body was rejected. Exactly one of bitstream / bitstream_id must be given. Detail: $(mf deploy.program.error)"
             return ;;
        401|403) ci_fail deploy.program \
                 "HTTP $status - the program endpoint is admin-gated. Over TCP it needs an ADMIN Bearer token (FPGAHUB_TOKEN); only the unix socket is trusted without one, and a write-role token is not enough. Detail: $(mf deploy.program.error)"
             return ;;
        *)   ci_fail deploy.program "HTTP $status from the program endpoint - $(mf deploy.program.error)"
             return ;;
    esac

    # THE DAEMON'S 'SKIP' PATH RETURNS ok:true AND PROGRAMS NOTHING.
    #
    # skip_if_loaded compares the candidate file's sha256 against the fingerprint
    # the daemon RECORDED the last time it believed a program succeeded, plus the
    # lease token. Neither term touches hardware, and a reset does not clear
    # either - so a PL blanked by a reboot, a POR or an fpgautil unload is still
    # "already loaded" as far as the daemon is concerned. A skip is therefore not
    # a successful deploy; it is an assertion about the daemon's memory.
    skipped="$(mf deploy.program.skipped)"
    if truthy "$skipped"; then
        ci_fail deploy.program \
            "the daemon SKIPPED programming: it believes this image is already loaded. That belief is its own record of a previous program plus the lease token - no readback, and a reset does not clear it. Send skip_if_loaded=false after any reset, reboot or power event. Detail: $(mf deploy.program.message)"
        return
    fi

    ci_pass deploy.program "HTTP $status, fingerprint $(mf deploy.program.fingerprint)"
}

# THE ONE GATE THAT ASKS THE DEVICE RATHER THAN THE SERVICE.
#
# Everything above grades a conversation with a daemon. This grades the pin.
#
# HOW THE ANSWER IS CARRIED, WHICH IS WORSE THAN IT SOUNDS: there is no boolean
# in the program response. The programming Tcl prints `PROGRAM_VERIFIED: DONE
# asserted` when it read DONE back, and the plugin then appends the literal
# string ` (DONE unverified)` to the run's `message` when it did NOT. So the
# evidence is a substring, in two places, and the driver records which it found.
#
# AND A DEVICE THAT EXPOSES NO DONE PROPERTY IS UNVERIFIED, NOT A PASS. This is
# the entire reason the gate is separate from deploy.program. In that case the
# Tcl prints a warning, exits 0, the plugin reports `ok: true`, and the run looks
# exactly like a success. The comfortable reading is "this device does not report
# DONE, so there is nothing to check"; the true reading is "we do not know
# whether this board is configured". They differ on precisely the runs that
# matter - the ones where the image did not take.
gate_verify() {
    local verified prop mode

    mode="$(mf deploy.mode)"
    if [ "$mode" = "dry-run" ]; then
        ci_skip deploy.verify "DEPLOY_EXECUTE=0, so no device was configured and there is no DONE pin to read"
        return
    fi
    if truthy "$(mf deploy.program.skipped)"; then
        ci_unverified deploy.verify \
            "the daemon skipped programming, so no DONE readback happened on this run. Whatever is in the fabric was put there by an earlier run, or by nothing"
        return
    fi
    # AN ABORTED RUN MUST NOT BE GRADED AS A DONE PROBLEM. When nothing was ever
    # programmed, "no PROGRAM_VERIFIED evidence" is true and useless - it points
    # at the pin when the cause is three gates upstream. One finding should read
    # as one finding.
    if ! truthy "$(mf deploy.program.attempted)"; then
        ci_unverified deploy.verify \
            "no device was configured on this run, so there was no DONE to read - $(mf deploy.program.why). The finding is upstream: see deploy.preflight and deploy.program"
        return
    fi

    verified="$(mf deploy.verify.program_verified)"
    prop="$(mf deploy.verify.done_property)"

    if [ "$prop" = "none" ]; then
        ci_unverified deploy.verify \
            "target '$(mf deploy.target)' exposes NO DONE_PIN property, so nothing was read back off the device. THIS IS NOT A PASS. The programming run reported ok, which here means the request completed - not that a device is configured. A measurement taken from this board cannot be attributed to this bitstream"
        return
    fi
    if ! ci_is_measured "$verified"; then
        ci_unverified deploy.verify \
            "no PROGRAM_VERIFIED evidence was recorded, so the DONE readback is unknown. A 2xx from the program endpoint is the REQUEST being accepted; DONE is the only thing that says a device took the image"
        return
    fi
    if ! truthy "$verified"; then
        ci_fail deploy.verify \
            "DONE was NOT asserted after configuration (program_verified=$verified). The image reached the cable and not the fabric. Detail: $(mf deploy.verify.detail)"
        return
    fi

    ci_pass deploy.verify "PROGRAM_VERIFIED - DONE read back from the device"
}

gate_test() {
    local action state mode rid

    mode="$(mf deploy.mode)"
    action="$(mf deploy.test.action)"

    if [ "$mode" = "dry-run" ]; then
        ci_skip deploy.test "DEPLOY_EXECUTE=0, so no action was dispatched"
        return
    fi

    # NO ACTION CONFIGURED IS A SKIP WITH ITS REASON. Programming a board and
    # running nothing on it is a legitimate deploy - but it is not a tested one,
    # and the difference has to survive into the record, because "deployed" is
    # the one claim in this ladder somebody will repeat in a meeting.
    if ! ci_is_measured "$action" || [ "$action" = "none" ]; then
        ci_skip deploy.test \
            "DEPLOY_ACTION is unset. The board was programmed and NOTHING WAS RUN ON IT. This run has not tested the design; it has loaded it"
        return
    fi

    # AN ACTION THAT WAS CONFIGURED AND NEVER DISPATCHED IS NOT A SKIP. A skip
    # says "this did not apply"; here it did apply and the run did not reach it,
    # which is UNVERIFIED - and the reason belongs to whatever stopped it, not to
    # this gate. The dispatched flag is read rather than inferred from a missing
    # state, because a MISSING state also describes a client timeout - and a
    # timed-out action is still running on the board, which is the opposite
    # situation and wants the opposite response.
    if ! truthy "$(mf deploy.test.dispatched)"; then
        ci_unverified deploy.test \
            "action '$action' was configured and NEVER SENT: $(mf deploy.test.why)$(mf deploy.program.why). Nothing here is a finding about the design - look upstream"
        return
    fi

    state="$(mf deploy.test.state)"
    rid="$(mf deploy.test.run_id)"

    if ! ci_is_measured "$state"; then
        # THE TIMEOUT CASE HAS ITS OWN SENTENCE. Dispatch is declared 202 and is
        # SYNCHRONOUS: the handler awaits the subprocess, so the response - and
        # the run id with it - only arrives once the action has finished. A
        # client timeout therefore returns before the run id exists, while the
        # action carries on running on the board with nothing here to say so.
        ci_unverified deploy.test \
            "action '$action' was dispatched and no final state was recorded. Dispatch is synchronous behind a 202, so a client timeout returns before the run id exists AND THE ACTION KEEPS RUNNING on the board. Timeout was $(mf deploy.test.timeout_s)s; the event stream is the only in-flight record: $(mf deploy.test.event_log)"
        return
    fi

    # THE HUB'S OWN STATE VOCABULARY, not a guess: its exit-code map is
    # ok=0 failed=1 rejected=3 timeout=124 cancelled=130.
    case "$state" in
        ok)
            ci_pass deploy.test "action '$action' -> ok (run ${rid:-?})" ;;
        rejected)
            ci_fail deploy.test \
                "action '$action' was REJECTED (run ${rid:-?}) - the manifest or its prerequisites refused it before anything ran on the board. This is a configuration finding, not a design one: $(mf deploy.test.detail)" ;;
        timeout)
            ci_fail deploy.test \
                "action '$action' TIMED OUT server-side (run ${rid:-?}) after the manifest's own timeout_s. Distinct from our client timeout - the hub stopped it" ;;
        cancelled)
            ci_fail deploy.test \
                "action '$action' was CANCELLED (run ${rid:-?}). On this hub an admin lease revoke SIGTERMs a running action, so somebody may have taken the board" ;;
        *)
            ci_fail deploy.test \
                "action '$action' -> $state (run ${rid:-?}). THIS is the gate that is about the design; every gate above it is about getting to the board. Log: $(mf deploy.test.log)" ;;
    esac
}

# RELEASE IS A GATE, NOT HOUSEKEEPING.
#
# A leaked lease is invisible until somebody else cannot book the board, and then
# it is a person's afternoon. The dead-PID reaper does not help: it skips any
# lease whose holder is not the daemon's own hostname, which is every lease this
# toolkit takes. So the TTL and this gate are the whole of the safety net.
gate_release() {
    local released mode

    mode="$(mf deploy.mode)"
    if [ "$mode" = "dry-run" ]; then
        ci_skip deploy.release "DEPLOY_EXECUTE=0, so no lease was taken and none needed giving back"
        return
    fi
    if ! truthy "$(mf deploy.lease.acquired)"; then
        ci_skip deploy.release "no lease was acquired, so there was nothing to release"
        return
    fi

    released="$(mf deploy.release.result)"
    if ! ci_is_measured "$released"; then
        ci_unverified deploy.release \
            "a lease was acquired and nothing recorded whether it was given back. It frees itself $(mf deploy.lease.ttl_s)s after the last heartbeat and not before - the reaper skips leases held from this host, so nothing else will free it"
        return
    fi
    case "$released" in
        ok|released)
            ci_pass deploy.release "lease released (token-scoped, holder $(mf deploy.lease.holder))" ;;
        not-held)
            ci_warn deploy.release \
                "release reported no lease to release. The lease had already gone - expired, or cleared by an admin - so the board was unheld for some part of this run and the results above may not be attributable to this run alone" ;;
        *)
            ci_fail deploy.release \
                "release returned '$released'. The board stays held until the TTL ($(mf deploy.lease.ttl_s)s) runs out. DO NOT REVOKE IT: revoke is an admin force-release that is final for the holder, and every lease on this hub carries the same user - so it cannot tell your own stale lease from a colleague's live one. Retry: make deploy-release" ;;
    esac
}

#-----------------------------------------------------------------------------
# THE SELFTEST
#
# CONTRACT.md section 7: a check that cannot fail is not a check. Each case
# plants ONE fault in a throwaway manifest and requires the matching gate to go
# red, so the ids above are known to be REACHABLE rather than merely written.
#
# ITS LIMIT, SAID HERE RATHER THAN DISCOVERED LATER: these fixtures are what this
# author believes the driver records, and a fixture cannot disagree with its
# author. Passing proves the gate reads a manifest correctly. It does not prove
# the driver writes that manifest, and it does not prove the daemon sends what
# the driver believes. Only a run against real hardware closes those two joints,
# and until one happens they are UNPROVEN - see docs/DEPLOY.md.
#-----------------------------------------------------------------------------

# A manifest with every field good. Each case corrupts exactly one line, so a red
# result can only have been caused by the line that changed.
GOOD_MANIFEST='stage deploy
block selftest_block
run_tag selftest
deploy.mode execute
deploy.board_group group_placeholder
deploy.target group_placeholder_pl
deploy.preflight.program_method vivado_jtag
deploy.bitstream.path /srv/images/x.bit
deploy.bitstream.sha256 0000000000000000000000000000000000000000000000000000000000000000
deploy.stage.mode local
deploy.stage.server_path /srv/images/x.bit
deploy.lease.acquired yes
deploy.lease.held_at_program yes
deploy.lease.holder fpga-flow-selftest
deploy.lease.ttl_s 600
deploy.program.attempted yes
deploy.program.http_status 200
deploy.program.skipped no
deploy.program.fingerprint 000000000000
deploy.verify.program_verified yes
deploy.verify.done_property present
deploy.test.action selftest_action
deploy.test.dispatched yes
deploy.test.state ok
deploy.test.run_id run-0
deploy.release.result ok'

selftest() {
    local tmp rc fails=0 n=0
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/deploy-gates-selftest.XXXXXX")" || {
        echo "deploy-gates: cannot create a scratch directory" >&2; exit 2; }
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT

    ## case_is <gate id> <expected verdict> <sed expression>
    ## Applies one edit to the good manifest and requires that verdict for that
    ## gate. An empty edit leaves the manifest good, which is how the baseline
    ## rows below prove the fixture is green before anything claims a red.
    case_is() {
        local id="$1" want="$2" edit="$3" got
        n=$((n + 1))
        printf '%s\n' "$GOOD_MANIFEST" | sed "$edit" > "$tmp/m.txt"
        CI_VERDICT_DIR="$tmp/v" CI_COLOUR=0 \
            "$FLOW_DIR/ci/deploy-gates.sh" --manifest "$tmp/m.txt" >/dev/null 2>&1
        got="$(awk -F'\t' -v g="$id" '$3 == g { print $2; exit }' "$tmp/v/verdicts.tsv" 2>/dev/null)"
        if [ "$got" = "$want" ]; then
            printf '  ok    %-22s %-11s %s\n' "$id" "$want" "${edit:-<unmutated: the fixture itself must be green>}"
        else
            printf 'FAIL    %-22s want %-11s got %-11s %s\n' \
                   "$id" "$want" "${got:-<no verdict>}" "$edit" >&2
            fails=$((fails + 1))
        fi
        rm -rf "$tmp/v"
    }

    echo "deploy-gates selftest - one planted fault per case, each must go red"
    echo ""
    echo "  BASELINE - the unmutated fixture, which must be green or every red below proves nothing"
    case_is deploy.preflight PASS ''
    case_is deploy.lease     PASS ''
    case_is deploy.program   PASS ''
    case_is deploy.verify    PASS ''
    case_is deploy.test      PASS ''
    case_is deploy.release   PASS ''

    echo ""
    echo "  PREFLIGHT - the namespace split, the KR260 gap, the staging path"
    case_is deploy.preflight FAIL       's|^deploy.target .*|deploy.target |'
    case_is deploy.preflight FAIL       's|^deploy.preflight.program_method .*|deploy.preflight.program_method none|'
    case_is deploy.preflight UNVERIFIED '/^deploy.preflight.program_method /d'
    case_is deploy.preflight FAIL       's|^deploy.stage.server_path .*|deploy.stage.server_path images/x.bit|'
    case_is deploy.preflight UNVERIFIED '/^deploy.bitstream.sha256 /d'

    echo ""
    echo "  LEASE - the enforcement this toolkit is the only holder of"
    case_is deploy.lease FAIL       's|^deploy.lease.held_at_program .*|deploy.lease.held_at_program no|'
    case_is deploy.lease UNVERIFIED '/^deploy.lease.held_at_program /d'
    case_is deploy.lease UNVERIFIED 's|^deploy.lease.holder .*|deploy.lease.holder UNVERIFIED:not-recorded|'
    case_is deploy.lease SKIP       's|^deploy.mode .*|deploy.mode dry-run|'
    case_is deploy.lease FAIL       's|^deploy.lease.acquired .*|deploy.lease.why queued-position-2|'

    echo ""
    echo "  PROGRAM - including the daemon's ok:true skip path"
    case_is deploy.program FAIL       's|^deploy.program.http_status .*|deploy.program.http_status 400|'
    case_is deploy.program FAIL       's|^deploy.program.http_status .*|deploy.program.http_status 404|'
    case_is deploy.program FAIL       's|^deploy.program.http_status .*|deploy.program.http_status 401|'
    case_is deploy.program UNVERIFIED '/^deploy.program.http_status /d'
    case_is deploy.program FAIL       's|^deploy.program.skipped .*|deploy.program.skipped yes|'
    case_is deploy.program SKIP       's|^deploy.mode .*|deploy.mode dry-run|'

    echo ""
    echo "  VERIFY - the gate that must NOT launder a missing DONE into a pass"
    case_is deploy.verify FAIL       's|^deploy.verify.program_verified .*|deploy.verify.program_verified no|'
    case_is deploy.verify UNVERIFIED 's|^deploy.verify.done_property .*|deploy.verify.done_property none|'
    case_is deploy.verify UNVERIFIED '/^deploy.verify.program_verified /d'
    case_is deploy.verify UNVERIFIED 's|^deploy.program.skipped .*|deploy.program.skipped yes|'
    case_is deploy.verify UNVERIFIED 's|^deploy.program.attempted .*|deploy.program.attempted no|'

    echo ""
    echo "  TEST - the hub's own state vocabulary"
    case_is deploy.test FAIL       's|^deploy.test.state .*|deploy.test.state failed|'
    case_is deploy.test FAIL       's|^deploy.test.state .*|deploy.test.state rejected|'
    case_is deploy.test FAIL       's|^deploy.test.state .*|deploy.test.state timeout|'
    case_is deploy.test UNVERIFIED '/^deploy.test.state /d'
    case_is deploy.test SKIP       '/^deploy.test.action /d'
    case_is deploy.test UNVERIFIED 's|^deploy.test.dispatched .*|deploy.test.dispatched no|'

    echo ""
    echo "  RELEASE - a leaked lease is somebody else's afternoon"
    case_is deploy.release FAIL       's|^deploy.release.result .*|deploy.release.result http-500|'
    case_is deploy.release UNVERIFIED '/^deploy.release.result /d'
    case_is deploy.release WARN       's|^deploy.release.result .*|deploy.release.result not-held|'
    case_is deploy.release SKIP       's|^deploy.lease.acquired .*|deploy.lease.acquired no|'

    echo ""
    echo "  THE ABSENT RECORD - a deploy that recorded nothing and one that never ran"
    echo "  look identical from disk, and neither may be reported clean"
    n=$((n + 1))
    CI_VERDICT_DIR="$tmp/v" CI_COLOUR=0 \
        "$FLOW_DIR/ci/deploy-gates.sh" --manifest "$tmp/does-not-exist.txt" >/dev/null 2>&1
    rc=$?
    if [ "$rc" = "2" ]; then
        printf '  ok    %-22s %-11s %s\n' '(no manifest)' 'exit 2' 'refused, not reported clean'
    else
        printf 'FAIL    %-22s want exit 2 got exit %-4s %s\n' \
               '(no manifest)' "$rc" 'a deploy that recorded nothing must NOT exit 0' >&2
        fails=$((fails + 1))
    fi

    # AND A ZERO-BYTE ONE, which satisfies every `test -e` in the world and is
    # the shape a driver leaves when it opened its manifest and then died.
    n=$((n + 1))
    : > "$tmp/empty.txt"
    CI_VERDICT_DIR="$tmp/v" CI_COLOUR=0 \
        "$FLOW_DIR/ci/deploy-gates.sh" --manifest "$tmp/empty.txt" >/dev/null 2>&1
    rc=$?
    if [ "$rc" = "2" ]; then
        printf '  ok    %-22s %-11s %s\n' '(zero-byte manifest)' 'exit 2' 'absent and empty are told apart'
    else
        printf 'FAIL    %-22s want exit 2 got exit %-4s %s\n' \
               '(zero-byte manifest)' "$rc" 'a zero-byte manifest must NOT exit 0' >&2
        fails=$((fails + 1))
    fi

    printf '\n'
    if [ "$fails" -gt 0 ]; then
        printf '%d of %d selftest case(s) FAILED - these gates are not known to work\n' "$fails" "$n" >&2
        return 1
    fi
    printf '%d of %d: every gate goes red on its own planted fault.\n' "$n" "$n"
    printf '\n'
    printf 'What this does NOT prove: that scripts/fpga-flow-deploy writes these\n'
    printf 'fields, or that the daemon sends what it believes. Both need the rig.\n'
    return 0
}

#-----------------------------------------------------------------------------
# MAIN
#-----------------------------------------------------------------------------

if [ "$SELFTEST" = "1" ]; then
    selftest
    exit $?
fi

# LOCATE THE RECORD. --manifest wins; otherwise the run directory make exported.
if [ -z "$MANIFEST" ]; then
    if [ -n "${FPGA_REPORT_DIR:-}" ]; then
        MANIFEST="$FPGA_REPORT_DIR/deploy_manifest.txt"
    elif [ -n "${REPORT_DIR:-}" ]; then
        MANIFEST="$REPORT_DIR/deploy_manifest.txt"
    fi
fi

if [ -z "$MANIFEST" ]; then
    echo "deploy-gates: no manifest named and no FPGA_REPORT_DIR in the environment." >&2
    echo "              Pass --manifest <file>, or run this under make so that the" >&2
    echo "              run directory is exported." >&2
    exit 2
fi

ci_init

if [ ! -s "$MANIFEST" ]; then
    # REFUSED (exit 2), NOT FAILED (exit 1). CONTRACT.md section 10: 1 is "we
    # looked and found something", 2 is "we could not look", and a caller is
    # entitled to tell them apart. A verdict is recorded either way, so an
    # archived run does not merely go quiet.
    if [ -e "$MANIFEST" ]; then
        ci_unverified deploy.preflight \
            "$MANIFEST is ZERO BYTES - the driver opened its manifest and died before writing it. That satisfies every test -e in the world and is not a record"
    else
        ci_unverified deploy.preflight \
            "no $MANIFEST - this run recorded no deploy. That is not the same as a run that did not need one, and neither may be quoted as tested"
    fi
    ci_exit "deploy gates" >/dev/null 2>&1
    echo "deploy-gates: refusing to grade a deploy that left no record ($MANIFEST)" >&2
    exit 2
fi

ci_head "deploy gates - $MANIFEST"
gate_preflight
gate_lease
gate_program
gate_verify
gate_test
gate_release

# THE VERDICT ARTEFACT (CONTRACT.md section 5's fixed section structure), so a
# reader gets the four verdict classes rather than a pass/fail - including what
# this run did NOT measure, which on a deploy is most of what anybody wants.
if [ -n "$GATE_FILE" ]; then
    {
        printf 'DEPLOY gate, %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'design %s, run tag %s, board group %s, target %s\n' \
            "$(mf block)" "$(mf run_tag)" "$(mf deploy.board_group)" "$(mf deploy.target)"
        printf '\n'
        printf 'WHAT THIS IS: a grading of what scripts/fpga-flow-deploy recorded AT THE\n'
        printf 'TIME - the lease it held at the instant it programmed, the DONE readback\n'
        printf 'that followed, the action state that came back.\n'
        printf 'WHAT THIS IS NOT: a live check. By the time you read it the lease has been\n'
        printf 'released on purpose and the board may have been reprogrammed since. It says\n'
        printf 'this image reached this target and what happened next. It says NOTHING\n'
        printf 'about any other board, or about this board now.\n'
        printf '\n'
        if awk -F'\t' '$2=="FAIL" || $2=="UNVERIFIED" { found=1 } END { exit !found }' \
               "$CI_VERDICT_DIR/verdicts.tsv" 2>/dev/null; then
            printf 'HARD FAILURES:\n'
            awk -F'\t' '$2=="FAIL" || $2=="UNVERIFIED" { printf "  - %s: %s\n", $3, $4 }' \
                "$CI_VERDICT_DIR/verdicts.tsv"
        else
            printf 'HARD FAILURES: none\n'
        fi
        printf '\n'
        printf 'DECLARED ELSEWHERE - MEASURED HERE, OWNED BY SOMEBODY ELSE\n'
        printf '  - lease enforcement, owner=fpgahub: the program and action-dispatch\n'
        printf '    handlers do NOT check holdership. deploy.lease above is enforced by\n'
        printf '    this toolkit and by nothing on the server.\n'
        printf '  - dead-holder reaping, owner=fpgahub: the reaper skips a lease whose\n'
        printf '    holder is not the daemon host, so --pid is inert from here and the\n'
        printf '    TTL is the only net under a crashed run.\n'
        printf '  - DONE readback, owner=fpgahub program plugin: carried as a substring of\n'
        printf '    the run message, not as a field. A device with no DONE property\n'
        printf '    reports ok and proves nothing.\n'
        printf '\n'
        printf 'NOT covered by ANY run of this flow, at any setting:\n'
        printf '  - that the board on the bench is the one this name addresses\n'
        printf '  - anything about the board AFTER the lease was released\n'
        printf '  - whether a passing action exercised the design or only the harness\n'
        awk -F'\t' '$2=="SKIP" { printf "  - %s: %s\n", $3, $4 }' \
            "$CI_VERDICT_DIR/verdicts.tsv" 2>/dev/null
    } > "$GATE_FILE" 2>/dev/null || \
        echo "deploy-gates: could not write $GATE_FILE" >&2
fi

[ "$WANT_SUMMARY" = "1" ] && ci_summary_table "deploy gates"

ci_exit "deploy gates"
exit $?

# Copyright (C) 2026, SoC Labs (www.soclabs.org)
