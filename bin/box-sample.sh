#!/usr/bin/env bash
# Run a command while sampling `available` memory, and report the MINIMUM.
#
# ⛔ A PRE-FLIGHT ANSWERS "MAY I START". IT CANNOT ANSWER "WHAT DID MY RUN DO TO
# THE BOX." Measured by `yelixer` 2026-08-27: pre-flight 4286 MB, post-run
# 4351 MB, and the MINIMUM ACROSS 174 SAMPLES DURING THE RUN WAS 934 MB — 566 MB
# below the fleet danger line. A before/after pair certifies a clean window that
# never existed.
#
# ⭐ The minimum is the number. You cannot get a minimum from the endpoints.
#
# ⭐ WHICH OF THIS SCRIPT'S ARMS ARE ACTUALLY PROVEN — and which are latent, which have
#   unexercised wiring, and which is DOWNSTREAM OF THE GUARDED ACTION and cannot be
#   stubbed at all — is recorded in docs/THRESHOLD-AUDIT.md. Read it before trusting a
#   green from here.
# ⛔ The pointer is HERE, in the script you are running, because a filed artifact fires
#   only if something reads it: that audit had one referrer (README) and none from the
#   scripts it documents.
#
# Usage:  bin/box-sample.sh [-i SECS] -- <command...>
#         bin/box-sample.sh --self-test
#
# Exit status is the COMMAND's, not the sampler's -- so this wraps a gate
# without becoming one.

set -uo pipefail

INTERVAL=1

# ⭐ The reducer is separated from the sampling so it can be tested WITHOUT
# running anything or allocating memory. A minimum-finder that has never been
# shown to find a minimum is decoration.
min_of() {
  awk 'NR==1||$1<m{m=$1} END{if(NR==0) print "NONE"; else print m}'
}

max_of() {
  awk 'NR==1||$1>m{m=$1} END{if(NR==0) print "NONE"; else print m}'
}

# ⛔ `available` ALONE IS THE OPTIMISTIC FIGURE. One process on this box faulted
# 2.4 GB back in and released it again inside fifteen minutes -- same pid, never
# restarted, readings 2605 -> 385 -> 317 -> 2768 -> 298. That single
# oscillation is larger than the whole fleet's danger margin.
# ⇒ The number to judge on is the headroom you would have IF IT FAULTS BACK IN
# MID-RUN:   available - (peak_rss - current_rss)
#
# ⚠️ 2768 is an OBSERVED peak (2026-08-27), not a bound. The sampler also tracks
# the largest value IT sees and uses whichever is greater, so the figure cannot
# be flattered by a peak that has already been exceeded.
# ⭐ USE `VmHWM`, NOT THE LARGEST SAMPLE ANYONE HAPPENED TO TAKE. The observed
# peak (2768 MB) is a READING; `VmHWM` is a PROPERTY of the process, it only
# moves up, and it is immune to the sampling luck that produced the reading.
# Measured on the same pid the same evening: VmHWM 2854 > 2768 — the sampled
# peak was already stale when it was published.
# ⛔⛔ NO FALLBACK CONSTANT. An earlier cut of this file returned 2768 when the
# /proc read failed, so a BOGUS PID PRODUCED A CONFIDENT-LOOKING 2768 and that
# fabricated term entered the arithmetic indistinguishably from a measurement.
# ⚠️ It erred in the CONSERVATIVE direction, which is luck, not design — the
# defect is that a number nobody measured was printed as one that somebody did.
# ⭐ AND THE TWO ABSENCES DO NOT SHARE A CODE PATH: "the serve was not found"
# and "the serve was found and its /proc read failed" are different failures,
# and guarding only the first leaves the second computing on a sentinel.
# ⇒ Return NOTHING and let `is_num` refuse downstream. UNVERIFIABLE, not a value.
serve_hwm_mb() {
  awk '/^VmHWM:/{print int($2/1024)}' "/proc/$1/status" 2>/dev/null
}

# ⭐ SELECTOR, STATED: among `beam.smp` processes ONLY, the one whose
# /proc/PID/cwd contains $SERVE_CWD_MATCH.
# ⛔ Located by cwd, NEVER by `pgrep -f` on a typed pattern -- that matches the
# searching shell's own command line. A cwd cannot match this script, because
# this script does not run from the serve's directory.
SERVE_CWD_MATCH="${SERVE_CWD_MATCH:-serve}"

serve_pid() {
  local p cwd
  for p in $(pgrep -x beam.smp 2>/dev/null); do
    cwd="$(readlink "/proc/$p/cwd" 2>/dev/null)" || continue
    case "$cwd" in *"$SERVE_CWD_MATCH"*) echo "$p"; return 0 ;; esac
  done
  return 1
}

# ⭐ A missing measurement must never reach arithmetic, where it becomes 0.
is_num() { [[ "$1" =~ ^-?[0-9]+$ ]]; }

