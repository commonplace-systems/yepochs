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
