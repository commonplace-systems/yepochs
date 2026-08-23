defmodule Yepochs.TranslatorTest do
  use ExUnit.Case, async: true

  alias Yelixer.Encoding
  alias Yepochs.Algorithm
  alias Yepochs.Bridge
  alias Yepochs.Derivation
  alias Yepochs.Error
  alias Yepochs.Span
  alias Yepochs.Test.Updates
  alias Yepochs.Translation
  alias Yepochs.Translator
  alias Yepochs.Update

  defp span(lc, lk, rc, rk, len) do
    {:ok, s} =
      Span.new(left_client: lc, left_clock: lk, right_client: rc, right_clock: rk, length: len)

    s
  end

  defp bridge(spans) do
    {:ok, d} = Derivation.new(spans)
    {:ok, b} = Bridge.attach(d, "origin-epoch", "derived-epoch", Algorithm.snapshot())
    b
  end

  # Source epoch: "abcdefgh" authored by client 100.
  # Destination epoch: the same text re-authored as client 500.
  defp full_bridge, do: bridge([span(100, 0, 500, 0, 8)])

  setup_all do
    %{source: Updates.base("abcdefgh", 100), dest: Updates.base("abcdefgh", 500)}
  end

  defp parent_id({:id, id}), do: id
  defp parent_id({:infer, id}), do: id
  defp parent_id(_), do: nil

  defp apply_to(dest, update) do
    {:ok, d} = Encoding.apply_update(dest, update)
    Yelixer.Types.Text.to_string(d, "t")
  end

  describe "translate/4 — the strict fast path" do
    test "produces an update that applies to the DESTINATION with the right observable state",
         %{source: source, dest: dest} do
      # Spec §28.2 fixture 15.
      u = Updates.insert_delta(source, 200, 2, "XY")
      assert {:ok, %Translation{} = t} = Translator.translate(u, full_bridge(), :left, [])

      assert apply_to(dest, t.update) == "abXYcdefgh"
    end

    test "translates a DELETE, so the destination loses the right characters",
         %{source: source, dest: dest} do
      u = Updates.delete_delta(source, 200, 2, 3)
      {:ok, t} = Translator.translate(u, full_bridge(), :left, [])

      assert apply_to(dest, t.update) == "abfgh"
    end

    test "⛔ does NOT reuse the source delete set unchanged — §15.8", %{source: source} do
      u = Updates.delete_delta(source, 200, 2, 3)
      {:ok, t} = Translator.translate(u, full_bridge(), :left, [])

      {:ok, before} = Update.decode(u)
      {:ok, after_} = Update.decode(t.update)

      assert before.delete_set.clients |> Map.keys() == [100]
      assert after_.delete_set.clients |> Map.keys() == [500],
             "the delete set must be rewritten into destination coordinates"
    end

    test "preserves every identity the update itself authored — §15.4", %{source: source} do
      u = Updates.insert_delta(source, 200, 2, "XY")
      {:ok, t} = Translator.translate(u, full_bridge(), :left, [])

      {:ok, before} = Update.decode(u)
      {:ok, after_} = Update.decode(t.update)

      assert Update.owned_intervals(after_) == Update.owned_intervals(before)
    end

    test "rewrites external anchors into destination coordinates", %{source: source} do
      u = Updates.insert_delta(source, 200, 2, "XY")
      {:ok, t} = Translator.translate(u, full_bridge(), :left, [])
      {:ok, after_} = Update.decode(t.update)

      refs = after_ |> Update.external_refs() |> Enum.map(&elem(&1.ref, 0)) |> Enum.uniq()
      assert refs != []
      assert refs == [500], "every external reference must now name the destination client"
    end

    test "leaves references among the update's OWN items alone", %{source: source, dest: dest} do
      # Two runs inserted by one update: the second anchors on the first.
      r = Yelixer.Types.Text.insert(Updates.replica(source, 200), "t", 2, "XY")
      r = Yelixer.Types.Text.insert(r, "t", 4, "ZW")
      u = Updates.delta(r, source)

      {:ok, t} = Translator.translate(u, full_bridge(), :left, [])
      assert apply_to(dest, t.update) == "abXYZWcdefgh"
    end

    test "carries identity spans for every owned interval — §15.4", %{source: source} do
      u = Updates.insert_delta(source, 200, 2, "XY")
      {:ok, t} = Translator.translate(u, full_bridge(), :left, [])

      assert [%Span{left_client: 200, left_clock: 0, right_client: 200, right_clock: 0, length: 2}] =
               t.carried.spans
    end

    test "translates an ID-VALUED parent — §15.7", %{source: source} do
      {:ok, decoded} = Update.decode(Updates.insert_delta(source, 200, 2, "XY"))

      # No origins, so the parent IS written to the wire (verified against the
      # encoder: parent is emitted only when both origins are nil).
      nested = %Yelixer.Item{
        id: %Yelixer.ID{client: 700, clock: 0},
        origin: nil,
        right_origin: nil,
        content: {:string, "Q"},
        parent: {:id, %Yelixer.ID{client: 100, clock: 3}},
        parent_sub: nil,
        deleted: false,
        length: 1
      }

      {:ok, t} =
        Translator.translate(%{decoded | items: decoded.items ++ [nested]}, full_bridge(), :left, [])

      {:ok, out} = Update.decode(t.update)

      assert {:id, %Yelixer.ID{client: 500, clock: 3}} in Enum.map(out.items, & &1.parent),
             "an ID-valued parent must be rewritten into destination coordinates"
    end

    test "leaves a NAMED root parent unchanged — §15.7", %{source: source} do
      # The base document's own first insert has no origin, so its parent is the
      # named root and is written explicitly.
      {:ok, t} = Translator.translate(Updates.full(source), full_bridge(), :left, [])
      {:ok, out} = Update.decode(t.update)

      assert {:named, "t"} in Enum.map(out.items, & &1.parent)
    end

    test "⛔ no SOURCE-epoch coordinate survives in any identity-bearing field", %{source: source} do
      # The invariant behind §15.6-§15.9, asserted directly rather than
      # field-by-field: after translating away from client 100, nothing in the
      # output may still name client 100.
      r = Yelixer.Types.Text.insert(Updates.replica(source, 200), "t", 2, "XY")
      r = Yelixer.Types.Text.delete(r, "t", 5, 2)
      {:ok, t} = Translator.translate(Updates.delta(r, source), full_bridge(), :left, [])
      {:ok, out} = Update.decode(t.update)

      coords =
        Enum.flat_map(out.items, fn item ->
          [item.origin, item.right_origin, parent_id(item.parent)]
          |> Enum.reject(&is_nil/1)
          |> Enum.map(& &1.client)
        end) ++ Map.keys(out.delete_set.clients)

      assert coords != [], "the check needs identity fields to inspect"
      refute 100 in coords, "a source-epoch client id leaked into the translated update"
    end

    test "records the strict translation algorithm", %{source: source} do
      u = Updates.insert_delta(source, 200, 2, "XY")
      {:ok, t} = Translator.translate(u, full_bridge(), :left, [])
      assert t.algorithm == Algorithm.translate()
    end

    test "crosses RIGHT-to-left as well, because the bridge is bilateral" do
      derived = Updates.base("abcdefgh", 500)
      origin = Updates.base("abcdefgh", 100)
      u = Updates.insert_delta(derived, 600, 2, "XY")

      {:ok, t} = Translator.translate(u, full_bridge(), :right, [])
      assert apply_to(origin, t.update) == "abXYcdefgh"
    end
  end

  describe "determinism — §15.10" do
    test "the same input yields byte-identical output", %{source: source} do
      u = Updates.insert_delta(source, 200, 2, "XY")

      outputs =
        for _ <- 1..50 do
          {:ok, t} = Translator.translate(u, full_bridge(), :left, [])
          t.update
        end

      assert outputs |> Enum.uniq() |> length() == 1
    end

    test "an equivalent bridge built in a different span order yields the same bytes",
         %{source: source} do
      u = Updates.delete_delta(source, 200, 2, 3)
      a = bridge([span(100, 0, 500, 0, 4), span(100, 4, 500, 4, 4)])
      b = bridge([span(100, 4, 500, 4, 4), span(100, 0, 500, 0, 4)])

      {:ok, ta} = Translator.translate(u, a, :left, [])
      {:ok, tb} = Translator.translate(u, b, :left, [])
      assert ta.update == tb.update
    end
  end

  describe "it is the low-level API, so it surfaces strict failures — §15.3" do
    test "propagates a missing anchor rather than re-authoring", %{source: source} do
      u = Updates.insert_delta(source, 200, 2, "XY")
      assert {:error, %Error{code: :missing_anchor}} =
               Translator.translate(u, bridge([span(100, 5, 500, 5, 3)]), :left, [])
    end

    test "propagates a missing delete target", %{source: source} do
      u = Updates.delete_delta(source, 200, 2, 3)
      assert {:error, %Error{code: :missing_operation_target}} =
               Translator.translate(u, bridge([span(100, 0, 500, 0, 2)]), :left, [])
    end

    test "emits no partial update when preflight fails", %{source: source} do
      u = Updates.insert_delta(source, 200, 2, "XY")
      assert {:error, %Error{}} = Translator.translate(u, bridge([]), :left, [])
    end
  end
