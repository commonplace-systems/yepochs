#!/usr/bin/env bash
# ONE statement of the slot rule, with every caller sourcing it.
#
# ⛔ A TOKEN THAT GATES YOUR WRAPPER IS NOT A TOKEN THAT GATES YOUR REPO.
# Measured 2026-08-27: `bin/with-slot.sh` was gated and `bin/mutate.sh:228` --
# THE ONLY REAL SUITE INVOCATION IN THIS REPO -- was not. The wrapper nobody is
# obliged to call was protected; the thing that actually starts a suite was not.
#
# ⭐ ONE STATEMENT, MANY CALLERS. Two statements of one rule cannot be kept in
# step by attention, and attention is not a mechanism.
#
# ⚠️ THIS NARROWS THE HOLE, IT DOES NOT CLOSE IT. A bare `mix test` typed at a
# prompt calls nothing in this file -- which is exactly how seven silent suites
# escaped at another door tonight. Stated here so no reader mistakes it for a
# lock on the repo.

# require_slot <what>  -- refuses at 76 unless a token exists; CONSUMES it.
require_slot() {
  local what="${1:-this run}" token="${SLOT_TOKEN:-.slot-granted}"
  if [[ ! -f "$token" ]]; then
    echo "⛔ REFUSED rc76: no slot token at '$token' — $what was NOT started." >&2
    echo "   The box being clear is permission from the HOST, not from the ORDERING." >&2
    echo "   When the queue names you:  touch $token" >&2
    return 76
  fi
  # ⭐ CONSUMED, not read. A token that survives its run is a standing
  # permission, and a standing permission is not a slot.
  rm -f "$token"
  echo "✅ slot token consumed for $what."
  return 0
}
