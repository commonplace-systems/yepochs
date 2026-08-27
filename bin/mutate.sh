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
# Usage: bin/mutate.sh [--dry-run] <file> <old> <new> [test target]
#   --dry-run applies the mutation, runs the expectation guard, restores, and
#   exits WITHOUT running the suite — so both arms of the guard are
#   demonstrable at zero cost to a busy box.
# Exit:  0 mutation was CAUGHT (gate works) · 1 mutation SURVIVED (gate suspect)
#        2 usage/precondition · 3 mutation changed nothing (malformed)
#        4 suite never ran (compile error) — NOT a catch
#        5 the mutation ALSO CHANGED THE EXPECTATIONS — no verdict available
#
# Works on a file with uncommitted changes; they are preserved. See the note
# below for the one case that is not covered (SIGKILL).

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

DRY_RUN=0

# ⭐ --self-test EXERCISES THE SHIPPED SCRIPT, NOT COPIES OF ITS PREDICATES.
# It re-invokes "$0" with real arguments and asserts the EXIT CODES, so every
# arm travels the same path a caller does. A demonstration against a duplicate
# proves the duplicate.
# ⛔ These arms were demonstrated BY HAND on 2026-08-27 and a hand
# demonstration does not fire again. Zero test runs: every arm is --dry-run or
# refused before the suite is reached.
if [[ "${1:-}" == "--self-test" ]]; then
  LIBF="$(ls lib/yepochs/*.ex 2>/dev/null | head -1)"
  TESTF="$(ls test/*_test.exs 2>/dev/null | head -1)"
  # ⛔ PROVE THE CORPUS IS NON-EMPTY BEFORE TRUSTING ANY RESULT FROM IT. A
  # missing fixture would make every arm below fail for the wrong reason.
  [[ -n "$LIBF" && -n "$TESTF" ]] || { echo "SELF-TEST BLIND: no lib/test fixture found"; exit 2; }
  grep -q defmodule "$LIBF" || { echo "SELF-TEST BLIND: 'defmodule' absent from $LIBF"; exit 2; }
  grep -q assert "$TESTF"    || { echo "SELF-TEST BLIND: 'assert' absent from $TESTF"; exit 2; }

  BEFORE="$(git status --porcelain | sha256sum)"

  # GREEN: a lib mutation leaves test/ untouched -> guard passes, no suite run.
  "$0" --dry-run "$LIBF" 'defmodule' 'defmodulex' >/dev/null 2>&1
  [[ $? -eq 0 ]] || { echo "SELF-TEST FAILED: green arm did not return 0"; exit 1; }

  # FACE (1): a substitution that matches nothing must be MALFORMED, not a
  # verdict. An unchanged file passing reads exactly like a working gate.
  "$0" --dry-run "$LIBF" 'zzz-absent-token-zzz' 'x' >/dev/null 2>&1
  [[ $? -eq 3 ]] || { echo "SELF-TEST FAILED: face (1) did not return 3"; exit 1; }

  # FACE (3): mutating a test file moves the expectation with the target.
  "$0" --dry-run "$TESTF" 'assert' 'refute' >/dev/null 2>&1
  [[ $? -eq 5 ]] || { echo "SELF-TEST FAILED: face (3) did not return 5"; exit 1; }

  # ⛔ AND THE RESTORE IS PART OF THE CONTRACT: three mutations were applied to
  # real files. If any survived, the tool is worse than useless.
  AFTER="$(git status --porcelain | sha256sum)"
  [[ "$BEFORE" == "$AFTER" ]] || { echo "SELF-TEST FAILED: tree not restored"; exit 1; }

  echo "self-test ok: green=0 face1=3 face3=5, tree restored"
  exit 0
fi

if [[ "${1:-}" == "--dry-run" ]]; then DRY_RUN=1; shift; fi

FILE="${1:-}"; OLD="${2:-}"; NEW="${3:-}"; TARGET="${4:-}"

