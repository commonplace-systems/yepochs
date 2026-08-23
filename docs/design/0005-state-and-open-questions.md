# 0005 — Where this repo stands, and what is not decided

**Status:** current · **Date:** 2026-08-23 · **Read this first if you are picking the work up.**

## The one-paragraph version

`yepochs` implements spec **r2** (`docs/proposals/2026-08-23-yepochs-spec-r2.md`, sha256
`8765bb15…`) — ⚠️ **r1 and r2 are indistinguishable by header; tell them apart by hash.** The
library is complete against §6–§24 and has coverage for §28.1–§28.4. It depends on **yelixer pinned
at `bc35a0e9`** — the same ref `commonplace` pins — and on nothing else at runtime.

## ⛔ The gate, which has not moved

```
OPEN    building this library on the yelixer substrate
GATED   `commonplace` TAKING A DEPENDENCY ON yepochs
        -- either direction of arrival, and gated EVEN IF NO FILE EVER MOVES
```

`commonplace-plan` owns this. **Reading commonplace's tree and recreating its fixtures is explicitly
NOT gated** and has been done. §30 criterion 14 ("the Commonplace monorepo consumes the package") is
therefore **not satisfiable from this repo**, by design.

⚠️ **Standing caveat from jes:** *"the specs could easily be confused about repo boundaries."* The
technical direction is authoritative; the repo attributions are **not**. Before designing to any
"X remains in repo R" claim, `command grep` R's tree. Verified instance: r2 still assigns
`CrossEpochMerge`/`Merger`/`SnapshotAncestry` to `commonplace-merkle-crdt`, whose `lib/` contains
**zero** references to them.

## Two questions with jes — do not close them by inventing an answer

1. **§28.2 fixture 19** — a re-authored crossing returning *non-identity* correspondence spans. §17
   hedges (*"wherever the adapter can prove"*), and 0.1's adapters prove none: they re-author from
   an observable diff and cannot say which destination item answers which source item. The current
   empty-span behaviour is **pinned in a passing test** so an answer changes code deliberately.
2. **The tombstone interaction** — see [`0004`](0004-tombstones-narrow-the-strict-path.md). §10.5
   declines to map tombstones, §15.8 requires every delete interval be translated, and
   `encode_diff/2` carries the *whole* delete set ⇒ **the strict path is available mainly for
   documents that have never had a deletion.** Three options recorded, none chosen. Per-case
   crossing modes are pinned in tests.

## What was measured, and where it is written down

| finding | where |
|---|---|
| build order; why Tier 0 has no dependencies | [`0001`](0001-build-order-and-gate.md) |
| yelixer encode determinism — two distinct mechanisms | [`0002`](0002-encode-determinism.md) |
| which XML shapes can hold a bridge at all | [`0002`](0002-encode-determinism.md) |
| r1→r2 migration; `target`→`right` is a **swap**, not a rename | [`0003`](0003-r2-migration.md) |
| §22 / §29 audit; §28 fixture status | [`0003`](0003-r2-migration.md) |
| tombstones narrow the strict path | [`0004`](0004-tombstones-narrow-the-strict-path.md) |

## ⭐ How to work on this, learned the hard way

**A green suite is not evidence a check works.** Mutation testing — disable one check, re-run,
restore — found ornamental gates in **every module it was applied to**, and three genuine defects
no test noticed. The recurring cause is never a wrong assertion; it is *data that cannot exercise
the check*: a composition test clipping exactly at a span start so the offset was always zero, an
"is sorted" assertion over a single element, `receipts >= 0` on a bridge that always had none.

⛔ **The dangerous defects here all produce a plausible answer rather than an error** — an empty
snapshot, an absorbed no-op for a real edit, a delete range covering clocks nothing deleted. Tests
that compare *shape* survive all of them; tests that compare **identity or content at the endpoints**
do not. When a test passes on the first run, ask what data would make it fail.

**Other traps this repo has actually hit**, each now recorded at its site: `doc.types` records what
the registry was *told*, not what the document *holds*; a guard whose reference value is computed
by the same rule as the thing it guards cannot detect a fault in that rule (twice, in one function);
`grep` for "where is X built" finds only literal constructions and is blind to indirection; and
`:erlang.system_info(:atom_count)` is a global counter that races every async test.

## Verifying the state yourself

```
mix deps.get && mix test          # 274 tests, 12 properties
mix format --check-formatted      # clean
mix compile --warnings-as-errors  # clean
```

Probes needing the substrate live in `probes/` with their own README — run them from a throwaway
project, **not inside `~/yelixer`**.
