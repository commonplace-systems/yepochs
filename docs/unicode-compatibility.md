# UTF-16 candidate

This branch evaluates Yelixer `bcaec6a3520c59464bab87daaab7e4f76546c9c5`.
It is a compatibility candidate, not a recommendation to upgrade saved documents.

The old pin ran 56 focused tests with 19 failures. Updating only Yelixer reduced
that to six failures, all in positional reauthoring: the fallback measured its
prefix and removed text in graphemes. It also sliced a scalar prefix using a
grapheme count, so removing only a combining mark could be refused incorrectly.
The repair converts text API positions to UTF-16 units and matches the exact
prefix bytes. The 96 focused conformance, crossing, adapter, and Unicode tests
then passed with no skips.

The new tests send foreign Yjs 13.6.32 updates through snapshots, strict crossings
in both directions, bridge extension, reauthoring, serialization and reload, and
decode the resulting updates in real Yjs. The twelve interval cases are reused
from the parked `wip/yepochs-repin-2026-08-27-boss` branch. Fixture JSON is now
parsed as JSON, including exact map equality and array order, rather than by
regular expressions that cannot decode escaped strings or nested values.

```
npm ci --prefix deps/yelixer/test/fixtures
mix test test/yjs_conformance_test.exs test/yjs_map_array_conformance_test.exs test/conformance_test.exs test/utf16_unit_corpus_test.exs test/unicode_runtime_test.exs test/crossing_test.exs test/rebase_adapters_test.exs
```

The test-only `COMPAT_YELIXER_HARNESS` override permits the same modern oracle
harness to run against the old pin; it does not replace the installed codec.
Normal candidate runs use the harness in the pinned Git dependency.

Adoption remains gated by saved-history interpretation and versioning. These
tests do not prove that metadata produced under a grapheme codec and the same
algorithm identifier can be reinterpreted under UTF-16. Snapshot version 3 and
rebase version 1 are unchanged here; do not silently deploy the changed coordinate
convention under existing durable interpretation tags. A versioned transition
must preserve old bytes, references and admitted commit IDs. Unicode XML crossing
and formatted-text positional parity are not established by this text/delete
matrix; the existing explicit refusal tests remain in place.
