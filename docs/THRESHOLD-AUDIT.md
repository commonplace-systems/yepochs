# Threshold and guard audit

**Date:** 2026-08-27 · **Rule:** a labelled gap beats a manufactured green.

Every guard in this repo, and *how far* it has actually been demonstrated. The distinction that
matters is **predicate demonstrated** (the logic was exercised) versus **wiring demonstrated** (the
path a real caller travels was exercised). They are not the same claim and this file will not
merge them.

## ✅ Demonstrated red AND green, through the shipped path

| guard | red arm seen | notes |
|---|---|---|
| `bin/mutate.sh` face (1) — substitution changed nothing | ✅ exit 3 | also hit BY HAND today via a `sed` that never matched |
| `bin/mutate.sh` face (3) — mutation moved the expectation | ✅ exit 5 | `assert`→`refute` on a test file |
| `bin/mutate.sh --self-test` itself | ✅ both guards disabled in turn, each named its arm | scoped mutations; self-test block verified byte-identical |
| `bin/box-sample.sh` `is_num` | ✅ regex → `.*` → `is_num accepted []` | |
| `bin/box-sample.sh` `min_of`/`max_of` | ✅ | dip, empty, ascending, descending |
| `bin/box-sample.sh` serve NOT FOUND ⇒ UNKNOWN | ✅ | pointed at a cwd that cannot match |
| `mix check` `test` stage catches a timeout | ✅ rc=2 `ExUnit.TimeoutError` | and `--trace` rc=0, proving the mode matters |
| `test/fixture_coverage_test.exs` corpus check | ✅ | see LATENT below — required inducing a nested file |
| `box-sample.sh` cleanup cannot fail the measured run | ✅ | run under a forced `set -e`: wrapped command's rc 9 survives, not the cleanup's |
| `with-slot.sh` refuses without a token | ✅ rc 76, nothing run | the wrapped command was written to print if reached; it did not |
| `with-slot.sh` consumes the token | ✅ | second invocation refuses — a token that survives its run is a standing permission, not a slot |
| `mutate.sh` suite path refuses without a token | ✅ rc 76 in 18 ms | and the file is **never touched**: `git diff` empty |
| `mutate.sh --self-test` / `--dry-run` stay ungated | ✅ | they start nothing, so requiring a token would make the cheap path lie |
| `box-sample.sh` UNVERIFIABLE branch, **in a live run** | ✅ | fired unplanned in a 1-sample window: serve pid found, no rss sample landed, no number printed |
| `box-sample.sh` `< 2 samples` warning | ✅ | same run |

## ⚠️ Predicate demonstrated · WIRING NOT

| guard | what is proven | what is NOT |
|---|---|---|
| `serve_hwm_mb` on an unreadable `/proc` | passing a bogus pid returns EMPTY and is refused downstream | a `/proc` read **failing on a pid that WAS found**. Those are different absences on different code paths, and I cannot make the second happen on demand. ⚠️ A live run has now hit the UNVERIFIABLE *branch* (no rss sample landed in a 1-sample window) — that is a DIFFERENT CAUSE reaching the same branch, and it does **not** close this row. |
| `with-slot.sh` green path into `mix check` | the wrapper, the token consume, and the sampler hand-off are exercised with a cheap command | ⛔ never run with `mix check` as the command — that is the queued slot run |
| `mutate.sh` suite path GREEN (token present) | the refusal arm is proven | ⛔ the green arm runs a real suite, so it needs a slot. Not closed by argument. |
| `mix check` self-test stages | both commands verified standalone, exactly as the alias invokes them | ⛔ **never run THROUGH the alias.** Added 2026-08-27; the box was queued, so no `mix check` has executed since. This is a path a healthy day does not exercise until someone runs the gate. |

## ⚠️ LATENT — cannot fire on today's tree, demonstrated by INDUCING the condition

| guard | why latent | how demonstrated |
|---|---|---|
| `mutate.sh` doctest refusal | zero `iex>` in `lib/` today | induced a doctest → rc 5; removed → rc 0 |
| `fixture_coverage_test.exs` glob-vs-walk | all 28 `.exs` are top-level, so a narrowed glob returns the same set | induced `test/nested/probe_test.exs` → narrowed glob CAUGHT; correct glob green |

⭐ Both fire the moment the tree grows the shape they guard — which is exactly when they would
otherwise start lying.

## 📌 The evidence behind this repo's strongest claim, anchored where it can be found

