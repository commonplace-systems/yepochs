defmodule Yepochs.DerivationPropertyTest do
  @moduledoc "Spec r2 §28.3 — algebraic properties over generated valid span sets."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Yepochs.Algorithm
  alias Yepochs.Bridge
  alias Yepochs.Bridge.Delta
  alias Yepochs.Crossing.Receipt
  alias Yepochs.Derivation
  alias Yepochs.Span

  # Clocks advance monotonically across the whole list and are never reused, so
  # the result is a partial bijection by construction regardless of which client
  # each span lands on. Ranges stay small so independently generated bridges
  # overlap often enough to actually exercise composition.
  defp span_list do
    gen all steps <-
              list_of(
                tuple({integer(0..3), integer(0..3), integer(1..4), integer(1..3), integer(1..3)}),
                max_length: 6
              ) do
      {spans, _, _} =
        Enum.reduce(steps, {[], 0, 0}, fn {lgap, rgap, len, lclient, rclient}, {acc, lc, rc} ->
          l = lc + lgap
          r = rc + rgap

          span = %Span{
            left_client: lclient,
            left_clock: l,
            right_client: rclient,
            right_clock: r,
            length: len
          }

          {[span | acc], l + len, r + len}
        end)

      Enum.reverse(spans)
    end
  end

  defp derivation do
    gen all spans <- span_list() do
      {:ok, d} = Derivation.new(spans)
      d
    end
  end

  defp bridge(left, right) do
    gen all d <- derivation() do
      {:ok, b} = Bridge.attach(d, left, right, Algorithm.snapshot())
      b
    end
  end

  defp left_refs(%Bridge{} = b) do
    Enum.flat_map(b.correspondence.spans, fn s ->
      for n <- 0..(s.length - 1), do: {s.left_client, s.left_clock + n}
    end)
  end

  property "normalization is idempotent" do
    check all d <- derivation() do
      {:ok, once} = Derivation.normalize(d)
      {:ok, twice} = Derivation.normalize(once)
      assert once == twice
    end
  end

  property "invert(invert(d)) == normalize(d)" do
    check all d <- derivation() do
      {:ok, n} = Derivation.normalize(d)
      {:ok, i} = Derivation.invert(d)
      {:ok, ii} = Derivation.invert(i)
      assert ii == n
    end
  end

  property "serialization round-trips without semantic change" do
    check all d <- derivation() do
      {:ok, n} = Derivation.normalize(d)
      assert {:ok, ^n} = Derivation.from_map(Derivation.to_map(n))
    end
  end

  property "reorienting swaps presentation, not capability (invariant 6)" do
    check all b <- bridge("A", "B") do
      {:ok, flipped} = Bridge.invert(b)

      for ref <- left_refs(b) do
        {:ok, right} = Bridge.right_ref(b, ref)
        # Every correspondence readable one way is readable the other way.
        assert Bridge.left_ref(b, right) == {:ok, ref}
        # And the reoriented bridge answers the same pairs with the roles swapped.
        assert Bridge.left_ref(flipped, ref) == {:ok, right}
        assert Bridge.right_ref(flipped, right) == {:ok, ref}
      end
    end
  end

  property "lookup across a composed bridge equals successive lookup across its inputs" do
    check all ab <- bridge("A", "B"), bc <- bridge("B", "C") do
      {:ok, ac} = Bridge.compose([ab, bc])

      for ref <- left_refs(ab) do
        expected =
          case Bridge.right_ref(ab, ref) do
            {:ok, mid} -> Bridge.right_ref(bc, mid)
            :unmapped -> :unmapped
          end

        assert Bridge.right_ref(ac, ref) == expected
      end
    end
  end

  property "composition is associative after normalization" do
    check all ab <- bridge("A", "B"), bc <- bridge("B", "C"), cd <- bridge("C", "D") do
      {:ok, li} = Bridge.compose([ab, bc])
      {:ok, left} = Bridge.compose([li, cd])
      {:ok, ri} = Bridge.compose([bc, cd])
      {:ok, right} = Bridge.compose([ab, ri])

      assert left.correspondence == right.correspondence
      assert left.left_epoch == right.left_epoch and left.right_epoch == right.right_epoch
    end
  end

  property "exact duplicate extension is idempotent in both correspondence and receipts" do
    check all b <- bridge("A", "B") do
      r = %Receipt{
        ref: "dup",
        from: :left,
        to: :right,
        mode: :translated,
        outcome: :applied,
        algorithm: Algorithm.cross()
      }

      d = %Delta{correspondence: b.correspondence, receipt: r}
      {:ok, once} = Bridge.extend(b, d)
      {:ok, twice} = Bridge.extend(once, d)

      assert once.correspondence == b.correspondence
      assert twice.correspondence == once.correspondence
      assert length(twice.receipts) == 1
    end
  end

  property "composition never maps a coordinate neither input path covered" do
    check all ab <- bridge("A", "B"), bc <- bridge("B", "C") do
      {:ok, ac} = Bridge.compose([ab, bc])

      for span <- ac.correspondence.spans, n <- 0..(span.length - 1) do
        ref = {span.left_client, span.left_clock + n}
        assert {:ok, mid} = Bridge.right_ref(ab, ref)
        assert {:ok, _} = Bridge.right_ref(bc, mid)
      end
    end
  end
end
