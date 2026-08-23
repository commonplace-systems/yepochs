# Conformance corpus — upstream Yjs v1

⭐ **These bytes were authored by upstream `yjs` 13.6.32 in Node, NOT by yelixer.** That is the
entire point: every other test in this repo builds its documents through yelixer, so yelixer's
encoder is on both sides of the comparison. These vectors put a *different implementation* on one
side.

Spec r2 §28.4: *"Pinned conformance vectors SHOULD be applicable by both Yelixer and the
corresponding official Yjs wire implementation. Cross-language fixtures MUST record the Yjs and
Yelixer versions that generated them."*

| provenance | value |
|---|---|
| generator | `yjs` 13.6.32 (Node) |
| copied from | `commonplace-systems/commonplace-merkle-crdt`, `conformance/yjs-v1/`, at `2a669a5` |
| copied on | 2026-08-23 |
| yelixer pinned here | `bc35a0e9` (see `mix.exs`) |

## Files per case

| file | meaning |
|---|---|
| `updates.hex` | one independently-authored Yjs update per line, lowercase hex |
| `expected_view.json` | the view **upstream** computes after applying them |
| `upstream.json` | generator, version, and whether upstream is path-independent on this case |
| `upstream_final.hex` | the bytes upstream encodes the assembled state to |
| `yelixer_final.hex` | the bytes yelixer encodes it to — **may legitimately differ**, see below |

⚠️ **Byte rules**, so "the fixture changed" and "an editor changed it" stay distinguishable: UTF-8,
no BOM, LF only, exactly one trailing LF. `updates.hex` lines match `^[0-9a-f]+$`.

## ⛔ What a green run here does NOT mean

It does not mean yelixer and upstream agree byte-for-byte. **Cases 003 and 004 encode differently
depending on arrival order under yelixer, while upstream encodes them identically** — measured
independently in `docs/design/0002-encode-determinism.md`. Yjs v1 is a serialisation format, not a
canonicalisation standard, so byte agreement is not guaranteed.

⇒ **What this corpus tests for `yepochs` is narrower and is the part that matters here:** that the
library's operations work on updates it did not author, decoded from the real wire format.

⛔ **And narrower still, per ruling 8.1:** these five cases are all **text and deletes**. They
establish text/delete interoperability and **MUST NOT be presented as evidence for maps, arrays, or
XML.** Before 0.1 claims cross-language support for those, at least one upstream-authored crossing
vector per claimed type has to be added here.