if [[ -z "$FILE" || -z "$OLD" || -z "$NEW" ]]; then
  echo "usage: bin/mutate.sh <file> <old> <new> [test target]" >&2
  echo "  (nothing was changed)" >&2
  exit 2
fi
[[ -f "$FILE" ]] || { echo "no such file: $FILE (nothing was changed)" >&2; exit 2; }

# ⛔ THIS SCRIPT USED TO REFUSE A FILE WITH UNCOMMITTED CHANGES, AND THE REASON
# WAS FALSE. The stated reason was "the restore would silently discard them".
# It would not: the backup is `cp "$FILE" "$BACKUP"` — the file AS IT IS,
# uncommitted changes included — so the restore puts back exactly what was
# there. Measured: a scratch line added to a file survives a full mutate run
# byte-identical.
#
# ⭐ AND THE FALSE GUARD CHANGED ITS USER'S BEHAVIOUR, WHICH IS THE PART WORTH
# KEEPING. To satisfy it I twice ran `git commit -m "wip"` purely as scratch,
# and one of those escaped into pushed history (c71c706). ⇒ A precondition that
# is not actually required does not merely annoy — it manufactures a worse
# habit, and the evidence was in my own git log.
#
# ⚠️ THE REAL RESIDUAL RISK, which is narrower and true: the EXIT trap covers
# every ordinary exit and every catchable signal, but NOT SIGKILL. If this is
# `kill -9`ed mid-run the mutation persists. With the file committed you recover
# with `git checkout --`; with uncommitted changes you do not. That is a caveat
# to state, not a reason to refuse.

# ⛔⛔ FACE (3) OF THE MUTATION TRAP: THE MUTATION MOVES THE EXPECTATION WITH IT.
# A blanket substitution over a file that holds BOTH the code and its assertion
# changes both — and the suite then asserts a function equal to itself and
# prints a PASS that reads exactly like a working gate.
#
# The three faces, complete:
#   (1) the mutation never applied            -> caught below, exit 3
#   (2) it applied, the red came from a broken harness -> caught below, exit 4
#   (3) IT APPLIED AND MOVED THE EXPECTATION  -> caught here, exit 5
#
# ⭐ THE STRUCTURAL ESCAPE COMES FIRST AND THIS IS ONLY THE DETECTOR. The check
# and the thing checked must not live where ONE EDIT REACHES BOTH: compute one
# side of the comparison, select the mutation by dispatch instead of editing, or
# keep the expectations in a different file. This repo pays the third — targets
# live in `lib/`, assertions in `test/` — but only BY CONVENTION: nothing stopped
# this script being pointed at a test file, and then one edit reaches both.
# ⇒ The fingerprint makes the convention enforceable rather than remembered.
expectation_fingerprint() {
  # Every .exs under test/, content-hashed. Uncommitted changes included, so
  # this works on a dirty tree exactly as the backup/restore does.
  find test -name '*.exs' -type f -print0 2>/dev/null \
    | sort -z | xargs -0 cat 2>/dev/null | sha256sum | awk '{print $1}'
}
EXPECT_BEFORE="$(expectation_fingerprint)"

# ⛔ THE FINGERPRINT WATCHES `test/` ONLY, SO IT IS BLIND WHERE A FILE HOLDS ITS
# OWN ASSERTIONS. A DOCTEST IS EXACTLY THAT: the `iex>` example and the code it
# exercises live in the SAME lib file, so a substitution can move both and the
# fingerprint never changes.
# ⚠️ LATENT ON TODAY'S TREE AND CLOSED ANYWAY — measured 2026-08-27: zero `iex>`
# examples in lib/, so this cannot fire on the current tree. It fires the moment
# a doctest is added, which is precisely when it would otherwise start lying.
# ⭐ Demonstrated by inducing a doctest rather than by reasoning about it.
if grep -q 'iex>' "$FILE" 2>/dev/null; then
  echo "⛔ $FILE CONTAINS ITS OWN EXPECTATIONS (a doctest: 'iex>')."
  echo "   The check and the thing checked live in one file, so a substitution"
  echo "   can move BOTH and no fingerprint of test/ would notice. That is"
  echo "   face (3), unobservable from here — refusing rather than reporting a"
  echo "   verdict this tool cannot support."
  echo "   ⇒ Scope the mutation to a line, or move the example into test/."
  echo "   Nothing was changed."
  exit 5
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