rss_mb() {
  awk '/^VmRSS:/{print int($2/1024)}' "/proc/$1/status" 2>/dev/null
}

if [[ "${1:-}" == "--self-test" ]]; then
  # Known series, known answer. Both arms: a dip in the middle, and empty input.
  got="$(printf '4286\n934\n4351\n' | min_of)"
  [[ "$got" == "934" ]] || { echo "SELF-TEST FAILED: dip -> $got, want 934"; exit 1; }
  got="$(printf '' | min_of)"
  [[ "$got" == "NONE" ]] || { echo "SELF-TEST FAILED: empty -> $got, want NONE"; exit 1; }
  # ⛔ And the negative arm: prove the finder is not just echoing the FIRST value.
  got="$(printf '100\n200\n300\n' | min_of)"
  [[ "$got" == "100" ]] || { echo "SELF-TEST FAILED: ascending -> $got"; exit 1; }
  got="$(printf '300\n200\n100\n' | min_of)"
  [[ "$got" == "100" ]] || { echo "SELF-TEST FAILED: descending -> $got"; exit 1; }
  # ⭐ max_of, the OTHER reducer -- it feeds the reserve term.
  got="$(printf '297\n1803\n345\n' | max_of)"
  [[ "$got" == "1803" ]] || { echo "SELF-TEST FAILED: max -> $got, want 1803"; exit 1; }
  got="$(printf '' | max_of)"
  [[ "$got" == "NONE" ]] || { echo "SELF-TEST FAILED: max empty -> $got, want NONE"; exit 1; }

  # ⛔⛔ THESE TWO ARMS EXIST BECAUSE THEY WERE MISSING WHILE I "DEMONSTRATED"
  # THEM. A REACHABILITY OR SELF CHECK IS ITSELF A CHECK, SO IT MUST TEST THE
  # THING UNDER TEST -- and I had exercised `is_num` from a RE-DECLARED COPY in
  # a `bash -c`, and `serve_hwm_mb` from a `sed`-EXTRACTED COPY. Both passed.
  # Neither touched the function this script actually calls.
  # ⇒ A demonstration against a duplicate proves the duplicate.
  for v in 12 -3 0; do
    is_num "$v" || { echo "SELF-TEST FAILED: is_num rejected [$v]"; exit 1; }
  done
  for v in "" "NONE" "1.5" "12x" " 12"; do
    ! is_num "$v" || { echo "SELF-TEST FAILED: is_num accepted [$v]"; exit 1; }
  done

  # ⛔ An unverifiable reading must resolve to NO NUMBER -- not to the
  # comfortable one and NOT TO THE CAUTIOUS ONE. "I could not read it" is a
  # THIRD STATE. pid 0 has no /proc/0/status on Linux.
  got="$(serve_hwm_mb 0)"
  [[ -z "$got" ]] || { echo "SELF-TEST FAILED: unreadable pid -> [$got], want empty"; exit 1; }
  is_num "$got" && { echo "SELF-TEST FAILED: unreadable pid reached arithmetic"; exit 1; }

  echo "self-test ok: min(dip/empty/asc/desc) max(peak/empty) is_num(3 accept,5 reject) hwm(unreadable=empty)"
  exit 0
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i) INTERVAL="$2"; shift 2 ;;
    --) shift; break ;;
    *) echo "usage: $0 [-i SECS] -- <command...>" >&2; exit 2 ;;
  esac
done

