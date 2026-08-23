defmodule Yepochs.CompatibilityTest do
  @moduledoc """
  Spec r2 §28.1 — the experimental behaviours the extraction must preserve,
  recreated against the span-based API.

  Each `describe` names the §28.1 bullet it covers. Where the experimental
  behaviour and the spec's required behaviour DIFFER, the difference is asserted
  and explained rather than smoothed over: §27 makes three deliberate
  corrections, so "preserve the fixtures" cannot mean "preserve every property".
  """
  use ExUnit.Case, async: true

  alias Yelixer.Doc
  alias Yelixer.Encoding
  alias Yelixer.Types.Text
  alias Yelixer.Types.YMap
  alias Yepochs.Algorithm
  alias Yepochs.Bridge
  alias Yepochs.Derivation
  alias Yepochs.Error
  alias Yepochs.Snapshotter
  alias Yepochs.Span
  alias Yepochs.Test.Updates

  defp span(lc, lk, rc, rk, len) do
    {:ok, s} =
      Span.new(left_client: lc, left_clock: lk, right_client: rc, right_clock: rk, length: len)

    s
  end

  defp deriv(spans) do
    {:ok, d} = Derivation.new(spans)
    d
  end

  defp bridge(l, r, spans) do
    {:ok, b} = Bridge.attach(deriv(spans), l, r, Algorithm.snapshot())
    b
  end

  defp mat(%Doc{} = d) do
    {:ok, m} = Encoding.apply_update(Doc.new(client_id: d.client_id), Encoding.encode_update(d))
    m
  end

  # {client, clock} => the character at that coordinate.
  defp chars(%Doc{store: store}) do
    store
    |> Yelixer.BlockStore.all_items()
    |> Enum.reject(& &1.deleted)
    |> Enum.flat_map(fn
      %{content: {:string, str}} = i ->
        for n <- 0..(i.length - 1)//1, do: {{i.id.client, i.id.clock + n}, binary_part(str, n, 1)}

      _ ->
        []
    end)
    |> Map.new()
  end

  defp applied(update, client) do
    {:ok, d} = Encoding.apply_update(Doc.new(client_id: client), update)
    d
  end

  describe "§28.1 derivation-map inversion" do
    test "an empty derivation inverts to an empty derivation" do
      {:ok, i} = Derivation.invert(deriv([]))
      assert i.spans == []
    end

    test "every pair is exchanged" do
      {:ok, i} = Derivation.invert(deriv([span(100, 0, 1, 0, 3)]))
      assert [%Span{left_client: 1, left_clock: 0, right_client: 100, right_clock: 0, length: 3}] = i.spans
    end

    test "inversion is involutive" do
      d = deriv([span(99, 2, 1, 5, 2), span(50, 0, 2, 0, 1)])
      {:ok, n} = Derivation.normalize(d)
      {:ok, i} = Derivation.invert(d)
      {:ok, ii} = Derivation.invert(i)
      assert ii == n
    end

    test "⛔ DIFFERS from the experimental map: a non-bijection is REFUSED, not silently collapsed" do
      # `Namespace.inverse_derivation_map/1` flips `%{new => old}` pairs with no
      # bijection check, so two new ids naming one old id lose an entry to a map
      # key collision -- silently. §27.1 makes the mapping a validated partial
      # bijection precisely so that cannot happen.
      collapsing = [span(1, 0, 100, 0, 1), span(2, 0, 100, 0, 1)]

      assert {:error, %Error{code: :invalid_derivation}} = Derivation.new(collapsing)
    end
  end

  describe "§28.1 derivation-map composition" do
    test "an empty path is rejected rather than returning an identity" do
      # The experimental `compose_dms([])` returns `%{}`, an identity that
      # silently succeeds. A bridge path has endpoints, so an empty one is a
      # caller error (§14 requires at least one bridge).
      assert {:error, %Error{code: :bridge_endpoint_mismatch}} = Bridge.compose([])
    end

    test "a single bridge composes to itself" do
      b = bridge("A", "B", [span(100, 0, 1, 0, 3)])
      assert {:ok, ^b} = Bridge.compose([b])
    end

    test "drops entries whose intermediate lookup misses" do
      ab = bridge("A", "B", [span(100, 0, 200, 0, 4)])
      bc = bridge("B", "C", [span(200, 2, 300, 0, 2)])
      {:ok, ac} = Bridge.compose([ab, bc])

      assert Bridge.right_ref(ac, {100, 0}) == :unmapped
      assert Bridge.right_ref(ac, {100, 2}) == {:ok, {300, 0}}
    end

    test "returns an empty correspondence when nothing chains through" do
      ab = bridge("A", "B", [span(100, 0, 200, 0, 2)])
      bc = bridge("B", "C", [span(200, 50, 300, 0, 2)])
      {:ok, ac} = Bridge.compose([ab, bc])
      assert ac.correspondence.spans == []
    end

    test "composed lookup equals sequential chain application, for every mapped id" do
      ab = bridge("A", "B", [span(100, 0, 200, 10, 6)])
      bc = bridge("B", "C", [span(200, 12, 300, 0, 3)])
      {:ok, ac} = Bridge.compose([ab, bc])

      for clock <- 0..5 do
        sequential =
          case Bridge.right_ref(ab, {100, clock}) do
            {:ok, mid} -> Bridge.right_ref(bc, mid)
            :unmapped -> :unmapped
          end

        assert Bridge.right_ref(ac, {100, clock}) == sequential
      end
    end
  end

  describe "§28.1 real snapshot chain — composing two successive REAL snapshots" do
    test "an A-coordinate resolves into C through the composed bridge" do
      # A --snapshot--> B --edit, snapshot--> C, then compose A<->B<->C.
      doc_a = mat(Text.insert(Doc.new(client_id: 100), "t", 0, "abcdefgh"))
      {:ok, s1} = Snapshotter.snapshot(doc_a, [])

      doc_b = applied(s1.update, 1)
      {:ok, s2} = Snapshotter.snapshot(doc_b, [])
      doc_c = applied(s2.update, 2)

      assert Text.to_string(doc_b, "t") == "abcdefgh"
      assert Text.to_string(doc_c, "t") == "abcdefgh"

      ab = bridge("A", "B", s1.derivation.spans)
      bc = bridge("B", "C", s2.derivation.spans)
      assert {:ok, ac} = Bridge.compose([ab, bc])

      # Every clock A holds must still resolve in C, and to the same place the
      # two hops would reach.
      for s <- ab.correspondence.spans, n <- 0..(s.length - 1) do
        ref = {s.left_client, s.left_clock + n}
        {:ok, mid} = Bridge.right_ref(ab, ref)
        assert Bridge.right_ref(ac, ref) == Bridge.right_ref(bc, mid)
      end

      assert ac.correspondence.spans != [], "the chain must retain coverage"
    end

    test "a snapshot of an EDITED document still chains" do
      doc_a = mat(Text.insert(Doc.new(client_id: 100), "t", 0, "abcd"))
      {:ok, s1} = Snapshotter.snapshot(doc_a, [])

      doc_b = mat(Text.insert(applied(s1.update, 1), "t", 2, "XY"))
      {:ok, s2} = Snapshotter.snapshot(doc_b, [])
      doc_c = applied(s2.update, 2)

      assert Text.to_string(doc_c, "t") == "abXYcd"

      ab = bridge("A", "B", s1.derivation.spans)
      bc = bridge("B", "C", s2.derivation.spans)
      assert {:ok, ac} = Bridge.compose([ab, bc])

      # ⭐ The real assertion: an A-coordinate must land on a C-coordinate
      # holding the SAME CHARACTER, across both hops. `spans != []` would pass
      # for a mapping that is entirely wrong.
      from = chars(doc_a)
      to = chars(doc_c)

      pairs =
        Enum.flat_map(ac.correspondence.spans, fn sp ->
          for n <- 0..(sp.length - 1),
              do: {{sp.left_client, sp.left_clock + n}, {sp.right_client, sp.right_clock + n}}
        end)

      assert pairs != [], "the chain must retain coverage"

      for {left, right} <- pairs do
        assert Map.fetch!(from, left) == Map.fetch!(to, right),
               "#{inspect(left)} -> #{inspect(right)}: #{inspect(Map.get(from, left))} vs " <>
                 "#{inspect(Map.get(to, right))}"
      end
    end
  end

  describe "§28.1 mixed top-level shared types" do
    test "a document with text, map and a second text type round-trips through a snapshot" do
      d = Doc.new(client_id: 100) |> Text.insert("t", 0, "abc")
      d = Text.insert(d, "notes", 0, "hi")
      d = YMap.set(d, "cfg", "k", "v")
      src = mat(d)

      {:ok, s} = Snapshotter.snapshot(src, [])
      out = applied(s.update, 7)

      assert Text.to_string(out, "t") == "abc"
      assert Text.to_string(out, "notes") == "hi"
      assert YMap.get(out, "cfg", "k") == "v"
    end
  end

  describe "§28.1 mixed source client IDs" do
    test "the snapshot mints under the smallest source client and maps all of them" do
      a = Text.insert(Doc.new(client_id: 900), "t", 0, "abcd")
      {:ok, b} = Encoding.apply_update(Doc.new(client_id: 300), Encoding.encode_update(a))
      src = mat(Text.insert(b, "t", 2, "XY"))

      {:ok, s} = Snapshotter.snapshot(src, [])
      out = applied(s.update, 5)

      assert Text.to_string(out, "t") == "abXYcd"
      assert Yelixer.BlockStore.client_ids(out.store) == [300]

      left_clients = s.derivation.spans |> Enum.map(& &1.left_client) |> Enum.uniq() |> Enum.sort()
      assert left_clients == [300, 900], "both source clients must appear on the origin side"
    end
  end

  describe "§28.1 translation behaviours" do
    test "origin, right origin, and update-owned identities together" do
      source = Updates.base("abcdefgh", 100)
      b = bridge("A", "B", [span(100, 0, 500, 0, 8)])
      u = Updates.insert_delta(source, 200, 2, "XY")

      {:ok, t} = Yepochs.translate(u, b, :left, [])
      {:ok, out} = Yepochs.Update.decode(t.update)

      assert Yepochs.Update.owned_intervals(out) == [{200, 0, 2}]
      externals = out |> Yepochs.Update.external_refs() |> Enum.map(&elem(&1.ref, 0)) |> Enum.uniq()
      assert externals == [500]
    end

    test "late-edit preflight distinguishes a missing anchor from a missing delete target" do
      source = Updates.base("abcdefgh", 100)
      empty = bridge("A", "B", [])

      assert {:error, %Error{code: :missing_anchor}} =
               Yepochs.preflight(Updates.insert_delta(source, 200, 2, "XY"), empty, :left, [])

      assert {:error, %Error{code: :missing_operation_target}} =
               Yepochs.preflight(Updates.delete_delta(source, 200, 2, 3), empty, :left, [])
    end

    test "positional fallback recovers the edit strict translation cannot prove" do
      source = Updates.base("abcdefgh", 100)
      dest = Updates.base("abcdefgh", 500)
      u = Updates.insert_delta(source, 200, 2, "XY")

      {:ok, c} =
        Yepochs.cross(bridge("A", "B", []), u, source, dest,
          from: :left,
          author: 9000,
          receipt_ref: "compat"
        )

      assert c.mode == :reauthored
      {:ok, out} = Encoding.apply_update(dest, c.update)
      assert Text.to_string(out, "t") == "abXYcdefgh"
    end
  end
end
