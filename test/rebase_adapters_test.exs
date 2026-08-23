defmodule Yepochs.RebaseAdaptersTest do
  use ExUnit.Case, async: true

  alias Yelixer.Doc
  alias Yelixer.Encoding
  alias Yelixer.Types.Array
  alias Yelixer.Types.Text
  alias Yelixer.Types.YMap
  alias Yepochs.Algorithm
  alias Yepochs.Bridge
  alias Yepochs.Derivation
  alias Yepochs.Error
  alias Yepochs.Rebase

  defp mat(%Doc{} = d) do
    {:ok, m} = Encoding.apply_update(Doc.new(client_id: d.client_id), Encoding.encode_update(d))
    m
  end

  defp empty_bridge do
    {:ok, d} = Derivation.new([])
    {:ok, b} = Bridge.attach(d, "o", "n", Algorithm.snapshot())
    b
  end

  defp applied(%Doc{} = target, %{update: <<>>}), do: target

  defp applied(%Doc{} = target, %{update: u}) do
    {:ok, d} = Encoding.apply_update(target, u)
    d
  end

  defp reauthor(before, edited, target) do
    Rebase.rebase(before, edited, target, author: 9000)
  end

  defp cross(update, before, target) do
    Yepochs.cross(empty_bridge(), update, before, target,
      from: :left,
      author: 9000,
      receipt_ref: "r1"
    )
  end

  describe "Y.Map adapter — §19.2" do
    test "carries a NEW key across" do
      before = mat(YMap.set(Doc.new(client_id: 100), "m", "a", "1"))
      edited = mat(YMap.set(before, "m", "b", "2"))
      target = mat(YMap.set(Doc.new(client_id: 500), "m", "a", "1"))

      assert {:ok, r} = reauthor(before, edited, target)
      assert r.outcome == :applied
      out = applied(target, r)
      assert YMap.get(out, "m", "b") == "2"
      assert YMap.get(out, "m", "a") == "1"
    end

    test "carries a CHANGED value across" do
      before = mat(YMap.set(Doc.new(client_id: 100), "m", "a", "1"))
      edited = mat(YMap.set(before, "m", "a", "changed"))
      target = mat(YMap.set(Doc.new(client_id: 500), "m", "a", "1"))

      assert {:ok, r} = reauthor(before, edited, target)
      assert YMap.get(applied(target, r), "m", "a") == "changed"
    end

    test "carries a DELETED key across" do
      before = mat(YMap.set(YMap.set(Doc.new(client_id: 100), "m", "a", "1"), "m", "b", "2"))
      edited = mat(YMap.delete(before, "m", "b"))
      target = mat(YMap.set(YMap.set(Doc.new(client_id: 500), "m", "a", "1"), "m", "b", "2"))

      assert {:ok, r} = reauthor(before, edited, target)
      out = applied(target, r)
      assert YMap.get(out, "m", "b") == nil
      assert YMap.get(out, "m", "a") == "1"
    end

    test "ABSORBS a change already true at the destination" do
      before = mat(YMap.set(Doc.new(client_id: 100), "m", "a", "1"))
      edited = mat(YMap.set(before, "m", "b", "2"))
      target = mat(YMap.set(YMap.set(Doc.new(client_id: 500), "m", "a", "1"), "m", "b", "2"))

      assert {:ok, r} = reauthor(before, edited, target)
      assert r.outcome == :absorbed
      assert r.update == <<>>
    end

    test "a NEW key needs no correspondence, so it crosses on the STRICT path" do
      # Its parent is a named root, not an item coordinate, and it anchors on
      # nothing -- so there is no external reference for a bridge to resolve and
      # strict translation applies even across an empty bridge. Preserving the
      # authored identity is strictly better than re-authoring it.
      before = mat(YMap.set(Doc.new(client_id: 100), "m", "a", "1"))
      edited = mat(YMap.set(before, "m", "b", "2"))
      target = mat(YMap.set(Doc.new(client_id: 500), "m", "a", "1"))
      update = Encoding.encode_diff(edited, Yelixer.BlockStore.state_vector(before.store))

      assert {:ok, c} = cross(update, before, target)
      assert c.mode == :translated

      {:ok, out} = Encoding.apply_update(target, c.update)
      assert YMap.get(out, "m", "b") == "2"
      assert YMap.get(out, "m", "a") == "1"
    end

    test "CHANGING an existing key needs the old item's id, so it re-authors" do
      # Overwriting tombstones the previous item, and that delete-set coordinate
      # is external -- an empty bridge cannot resolve it, so the crossing falls
      # back rather than failing.
      before = mat(YMap.set(Doc.new(client_id: 100), "m", "a", "1"))
      edited = mat(YMap.set(before, "m", "a", "changed"))
      target = mat(YMap.set(Doc.new(client_id: 500), "m", "a", "1"))
      update = Encoding.encode_diff(edited, Yelixer.BlockStore.state_vector(before.store))

      assert {:ok, c} = cross(update, before, target)
      assert c.mode == :reauthored

      {:ok, out} = Encoding.apply_update(target, c.update)
      assert YMap.get(out, "m", "a") == "changed"
    end
  end

  describe "Y.Array adapter — §19.2" do
    test "carries an APPEND across" do
      before = mat(Array.insert(Doc.new(client_id: 100), "arr", 0, ["x", "y"]))
      edited = mat(Array.insert(before, "arr", 2, ["z"]))
      target = mat(Array.insert(Doc.new(client_id: 500), "arr", 0, ["x", "y"]))

      assert {:ok, r} = reauthor(before, edited, target)
      assert Array.to_list(applied(target, r), "arr") == ["x", "y", "z"]
    end

    test "carries a middle INSERT across" do
      before = mat(Array.insert(Doc.new(client_id: 100), "arr", 0, ["x", "z"]))
      edited = mat(Array.insert(before, "arr", 1, ["y"]))
      target = mat(Array.insert(Doc.new(client_id: 500), "arr", 0, ["x", "z"]))

      assert {:ok, r} = reauthor(before, edited, target)
      assert Array.to_list(applied(target, r), "arr") == ["x", "y", "z"]
    end

    test "carries a DELETE across" do
      before = mat(Array.insert(Doc.new(client_id: 100), "arr", 0, ["x", "y", "z"]))
      edited = mat(Array.delete(before, "arr", 1, 1))
      target = mat(Array.insert(Doc.new(client_id: 500), "arr", 0, ["x", "y", "z"]))

      assert {:ok, r} = reauthor(before, edited, target)
      assert Array.to_list(applied(target, r), "arr") == ["x", "z"]
    end

    test "⛔ an array change is NOT mistaken for a no-op" do
      # Y.Text.to_string/2 renders an array plane as "", so a text-only adapter
      # sees no difference and reports :absorbed -- returning an empty update for
      # a real edit. A wrong answer, not an error.
      before = mat(Array.insert(Doc.new(client_id: 100), "arr", 0, ["x"]))
      edited = mat(Array.insert(before, "arr", 1, ["y"]))
      target = mat(Array.insert(Doc.new(client_id: 500), "arr", 0, ["x"]))

      assert {:ok, r} = reauthor(before, edited, target)
      refute r.outcome == :absorbed, "the array edit must not be reported as already satisfied"
      assert Array.to_list(applied(target, r), "arr") == ["x", "y"]
    end
  end

  describe "a document with several planes" do
    test "carries text, map and array changes together" do
      b = Doc.new(client_id: 100) |> Text.insert("t", 0, "ab")
      b = YMap.set(b, "m", "k", "v")
      before = mat(Array.insert(b, "arr", 0, ["x"]))

      e = Text.insert(before, "t", 2, "c")
      e = YMap.set(e, "m", "k2", "v2")
      edited = mat(Array.insert(e, "arr", 1, ["y"]))

      t = Doc.new(client_id: 500) |> Text.insert("t", 0, "ab")
      t = YMap.set(t, "m", "k", "v")
      target = mat(Array.insert(t, "arr", 0, ["x"]))

      assert {:ok, r} = reauthor(before, edited, target)
      out = applied(target, r)

      assert Text.to_string(out, "t") == "abc"
      assert YMap.get(out, "m", "k2") == "v2"
      assert Array.to_list(out, "arr") == ["x", "y"]
    end
  end

  describe "refusal rather than flattening" do
    test "reports a conflict when the destination diverged from what the edit replaces" do
      before = mat(Text.insert(Doc.new(client_id: 100), "t", 0, "abcdef"))
      edited = mat(Text.delete(before, "t", 2, 2))
      diverged = mat(Text.insert(Doc.new(client_id: 500), "t", 0, "abZZef"))

      assert {:error, %Error{code: :rebase_conflict}} = reauthor(before, edited, diverged)
    end

    test "reports a conflict when the ARRAY destination no longer holds what the edit removes" do
      before = mat(Array.insert(Doc.new(client_id: 100), "arr", 0, ["x", "y", "z"]))
      edited = mat(Array.delete(before, "arr", 1, 1))
      diverged = mat(Array.insert(Doc.new(client_id: 500), "arr", 0, ["x", "Q", "z"]))

      assert {:error, %Error{code: :rebase_conflict} = err} = reauthor(before, edited, diverged)
      assert err.details.removed == ["y"]
    end

    test "refuses a plane that CHANGES KIND between before and edited" do
      # A named type whose sequence plane holds text in `before` and array
      # values in `edited` is outside what any single positional adapter can
      # deterministically apply. §19.2's rule is refuse, not flatten.
      before = mat(Text.insert(Doc.new(client_id: 100), "p", 0, "abc"))
      edited = mat(Yelixer.Types.Array.insert(Doc.new(client_id: 100), "p", 0, ["x", "y"]))
      target = mat(Text.insert(Doc.new(client_id: 500), "p", 0, "abc"))

      assert {:error, %Error{code: :unsupported_crossing_content, phase: :rebase} = err} =
               reauthor(before, edited, target)

      assert err.details.type == "p"
      assert err.details.before == :text
      assert err.details.after == :array
    end

    test "requires an explicit author id" do
      before = mat(Text.insert(Doc.new(client_id: 100), "t", 0, "ab"))
      edited = mat(Text.insert(before, "t", 2, "c"))
      assert {:error, %Error{code: :invalid_rebase_input}} = Rebase.rebase(before, edited, before, [])
    end
  end
