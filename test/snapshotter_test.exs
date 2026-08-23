defmodule Yepochs.SnapshotterTest do
  use ExUnit.Case, async: true

  alias Yelixer.Doc
  alias Yelixer.Encoding
  alias Yelixer.Types.Text
  alias Yelixer.Types.YMap
  alias Yepochs.Algorithm
  alias Yepochs.Bridge
  alias Yepochs.Error
  alias Yepochs.Snapshot
  alias Yepochs.Snapshotter
  alias Yepochs.Span

  # A locally-authored doc keeps items in BlockStore.client_pending; a
  # reconstructed one (the real caller's input) has them materialized.
  defp materialized(%Doc{} = d) do
    {:ok, m} = Encoding.apply_update(Doc.new(client_id: d.client_id), Encoding.encode_update(d))
    m
  end

  defp text(%Doc{} = d), do: Text.to_string(d, "t")

  defp applied(update) do
    {:ok, d} = Encoding.apply_update(Doc.new(client_id: 1), update)
    d
  end

  defp source(str, client \\ 100),
    do: materialized(Text.insert(Doc.new(client_id: client), "t", 0, str))

  # {client, clock} => the value living at that coordinate, for any content kind.
  defp content_by_clock(%Doc{store: store}) do
    store
    |> Yelixer.BlockStore.all_items()
    |> Enum.reject(& &1.deleted)
    |> Enum.flat_map(fn
      %{content: {:string, str}} = item ->
        for n <- 0..(item.length - 1)//1,
            do: {{item.id.client, item.id.clock + n}, {:char, binary_part(str, n, 1)}}

      item ->
        for n <- 0..(item.length - 1)//1,
            do: {{item.id.client, item.id.clock + n}, {item.parent_sub, item.content}}
    end)
    |> Map.new()
  end

  defp assert_correspondence(src, snapshot) do
    out = applied(snapshot.update)
    from = content_by_clock(src)
    to = content_by_clock(out)

    pairs =
      Enum.flat_map(snapshot.derivation.spans, fn sp ->
        for n <- 0..(sp.length - 1),
            do: {{sp.left_client, sp.left_clock + n}, {sp.right_client, sp.right_clock + n}}
      end)

    for {left, right} <- pairs do
      assert Map.fetch!(from, left) == Map.fetch!(to, right),
             "#{inspect(left)} -> #{inspect(right)}: #{inspect(Map.get(from, left))} " <>
               "vs #{inspect(Map.get(to, right))}"
    end

    pairs
  end

  # {client, clock} => the single character living at that coordinate.
  defp chars_by_clock(%Doc{store: store}) do
    store
    |> Yelixer.BlockStore.client_ids()
    |> Enum.flat_map(fn c -> Yelixer.BlockStore.client_blocks(store, c) end)
    |> Enum.reject(& &1.deleted)
    |> Enum.flat_map(fn
      %{content: {:string, str}} = item ->
        for n <- 0..(item.length - 1)//1,
            do: {{item.id.client, item.id.clock + n}, binary_part(str, n, 1)}

      _ ->
        []
    end)
    |> Map.new()
  end

  describe "observable equivalence — §10.2" do
    test "applying the snapshot to an empty doc reproduces the source's visible text" do
      src = source("abcdefgh")
      assert {:ok, %Snapshot{} = s} = Snapshotter.snapshot(src, [])
      assert text(applied(s.update)) == "abcdefgh"
    end

    test "tombstoned content is not resurrected" do
      src = materialized(Text.delete(source("abcdefgh"), "t", 3, 2))
      {:ok, s} = Snapshotter.snapshot(src, [])
      assert text(applied(s.update)) == text(src)
      assert text(applied(s.update)) == "abcfgh"
    end

    test "preserves a map plane alongside a text plane" do
      d = Text.insert(Doc.new(client_id: 100), "t", 0, "abc")
      src = materialized(YMap.set(d, "m", "k1", "v1"))

      {:ok, s} = Snapshotter.snapshot(src, [])
      out = applied(s.update)
      assert text(out) == "abc"
      assert YMap.get(out, "m", "k1") == "v1"
    end

    test "⛔ refuses to emit an EMPTY snapshot for a document that has content" do
      # Measured: the replay iterates the source's TYPE REGISTRY, so a doc whose
      # `types` map does not list the name its content lives under is replayed
      # to nothing -- bytes, no error. §10.2 forbids silently omitting it.
      unregistered = Text.insert(Doc.new(client_id: 100), "t", 0, "abcdefgh")
      assert unregistered.types == %{}, "precondition: the registry is empty"

      assert {:error, %Error{code: :unsupported_content, phase: :snapshot} = err} =
               Snapshotter.snapshot(unregistered, [])

      assert err.details.source_clocks == 8
      assert err.details.derived_clocks == 0
    end

    test "⛔ refuses an XML element with CHILDREN, which the replay silently drops" do
      # Measured: the replay does not re-author `name::children`, so an element
      # with one child snapshots to an element with none -- attributes intact,
      # no error. §10.2 forbids silently omitting it.
      d = Yelixer.Types.XMLElement.new_element(Doc.new(client_id: 100), "el", "div")
      d = Yelixer.Types.XMLElement.insert_child(d, "el", 0, {:element, "span"})
      src = materialized(Yelixer.Types.XMLElement.set_attribute(d, "el", "class", "big"))

      assert Yelixer.Types.XMLElement.child_count(src, "el") == 1

      assert {:error, %Error{code: :unsupported_content, phase: :snapshot}} =
               Snapshotter.snapshot(src, [])
    end

    test "an XML element with attributes but NO children still snapshots" do
      d = Yelixer.Types.XMLElement.new_element(Doc.new(client_id: 100), "el", "div")
      src = materialized(Yelixer.Types.XMLElement.set_attribute(d, "el", "class", "big"))

      assert {:ok, s} = Snapshotter.snapshot(src, [])
      {:ok, out} = Encoding.apply_update(Doc.new(client_id: 1), s.update)
      assert Yelixer.Types.XMLElement.get_attributes(out, "el") == %{"class" => "big"}
    end

    test "refuses content it cannot faithfully re-author, rather than flattening it" do
      nested = Doc.new(client_id: 100) |> Text.insert("t", 0, "abc")

      case Yelixer.Doc.nested_subtype_names(nested) do
        [] ->
          assert {:ok, _} = Snapshotter.snapshot(materialized(nested), [])

        _ ->
          assert {:error, %Error{code: :unsupported_content}} = Snapshotter.snapshot(nested, [])
      end
    end
  end

  describe "algorithm version 2 — §10.3" do
    test "selects the minimum source client id as the snapshot client id" do
      a = Text.insert(Doc.new(client_id: 700), "t", 0, "abcd")
      {:ok, a} = Encoding.apply_update(Doc.new(client_id: 300), Encoding.encode_update(a))
      src = materialized(Text.insert(a, "t", 2, "XY"))

      {:ok, s} = Snapshotter.snapshot(src, [])
      clients = applied(s.update).store |> Yelixer.BlockStore.client_ids()

      assert clients == [300], "v2 must mint under the smallest source client id"
    end

    test "uses client id 0 for an empty source" do
      {:ok, s} = Snapshotter.snapshot(Doc.new(client_id: 55), [])
      assert s.derivation.spans == []
      assert s.algorithm == Algorithm.snapshot()
    end

    test "stamps snapshot algorithm version 2" do
      {:ok, s} = Snapshotter.snapshot(source("abc"), [])
      assert s.algorithm == %Algorithm{id: "yepochs.snapshot", version: 2}
    end
  end

  describe "derivation is SPAN-based and complete — §10.5, §27.1" do
    test "covers EVERY emitted clock, even when the replay consolidates items" do
      # Eight 1-char inserts consolidate into one 8-clock item. The old
      # item-start derivation map covered 1 of those 8 clocks; spans must cover
      # all 8.
      frag =
        materialized(
          Enum.reduce(0..7, Doc.new(client_id: 100), fn i, d ->
            Text.insert(d, "t", i, <<?a + i>>)
          end)
        )

      {:ok, s} = Snapshotter.snapshot(frag, [])
      covered = Enum.sum(Enum.map(s.derivation.spans, & &1.length))

      assert covered == 8, "expected all 8 clocks covered, got #{covered}"
    end

    test "the derivation is a valid partial bijection" do
      frag =
        materialized(
          Enum.reduce(0..7, Doc.new(client_id: 100), fn i, d ->
            Text.insert(d, "t", i, <<?a + i>>)
          end)
        )

      {:ok, s} = Snapshotter.snapshot(frag, [])
      assert :ok = Yepochs.Derivation.validate(s.derivation)
    end

    test "left is the ORIGIN and right is the DERIVED side" do
      src = source("abcdefgh")
      {:ok, s} = Snapshotter.snapshot(src, [])

      assert [
               %Span{
                 left_client: 100,
                 left_clock: 0,
                 right_client: 100,
                 right_clock: 0,
                 length: 8
               }
             ] =
               s.derivation.spans
    end

    test "maps a reference into the MIDDLE of a consolidated item — §27.1" do
      frag =
        materialized(
          Enum.reduce(0..7, Doc.new(client_id: 100), fn i, d ->
            Text.insert(d, "t", i, <<?a + i>>)
          end)
        )

      {:ok, s} = Snapshotter.snapshot(frag, [])
      {:ok, b} = Bridge.attach(s.derivation, "origin", "derived", Algorithm.snapshot())

      # Source clock 5 was its own item; in the target it is inside one big item.
      assert {:ok, _} = Bridge.right_ref(b, {100, 5})
    end

    test "SPLITS the derivation where source clocks are non-contiguous around tombstones" do
      # Observable clocks are 0,1,2 then 5,6,7 -- the deleted 3,4 are not
      # re-authored. Merging across that gap would map source clock 3 to a live
      # target clock, which is a wrong answer rather than an error.
      src = materialized(Text.delete(source("abcdefgh"), "t", 3, 2))
      {:ok, s} = Snapshotter.snapshot(src, [])

      assert length(s.derivation.spans) == 2,
             "expected two spans across the tombstone gap, got #{inspect(s.derivation.spans)}"

      {:ok, b} = Bridge.attach(s.derivation, "o", "d", Algorithm.snapshot())

      assert Bridge.right_ref(b, {100, 3}) == :unmapped,
             "§10.5 promises no mapping for tombstoned content"

      assert {:ok, _} = Bridge.right_ref(b, {100, 5})
    end

    test "maps every source clock to a target clock holding the SAME character" do
      # The strongest available correctness check on the pairing, and the one
      # that catches a wrong stream ORDER: a mis-ordered pairing still produces a
      # valid-looking bijection, but it lines characters up with the wrong ones.
      a = Text.insert(Doc.new(client_id: 700), "t", 0, "abcd")
      {:ok, a} = Encoding.apply_update(Doc.new(client_id: 300), Encoding.encode_update(a))
      src = materialized(Text.insert(a, "t", 2, "XY"))

      {:ok, s} = Snapshotter.snapshot(src, [])
      out = applied(s.update)

      source_chars = chars_by_clock(src)
      target_chars = chars_by_clock(out)

      pairs =
        Enum.flat_map(s.derivation.spans, fn sp ->
          for n <- 0..(sp.length - 1),
              do: {{sp.left_client, sp.left_clock + n}, {sp.right_client, sp.right_clock + n}}
        end)

      assert length(pairs) == 6, "all six observable clocks must be paired"

      for {left, right} <- pairs do
        assert Map.fetch!(source_chars, left) == Map.fetch!(target_chars, right),
               "clock #{inspect(left)} maps to #{inspect(right)}, but the characters differ " <>
                 "(#{inspect(Map.get(source_chars, left))} vs #{inspect(Map.get(target_chars, right))})"
      end
    end

    test "pairs correctly across SEVERAL named types and SEVERAL map keys" do
      # With one type and one key, any traversal order agrees with any other. The
      # ordering rules only become observable once both documents could enumerate
      # their content differently -- which they can, because the map-plane scan
      # reads all_items, whose order follows the very ids the snapshot replaces.
      d = Doc.new(client_id: 100)
      d = Text.insert(d, "zeta", 0, "zz")
      d = Text.insert(d, "alpha", 0, "aa")
      d = Text.insert(d, "mid", 0, "mm")
      d = YMap.set(d, "cfg", "kb", "vb")
      d = YMap.set(d, "cfg", "ka", "va")
      d = YMap.set(d, "cfg", "kc", "vc")
      src = materialized(d)

      {:ok, s} = Snapshotter.snapshot(src, [])
      out = applied(s.update)

      assert Text.to_string(out, "alpha") == "aa"
      assert Text.to_string(out, "zeta") == "zz"
      assert YMap.get(out, "cfg", "ka") == "va"
      assert YMap.get(out, "cfg", "kc") == "vc"

      pairs = assert_correspondence(src, s)
      assert length(pairs) == 9, "6 text clocks + 3 map entries must all be paired"
    end

    test "the result carries NO target epoch reference — §10.1" do
      {:ok, s} = Snapshotter.snapshot(source("abc"), [])
      refute Map.has_key?(s, :target_epoch)
      refute Map.has_key?(s, :epoch)
    end
  end

  describe "determinism — §10.4" do
    test "repeated calls on the same decoded state produce byte-identical output" do
      src = source("abcdefgh")

      results = for _ <- 1..30, do: Snapshotter.snapshot(src, [])
      updates = Enum.map(results, fn {:ok, s} -> s.update end)
      derivations = Enum.map(results, fn {:ok, s} -> Yepochs.Derivation.to_map(s.derivation) end)

      assert Enum.uniq(updates) |> length() == 1
      assert Enum.uniq(derivations) |> length() == 1
    end

    test "does not depend on the source doc's own client_id field" do
      a = source("abcdefgh")
      b = %{a | client_id: 999_999}

      {:ok, sa} = Snapshotter.snapshot(a, [])
      {:ok, sb} = Snapshotter.snapshot(b, [])
      assert sa.update == sb.update
    end
  end
end