⚠️ Audited 2026-08-27: the pair below existed **only in a commit message** (`483c42c`) — durable and
`git log --grep`-able, but invisible to anyone reading `docs/`. Not lost, and not filed either.
Anchored here so the claim and its evidence live together.

| reading | value |
|---|---|
| pre-flight minimum, 5 samples spread over 24 s | 3843 MB |
| **during-run minimum, 67 samples wrapping `mix check`** | **2865 MB** |
| post-run | comfortable again |

⇒ **~978 MB invisible to the endpoints.** This is the whole argument for `bin/box-sample.sh`: the
ends of a window cannot show you the window.

⚠️ **THE FINDING IS THE GAP; THE ABSOLUTE NUMBERS ARE THE CONDITIONS OF ONE RUN.** Measured
2026-08-27 on a shared host carrying other repos' suites, one `mix check` (629 tests + 12
properties, ~100 s) with a process elsewhere on the box oscillating ~2.4 GB on a ~60–90 s cadence.
⛔ **Do not read 3843/2865 as characteristic of this tool or this suite.** A number whose meaning is
*"the conditions of that run"* decays into a general claim the moment it sits in a general document
— which is exactly how an unfiled table elsewhere got quoted at four doors as though it described
gates rather than one evening. **Kept here because the DELTA is the evidence and it belongs beside
the claim; the readings are dated and qualified so they cannot be lifted out of it.**

⚠️ Also commit-message-only: `VmHWM 2854` (the reserve term, measured above the 2768 that had been
published as a peak — a sampled maximum is a reading, not a bound).

⛔ **Deliberately unfiled:** tonight's individual box readings (944 / 4196 / 1645 MB). Those are
transient observations of a shared host, not findings about this repo, and filing them would dress
a timestamped reading as a property.

## ⏱ Cheap flags — TIMED, not read

⛔ **A flag that claims to be cheap must be cheap BY POSITION, NOT BY INTENTION.** Measured
elsewhere tonight: a `--self-test` block placed *below* the suite invocation ran ~7 full suites while
its author reported "no BEAM started" in four commit messages. **Reading the file is what let that
ship; only the clock could have caught it.**

| flag | measured | vs a suite (~100 s) |
|---|---|---|
| `mutate.sh --self-test` | 1349 ms | 0.013× |
| `mutate.sh --dry-run` | 315 ms | 0.003× |
| `box-sample.sh --self-test` | 170 ms | 0.002× |
| `with-slot.sh` refusal | 26 ms | 0.0003× |

Positional check beside the clock: `--dry-run` exits at `bin/mutate.sh:213`, the `mix test`
invocation is at `:228`. **Both, because either alone can be satisfied by an accident.**

## 🔎 Suite-starters — enumerated TWICE, because the first selector was blind

⛔ My first enumeration grepped `mix (test|check|compile)` and reported **exactly one** starter. It
was under-inclusive in two ways at once:

1. **It omitted `mix run` and `mix deps.get`.**
2. ⭐ **It was structurally blind to INDIRECTION.** `bin/box-sample.sh` runs `"$@"` — the command is
   an *argument*, not text in the file — so no literal selector can see it. **An indirection is
   invisible to a literal selector exactly as a habit is invisible to a repo grep.**

⚠️ And the *second* selector failed too: my indirection pattern `(exec |^\s*)"\$@"` missed
`with-slot.sh`, whose `"$@"` sits after a `--`. **Two selector failures inside one check whose whole
purpose was to catch a selector failure.**

| starter | how it starts things | gated? |
|---|---|---|
| `bin/mutate.sh:243` | literal `mix test` | ✅ marker + token |
| `bin/with-slot.sh` | passes `"$@"` onward | ✅ it *is* the gate |
| `bin/box-sample.sh:152` | runs `"$@"` | ⛔ **deliberately not** — see below |

⭐ **`box-sample.sh` is an INSTRUMENT and stays ungated by decision:** a measuring tool that demands
permission cannot measure the thing you needed permission to see. The interlock is `with-slot.sh`,
which takes the token and *then* delegates here. Invoking the sampler directly with an expensive
command is outside the interlock **on purpose**, and that is now written in the file rather than
inferred from its absence.

## 👁 Observing the object, instead of fixing the selector

⛔ **Both enumerations above are SELECTORS, and a literal selector cannot answer a semantic
question.** "Does this start a suite?" is about *behaviour*; grep answers only about *text*. Every
repair I made was a better proxy, never the thing.

