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

## ⚠️ Limits of the measurement, stated rather than rounded off

- The corpus is **concurrent deletes over text**. It does not cover map/array concurrency, nested
  types, or more than two concurrent authors. **Order-independence is measured, not proven.**
- ⛔ **It is not a contract.** `docs/design/0002` states determinism over the exact `Doc`
  *representation*; this measurement shows the snapshotter is in fact representation-independent
  across the path-dependence that occurs, **but I have not promised that**, and promising it would
  itself require a version bump.

⭐ **Therefore the recommendation is belt-and-braces: canonicalise the update order anyway.**
`merkle-crdt`'s checkpoint is already **the ordered update list, not the encoded doc** — so a
canonical input order costs them nothing and makes determinism independent of my
representation-independence entirely. ⇒ **Two independent reasons the token names one document is
the right number for something federation depends on.**
