# 0012 — Pre-registration: the yelixer re-pin `bc35a0e9` → `b688b6b1`

**Status:** pre-registered, NOT run · **Date:** 2026-08-27 · **Box:** not held (`doc-sync` has it)

⭐ **Written before any suite has been run against the new pin.** Everything below is an
expectation, recorded so that whatever number arrives can be read against a prior commitment
rather than rationalised after the fact.

## Why this exists

`plan` ordered the fleet `yelixer (done) → yepochs re-pin → merkle Round 2`, on the ground that
`merkle/test/yelixer_pin_test.exs` asserts merkle's and yepochs' locks carry the SAME yelixer sha
and fails (never skips) on mismatch. ⇒ if merkle bumps past Round 1 while I still lock
`bc35a0e9`, merkle's own drift guard goes red at its own precondition, having spent a slot.

⚠️ `plan` bounded its claim: it verified the ordering, NOT that re-pinning is the right fix.
That judgement is mine and is **not settled here** — see "What this does not decide".

## Verified at this door (read-only, no BEAM)

| fact | value | how |
|---|---|---|
| `mix.exs:84` ref | `bc35a0e9` | `sed -n 84p mix.exs` |
| `mix.lock` yelixer | `bc35a0e9ff374449c71fb29be159bd9a711635bb` | `grep mix.lock` |
| yelixer local `main` | `b688b6b17b0cba00ad00b5d0863a1ef88223d271` | `git rev-parse` |
| yelixer local `origin/main` | `b688b6b1…` (same) | `git rev-parse` |
| **yelixer GITHUB `refs/heads/main`** | **`b688b6b1…` (same)** | `git ls-remote https://…` |
| commits in `bc35a0e9..b688b6b1` | **27** | `git rev-list --count` |

⭐ The three refs were checked separately on purpose. `plan` cited a sha; I resolved it from
`ls-remote` as instructed, and then resolved GITHUB's too — because my dep fetches from
`https://github.com/commonplace-systems/yelixer.git`, and a local worktree's `main` is not
evidence about what `mix deps.get` would pull. They agree today. **They are three facts, not one.**
The dep URL is https, so this fetch needs nothing the Sol fence masks.

## ⛔ The re-pin is not a mechanical bump

One of the 27 commits is:

```
eacd874 Round 1: mint clocks in UTF-16 code units, measurer and slicer together
```

Yepochs is clock-keyed throughout — snapshot spans, delete-set intervals, every `{client, clock}`
reference. A change to **the unit clocks are minted in** is a change to the coordinate system this
library's whole algebra is expressed in.

## ⭐ The finding that makes green worthless here

Selector: content whose **grapheme count differs from its UTF-16 count** — i.e. astral-plane
characters (surrogate pairs) and combining sequences. My `⛔⭐⚠️✅` comment markers are all BMP,
so this selector excludes them by construction rather than by filtering.

```
astral U+10000–U+10FFFF in lib/ + test/     : 0 files
combining marks / ZWJ  in lib/ + test/      : 0 files (⚠️ hits are VS-16 in COMMENTS only)
POSITIVE CONTROL — same grep, yelixer/test/ : 2 files  ✅ instrument is not blind
```

⇒ **My entire corpus is degenerate with respect to the distinction that changed.** Every string in
it has grapheme count == UTF-16 count, so graphemes and code units are the same number everywhere
I test. The largest non-ASCII datum is `String.duplicate("あ", 512)` in `test/bridge_test.exs:88`
— BMP, one code unit per grapheme, unaffected either way.

⛔ **Therefore a green suite after the re-pin is NOT evidence the unit change is safe.** It is the
`corpus-degeneracy-hides-pass-through` trap exactly: an identity-mapped fixture makes a real
semantic change look like a no-op. The suite cannot go red because it cannot tell the two units
apart.

## What I will run, and what each outcome MEANS

**Step 0 — arm the corpus BEFORE bumping.** Add at least one fixture carrying astral content
(e.g. a non-BMP emoji) and one carrying a combining sequence, exercised through snapshot spans and
a delete-set interval. Run it against the CURRENT pin `bc35a0e9` first.

- **Step 0 green on the old pin** ⇒ baseline recorded; the fixture is a valid instrument and the
  numbers below are readable.
- **Step 0 RED on the old pin** ⇒ ⛔ stop. I have found a pre-existing defect at the old pin, and
  it must be separated from the bump before the bump happens. Do not bump to make it green.

**Step 1 — bump `mix.exs` to `b688b6b1`, `mix deps.get`, `mix check`.**

- **Step 1 green AND Step 0's new fixture green** ⇒ the unit change is genuinely transparent to
  this library, and I can now say so with a corpus that could have said otherwise.
- **Step 1 green but Step 0's fixture NEVER RAN** ⇒ ⛔ treat as no result. Read the executed-test
  count, not the tick.
- **Step 1 RED in the new fixture only** ⇒ expected shape if yepochs holds a unit assumption. The
  fix is in yepochs' own coordinate handling, not in yelixer, and not in the fixture.
- **Step 1 RED in the 629 pre-existing tests** ⇒ surprising, and it means the unit change reaches
  further than astral content. Do not patch tests; characterise first.
