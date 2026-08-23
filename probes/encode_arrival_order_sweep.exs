# Corrected sweep. The first sweep authored updates with encode_update/1, which
# emits FULL STATE -- so every "delta" carried its own base and could not be
# delivered out of causal order. This one authors TRUE deltas via encode_diff/2
# and varies arrival order relative to the causal dependency.
alias Yelixer.{Doc, Encoding, BlockStore, StateVector}
alias Yelixer.Types.Text

base = Doc.new(client_id: 100)
base = Text.insert(base, "t", 0, "abcdefgh")
base_u = Encoding.encode_update(base)
base_sv = BlockStore.state_vector(base.store)

# A TRUE delta: only the delete, not the base it depends on.
delta = fn cid, idx, len ->
  d = Doc.new(client_id: cid)
  {:ok, d} = Encoding.apply_update(d, base_u)
  Encoding.encode_diff(Text.delete(d, "t", idx, len), base_sv)
end

full = fn cid, idx, len ->
  d = Doc.new(client_id: cid)
  {:ok, d} = Encoding.apply_update(d, base_u)
  Encoding.encode_update(Text.delete(d, "t", idx, len))
end

IO.puts("authoring sizes: full-state=#{byte_size(full.(200,1,3))}B  true-delta=#{byte_size(delta.(200,1,3))}B")

integrate = fn us ->
  Enum.reduce(us, Doc.new(client_id: 1), fn u, d ->
    {:ok, d} = Encoding.apply_update(d, u)
    d
  end)
end

classify = fn {i1, l1}, {i2, l2} ->
  {a1, b1, a2, b2} = {i1, i1 + l1 - 1, i2, i2 + l2 - 1}
  cond do
    a1 == a2 and b1 == b2 -> :identical
    b1 < a2 or b2 < a1 -> if b1 + 1 == a2 or b2 + 1 == a1, do: :adjacent, else: :disjoint
    (a1 <= a2 and b2 <= b1) or (a2 <= a1 and b1 <= b2) -> :contained
    true -> :overlapping
  end
end

ranges = for i <- 0..7, l <- 1..4, i + l <= 8, do: {i, l}

rows =
  for {i1, l1} <- ranges, {i2, l2} <- ranges do
    d1 = delta.(200, i1, l1)
    d2 = delta.(300, i2, l2)
    # P1: base arrives first (causal deps satisfied on arrival)
    p1 = Encoding.encode_update(integrate.([base_u, d1, d2])) ==
         Encoding.encode_update(integrate.([base_u, d2, d1]))
    # P2: base arrives LAST (both deltas sit in the pending buffer first)
    p2 = Encoding.encode_update(integrate.([d1, d2, base_u])) ==
         Encoding.encode_update(integrate.([d2, d1, base_u]))
    # P3: base-first vs base-last, same delta order -- does arrival order alone matter?
    p3 = Encoding.encode_update(integrate.([base_u, d1, d2])) ==
         Encoding.encode_update(integrate.([d1, d2, base_u]))
    conv = Text.to_string(integrate.([d1, d2, base_u]), "t") ==
           Text.to_string(integrate.([base_u, d1, d2]), "t")
    {classify.({i1, l1}, {i2, l2}), p1, p2, p3, conv}
  end

IO.puts("\ntotal pairs: #{length(rows)}")
IO.puts("\n                     P1 base-first      P2 base-LAST       P3 first-vs-last   converged")
IO.puts("class          n     eq    differ       eq    differ       eq    differ       ok")
rows
|> Enum.group_by(fn {c, _, _, _, _} -> c end)
|> Enum.sort()
|> Enum.each(fn {c, rs} ->
  n = length(rs)
  cnt = fn f -> Enum.count(rs, f) end
  e1 = cnt.(fn {_, a, _, _, _} -> a end)
  e2 = cnt.(fn {_, _, a, _, _} -> a end)
  e3 = cnt.(fn {_, _, _, a, _} -> a end)
  ok = cnt.(fn {_, _, _, _, a} -> a end)
  p = &String.pad_trailing(to_string(&1), 6)
  IO.puts("#{String.pad_trailing(to_string(c), 14)} #{p.(n)}#{p.(e1)}#{p.(n - e1)}       #{p.(e2)}#{p.(n - e2)}       #{p.(e3)}#{p.(n - e3)}       #{ok}/#{n}")
end)
