defmodule Yepochs.CrossingPropertyTest do
  @moduledoc """
  Properties over `cross/5` — the invariants §7 states about the Bridge contract
  itself, which were previously only unit-tested.

  Invariant 5: *given the required endpoint state, every valid edit over the
  supported data model can cross from either endpoint to the other.*
  Invariant 11: *every successful crossing returns a bridge delta and receipt.*
  Invariant 12: *bridge evolution is monotonic.*
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Yelixer.BlockStore
  alias Yelixer.Doc
  alias Yelixer.Encoding
  alias Yelixer.Types.Text
  alias Yepochs.Algorithm
  alias Yepochs.Bridge
  alias Yepochs.Crossing
  alias Yepochs.Crossing.Receipt
  alias Yepochs.Snapshotter

  defp mat(%Doc{} = d) do
    {:ok, m} = Encoding.apply_update(Doc.new(client_id: d.client_id), Encoding.encode_update(d))
    m
  end

  defp letters, do: string(?a..?z, min_length: 1, max_length: 10)

  # A source document, one valid edit on it, and how much correspondence the
  # bridge carries.
  #
  # ⚠️ The coverage dimension is load-bearing. Without it every generated
  # scenario took the STRICT path — measured, 300 of 300 — so invariant 5 was
  # only ever exercised for `:translated`, which is the easy case. Invariant 5
  # is a claim about EVERY valid edit, so the generator has to be able to defeat
  # the fast path.
  defp scenario do
    gen all base <- letters(),
            op <- member_of([:insert, :delete]),
            pos <- integer(0..20),
            payload <- string(?A..?Z, min_length: 1, max_length: 3),
            coverage <- member_of([:full, :none]),
            len <- integer(1..3) do
      source = mat(Text.insert(Doc.new(client_id: 100), "t", 0, base))
      size = String.length(base)

      edited =
        case op do
          :insert ->
            Text.insert(source, "t", rem(pos, size + 1), payload)

          :delete ->
            at = rem(pos, size)
            Text.delete(source, "t", at, min(len, size - at))
        end

      {source, mat(edited), coverage}
    end
  end

  defp setup_crossing({source, edited, coverage}) do
    {:ok, s} = Snapshotter.snapshot(source, [])
    {:ok, destination} = Encoding.apply_update(Doc.new(client_id: 500), s.update)

    spans = if coverage == :full, do: s.derivation.spans, else: []
    {:ok, d} = Yepochs.Derivation.new(spans)
    {:ok, fresh} = Bridge.attach(d, "origin", "derived", Algorithm.snapshot())

    # ⚠️ The bridge is given PRIOR history before the property runs. Without it
    # `length(extended.receipts) >= length(bridge.receipts)` reduces to `>= 0`,
    # which no mutation can falsify -- measured: dropping prior receipts on
    # extend reddened nothing. Monotonicity is only observable on a bridge that
    # already has something to lose.
    {:ok, prior} = Yepochs.Derivation.new([])

    {:ok, bridge} =
      Bridge.extend(fresh, %Bridge.Delta{
        correspondence: prior,
        receipt: %Receipt{
          ref: "prior-crossing",
          from: :right,
          to: :left,
          mode: :absorbed,
          outcome: :absorbed,
          algorithm: Algorithm.cross()
        }
      })

    update = Encoding.encode_diff(edited, BlockStore.state_vector(source.store))
    {bridge, update, source, destination}
  end

  defp text(%Doc{} = d), do: Text.to_string(d, "t")

  property "invariant 5 — every valid edit crosses, and lands the right observable state" do
    check all scenario <- scenario() do
      {_src, edited, _coverage} = scenario
      {bridge, update, source, destination} = setup_crossing(scenario)

      assert {:ok, %Crossing{} = c} =
               Yepochs.cross(bridge, update, source, destination,
                 from: :left,
                 author: 7000,
                 receipt_ref: "p"
               ),
             "a valid edit failed to cross: #{inspect(text(source))} -> #{inspect(text(edited))}"

      result =
        case c.update do
          <<>> -> destination
          u -> (fn -> {:ok, d} = Encoding.apply_update(destination, u); d end).()
        end

      assert text(result) == text(edited),
             "crossed to #{inspect(text(result))}, expected #{inspect(text(edited))} (#{c.mode})"
    end
  end

  property "invariant 11 — every successful crossing returns a delta and a receipt" do
    check all scenario <- scenario() do
      {bridge, update, source, destination} = setup_crossing(scenario)

      {:ok, c} =
        Yepochs.cross(bridge, update, source, destination,
          from: :left,
          author: 7000,
          receipt_ref: "ref-1"
        )

      assert %Receipt{ref: "ref-1", from: :left, to: :right} = c.bridge_delta.receipt
      assert c.bridge_delta.receipt.mode == c.mode
      assert c.bridge_delta.receipt.outcome == c.outcome
      assert %Yepochs.Derivation{} = c.bridge_delta.correspondence
    end
  end

  property "invariant 12 — bridge evolution is monotonic" do
    check all scenario <- scenario() do
      {bridge, update, source, destination} = setup_crossing(scenario)

      {:ok, c} =
        Yepochs.cross(bridge, update, source, destination,
          from: :left,
          author: 7000,
          receipt_ref: "ref-1"
        )

      {:ok, extended} = Bridge.extend(bridge, c.bridge_delta)

      # Nothing the bridge already knew may be lost.
      for span <- bridge.correspondence.spans, n <- 0..(span.length - 1) do
        ref = {span.left_client, span.left_clock + n}

        assert Bridge.right_ref(extended, ref) == Bridge.right_ref(bridge, ref),
               "extension changed an existing mapping"
      end

      assert length(extended.receipts) > length(bridge.receipts),
             "a new crossing must ADD a receipt"

      for prior <- bridge.receipts do
        assert prior in extended.receipts, "extension dropped an earlier receipt"
      end

      assert extended.left_epoch == bridge.left_epoch
      assert extended.right_epoch == bridge.right_epoch
    end
  end

  property "a crossing is deterministic — same inputs, same bytes and same receipt" do
    check all scenario <- scenario() do
      {bridge, update, source, destination} = setup_crossing(scenario)

      results =
        for _ <- 1..3 do
          {:ok, c} =
            Yepochs.cross(bridge, update, source, destination,
              from: :left,
              author: 7000,
              receipt_ref: "ref-1"
            )

          {c.update, c.mode, c.outcome, c.bridge_delta.receipt}
        end

      assert results |> Enum.uniq() |> length() == 1
    end
  end
end