end

defmodule Yepochs.TranslatePathTest do
  use ExUnit.Case, async: true

  alias Yepochs.Algorithm
  alias Yepochs.Bridge
  alias Yepochs.Derivation
  alias Yepochs.Error
  alias Yepochs.Span
  alias Yepochs.Test.Updates

  defp span(lc, lk, rc, rk, len) do
    {:ok, s} =
      Span.new(left_client: lc, left_clock: lk, right_client: rc, right_clock: rk, length: len)

    s
  end

  defp bridge(l, r, spans) do
    {:ok, d} = Derivation.new(spans)
    {:ok, b} = Bridge.attach(d, l, r, Algorithm.snapshot())
    b
  end

  defp text(dest, update) do
    {:ok, d} = Yelixer.Encoding.apply_update(dest, update)
    Yelixer.Types.Text.to_string(d, "t")
  end

  setup_all do
    %{source: Updates.base("abcdefgh", 100), final: Updates.base("abcdefgh", 900)}
  end

  test "translates across two composed bridges", %{source: source, final: final} do
    u = Updates.insert_delta(source, 200, 2, "XY")
    ab = bridge("A", "B", [span(100, 0, 500, 0, 8)])
    bc = bridge("B", "C", [span(500, 0, 900, 0, 8)])

    assert {:ok, t} = Yepochs.translate_path(u, [ab, bc], [])
    assert text(final, t.update) == "abXYcdefgh"
  end

  test "translates across three composed bridges", %{source: source, final: final} do
    u = Updates.delete_delta(source, 200, 2, 3)
    ab = bridge("A", "B", [span(100, 0, 500, 0, 8)])
    bc = bridge("B", "C", [span(500, 0, 700, 0, 8)])
    cd = bridge("C", "D", [span(700, 0, 900, 0, 8)])

    assert {:ok, t} = Yepochs.translate_path(u, [ab, bc, cd], [])
    assert text(final, t.update) == "abfgh"
  end

  test "a single-bridge path behaves like translate/4", %{source: source} do
    u = Updates.insert_delta(source, 200, 2, "XY")
    ab = bridge("A", "B", [span(100, 0, 500, 0, 8)])

    assert {:ok, direct} = Yepochs.translate(u, ab, :left, [])
    assert {:ok, via_path} = Yepochs.translate_path(u, [ab], [])
    assert direct.update == via_path.update
  end

  test "rejects a disconnected path", %{source: source} do
    u = Updates.insert_delta(source, 200, 2, "XY")
    ab = bridge("A", "B", [span(100, 0, 500, 0, 8)])
    cd = bridge("C", "D", [span(700, 0, 900, 0, 8)])

    assert {:error, %Error{code: :bridge_endpoint_mismatch}} =
             Yepochs.translate_path(u, [ab, cd], [])
  end

  test "rejects an empty path", %{source: source} do
    u = Updates.insert_delta(source, 200, 2, "XY")
    assert {:error, %Error{code: :bridge_endpoint_mismatch}} = Yepochs.translate_path(u, [], [])
  end

  test "fails strictly when composition loses the coverage the edit needs", %{source: source} do
    # §18: composition is partial, and a strict path translation that fails is
    # the caller's cue to cross edge-by-edge instead.
    u = Updates.insert_delta(source, 200, 2, "XY")
    ab = bridge("A", "B", [span(100, 0, 500, 0, 8)])
    bc = bridge("B", "C", [span(500, 6, 900, 6, 2)])

    assert {:error, %Error{code: :missing_anchor}} = Yepochs.translate_path(u, [ab, bc], [])
  end
end