# ⛔ THE GUARD. Assert the EXPECTATION IS UNCHANGED -- not merely that the target
# changed. Placed BEFORE the suite runs, so the refusal costs no test run at all.
EXPECT_AFTER="$(expectation_fingerprint)"
if [[ "$EXPECT_BEFORE" != "$EXPECT_AFTER" ]]; then
  echo "⛔ FACE (3): THE MUTATION ALSO CHANGED THE EXPECTATIONS."
  echo "   Files under test/ moved with the target, so any green would be a"
  echo "   function asserted equal to itself. This is NOT a surviving mutation"
  echo "   and NOT a catch — no verdict is available from this run."
  echo "   before: $EXPECT_BEFORE"
  echo "   after:  $EXPECT_AFTER"
  echo "   ⇒ Scope the substitution to the asserted line, or mutate lib/ only."
  echo "   $FILE has been RESTORED; the tree is as you left it."
  exit 5
fi

echo "mutation applied to $FILE ($(git diff --numstat -- "$FILE" | awk '{print $1"+ "$2"-"}'))"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "--dry-run: mutation applied and the expectation guard PASSED; no suite run."
  echo "   $FILE will be RESTORED on exit."
  exit 0
fi

LOG="$(mktemp)"
# ⛔ THE FAILING TEST NAME IS THE EVIDENCE, AND A COUNT IS NOT IT.
# This used to print "N tests, M failures" and then `rm -f "$LOG"` — destroying
# the only record of WHICH test failed. That is fine for an expected mutation
# result and catastrophic for an unexpected one: a flaky or concurrency-induced
# failure inside a mutation run would be reported as a successful catch, with
# the name gone. Two repos in this fleet lost a name exactly this way on the
# same afternoon, one of them to `tail -1`.
# ⇒ The log is KEPT and its path printed. The re-run is what destroys the
# evidence, so the evidence has to outlive the first run.
if mix test ${TARGET:+"$TARGET"} > "$LOG" 2>&1; then
  echo "⚠️  SURVIVED — the suite stayed green under this mutation."
  echo "   $(grep -oE '[0-9]+ tests?, [0-9]+ failures?' "$LOG" | tail -1)"
  echo "   full output: $LOG"
  exit 1
else
  COUNT="$(grep -oE '[0-9]+ tests?, [0-9]+ failures?' "$LOG" | tail -1)"
  # ⛔ NO COUNT AT ALL MEANS THE SUITE NEVER RAN — a compile error, not a caught
  # mutation. Both exit non-zero; only one shows the assertions saw the change.
  # Said here rather than left to the reader: this case has been misread three
  # times in one session by the person who wrote the warning in this header.
  if [[ -z "$COUNT" ]]; then
    echo "⚠️  NOT A CATCH — the suite produced no test count, so it never ran."
    echo "   This is almost certainly a COMPILE ERROR from a malformed mutation."
    echo "   full output: $LOG"
    exit 4
  fi
  echo "✅ CAUGHT — $COUNT"
  # ⭐ Name every failing test, in full. If a name here is NOT one you expected
  # this mutation to break, you have found something else — do not re-run before
  # reading $LOG.
  grep -E '^\s+[0-9]+\) (test|property) ' "$LOG" | sed 's/^/   /'
  echo "   full output: $LOG"
  exit 0
fi
