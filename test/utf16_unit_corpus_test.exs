defmodule Yepochs.Utf16UnitCorpusTest do
  @moduledoc """
  These concrete clocks assume grapheme-based item lengths as recorded against
  yelixer `bc35a0e9`. They are expected to move if that pin advances past
  `eacd874`, where yelixer begins minting clocks in UTF-16 code units.
  """

  use ExUnit.Case, async: true

  alias Yelixer.BlockStore
  alias Yelixer.Doc
  alias Yelixer.Encoding
  alias Yelixer.ID
  alias Yelixer.Types.Text
  alias Yepochs.Algorithm
  alias Yepochs.Bridge
  alias Yepochs.Span
  alias Yepochs.Update

  @astral "😀"
  @combining "e\u0301"
  @zwj "👩‍💻"
  @bmp "あ"

  defp materialized(%Doc{} = doc) do
    {:ok, result} =
      Encoding.apply_update(Doc.new(client_id: doc.client_id), Encoding.encode_update(doc))

    result
  end

  defp source(text) do
    Doc.new(client_id: 100)
    |> Text.insert("t", 0, text)
    |> materialized()
  end

  defp snapshot_span(text) do
    assert {:ok, snapshot} = Yepochs.snapshot(source(text), [])
    assert [span] = snapshot.derivation.spans
    span
  end

  test "snapshot spans expose grapheme clocks for astral, combining, and ZWJ content" do
    assert %Span{
             left_client: 100,
             left_clock: 0,
             right_client: 100,
             right_clock: 0,
             length: 1
           } = snapshot_span(@astral)

    assert %Span{
             left_client: 100,
             left_clock: 0,
             right_client: 100,
             right_clock: 0,
             length: 1
           } = snapshot_span(@combining)

    assert %Span{
             left_client: 100,
             left_clock: 0,
             right_client: 100,
             right_clock: 0,
             length: 1
           } = snapshot_span(@zwj)
  end

  test "snapshot span for a BMP character is the unit-agreement control" do
    assert %Span{
             left_client: 100,
             left_clock: 0,
             right_client: 100,
             right_clock: 0,
             length: 1
           } = snapshot_span(@bmp)
  end

  test "deleting one of two astral graphemes records its clock interval" do
    original = source(@astral <> @astral)
    assert Text.length(original, "t") == 2

    {:ok, replica} =
      Encoding.apply_update(Doc.new(client_id: 200), Encoding.encode_update(original))

    one_astral_clock_length = div(Text.length(original, "t"), 2)
    edited = Text.delete(replica, "t", 0, one_astral_clock_length)
    update = Encoding.encode_diff(edited, BlockStore.state_vector(original.store))

    assert {:ok, decoded} = Update.decode(update)
    assert decoded.delete_set.clients == %{100 => [{0, 1}]}

    assert {:ok, snapshot} = Yepochs.snapshot(original, [])

    assert {:ok, bridge} =
             Bridge.attach(snapshot.derivation, "origin", "derived", Algorithm.snapshot())

    assert {:ok, translated} = Yepochs.translate(update, bridge, :left, [])
    assert {:ok, translated_update} = Update.decode(translated.update)
    assert translated_update.delete_set.clients == %{100 => [{0, 1}]}
  end

  test "translation rewrites anchors on both sides of an astral grapheme" do
    original = source(@astral <> "A")
    assert Text.length(original, "t") == 2

    assert {:ok, snapshot} = Yepochs.snapshot(original, [])

    assert [
             %Span{
               left_client: 100,
               left_clock: 0,
               right_client: 100,
               right_clock: 0,
               length: 2
             }
           ] = snapshot.derivation.spans

    assert {:ok, bridge} =
             Bridge.attach(snapshot.derivation, "origin", "derived", Algorithm.snapshot())

    {:ok, replica} =
      Encoding.apply_update(Doc.new(client_id: 200), Encoding.encode_update(original))

    insertion_index = Text.length(original, "t") - 1
    edited = Text.insert(replica, "t", insertion_index, "X")
    update = Encoding.encode_diff(edited, BlockStore.state_vector(original.store))

    assert {:ok, translated} = Yepochs.translate(update, bridge, :left, [])
    assert {:ok, translated_update} = Update.decode(translated.update)

    assert [item] = translated_update.items
    assert item.origin == %ID{client: 100, clock: 0}
    assert item.right_origin == %ID{client: 100, clock: 1}
  end
end