end

defmodule Yepochs.XmlRebaseTest do
  @moduledoc """
  §19.2 names Y.XML as an adapter target. Measured first: of the XML shapes,
  only **XMLText** and **element attributes** survive the snapshot replay at all
  — an element's children are dropped by it, so `Yepochs.Snapshotter` refuses
  such a document (§10.2). ⇒ An adapter is only meaningful for the surface that
  can hold a bridge, and these tests establish which of that surface the
  existing plane dispatch already covers.
  """
  use ExUnit.Case, async: true

  alias Yelixer.Doc
  alias Yelixer.Encoding
  alias Yelixer.Types.XMLElement
  alias Yelixer.Types.XMLText
  alias Yepochs.Error
  alias Yepochs.Rebase

  defp mat(%Doc{} = d) do
    {:ok, m} = Encoding.apply_update(Doc.new(client_id: d.client_id), Encoding.encode_update(d))
    m
  end

  defp reauthor(b, e, t), do: Rebase.rebase(b, e, t, author: 9000)

  defp applied(%Doc{} = target, %{update: <<>>}), do: target

  defp applied(%Doc{} = target, %{update: u}) do
    {:ok, d} = Encoding.apply_update(target, u)
    d
  end

  describe "XMLText crosses on the text plane" do
    test "an insertion is re-authored at the destination" do
      before = mat(XMLText.insert(Doc.new(client_id: 100), "xt", 0, "hello"))
      edited = mat(XMLText.insert(before, "xt", 5, " world"))
      target = mat(XMLText.insert(Doc.new(client_id: 500), "xt", 0, "hello"))

      assert {:ok, r} = reauthor(before, edited, target)
      assert r.outcome == :applied
      assert XMLText.to_string(applied(target, r), "xt") == "hello world"
    end

    test "a deletion is re-authored at the destination" do
      before = mat(XMLText.insert(Doc.new(client_id: 100), "xt", 0, "abcdef"))
      edited = mat(XMLText.delete(before, "xt", 2, 2))
      target = mat(XMLText.insert(Doc.new(client_id: 500), "xt", 0, "abcdef"))

      assert {:ok, r} = reauthor(before, edited, target)
      assert XMLText.to_string(applied(target, r), "xt") == "abef"
    end
  end

  describe "element attributes cross on the map plane" do
    defp element_with(attrs, client) do
      d = XMLElement.new_element(Doc.new(client_id: client), "el", "div")
      mat(Enum.reduce(attrs, d, fn {k, v}, acc -> XMLElement.set_attribute(acc, "el", k, v) end))
    end

    test "a new attribute is carried across" do
      before = element_with([{"class", "big"}], 100)
      edited = mat(XMLElement.set_attribute(before, "el", "id", "x1"))
      target = element_with([{"class", "big"}], 500)

      assert {:ok, r} = reauthor(before, edited, target)
      out = applied(target, r)
      assert XMLElement.get_attribute(out, "el", "id") == "x1"
      assert XMLElement.get_attribute(out, "el", "class") == "big"
    end

    test "a changed attribute value is carried across" do
      before = element_with([{"class", "big"}], 100)
      edited = mat(XMLElement.set_attribute(before, "el", "class", "small"))
      target = element_with([{"class", "big"}], 500)

      assert {:ok, r} = reauthor(before, edited, target)
      assert XMLElement.get_attribute(applied(target, r), "el", "class") == "small"
    end

    test "a deleted attribute is carried across" do
      before = element_with([{"class", "big"}, {"id", "x1"}], 100)
      edited = mat(XMLElement.delete_attribute(before, "el", "id"))
      target = element_with([{"class", "big"}, {"id", "x1"}], 500)

      assert {:ok, r} = reauthor(before, edited, target)
      out = applied(target, r)
      assert XMLElement.get_attribute(out, "el", "id") == nil
      assert XMLElement.get_attribute(out, "el", "class") == "big"
    end

    test "an unchanged element is absorbed" do
      before = element_with([{"class", "big"}], 100)
      target = element_with([{"class", "big"}], 500)

      assert {:ok, r} = reauthor(before, before, target)
      assert r.outcome == :absorbed
    end
  end

  describe "⛔ element CHILDREN are out of reach, and the boundary is asserted" do
    test "a document with element children cannot be snapshotted, so it can hold no bridge" do
      d = XMLElement.new_element(Doc.new(client_id: 100), "el", "div")
      src = mat(XMLElement.insert_child(d, "el", 0, {:element, "span"}))

      assert XMLElement.child_count(src, "el") == 1

      assert {:error, %Error{code: :unsupported_content}} = Yepochs.Snapshotter.snapshot(src, [])
    end
  end
end