[[ $# -gt 0 ]] || { echo "usage: $0 [-i SECS] -- <command...>" >&2; exit 2; }

SAMPLES="$(mktemp)"
SERVE_SAMPLES="$(mktemp)"
# ⭐ ONE trap, covering every temp. A second `trap ... EXIT` REPLACES the first
# rather than adding to it -- measured elsewhere in this fleet, and shipped by
# the repo that had published the rule.
trap 'rm -f "$SAMPLES" "$SERVE_SAMPLES"' EXIT

SERVE_PID="$(serve_pid || true)"
( while :; do
    free -m | awk '/Mem:/ {print $7}' >> "$SAMPLES"
    if [[ -n "$SERVE_PID" ]]; then rss_mb "$SERVE_PID" >> "$SERVE_SAMPLES"; fi
    sleep "$INTERVAL"
  done ) &
# ⛔ Captured PID. NEVER `pkill -f` a pattern that appears in this script's own
# command line -- the shell matches itself.
SAMPLER_PID=$!

# ⚠️ INDIRECTION: THIS LINE CAN START ANYTHING, INCLUDING A SUITE. A literal
# grep for `mix test` is structurally blind to it -- the command is an argument,
# not text in this file. Enumerating suite-starters by symbol misses every
# wrapper, exactly as a repo grep misses a dependency that lives in a habit.
# ⭐ DELIBERATELY UNGATED, and this is a decision rather than an oversight: an
# INSTRUMENT must be usable to measure anything, and a measuring tool that
# demands permission cannot measure the thing you needed permission to see.
# ⇒ The gate lives in `bin/with-slot.sh`, which requires a token and THEN
# delegates here. If you invoke this directly with an expensive command, you are
# outside the interlock on purpose.
"$@"
STATUS=$?

# ⛔⛔ THE CLEANUP OF A SAMPLER MUST NEVER BE ABLE TO FAIL THE RUN IT MEASURED.
# Measured elsewhere in this fleet: under `set -e`, `wait` on a killed child
# exits 143 and `kill` on an already-dead pid exits 1 -- so a cleanup defect
# killed two landings AFTER both suites had passed and BEFORE a word was
# printed about them. A successful run left no trace and the rc named a signal
# nothing had sent.
# ⭐ SAFE BY CONSTRUCTION, NOT SAFE BECAUSE `-e` IS ABSENT. This file does not
# set `-e` today, and that is the kind of protection one hygiene commit removes.
# `|| true` holds either way.
# ⚠️ STATUS is captured ABOVE, before any of this runs -- the wrapped command's
# verdict must not be reachable by the teardown.
kill "$SAMPLER_PID" 2>/dev/null || true
wait "$SAMPLER_PID" 2>/dev/null || true

N="$(wc -l < "$SAMPLES" | tr -d ' ')"
MIN="$(min_of < "$SAMPLES")"
# ⭐ THIRD FIELD: WHAT THE WINDOW COVERS. A sampler started late is a partial
# instrument that reads exactly like a complete one. This one starts BEFORE the
# command and stops AFTER it, so it covers the whole run by construction --
# which is worth PRINTING, because a line that omits its coverage is
# indistinguishable from one whose coverage is a tail.
echo "box: ${N} samples, MINIMUM available=${MIN} MB (interval ${INTERVAL}s, window: WHOLE RUN -- sampler started before the command and stopped after it)"

# ⛔ A MISSING MEASUREMENT MUST NOT RESOLVE TO THE REASSURING VALUE. If the
# serve was not found, treating its RSS as 0 would print a COMFORTABLE headroom
# number from an absence. Say "unknown" instead.
if [[ -z "$SERVE_PID" ]]; then
  echo "     serve: NOT FOUND (selector: beam.smp with cwd matching '${SERVE_CWD_MATCH}')"
  echo "     ⇒ pessimistic headroom UNKNOWN — the ${MIN} MB above is the OPTIMISTIC figure."
else
  SERVE_MAX="$(max_of < "$SERVE_SAMPLES")"
  HWM="$(serve_hwm_mb "$SERVE_PID")"
  # ⛔ SAFE BY CONSTRUCTION, NOT SAFE-IF-THE-GUARD-FIRES. Bash arithmetic treats
  # an empty or non-numeric value as 0, so `$(( MIN - (HWM - SERVE_MAX) ))` on a
  # missing reading prints a PLAUSIBLE NUMBER rather than failing. Every operand
  # is checked to be an integer before any arithmetic happens.
  if is_num "$MIN" && is_num "$SERVE_MAX" && is_num "$HWM"; then
    RESERVE=$(( HWM - SERVE_MAX ))
    HEADROOM=$(( MIN - RESERVE ))
    # ⭐ PRINT ALL THREE, because a reserve derived from a MONOTONIC high-water
    # mark is a RATCHET: VmHWM only moves up and nothing but a restart resets
    # it, so a criterion built on it gets harder to satisfy forever and never
    # easier -- and each individual reading looks defensible while it drifts.
    # Printing the reserve beside its inputs makes the drift READABLE instead of
    # invisible. (A single number has nothing to disagree with.)
    # ⚠️ HONEST LABEL: VmHWM is the most this process has EVER held SINCE IT
    # STARTED -- not the most it holds. Those diverge further every day it is up.
    echo "     serve: pid ${SERVE_PID} · rss now ${SERVE_MAX} MB · VmHWM ${HWM} MB (peak since start, monotonic)"
    echo "     ⇒ reserve ${RESERVE} MB · PESSIMISTIC headroom ${HEADROOM} MB"
  else
    echo "     serve: pid ${SERVE_PID}, a reading was missing (min=${MIN:-<empty>} rss=${SERVE_MAX:-<empty>} hwm=${HWM:-<empty>})"
    echo "     ⇒ headroom UNVERIFIABLE — no number printed from a missing measurement."
  fi
fi
# ⚠️ A sample count of 0 or 1 means the run was shorter than the interval: the
# minimum is then an endpoint reading again, with none of its authority.
if [[ "$N" -lt 2 ]]; then
  echo "⚠️  ${N} sample(s) -- too short to be a DURING reading; treat as an endpoint."
fi
exit "$STATUS"
