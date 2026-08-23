# Does YELIXER'S OWN derivation map pair matching content? Verified directly
# against Yelixer.Doc.snapshot_update/1's map, not against a reimplementation of
# its approach.
alias Yelixer.{Doc, Encoding, BlockStore}
alias Yelixer.Types.Text

mat = fn d ->
  {:ok, m} = Encoding.apply_update(Doc.new(client_id: d.client_id), Encoding.encode_update(d))
  m
end

content = fn %Doc{store: store} ->
  store
  |> BlockStore.all_items()
  |> Enum.reject(& &1.deleted)
  |> Enum.flat_map(fn
    %{content: {:string, s}} = i ->
      for n <- 0..(i.length - 1)//1, do: {{i.id.client, i.id.clock + n}, binary_part(s, n, 1)}

    _ ->
      []
  end)
  |> Map.new()
end

check = fn name, src0 ->
  src = mat.(src0)

  det = %{
    src
    | client_id:
        case Doc.client_ids(src) do
          [] -> 0
          c -> Enum.min(c)
        end
  }

  {bytes, dm} = Doc.snapshot_update(det)
  {:ok, out} = Encoding.apply_update(Doc.new(client_id: 1), bytes)
  from = content.(det)
  to = content.(out)

  results =
    for {new_id, old_id} <- Enum.sort(dm) do
      {new_id, old_id, Map.get(to, new_id), Map.get(from, old_id)}
    end

  bad = Enum.filter(results, fn {_, _, a, b} -> a != nil and b != nil and a != b end)
  comparable = Enum.count(results, fn {_, _, a, b} -> a != nil and b != nil end)

  IO.puts("\n#{name}")

  IO.puts(
    "  source text #{inspect(Text.to_string(det, "t"))} -> snapshot text #{inspect(Text.to_string(out, "t"))}"
  )

  IO.puts(
    "  dm entries: #{map_size(dm)}   COMPARABLE: #{comparable}/#{length(results)}   MISMATCHED: #{length(bad)}"
  )

  for {n, o, a, b} <- results do
    flag = if a != nil and b != nil and a != b, do: "  <-- ⛔ MISMAP", else: ""
    IO.puts("    new #{inspect(n)}=#{inspect(a)}  <-  old #{inspect(o)}=#{inspect(b)}#{flag}")
  end
end

# Cases where the map has MORE THAN ONE entry -- the only place index-pairing
# across two independently grouped lists can misalign.
alias Yelixer.Types.{YMap, Array}

check.("single client", Doc.new(client_id: 100) |> Text.insert("t", 0, "abcdefgh"))

m = Doc.new(client_id: 100) |> Text.insert("t", 0, "abc")
m = YMap.set(m, "m", "k1", "v1") |> YMap.set("m", "k2", "v2")
check.("text + map planes", m)

a = Doc.new(client_id: 100) |> Text.insert("t", 0, "ab")
check.("text + array planes", Array.insert(a, "arr", 0, ["x", "y", "z"]))

t3 = Doc.new(client_id: 100) |> Text.insert("zeta", 0, "zz")
t3 = Text.insert(t3, "alpha", 0, "aa") |> Text.insert("mid", 0, "mm")
check.("three named text types", t3)

# Multi-client AND multi-entry together.
mc = Doc.new(client_id: 700) |> Text.insert("t", 0, "abcd")
mc2 = Doc.new(client_id: 300)
{:ok, mc2} = Encoding.apply_update(mc2, Encoding.encode_update(mc))
mc2 = Text.insert(mc2, "t", 2, "XY")
mc2 = YMap.set(mc2, "m", "k1", "v1") |> YMap.set("m", "k2", "v2")
check.("TWO clients + map plane (multi-entry)", mc2)

two = Doc.new(client_id: 700) |> Text.insert("t", 0, "abcd")
r = Doc.new(client_id: 300)
{:ok, r} = Encoding.apply_update(r, Encoding.encode_update(two))
check.("TWO clients (700 base, 300 inserts)", Text.insert(r, "t", 2, "XY"))
