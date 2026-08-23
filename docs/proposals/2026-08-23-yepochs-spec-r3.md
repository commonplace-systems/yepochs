# Yepochs

**Version:** 0.1-draft-r3  
**Status:** Proposed extraction specification  
**Date:** 2026-08-23  
**Supersedes:** r2 (sha256 `8765bb150fcc01c7dcba164b994d5a6fe407f2cc86e5f3f69289f326c8405c14`), unchanged on disk  
**Amendment:** satisfiability only — see `docs/design/0007-spec-r3-amendment.md`  
**Library:** `yepochs`  
**Implementation substrate:** Yelixer

## 1. Decision

`yepochs` is a small, Commonplace-independent Elixir library for moving Yjs
edits in either direction between histories that represent compatible document
content but use different internal Yjs identities.

Yjs operations refer to internal items by `{client_id, clock}`. Re-authoring a
document can preserve its observable value while replacing those identities.
After that replacement, a change authored against the old identities cannot be
applied safely to the new document merely because both documents look the same.

`yepochs` makes that boundary explicit:

- a **Yepoch** names one interpretation of Yjs item coordinates;
- a deterministic **snapshot** re-authors observable state into a new identity
  space;
- a **derivation** records which new item coordinates came from which old item
  coordinates;
- a **bridge** is an evolving, bidirectional edit-compatibility relationship
  between two Yepochs;
- a **crossing** turns an edit authored at either endpoint into an edit
  applicable at the other endpoint;
- strict translation is the identity-preserving fast path; and
- deterministic re-authoring is the normal fallback when exact coordinate
  translation is impossible.

The defining Bridge contract is:

> Where a bridge exists between two Yepochs, every valid edit over the
> supported Yjs data model, authored in either endpoint Yepoch, can be
> deterministically applied to the other endpoint when the bridge is given the
> required endpoint state.

The precondition is not a weakening in disguise. A bridge exists exactly when a
snapshot could preserve the origin document's observable state under the pinned
algorithm version (§6.11). ⇒ Whether a document can hold a bridge is decidable
before any edit is crossed, and is answered by attempting the snapshot, which
either succeeds or returns `:unsupported_content`. The contract is unconditional
over every document for which the answer is yes.

A missing coordinate mapping is not normally a failed crossing. It means that
the strict fast path cannot prove an exact translation and the crossing must
re-author the edit's observable effect at the destination.

The library owns Yjs identity-space algebra. It does not own Commonplace logs,
Merkle commits, branches, signatures, admission policy, or document processes.

## 2. Architectural position

The intended dependency direction is:

~~~mermaid
flowchart TD
    Y["yelixer"] --> E["yepochs"]
    E --> M["commonplace-merkle-crdt"]
    M --> D["commonplace-document"]
    R["commonplace-log-reducer"] --> M
~~~

The arrows mean “is depended on by.”

`yepochs` MUST depend on Yelixer and ordinary utility libraries only. It MUST
NOT depend on any Commonplace package.

`commonplace-merkle-crdt` uses `yepochs` to implement a Yjs-backed reducer. It
owns the commit graph and decides which bridges and updates to supply.

## 3. Normative language

The terms MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are normative.

## 4. Scope

This specification defines:

- the meaning of a Yepoch;
- deterministic Yjs re-authoring;
- derivation spans and evolving bilateral bridges;
- bridge validation, inversion, extension, and composition;
- bidirectional edit crossing;
- strict translation of Yjs updates across one bridge or a bridge path;
- translation of insertion anchors, ID-valued parents, and delete sets;
- preservation of identities authored by the update being translated;
- deterministic strict-preflight diagnostics;
- deterministic positional re-authoring when strict translation is
  unavailable;
- bridge deltas and crossing receipts;
- algorithm and artifact versioning;
- the initial Elixir API; and
- extraction and conformance requirements.

This specification does not define:

- an append-only log;
- a Merkle commit or commit DAG;
- branch, directory, Cell, Assembly, Environment, or Realm semantics;
- discovery of a common ancestor;
- selection of a merge strategy;
- commit signing or trust policy;
- authorization or capabilities;
- network synchronization;
- multi-writer admission;
- automatic storage or garbage collection; or
- a general-purpose semantic merge for arbitrary application schemas.

## 5. The problem

Within one Yjs history, an item coordinate is conventionally written as:

~~~elixir
{client_id, clock}
~~~

The pair is meaningful only within the history that assigned it. Consider two
documents with the same visible text:

~~~text
source: "hello" stored at client 9, clocks 21..25
target: "hello" stored at client 17, clocks 4..8
~~~

An old insertion whose origin is `{9, 23}` cannot be applied unchanged to the
target. Its origin must become `{17, 6}`. The same is true for right origins,
ID-valued parents, and coordinates inside delete sets.

Comparing only the visible documents is insufficient. A translation requires a
proof of coordinate correspondence established when one representation was
derived from the other.

## 6. Vocabulary

### 6.1 Item reference

An **item reference** is a Yjs coordinate:

~~~elixir
@type client_id :: non_neg_integer()
@type clock :: non_neg_integer()
@type item_ref :: {client_id(), clock()}
~~~

Client IDs and clocks MUST be valid Yjs safe integers supported by the pinned
Yelixer codec.

### 6.2 Clock interval

A **clock interval** is the half-open range:

~~~text
[clock, clock + length)
~~~

for one client ID, where `length` is positive.

Intervals, rather than item-start pairs, are the primitive mapping unit. Yjs
may consolidate or split structs while retaining references to clocks inside
their logical ranges.

### 6.3 Yepoch

A **Yepoch** is one identity namespace for a Yjs document history. It determines
what each raw `{client_id, clock}` coordinate means.

A Yepoch is not:

- a Commonplace log;
- a Document UUID;
- a branch;
- a Merkle commit in general;
- a reducer epoch; or
- a particular observable document value.

Ordinary edits within a history do not create new Yepochs. Deterministic
re-authoring does.

The library treats a Yepoch reference as an opaque, canonical UTF-8 string
supplied by its caller:

~~~elixir
@type epoch_ref :: String.t()
~~~

An epoch reference MUST be non-empty and contain at most 1,024 UTF-8 bytes.
`yepochs` MUST otherwise compare it byte-for-byte. It MUST NOT require the
reference to be a UUID, CID, hash, or Commonplace commit ID.

### 6.4 Snapshot

A **snapshot** is a deterministic re-authoring of a Yjs document’s observable
state into a fresh Yjs history.

It is not a Yjs state-vector snapshot and it is not merely serialization of the
source struct store. It intentionally creates a new identity space.

### 6.5 Derivation

A **derivation** is an endpoint-free, canonical set of spans produced while
creating one representation from another.

Each span pairs coordinates in the originating representation with coordinates
in the newly derived representation:

~~~text
origin/old <-> derived/new
~~~

Derivation provenance is directed: the new representation was produced from
the old representation. The coordinate correspondence is a partial bijection
and can be looked up in either direction.

### 6.6 Bridge

A **bridge** is an evolving, bidirectional edit-compatibility relationship
between two Yepochs. Its endpoints are called **left** and **right** only to
give persisted correspondence spans a stable orientation.