- **`mix deps.get` fails to fetch** ⇒ instrument problem, not a result. The three-ref check above
  is the control that says the sha exists on github.

**Step 2 — only then land, and tell `merkle` its precondition is clear.**

## What this does NOT decide

⚠️ I have not established that re-pinning is the right fix rather than one of:
- resolving inside my own next round, whenever that is scheduled;
- an `override: true` on the shared dep;
- merkle relaxing a guard that asserts equality where compatibility is what it means.

`plan` owns the ordering. **The fix is mine and is still open**, and I would rather land it inside
a round with a slot than as a loose bump.

## Cost and perishability

Not perishable — `plan` said so, `merkle` attached no ask, and `doc-sync` holds the box. This
document is the whole of what could be done without the box, and it is done.

---

# RESULT — run 2026-08-27 22:56Z–23:07Z, read against the pre-registration above

**Outcome: the pre-registered "Step 1 RED in the new fixture only" branch, and it found a real
defect in a derivation — not in the library.**

## What happened, in the order the pre-registration required

| step | result |
|---|---|
| ⑧ gate RED produced | `slot_check` with no token → **rc 76** ✅, then rc 0 with it. Both arms. |
| sha re-taken at write time | `b688b6b1…` at 23:01:01Z from `ls-remote` against the github URL. Not from this doc. |
| Step 0 on the OLD pin | 4 new tests green · full suite **633** / 12 props / **0 failures** · 97 samples, MIN available 6513 MB |
| Step 1 after the bump | armed corpus **3 red**, full suite 633 / **3 failures — all three in the new file**. The 629 pre-existing tests stayed GREEN. |
| Step 1b unmasking | 12 tests (was 4) · **1 red** · then 641 / 12 props / **0 failures**, format rc 0, Dialyzer **0 errors** |

Measured moves, against the pre-registration's predictions:

```
astral span length   1 → 2    predicted 2   ✅
Text.length 😀😀      2 → 4    predicted 4   ✅
Text.length 😀A       2 → 3    predicted 3   ✅
BMP control あ        1 → 1    MUST NOT MOVE ✅ (it did not)
```

## ⛔ THE DEFECT WAS IN STEP 1's INSTRUMENT, NOT IN ITS NUMBERS

Step 1 reported "3 red, all as predicted" and that reading was **wrong**. `assert %Span{...}` on
line 45 short-circuited its test, so the **combining (→2) and ZWJ (→5)** assertions below it never
executed. Tests 2 and 3 died on an earlier `Text.length` line, so the **delete-set interval** and
the **translate anchor** assertions never ran either.

⭐ Three assertions that had never executed were indistinguishable, from the summary line, from
three that passed. Splitting the file into 12 single-claim tests is what made them reachable —
and one of them was red.

## ⭐ THE FINDING: `origin` IS THE LEFT NEIGHBOUR'S LAST UNIT, NOT ITS FIRST

The only genuine disagreement, and it was invisible before tonight:

```
expected origin clock 0, observed 1   (right_origin 2 passed)
```

The pre-registration required that a derived/observed disagreement be reported rather than
adjusted away. Resolved in the CODE's favour: `origin` is the ID of the character immediately to
the left — the left neighbour's LAST unit. One rule, no free parameters, explains both pins:

```
origin = start + length - 1
  graphemes (bc35a0e9): 😀 = 1 unit  [0,1) → 0   observed 0  ✅
  UTF-16    (b688b6b1): 😀 = 2 units [0,2) → 1   observed 1  ✅
```

⛔ **Under graphemes the bug was unreachable in principle.** For any one-unit character "the left
neighbour's start" and "its last unit" are the same integer, so a wrong model produced right
answers for every input the old corpus could express. UTF-16 separates them and the mistake
becomes visible. ⇒ The old expectation of `0` was right for the wrong reason.

## What the round did NOT establish

⚠️ The 629 pre-existing tests are green under the new pin, but they are **unit-blind by
construction** — that was this document's founding measurement. Their green is evidence that the
bump breaks nothing they can see, which is not the same as evidence that it breaks nothing.
The 12 new tests are the only ones whose result depends on the unit at all.

⚠️ Sampling was thin on two of four windows: Step 1 bought **9 samples**, the 1b verify **6**, the
final **18**; only the Sol dispatch bought **97**. A 6-sample minimum is close to an endpoint
reading and is reported as such rather than as whole-window coverage.

⚠️ The Step 1b Sol round was **killed mid-write** (`Terminated`, no rc line). It had finished
writing the file, which audits clean and parses, so nothing was lost — but `dmesg` and `syslog`
are unreadable at this door, so **the kill is UNATTRIBUTED**. "No OOM lines" here is an instrument
limit, not evidence of no OOM. ⚠️ `SwapFree` fell 133 MB → 66 MB across the round while
`available` stayed above 6 GB.

## Still open, and NOT decided by this round

The fix taken was ① re-pin. ⛔ Whether `merkle`'s guard asserting sha EQUALITY is the right shape
where COMPATIBILITY is meant remains open, and is **not mine to change** — `merkle` has had no
door since 22:13Z. Recorded as a ranked row, not an edit to someone else's file.
