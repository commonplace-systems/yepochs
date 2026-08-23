defmodule Yepochs.Test.Updates do
  @moduledoc """
  Builds REAL Yjs updates with yelixer, so Tier 1 tests exercise the actual wire
  format rather than a hand-rolled approximation of it.

  ⚠️ `Encoding.encode_update/1` emits the doc's FULL STATE, not a delta. Use
  `delta/2` when a test needs an update that genuinely depends on state it does
  not carry.
  """

  alias Yelixer.BlockStore
  alias Yelixer.Doc
  alias Yelixer.Encoding
  alias Yelixer.Types.Text

  @doc "A base document with `text` in type `t`, authored by `client`."
  def base(text, client \\ 100) do
    Doc.new(client_id: client) |> Text.insert("t", 0, text)
  end

  @doc "Full-state encoding of a doc."
  def full(%Doc{} = doc), do: Encoding.encode_update(doc)

  @doc "A true delta: only what `doc` has beyond `since`."
  def delta(%Doc{} = doc, %Doc{} = since),
    do: Encoding.encode_diff(doc, BlockStore.state_vector(since.store))

  @doc "A replica of `base_doc` under a new client id, ready to be edited."
  def replica(%Doc{} = base_doc, client) do
    d = Doc.new(client_id: client)
    {:ok, d} = Encoding.apply_update(d, full(base_doc))
    d
  end

  @doc "An update inserting `text` at `index`, authored by `client` over `base_doc`."
  def insert_delta(%Doc{} = base_doc, client, index, text) do
    r = replica(base_doc, client)
    delta(Text.insert(r, "t", index, text), base_doc)
  end

  @doc "An update deleting `len` characters at `index`, authored by `client` over `base_doc`."
  def delete_delta(%Doc{} = base_doc, client, index, len) do
    r = replica(base_doc, client)
    delta(Text.delete(r, "t", index, len), base_doc)
  end
end