The snapshot that established a bridge has directed provenance:

~~~text
origin Yepoch --snapshot/derivation--> derived Yepoch
~~~

The bridge itself does not have a permanent source or target. For one crossing,
the endpoint where the edit was authored is the source and the other endpoint
is the destination; the roles reverse for an edit traveling the other way.

A bridge contains:

- its two endpoint Yepoch references;
- a monotonically growing correspondence between item-coordinate subsets;
- metadata describing the snapshot or equivalent witness that established the
  initial relationship; and
- crossing receipts needed for idempotence or for edits whose effects were
  re-authored or absorbed without a complete item-for-item correspondence.

Keeping the derivation endpoint-free avoids a content-addressing cycle. A
caller may:

1. create a snapshot and derivation;
2. place both in a Merkle object;
3. calculate that object’s ID; and then
4. attach the resulting derived Yepoch reference to form a bridge.

### 6.7 Crossing

A **crossing** takes an edit authored in either endpoint Yepoch and produces an
update applicable to the other endpoint.

A crossing returns:

- the destination update, which may be empty;
- the mode used: strict translation, re-authoring, or absorption;
- a monotonic bridge delta; and
- a receipt suitable for associating the source edit with its destination
  outcome.

Crossing is the high-level operation that provides the Bridge guarantee.
Strict translation and positional re-authoring are its two implementation
paths.

### 6.8 Owned identity

An **owned identity** is an item coordinate defined by an item struct inside the
update currently being translated.

Strict translation preserves owned identities. References among items in the
same translated update therefore remain valid without bridge lookup.

### 6.9 External reference

An **external reference** is an identity-bearing coordinate used by an update
but not defined by that update.

External references MUST be translated through a bridge. They MUST NOT be
passed through merely because their numeric client and clock values look valid
in the destination.

### 6.10 Positional re-authoring

A **positional re-authoring** recovers the observable effect of an edit by
comparing the source state before and after that edit and re-authoring the
effect against a destination state. The implementation module may retain the
name `YEpochs.Rebase`.

It is the normal crossing fallback, not identity-preserving translation. It
creates new item identities and does not preserve the original Yjs authorship
coordinates.

### 6.11 Supported data model, and bridgeability

The **supported data model** of an algorithm version is the set of observable
Yjs constructs that version can preserve through a snapshot. It is a property of
the version, not of this document, and an implementation MUST be able to report
it for each version it exposes.

A document is **bridgeable** under a version when snapshotting it under that
version preserves its observable state. A document containing content outside
the supported data model is **not bridgeable**: no correspondence over it can be
derived, so no bridge over it can be attached, and consequently no edit
authored on it can cross.

⛔ This is announced, never inferred. Attempting to snapshot an unbridgeable
document MUST return `:unsupported_content` (§10.2), and MUST NOT return a
snapshot whose observable state differs from the source.

A limit of this kind belongs to a version and can be lifted by a later one. An
implementation MUST NOT record it as a permanent property of the data model.

## 7. Core invariants

A conforming implementation MUST preserve these invariants:

1. A raw item reference is never interpreted without a known Yepoch.
2. Snapshotting preserves supported observable Yjs state but creates a new
   identity space.
3. Every correspondence span pairs equal-length intervals at the two
   endpoints.
4. The strict correspondence is a partial bijection: neither endpoint contains
   overlapping mapped intervals.
5. Between the endpoints of an existing bridge, and given the required endpoint
   state, every valid edit over the supported Yjs data model can cross from
   either endpoint to the other. Documents that are not bridgeable under the
   pinned version (§6.11) are outside this invariant, and are refused rather
   than partially served.
6. Reorienting a bridge swaps presentation, not capability: the same edits can
   cross in both directions.
7. Strict translation preserves every item identity authored by the translated
   update.
8. Strict translation rewrites every external identity reference or leaves the
   strict fast path without partial output.
9. Missing mappings are never guessed from visible position or raw numeric
   equality during strict translation.
10. A failed strict preflight normally selects deterministic positional
    re-authoring; it is not itself a failed crossing.
11. Every successful crossing returns a bridge delta and receipt before its
    result is considered admitted.
12. Bridge evolution is monotonic: accepted correspondence and receipts are
    added, never silently rewritten or removed.
13. The same supported inputs, endpoint states, options, and algorithm versions
    produce the same crossing bytes, bridge delta, and receipt, or the same
    error.

## 8. Data model

### 8.1 Span

The logical Elixir representation is:

~~~elixir
defmodule Yepochs.Span do
  @enforce_keys [
    :left_client,
    :left_clock,
    :right_client,
    :right_clock,
    :length
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          left_client: non_neg_integer(),
          left_clock: non_neg_integer(),
          right_client: non_neg_integer(),
          right_clock: non_neg_integer(),
          length: pos_integer()
        }
end
~~~

For offset `n` where `0 <= n < length`, the span means:

~~~text
{left_client, left_clock + n}
    corresponds to
{right_client, right_clock + n}
~~~

For a fresh snapshot derivation, the left side is the origin document and the
right side is the newly derived document. Once attached to a bridge, left and
right refer only to the bridge's stable endpoint orientation.

### 8.2 Derivation

~~~elixir
defmodule Yepochs.Derivation do
  @enforce_keys [:format_version, :spans]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          format_version: pos_integer(),
          spans: [YEpochs.Span.t()]
        }
end
~~~

Version 0.1 defines derivation format version 1.

Despite its provenance-oriented name, the value is mathematically an
endpoint-free correspondence. A bridge may monotonically union derivations
produced by crossings in either direction after orienting their spans to the
bridge's left and right endpoints.

### 8.3 Bridge

~~~elixir
defmodule Yepochs.Bridge do
  @enforce_keys [
    :format_version,
    :left_epoch,
    :right_epoch,
    :correspondence,
    :basis,
    :receipts
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          format_version: pos_integer(),
          left_epoch: String.t(),
          right_epoch: String.t(),
          correspondence: Yepochs.Derivation.t(),
          basis: Yepochs.Bridge.Basis.t(),
          receipts: [YEpochs.Crossing.Receipt.t()]
        }
end
~~~

`basis` identifies how the initial correspondence was established. A snapshot
basis records which endpoint was re-authored from the other; a composed or
explicit basis makes no such claim. This metadata does not constrain the
direction of later crossings.

~~~elixir
defmodule Yepochs.Bridge.Basis do
  @enforce_keys [:kind, :producer]
  defstruct [:kind, :producer, :origin, :derived]

  @type side :: :left | :right
  @type t :: %__MODULE__{
          kind: :snapshot | :composition | :explicit,
          producer: Yepochs.Algorithm.t(),
          origin: side() | nil,
          derived: side() | nil
        }
end
~~~

For `:snapshot`, `origin` and `derived` MUST name opposite sides. For a composed
or explicitly asserted bridge, they MUST be null because neither endpoint is
claimed to have been directly produced from the other.

### 8.4 Bridge delta and receipt

Every successful crossing returns an append-only delta:

~~~elixir
defmodule Yepochs.Bridge.Delta do
  @enforce_keys [:correspondence, :receipt]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          correspondence: Yepochs.Derivation.t(),
          receipt: Yepochs.Crossing.Receipt.t()
        }
end
~~~

The correspondence spans are already oriented to the bridge's left and right
endpoints. They may be empty for an absorbed edit.

A receipt is conceptually:

~~~elixir
defmodule Yepochs.Crossing.Receipt do
  @enforce_keys [:ref, :from, :to, :mode, :outcome, :algorithm]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          ref: String.t(),
          from: :left | :right,
          to: :left | :right,
          mode: :translated | :reauthored | :absorbed,
          outcome: :applied | :absorbed,
          algorithm: Yepochs.Algorithm.t()
        }
end
~~~

A receipt contains:

- an opaque crossing or source-edit reference supplied by the caller;
- the endpoint from which the edit crossed;
- the endpoint to which it crossed;
- the crossing mode;
- whether the effect was applied or absorbed; and
- versioned algorithm identifiers sufficient to replay the decision.

The Commonplace integration normally uses a Merkle commit or operation ID as
the opaque receipt reference. Yepochs does not interpret or mint that ID.

### 8.5 Algorithm

~~~elixir
defmodule Yepochs.Algorithm do
  @enforce_keys [:id, :version]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          version: pos_integer()
        }
end
~~~

Version 0.1 recognizes at least:

| Algorithm ID | Version | Purpose |
| --- | ---: | --- |
| `yepochs.snapshot` | 2 | Compatibility extraction of the experimental Commonplace snapshotter. |
| `yepochs.cross` | 1 | Bidirectional crossing strategy and result contract. |
| `yepochs.translate` | 1 | Strict identity translation. |
| `yepochs.rebase` | 1 | Positional re-authoring fallback. |
| `yepochs.compose` | 1 | Composition of compatible bridge mappings. |
| `yepochs.extend` | 1 | Addition of an admitted bridge delta. |

Algorithm versions are durable semantic identifiers. They are independent of
the Hex package version.

### 8.6 Portable wire value

The library MUST expose `to_map/1` and `from_map/1` for derivations and bridges.
The representation MUST use string keys, safe non-negative integers, and a
canonically sorted span list. It MUST contain no Elixir module names or atoms
derived from input.

A bridge version 1 map is equivalent to:

~~~json
{
  "version": 1,
  "left_epoch": "origin-epoch-reference",
  "right_epoch": "derived-epoch-reference",
  "basis": {
    "kind": "snapshot",
    "origin": "left",
    "derived": "right",
    "producer": {
      "id": "yepochs.snapshot",
      "version": 2
    }
  },
  "correspondence": [
    {
      "left_client": 9,
      "left_clock": 21,
      "right_client": 17,
      "right_clock": 4,
      "length": 5
    }
  ],
  "receipts": [
    {
      "ref": "opaque-source-edit-reference",
      "from": "left",
      "to": "right",
      "mode": "translated",
      "outcome": "applied",
      "algorithm": {
        "id": "yepochs.cross",
        "version": 1
      }
    }
  ]
}
~~~

The enclosing application owns canonical byte encoding of this map. Yepochs
owns its semantic validation and canonical span order.

## 9. Derivation validation and normalization

`YEpochs.Derivation.validate/1` MUST enforce:

- format version is supported;
- every coordinate is a valid Yjs safe integer;
- every length is positive;
- no interval overflows the supported clock range;
- left intervals do not overlap;
- right intervals do not overlap; and
- spans are a partial bijection at every mapped clock.

`YEpochs.Derivation.normalize/1` MUST:

1. validate the input;
2. sort spans by left client, left clock, right client, and right clock;
3. coalesce adjacent spans when both their left intervals and right
   intervals are contiguous and their client IDs match; and
4. return one canonical representation.

Normalization MUST NOT reorder semantic content, fill gaps, or infer a mapping.

The same logical derivation MUST normalize to byte-equivalent `to_map/1`
output.

## 10. Deterministic snapshotting

### 10.1 Contract

The initial public operation is conceptually:

~~~elixir
@spec snapshot(Yelixer.Doc.t(), keyword()) ::
        {:ok, Yepochs.Snapshot.t()} | {:error, Yepochs.Error.t()}
~~~

with result:

~~~elixir
defmodule Yepochs.Snapshot do
  @enforce_keys [:update, :derivation, :algorithm]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          update: binary(),
          derivation: Yepochs.Derivation.t(),
          algorithm: Yepochs.Algorithm.t()
        }
end
~~~

The result intentionally does not contain a target Yepoch reference. The
caller commonly learns that reference only after storing or hashing the
snapshot artifact.

### 10.2 Observable equivalence

Applying `snapshot.update` to an empty Yelixer document MUST produce the same
supported observable state as the source document.

Observable state includes, where supported by the pinned algorithm version:

- top-level shared type names and kinds;
- visible text and text formatting;
- map keys and values;
- visible array order and values;
- XML structure, attributes, and text; and
- supported nested shared values.

Struct-store layout, state vectors, item coordinates, deleted structs, and
client history are not observable state for this contract.

If the implementation cannot preserve an encountered shared type, nested type,
content variant, embed, or formatting form, it MUST return
`:unsupported_content`. It MUST NOT silently omit, stringify, or flatten it.

Such a document is not bridgeable under this version (§6.11), and the refusal is
the whole of the behaviour owed: there is no partial bridge, no best-effort
correspondence, and no degraded crossing over it.

`:unsupported_content` covers two conditions that differ in what a caller can do
about them, and an implementation MUST distinguish them in the error's details:

- a **caller-side** condition, where the same content would be preserved if
  presented differently — the implementation MUST report what would remedy it;
- a **version limit**, where the content lies outside the supported data model —
  the implementation MUST NOT offer a remedy, because none exists at this
  version.

### 10.3 Algorithm version 2

The extraction MUST preserve the current experimental Commonplace snapshotter
behavior under `yepochs.snapshot` version 2, including its mixed shared-type
handling and existing deterministic fixtures.

For compatibility, version 2 selects the minimum source client ID as its
snapshot client ID, or `0` for an empty source. All other traversal, item
construction, and encoding choices that affect output bytes are part of the
versioned algorithm and MUST be fixed by conformance fixtures before release.

Changing any byte-affecting choice requires a new snapshot algorithm version.

### 10.4 Snapshot determinism

For a supported source document, repeated calls using the same:

- decoded source state, including its Yjs item identities and supported struct
  representation;
- algorithm version;
- explicit options; and
- pinned Yelixer codec version

MUST return byte-identical update data and byte-equivalent normalized
derivations.

Snapshotting MUST NOT depend implicitly on wall-clock time, randomness, BEAM
process identity, map enumeration accidents, network data, or node identity.

### 10.5 Derivation completeness

The derivation MUST cover every right-side item clock emitted for observable
content and its corresponding left-side source clock.

Version 0.1 snapshots do not promise mappings for source tombstones or content
that is not retained in the derived snapshot. A later edit that refers to such
content may therefore leave the strict translation path. The bridge crossing
contract still requires positional re-authoring of that edit.