✅ **Measured instead — BEAM count sampled at 100 ms through each invocation, beside the clock:**

| invocation | BEAMs before | peak | ms |
|---|---|---|---|
| `mutate.sh --self-test` | 4 | **4** | 1161 |
| `mutate.sh --dry-run …` | 4 | **4** | 203 |
| `box-sample.sh --self-test` | 4 | **4** | 278 |
| `require-slot.sh` | 4 | **4** | 214 |
| ⭐ **positive control** — `elixir -e ':timer.sleep(1500)'` | 4 | **5** | 4643 |

⭐ **The control is the row that makes the other four mean anything.** Four zeros from a harness
never shown to detect a start are indistinguishable from four zeros from a blind harness. It
detects one, so these are absences rather than silence.

⚠️ **Both limits, because neither instrument covers the other:**
- **A clock and a process count answer "did THIS INVOCATION start a suite", not "can this file
  ever."** A branch not taken stays invisible.
- **A process count under-reports** (a start and exit between two samples is missed) — safe for
  *this* question, since a missed start can only make me over-cautious, not under.

⇒ **When a selector and a behavioural measurement disagree, the measurement wins on the invocation
it covers — and the disagreement bounds the claim rather than licensing another pattern edit.**

## 🔗 Composition — each arm alone is silent about their order

⛔ **Every guard here had been demonstrated ALONE. Seeing each arm fire alone is not seeing them
ordered correctly**, and the composition test found a real defect immediately.

| case | expected | got |
|---|---|---|
| no token **and** a doctest, real path | slot refuses first | ✅ rc 76 |
| `--dry-run` (slot skipped) **and** a doctest | doctest guard | ✅ rc 5 |
| token granted **and** a doctest | doctest guard | ✅ rc 5 — ⛔ **but the token was BURNED** |

⛔⛔ **The slot was spent by a run that never started a suite.** Checking and consuming had been
collapsed into one call placed early, so a precondition failure downstream cost a scarce permission.
✅ **Split: `slot_check` early (refuse before doing work) · `slot_consume` late (at the point the
expensive thing actually starts).** Re-tested: the doctest arm now refuses **and the token survives**.

⚠️ **And my own third arm was a false red.** I predicted 76 and got 3, then found the *code* was
right and my *fixture* was wrong — I had assumed a previous arm consumed the token when it had
correctly exited earlier. **A precondition assumed rather than established.** Re-run with the token
explicitly removed: rc 76. ⭐ Same class as reading three `rc=128`s as arms firing.

| arm | status |
|---|---|
| `slot_check` refuses / passes / no-marker | ✅ all three seen |
| `slot_consume` on a run that reaches the suite | ⛔ **UNEXERCISED** — that *is* a suite, and I hold no slot. Labelled, not manufactured. |

## ⚠️ The interlock disarms SILENTLY, and I disarmed it myself

⛔ **Measured 2026-08-27 18:53Z:** the operator marker `.slot-protocol` was **absent**, so the slot
gate was fail-open and would have refused nothing. **I had removed it in the teardown of the
composition test — the very test that exercised the gate.** ⇒ I had just told another door *"my own
scripts refuse me"*, which was **false at the moment I wrote it**.

⭐ **THE MECHANISM AND ITS OFF SWITCH ARE THE SAME FILE, AND ITS ABSENCE IS INDISTINGUISHABLE FROM
NEVER HAVING ARMED IT.** A fail-open design is correct for a library (a clone must not be refused),
and the price is exactly this: **disarmed and armed look identical from outside, and the disarmed
state is the quiet one.**

✅ **Detected only by VERIFYING STATE AT THE END rather than asserting it** — and re-armed, then
confirmed **by running the gate** (rc 76), not by observing that the file exists.

⇒ ⭐ **Before claiming an interlock protects you, run it.** A protection asserted from memory of
having built it is the same class as a threshold quoted from memory of having measured it.

### Second instance, 19:02:54Z — and this one started a suite

⛔ **It happened again, in the command written to check whether the marker was there.** The marker
was absent (removed in an earlier test teardown), and the "check" was
`bin/mutate.sh <file> <old> <new> | head -1` — **which without `--dry-run` applies the mutation and
runs `mix test`.**

