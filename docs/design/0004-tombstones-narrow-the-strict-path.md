# 0004 — Tombstones narrow the strict path much further than §15 suggests

**Status:** measured · **Date:** 2026-08-23 · **Evidence:** `test/yjs_conformance_test.exs`,
`test/fixtures/yjs-v1/` (upstream `yjs` 13.6.32)

## The finding

Three spec clauses interact, and the result is not stated anywhere:

1. **§10.5** — *"Version 0.1 snapshots do not promise mappings for source tombstones."*
2. **§15.8** — *"Every delete-set interval MUST be translated… If any part of a delete interval is
   uncovered, strict translation fails with `:missing_operation_target`."*
3. **The substrate** — `Encoding.encode_diff/2` includes the document's **entire delete set**.
   Delete sets are not filtered by a state vector, so an update carries every tombstone the
   document holds, not only the ones the edit created.

⇒ **Any edit authored on a document that has ever had a deletion carries pre-existing tombstone
coordinates, which a §10.5 derivation does not map — so strict translation fails and the crossing
re-authors.**

## Measured, with a control

Upstream-authored corpus, one insert authored over each assembled document:

| case | tombstones | `translate/4` | `cross/5` |
|---|---|---|---|
| 001 concurrent inserts | none | ✅ **OK** | `:translated` |
| 002 sequential inserts | none | ✅ **OK** | `:translated` |
| 003 overlapping deletes | yes | ⛔ `:missing_operation_target` | `:reauthored` |
| 004 adjacent deletes | yes | ⛔ `:missing_operation_target` | `:reauthored` |
| 005 delete then insert | yes | ⛔ `:missing_operation_target` | `:reauthored` |

The failing reference is the **delete set**, not the anchor:

```
edit's delete_set : %{100 => [{1, 5}]}   # clocks 1..4 — PRE-EXISTING tombstones
snapshot spans    : {100,0,len 1}, {100,5,len 3}   # live clocks only
failure           : :missing_operation_target, field: :delete, ref: {100, 1}
```

⭐ **Control:** the *same edit* against a document assembled from only the first update — identical
in every way except that nothing has been deleted — **translates successfully.** So it is the
tombstones, not the foreignness of the bytes, the client ids, or the edit itself.

## Why it matters

⛔ **Nothing here is a defect.** Every clause behaves as written, and §27.4's fallback catches it:
the edit still crosses, by re-authoring. But the practical shape is worth stating plainly:

> **The strict, identity-preserving fast path is available mainly for documents that have never
> had a deletion.** For everything else, crossing works but loses authorship identity.

And §17 compounds it: a re-authored delta proves no correspondence, so a *later* edit depending on
it also re-authors. **A document reverts to identity-preserving translation only when a fresh
snapshot re-establishes a correspondence.**

## Options, for the spec's owner rather than for me

1. **Map tombstones in the derivation.** §31 already lists *"tombstone-preserving snapshots and
   bridges"* as deferred beyond 0.1 — this measurement is an argument about its priority, not a new
   idea.
2. **Let strict translation tolerate an uncovered delete range that is already satisfied at the
   destination.** §15.8 explicitly declines this today: *"Version 0.1 does not silently discard that
   part of the source deletion."* ⚠️ Note "silently" — a *checked* discard, against a supplied
   destination state, is a different proposition from a silent one.
3. **Have the caller trim the delete set** to the edit's own deletions before translating. Cheapest,
   and pushes the decision to whoever knows which deletions are new — but it makes the caller
   responsible for a wire-format detail (`encode_diff` includes everything) that is easy to get
   wrong and silent when wrong.

**Not resolved here.** Recorded so the choice is made rather than inherited.

## Method note

⭐ This surfaced only from running the library against **bytes authored by a different
implementation**. Every other test in the repo builds documents through yelixer, and none of them
combined "a document with tombstones" with "an edit encoded as a real delta" — the two halves each
appeared, never together. The conformance corpus produced that combination without being designed
to.