⭐ For source tombstones this is impossible **by construction**, not merely
unpromised. A snapshot mints live content only, so a source tombstone has no
item in the derived document to be paired with — it is absent, not misplaced.
No derivation over a snapshot of live content can map it, at any version that
snapshots live content.

Two consequences follow, and are therefore not exceptions:

- a correspondence may legitimately be **empty** for an edit, and §17's receipt
  rather than its spans is what records the crossing; and
- a re-authored edit proves no correspondence, so later edits depending on it
  also re-author (§17) until a fresh snapshot re-establishes one.

A version that also snapshots tombstones would lift this. Until one exists, an
implementation MUST NOT present the tombstone case as an unimplemented feature.

## 11. Attaching a bridge

After a caller has identified the derived Yepoch, it constructs a bridge:

~~~elixir
@spec attach(
        Yepochs.Derivation.t(),
        origin_epoch :: String.t(),
        derived_epoch :: String.t(),
        producer :: Yepochs.Algorithm.t()
      ) :: {:ok, Yepochs.Bridge.t()} | {:error, Yepochs.Error.t()}
~~~

The function MUST validate both epoch references, validate and normalize the
derivation, reject equal endpoints, assign the origin to the bridge's left
endpoint, assign the derived Yepoch to its right endpoint, and record that
directed fact in `basis`.

Attaching endpoint labels does not change any span. Later use of the bridge is
bidirectional regardless of its construction orientation.

## 12. Bridge lookup

The API MUST make direction explicit:

~~~elixir
# Given a coordinate in the left endpoint
@spec right_ref(Bridge.t(), item_ref()) ::
        {:ok, item_ref()} | :unmapped

# Given a coordinate in the right endpoint
@spec left_ref(Bridge.t(), item_ref()) ::
        {:ok, item_ref()} | :unmapped
~~~

Both operations MUST support references to any clock inside a span, not only
the first clock of an encoded Yjs item.

Lookup MUST NOT fall back to the same numeric coordinate when no span matches.
These lookups expose only the strict correspondence. `:unmapped` selects the
crossing fallback; it does not prove that an edit cannot cross.

## 13. Bridge inversion

~~~elixir
@spec invert(Bridge.t()) ::
        {:ok, Bridge.t()} | {:error, Yepochs.Error.t()}
~~~

Inversion swaps:

- left and right epoch references;
- the left and right coordinates in every span;
- left and right roles in the basis metadata; and
- `from` and `to` sides in every receipt.

It then normalizes the result. Inversion MUST fail if the input is not a valid
partial bijection.

Endpoint-free derivations MAY be inverted by swapping left and right
coordinates in the same way. Bridge inversion additionally swaps endpoint and
receipt presentation. It does not produce a new logical relationship.

For every valid bridge `b`:

~~~text
invert(invert(b)) == normalize(b)
~~~

## 14. Bridge composition

Given:

~~~text
A --ab--> B --bc--> C
~~~

where `ab.left_epoch == A`, `ab.right_epoch == B`,
`bc.left_epoch == B`, and `bc.right_epoch == C`, composition produces:

~~~text
A --ac--> C
~~~

Its strict correspondence is calculated through the shared endpoint:

~~~text
A <-> B <-> C
~~~

The API is:

~~~elixir
@spec compose([Bridge.t()]) ::
        {:ok, Bridge.t()} | {:error, Yepochs.Error.t()}
~~~

Composition MUST:

1. require at least one bridge;
2. validate adjacent endpoints;
3. intersect and split spans at intermediate range boundaries;
4. retain only coordinates mapped across the complete path;
5. normalize the result; and
6. use an explicit composition basis identifier rather than pretending one
   snapshotter directly produced the composed mapping; and
7. leave edge-specific crossing receipts on their original bridges rather than
   pretending they occurred directly between A and C.

Composition is associative at the logical mapping level. After normalization:

~~~text
compose([compose([ab, bc]), cd])
    ==
compose([ab, compose([bc, cd])])
~~~

for every compatible path.

The resulting strict mapping may be smaller than either input because each
correspondence is partial. Composition MUST NOT invent missing item mappings.
An edit crossing the composed bridge still uses positional re-authoring when
strict preflight lacks coverage.

## 15. Crossing edits

### 15.1 Crossing contract

The high-level operation is conceptually:

~~~elixir
@spec cross(
        Yepochs.Bridge.t(),
        source_update :: binary(),
        source_before :: Yelixer.Doc.t(),
        destination :: Yelixer.Doc.t(),
        keyword()
      ) :: {:ok, Yepochs.Crossing.t()}
           | {:error, Yepochs.Error.t()}

defmodule Yepochs.Crossing do
  @enforce_keys [
    :from_epoch,
    :to_epoch,
    :update,
    :mode,
    :outcome,
    :bridge_delta,
    :algorithm
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          from_epoch: String.t(),
          to_epoch: String.t(),
          update: binary(),
          mode: :translated | :reauthored | :absorbed,
          outcome: :applied | :absorbed,
          bridge_delta: Yepochs.Bridge.Delta.t(),
          algorithm: Yepochs.Algorithm.t()
        }
end
~~~

Options MUST identify whether the edit is crossing from the bridge's left or
right endpoint and MUST supply:

- an explicit destination author/client ID for possible re-authoring;
- the supported rebase adapter set and versions;
- an opaque receipt reference for durable use; and
- deterministic resource limits.

`source_before` MUST be the exact source state against which the update was
authored. `destination` MUST be the exact destination state at which the
crossing result will be admitted. The function applies the source update to a
private copy of `source_before` when it needs the edited state.

For a structurally valid edit over the selected supported data model, `cross/5`
MUST return an update applicable to the destination in either direction. It MAY
return an error only when:

- the update or endpoint state is malformed;
- a required exact endpoint state is unavailable;
- the edit uses content outside the declared adapter support;
- a deterministic resource limit is exceeded;
- a requested durable algorithm version is unavailable; or
- the caller explicitly requested strict-only diagnostics.

Missing coordinate coverage and strict identity collisions are not terminal
errors under the default crossing strategy.

### 15.2 Crossing modes

A crossing selects exactly one mode:

1. `:translated`: strict preflight succeeds, every external identity reference
   is rewritten through the correspondence, and update-owned IDs are
   preserved.
2. `:reauthored`: strict preflight cannot prove an exact translation, so the
   observable source change is deterministically re-authored against the
   destination with new destination identities.
3. `:absorbed`: the observable source change is already satisfied at the
   destination or has no destination-visible effect, so the returned update is
   empty.

Every mode returns a receipt. Translated and re-authored crossings additionally
return every item correspondence the implementation can prove. Later dependent
edits may use those spans; any remaining unmapped dependency simply selects
re-authoring again.

The caller MUST apply or durably admit the returned destination update before
applying its bridge delta. Destination admission and bridge extension SHOULD be
committed atomically by the enclosing Merkle or log protocol.

### 15.3 Strict fast-path contract

Strict translation has the conceptual API:

~~~elixir
@spec translate(binary(), Bridge.t(), :left | :right, keyword()) ::
        {:ok, Yepochs.Translation.t()}
        | {:error, Yepochs.Error.t()}

