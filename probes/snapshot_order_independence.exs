# ⭐ Feasibility measurement for DETERMINISTIC epoch-token minting (ledger 26).
#
# The token can trivially be a hash of deterministic inputs. The real question is
# whether the thing it NAMES is deterministic: do two nodes that replay the same
# commit set in DIFFERENT ORDERS derive the same snapshot?
#
# ⛔ `encode_update/1` is path-dependent under concurrent deletes (measured, 676
# pairs). If snapshotting inherited that, one token would name two documents.
#
# ⚠️ Corpus discipline: a case whose RAW encoding does not vary cannot
# discriminate. The headline number is the DISCRIMINATING count, not the total.
alias Yelixer.{Doc, Encoding}
alias Yelixer.Types.Text
alias Yepochs.Snapshotter

base = Text.insert(Doc.new(client_id: 100), "t", 0, "abcdefgh")
base_u = Encoding.encode_update(base)

del = fn cid, idx, len ->
  {:ok, d} = Encoding.apply_update(Doc.new(client_id: cid), base_u)
  Encoding.encode_update(Text.delete(d, "t", idx, len))
end

integrate = fn us ->
  Enum.reduce(us, Doc.new(client_id: 1), fn u, d ->
    {:ok, d} = Encoding.apply_update(d, u)
    d
  end)
end

ranges = for i <- 0..7, l <- 1..4, i + l <= 8, do: {i, l}

rows =
  for {i1, l1} <- ranges, {i2, l2} <- ranges do
    u1 = del.(200, i1, l1)
    u2 = del.(300, i2, l2)

    fwd = integrate.([base_u, u1, u2])
    rev = integrate.([base_u, u2, u1])

    raw_differs = Encoding.encode_update(fwd) != Encoding.encode_update(rev)

    {sf, sr} = {Snapshotter.snapshot(fwd), Snapshotter.snapshot(rev)}

    snap_differs =
      case {sf, sr} do
        {{:ok, a}, {:ok, b}} -> a.update != b.update or a.derivation.spans != b.derivation.spans
        {{:error, _}, {:error, _}} -> false
        _ -> true
      end

    text_differs = Text.to_string(fwd, "t") != Text.to_string(rev, "t")
    {raw_differs, snap_differs, text_differs}
  end

total = length(rows)
disc = Enum.count(rows, &elem(&1, 0))
snap_bad = Enum.count(rows, &elem(&1, 1))
text_bad = Enum.count(rows, &elem(&1, 2))

IO.puts("pairs total                                  : #{total}")
IO.puts("⭐ DISCRIMINATING (raw encoding order-dependent): #{disc}")

IO.puts(
  "   observable text differed                  : #{text_bad}   (must be 0 — CRDT convergence)"
)

IO.puts("⇒ SNAPSHOT or SPANS differed by arrival order : #{snap_bad}")

IO.puts("\nAmong the discriminating pairs only:")
d = Enum.filter(rows, &elem(&1, 0))
IO.puts("  count #{length(d)}, snapshot differed in #{Enum.count(d, &elem(&1, 1))}")

if disc == 0 do
  IO.puts("\n⛔ INSTRUMENT BLIND: no pair exercised path-dependence; the result is vacuous.")
end