**Measured, not inferred:**
```
19:02:54.313  _build/test/lib/yepochs/.mix/compile.elixir.checkpoint   written
19:02:54.380  _build/test/lib/yepochs/ebin                             touched
.beam written after 19:02:50 : 0   ·   BEAMs after : 0   ·   tree : restored, 0 dirty
```
⇒ **A `mix test` in the test env BEGAN.** It died within seconds because `head -1` closed the pipe
and SIGPIPE killed the script. ⛔ **The cost was a compile start rather than a ~100 s suite, and the
difference was a pipe I used for brevity — not a guard.** No box reading exists for the window.

⭐⭐ **Eleven minutes earlier I had written that "a gate whose only firings are deliberate has a real
duty cycle of zero." Its first NON-deliberate firing opportunity arrived and the gate was disarmed —
in the command asking whether it was armed.**

⇒ **Two failures on the ARMING while passing the deployed-gate check cleanly both times.** ⭐ **The
two `git show` lines verify the *mechanism* and are structurally blind to the *arming state*.**
⚠️ **And the sharper trap under it: `bin/mutate.sh` without `--dry-run` is a SUITE-STARTER that
reads like a state check.** ⛔ **Recorded as a gap, not fixed — the obvious remedies are new gating
mechanisms, and building one tonight is outside the standing ruling.**

## ⚠️ A negative result whose fixture omitted the necessary condition

Another door reported that an EXIT trap's failing last command rewrites a script's exit code,
relabelling a successful run as a failure. Both scripts here have EXIT traps and return meaningful
codes (3, 5, 76, the wrapped status), so I tested it. **Four probes, all clean:**

```
trap 'false'                  ; exit 0        → 0
trap 'kill <dead pid>'        ; exit 5        → 5
trap 'kill <dead pid>'  falls off end         → 0
trap 'kill <dead pid>'  explicit exit 0       → 0
```

⛔ **I was one message from reporting "does not reproduce" against a filed fix.** Then:

```
set -euo pipefail ; trap 'kill "$p" 2>/dev/null' EXIT ; true   → 1   ⬅ REPRODUCES
```

⭐⭐ **`set -e` is the necessary condition, and every one of my four probes omitted it.** A negative
result from a fixture that cannot reach the state the claim is about is **indistinguishable from a
real absence** — and mine would have been loud, because it contradicted someone's committed fix.

⇒ ✅ **Cheap conditional rule: `grep -n '^set ' <script>`. No `-e` ⇒ the class cannot reach you.**

**Here:** neither script sets `-e`, so this is the **incidental** kind — safe by a flag's absence.
- `box-sample.sh` already carries `|| true` on `kill`/`wait`, so it holds under a forced `set -e`
  (verified: a wrapped `exit 9` still yields 9).
- `mutate.sh`'s trap is `cp "$BACKUP" "$FILE"; rm -f "$BACKUP"` — the last command returns 0, so it
  is well-ordered. ⭐ **Labelled rather than banked, and deliberately NOT "hardened":** silencing the
  `cp` would be wrong, because a failed restore must surface.

## 🚀 Is the gate in the artifact you HOLD, or the artifact that is DEPLOYED?

⛔ **A guard demonstrated on your working tree is silent about the script an invocation actually
runs.** Measured elsewhere 2026-08-27: a door's slot gate existed only on its branch; `main` carried
an older script with no gate at all. Checking out `main` to *test the gate* **swapped out the gate**,
and the run landed 18 commits to origin without a slot. Its "no token, so I cannot start by
accident" had been asserted five times and never once run — true of one checkout, false of the one
that mattered.

✅ **The check, two commands, no suite:**
```sh
git grep -n "slot_check\|slot_consume\|require_slot" origin/main -- bin/
git diff --quiet origin/main -- bin/mutate.sh && echo identical
```

**Result here (18:58Z):** all four `bin/` scripts present at `origin/main`, gate call sites at
`mutate.sh:115` and `:246`, and working tree **byte-identical to deployed** for all four.

⚠️ **Residual, stated because the gate being deployed is not the whole claim:** the *arming* is
local. `.slot-protocol` is untracked by design (a clone must be fail-open), so being gated depends
on a file that is silently removable — and I removed it myself once, in a test teardown. **Deployed
mechanism, local arming state; verify both.**

## 🔢 Two states sharing one exit code are indistinguishable to a script

⛔ **`bin/mutate.sh` returned `5` for two different conditions until 2026-08-27:**

