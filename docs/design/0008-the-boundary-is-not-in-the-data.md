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
