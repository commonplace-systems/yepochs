# Yepochs

**Version:** 0.1-draft  
**Status:** Proposed extraction specification  
**Date:** 2026-08-22  
**Library:** `yepochs`  
**Implementation substrate:** Yelixer

## 1. Decision

`yepochs` is a small, Commonplace-independent Elixir library for moving Yjs
changes between histories that represent compatible document content but use
different internal Yjs identities.

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
- a **bridge** attaches a derivation to its source and target Yepochs;
- strict translation rewrites every external identity reference in an update;
  and
- positional rebase is an explicit fallback when identity-preserving
  translation is impossible.

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
- derivation spans and bridges;
- bridge validation, inversion, extension, and composition;
- strict translation of Yjs updates across one bridge or a bridge path;
- translation of insertion anchors, ID-valued parents, and delete sets;
- preservation of identities authored by the update being translated;
- deterministic preflight errors;
- an explicit positional-rebase fallback;
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
creating a target representation from a source representation.

Each span maps target coordinates back to the source coordinates from which
they were derived. The stored direction is therefore:

~~~text
target/new -> source/old
~~~

This direction is natural during snapshot construction and records provenance.
Translation of an old update into the new Yepoch uses the validated inverse.

### 6.6 Bridge

A **bridge** associates a derivation with a source Yepoch and target Yepoch:

~~~text
source Yepoch --snapshot/derivation--> target Yepoch
~~~

Its stored spans still point from target coordinates back to source
coordinates.

Keeping the derivation endpoint-free avoids a content-addressing cycle. A
caller may:

1. create a snapshot and derivation;
2. place both in a Merkle object;
3. calculate that object’s ID; and then
4. attach the resulting target Yepoch reference to form a bridge.

### 6.7 Owned identity

An **owned identity** is an item coordinate defined by an item struct inside the
update currently being translated.

Strict translation preserves owned identities. References among items in the
same translated update therefore remain valid without bridge lookup.

### 6.8 External reference

An **external reference** is an identity-bearing coordinate used by an update
but not defined by that update.

External references MUST be translated through a bridge. They MUST NOT be
passed through merely because their numeric client and clock values look valid
in the target.

### 6.9 Positional rebase

A **positional rebase** recovers the observable effect of an edit by comparing
the source state before and after that edit and re-authoring the effect against
a target state.

It is a fallback, not identity-preserving translation. It creates new item
identities and does not preserve the original Yjs authorship coordinates.

## 7. Core invariants

A conforming implementation MUST preserve these invariants:

1. A raw item reference is never interpreted without a known Yepoch.
2. Snapshotting preserves supported observable Yjs state but creates a new
   identity space.
3. Every derivation span maps equal-length target and source intervals.
4. A valid derivation is a partial bijection: neither side contains overlapping
   mapped intervals.
5. Strict translation preserves every item identity authored by the translated
   update.
6. Strict translation rewrites every external identity reference or fails.
7. Missing mappings are never guessed from visible position or raw numeric
   equality.
8. Preflight and translation are all-or-nothing.
9. The same supported inputs, options, and algorithm versions produce the same
   bytes or the same error.
10. Positional rebase is invoked only through an explicit API or caller policy.

## 8. Data model

### 8.1 Span

The logical Elixir representation is:

~~~elixir
defmodule Yepochs.Span do
  @enforce_keys [
    :target_client,
    :target_clock,
    :source_client,
    :source_clock,
    :length
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          target_client: non_neg_integer(),
          target_clock: non_neg_integer(),
          source_client: non_neg_integer(),
          source_clock: non_neg_integer(),
          length: pos_integer()
        }
end
~~~

For offset `n` where `0 <= n < length`, the span means:

~~~text
{target_client, target_clock + n}
    derives from
{source_client, source_clock + n}
~~~

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

### 8.3 Bridge

~~~elixir
defmodule Yepochs.Bridge do
  @enforce_keys [
    :format_version,
    :source_epoch,
    :target_epoch,
    :derivation,
    :producer
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          format_version: pos_integer(),
          source_epoch: String.t(),
          target_epoch: String.t(),
          derivation: Yepochs.Derivation.t(),
          producer: Yepochs.Algorithm.t()
        }
end
~~~

`producer` identifies the algorithm that established the correspondence. It is
evidence metadata; bridge composition is governed by span semantics rather
than by requiring all source bridges to share one producer.

### 8.4 Algorithm

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
| `yepochs.translate` | 1 | Strict identity translation. |
| `yepochs.rebase` | 1 | Positional fallback. |
| `yepochs.compose` | 1 | Composition of compatible bridge mappings. |
| `yepochs.extend` | 1 | Addition of admitted carried-identity mappings. |

Algorithm versions are durable semantic identifiers. They are independent of
the Hex package version.

### 8.5 Portable wire value

