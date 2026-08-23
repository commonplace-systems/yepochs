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
