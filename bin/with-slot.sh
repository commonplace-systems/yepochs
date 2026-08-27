#!/usr/bin/env bash
# Refuse to run anything expensive without a granted slot token.
#
# ⛔ THE BOX BEING CLEAR IS PERMISSION FROM THE HOST, NOT FROM THE ORDERING.
# `suites == 0` is a CHECK, NOT A LOCK: every door observing it independently
# clears at the same instant, so the more disciplined everyone is about
# checking, the more precisely they synchronise. Measured 2026-08-27 --
# four suites started within seconds of each other, every pre-flight honest.
#
# ⭐ THE THING THAT PROTECTS YOU MUST NOT BE YOUR ATTENTION AT THE MOMENT YOU
# MOST WANT TO PROCEED -- and the moment your waiter goes green is exactly that
# moment. This gates the SCRIPT, not your classification of what you are doing,
# which is the failure mode of "I was thinking *demonstrate a step* and the
# thing I typed was *start a suite*".
#
# Usage:  bin/with-slot.sh <command...>
#         SLOT_TOKEN=path bin/with-slot.sh ...   (default: .slot-granted)
# Exit:   76 no slot token -- nothing was run
#         otherwise the wrapped command's own status, via bin/box-sample.sh

set -uo pipefail

TOKEN="${SLOT_TOKEN:-.slot-granted}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -eq 0 ]]; then
  echo "usage: bin/with-slot.sh <command...>" >&2
  exit 2
fi

# ⭐ ONE statement of the rule, sourced -- not a second copy of it.
# shellcheck source=bin/require-slot.sh
. "$HERE/require-slot.sh"
require_slot "the wrapped command" || exit 76
exec "$HERE/box-sample.sh" -i 2 -- "$@"
