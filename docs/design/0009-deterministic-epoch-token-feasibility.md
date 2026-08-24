# 0009 — Deterministic epoch-token minting is feasible; here is the measurement

**Status:** measured · **Date:** 2026-08-24
**Evidence:** `test/snapshot_order_independence_test.exs`, `probes/snapshot_order_independence.exs`

## The question handed over

jes, 15:40:50Z: a boundary epoch token is minted **"deterministic if possible"**. ⚠️ *"If possible"*
is a **feasibility determination handed over, not a fallback licence** — a quiet fall back to random
would fork federation on every epoch change.

`commonplace-merkle-crdt` scoped itself out correctly: it carries the token and never computes it.
⇒ The question is whoever mints.

## The question that actually decides it

⭐ **The token itself is trivially deterministic** — it is a hash of inputs one chooses. **The
question is whether the thing it NAMES is deterministic:** do two nodes replaying the same commit
set in different orders derive the *same* snapshot? If not, one token names two documents.

⛔ **There was good reason to doubt it.** `Encoding.encode_update/1` **is** path-dependent under
concurrent deletes — measured here over 676 pairs, and independently by `merkle-crdt`. If
snapshotting inherited that path-dependence, determinism would be impossible from a locally
materialized `Doc`.

## Measured: it does not inherit it

Exhaustive sweep, every pair of concurrent deletes over an 8-character base:

| | |
|---|---|
| pairs total | **676** |
| ⭐ **discriminating** (raw encoding order-dependent) | **290** |
| observable text differed | **0** (control: CRDT convergence held) |
| ⇒ **snapshot bytes or derivation spans differed** | **0 of 290** |

⇒ **Snapshotting is arrival-order independent exactly where encoding is not.** That is not luck: the
snapshotter's traversal is **content-structural** — type names in name order, sequence order within
a type — deliberately *not* identity- or arrival-order dependent, because identity is the thing the
snapshot replaces.

⚠️ **The discriminating count is the headline, not the total.** A pair whose raw encoding does not
vary cannot discriminate; a corpus of those reports a confident vacuous pass. The test asserts a
**floor of 200 discriminating pairs** before it believes its own result — and mutation confirms
that floor fires: making both deletes identical turns it red.

## Answer: yes, with three conditions, all already satisfiable

1. ⭐ **Mint from inputs, not from output.** `token = H(sorted parent ids ++ source epoch ref ++
   algorithm version)`. Every input is known *before* snapshotting, so the token does not depend on
   the snapshot at all — and the measurement above is what guarantees it names one document.
2. ⭐ **The 2-parent order rule is trivial.** Commit ids and epoch refs are **opaque byte strings**
   (§6.3), so **byte-lexicographic sort** is total and deterministic, and ids are unique so there
   are no ties. **No semantic ordering is needed.**
3. ✅ **Version riding along is already mandatory.** §21 requires a new algorithm version for any
   change that can alter output bytes or mapping semantics, and requires the package to expose its
   supported versions with durable callers selecting explicitly. `Algorithm.resolve/3` enforces it;
   `snapshot_v2` is the live precedent — **recognised, never produced, `:incompatible_algorithm`
   rather than v3 bytes under a v2 tag.**

⇒ **This is not a "tell jes it cannot be done" case.**

## Map and array concurrency — the gap, now closed by a stronger result

⭐ **`commonplace-doc` was right to refuse this as "asserted".** The wiki slice's openers come from
`map_set`/`map_delete` on a Directory's Y.Map root, so a text-only measurement discharged the wrong
half. Measured:

| corpus | pairs | discriminating | snapshot differed |
|---|---|---|---|
| map ops (set/delete, same and different keys) | 121 | **0** | 0 |
| array ops (insert/delete) | 144 | **0** | 0 |

⛔ **Zero discriminating pairs is normally a blind instrument, not a result.** Two causes share that
observable: map concurrency is genuinely order-independent, *or* my corpus cannot reach the case that
would show otherwise. ⇒ **Positive control: the same harness on the text-delete corpus reports 290.
The harness works.**

⭐ **And the cause of the zero is structural, not incidental:**

```
text  "abcdefgh"      items=1   lengths %{8 => 1}     <- ONE item, SPLITTABLE
array 4 elements      items=4   lengths %{1 => 4}     <- nothing to split
map   3 keys          items=3   lengths %{1 => 3}     <- nothing to split
```

Concurrent text deletes are order-dependent because they **split a multi-length item**, and the split
boundaries depend on arrival order. **Map and array items are length 1 across seven different
constructions** — one call or eight, strings, integers, long values, repeated overwrites. ⇒ **There is
nothing to split, so the encoding itself is order-independent and snapshot agreement follows rather
than being an extra fact.**

⭐ **This is a stronger result than the text case**, not a weaker one: for text, order-independence
holds *despite* the encoding varying; for maps and arrays the encoding does not vary at all.

⚠️ **Guarded so it cannot outlive its cause.** `test/snapshot_order_independence_test.exs` asserts
max item length is 1 for all seven constructions and **fails if the substrate ever consolidates
map/array content into multi-length blocks** — at which point map concurrency could become
order-dependent and this conclusion must be **re-measured rather than inherited**. Mutations: making
the length probe always return 1 → red; simulating consolidation → red.

## ⚠️ Limits of the measurement, stated rather than rounded off

- Text order-independence is measured over **concurrent deletes**, two authors. Nested types and
  more than two concurrent authors are **not** covered. **Measured, not proven.**
- ⛔ **It is not a contract.** `docs/design/0002` states determinism over the exact `Doc`
  *representation*; this measurement shows the snapshotter is in fact representation-independent
  across the path-dependence that occurs, **but I have not promised that**, and promising it would
  itself require a version bump.

⭐ **Therefore the recommendation is belt-and-braces: canonicalise the update order anyway.**
`merkle-crdt`'s checkpoint is already **the ordered update list, not the encoded doc** — so a
canonical input order costs them nothing and makes determinism independent of my
representation-independence entirely. ⇒ **Two independent reasons the token names one document is
the right number for something federation depends on.**