defmodule Yepochs.Translation do
  @enforce_keys [:update, :carried, :algorithm]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          update: binary(),
          carried: Yepochs.Derivation.t(),
          algorithm: Yepochs.Algorithm.t()
        }
end
~~~

The direction argument identifies the endpoint in which the update was
authored. The other endpoint is the destination.

`translate/4` MUST run preflight first and MUST NOT emit a partial update. It is
a public low-level diagnostic and optimization API; unlike `cross/5`, it MAY
return missing-mapping or identity-collision errors.

`cross/5` MUST attempt this path first unless the caller explicitly selects a
different deterministic strategy. Any strict failure eligible for re-authoring
is internal control flow, not the crossing result.

### 15.4 Owned item identities

The translator first inventories every item interval defined by the input
update. Those intervals are owned by the update.

The translator MUST preserve:

- each owned item’s client ID;
- its starting clock;
- its length; and
- references from one owned interval to another owned interval.

The result’s `carried` derivation contains identity spans for owned intervals:

~~~text
destination coordinate == authored coordinate
~~~

Within `carried`, the local left side denotes the authored endpoint and the
local right side denotes the destination. `cross/5` reorients the spans to
bridge-left/bridge-right form inside its delta. The caller MUST NOT apply that
delta until the translated update has been accepted by the destination
document.

### 15.5 Identity collision

Preserving an owned identity is impossible if that raw coordinate already
means a different item in the destination Yepoch.

Preflight MUST reject an owned interval that overlaps a destination interval in
the bridge unless the existing correspondence is the same identity mapping. If
the caller supplies a destination document or interval inventory, preflight
MUST also reject overlap with any occupied destination coordinate not
represented by the bridge.

The strict error code is `:target_identity_collision`. The high-level crossing
then uses positional re-authoring, which can allocate a new caller-supplied
destination author identity.

### 15.6 Insertion anchors

For every item, the translator MUST examine:

- `origin`; and
- `right_origin`.

For each non-null reference:

1. if the reference is owned by the input update, leave it unchanged;
2. otherwise, translate it from the authored endpoint to the destination
   through the bridge correspondence; and
3. if no mapping exists, fail with `:missing_anchor`.

The error MUST identify the field and source reference.

### 15.7 Parent references

A named root parent is not an item coordinate and MUST remain unchanged.

An ID-valued parent MUST be handled as follows:

1. if it refers to an interval owned by the input update, leave it unchanged;
2. otherwise, translate it through the bridge; and
3. if no mapping exists, fail with `:missing_operation_target`.

### 15.8 Delete sets

Every delete-set interval MUST be translated. Reusing the source delete set
unchanged is non-conforming, even if insertion anchors were translated.

For each clock in a source delete interval, the translator MUST prove that it
is either:

- inside an interval owned by the input update, in which case the coordinate is
  preserved; or
- covered on the authored side of the bridge correspondence, in which case it
  is mapped to the destination coordinate.

The implementation SHOULD translate intervals by range arithmetic rather than
expanding them one clock at a time. It MUST split an interval when mappings are
non-contiguous, then normalize adjacent output delete ranges using Yjs ordering
rules.

If any part of a delete interval is uncovered, strict translation fails with
`:missing_operation_target`. Version 0.1 does not silently discard that part of
the source deletion. The high-level crossing uses positional re-authoring to
determine whether the delete must be reapplied or is already satisfied.

### 15.9 Unknown identity-bearing fields

The translator MUST understand every identity-bearing field emitted by the
pinned Yelixer/Yjs update version.

If a decoded struct or content variant may contain identity data that the
translator does not understand, translation MUST fail with
`:unsupported_translation_feature`. It MUST NOT copy the field through
unchanged. `cross/5` MAY still re-author the edit when a positional adapter
supports its observable content.

### 15.10 Encoding

The translated update MUST be encoded deterministically. Semantically
equivalent but byte-different output caused by unordered map traversal is not
permitted within one translator algorithm version.

## 16. Strict translation preflight

~~~elixir
@spec preflight(binary(), Bridge.t(), :left | :right, keyword()) ::
        {:ok, Yepochs.Preflight.t()}
        | {:error, Yepochs.Error.t()}
~~~

Preflight MUST perform every validation necessary for translation without
returning partially translated bytes. It MUST at least:

1. validate the bridge;
2. decode and validate the update;
3. inventory owned item intervals;
4. detect destination identity collisions visible from supplied information;
5. verify every external origin and right origin;
6. verify every external ID-valued parent;
7. verify complete coverage of every delete interval;
8. reject unsupported identity-bearing structures; and
9. calculate a deterministic translation plan.

The translator SHOULD consume the preflight plan rather than repeat lookup
logic independently.

When multiple references fail, the error details SHOULD contain every failure
in deterministic order. Missing references are classified as:

| Error code | Meaning |
| --- | --- |
| `:missing_anchor` | An insertion origin or right origin is absent, commonly because the anchor was tombstoned or omitted by re-authoring. |
| `:missing_operation_target` | A delete target or ID-valued parent is absent. |
| `:target_identity_collision` | An update-owned identity already has another meaning in the destination. |

This distinction is diagnostic. It does not authorize preflight to guess a
different anchor or target. Under `cross/5`, a missing reference or collision
selects re-authoring when the edit lies within the supported data model.

## 17. Bridge evolution and incremental crossing

A bridge is an immutable value that evolves by applying append-only deltas.
Either endpoint may originate the next crossing.

After a crossing result has been admitted at its destination, the caller
extends the bridge:

~~~elixir
@spec extend(Bridge.t(), Yepochs.Bridge.Delta.t()) ::
        {:ok, Bridge.t()} | {:error, Yepochs.Error.t()}
~~~

Extension MUST:

- preserve the bridge endpoints;
- validate new spans in the bridge's left/right orientation;
- reject an overlap that assigns either side two meanings;
- accept exact duplicate mappings idempotently;
- accept an exact duplicate receipt idempotently;
- reject reuse of one receipt reference for a different crossing result;
- normalize the correspondence; and
- retain earlier correspondence and receipts unchanged.

For a strictly translated edit, the delta normally adds identity spans because
the authored item IDs were preserved at the destination.

For a re-authored edit, the delta adds non-identity spans wherever the rebase
adapter can prove that newly authored destination items correspond to source
items. It also adds a receipt even when some source identities have no durable
item correspondent.

For an absorbed edit, the delta may contain alignments to existing destination
items, but its receipt is mandatory even when its correspondence is empty.

A later edit may refer to an earlier item that has no strict correspondence.
That is valid: strict preflight fails and crossing re-authors the later edit
from its observable before/after states.

This operation is an admission record, not merely an optimization. The caller
MUST persist the extension, or reconstruct it from accepted crossing records,
before relying on it for a later strict translation.

Translation of one closed batch remains an optimization: all post-fork edits
can be combined so references among them are owned by one input update. It is
not a prerequisite for correct incremental crossing.

## 18. Crossing a bridge path

