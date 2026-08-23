# Is the existing derivation map a partial bijection? yepochs invariant 4 says a
# valid derivation must be one; pair_ids/2 collapses excess new ids onto the LAST
# source id, which would not be.
alias Yelixer.{Doc, Encoding, BlockStore}
alias Yelixer.Types.{Text, YMap, Array}

# Materialize: a locally-authored doc keeps its items in BlockStore.client_pending
# until something flushes them. Round-tripping through apply_update is how a
# reconstructed doc (the real caller's input) arrives.
materialize = fn %Doc{} = d ->
  fresh = Doc.new(client_id: d.client_id)
  {:ok, m} = Encoding.apply_update(fresh, Encoding.encode_update(d))
  m
end

report = fn name, source0 ->
  source = materialize.(source0)

  det = %{
    source
    | client_id:
        case Doc.client_ids(source) do
          [] -> 0
          cs -> Enum.min(cs)
        end
  }

  case Doc.snapshot_update(det) do
    {:error, reason} ->
      IO.puts("#{String.pad_trailing(name, 34)} REFUSED #{inspect(reason)}")

    {bytes, dm} ->
      fresh = Doc.new(client_id: 1)
      {:ok, applied} = Encoding.apply_update(fresh, bytes)

      src_items =
        det.store
        |> BlockStore.client_ids()
        |> Enum.flat_map(&BlockStore.client_blocks(det.store, &1))

      new_vals = Map.values(dm)
      injective? = length(Enum.uniq(new_vals)) == length(new_vals)
      src_lens = Enum.map(src_items, & &1.length) |> Enum.sum()

      IO.puts(
        "#{String.pad_trailing(name, 34)} dm=#{map_size(dm)} " <>
          "src_items=#{length(src_items)} src_clocks=#{src_lens} " <>
          "injective=#{injective?} " <>
          "text=#{inspect(Text.to_string(applied, "t"))}"
      )

      unless injective? do
        dup = new_vals -- Enum.uniq(new_vals)

        IO.puts(
          "    ⛔ NOT A BIJECTION -- these source ids are claimed by >1 new id: #{inspect(Enum.uniq(dup))}"
        )
      end
  end
end

report.("plain text", Doc.new(client_id: 100) |> Text.insert("t", 0, "abcdefgh"))

# Many small inserts -> many source items; the replay may consolidate them.
frag =
  Enum.reduce(0..7, Doc.new(client_id: 100), fn i, d -> Text.insert(d, "t", i, <<?a + i>>) end)

report.("8 separate 1-char inserts", frag)

# Split the source by deleting in the middle (tombstones are not replayed).
tomb = Doc.new(client_id: 100) |> Text.insert("t", 0, "abcdefgh") |> Text.delete("t", 3, 2)
report.("text with tombstones", tomb)

# Two clients.
two = Doc.new(client_id: 100) |> Text.insert("t", 0, "abcd")
r = Doc.new(client_id: 200)
{:ok, r} = Encoding.apply_update(r, Encoding.encode_update(two))
report.("two clients", Text.insert(r, "t", 2, "XY"))

# A map plane alongside text -- the mixed case version 2 exists for.
mixed = Doc.new(client_id: 100) |> Text.insert("t", 0, "abc")
mixed = YMap.set(mixed, "m", "k1", "v1") |> YMap.set("m", "k2", "v2")
report.("mixed text + map planes", mixed)

arr = Doc.new(client_id: 100) |> Text.insert("t", 0, "ab")
arr = Array.insert(arr, "a", 0, ["x", "y", "z"])
report.("text + array planes", arr)
