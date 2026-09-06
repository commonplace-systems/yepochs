# Standalone repaired-codec closure — 2026-09-06

Yepochs now declares and locks Yelixer
`59b04eb1ba4c03d003e91f8867db3bd90a517bf5` itself. An application override is
not required to obtain the repaired incoming UTF-16 clock behavior. This branch
starts at `2d8c6282203c28dd969cc7af76176752bc0e2f4d`; only the codec pin and
documentation/evidence change. Yepochs production `lib/` is unchanged.

The old declaration and lock selected `bcaec6a3520c59464bab87daaab7e4f76546c9c5`.
The new manifest, lock and installed Git checkout agree at `59b04eb`. The codec
and Yepochs were force-compiled before validation; compiled module hashes and
timestamps are in the [standalone packet](compatibility-evidence/standalone-inbound.json).

The bounded affected selection executes **70 tests, zero failures, no exclusions,
rc 0**: `unicode_runtime_test.exs`, `utf16_unit_corpus_test.exs`,
`snapshotter_test.exs`, and `translator_test.exs`. It covers real Yjs 13.6.32
Unicode reauthoring/crossing, UTF-16 intervals, snapshots and translation.
Formatting and warnings-as-errors compilation pass. The oracle helper came from
the verified Yelixer checkout; the production codec loads from this repository's
own fetched dependency. No local path dependency or overriding parent consumer
participates in this selection.

Per the corrected dispatch, this is affected validation, not a repeated full
suite or Dialyzer run. The earlier 656-test/12-property full check remains evidence
at its original `bcaec6a` codec pin. No standalone full result at `59b04eb` is
claimed. Original incremental-byte and actual durable consumer evidence is retained
in Yelixer's `docs/unicode-inbound-repair.md`; the integration owner must execute
the repaired boundary arm explicitly when validating the combined application.

This published branch supplies a coherent candidate dependency, not an adoption
or landing warrant. The accepted own-history semantic break and four documented
codec content limits remain as described in the earlier reports. No migration,
live-store operation or deployment is performed here.
