defmodule Yepochs.UnsupportedContentCauseTest do
  @moduledoc """
  ⭐ **"Do something sensible" includes making a refusal actionable.**

  `:unsupported_content` currently has two very different causes that produce
  the *same* error, and a caller cannot tell them apart:

    * **`:unregistered_types`** — the doc's type registry does not describe the
      content its store holds, so the replay has nothing to iterate. This is a
      caller-side condition with a one-line remedy, and the content is perfectly
      bridgeable once it is met.
    * **`:nested_type_children`** — the doc holds an item whose content is a
      nested type instance. The replay drops those, so **no bridge over this
      document can exist** under this algorithm. No remedy; see design 0006 §2.

  ⛔ Reporting both as a bare `:unsupported_content` tells a caller with a
  trivially fixable doc exactly what it tells a caller facing a hard limit.
  """
  use ExUnit.Case, async: true

  alias Yelixer.Doc
  alias Yelixer.Encoding
  alias Yelixer.Types.Text
  alias Yelixer.Types.XMLElement
  alias Yepochs.Snapshotter

  test "a locally-authored doc is refused with a cause naming the remedy" do
    # Never round-tripped: items sit in client_pending and `types` is empty.
    local = Doc.new(client_id: 100) |> Text.insert("t", 0, "hello")
    assert local.types == %{}, "premise: a locally-authored doc has an empty type registry"

    assert {:error, error} = Snapshotter.snapshot(local)
    assert error.code == :unsupported_content
    assert error.details.cause == :unregistered_types
    assert error.details.remedy =~ "apply_update"
  end

  test "and the same content bridges once the registry describes it" do
    # ⭐ Positive control: the refusal above is about the REGISTRY, not the
    # content. Without this the first test would also pass if text were simply
    # unsupported.
    local = Doc.new(client_id: 100) |> Text.insert("t", 0, "hello")

    {:ok, materialized} =
      Encoding.apply_update(Doc.new(client_id: 100), Encoding.encode_update(local))

    assert {:ok, _snapshot} = Snapshotter.snapshot(materialized)
  end

  test "a nested-type child is refused with the cause that has no remedy" do
    local =
      Doc.new(client_id: 100)
      |> XMLElement.new_element("e", "p")
      |> XMLElement.insert_child("e", 0, :text)

    {:ok, doc} = Encoding.apply_update(Doc.new(client_id: 100), Encoding.encode_update(local))

    assert {:error, error} = Snapshotter.snapshot(doc)
    assert error.code == :unsupported_content
    assert error.details.cause == :nested_type_children
    refute Map.has_key?(error.details, :remedy), "this cause has no caller-side remedy"
  end

  test "a doc in BOTH states reports the cause that has no remedy" do
    # ⛔ Mutation testing caught this one missing. Swapping the two `cond`
    # branches left every other test green, because no case held both
    # conditions at once — so the ordering the code comments justify was
    # asserted nowhere.
    #
    # `Text.insert/4` on a fresh doc leaves "t" out of the registry, while
    # `insert_child/4` registers its own names — so this doc is unregistered
    # AND holds a nested-type child.
    both =
      Doc.new(client_id: 100)
      |> Text.insert("t", 0, "hi")
      |> XMLElement.new_element("e", "p")
      |> XMLElement.insert_child("e", 0, :text)

    assert Map.has_key?(both.types, "e"), "premise: the element IS registered"
    refute Map.has_key?(both.types, "t"), "premise: the text is NOT registered"

    assert {:error, error} = Snapshotter.snapshot(both)

    assert error.details.cause == :nested_type_children,
           "a doc that also holds an unbridgeable child must not be sent round a " <>
             "round-trip that cannot help it"

    refute Map.has_key?(error.details, :remedy)
  end

  test "the counts survive alongside the cause" do
    # The numeric evidence is what proved the loss in the first place; a
    # friendlier error must not discard it.
    local =
      Doc.new(client_id: 100)
      |> XMLElement.new_element("e", "p")
      |> XMLElement.insert_child("e", 0, :text)

    {:ok, doc} = Encoding.apply_update(Doc.new(client_id: 100), Encoding.encode_update(local))
    assert {:error, error} = Snapshotter.snapshot(doc)

    assert %{source_clocks: s, traversed_clocks: t, derived_clocks: d} = error.details
    assert is_integer(s) and is_integer(t) and is_integer(d)
    assert s > d, "the source must hold more than the derivation covers, or nothing was lost"
  end
end