A live tree normally propagates an edit one edge at a time. Each edge crossing
produces a destination update and a delta for that particular bridge. This is
the preferred high-level behavior because intermediate endpoints learn the edit
and every bilateral relationship evolves.

For strict-only algebra, the library also exposes:

~~~elixir
@spec translate_path(binary(), [Bridge.t()], keyword()) ::
        {:ok, Yepochs.Translation.t()}
        | {:error, Yepochs.Error.t()}
~~~

`translate_path/3` MUST:

1. validate that the bridges form a connected source-to-target path;
2. compose the path into one bridge;
3. preflight the update once against that composed bridge; and
4. translate the update once.

It SHOULD NOT repeatedly decode, translate, and re-encode the update at every
hop.

Path discovery, ancestor selection, and choice between competing paths belong
to the caller.

`translate_path/3` does not satisfy the full Bridge crossing contract and does
not update the constituent bridges. If strict path translation fails, the
caller MUST either cross the edit edge-by-edge or invoke `cross/5` against a
real bridge joining the final endpoint states.

## 19. Positional re-authoring fallback

### 19.1 Contract

The re-authoring primitive remains separately callable:

~~~elixir
@spec rebase(
        before :: Yelixer.Doc.t(),
        edited :: Yelixer.Doc.t(),
        target :: Yelixer.Doc.t(),
        keyword()
      ) :: {:ok, Yepochs.Rebase.Result.t()}
           | {:error, Yepochs.Error.t()}
~~~

where:

- `before` is the source document immediately before the edit being crossed;
- `edited` is `before` plus that edit;
- `target` is the state onto which its observable effect should be reapplied;
  and
- options include an explicit target author/client identity.

The result contains:

- an update authored against `target`;
- an outcome such as `:applied` or `:absorbed`;
- every source-to-destination item correspondence the adapter can prove; and
- the rebase algorithm and adapter versions.

Conceptually:

~~~elixir
defmodule Yepochs.Rebase.Result do
  @enforce_keys [:update, :outcome, :correspondence, :algorithm, :adapters]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          update: binary(),
          outcome: :applied | :absorbed,
          correspondence: Yepochs.Derivation.t(),
          algorithm: Yepochs.Algorithm.t(),
          adapters: [YEpochs.Algorithm.t()]
        }
end
~~~

Within `correspondence`, the local left side denotes the source edit and the
local right side denotes the destination result. `cross/5` reorients it to the
Bridge's stable endpoint sides before returning its delta.

### 19.2 Semantics

Rebase computes the supported observable difference from `before` to `edited`
and re-authors that difference against `target` using type-specific logic.

Version 0.1 SHOULD extract the existing Commonplace handlers for:

- Y.Text;
- Y.Map;
- Y.Array; and
- supported Y.XML forms.

Application-specific schemas MAY provide adapters through a behavior defined by
`YEpochs.Rebase.Adapter`. The base `yepochs` package MUST NOT depend on
Commonplace document modules.

An adapter that declares a data-model subset supported MUST deterministically
handle every structurally valid edit in that subset. If it can return
`:rebase_conflict` for such an edit, its declared support is narrower than that
subset and MUST say so explicitly.

If the observable effect is already true in `target`, rebase MAY return
`:absorbed` with an empty update.

### 19.3 Explicit loss of identity

Rebase does not necessarily preserve:

- original item identities;
- byte identity of the original update;
- original Yjs client authorship; or
- operation-level intent beyond the supported observable diff.

It MUST NOT be invoked silently by `translate/4` or `translate_path/3`.
`cross/5`, however, explicitly includes re-authoring in its contract and MUST
invoke it when strict translation cannot cross an otherwise supported edit.

Deterministic rebase requires an explicit author/client ID, algorithm version,
adapter set, and all other semantic options. A caller that supplies randomness
has chosen non-content-addressable output.

## 20. Version bridging

Snapshot algorithm upgrades create a practical migration problem: the same
source state may be re-authored differently by versions 2 and 3.

The supported bridge is a pair of snapshots from the same source Yepoch:

~~~text
                 source A
                /        \
       snapshot v2      snapshot v3
              /            \
         target B        target C
~~~

Because both derivations point back to A, a B-to-C bridge can be calculated by
inverting and composing their mappings through A. No special cross-version
translator is required when both derivations are valid.

Callers SHOULD retain derivations for old snapshot versions as long as updates
from those Yepochs may arrive.

## 21. Algorithm versioning

Any change that can alter accepted input, rejected input, crossing mode, output
bytes, bridge deltas, receipts, mapping semantics, or rebase results requires a
new algorithm version.

This includes changes to:

- snapshot traversal order;
- snapshot client-ID selection;
- Yjs struct construction or consolidation;
- update encoding;
- supported shared types;
- reference classification;
- delete-set translation;
- normalization; or
- positional diff and patch rules;
- selection between translation, re-authoring, and absorption; or
- the correspondence emitted by a rebase adapter.

Bug fixes that change durable output also require a new version unless the
previous behavior could never have produced a successful valid artifact.

The package MUST expose its supported algorithm versions. A durable caller MUST
select a version explicitly and MUST NOT silently substitute a newer version
during replay.

## 22. Error model

Public operations return tagged tuples and a structured error:

~~~elixir
defmodule Yepochs.Error do
  @enforce_keys [:code, :phase]
  defstruct [:code, :phase, :path, :refs, details: %{}]
end
~~~

At minimum, version 0.1 defines these codes:

| Code | Meaning |
| --- | --- |
| `:invalid_epoch_ref` | An endpoint reference is empty, too long, or invalid UTF-8. |
| `:invalid_derivation` | A span is malformed, overlapping, overflowing, or otherwise not a partial bijection. |
| `:bridge_endpoint_mismatch` | A bridge path is disconnected or supplied in the wrong order. |
| `:missing_endpoint_state` | A crossing lacks the exact source-before or destination state it requires. |
| `:malformed_update` | Yelixer cannot decode or structurally validate the update. |
| `:unsupported_content` | Snapshotting cannot faithfully preserve source content. |
| `:unsupported_translation_feature` | Strict translation encountered an identity-bearing feature it cannot safely rewrite. |
| `:unsupported_crossing_content` | Neither strict translation nor the selected rebase adapters support the edit's content. |
| `:missing_anchor` | Strict translation found an external origin or right origin without a mapping. |
| `:missing_operation_target` | Strict translation found an external parent or delete coordinate without a mapping. |
| `:target_identity_collision` | An owned source identity conflicts with the destination namespace on the strict path. |
| `:receipt_conflict` | One opaque receipt reference was reused for a different crossing result. |
| `:incompatible_algorithm` | A requested durable algorithm version is unavailable. |
| `:limit_exceeded` | A configured deterministic resource limit was exceeded. |
| `:invalid_rebase_input` | Before, edited, and target inputs do not satisfy the selected adapter contract. |
| `:rebase_conflict` | The edit lies outside the subset for which the selected positional adapter is total. |

Errors MUST contain data, not preformatted English as their only diagnostic.
Reference lists and paths MUST be deterministically ordered.

The default `cross/5` MUST NOT return `:missing_anchor`,
`:missing_operation_target`, or `:target_identity_collision` for an otherwise
supported edit. Those are low-level strict-path diagnostics that select
re-authoring.

