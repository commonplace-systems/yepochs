# Rulings on Yepochs Open Questions

**Status:** Authoritative design rulings for the 0.1 specification  
**Date:** 2026-08-23  
**Applies to:** `yepochs` spec r2 and
[`docs/OPEN-QUESTIONS.md`](https://github.com/commonplace-systems/yepochs/blob/main/docs/OPEN-QUESTIONS.md)

## 1. Summary of decisions

| Question | Ruling |
| --- | --- |
| Re-authored correspondence spans | Zero or more proven spans; empty is valid in 0.1. Remove the mandatory non-identity-span fixture. |
| Cumulative tombstone delete sets | Implement checked omission inside `yepochs`; do not make callers trim Yjs delete sets. |
| Determinism precondition | Determinism of Doc-taking APIs is over the exact Yelixer `Doc` representation, not merely observable value. |
| Commonplace consuming the package | Move from the library’s 0.1 acceptance criteria to a `commonplace-plan` integration milestone. |
| Repository attribution | Specify architectural layer ownership, not present repository location. |
| Module name | `Yepochs` is authoritative. |
| Adapter organization | Current implementation choices are accepted. |
| Span-complete snapshot derivations | Version as snapshot algorithm v3 unless all version-2 artifacts are explicitly abandoned. |

## 2. Re-authored crossings may return no correspondence spans

### Ruling

The current implementation is conforming for 0.1:

- a re-authored crossing MUST return a receipt;
- it MUST return every item correspondence it can prove; and
- the set of proven correspondence spans MAY be empty.

The specification MUST NOT require every re-authored crossing to return a
non-identity span.

### Required specification change

Replace the mandatory fixture requiring:

> a re-authored crossing returning non-identity correspondence spans

with fixtures requiring:

1. a re-authored crossing returns a receipt and zero or more proven spans;
2. an empty correspondence is valid when the adapter cannot prove item-level
   provenance;
3. a later causally dependent edit still crosses, using re-authoring again if
   strict correspondence remains absent; and
4. any adapter that claims provenance recovery is tested for the exact spans it
   emits.

### Consequence

The current observable-diff adapters may **latch into re-authoring**: once an
edit crosses without correspondence, later edits depending on its identities
will also miss the strict path. This does not violate the Bridge guarantee,
because those edits still cross by deterministic re-authoring.

Recovering strict translation through provenance-aware adapters is a desirable
optimization, not a 0.1 correctness requirement. A fresh snapshot may also
establish a new correspondence.

## 3. Historical delete ranges receive checked omission

### Ruling

Choose checked omission of already-satisfied delete ranges.

This logic belongs inside `yepochs`, specifically the high-level crossing path.
The caller MUST NOT be responsible for knowing that Yelixer’s
`Encoding.encode_diff/2` includes the document’s cumulative delete set.

Tombstone-preserving snapshots and Bridges remain deferred. They solve the
harder problem of later edits that genuinely use discarded tombstones as
anchors; they are not required merely to prevent historical delete ranges from
poisoning every later strict translation.

### Required algorithm

Given:

- `source_before`, the exact source Doc before the edit;
- `source_update`, the update being crossed;
- the Bridge correspondence and basis; and
- the exact destination Doc;

partition the incoming delete set as:

~~~text
historical = incoming_delete_set ∩ delete_set(source_before)
novel      = incoming_delete_set − historical
~~~

Then process each range as follows:

1. A range covered by the Bridge correspondence MUST be translated normally.
2. An uncovered historical range MAY be omitted only after `yepochs` proves
   that:
   - the range was already deleted before the current edit;
   - the Bridge basis is complete for live source content at its cut; and
   - the destination already embodies the deletion and contains no
     corresponding live item requiring deletion.
3. An uncovered novel range MUST NOT be omitted. Strict translation fails for
   that edit and `cross/5` selects positional re-authoring.
4. Mixed ranges MUST be split so covered, checked-historical, and novel
   subranges are handled independently.
5. Omission MUST be represented in deterministic preflight output. It MUST NOT
   happen silently inside the encoder.

### Low-level API behavior

`translate/4` may remain conservative when it is called without
`source_before` and destination state. In that case, an uncovered delete range
continues to return `:missing_operation_target`.

The normal `cross/5` path has the endpoint states required to perform checked
omission and SHOULD therefore preserve strict translation for ordinary edits
authored after historical deletions.

### Required tests

Add conformance cases proving:

1. an insertion after an old deletion crosses as `:translated` when the only
   uncovered delete coordinates are checked historical ranges;
2. a newly introduced uncovered deletion crosses as `:reauthored`;
3. a mixed delete interval is split correctly;
4. omission fails closed without exact source-before state;
5. omission fails closed when Bridge completeness cannot be established; and
6. upstream Yjs delete vectors 003–005 no longer re-author solely because their
   updates repeat pre-existing tombstones.

The measured basis for this ruling is
[`design/0004-tombstones-narrow-the-strict-path.md`](https://github.com/commonplace-systems/yepochs/blob/main/docs/design/0004-tombstones-narrow-the-strict-path.md).

## 4. Determinism is over exact Doc representation

### Ruling

Add this normative caller contract to every API that receives a materialized
Yelixer Doc:

> Byte determinism is defined over the exact Yelixer `Doc` representation
> supplied by the caller, including item identities, struct boundaries, and
> arrival-dependent internal representation. Two Docs with the same observable
> value but different internal representations are different inputs.

This applies to:

- `snapshot/2`;
- `rebase/4`; and
- `cross/5`, for both `source_before` and destination Docs.

It does not need to be a precondition of strict `translate/4`, which transforms
decoded update bytes without constructing a Doc.

The library MUST remain deterministic for one fixed exact input representation,
algorithm version, adapter version, codec version, and option set. It MUST NOT
claim canonicalization across different valid internal representations of the
same observable Yjs value.

The measured basis for this ruling is
[`design/0002-encode-determinism.md`](https://github.com/commonplace-systems/yepochs/blob/main/docs/design/0002-encode-determinism.md).

## 5. Commonplace adoption is not a library release gate

### Ruling

Remove “the Commonplace monorepo consumes the package” from the `yepochs` 0.1
acceptance criteria.

Replace it with a library-owned criterion:

> The package exposes the complete documented API and can be consumed by an
> external Mix project without a Commonplace dependency.

Track the following separately in `commonplace-plan`:

> `commonplace` takes a pinned dependency on `yepochs` and routes at least one
> existing crossing path through it.

Reading Commonplace code, recreating fixtures, and verifying compatibility
remain valid `yepochs` work. Mutating the Commonplace dependency graph does not.

## 6. Specifications name layers, not repository locations

### Ruling

Repository-placement claims in the extraction map are advisory and MUST NOT be
treated as architectural requirements.

Normative language should say:

- commit ancestry and common-ancestor discovery belong above `yepochs`, in the
  Merkle-CRDT layer;
- crossing policy, bridge persistence, signatures, and commit construction
  belong to their stated architectural layers; and
- current modules MAY remain in the Commonplace monorepo until a separate
  extraction plan moves them.

Before asserting that a module “remains in repository R,” an implementation
plan MUST verify that repository’s current tree.

## 7. Naming and implementation choices

### 7.1 Module name

`Yepochs` is authoritative. Replace remaining normative `YEpochs` spellings.

### 7.2 Rebase adapter files

The built-in adapters MAY remain together in `rebase.ex`. The suggested package
layout is non-normative. `Yepochs.Rebase.Adapter` remains the required extension
boundary.

### 7.3 XML

A dedicated XML adapter is not required for the currently supported subset:

- `XMLText` crosses through the sequence/text plane;
- element attributes cross through the map plane; and
- XML element children that snapshotting cannot preserve MUST be rejected with
  `:unsupported_content`.

Silent loss of XML children is never acceptable. The current post-condition
that counts live items under synthetic parent names is the correct guard.

### 7.4 Wire keys

`Derivation.to_map/1` MAY emit `"spans"` while `Bridge.to_map/1` emits
`"correspondence"`. The two objects have different semantic roles.

### 7.5 Decode limits

Decode-time resource limits MAY be enforced only by the bytes-to-`Update`
boundary. An API accepting an already decoded `Update` treats it as trusted
in-process data unless its contract explicitly says otherwise.

## 8. Remaining smaller rulings

### 8.1 Cross-language vectors

The existing five upstream-Yjs text vectors establish only text/delete
interoperability. They MUST NOT be presented as evidence for maps, arrays, or
XML.

Before 0.1 claims cross-language support for maps or arrays, add at least one
upstream-authored crossing vector for each claimed type. XML support may remain
explicitly limited to the measured subset above.

### 8.2 Inversion guard

Every inversion API MUST validate that its input is a partial bijection before
constructing an inverse. A map-key collision MUST return
`:invalid_derivation`; it MUST NOT silently discard a correspondence.

This is already a normative consequence of the Bridge algebra and is not an
open design choice.

### 8.3 Clock spans

The measured one-of-eight coverage from item-start maps is sufficient evidence
for the clock-span requirement. A visible refusal is preferable to a wrong
translation, but complete span coverage is required for the intended strict
path.

### 8.4 Content addressing and snapshot version

Span-complete derivations change persisted snapshot metadata and therefore
change content-addressed commit IDs.

If any experimental snapshot-version-2 artifacts may be retained or exchanged:

1. preserve version 2 as the legacy item-start derivation algorithm;
2. introduce the span-complete derivation algorithm as
   `yepochs.snapshot` version 3; and
3. retain explicit readers or migration boundaries for version-2 artifacts.

If every version-2 artifact is deliberately abandoned, the project MAY instead
declare an epoch-format reset. It MUST document that reset explicitly; it MUST
NOT silently assign changed mapping semantics to the old durable algorithm
version.

## 9. Required specification edits

The next spec revision should:

1. remove mandatory non-identity correspondence from fixture 19;
2. specify zero-or-more proven spans for re-authored crossings;
3. add checked omission of historical delete ranges to crossing preflight;
4. add the exact-Doc determinism precondition to every Doc-taking API;
5. move Commonplace adoption out of the library acceptance criteria;
6. replace repository-placement assertions with architectural layer ownership;
7. make `Yepochs` spelling consistent;
8. narrow cross-language claims to their actual vectors;
9. require inversion collision guards; and
10. version the span-complete snapshot algorithm as version 3 or declare an
    explicit epoch-format reset.

## 10. Resulting 0.1 boundary

After these changes, the 0.1 promise is:

> A supported edit authored at either endpoint of a Bridge crosses to the
> other endpoint deterministically. The library preserves Yjs identities when
> strict correspondence proves that it can; otherwise it re-authors the
> observable edit and returns a durable receipt. Historical cumulative delete
> ranges do not disable strict translation when their effects are provably
> already satisfied.

Provenance recovery after re-authoring, tombstone anchors, multi-source
derivations, and distributed Bridge-delta reconciliation remain later work.
