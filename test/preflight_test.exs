defmodule Yepochs.PreflightTest do
  use ExUnit.Case, async: true

  alias Yepochs.Algorithm
  alias Yepochs.Bridge
  alias Yepochs.Derivation
  alias Yepochs.Error
  alias Yepochs.Preflight
  alias Yepochs.Span
  alias Yepochs.Test.Updates

  # Base document: client 100, clocks 0..7 ("abcdefgh").
  # Destination epoch re-authors that content as client 500, clocks 0..7.
  defp bridge(spans) do
    {:ok, d} = Derivation.new(spans)
    {:ok, b} = Bridge.attach(d, "origin-epoch", "derived-epoch", Algorithm.snapshot())
    b
  end

  defp span(lc, lk, rc, rk, len) do
    {:ok, s} =
      Span.new(left_client: lc, left_clock: lk, right_client: rc, right_clock: rk, length: len)

    s
  end

  defp full_bridge, do: bridge([span(100, 0, 500, 0, 8)])

  setup_all do
    %{base: Updates.base("abcdefgh", 100)}
  end

  describe "happy path" do
    test "translates every external anchor through the correspondence", %{base: base} do
      u = Updates.insert_delta(base, 200, 2, "XY")
      assert {:ok, %Preflight{} = p} = Preflight.run(u, full_bridge(), :left, [])

      assert p.direction == :left
      assert p.owned == [{200, 0, 2}]
      # The inserted run anchors on base characters, which live at client 500
      # in the destination.
      assert map_size(p.anchors) > 0
      assert Enum.all?(p.anchors, fn {{c, _}, {dc, _}} -> c == 100 and dc == 500 end)
    end

    test "preserves the offset when mapping into the middle of a span", %{base: base} do
      u = Updates.insert_delta(base, 200, 5, "XY")
      {:ok, p} = Preflight.run(u, full_bridge(), :left, [])

      for {{100, k}, {500, dk}} <- p.anchors, do: assert(dk == k)
    end

    test "translates delete ranges into destination coordinates", %{base: base} do
      u = Updates.delete_delta(base, 200, 2, 3)
      {:ok, p} = Preflight.run(u, full_bridge(), :left, [])

      assert p.deletes == [{500, 2, 3}]
    end

    test "SPLITS a delete range whose destination mapping is non-contiguous", %{base: base} do
      # Spec §28.2 fixture 3. Clocks 2,3 map into client 500; clock 4 maps into
      # client 900. One source range must become two destination ranges.
      split = bridge([span(100, 0, 500, 0, 4), span(100, 4, 900, 0, 4)])
      u = Updates.delete_delta(base, 200, 2, 3)

      {:ok, p} = Preflight.run(u, split, :left, [])
      assert p.deletes == [{500, 2, 2}, {900, 0, 1}]
    end

    test "SPLITS on a gap within ONE destination client, not just across clients", %{base: base} do
      # The sharper case: all three clocks land on client 500, but 3 and 4 land
      # after a gap. Merging on client identity alone would silently produce one
      # range covering clocks the source never deleted.
      gapped =
        bridge([
          span(100, 2, 500, 2, 1),
          span(100, 3, 500, 9, 1),
          span(100, 4, 500, 10, 1)
        ])

      u = Updates.delete_delta(base, 200, 2, 3)
      {:ok, p} = Preflight.run(u, gapped, :left, [])

      assert p.deletes == [{500, 2, 1}, {500, 9, 2}],
             "a non-contiguous mapping must split the interval, got #{inspect(p.deletes)}"
    end

    test "records the strict-translation algorithm", %{base: base} do
      {:ok, p} = Preflight.run(Updates.full(base), full_bridge(), :left, [])
      assert p.algorithm == Algorithm.translate()
    end

    test "works in the RIGHT-to-left direction too, because bridges are bilateral" do
      # An update authored in the derived epoch, crossing back to the origin.
      derived_base = Updates.base("abcdefgh", 500)
      u = Updates.delete_delta(derived_base, 600, 2, 3)

      assert {:ok, p} = Preflight.run(u, full_bridge(), :right, [])
      assert p.direction == :right
      assert p.deletes == [{100, 2, 3}]
    end
  end

  describe "missing coverage — these are strict-path diagnostics, not crossing failures" do
    test "an uncovered insertion anchor fails with :missing_anchor", %{base: base} do
      u = Updates.insert_delta(base, 200, 2, "XY")
      partial = bridge([span(100, 5, 500, 5, 3)])

      assert {:error, %Error{code: :missing_anchor} = err} = Preflight.run(u, partial, :left, [])
      assert err.phase == :preflight
      assert err.refs != []
    end

    test "the error identifies the field and the source reference", %{base: base} do
      u = Updates.insert_delta(base, 200, 2, "XY")
      partial = bridge([span(100, 5, 500, 5, 3)])

      {:error, err} = Preflight.run(u, partial, :left, [])
      assert [%{field: field, ref: {100, _}} | _] = err.details.failures
      assert field in [:origin, :right_origin]
    end

    test "an uncovered delete target fails with :missing_operation_target", %{base: base} do
      u = Updates.delete_delta(base, 200, 2, 3)
      partial = bridge([span(100, 0, 500, 0, 2)])

      assert {:error, %Error{code: :missing_operation_target}} = Preflight.run(u, partial, :left, [])
    end

    test "a PARTIALLY covered delete range still fails — no silent discard", %{base: base} do
      # Deletes clocks 2,3,4; the bridge covers only 2 and 3.
      u = Updates.delete_delta(base, 200, 2, 3)
      partial = bridge([span(100, 0, 500, 0, 4)])

      assert {:error, %Error{code: :missing_operation_target} = err} =
               Preflight.run(u, partial, :left, [])

      assert Enum.any?(err.details.failures, fn f -> f.ref == {100, 4} end)
    end

    test "reports EVERY failure, in deterministic order", %{base: base} do
      # An update that both inserts and deletes has anchors AND delete targets,
      # so an empty bridge fails it in more than one place at once.
      r = Yelixer.Types.Text.insert(Updates.replica(base, 200), "t", 2, "XY")
      r = Yelixer.Types.Text.delete(r, "t", 6, 2)
      u = Updates.delta(r, base)

      {:error, err} = Preflight.run(u, bridge([]), :left, [])

      assert length(err.details.failures) > 1
      assert Enum.map(err.details.failures, & &1.field) |> Enum.uniq() |> length() > 1
      assert err.details.failures == Enum.sort_by(err.details.failures, &{&1.field, &1.ref})
    end

    test "is all-or-nothing: no partial plan accompanies an error", %{base: base} do
      u = Updates.insert_delta(base, 200, 2, "XY")
      assert {:error, %Error{}} = Preflight.run(u, bridge([]), :left, [])
    end
  end

  describe "identity collision — §15.5" do
    test "rejects an owned interval that means something else at the destination", %{base: base} do
      u = Updates.insert_delta(base, 200, 2, "XY")
      # The destination side already assigns client 200, clocks 0..7 to base
      # content — so the update's own IDs cannot be preserved there.
      colliding = bridge([span(100, 0, 200, 0, 8)])

      assert {:error, %Error{code: :target_identity_collision} = err} =
               Preflight.run(u, colliding, :left, [])

      assert err.phase == :preflight
    end

    test "allows the overlap when the existing correspondence IS the identity mapping",
         %{base: base} do
      u = Updates.insert_delta(base, 200, 2, "XY")

      # The destination side DOES cover the update's own IDs (200:0..7) -- but it
      # maps them from 200:0..7, i.e. to themselves. That is not a collision.
      identity = bridge([span(100, 0, 500, 0, 8), span(200, 0, 200, 0, 8)])

      assert {:ok, _} = Preflight.run(u, identity, :left, []),
             "an identity correspondence over an owned interval must be permitted"
    end

    test "the identity exception is narrow: the SAME destination coords mapped from elsewhere collide",
         %{base: base} do
      u = Updates.insert_delta(base, 200, 2, "XY")
      # Same destination coordinates as the test above, but reached from 100.
      nonidentity = bridge([span(100, 0, 200, 0, 8)])

      assert {:error, %Error{code: :target_identity_collision}} =
               Preflight.run(u, nonidentity, :left, [])
    end

    test "rejects overlap with a caller-supplied destination inventory", %{base: base} do
      u = Updates.insert_delta(base, 200, 2, "XY")

      assert {:error, %Error{code: :target_identity_collision}} =
               Preflight.run(u, full_bridge(), :left, destination_intervals: [{200, 0, 4}])
    end

    test "accepts a destination inventory that does not overlap", %{base: base} do
      u = Updates.insert_delta(base, 200, 2, "XY")

      assert {:ok, _} =
               Preflight.run(u, full_bridge(), :left, destination_intervals: [{999, 0, 4}])
    end
  end

  describe "unsupported identity-bearing content — §15.9" do
    test "refuses a content variant it cannot prove safe to rewrite", %{base: base} do
      {:ok, decoded} = Yepochs.Update.decode(Updates.full(base))

      exotic = %Yelixer.Item{
        id: %Yelixer.ID{client: 700, clock: 0},
        origin: nil,
        right_origin: nil,
        content: {:some_future_variant, %{}},
        parent: {:named, "t"},
        parent_sub: nil,
        deleted: false,
        length: 1
      }

      tainted = %{decoded | items: [exotic | decoded.items]}

      assert {:error, %Error{code: :unsupported_translation_feature} = err} =
               Preflight.run(tainted, full_bridge(), :left, [])

      assert err.details.features == [:some_future_variant]
    end

    test "accepts an update whose content variants are all understood", %{base: base} do
      {:ok, decoded} = Yepochs.Update.decode(Updates.full(base))
      assert {:ok, _} = Preflight.run(decoded, full_bridge(), :left, [])
    end
  end

  describe "input validation" do
    test "rejects a malformed update" do
      assert {:error, %Error{code: :malformed_update}} =
               Preflight.run(<<0xFF, 0xFF, 0xFF>>, full_bridge(), :left, [])
    end

    test "rejects an invalid direction", %{base: base} do
      assert {:error, %Error{}} = Preflight.run(Updates.full(base), full_bridge(), :sideways, [])
    end
  end
end
