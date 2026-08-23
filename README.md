# yepochs

Sibling to [yelixer](https://github.com/commonplace-systems/yelixer) — the planned **Phase-2
extraction** of commonplace's epoch handling into its own package.

## Status

**Repo created 2026-08-23 at jes's request. Nothing extracted yet.**

Until this repo has content, `yepochs` was **absent**: the log-reducer and merkle-crdt briefs both
record it as "not a repo, a planned extraction". That is no longer true of the *repo*; it is still
true of the *code*.

## What would move here — measured 2026-08-23, not assumed

Both modules exist on `commonplace` main today:

| File | Lines |
|---|---|
| `apps/commonplace/lib/commonplace/store/translator.ex` | 346 |
| `apps/commonplace/lib/commonplace/store/cross_epoch_merge.ex` | 420 |

⚠️ **Both currently depend on `Commonplace.Store`**, which is why commonplace-plan recorded them as
*"need `Commonplace.Store` and stay"* — the dependency has to be broken before either can leave.
Plan's open question, in its words, is **"whether 124 lines is a package or a module."**

## ⛔ The sequencing constraint, recorded so it is not rediscovered late

commonplace-plan's queue carries two findings that bound when this extraction can happen:

1. **A yepochs consuming published yelixer REPEATS THE WHOLE GATE STRUCTURE** — it is *not* cheaper
   for having done the yelixer extraction once. The gate work does not amortize.
2. **Not before the arc lands: a mid-arc commit to yelixer invalidates a closed gate.**

⇒ **This is a real sequencing gate, not a caution.** Whether it is time to start is
**commonplace-plan's call** — it owns ranking across the commonplace family via
`commonplace-plan/docs/plans/QUEUE.md`. This repo existing does not re-rank it.

## Consumers waiting on it

- `commonplace-merkle-crdt` — jes named yepochs as something that repo needs to know about.
- The §5 vertical slice, which plan records as **gated on this extraction** rather than startable
  today.
