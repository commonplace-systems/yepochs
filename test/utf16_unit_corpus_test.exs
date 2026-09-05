defmodule Yepochs.Utf16UnitCorpusTest do
  @moduledoc """
  These concrete clocks are UTF-16 code units, recorded against yelixer
  `b688b6b1`. They are expected to move if the pin ever goes back to a
  grapheme-minting yelixer.
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
    {:ok, snapshot} = Yepochs.snapshot(source(text), [])
    [span] = snapshot.derivation.spans
    span
  end

  defp astral_delete_fixture do
    original = source(@astral <> @astral)

    {:ok, replica} =
      Encoding.apply_update(Doc.new(client_id: 200), Encoding.encode_update(original))

    # 😀 is one surrogate pair, so deleting one grapheme consumes 2 UTF-16 units.
    edited = Text.delete(replica, "t", 0, 2)
    update = Encoding.encode_diff(edited, BlockStore.state_vector(original.store))

    {original, update}
  end

  defp bridge_for(original) do
    {:ok, snapshot} = Yepochs.snapshot(original, [])

    {:ok, bridge} =
      Bridge.attach(snapshot.derivation, "origin", "derived", Algorithm.snapshot())

    bridge
  end

  defp decoded_astral_delete do
    {_original, update} = astral_delete_fixture()
    {:ok, decoded} = Update.decode(update)
    decoded
  end

  defp translated_astral_delete do
    {original, update} = astral_delete_fixture()
    bridge = bridge_for(original)
    {:ok, translated} = Yepochs.translate(update, bridge, :left, [])
    {:ok, translated_update} = Update.decode(translated.update)
    translated_update
  end

  defp astral_insertion_fixture do
    original = source(@astral <> "A")
    bridge = bridge_for(original)

    {:ok, replica} =
      Encoding.apply_update(Doc.new(client_id: 200), Encoding.encode_update(original))

    # 😀 occupies [0, 2) and A occupies [2, 3), so index 2 is between them.
    edited = Text.insert(replica, "t", 2, "X")
    update = Encoding.encode_diff(edited, BlockStore.state_vector(original.store))

    {:ok, translated} = Yepochs.translate(update, bridge, :left, [])
    {:ok, translated_update} = Update.decode(translated.update)
    [item] = translated_update.items
    item
  end

  test "astral snapshot span uses two UTF-16 units" do
    # 😀 U+1F600 is one surrogate pair: 2 UTF-16 units.
    assert %Span{length: 2} = snapshot_span(@astral)
  end

  test "combining snapshot span uses two UTF-16 units" do
    # "e" + U+0301 are two BMP scalars: 1 + 1 = 2 UTF-16 units.
    assert %Span{length: 2} = snapshot_span(@combining)
  end

  test "ZWJ snapshot span uses five UTF-16 units" do
    # 👩‍💻 is U+1F469 + ZWJ + U+1F4BB: 2 + 1 + 2 = 5 UTF-16 units.
    assert %Span{length: 5} = snapshot_span(@zwj)
  end

  test "BMP snapshot span remains the unit-agreement control" do
    # あ U+3042 is one BMP scalar, so it must stay 1 under both units; a change
    # here indicates an instrument defect, not a UTF-16-versus-grapheme finding.
    assert %Span{length: 1} = snapshot_span(@bmp)
  end

  test "two astral graphemes have a four-unit text length" do
    # 😀😀 is two surrogate pairs: 2 + 2 = 4 UTF-16 units.
    assert Text.length(source(@astral <> @astral), "t") == 4
  end

  test "deleting one astral grapheme records a two-unit interval" do
    # The first 😀 is one surrogate pair at [0, 2): start 0, length 2.
    assert decoded_astral_delete().delete_set.clients == %{100 => [{0, 2}]}
  end

  test "translation preserves the astral delete-set interval" do
    # Translation must preserve the first 😀 interval [0, 2): start 0, length 2.
    assert translated_astral_delete().delete_set.clients == %{100 => [{0, 2}]}
  end

  test "astral delete-set endpoint agrees with its snapshot coordinates" do
    span = snapshot_span(@astral <> @astral)
    %{100 => [{delete_start, delete_length}]} = decoded_astral_delete().delete_set.clients

    # 😀😀 spans [0, 4), since two pairs are 4 units; the deleted first 😀 spans
    # [0, 2), since one pair is 2 units. Its endpoint must therefore be 2.
    assert {span.left_clock, delete_start + delete_length, span.left_clock + span.length} ==
             {0, 2, 4}
  end

  test "astral plus BMP text has a three-unit length" do
    # 😀A is one surrogate pair plus one BMP scalar: 2 + 1 = 3 UTF-16 units.
    assert Text.length(source(@astral <> "A"), "t") == 3
  end

  test "astral plus BMP snapshot span has three units" do
    # 😀A is one surrogate pair plus one BMP scalar: 2 + 1 = 3 UTF-16 units.
    assert %Span{length: 3} = snapshot_span(@astral <> "A")
  end

  test "translated insertion left anchor is the astral item's LAST unit" do
    # ⭐ CORRECTED, and the correction is the finding. `origin` is the ID of the
    # character immediately to the LEFT -- the left neighbour's LAST unit, not its
    # first. 😀 occupies [0, 2), so its last unit is clock 1.
    #
    # ⛔ The value was NOT copied from the failure output. One rule with no free
    # parameters explains BOTH pins: origin = start + length - 1.
    #   graphemes (bc35a0e9): 😀 = 1 unit  [0,1) -> 0 + 1 - 1 = 0  (observed 0)
    #   UTF-16    (b688b6b1): 😀 = 2 units [0,2) -> 0 + 2 - 1 = 1  (observed 1)
    # Under graphemes "start" and "last unit" coincide, so the old expectation of
    # 0 was right for the wrong reason; UTF-16 separates them and exposes it.
    assert astral_insertion_fixture().origin == %ID{client: 100, clock: 1}
  end

  test "translated insertion right anchor starts after the astral item" do
    # 😀 is one surrogate pair occupying [0, 2), so the following A starts at 2.
    assert astral_insertion_fixture().right_origin == %ID{client: 100, clock: 2}
  end
end
