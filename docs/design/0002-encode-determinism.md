# 0002 — yelixer encode determinism, measured independently

**Status:** measured · **Date:** 2026-08-23 · **Probes:** [`../../probes/`](../../probes/)

Run independently rather than inherited from `commonplace-merkle-crdt`, because **an inherited
result carries the instrument that produced it, and an instrument you did not run cannot be
audited.** Where this agrees with merkle-crdt, that agreement is now two instruments. Where it
disagrees, the disagreement is recorded rather than reconciled away.

## Result 1 — `encode_update/1` is a pure function of the `Doc` term ✅

200 calls on one fixed `Doc`: **1 distinct output.** Independently confirms merkle-crdt.

⇒ **Spec §10.4 is satisfiable.** It pins "the same decoded source state, *including its Yjs item
identities and supported struct representation*" — the struct representation is exactly what varies,
so §10.4 never promised that two differently-built docs agree.

> ⚠️ **That clause is load-bearing, not boilerplate. If it is ever "simplified" to pin the decoded
> *value*, §10.4 becomes unsatisfiable on this substrate overnight.**

## Result 2 — the divergence is exactly range intersection

Every pair of concurrent deletes over an 8-character base — **676 pairs**, classified by the
geometric relationship between the two deleted ranges:

| class | n | bytes equal | bytes differ | delete sets differ | failed to converge |
|---|---:|---:|---:|---:|---:|
| identical | 26 | **26** | 0 | 0 | 0 |
| adjacent | 128 | **128** | 0 | 0 | 0 |
| disjoint | 232 | **232** | 0 | 0 | 0 |
| contained | 178 | 0 | **178** | 0 | 0 |
| overlapping | 112 | 0 | **112** | 0 | 0 |

**Perfect separation, no mixed class.** ⇒ The rule is:

> **Two concurrent deletes encode differently across apply-order iff their ranges INTERSECT and are
> not identical.**

Mechanism: a delete splits blocks at its range boundaries. Non-intersecting ranges contribute
split-point sets that commute; identical ranges contribute the same set either way. Only an
intersecting, non-identical pair produces order-dependent split points. Observed directly —
`A: [{0,2},{2,3},{5,2},{7,1}]` vs `B: [{0,2},{2,2},{4,3},{7,1}]`: **same block count, different
boundaries.**

## Result 3 — the delete set is NOT the divergent part ✅

**0 of 676** pairs had differing delete sets. `DeleteSet.add_range/2` coalesces order-independently.
Confirms merkle-crdt. ⇒ **§15.6 delete-set translation and the §27.2 correction are not exposed to
this.**

## Result 4 — convergence is never violated ✅

**0 of 676** pairs failed to converge on observable value. This is a *representation* divergence, not
a CRDT correctness bug.

## ⛔ Disagreement with commonplace-merkle-crdt: ADJACENT deletes

merkle-crdt reported adjacent ranges `(0,3)` / `(3,3)` as divergent. **This probe measures adjacent
deletes as byte-identical in 128 of 128 cases**, including that exact pair.

Both directions of the instrument are demonstrated on the same run — 290 pairs differ and 386 agree
— so it is not stuck on one answer.

**Most likely explanation, offered rather than asserted:** merkle-crdt's adjacent evidence may come
from `conformance/yjs-v1/004-concurrent-adjacent-deletes/`, which compares **yelixer against upstream
yjs**, not two yelixer apply-orders. Those are different comparisons, and merkle-crdt has already
caught itself conflating them once (the "4 vs 3 blocks" count was yelixer-vs-upstream, while the
apply-order case is 4-vs-4). **Unresolved; do not treat either number as settled.**

## What this constrains in `yepochs`

1. **§15.8 (deterministic translated encoding) is safe as designed.** Translation is a pure function
   of the decoded *update binary*, not of a `Doc` assembled by applying updates in some order. It
   never enters the regime above.
