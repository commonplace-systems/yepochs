# 0010 — Epoch token minting: the specification, ahead of any implementation

**Status:** specified, **NOT implemented, NOT authorised to implement** · **Date:** 2026-08-24
**Depends on:** `docs/design/0009` (feasibility) · **Blocked on:** decision (3), the compaction premise

## Why this file exists before the code does

⛔ **The formula is normative elsewhere and had no trace here.** jes ruled (19:32Z) *"i do want epoch
tokens as hash if possible"*; the feasibility clause was discharged by `46f88f8`; `commonplace-doc`
records the result at `docs/DECISION-epoch-tokens-are-hashes.md`. ⭐ **This repo is named as the
natural owner of the minting function, and owned a decision that lived only in a conversation and
another repo's record.** That is the failure mode this repo spends most of its effort avoiding.

⚠️ **Nothing here is built.** The pause stands on a named condition: **decision (3), whether this
host mints openers at all, is unruled.**

## The rule

```
token = H( "yepochs.epoch-token.v1"
         ‖ u32(n) ‖ for each of n parent ids,           ASCENDING BYTE ORDER: u32(len) ‖ bytes
         ‖ u32(m) ‖ for each of m distinct source epochs, ASCENDING BYTE ORDER: u32(len) ‖ bytes
         ‖ u32(len) ‖ algorithm_id_bytes ‖ u32(algorithm_version) )
```

### Every clause, and what it is for

**⭐ Mint from INPUTS, never from output.** Every field is known *before* the snapshot is taken. This
is the whole property: combined with `0009`'s measurement that the snapshot `update` bytes are
identical on every node, it makes a boundary commit **converge instead of duplicating** under
decision (1)'s `commit_id = H(parent, epoch, update)`. ⛔ A token derived from the snapshot's output,
or minted randomly, breaks that — and the duplication lands **inside the content address**, where it
is permanent.

**⛔ Length-prefix everything.** The first draft was `H(sorted parent ids ++ source epoch ref ++
algorithm version)` — **plain concatenation of variable-length byte strings.** Epoch refs are
arbitrary UTF-8 up to 1024 bytes (§6.3), so `a ‖ b` and `a' ‖ b'` can be the same byte sequence under
a different split. ⇒ **Two different openers hashing identically: a collision inside the content
address, arriving through the encoding rather than the ordering.**

**⭐ Domain-separation prefix**, so an epoch token can never collide with any other hash in the system.

**Sort byte-ascending.** Parent ids and epoch refs are **opaque byte strings** (§6.3), so
byte-lexicographic order is total, and ids are unique so there are no ties. ⇒ **No semantic ordering
is required** — the opacity that usually costs something pays here.

**Algorithm is a PAIR, not a number.** `%Algorithm{id: String.t(), version: pos_integer()}` — a bare
version integer is ambiguous across algorithms. §21 already requires the version to ride along and
`Algorithm.resolve/3` already enforces it; `snapshot_v2` is the precedent, **recognised, never
produced.**

**Source epochs: the sorted set of DISTINCT parent epochs.** Same-epoch openers collapse to `m = 1`;
cross-epoch openers give `m = 2` and are reachable today — `CrossEpochMerge` merges commits from
different snapshot epochs. ⛔ **Not "the namespace the content was re-expressed in"**: that is a
property of the crossing's *output*, and would reintroduce the dependency mint-from-inputs removes.

⚠️ **Honesty note, recorded rather than smoothed:** under decision (1) a parent id **already commits
to its epoch**, so the epoch refs are **strictly redundant**. They are included so the token is
computable from carried metadata **without fetching parents**, and because a later change to (1)
would otherwise silently weaken the token. ⭐ **Deliberate redundancy, not necessity.**

## Conformance vectors — the specification made executable

⭐ **A spec that cannot refuse an implementation is a suggestion.** `probes/epoch_token_reference.exs`
is a reference implementation **and not library code**; whoever ships the real one must reproduce
these sha256 values byte-for-byte.

| vector | inputs | sha256 |
|---|---|---|
| V1 | 1 parent, 1 epoch | `566bd000927dfd33…` |
| V2 | 2 parents, 1 epoch *(same-epoch opener)* | `aa96fa5ff052168b…` |
| V3 | 2 parents, 2 epochs *(**cross-epoch opener**)* | `cbee36a3f7372ffb…` |
| V10 | 0 parents *(root opener)* | `3584377094a115e6…` |

**Required relations, all verified:** V4 (pre-sorted inputs) **==** V3 · V5 (duplicate epoch) **==**
V3 · V6 (algorithm version 2) **!=** V1 · V7 (different algorithm id) **!=** V1 · V2 **!=** V3.

⛔⛔ **And the framing case, which is why the draft formula had to change.** V8 `parents=["ab","c"]`
and V9 `parents=["a","bc"]`, same epoch, same algorithm:

- **framed** ⇒ `8e97da39…` vs `cd25c2e6…` — **distinct** ✅
- **unframed draft** ⇒ ⛔ **IDENTICAL. Measured, not argued.** Two different openers, one token,
  one permanent id inside the content address.

## First fixture, when there is one

⭐ **The cross-epoch 2-parent opener** (`m = 2`), not a single-parent case. ⛔ **A same-epoch or
single-parent corpus passes identically with the dedup-and-sort removed** — it cannot exercise the
only clause that does any work here. Same discipline as `0009`'s discriminating-count floor and
`0006`'s non-degenerate correspondence.

## Not settled here

⛔ **The opener parent-order gap.** Sorting the token's inputs makes the **token** order-blind; the
**commit id** is not, if `merge_parents` is hashed **as carried** — so two nodes independently
minting one opener with parents in different carried orders get **two commit ids for byte-identical
content**. ⚠️ The fix is *not* sorting `merge_parents` in the commit hash: carried order is plausibly
semantic (first-parent-is-mainline). It resolves either by writing down that openers are minted by
exactly one node and propagated — **a federation assumption that should be recorded as one** — or by
canonicalising carried parent order **for boundary commits specifically**. With jes.

⛔ **Decision (3)**, the compaction premise. Until it is ruled, nothing here is built.
