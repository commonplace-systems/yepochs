# Does encode_items/2 satisfy spec §15.8 -- "semantically equivalent but
# byte-different output caused by unordered map traversal is not permitted"?
alias Yelixer.{Doc, Encoding}
alias Yelixer.Types.Text

d = Doc.new(client_id: 100)
d = Text.insert(d, "t", 0, "hello")
d2 = Doc.new(client_id: 250)
{:ok, d2} = Encoding.apply_update(d2, Encoding.encode_update(d))
d2 = Text.insert(d2, "t", 5, " world")
d2 = Text.delete(d2, "t", 1, 2)
u = Encoding.encode_update(d2)
{:ok, {items, ds, _}} = Encoding.decode_update(u)

IO.puts("decoded #{length(items)} items across clients #{inspect(Enum.map(items, & &1.id.client) |> Enum.uniq())}")

base = Encoding.encode_items(items, ds)
IO.puts("\n1. repeated calls, same input:      #{1..100 |> Enum.map(fn _ -> Encoding.encode_items(items, ds) end) |> Enum.uniq() |> length()} distinct")
IO.puts("2. round-trip decode->encode == in:  #{base == u}")

perms = [
  {"reversed",        Enum.reverse(items)},
  {"sorted by client", Enum.sort_by(items, &{&1.id.client, &1.id.clock})},
  {"sorted desc",     Enum.sort_by(items, &{-&1.id.client, &1.id.clock})}
]

IO.puts("\n3. INPUT ORDER SENSITIVITY (§15.8 depends on this):")
for {name, permuted} <- perms do
  out = Encoding.encode_items(permuted, ds)
  IO.puts("   #{String.pad_trailing(name, 18)} bytes == canonical: #{out == base}  (#{byte_size(out)} vs #{byte_size(base)})")
end

IO.puts("\n4. applying each encoding yields the same observable text:")
for {name, permuted} <- [{"canonical", items} | perms] do
  fresh = Doc.new(client_id: 9)
  {:ok, fresh} = Encoding.apply_update(fresh, Encoding.encode_items(permuted, ds))
  IO.puts("   #{String.pad_trailing(name, 18)} #{inspect(Text.to_string(fresh, "t"))}")
end
