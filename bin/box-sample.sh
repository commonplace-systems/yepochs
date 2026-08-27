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
  echo "self-test ok: dip=934 empty=NONE ascending=100 descending=100"
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
# ⭐ ONE trap, covering every temp. A second `trap ... EXIT` REPLACES the first
# rather than adding to it -- measured elsewhere in this fleet, and shipped by
# the repo that had published the rule.
trap 'rm -f "$SAMPLES"' EXIT

( while :; do
    free -m | awk '/Mem:/ {print $7}' >> "$SAMPLES"
    sleep "$INTERVAL"
  done ) &
# ⛔ Captured PID. NEVER `pkill -f` a pattern that appears in this script's own
# command line -- the shell matches itself.
SAMPLER_PID=$!

"$@"
STATUS=$?

kill "$SAMPLER_PID" 2>/dev/null
wait "$SAMPLER_PID" 2>/dev/null

N="$(wc -l < "$SAMPLES" | tr -d ' ')"
MIN="$(min_of < "$SAMPLES")"
echo "box: ${N} samples during run, MINIMUM available=${MIN} MB (interval ${INTERVAL}s)"
# ⚠️ A sample count of 0 or 1 means the run was shorter than the interval: the
# minimum is then an endpoint reading again, with none of its authority.
if [[ "$N" -lt 2 ]]; then
  echo "⚠️  ${N} sample(s) -- too short to be a DURING reading; treat as an endpoint."
fi
exit "$STATUS"
