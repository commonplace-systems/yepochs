# 0008 — A Yepoch boundary is not detectable by inspecting the documents

**Status:** measured · **Date:** 2026-08-23 · **Evidence:** `test/epoch_boundary_test.exs`

## The finding

⛔ **This file exists because I asserted the opposite and the test failed.**

I wrote that a re-authoring *"replaces the base's identities"*. For a **single-author** document that
is false. The deterministic minter re-authors under the **smallest client id present**; with one
author it reuses it, and the clocks land identically:

```
origin identities   [{100, 0, 5}]
derived identities  [{100, 0, 5}]          <- IDENTICAL
spans               {100,0} -> {100,0}     <- the identity mapping
snapshot.update == Encoding.encode_update(origin)   -> TRUE, byte-identical
```

⇒ **Two documents can be byte-for-byte equal and belong to different Yepochs.** A Yepoch is a
namespace, not a property of the content — and **nothing in the artifact distinguishes them.**

## Why it matters more than it looks

⭐ **This is the argument for a carried epoch id, and it is stronger than any argument from
convenience: the boundary is not merely awkward to detect from the data, it is ABSENT from the
data.** There is no cleverer inspection that recovers it. Content, coordinates, and bytes are all
identical across it.

⇒ It also refines the advice I gave `commonplace-merkle-crdt` about their label-keyed
`refuse_snapshot` gate. I said *"key on the property, not the label."* ⚠️ **The property is not
available in the operation's content**, so the carried id is not merely the better instrument — it
is **the only** property-keyed instrument that exists.

⛔ And the hazard is real rather than theoretical: the two lineages **mint the same coordinate for
different content** as soon as either diverges. The test asserts that collision, because it is
invariant 1's exact failure — a raw `{client_id, clock}` interpreted without its Yepoch.

## What the collision actually costs — measured on a DESCENDANT

⭐ **The evidence belongs one edit later than the collision, and moving it there made the result
worse than either `commonplace-merkle-crdt` or I had stated.**

At the moment of a single-author snapshot the two namespaces are **isomorphic** — same coordinates,
same content, same bytes. ⇒ **Nothing is lost yet**, so a test on the colliding pair asserts a
difference that does not exist and is correctly refutable. The difference first *exists* when either
lineage takes its next edit:

```
child A   "helloAAA"   state vector %{100 => 8}
child B   "helloBBB"   state vector %{100 => 8}     <- SAME coordinates, by construction

integrate A then B  ->  "helloAAA"
integrate B then A  ->  "helloBBB"
```

⛔ **It is not ambiguity. It is silent data loss** — Yjs deduplicates by `{client, clock}`, so the
second edit is discarded as already-seen. **No error, no conflict, no trace.**

⛔⛔ **And the loser is chosen by ARRIVAL ORDER.** Two replicas handed the same two updates in
different orders converge to **different documents and stay there** — ⇒ **the one property a CRDT
exists to guarantee, broken not by a defect in the merge but by interpreting coordinates without
their Yepoch.** That is invariant 1 stated as a consequence rather than as a rule.

⚠️ Independently reproduced: `commonplace-merkle-crdt` measured the byte-identity result at the Yjs
level, without my minter on the path. The order-dependence is the half this repo added.

## The hinge this protects

Spec §6.3: *"Ordinary edits within a history do not create new Yepochs. Deterministic re-authoring
does."*

⚠️ The plausible tightening — **"every fork mints a Yepoch"** — is wrong, and it forecloses a
forked document pushing changes back. A fork that branches over the same Yjs history keeps its
identity space; one that **replays into fresh identities** mints a new Yepoch, and that fork
genuinely cannot be merged back cheaply, which is correct rather than a limitation.

⭐ Measured: **"fork" appears exactly once in the whole spec** (§17, about batching), and the only
statements about what creates a Yepoch are §6.3's rule and §6.4's *"intentionally creates a new
identity space"*. **So the spec does not invite the tightening — it simply never states the
negative.** `test/epoch_boundary_test.exs` is the negative, in executable form.

**Mutations:** claiming a fork does not retain identities → red. Making the contrast case
single-author, so re-authoring stops being visible → **red**, which is what proves the multi-author
precondition is load-bearing rather than incidental. Restored → green.

## Consequence for the identity-visible half

⇒ Where the source **is** multi-author, the difference is visible: a fork retains the origin's
identities and a re-authoring does not. ⚠️ **That is a true statement with a precondition**, and
stating it without the precondition is what produced this document.
