#!/usr/bin/env bash
# Mutation-test one gate: apply a substitution, run a test target, restore.
#
# ⛔ THE CHECK THIS EXISTS FOR: a mutation that changed no bytes reads EXACTLY
# like an ornamental gate. Both are "I changed it and nothing happened." This
# script refuses the first case (exit 3) so it can never be mistaken for the
# second. Caught three times by hand in one session before being filed here;
# once because `mix format` had wrapped a line and a single-line pattern never
# matched.
#
# ⚠️ AN EMPTY TEST COUNT IN A "CAUGHT" LINE MEANS A COMPILE ERROR, NOT A TEST
#   FAILURE. Both exit non-zero and both print ✅ CAUGHT, but only one of them
#   shows that the ASSERTIONS can see the change. 2026-08-24: a caller loop used
#   `IFS='|' read` to split its cases, which split on the `|>` pipes inside the
#   Elixir being mutated — so two "mutations" were garbage that failed to
#   compile. The tool was right; the harness around it was not. ⇒ READ THE
#   COUNT, not the tick.
#
# ⚠️ A WEAKENING mutation always survives and proves nothing. Changing
#   `assert x == "expected"` to `assert is_binary(x)` reports SURVIVED, but a
#   weaker assertion cannot fail by construction — that is not evidence the gate
#   is ornamental. Mutate by INVERTING or by breaking the mechanism, not by
#   loosening. (Demonstrated: DEMO 4 in the commit that added this file.)
#
# Usage: bin/mutate.sh <file> <old> <new> [test target]
# Exit:  0 mutation was CAUGHT (gate works) · 1 mutation SURVIVED (gate suspect)
#        2 usage/precondition · 3 mutation changed nothing (malformed)

# ⭐ SAFE BY CONSTRUCTION, NOT SAFE BY THIS LINE — measured, not asserted.
# Removing `pipefail` changes NOTHING here: all three arms (caught / survived /
# malformed) return identical exit codes and text without it. Every gate's rc
# comes from a command's own status — `if mix test > "$LOG"` is a REDIRECT, not
# a pipeline — and the only pipes in this file are inside `echo "$(... | tail)"`,
# which reports a count and gates nothing.
# ⛔ The standard is commonplace-plan's: not "pipefail protects my gates" but
# "no gate depends on pipefail". A gate whose gating property rests on a shell
# option set elsewhere is ONE EDIT FROM DECORATION, and its failure mode is that
# it proceeds. If you add a gate here, keep it a redirect or capture rc.
# `-e` is deliberately absent: mix test's failure is HANDLED, not fatal.
set -uo pipefail

FILE="${1:-}"; OLD="${2:-}"; NEW="${3:-}"; TARGET="${4:-}"

if [[ -z "$FILE" || -z "$OLD" || -z "$NEW" ]]; then
  echo "usage: bin/mutate.sh <file> <old> <new> [test target]" >&2
  echo "  (nothing was changed)" >&2
  exit 2
fi
[[ -f "$FILE" ]] || { echo "no such file: $FILE (nothing was changed)" >&2; exit 2; }

# ⛔ Refuse to operate on a file with uncommitted changes: the restore below
# would silently discard them.
if ! git diff --quiet -- "$FILE" || ! git diff --cached --quiet -- "$FILE"; then
  echo "⛔ $FILE has uncommitted changes; commit or stash first (restore would clobber them)." >&2
  echo "   Nothing was changed — this refusal happens before any backup or edit." >&2
  exit 2
fi

BACKUP="$(mktemp)"
# ⛔⛔ VERIFY THE BACKUP BEFORE ARMING THE TRAP. If `cp` failed, $BACKUP is an
# EMPTY file and the restore below would TRUNCATE the caller's source to zero —
# a safety mechanism causing the exact harm it exists to prevent. `set -e` is
# deliberately not in use here (mix test's failure is handled, not fatal), so a
# failed cp would otherwise pass silently.
if ! cp "$FILE" "$BACKUP" || ! cmp -s "$FILE" "$BACKUP"; then
  rm -f "$BACKUP"
  echo "⛔ could not take a verified backup of $FILE — refusing to mutate. Nothing was changed." >&2
  exit 2
fi
# Restore on ANY exit, including a signal — a crash must never leave the tree
# mutated.
trap 'cp "$BACKUP" "$FILE"; rm -f "$BACKUP"' EXIT

python3 - "$FILE" "$OLD" "$NEW" <<'PY'
import io, sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
body = io.open(path, encoding="utf-8").read()
io.open(path, "w", encoding="utf-8").write(body.replace(old, new))
PY

if cmp -s "$BACKUP" "$FILE"; then
  echo "⛔ MALFORMED: the substitution changed no bytes — the pattern did not match."
  echo "   This is NOT a surviving mutation. Check for reflowed lines (mix format wraps)."
  echo "   $FILE has been RESTORED; the tree is as you left it."
  exit 3
fi

echo "mutation applied to $FILE ($(git diff --numstat -- "$FILE" | awk '{print $1"+ "$2"-"}'))"

LOG="$(mktemp)"
if mix test ${TARGET:+"$TARGET"} > "$LOG" 2>&1; then
  echo "⚠️  SURVIVED — the suite stayed green under this mutation."
  echo "   $(grep -oE '[0-9]+ tests?, [0-9]+ failures?' "$LOG" | tail -1)"
  rm -f "$LOG"
  exit 1
else
  echo "✅ CAUGHT — $(grep -oE '[0-9]+ tests?, [0-9]+ failures?' "$LOG" | tail -1)"
  rm -f "$LOG"
  exit 0
fi