## 23. Resource limits and untrusted input

Yjs updates and bridge maps may be untrusted. Public decoding operations MUST
support explicit deterministic limits for at least:

- input update bytes;
- decoded struct count;
- bridge span count;
- delete interval count;
- nested shared-type depth; and
- encoded output bytes.

The implementation MUST NOT create atoms from wire strings, execute stored
module names, fetch network resources, or use caller process state as implicit
input.

A limit failure returns `:limit_exceeded`; it does not return a partial
derivation or update.

## 24. Initial public API

The initial API SHOULD resemble:

~~~elixir
defmodule Yepochs do
  @spec snapshot(Yelixer.Doc.t(), keyword()) ::
          {:ok, Snapshot.t()} | {:error, Error.t()}

  @spec cross(
          Bridge.t(),
          binary(),
          Yelixer.Doc.t(),
          Yelixer.Doc.t(),
          keyword()
        ) :: {:ok, Crossing.t()} | {:error, Error.t()}

  @spec preflight(binary(), Bridge.t(), :left | :right, keyword()) ::
          {:ok, Preflight.t()} | {:error, Error.t()}

  @spec translate(binary(), Bridge.t(), :left | :right, keyword()) ::
          {:ok, Translation.t()} | {:error, Error.t()}

  @spec translate_path(binary(), [Bridge.t()], keyword()) ::
          {:ok, Translation.t()} | {:error, Error.t()}

  @spec rebase(
          Yelixer.Doc.t(),
          Yelixer.Doc.t(),
          Yelixer.Doc.t(),
          keyword()
        ) :: {:ok, Rebase.Result.t()} | {:error, Error.t()}
end

defmodule Yepochs.Derivation do
  @spec new([Span.t()]) :: {:ok, t()} | {:error, Error.t()}
  @spec validate(t()) :: :ok | {:error, Error.t()}
  @spec normalize(t()) :: {:ok, t()} | {:error, Error.t()}
  @spec invert(t()) :: {:ok, t()} | {:error, Error.t()}
  @spec to_map(t()) :: map()
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
end

defmodule Yepochs.Bridge do
  @spec attach(Derivation.t(), String.t(), String.t(), Algorithm.t()) ::
          {:ok, t()} | {:error, Error.t()}

  @spec right_ref(t(), item_ref()) :: {:ok, item_ref()} | :unmapped
  @spec left_ref(t(), item_ref()) :: {:ok, item_ref()} | :unmapped
  @spec invert(t()) :: {:ok, t()} | {:error, Error.t()}
  @spec compose([t()]) :: {:ok, t()} | {:error, Error.t()}
  @spec extend(t(), Yepochs.Bridge.Delta.t()) ::
          {:ok, t()} | {:error, Error.t()}
  @spec to_map(t()) :: map()
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
end
~~~

The exact module split may change before 0.1, but the semantic separation among
snapshot, derivation, bilateral bridge, crossing, strict translation, and
positional re-authoring is normative.

## 25. Commonplace integration

### 25.1 commonplace-merkle-crdt

`commonplace-merkle-crdt` owns:

- Merkle commit encoding and storage;
- commit parents and ancestry;
- selection of a common ancestor;
- reconstruction of source and target documents;
- collection or combination of updates since an ancestor;
- storage of snapshot updates and derivations;
- assignment of Yepoch references from commit or artifact IDs;
- selection of a bridge path;
- selection of a durable crossing algorithm version and any explicit
  strict-only or merge-snapshot policy;
- destination admission and atomic bridge-delta persistence after admission;
- author and system signatures; and
- construction of crossed or merge commits.

It calls `yepochs` for pure transformations and algebra.

A bidirectional bridge does not make either endpoint log multi-writer. A
crossing returns an update for the destination's own writer to admit. Source
authorship can remain durable metadata without bypassing the destination's
single append lane.

### 25.2 commonplace-log-reducer

A reducer epoch and a Yepoch are different concepts:

- a **reducer epoch** changes a projection’s reducer lifecycle, version, or
  self-contained base; while
- a **Yepoch** changes the meaning of Yjs item coordinates.

They often advance together for a Merkle CRDT projection, but they need not. A
reducer implementation upgrade may start a new reducer epoch while retaining
the same Yepoch. A Yepoch reference SHOULD therefore live inside the
`commonplace-merkle-crdt` reducer’s epoch base rather than being inferred from
the generic reducer epoch ID.

The current `commonplace-log-reducer` draft may retain UUIDs for its own epoch
IDs. If Commonplace later chooses to use one identifier for both concepts, that
draft must instead permit opaque canonical identifiers; `yepochs` itself MUST
not impose the coupling.

### 25.3 commonplace-document

`commonplace-document` owns admission, messages, permissions, mounted verbs,
and process lifecycle. It does not inspect Yjs clocks directly.

## 26. Extraction map from the experimental monorepo

| Experimental module or area | Destination |
| --- | --- |
| `Commonplace.Store.Snapshotter` | `YEpochs.Snapshotter` and snapshot fixtures. |
| Derivation-map functions in `Commonplace.Store.Namespace` | `YEpochs.Derivation` and `YEpochs.Bridge`. |
| `Commonplace.Store.LateEditPreflight` | `YEpochs.Preflight`. |
| `Commonplace.Store.LateEditTranslator` | `YEpochs.Translator`. |
| Pure crossing orchestration in `Commonplace.Store.Translator` | `YEpochs.Crossing`; commit loading, emission, and signing remain in Commonplace. |
| `Commonplace.Document.Rebase` and its Y.Text/Y.Map/Y.Array/Y.XML helpers | `YEpochs.Rebase` and adapters after removing Commonplace dependencies. |
| `Commonplace.Store.CrossEpochMerge` | Remains in `commonplace-merkle-crdt`; it calls Bridge crossing or the strict path algebra. |
| `Commonplace.Store.Merger` | Remains in `commonplace-merkle-crdt`; it chooses higher-order crossing versus merge-snapshot policy, not the internal strict-to-reauthor fallback. |
| `Commonplace.Store.SnapshotAncestry` | Remains in `commonplace-merkle-crdt`; it owns DAG traversal. |
| Node identity and commit signatures | Remain outside `yepochs`. |

The extraction MUST preserve existing successful fixtures before behavior is
changed.

## 27. Required corrections during extraction

Version 0.1 is not a namespace-only refactor. It makes four deliberate design
corrections.

### 27.1 Use spans, not item-start maps

The durable mapping primitive is a clock span. An implementation MAY build
indexes internally, but MUST NOT rely on ad hoc expansion from item-start pairs
as its semantic model.

This is required for:

- references into the middle of multi-clock items;
- item consolidation and splitting;
- delete ranges; and
- correct bridge composition.

### 27.2 Translate delete sets

The experimental preflight checks delete-set references, but the current late
edit translator appears to re-encode the original delete set unchanged. The
extracted implementation MUST translate delete-set coordinates and add
integration tests that fail under the old behavior.

### 27.3 Separate Yepochs from reducer epochs

