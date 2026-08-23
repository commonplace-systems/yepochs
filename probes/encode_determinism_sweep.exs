# Exhaustive sweep: every pair of concurrent deletes over an 8-char base,
# classified by the geometric relationship between the two ranges.
alias Yelixer.{Doc, Encoding}
alias Yelixer.Types.Text

base = Doc.new(client_id: 100)
base = Text.insert(base, "t", 0, "abcdefgh")
base_u = Encoding.encode_update(base)

del = fn cid, idx, len ->
  d = Doc.new(client_id: cid)
  {:ok, d} = Encoding.apply_update(d, base_u)
  Encoding.encode_update(Text.delete(d, "t", idx, len))
end

integrate = fn us ->
  Enum.reduce(us, Doc.new(client_id: 1), fn u, d ->
    {:ok, d} = Encoding.apply_update(d, u)
    d
  end)
end

classify = fn {i1, l1}, {i2, l2} ->
  a1..b1//1 = i1..(i1 + l1 - 1)
  a2..b2//1 = i2..(i2 + l2 - 1)

  cond do
    a1 == a2 and b1 == b2 -> :identical
    b1 < a2 or b2 < a1 -> if b1 + 1 == a2 or b2 + 1 == a1, do: :adjacent, else: :disjoint
    (a1 <= a2 and b2 <= b1) or (a2 <= a1 and b1 <= b2) -> :contained
    true -> :overlapping
  end
end

ranges = for i <- 0..7, l <- 1..4, i + l <= 8, do: {i, l}

results =
  for r1 <- ranges, r2 <- ranges do
    u1 = del.(200, elem(r1, 0), elem(r1, 1))
    u2 = del.(300, elem(r2, 0), elem(r2, 1))
    a = integrate.([u1, u2])
    b = integrate.([u2, u1])

    {classify.(r1, r2), Encoding.encode_update(a) == Encoding.encode_update(b),
     a.delete_set == b.delete_set, Text.to_string(a, "t") == Text.to_string(b, "t"), r1, r2}
  end

IO.puts("total pairs: #{length(results)}")
IO.puts("\nclass         n    bytes_equal  bytes_differ   ds_differ  non_converged")

results
|> Enum.group_by(fn {c, _, _, _, _, _} -> c end)
|> Enum.sort()
|> Enum.each(fn {class, rows} ->
  eq = Enum.count(rows, fn {_, e, _, _, _, _} -> e end)
  dsd = Enum.count(rows, fn {_, _, d, _, _, _} -> not d end)
  nc = Enum.count(rows, fn {_, _, _, c, _, _} -> not c end)

  IO.puts(
    "#{String.pad_trailing(to_string(class), 13)} #{String.pad_trailing(to_string(length(rows)), 4)} " <>
      "#{String.pad_trailing(to_string(eq), 12)} #{String.pad_trailing(to_string(length(rows) - eq), 13)} " <>
      "#{String.pad_trailing(to_string(dsd), 10)} #{nc}"
  )
end)

IO.puts("\n== CONVERGENCE CONTROL: any pair that failed to converge? ==")
IO.puts("   #{Enum.count(results, fn {_, _, _, c, _, _} -> not c end)} of #{length(results)}")

IO.puts("\n== ADJACENT pairs that DIFFER (merkle-crdt reported adjacent as divergent) ==")
adj_diff = Enum.filter(results, fn {c, e, _, _, _, _} -> c == :adjacent and not e end)

IO.puts(
  "   #{length(adj_diff)} of #{Enum.count(results, fn {c, _, _, _, _, _} -> c == :adjacent end)}"
)

Enum.take(adj_diff, 5)
|> Enum.each(fn {_, _, _, _, r1, r2} -> IO.puts("     #{inspect(r1)} vs #{inspect(r2)}") end)

IO.puts("\n== sample DIVERGENT pairs ==")

results
|> Enum.filter(fn {_, e, _, _, _, _} -> not e end)
|> Enum.take(6)
|> Enum.each(fn {c, _, _, _, r1, r2} ->
  IO.puts("   #{String.pad_trailing(to_string(c), 12)} #{inspect(r1)} vs #{inspect(r2)}")
end)