2. **§15.6 / §27.2 are safe.** Delete-set encoding is order-independent.
3. ⭐ **The real constraint is a CALLER contract for §10 snapshotting.** `snapshot/2` receives a
   `Yelixer.Doc.t()` from its caller. Two callers holding the *same observable document* built by
   different apply-orders hold **different** `Doc` terms, and will get **different snapshot bytes and
   hence a different target Yepoch reference**. `yepochs` cannot detect this and must not pretend to.
   ⇒ **Tier 2 must document that a content-addressed caller is responsible for the source `Doc`'s
   struct representation, not merely its value** — and that requirement must be stated where
   `snapshot/2` is defined, not only here.

---

## Result 5 — `Encoding.encode_items/2` is the Tier 1 re-encoder, and it satisfies §15.8

The translator must emit a modified item list **without** round-tripping through an integrated
`Doc` — otherwise it would enter the apply-order regime above. yelixer already has the primitive:

```elixir
Yelixer.Encoding.encode_items(items, delete_set)
```

Its docstring was written for exactly this use — *"Translated items' origins point at ids from the
source namespace — those ids are not in our synthetic store, so the GC-remap lookups miss and return
the ref unchanged, which is exactly what we want"* — and it records two deliberate determinism
choices (clients filtered descending by id; `encode_delete_set/1` appended), tagged `CX-w62`.

Measured (`probes/encode_items_determinism.exs`), on a 4-item / 2-client update:

| check | result |
|---|---|
| 100 repeated calls on the same input | **1 distinct output** |
| `decode_update` → `encode_items` == original bytes | **true** |
| input list reversed / sorted asc / sorted desc | **all byte-identical to canonical** |
| all four encodings applied to a fresh doc | **same observable text** |

⇒ **§15.8 is satisfiable and the translator does not need to pin item order** — the encoder
re-derives its own canonical order. This also means Tier 1 never constructs a `Doc` by applying
updates, so Result 2's divergence regime is out of reach by construction.

⚠️ **Scope of this claim, stated so it is not over-read:** one small update, 4 items, 2 clients.
The mechanism in the docstring supports the general case, but **Tier 1 must property-test order
insensitivity over generated item lists** rather than resting on this.

---

## ⛔ Correction — the first sweep authored FULL-STATE updates, not deltas

`Encoding.encode_update/1` emits the doc's **entire state**, not a delta. The first sweep's
"updates" were therefore **27 bytes each and carried their own base**, so every update satisfied its
own causal dependencies on arrival and **a second mechanism was unreachable by construction.**
Caught by `commonplace-merkle-crdt`. The correct call is `Encoding.encode_diff(doc, state_vector)`
— **6 bytes** for the same edit.

⭐ This is the same blindness as the `client_pending` diagnostic error above, from the other side:
the pending buffer is where yelixer holds what it cannot causally integrate yet, and an instrument
that never produces a genuinely-pending update can never see that path.

## Re-run with TRUE deltas — two distinct mechanisms, both now measured

All 676 pairs re-authored with `encode_diff/2`, varying **arrival order relative to the causal
dependency** as well as the order of the two deletes:

| class | n | **P1** base first, swap deletes | **P2** base LAST, swap deletes | **P3** base-first vs base-last |
|---|---:|---:|---:|---:|
| identical | 26 | 0 differ | 0 differ | 0 differ |
| disjoint | 232 | 0 differ | 0 differ | **0 differ** |
| adjacent | 128 | 0 differ | 0 differ | **128 differ** |
| contained | 178 | **178 differ** | 0 differ | 89 differ |
| overlapping | 112 | **112 differ** | 0 differ | **112 differ** |

Convergence held at **676/676** in every protocol.

**M1 — concurrent-delete order, dependencies already satisfied (P1).** Reproduces *exactly* as in
the full-state sweep. ⇒ **The M1 result was not an authoring artifact**; "diverge iff the ranges
intersect and are not identical" stands, now measured on true deltas.

**M2 — arrival order relative to causal dependency (P3).** A different and broader mechanism: it
hits **all 128 adjacent** and **all 112 overlapping** pairs, plus half of contained — geometry that
*commutes* under M1 still diverges here. ⛔ **It does not hit disjoint or identical**, which
contradicts the prediction that M2 would reach every class.