The package API and persisted artifacts MUST call Yjs identity namespaces
Yepochs and MUST not reuse that term for the generic projection lifecycle.

### 27.4 Make Bridges bilateral edit transducers

The experimental derivation map is directed snapshot provenance. The extracted
Bridge MUST be a bidirectional, evolving relationship whose high-level
operation crosses supported edits in either direction.

Missing strict correspondence MUST select positional re-authoring rather than
becoming an ordinary “cannot cross” result. Every crossing MUST return a
monotonic bridge delta and receipt so later causally dependent edits can also
cross.

## 28. Conformance requirements

### 28.1 Compatibility fixtures

Before extraction is considered complete, the test suite MUST move or recreate
fixtures covering the current experimental behavior for:

- deterministic snapshotting;
- mixed top-level shared types;
- derivation-map inversion;
- derivation-map composition;
- origin translation;
- right-origin translation;
- ID-valued parent translation;
- preservation of update-owned identities;
- mixed source client IDs;
- late-edit preflight;
- positional fallback;
- re-authoring derivations; and
- cross-epoch translation inputs, even though commit orchestration remains in
  `commonplace-merkle-crdt`.

### 28.2 New mandatory fixtures

The extracted library MUST add fixtures for:

1. a reference into the middle of a multi-clock item;
2. a delete interval translated to a different client and clock;
3. a delete interval split across multiple target spans;
4. a delete interval containing both owned and bridged clocks;
5. a missing subrange in a delete interval;
6. an owned identity colliding with a target snapshot identity;
7. incremental bridge extension after accepted translation;
8. an exact duplicate extension applied idempotently;
9. a conflicting bridge extension;
10. translation through two and three composed bridges;
11. composition that loses partial coverage;
12. snapshot version bridging through a shared source;
13. deterministic refusal of an unsupported nested subtype;
14. repeated byte-identical snapshot and translation output; and
15. application of translated output to the destination producing the expected
    observable state;
16. the same insertion crossing left-to-right and right-to-left;
17. a missing anchor falling back to re-authoring in each direction;
18. an identity collision falling back to re-authoring rather than failing the
    crossing;
19. a re-authored crossing returning non-identity correspondence spans;
20. an absorbed crossing returning an empty update and durable receipt;
21. a later causally dependent edit crossing after a translated edit;
22. a later causally dependent edit crossing after a re-authored or absorbed
    edit with incomplete correspondence;
23. bridge inversion preserving the same bidirectional crossing capability;
24. duplicate receipt application being idempotent;
25. conflicting receipt reuse being rejected;
26. destination admission through its own writer without adding another log
    writer;
27. a **non-degenerate correspondence** — at least one fixture whose spans are
    not all identity mappings. ⛔ A single-author source document is re-authored
    under its own client ID, so every span comes out as an identity mapping, and
    a translator that ignored the bridge and passed raw coordinates through
    unchanged would satisfy the entire suite. That is invariant 9's exact
    prohibition, and a corpus of that shape cannot detect a violation of it; and
28. a **mislabelled crossing direction** over a non-identity span, which MUST
    re-author rather than translate through the opposite side of the
    correspondence.

### 28.3 Algebraic property tests

Generated valid span sets SHOULD verify:

- `invert(invert(d)) == normalize(d)`;
- normalized inversion preserves one-to-one lookup;
- composition is associative after normalization;
- exact duplicate extension is idempotent;
- lookup across a composed bridge equals successive lookup across its inputs;
- normalization is idempotent; and
- serialization round-trips without semantic change.

### 28.4 Yjs interoperability

Pinned conformance vectors SHOULD be applicable by both Yelixer and the
corresponding official Yjs wire implementation. Cross-language fixtures MUST
record the Yjs and Yelixer versions that generated them.

## 29. Suggested package layout

~~~text
lib/
  yepochs.ex
  yepochs/
    algorithm.ex
    bridge.ex
    bridge/
      basis.ex
      delta.ex
    crossing.ex
    crossing/
      receipt.ex
    derivation.ex
    error.ex
    limits.ex
    preflight.ex
    snapshot.ex
    snapshotter.ex
    span.ex
    translation.ex
    translator.ex
    rebase.ex
    rebase/
      adapter.ex
      array.ex
      map.ex
      text.ex
      xml.ex

test/
  fixtures/
    snapshot_v2/
    translation_v1/
    rebase_v1/
  bridge_test.exs
  crossing_test.exs
  crossing_property_test.exs
  derivation_property_test.exs
  preflight_test.exs
  snapshotter_test.exs
  translator_test.exs
  delete_set_translation_test.exs
  incremental_translation_test.exs
  rebase_test.exs
~~~

The package SHOULD use no runtime process, registry process, application
supervisor, storage adapter, or network client. Its core is pure data
transformation.

## 30. Acceptance criteria for 0.1

The extraction is complete when:

1. `yepochs` compiles and tests without any Commonplace dependency;
2. snapshotter version 2 reproduces the accepted experimental fixtures;
3. derivations use validated normalized clock spans;
4. bridge lookup, inversion, delta extension, and composition satisfy the
   algebraic tests;
5. strict translation handles origins, right origins, ID parents, and delete
   sets;
6. strict translation preserves owned identities or reports a collision;
7. missing anchors and operation targets are distinguished;
8. the high-level crossing API accepts supported edits from either endpoint;
9. missing mappings and identity collisions select re-authoring rather than
   failing a supported crossing;
10. translated, re-authored, and absorbed crossings return deterministic bridge
    deltas and receipts;
11. positional rebase reports its loss of identity and every correspondence it
    can prove;
12. all successful operations are deterministic for pinned algorithm and codec
   versions;
13. resource limits reject hostile inputs without partial output;
14. the Commonplace monorepo consumes the package for its pure Yepoch logic;
    and
15. commit DAG, policy, signing, storage, and process concerns remain outside
    the package.

## 31. Deferred work

The following are intentionally deferred beyond 0.1:

- tombstone-preserving snapshots and bridges;
- multi-source derivations produced by merge snapshots;
- automatic bridge-graph search;
- heuristic repair of missing anchors;
- semantic merge beyond the explicit positional adapters;
- distributed reconciliation of bridge deltas accepted independently at
  multiple replicas;
- garbage collection of bridges and snapshots;
- cryptographic proofs of derivation correctness; and
- transport or synchronization protocols.

These additions may extend the model, but none may weaken the rule that a raw
Yjs coordinate is interpreted only within a known Yepoch.

## 32. Summary

The conceptual core of `yepochs` is small:

~~~text
Yepoch
  = meaning assigned to Yjs coordinates

snapshot
  = same observable value, new coordinates

derivation
  = directed provenance plus endpoint-free coordinate correspondence

bridge
  = evolving bidirectional compatibility between two Yepochs

crossing
  = make an edit from either endpoint applicable to the other

translation
  = fast path: preserve update-owned identities and rewrite external references

rebase
  = crossing fallback: re-author observable intent at the destination
~~~

That boundary lets Commonplace keep append-only history and Merkle policy in
their own libraries while giving Yjs epoch changes one precise, testable,
content-addressing-friendly implementation.
