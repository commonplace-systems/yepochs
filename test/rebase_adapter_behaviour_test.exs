defmodule Yepochs.RebaseAdapterBehaviourTest do
  @moduledoc """
  Spec r2 §19.2 — *"Application-specific schemas MAY provide adapters through a
  behavior defined by `Yepochs.Rebase.Adapter`."* §15.1 further requires the
  crossing options to carry **the supported rebase adapter set**.

  Without the behaviour, that extension point does not exist: an application
  with a schema the built-in planes cannot express has no way in.
  """
  use ExUnit.Case, async: true

  alias Yelixer.Doc
  alias Yelixer.Encoding
  alias Yelixer.Types.Text
  alias Yepochs.Error
  alias Yepochs.Rebase

  defmodule UpcasingAdapter do
    @moduledoc "A stand-in application adapter: it owns the type named `owned`."
    @behaviour Yepochs.Rebase.Adapter

    @impl true
    def handles?(_before, _edited, name), do: name == "owned"

    @impl true
    def reauthor(before, edited, destination, name, _opts) do
      b = Text.to_string(before, name)
      e = Text.to_string(edited, name)

      if b == e do
        {:ok, destination, false}
      else
        # Deliberately distinguishable from the built-in text adapter.
        {:ok, Text.insert(destination, name, 0, String.upcase(e)), true}
      end
    end
  end

  defmodule RefusingAdapter do
    @behaviour Yepochs.Rebase.Adapter

    @impl true
    def handles?(_before, _edited, name), do: name == "owned"

    @impl true
    def reauthor(_before, _edited, _destination, name, _opts) do
      {:error, Error.new(:rebase_conflict, :rebase, details: %{type: name, from: :adapter})}
    end
  end

  defp mat(%Doc{} = d) do
    {:ok, m} = Encoding.apply_update(Doc.new(client_id: d.client_id), Encoding.encode_update(d))
    m
  end

  defp applied(%Doc{} = t, %{update: <<>>}), do: t

  defp applied(%Doc{} = t, %{update: u}) do
    {:ok, d} = Encoding.apply_update(t, u)
    d
  end

  test "a caller-supplied adapter takes precedence over the built-in plane dispatch" do
    before = mat(Text.insert(Doc.new(client_id: 100), "owned", 0, "ab"))
    edited = mat(Text.insert(before, "owned", 2, "c"))
    target = mat(Text.insert(Doc.new(client_id: 500), "owned", 0, "ab"))

    assert {:ok, r} =
             Rebase.rebase(before, edited, target, author: 9000, adapters: [UpcasingAdapter])

    # The built-in adapter would have produced "abc"; this one owns the type.
    assert Text.to_string(applied(target, r), "owned") == "ABCab"
  end

  test "types the adapter does not claim still use the built-in dispatch" do
    b = Text.insert(Doc.new(client_id: 100), "owned", 0, "ab")
    before = mat(Text.insert(b, "other", 0, "xy"))
    edited = mat(Text.insert(before, "other", 2, "z"))

    t = Text.insert(Doc.new(client_id: 500), "owned", 0, "ab")
    target = mat(Text.insert(t, "other", 0, "xy"))

    assert {:ok, r} =
             Rebase.rebase(before, edited, target, author: 9000, adapters: [UpcasingAdapter])

    assert Text.to_string(applied(target, r), "other") == "xyz"
  end

  test "an adapter's error propagates rather than falling through to the built-in" do
    before = mat(Text.insert(Doc.new(client_id: 100), "owned", 0, "ab"))
    edited = mat(Text.insert(before, "owned", 2, "c"))
    target = mat(Text.insert(Doc.new(client_id: 500), "owned", 0, "ab"))

    assert {:error, %Error{code: :rebase_conflict} = err} =
             Rebase.rebase(before, edited, target, author: 9000, adapters: [RefusingAdapter])

    assert err.details.from == :adapter
  end

  test "the built-in behaviour is unchanged when no adapters are supplied" do
    before = mat(Text.insert(Doc.new(client_id: 100), "owned", 0, "ab"))
    edited = mat(Text.insert(before, "owned", 2, "c"))
    target = mat(Text.insert(Doc.new(client_id: 500), "owned", 0, "ab"))

    assert {:ok, r} = Rebase.rebase(before, edited, target, author: 9000)
    assert Text.to_string(applied(target, r), "owned") == "abc"
  end

  test "adapters reach cross/5 through its options, as §15.1 requires" do
    before = mat(Text.insert(Doc.new(client_id: 100), "owned", 0, "ab"))
    edited = mat(Text.insert(before, "owned", 2, "c"))
    target = mat(Text.insert(Doc.new(client_id: 500), "owned", 0, "ab"))
    update = Encoding.encode_diff(edited, Yelixer.BlockStore.state_vector(before.store))

    {:ok, d} = Yepochs.Derivation.new([])
    {:ok, b} = Yepochs.Bridge.attach(d, "A", "B", Yepochs.Algorithm.snapshot())

    assert {:ok, c} =
             Yepochs.cross(b, update, before, target,
               from: :left,
               author: 9000,
               receipt_ref: "r",
               adapters: [UpcasingAdapter]
             )

    assert c.mode == :reauthored
    {:ok, out} = Encoding.apply_update(target, c.update)
    assert Text.to_string(out, "owned") == "ABCab"
  end
end
