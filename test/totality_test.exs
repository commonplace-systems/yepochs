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
                  xmlfragment-child multi-type empty)
  @edit_names ~w(text-insert text-delete map-set map-delete array-insert
                 array-delete xmltext-ins xml-attr-set xml-add-kid new-type)

  # A locally-authored Doc keeps its items in `client_pending` and has an EMPTY
  # type registry; the snapshot replay iterates that registry, so such a doc
  # snapshots to nothing and is refused. One round-trip materializes it.
  defp materialized(%Doc{} = d) do
    {:ok, m} = Encoding.apply_update(Doc.new(client_id: d.client_id), Encoding.encode_update(d))
    m
  end

  defp replica(%Doc{} = base, client) do
    d = Doc.new(client_id: client)
    {:ok, d} = Encoding.apply_update(d, Encoding.encode_update(base))
    d
  end

  defp delta(%Doc{} = doc, %Doc{} = since),
    do: Encoding.encode_diff(doc, BlockStore.state_vector(since.store))

  # Observable content, identity-free: every live item's parent, parent_sub and
  # content. Two docs holding the same observable value have equal lists even
  # though their item identities differ — which is what a crossing must achieve.
  defp observable(%Doc{} = d) do
    d.store
    |> BlockStore.all_items()
    |> Enum.reject(& &1.deleted)
    |> Enum.map(&{inspect(&1.parent), &1.parent_sub, inspect(&1.content)})
    |> Enum.sort()
  end

  defp shapes do
    [
      {"text-clean", fn -> Doc.new(client_id: 100) |> Text.insert("t", 0, "hello") end},
      {"text-tombstoned",
       fn ->
         Doc.new(client_id: 100) |> Text.insert("t", 0, "hello world") |> Text.delete("t", 5, 6)
       end},
      {"map-clean",
       fn -> Doc.new(client_id: 100) |> YMap.set("m", "a", "1") |> YMap.set("m", "b", "2") end},
      {"map-tombstoned",
       fn -> Doc.new(client_id: 100) |> YMap.set("m", "a", "1") |> YMap.set("m", "a", "2") end},
      {"array-clean", fn -> Doc.new(client_id: 100) |> Array.insert("a", 0, ["x", "y"]) end},
      {"array-tombstoned",
       fn ->
         Doc.new(client_id: 100)
         |> Array.insert("a", 0, ["x", "y", "z"])
         |> Array.delete("a", 1, 1)
       end},
      {"xmltext", fn -> Doc.new(client_id: 100) |> XMLText.insert("x", 0, "hi") end},
      {"xmlelement-attrs",
       fn ->
         Doc.new(client_id: 100)
         |> XMLElement.new_element("e", "p")
         |> XMLElement.set_attribute("e", "k", "v")
       end},
      {"xmlelement-child",
       fn ->
         Doc.new(client_id: 100)
         |> XMLElement.new_element("e", "p")
         |> XMLElement.insert_child("e", 0, :text)
       end},
      {"xmlfragment-child",
       fn ->
         Doc.new(client_id: 100)
         |> XMLFragment.new_fragment("f")
         |> XMLFragment.insert_child("f", 0, {:element, "b"})
       end},
      {"multi-type",
       fn ->
         Doc.new(client_id: 100)
         |> Text.insert("t", 0, "ab")
         |> YMap.set("m", "k", "v")
         |> Array.insert("a", 0, ["q"])
       end},
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

  # One cell of the matrix, classified.
  defp classify(sbuild, ebuild) do
    src = materialized(sbuild.())

    case Snapshotter.snapshot(src) do
      {:error, e} ->
        {:no_bridge, e.code}

      {:ok, snap} ->
        {:ok, dest} = Encoding.apply_update(Doc.new(client_id: 0), snap.update)
        {:ok, bridge} = Bridge.attach(snap.derivation, "ep:o", "ep:d", Algorithm.snapshot())
        r = replica(src, 777)
        edited = ebuild.(r)
        update = delta(edited, src)

        case Yepochs.cross(bridge, update, src, dest,
               from: :left,
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
    for sname <- @shape_names, ename <- @edit_names do
      @sname sname
      @ename ename

      test "#{sname} / #{ename}" do
        {_, sbuild} = Enum.find(shapes(), &(elem(&1, 0) == @sname))
        {_, ebuild} = Enum.find(edits(), &(elem(&1, 0) == @ename))
        result = classify(sbuild, ebuild)

        if @sname in @impossible_shapes do
          assert {:no_bridge, :unsupported_content} = result,
                 "#{@sname} is listed impossible (design 0006 §2) but produced #{inspect(result)}"
        else
          assert {:crossed, mode} = result,
                 "#{@sname} has no defined behaviour for this edit: #{inspect(result)}"

          assert mode in [:translated, :reauthored, :absorbed]
        end
      end
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
      src = materialized(build.())

      assert Enum.any?(observable(src), fn {_parent, _sub, content} ->
               String.starts_with?(content, "{:type,")
             end),
             "#{name} was expected to hold a nested-type child; it does not, so this test is " <>
               "no longer measuring the recorded mechanism"

      {update, _} = Doc.snapshot_update(%{src | client_id: 0})
      {:ok, replayed} = Encoding.apply_update(Doc.new(client_id: 0), update)

      assert observable(replayed) == [],
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