| condition | when | remedy |
|---|---|---|
| the mutation **moved** the expectations | detected **after** mutating | scope the substitution to the asserted line |
| the target **holds its own** expectations (a doctest) | refused **before** mutating | move the example into `test/`, or scope by line |

⭐ **A human reads the message; a caller reads the code.** The two remedies differ, so collapsing
them meant an automated caller could not act on either. Split: the doctest guard is now **6**.

✅ **Demonstrated red as well as green:** collapsing 6 back onto 5 → `SELF-TEST FAILED: doctest
guard returned 5, want 6` (rc 1); restored → green, file byte-identical.

⚠️ **`2` still deliberately covers two states** (bad usage · unverifiable backup) — both mean
"nothing was changed, fix the invocation or the environment", and no caller acts differently on
them. **Kept as a decision, written in the file, so a later reader does not "fix" the asymmetry.**

⇒ ⭐ **The general form, from a door whose branch guard returned the same code as its slot gate:
an exit code that answers two questions is silent about which one you asked** — and the reader most
in need of the distinction is the one that cannot see the message.

### And splitting codes is not enough — assert the rc AND the text

⛔ **An rc is a small integer namespace, and the arms that share a code are precisely the ones a
designer thinks of as "the same kind of refusal" — which is when they shadow each other.** Elsewhere
tonight a forced-floor demo passed while a *different* arm fired and returned the expected number.

✅ **`--self-test` now asserts a distinctive substring alongside every code**, so an arm cannot be
satisfied by a refusal from a different guard. **Demonstrated by changing only the MESSAGE and
leaving `exit 3` untouched:**

```
SELF-TEST FAILED: face (1) returned 3 but not from the expected arm
  wanted text: changed no bytes
```

⭐ **The rc matched and the arm did not — which is the whole failure mode, and it is invisible to
any rc-only check.** Restored → green, file byte-identical.

## ⛔ Known non-guards

- `bin/box-sample.sh` **reports, it does not gate.** Checked rather than assumed: the only exits are
  usage (2), `--self-test` (0/1), and the wrapped command's own status. No exit sits beside a
  headroom test.
- The sampler's teardown is **safe by construction, not safe because `-e` is absent**. Under `set -e`
  a `wait` on a killed child exits 143 and a `kill` on a dead pid exits 1 — a cleanup defect that
  killed two landings elsewhere tonight *after* their suites had passed and *before* anything was
  printed. `|| true` holds regardless of what a later hygiene commit sets.
- ⚠️ **The slot token now gates BOTH callers via one statement** (`bin/require-slot.sh`, sourced by
  `with-slot.sh` and by `mutate.sh`'s suite path). It was gating only the wrapper — **the path of
  least consequence** — while `bin/mutate.sh:228`, the only real `mix test` in this repo, was open.
  Found by enumerating suite-starting lines rather than assuming, with the comment/`echo` hits
  filtered and the raw count shown beside the filtered one.
- ⚠️ **It still gates only what calls it.** `bin/with-slot.sh` cannot see a `mix check` typed
  directly, and no token can see that. ⛔ **Correction:** an earlier version of this row cited
  another door's "seven silent suites" as the illustration — wrong, and corrected by that door
  itself: those ran through its *own* gate script, above whose `mix test` line the check sits, so a
  token would have refused all seven. **That case argues FOR the token.** The real residue is the
  habit route — suites typed by hand, invisible to every grep. Left with the correction stacked,
  because taking a plausible fit as evidence without checking it is the instructive part.
  It is a real interlock against *the moment a waiter goes green*, not a lock on the repo. Recorded
  as a limit rather than presented as coverage.
- ⭐ **Load-bearing vs incidental.** Two of this repo's clean answers tonight were INCIDENTAL and
  have been converted: the teardown was safe only because `-e` was absent (now `|| true`, verified
  under a forced `set -e`), and "not an adopter of the shared health tool" was true of committed
  files while the Sol dispatch is typed by hand — the same runtime read of another tree, invisible
  to any repo grep. Only the `--trace` absence is load-bearing, and only because a positive control
  proved the grep could see its corpus.
- No reachability check exists here, because nothing in this repo gates on a moving host term. That
  is **absence, not design** — if a host-dependent gate is ever added, it needs one, kept in the
  same edit as the gate it guards.

## Next action

Run `mix check` at the next free slot and record whether the two new stages executed. Until that
line exists, the wiring row above stays ⚠️.
