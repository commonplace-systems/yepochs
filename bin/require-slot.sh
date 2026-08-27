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
# prompt calls nothing in this file, and no token can see it.
#
# ⛔ CORRECTION, 2026-08-27: an earlier version of this comment illustrated that
# limit with another door's "seven silent suites". THAT WAS WRONG, and the door
# itself corrected it -- those suites ran through its OWN gate script, above
# whose `mix test` line the check sits, so a token WOULD have refused all seven.
# ⇒ That case is the argument FOR this file, not against it.
# ⭐ Kept with the correction stacked rather than amended away, because the
# error is the instructive part: I took a plausible fit as evidence WITHOUT
# CHECKING IT, in the file about not doing that. The real residue is the HABIT
# route -- suites typed by hand, invisible to every grep at every door.

# ⛔⛔ SCOPE: GATE EVERY SUITE-STARTER *YOU INVOKE AS A DOOR IN A QUEUE* -- NOT
# EVERY SUITE-STARTER. `bin/mutate.sh` is a REPOSITORY ARTIFACT: it must work
# for CI and for anyone who clones this tree. Gating it unconditionally on a
# token file would ENCODE A TRANSIENT SOCIAL PROTOCOL INTO A LIBRARY, and a
# fresh clone would refuse to run for a reason found nowhere in its history.
#
# ⭐ POLARITY: FAIL-OPEN FOR THE LIBRARY, FAIL-CLOSED FOR THE OPERATOR.
# Enforcement is keyed on a marker the OPERATOR creates (`.slot-protocol`,
# gitignored). No marker -> no gating, which is every clone and every CI run.
# Marker present -> a token is required, which is this machine during a queue.
#
# ⚠️ AND THE MARKER IS THE MECHANISM, NOT MY MEMORY: it persists across
# invocations, so "am I in a queue" is answered by the filesystem rather than
# by whether I remembered when I typed the command.

# require_slot <what>  -- refuses at 76 unless a token exists; CONSUMES it.
# No-ops entirely unless the operator marker is present.
require_slot() {
  local what="${1:-this run}" token="${SLOT_TOKEN:-.slot-granted}"
  local marker="${SLOT_PROTOCOL:-.slot-protocol}"

  if [[ ! -f "$marker" ]]; then
    return 0   # not operating under a queue protocol; this is a plain repo tool
  fi

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
