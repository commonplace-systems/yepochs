defmodule Yepochs.InvariantsTest do
  @moduledoc """
  Spec r2 §7's thirteen core invariants, numbered as the spec numbers them, so
  coverage is auditable rather than remembered.

  Most are enforced by a module's own suite and are cross-referenced here. The
  two asserted directly are the ones held **structurally** — and a structural
  guarantee is exactly the kind that goes unverified, because there is no
  obvious place for its test to live.
  """
  use ExUnit.Case, async: true

  alias Yepochs.Bridge
  alias Yepochs.Derivation
  alias Yepochs.Span

  describe "invariant 1 — a raw item reference is never interpreted without a known Yepoch" do
    test "no coordinate lookup exists that does not take a Bridge" do
      # The enforcement is the API's shape: `Derivation` holds spans but exposes
      # NO lookup, so a bare correspondence cannot resolve a coordinate. Only
      # `Bridge` can, and a Bridge cannot exist without two validated epoch
      # references. If a lookup were ever added to Derivation, this fails.
      derivation_exports = Derivation.__info__(:functions) |> Keyword.keys() |> Enum.uniq()

      for name <- [:left_ref, :right_ref, :lookup, :resolve, :source_ref, :target_ref] do
        refute name in derivation_exports,
               "Derivation exposes #{name}/n — a coordinate could then be interpreted " <>
                 "without a Yepoch, breaking invariant 1"
      end

      bridge_exports = Bridge.__info__(:functions) |> Keyword.keys() |> Enum.uniq()
      assert :left_ref in bridge_exports
      assert :right_ref in bridge_exports
    end

    test "a Bridge cannot be built without both epoch references" do
      {:ok, d} = Derivation.new([])

      for {l, r} <- [{"", "b"}, {"a", ""}, {"a", "a"}] do
        assert {:error, _} = Bridge.attach(d, l, r, Yepochs.Algorithm.snapshot()),
               "attach accepted #{inspect({l, r})} as endpoints"
      end
    end

    test "the Bridge struct always carries both epochs" do
      {:ok, d} = Derivation.new([])
      {:ok, b} = Bridge.attach(d, "left", "right", Yepochs.Algorithm.snapshot())

      assert b.left_epoch == "left"
      assert b.right_epoch == "right"
      assert Enum.all?([:left_epoch, :right_epoch], &(&1 in Map.keys(b)))
    end
  end

  describe "invariant 3 — every span pairs EQUAL-LENGTH intervals at the two endpoints" do
    test "the struct cannot express unequal lengths" do
      # One `length` field governs both sides, so the invariant holds by
      # construction. Asserted anyway: if the struct ever grew a second length,
      # a whole class of silent mis-mapping becomes expressible.
      fields =
        %Span{
          left_client: 0,
          left_clock: 0,
          right_client: 0,
          right_clock: 0,
          length: 1
        }
        |> Map.from_struct()
        |> Map.keys()
        |> Enum.sort()

      assert fields == [:left_client, :left_clock, :length, :right_client, :right_clock]
    end

    test "left and right intervals are the same width for any valid span" do
      {:ok, s} =
        Span.new(left_client: 9, left_clock: 21, right_client: 17, right_clock: 4, length: 5)

      assert Span.left_end(s) - s.left_clock == Span.right_end(s) - s.right_clock
      assert Span.left_end(s) - s.left_clock == s.length
    end

    test "a span with zero or negative length cannot be constructed" do
      for len <- [0, -1, -100] do
        assert {:error, _} =
                 Span.new(
                   left_client: 1,
                   left_clock: 0,
                   right_client: 2,
                   right_clock: 0,
                   length: len
                 )
      end
    end
  end

  # Invariants 2, 4-13 are enforced and tested in the suites that own them:
  #
  #   2  snapshotter_test        observable equivalence; new identity space
  #   4  derivation_test         overlap rejection on both sides, + property
  #   5  crossing_property_test  every valid edit crosses (both modes generated)
  #   6  derivation_property_test  reorienting preserves capability
  #   7  translator_test         owned identities preserved
  #   8  translator_test         no source coordinate leaks; no partial output
  #   9  bridge_test             :unmapped rather than numeric fallback
  #   10 crossing_test           strict failure selects re-authoring
  #   11 crossing_property_test  every crossing returns a delta and receipt
  #   12 crossing_property_test  monotonic evolution, on a bridge with history
  #   13 crossing/translator/snapshotter  determinism under repetition
end