**And a third observation neither of us predicted (P2):** with the base arriving **last**, the two
deltas' relative order stops mattering entirely — **0 divergence in every class.** Both deltas wait
in the pending buffer and are integrated in a canonical order once their dependency lands. ⇒ The
pending path is *more* deterministic than the direct path, not less.

## Consequence for `yepochs` — the caller contract is broader than result 5 stated

⭐ **Tier 1 translation remains immune by construction.** It decodes an update binary and re-encodes
with `encode_items/2`; it never applies updates to build a `Doc`, so neither M1 nor M2 is reachable.

⚠️ **But the §10 / §19 caller contract must cover arrival order, not just apply order.** Two callers
holding the same observable document differ in `Doc` term if their updates arrived in a different
order **relative to causal dependency** — even when the edits commute. §18 assigns path discovery to
the caller, so a caller can legitimately hand over histories assembled in different arrival orders.

⇒ **Recommended spec clause, for jes:** state explicitly that byte-determinism of snapshot output is
conditional on the caller's `Doc` having a fixed struct representation, and that supplying a
`Doc` assembled in a different arrival order is a *different input*, not a violated guarantee. §10.4
implies this via "supported struct representation"; **it is not stated as a precondition anywhere,
and §15.8 says nothing about it at all.**

---

## Re-verified against the PINNED codec (2026-08-23)

⚠️ The measurements above were taken against a local `~/yelixer` checkout at `691a4f4`, which was
**4 commits behind `origin/main`** — and `bc35a0e9` (origin/main's tip, and the ref `commonplace`
pins) is *not* an ancestor of it. So the original probe runs measured neither what commonplace uses
nor the current tip.

`yepochs` now pins `{:yelixer, git: …, ref: "bc35a0e9"}` — the same ref commonplace uses — because
§10.4 and §15.10 state determinism against a **pinned codec version**, and an unpinned codec makes
"the same bytes" a claim about whatever was fetched that day.

**Re-run against the pin: every result above reproduces identically.** The 676-pair class
separation is unchanged in all three protocols (P1/P2/P3), and `encode_items/2` remains
deterministic, byte-exact on round-trip, and order-insensitive. The four intervening commits (CI,
path fixes, a fixture-arm change) do not touch the encoder — now measured rather than assumed.

---

## Which XML shapes can cross at all (measured 2026-08-23)

§19.2 names Y.XML as an adapter target. Before writing one, measure what the snapshot path can
carry — an adapter is only meaningful for content that can hold a bridge.

| shape | `nested_subtype_names` | yelixer snapshot | verdict |
|---|---:|---|---|
| `XMLText` | 0 | ok, 16B, dm=1 | ✅ crosses on the **text** plane |
| element, no children | 0 | ok, 2B, dm=0 | ✅ nothing to carry |
| element + attributes | 0 | ok, 22B, dm=1 | ✅ crosses on the **map** plane |
| **element + child** | **0** | **ok, 2B, dm=0** | ⛔ **child silently dropped** |

⭐ **No dedicated adapter was needed.** `XMLText` is string content on the sequence plane and
attributes are `parent_sub` items on the map plane, so the existing plane dispatch already carries
both — confirmed by tests, and by mutation (disabling the map plane reddens 8, the text plane 4).
**The measurement replaced the feature.**

## ⛔ And it found a hole in my own §10.2 guard

An element's children live under a **synthetic** name (`el::children`), and the replay does not
re-author them: an element with one child snapshots to an element with none, attributes intact, no
error. ⚠️ **`nested_subtype_names/1` returns 0 for this**, so yelixer's own guard does not fire
either.

My post-condition missed it because `observable_clock_count/1` *excluded synthetic names* — the
reference count skipped exactly the content that was being lost, so the check compared a number
against itself and reported success. ⇒ Fixed: the count now includes every live item under any
named parent, so such a document is refused with `:unsupported_content` (`source_clocks: 1,
derived_clocks: 0`). Reverting the fix reddens the suite.

**This is the same defect class as the registry-derived count it replaced** — a guard whose
reference value is computed by the same rule as the thing it is guarding cannot detect a fault in
that rule. Twice now in one function.
