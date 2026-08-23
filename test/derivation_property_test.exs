defmodule Yepochs.DerivationPropertyTest do
  @moduledoc """
  Spec §28.3 — algebraic property tests over generated valid span sets.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Yepochs.Algorithm
  alias Yepochs.Bridge
  alias Yepochs.Derivation
  alias Yepochs.Span

  # Clocks advance monotonically across the whole list and are never reused, so
  # the result is a partial bijection by construction regardless of which client
  # each span lands on. Ranges are kept small so that independently generated
  # bridges actually overlap often enough to exercise composition.
  defp span_list do
    gen all steps <-
              list_of(
                tuple({integer(0..3), integer(0..3), integer(1..4), integer(1..3),
                       integer(1..3)}),
                max_length: 6
              ) do
      {spans, _, _} =
        Enum.reduce(steps, {[], 0, 0}, fn {tgap, sgap, len, tclient, sclient},
                                          {acc, tclock, sclock} ->
          t = tclock + tgap
          s = sclock + sgap

          span = %Span{
            target_client: tclient,
            target_clock: t,
            source_client: sclient,
            source_clock: s,
            length: len
          }

          {[span | acc], t + len, s + len}
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

  defp bridge(source_epoch, target_epoch) do
    gen all d <- derivation() do
      {:ok, b} = Bridge.attach(d, source_epoch, target_epoch, Algorithm.snapshot())
      b
    end
  end

  defp mapped_source_refs(%Bridge{} = b) do
    Enum.flat_map(b.derivation.spans, fn s ->
      for n <- 0..(s.length - 1), do: {s.source_client, s.source_clock + n}
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

  property "normalized inversion preserves one-to-one lookup" do
    check all b <- bridge("A", "B") do
      {:ok, inverted} = Bridge.invert(b)

      for ref <- mapped_source_refs(b) do
        {:ok, target} = Bridge.target_ref(b, ref)
        # The inverse bridge walks the same correspondence the other way.
        assert Bridge.source_ref(inverted, ref) == {:ok, target}
        assert Bridge.target_ref(inverted, target) == {:ok, ref}
      end
    end
  end

  property "lookup across a composed bridge equals successive lookup across its inputs" do
    check all ab <- bridge("A", "B"), bc <- bridge("B", "C") do
      {:ok, ac} = Bridge.compose([ab, bc])

      for ref <- mapped_source_refs(ab) do
        expected =
          case Bridge.target_ref(ab, ref) do
            {:ok, b_ref} -> Bridge.target_ref(bc, b_ref)
            :unmapped -> :unmapped
          end

        assert Bridge.target_ref(ac, ref) == expected
      end
    end
  end

  property "composition is associative after normalization" do
    check all ab <- bridge("A", "B"), bc <- bridge("B", "C"), cd <- bridge("C", "D") do
      {:ok, left_inner} = Bridge.compose([ab, bc])
      {:ok, left} = Bridge.compose([left_inner, cd])
      {:ok, right_inner} = Bridge.compose([bc, cd])
      {:ok, right} = Bridge.compose([ab, right_inner])

      assert left.derivation == right.derivation
      assert left.source_epoch == right.source_epoch and left.target_epoch == right.target_epoch
    end
  end

  property "exact duplicate extension is idempotent" do
    check all b <- bridge("A", "B") do
      {:ok, extended} = Bridge.extend(b, b.derivation)
      assert extended.derivation == b.derivation
    end
  end

  property "composition never maps a coordinate neither input path covered" do
    check all ab <- bridge("A", "B"), bc <- bridge("B", "C") do
      {:ok, ac} = Bridge.compose([ab, bc])

      for span <- ac.derivation.spans, n <- 0..(span.length - 1) do
        ref = {span.source_client, span.source_clock + n}
        assert {:ok, b_ref} = Bridge.target_ref(ab, ref)
        assert {:ok, _} = Bridge.target_ref(bc, b_ref)
      end
    end
  end
end
