# INDEPENDENT PROBE of yelixer encode determinism, for yepochs Tier 1.
# Deliberately not merkle-crdt's test: an inherited result carries the
# instrument that produced it, and an instrument you did not run can't be audited.
alias Yelixer.{Doc, Encoding}
alias Yelixer.Types.Text

base = Doc.new(client_id: 100)
base = Text.insert(base, "t", 0, "abcdefgh")
base_u = Encoding.encode_update(base)

del = fn cid, idx, len ->
  d = Doc.new(client_id: cid)
  {:ok, d} = Encoding.apply_update(d, base_u)
  d = Text.delete(d, "t", idx, len)
  Encoding.encode_update(d)
end

ins = fn cid, idx, s ->
  d = Doc.new(client_id: cid)
  {:ok, d} = Encoding.apply_update(d, base_u)
  d = Text.insert(d, "t", idx, s)
  Encoding.encode_update(d)
end

integrate = fn updates ->
  Enum.reduce(updates, Doc.new(client_id: 1), fn u, d ->
    {:ok, d} = Encoding.apply_update(d, u)
    d
  end)
end

pair = fn u, v -> {integrate.([u, v]), integrate.([v, u])} end
blocks = fn d ->
  d.store.clients |> Enum.sort()
  |> Enum.map(fn {c, l} -> {c, Enum.map(l, &{&1.id.clock, &1.length})} end)
end
nblocks = fn d -> d.store.clients |> Enum.map(fn {_, l} -> length(l) end) |> Enum.sum() end

scenario = fn name, u, v, expect ->
  {a, b} = pair.(u, v)
  eq = Encoding.encode_update(a) == Encoding.encode_update(b)
  conv = Text.to_string(a, "t") == Text.to_string(b, "t")
  ds = Encoding.encode_delete_set(a.delete_set) == Encoding.encode_delete_set(b.delete_set)
  flag = if eq == expect, do: "  ", else: "??"
  IO.puts("#{flag} #{String.pad_trailing(name, 34)} bytes_eq=#{String.pad_trailing(to_string(eq), 5)} " <>
          "ds_eq=#{String.pad_trailing(to_string(ds), 5)} store_eq=#{String.pad_trailing(to_string(a.store == b.store), 5)} " <>
          "converged=#{String.pad_trailing(to_string(conv), 5)} blocks=#{nblocks.(a)}/#{nblocks.(b)}")
  {a, b}
end

IO.puts("== Q1: is encode_update a pure function of ONE fixed Doc term? ==")
{fa, _} = pair.(del.(200, 2, 3), del.(300, 4, 3))
IO.puts("   distinct outputs over 200 calls on one doc: " <>
        "#{1..200 |> Enum.map(fn _ -> Encoding.encode_update(fa) end) |> Enum.uniq() |> length()}")

IO.puts("\n== Q2: which scenarios diverge across apply-order? (expect column = my prediction) ==")
scenario.("insert-only (CONTROL, expect eq)", ins.(200, 2, "XY"), ins.(300, 4, "ZW"), true)
scenario.("identical deletes (CONTROL, eq)", del.(200, 1, 3), del.(300, 1, 3), true)
scenario.("one delete + one insert (eq)", del.(200, 1, 3), ins.(300, 5, "Z"), true)
{a, b} = scenario.("OVERLAPPING deletes (expect NEQ)", del.(200, 2, 3), del.(300, 4, 3), false)
scenario.("ADJACENT deletes (expect NEQ)", del.(200, 0, 3), del.(300, 3, 3), false)
scenario.("disjoint, gap between (expect NEQ)", del.(200, 0, 2), del.(300, 5, 2), false)

IO.puts("\n== Q3: on the overlapping case, WHERE is the divergence? ==")
IO.puts("   delete_set A       : #{inspect(a.delete_set)}")
IO.puts("   delete_set B       : #{inspect(b.delete_set)}")
IO.puts("   DELETE SETS EQUAL  : #{a.delete_set == b.delete_set}")
IO.puts("   encoded ds equal   : #{Encoding.encode_delete_set(a.delete_set) == Encoding.encode_delete_set(b.delete_set)}")
IO.puts("   store terms equal  : #{a.store == b.store}")
IO.puts("   blocks A           : #{inspect(blocks.(a))}")
IO.puts("   blocks B           : #{inspect(blocks.(b))}")
IO.puts("   block COUNT        : A=#{nblocks.(a)} B=#{nblocks.(b)}")
