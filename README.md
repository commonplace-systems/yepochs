# yepochs

Sibling to [yelixer](https://github.com/commonplace-systems/yelixer) — the planned **Phase-2
extraction** of commonplace's epoch handling into its own package.

## Status

**Repo created 2026-08-23 at jes's request. Spec filed the same day. Nothing extracted yet.**

Per the spec, `yepochs` is **Commonplace-independent**: a small Elixir library on the Yelixer
substrate for moving Yjs changes between histories that represent compatible content under
**different internal Yjs identities** — Yepochs, deterministic snapshots, derivations, bridges,
strict translation, and positional rebase as an explicit fallback.

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

## ⚠️ There are TWO spec revisions and they are indistinguishable by header

Both say `Version: 0.1-draft`, `Date: 2026-08-22`. **Tell them apart by sha256.**

| revision | path | sha256 |
|---|---|---|
| r1 | `docs/proposals/2026-08-22-yepochs-spec.md` | `c24ce9dd…` |
| **r2 — CURRENT** | `docs/proposals/2026-08-23-yepochs-spec-r2.md` | `8765bb15…` |

r2 makes Bridges **bilateral edit transducers**: one-directional translation became *crossing*, and
missing correspondence now **selects re-authoring instead of failing**. See
[`docs/design/0003-r2-migration.md`](docs/design/0003-r2-migration.md). r1 is kept because it is what
Tier 0 was first built against.

## ⛔ The gate — see `docs/design/0001-build-order-and-gate.md` for the binding wording

⚠️ **The section below is the ORIGINAL wording and it is superseded.** `commonplace-plan` corrected
it on 2026-08-23: the gated act is **`commonplace` taking a dependency on `yepochs`** — in either
direction of arrival, and it stays gated **even if no file ever moves**. Building the library is
open; ⭐ **reading commonplace's code and reproducing its fixtures is explicitly NOT gated.**

⇒ Read [`docs/design/0001-build-order-and-gate.md`](docs/design/0001-build-order-and-gate.md)
before acting on anything in this section.

## The sequencing constraint, recorded so it is not rediscovered late

commonplace-plan's queue carries two findings that bound when this extraction can happen:

1. **A yepochs consuming published yelixer REPEATS THE WHOLE GATE STRUCTURE** — it is *not* cheaper
   for having done the yelixer extraction once. The gate work does not amortize.
2. **Not before the arc lands: a mid-arc commit to yelixer invalidates a closed gate.**

⇒ **This is a real sequencing gate, not a caution.** Whether it is time to start is
**commonplace-plan's call** — it owns ranking across the commonplace family via
`commonplace-plan/docs/plans/QUEUE.md`. This repo existing does not re-rank it.

### ✅ SUPERSEDED 2026-08-23 04:28Z — jes supplied a spec and staffed it

jes: *"I'll try to get you a yepochs spec so we can have an opus there too."* He then sent one.
⛔ **TWO REVISIONS EXIST AND THEIR HEADERS DO NOT DISTINGUISH THEM** — both say
`Version: 0.1-draft`, both say `Date: 2026-08-22`. **Tell them apart by sha256, never by the header.**

| received | file | sha256 | lines |
|---|---|---|---|
| 04:28Z | `docs/proposals/2026-08-22-yepochs-spec.md` | `c24ce9dd…` | 1315 |
| **04:51Z — CURRENT** | `docs/proposals/2026-08-23-yepochs-spec-r2.md` | `8765bb15…` | **1718** |

⭐ **The r2 change that matters most: §15 went from *"Strict update translation"* to *"Crossing
edits"*, and §1 now reads "moving Yjs edits **in either direction**".** New §27.4 is *"Make Bridges
bilateral edit transducers"*, plus new §8.4 (bridge delta and receipt), §15.1–15.10, and §6.7–6.10.
⇒ **One-directional translation became bilateral crossing.** Anything built against r1's Bridge
semantics should be re-read against r2 before extending.

⇒ The r1 spec is filed byte-identical at
[`docs/proposals/2026-08-22-yepochs-spec.md`](docs/proposals/2026-08-22-yepochs-spec.md)
(sha256 `c24ce9ddb9919fdf6846737f0ee2425320bc71d89a932211e09029958d055e34`) and an Opus worker runs
here.

⚠️ **The ruling below is NOT deleted, because its REASONING still binds** — what changed is the
premise, not the argument. plan ruled against staffing *an empty repo with no spec*; the repo is no
longer empty and the direction is no longer absent. ⛔ **The §5 sequencing gate is untouched and
still applies to the EXTRACTION itself** (see above): a yepochs consuming published yelixer repeats
the whole gate structure, and not mid-arc.

⇒ **Spec work and library design can proceed. Landing an extraction that displaces `commonplace`'s
`translator.ex` / `cross_epoch_merge.ex` is still plan's to sequence.**

### ⛔ RULED 2026-08-23 04:0xZ by commonplace-plan: NO AGENT, NO START (premise now superseded)

Asked directly whether to staff this repo, plan ruled no, and gave the reason in a form worth
keeping at the top of the file someone opens when they are about to start:

> **An empty repo is a NAME, and naming a thing is the cheapest possible act — it should
> therefore carry the least ranking weight, not the most.**

⭐ A new empty repo carries an implicit *"start me"* it has not earned by comparison with anything
already ranked. That is recency-as-priority in its purest form: **an artifact whose mere existence
argues for work.** ⇒ **Repo existence is not extraction.** The sequencing gate above stands
unchanged.

jes, same day, independently: he is writing a spec first, and an agent goes in after that.

## Consumers waiting on it

- `commonplace-merkle-crdt` — jes named yepochs as something that repo needs to know about.
- The §5 vertical slice, which plan records as **gated on this extraction** rather than startable
  today.