The library MUST expose `to_map/1` and `from_map/1` for derivations and bridges.
The representation MUST use string keys, safe non-negative integers, and a
canonically sorted span list. It MUST contain no Elixir module names or atoms
derived from input.

A bridge version 1 map is equivalent to:

~~~json
{
  "version": 1,
  "source_epoch": "source-epoch-reference",
  "target_epoch": "target-epoch-reference",
  "producer": {
    "id": "yepochs.snapshot",
    "version": 2
  },
  "spans": [
    {
      "target_client": 17,
      "target_clock": 4,
      "source_client": 9,
      "source_clock": 21,
      "length": 5
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
- target intervals do not overlap;
- source intervals do not overlap; and
- spans are a partial bijection at every mapped clock.

`YEpochs.Derivation.normalize/1` MUST:

1. validate the input;
2. sort spans by target client, target clock, source client, and source clock;
3. coalesce adjacent spans when both their target intervals and source
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

The derivation MUST cover every target item clock emitted for observable source
content and its corresponding source clock.

Version 0.1 snapshots do not promise mappings for source tombstones or content
that is not retained in the target snapshot. A later edit that refers to such
content may therefore fail strict translation and require positional rebase.

## 11. Attaching a bridge

After a caller has identified the target Yepoch, it constructs a bridge:

~~~elixir
@spec attach(
        Yepochs.Derivation.t(),
        source_epoch :: String.t(),
        target_epoch :: String.t(),
        producer :: Yepochs.Algorithm.t()
      ) :: {:ok, Yepochs.Bridge.t()} | {:error, Yepochs.Error.t()}
~~~

The function MUST validate both epoch references, validate and normalize the
derivation, and reject equal endpoints.

Attaching endpoint labels does not change any span.

## 12. Bridge lookup

The API MUST make direction explicit:

~~~elixir
# Stored provenance direction: target -> source
@spec source_ref(Bridge.t(), item_ref()) ::
        {:ok, item_ref()} | :unmapped

# Translation direction: source -> target
@spec target_ref(Bridge.t(), item_ref()) ::
        {:ok, item_ref()} | :unmapped
~~~

Both operations MUST support references to any clock inside a span, not only
the first clock of an encoded Yjs item.

Lookup MUST NOT fall back to the same numeric coordinate when no span matches.

## 13. Bridge inversion

~~~elixir
@spec invert(Bridge.t()) ::
        {:ok, Bridge.t()} | {:error, Yepochs.Error.t()}
~~~

Inversion swaps:

- source and target epoch references; and
- the target and source coordinates in every span.

It then normalizes the result. Inversion MUST fail if the input is not a valid
partial bijection.

Endpoint-free derivations MAY be inverted by swapping source and target
coordinates in the same way. Bridge inversion additionally swaps the endpoint
references.

For every valid bridge `b`:

~~~text
invert(invert(b)) == normalize(b)
~~~

## 14. Bridge composition

Given:

~~~text
A --ab--> B --bc--> C
~~~

where `ab.source_epoch == A`, `ab.target_epoch == B`,
`bc.source_epoch == B`, and `bc.target_epoch == C`, composition produces:

~~~text
A --ac--> C
~~~

Its stored mapping is calculated in provenance direction:

~~~text
C -> B -> A
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
6. use an explicit composition producer identifier rather than pretending one
   source snapshotter directly produced the composed mapping.

Composition is associative at the logical mapping level. After normalization:

~~~text
compose([compose([ab, bc]), cd])
    ==
compose([ab, compose([bc, cd])])
~~~

for every compatible path.

The resulting mapping may be smaller than either input because each bridge is
partial. Missing coverage is reported later by preflight; composition MUST NOT
invent it.

## 15. Strict update translation

### 15.1 Contract

Strict translation has the conceptual API:

~~~elixir
@spec translate(binary(), Bridge.t(), keyword()) ::
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

The input update is understood in `bridge.source_epoch`. The result is intended
for `bridge.target_epoch`.

`translate/3` MUST run preflight first and MUST NOT emit a partial update.

### 15.2 Owned item identities

The translator first inventories every item interval defined by the input
update. Those intervals are owned by the update.

The translator MUST preserve:

- each owned item’s client ID;
- its starting clock;
- its length; and
- references from one owned interval to another owned interval.

The result’s `carried` derivation contains identity spans for owned intervals:

~~~text
target coordinate == source coordinate
~~~

The caller MUST NOT extend a durable bridge with `carried` until the translated
update has been accepted by the target document.

### 15.3 Identity collision

Preserving an owned identity is impossible if that raw coordinate already
means a different item in the target Yepoch.

Preflight MUST reject an owned interval that overlaps a target interval in the
bridge unless the existing correspondence is the same identity mapping. If the
caller supplies a target document or target interval inventory, preflight MUST
also reject overlap with any occupied target coordinate not represented by the
bridge.

The error code is `:target_identity_collision`. Positional rebase is the normal
fallback because it can allocate a new caller-supplied author identity.

### 15.4 Insertion anchors

For every item, the translator MUST examine:

- `origin`; and
- `right_origin`.

For each non-null reference:

1. if the reference is owned by the input update, leave it unchanged;
2. otherwise, translate it from source to target through the bridge; and
3. if no mapping exists, fail with `:missing_anchor`.

The error MUST identify the field and source reference.

### 15.5 Parent references

A named root parent is not an item coordinate and MUST remain unchanged.

An ID-valued parent MUST be handled as follows:

1. if it refers to an interval owned by the input update, leave it unchanged;
2. otherwise, translate it through the bridge; and
3. if no mapping exists, fail with `:missing_operation_target`.

### 15.6 Delete sets

Every delete-set interval MUST be translated. Reusing the source delete set
unchanged is non-conforming, even if insertion anchors were translated.

For each clock in a source delete interval, the translator MUST prove that it
is either:

- inside an interval owned by the input update, in which case the coordinate is
  preserved; or
- covered by the bridge’s source side, in which case it is mapped to the target
  coordinate.

The implementation SHOULD translate intervals by range arithmetic rather than
expanding them one clock at a time. It MUST split an interval when mappings are
non-contiguous, then normalize adjacent output delete ranges using Yjs ordering
rules.

If any part of a delete interval is uncovered, translation fails with
`:missing_operation_target`. Version 0.1 does not silently absorb deletion of a
source item omitted from the target snapshot; caller policy may use positional
rebase to determine whether the edit is already satisfied.

### 15.7 Unknown identity-bearing fields

The translator MUST understand every identity-bearing field emitted by the
pinned Yelixer/Yjs update version.

If a decoded struct or content variant may contain identity data that the
translator does not understand, translation MUST fail with
`:unsupported_update_feature`. It MUST NOT copy the field through unchanged.

### 15.8 Encoding

The translated update MUST be encoded deterministically. Semantically
equivalent but byte-different output caused by unordered map traversal is not
permitted within one translator algorithm version.

## 16. Translation preflight

~~~elixir
@spec preflight(binary(), Bridge.t(), keyword()) ::
        {:ok, Yepochs.Preflight.t()}
        | {:error, Yepochs.Error.t()}
~~~

Preflight MUST perform every validation necessary for translation without
returning partially translated bytes. It MUST at least:

1. validate the bridge;
2. decode and validate the update;
3. inventory owned item intervals;
4. detect target identity collisions visible from supplied information;
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
| `:target_identity_collision` | An update-owned identity already has another meaning in the target. |

This distinction is diagnostic. It does not authorize preflight to guess a
different anchor or target.

## 17. Incremental translation and bridge extension

Translation of one closed batch is simplest: all post-fork source edits are
combined into one update, so references among those edits are owned by that
update.

For incremental translation, a later source update may refer to an earlier
translated item. After the earlier update is accepted, the caller may extend
the bridge with its `carried` identity spans:

~~~elixir
@spec extend(Bridge.t(), Derivation.t()) ::
        {:ok, Bridge.t()} | {:error, Yepochs.Error.t()}
~~~

Extension MUST:

- preserve the bridge endpoints;
- validate the new spans as target-to-source mappings;
- reject an overlap that assigns either side two meanings;
- accept an exact duplicate mapping idempotently; and
- normalize the result.

This operation is an admission record, not merely an optimization. The caller
MUST persist the extension, or reconstruct it from accepted translated commits,
before translating a later dependent update.

If the caller does not maintain bridge extensions, it MUST combine the complete
dependent source delta into one update before translating it.

## 18. Translating across a path

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

## 19. Positional rebase fallback

### 19.1 Contract

The fallback API is separate and explicit:

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

- `before` is the source document before the rejected or untranslatable edit;
- `edited` is `before` plus that edit;
- `target` is the state onto which its observable effect should be reapplied;
  and
- options include an explicit target author/client identity.

The result contains an update authored against `target` and an outcome such as
`:applied` or `:absorbed`.

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

If the observable effect is already true in `target`, rebase MAY return
`:absorbed` with an empty update.

### 19.3 Explicit loss of identity

Rebase does not preserve:

- original item identities;
- byte identity of the original update;
- original Yjs client authorship; or
- operation-level intent beyond the supported observable diff.

It MUST NOT be invoked silently by `translate/3` or `translate_path/3`.

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

Any change that can alter accepted input, rejected input, output bytes, mapping
semantics, or rebase results requires a new algorithm version.

This includes changes to:

- snapshot traversal order;
- snapshot client-ID selection;
- Yjs struct construction or consolidation;
- update encoding;
- supported shared types;
- reference classification;
- delete-set translation;
- normalization; or
- positional diff and patch rules.

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
| `:invalid_epoch_ref` | An endpoint reference is empty or not canonical for the selected wire profile. |
| `:invalid_derivation` | A span is malformed, overlapping, overflowing, or otherwise not a partial bijection. |
| `:bridge_endpoint_mismatch` | A bridge path is disconnected or supplied in the wrong order. |
| `:malformed_update` | Yelixer cannot decode or structurally validate the update. |
| `:unsupported_content` | Snapshotting cannot faithfully preserve source content. |
| `:unsupported_update_feature` | Translation encountered an unknown identity-bearing feature. |
| `:missing_anchor` | An external origin or right origin lacks a mapping. |
| `:missing_operation_target` | An external parent or delete coordinate lacks a mapping. |
| `:target_identity_collision` | An owned source identity conflicts with the target namespace. |
| `:incompatible_algorithm` | A requested durable algorithm version is unavailable. |
| `:limit_exceeded` | A configured deterministic resource limit was exceeded. |
| `:invalid_rebase_input` | Before, edited, and target inputs do not satisfy the selected adapter contract. |
| `:rebase_conflict` | The selected positional adapter cannot deterministically apply the observable change. |

Errors MUST contain data, not preformatted English as their only diagnostic.
Reference lists and paths MUST be deterministically ordered.

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

  @spec preflight(binary(), Bridge.t(), keyword()) ::
          {:ok, Preflight.t()} | {:error, Error.t()}

  @spec translate(binary(), Bridge.t(), keyword()) ::
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

  @spec source_ref(t(), item_ref()) :: {:ok, item_ref()} | :unmapped
  @spec target_ref(t(), item_ref()) :: {:ok, item_ref()} | :unmapped
  @spec invert(t()) :: {:ok, t()} | {:error, Error.t()}
  @spec compose([t()]) :: {:ok, t()} | {:error, Error.t()}
  @spec extend(t(), Derivation.t()) :: {:ok, t()} | {:error, Error.t()}
  @spec to_map(t()) :: map()
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
end
~~~

The exact module split may change before 0.1, but the semantic separation among
snapshot, derivation, bridge, preflight, strict translation, and rebase is
normative.

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
- the choice among strict translation, positional rebase, and merge snapshot;
- target admission and bridge extension after admission;
- author and system signatures; and
- construction of translated or merge commits.

It calls `yepochs` for pure transformations and algebra.

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
| Pure orchestration in `Commonplace.Store.Translator` | `YEpochs`; commit loading, emission, and signing remain in Commonplace. |
| `Commonplace.Document.Rebase` and its Y.Text/Y.Map/Y.Array/Y.XML helpers | `YEpochs.Rebase` and adapters, if they can be made Commonplace-independent. |
| `Commonplace.Store.CrossEpochMerge` | Remains in `commonplace-merkle-crdt`; it calls bridge composition and translation. |
| `Commonplace.Store.Merger` | Remains in `commonplace-merkle-crdt`; it owns strategy policy. |
| `Commonplace.Store.SnapshotAncestry` | Remains in `commonplace-merkle-crdt`; it owns DAG traversal. |
| Node identity and commit signatures | Remain outside `yepochs`. |

The extraction MUST preserve existing successful fixtures before behavior is
changed.

## 27. Required corrections during extraction

Version 0.1 is not a namespace-only refactor. It makes three deliberate design
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
- positional fallback; and
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
15. application of translated output to the target producing the expected
    observable state.

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
4. bridge lookup, inversion, extension, and composition satisfy the algebraic
   tests;
5. strict translation handles origins, right origins, ID parents, and delete
   sets;
6. strict translation preserves owned identities or reports a collision;
7. missing anchors and operation targets are distinguished;
8. positional rebase, if included in 0.1, is explicit and reports its loss of
   identity;
9. all successful operations are deterministic for pinned algorithm and codec
   versions;
10. resource limits reject hostile inputs without partial output;
11. the Commonplace monorepo consumes the package for its pure Yepoch logic;
    and
12. commit DAG, policy, signing, storage, and process concerns remain outside
    the package.

## 31. Deferred work

The following are intentionally deferred beyond 0.1:

- tombstone-preserving snapshots and bridges;
- multi-source derivations produced by merge snapshots;
- automatic bridge-graph search;
- heuristic repair of missing anchors;
- semantic merge beyond the explicit positional adapters;
- streaming translation without a persisted carried-identity record;
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
  = endpoint-free target/new -> source/old clock spans

bridge
  = derivation + source and target Yepoch references

translation
  = preserve update-owned identities; rewrite every external reference

rebase
  = explicitly re-author observable intent when translation cannot prove it
~~~

That boundary lets Commonplace keep append-only history and Merkle policy in
their own libraries while giving Yjs epoch changes one precise, testable,
content-addressing-friendly implementation.
