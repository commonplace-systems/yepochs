defmodule Yepochs.TotalityTest do
  @moduledoc """
  jes: *"it's possible the definition of bridge is mathematically impossible, we
  just need to do something sensible in every case, but not the impossible."*

  ⭐ **That turns an impossibility into a REQUIREMENT TO CLASSIFY.** For every
  case, this suite demands one of exactly two things:

    * a **defined sensible behaviour**, verified *at the destination* — the
      crossed update applied to the destination reproduces the edited source's
      observable content; or
    * a **demonstrated impossibility** — a typed refusal, listed by name below,
      with `docs/design/0006-totality-classification.md` recording the mechanism.

  ⛔ **A cell that is neither fails this suite.** A raise, an untyped error, or a
  crossing that produces bytes the destination does not accept is an
  unclassified case — which is precisely the state that reads later as an
  unimplemented feature rather than a known limit.

  ⚠️ The impossible set is asserted **by name**, not by count. A newly-impossible
  shape must be added deliberately, with its mechanism recorded; it cannot
  arrive by a cell quietly changing category.
  """
  use ExUnit.Case, async: true

  alias Yelixer.BlockStore
  alias Yelixer.Doc
  alias Yelixer.Encoding
  alias Yelixer.Types.Array
  alias Yelixer.Types.Text
  alias Yelixer.Types.XMLElement
  alias Yelixer.Types.XMLFragment
  alias Yelixer.Types.XMLText
  alias Yelixer.Types.YMap
  alias Yepochs.Algorithm
  alias Yepochs.Bridge
  alias Yepochs.Snapshotter

  # ⛔ Shapes that CANNOT hold a bridge, by name. See design doc 0006 §2.
  @impossible_shapes ["xmlelement-child", "xmlfragment-child"]

  # ⚠️ Plain compile-time NAME lists. `shapes/0` and `edits/0` return builder
  # functions, which have no compile-time representation and cannot be walked by
  # a module-body comprehension — so the generated tests are driven by these
  # names and look their builders up at run time. `all_names_are_covered/0`
  # below is the gate that keeps the two lists from drifting apart.
  @shape_names ~w(text-clean text-tombstoned map-clean map-tombstoned array-clean
                  array-tombstoned xmltext xmlelement-attrs xmlelement-child
                  xmlfragment-child multi-type single-author-degenerate empty)
  @edit_names ~w(text-insert text-delete map-set map-delete array-insert
                 array-delete xmltext-ins xml-attr-set xml-add-kid new-type)

  # A locally-authored Doc keeps its items in `client_pending` and has an EMPTY
  # type registry; the snapshot replay iterates that registry, so such a doc
  # snapshots to nothing and is refused. One round-trip materializes it.
  defp materialized(%Doc{} = d) do
    {:ok, m} = Encoding.apply_update(Doc.new(client_id: d.client_id), Encoding.encode_update(d))
    m
  end

  # ⛔ EVERY SHAPE MUST BE MULTI-AUTHOR, and this is not a nicety.
  #
  # The deterministic minter re-authors a snapshot under the SMALLEST client id
  # present in the source. A single-author document has exactly one, so the
  # derived document reuses it and every correspondence span comes out as an
  # IDENTITY mapping — left {100,0} == right {100,0}.
  #
  # ⇒ Measured: with identity spans, a translator that ignored the bridge
  # entirely and passed raw coordinates through unchanged passes every cell.
  # That is precisely what invariant 9 forbids, and a matrix built that way
  # cannot detect a violation of it. Mutation testing caught it: mislabelling
  # the crossing direction changed nothing, because with identity spans there is
  # nothing for a direction to be wrong about.
  #
  # A second, HIGHER-numbered author guarantees content that must be remapped.
  defp two_author(%Doc{} = first, second_fn) do
    base = materialized(first)
    second = second_fn.(replica(base, 200))
    {:ok, merged} = Encoding.apply_update(base, Encoding.encode_update(second))
    materialized(merged)
  end

  defp replica(%Doc{} = base, client) do
    d = Doc.new(client_id: client)
    {:ok, d} = Encoding.apply_update(d, Encoding.encode_update(base))
    d
  end

  defp delta(%Doc{} = doc, %Doc{} = since),
    do: Encoding.encode_diff(doc, BlockStore.state_vector(since.store))

  # Observable content: identity-free AND segmentation-free.
  #
  # ⛔ An earlier version listed each live ITEM's content, and that is a
  # representation comparison wearing a value comparison's clothes. The snapshot
  # replay CONSOLIDATES adjacent runs: a source holding "hello" and "!!" as two
  # items becomes one item "hello!!". Measured — it reported 61 correct
  # crossings as wrong, and every one of them was the same consolidation.
  #
  # ⇒ Sequences are flattened to their ordered atomic values via
  # `get_sequence/2` (document order), so item boundaries cannot be seen.
  # Keyed (`parent_sub`) content is compared per key.
  defp observable(%Doc{} = d) do
    names =
      d.store
      |> BlockStore.all_items()
      |> Enum.flat_map(fn
        %{parent: {:named, name}} -> [name]
        _ -> []
      end)
      |> Enum.uniq()
      |> Enum.sort()

    for name <- names do
      sequence =
        d.store
        |> BlockStore.get_sequence(name)
        |> Enum.reject(& &1.deleted)
        |> Enum.filter(&is_nil(&1.parent_sub))
        |> Enum.flat_map(&atoms/1)

      keyed =
        d.store
        |> BlockStore.all_items()
        |> Enum.reject(& &1.deleted)
        |> Enum.filter(&(match?({:named, ^name}, &1.parent) and not is_nil(&1.parent_sub)))
        |> Enum.map(&{&1.parent_sub, inspect(&1.content)})
        |> Enum.sort()

      {name, sequence, keyed}
    end
  end

  # One item's content as an ordered list of atomic values, so that two docs
  # segmenting the same value differently still compare equal.
  defp atoms(%{content: {:string, str}}), do: String.graphemes(str)
  defp atoms(%{content: {:any, values}}) when is_list(values), do: Enum.map(values, &inspect/1)
  defp atoms(%{content: other}), do: [inspect(other)]

  defp shapes do
    [
      {"text-clean",
       fn ->
         two_author(
           Text.insert(Doc.new(client_id: 100), "t", 0, "hello"),
           &Text.insert(&1, "t", 5, "!!")
         )
       end},
      {"text-tombstoned",
       fn ->
         two_author(
           Text.insert(Doc.new(client_id: 100), "t", 0, "hello world"),
           &(&1 |> Text.insert("t", 11, "!!") |> Text.delete("t", 5, 6))
         )
       end},
      {"map-clean",
       fn ->
         two_author(
           YMap.set(Doc.new(client_id: 100), "m", "a", "1"),
           &YMap.set(&1, "m", "b", "2")
         )
       end},
      {"map-tombstoned",
       fn ->
         two_author(
           YMap.set(Doc.new(client_id: 100), "m", "a", "1"),
           &YMap.set(&1, "m", "a", "2")
         )
       end},
      {"array-clean",
       fn ->
         two_author(
           Array.insert(Doc.new(client_id: 100), "a", 0, ["x"]),
           &Array.push(&1, "a", ["y"])
         )
       end},
      {"array-tombstoned",
       fn ->
         two_author(
           Array.insert(Doc.new(client_id: 100), "a", 0, ["x", "y"]),
           &(&1 |> Array.push("a", ["z"]) |> Array.delete("a", 1, 1))
         )
       end},
      {"xmltext",
       fn ->
         two_author(
           XMLText.insert(Doc.new(client_id: 100), "x", 0, "hi"),
           &XMLText.insert(&1, "x", 2, "!")
         )
       end},
      {"xmlelement-attrs",
       fn ->
         two_author(
           Doc.new(client_id: 100)
           |> XMLElement.new_element("e", "p")
           |> XMLElement.set_attribute("e", "k", "v"),
           &XMLElement.set_attribute(&1, "e", "k3", "v3")
         )
       end},
      {"xmlelement-child",
       fn ->
         two_author(
           Doc.new(client_id: 100)
           |> XMLElement.new_element("e", "p")
           |> XMLElement.set_attribute("e", "k", "v"),
           &XMLElement.insert_child(&1, "e", 0, :text)
         )
       end},
      {"xmlfragment-child",
       fn ->
         two_author(
           Doc.new(client_id: 100)
           |> XMLFragment.new_fragment("f")
           |> XMLFragment.insert_child("f", 0, {:element, "b"}),
           & &1
         )
       end},
      {"multi-type",
       fn ->
         two_author(
           Doc.new(client_id: 100) |> Text.insert("t", 0, "ab") |> YMap.set("m", "k", "v"),
           &Array.insert(&1, "a", 0, ["q"])
         )
       end},
      {
        "single-author-degenerate",
        # ⚠️ KEPT DELIBERATELY. The identity-span case is a real caller
        # situation, and it must still be classified — it just must never be the
        # ONLY case, which is what it was before this was measured.
        fn -> materialized(Text.insert(Doc.new(client_id: 100), "t", 0, "solo")) end
      },
      {"empty", fn -> Doc.new(client_id: 100) end}
    ]
  end

  defp edits do
    [
      {"text-insert", fn d -> Text.insert(d, "t", 0, "Z") end},
      {"text-delete", fn d -> Text.delete(d, "t", 0, 1) end},
      {"map-set", fn d -> YMap.set(d, "m", "new", "9") end},
      {"map-delete", fn d -> YMap.delete(d, "m", "a") end},
      {"array-insert", fn d -> Array.insert(d, "a", 0, ["N"]) end},
      {"array-delete", fn d -> Array.delete(d, "a", 0, 1) end},
      {"xmltext-ins", fn d -> XMLText.insert(d, "x", 0, "Z") end},
      {"xml-attr-set", fn d -> XMLElement.set_attribute(d, "e", "k2", "v2") end},
      {"xml-add-kid", fn d -> XMLElement.insert_child(d, "e", 0, :text) end},
      {"new-type", fn d -> Text.insert(d, "brand-new", 0, "fresh") end}
    ]
  end

  # One cell of the matrix, classified, in one direction.
  #
  # ⭐ Invariant 6: *"Reorienting a bridge swaps presentation, not capability:
  # the same edits can cross in both directions."* For `:right` the roles simply
  # exchange — the edit is authored on the DERIVED document and the origin
  # document is the destination. Nothing else about the cell changes, which is
  # what makes the two halves comparable.
  defp classify(sbuild, ebuild, direction) do
    origin = sbuild.()

    case Snapshotter.snapshot(origin) do
      {:error, e} ->
        {:no_bridge, e.code}

      {:ok, snap} ->
        {:ok, derived} = Encoding.apply_update(Doc.new(client_id: 0), snap.update)
        {:ok, bridge} = Bridge.attach(snap.derivation, "ep:o", "ep:d", Algorithm.snapshot())

        {src, dest} =
          case direction do
            :left -> {origin, derived}
            :right -> {derived, origin}
          end

        r = replica(src, 777)
        edited = ebuild.(r)
        update = delta(edited, src)

        case Yepochs.cross(bridge, update, src, dest,
               from: direction,
               author: 5150,
               receipt_ref: "totality"
             ) do
          {:ok, crossing} ->
            # ⭐ THE VERDICT IS THE DESTINATION, not the byte count. A crossing
            # that returns plausible bytes the destination cannot reproduce the
            # source's value from is a wrong answer, not a defined behaviour.
            case Encoding.apply_update(dest, crossing.update) do
              {:ok, after_dest} ->
                if observable(after_dest) == observable(edited),
                  do: {:crossed, crossing.mode},
                  else: {:wrong_at_destination, crossing.mode}

              other ->
                {:destination_rejected_update, other}
            end

          {:error, e} ->
            {:refused, e.code}
        end
    end
  end

  describe "every case is classified" do
    for sname <- @shape_names, ename <- @edit_names, direction <- [:left, :right] do
      @sname sname
      @ename ename
      @direction direction

      test "#{sname} / #{ename} / from #{direction}" do
        {_, sbuild} = Enum.find(shapes(), &(elem(&1, 0) == @sname))
        {_, ebuild} = Enum.find(edits(), &(elem(&1, 0) == @ename))
        result = classify(sbuild, ebuild, @direction)

        if @sname in @impossible_shapes do
          assert {:no_bridge, :unsupported_content} = result,
                 "#{@sname} is listed impossible (design 0006 §2) but produced #{inspect(result)}"
        else
          assert {:crossed, mode} = result,
                 "#{@sname} has no defined behaviour for this edit from #{@direction}: " <>
                   inspect(result)

          assert mode in [:translated, :reauthored, :absorbed]
        end
      end
    end
  end

  test "invariant 6: every shape/edit that crosses one way crosses the other" do
    # ⭐ The doubled cells above would each pass while quietly disagreeing about
    # WHICH cells work in which direction. This states the invariant directly:
    # capability is a property of the pair, not of the orientation.
    disagreements =
      for sname <- @shape_names, ename <- @edit_names do
        {_, sbuild} = Enum.find(shapes(), &(elem(&1, 0) == sname))
        {_, ebuild} = Enum.find(edits(), &(elem(&1, 0) == ename))
        l = classify(sbuild, ebuild, :left) |> elem(0)
        r = classify(sbuild, ebuild, :right) |> elem(0)
        if l == r, do: nil, else: {sname, ename, left: l, right: r}
      end
      |> Enum.reject(&is_nil/1)

    assert disagreements == [],
           "these cells cross in one direction only, which invariant 6 forbids: " <>
             inspect(disagreements)
  end

  test "the corpus is not degenerate: at least one span is a real remapping" do
    # ⛔ THE GUARD THAT WOULD HAVE CAUGHT THE FIRST VERSION OF THIS SUITE.
    # A single-author document snapshots under its own client id, so every span
    # comes out as an identity mapping and a translator that ignored the bridge
    # entirely would pass every cell — exactly what invariant 9 forbids.
    remapping =
      for sname <- @shape_names, sname != "single-author-degenerate" do
        {_, sbuild} = Enum.find(shapes(), &(elem(&1, 0) == sname))

        case Snapshotter.snapshot(sbuild.()) do
          {:ok, snap} ->
            Enum.any?(snap.derivation.spans, fn sp ->
              {sp.left_client, sp.left_clock} != {sp.right_client, sp.right_clock}
            end)

          {:error, _} ->
            :no_bridge
        end
      end

    assert Enum.any?(remapping, &(&1 == true)),
           "every shape produced identity-only spans — the matrix cannot distinguish a real " <>
             "translation from raw coordinate pass-through"
  end

  test "direction is load-bearing where a non-identity span carries the anchor" do
    # ⭐ Mutation testing said the direction axis was decoration: mislabelling
    # `from:` changed nothing across all 240 cells. The cause was the DATA, not
    # the axis — every edit anchored inside an identity-mapped span, where a
    # left lookup and a right lookup return the same coordinate.
    #
    # Here the anchor sits in the remapped span (left {200,0} ↔ right {100,5}).
    base = materialized(Text.insert(Doc.new(client_id: 100), "t", 0, "hello"))
    second = Text.insert(replica(base, 200), "t", 5, "!!")
    {:ok, merged} = Encoding.apply_update(base, Encoding.encode_update(second))
    origin = materialized(merged)

    {:ok, snap} = Snapshotter.snapshot(origin)
    {:ok, derived} = Encoding.apply_update(Doc.new(client_id: 0), snap.update)
    {:ok, bridge} = Bridge.attach(snap.derivation, "ep:o", "ep:d", Algorithm.snapshot())

    assert Enum.any?(snap.derivation.spans, fn sp ->
             {sp.left_client, sp.left_clock} != {sp.right_client, sp.right_clock}
           end),
           "premise: this fixture must produce a remapped span"

    edited = Text.insert(replica(derived, 777), "t", 6, "Z")
    update = delta(edited, derived)
    opts = [author: 5150, receipt_ref: "direction"]

    {:ok, correct} = Yepochs.cross(bridge, update, derived, origin, [from: :right] ++ opts)
    {:ok, mislabelled} = Yepochs.cross(bridge, update, derived, origin, [from: :left] ++ opts)

    assert correct.mode == :translated,
           "a correctly-oriented crossing over covered coordinates must preserve identity"

    assert mislabelled.mode == :reauthored,
           "a mislabelled crossing must NOT silently translate through the wrong side of the " <>
             "correspondence; invariant 10 requires it to fall back"

    # ⭐ And the fallback is sensible, not merely safe: the destination still
    # ends up with the right value. What is lost is authorship identity.
    for crossing <- [correct, mislabelled] do
      {:ok, after_dest} = Encoding.apply_update(origin, crossing.update)
      assert Text.to_string(after_dest, "t") == "hello!Z!"
    end
  end

  test "the name lists match the builder lists" do
    # ⛔ Without this, a shape renamed in `shapes/0` but not in `@shape_names`
    # silently shrinks the matrix — a corpus that got smaller looks exactly like
    # a corpus that passed.
    assert Enum.sort(Enum.map(shapes(), &elem(&1, 0))) == Enum.sort(@shape_names)
    assert Enum.sort(Enum.map(edits(), &elem(&1, 0))) == Enum.sort(@edit_names)
    assert Enum.all?(@impossible_shapes, &(&1 in @shape_names))
  end

  test "the impossible shapes are impossible for the recorded reason, not by accident" do
    # ⭐ Positive control on the impossibility itself: the mechanism is an item
    # whose CONTENT is a nested type instance. The replay drops it, so the
    # derived document cannot hold the source's observable content and no
    # correspondence exists to bridge.
    for name <- @impossible_shapes do
      {^name, build} = Enum.find(shapes(), &(elem(&1, 0) == name))
      src = build.()

      assert Enum.any?(BlockStore.all_items(src.store), &match?({:type, _}, &1.content)),
             "#{name} was expected to hold a nested-type child; it does not, so this test is " <>
               "no longer measuring the recorded mechanism"

      {update, _} = Doc.snapshot_update(%{src | client_id: 0})
      {:ok, replayed} = Encoding.apply_update(Doc.new(client_id: 0), update)

      assert Enum.all?(
               BlockStore.all_items(replayed.store),
               &(not match?({:type, _}, &1.content))
             ),
             "#{name} now survives the replay — the impossibility has been LIFTED and " <>
               "design 0006 §2 must be revisited rather than this list extended"
    end
  end

  test "attributes are NOT part of the impossibility — the boundary is nested-type content" do
    # Control in the other direction: an XML element with an attribute and no
    # children bridges fine. Without this, "XML cannot bridge" would read as the
    # rule, and it is not the rule.
    src =
      materialized(
        Doc.new(client_id: 100)
        |> XMLElement.new_element("e", "p")
        |> XMLElement.set_attribute("e", "k", "v")
      )

    assert {:ok, _snapshot} = Snapshotter.snapshot(src)
  end
end
