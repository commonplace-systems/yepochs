# REFERENCE IMPLEMENTATION + CONFORMANCE VECTORS for the epoch-token minting
# function specified in docs/design/0010.
#
# ⛔ THIS IS A PROBE, NOT LIBRARY CODE. It exists so the specification is
# EXECUTABLE before the implementation is written: whoever ships the real one
# must reproduce these vectors byte-for-byte. A spec that cannot refuse an
# implementation is a suggestion.
#
# Rule (0010):
#   token = H( "yepochs.epoch-token.v1"
#            ‖ u32(n) ‖ for each of n parent ids,            ASC BYTE ORDER: u32(len) ‖ bytes
#            ‖ u32(m) ‖ for each of m distinct source epochs, ASC BYTE ORDER: u32(len) ‖ bytes
#            ‖ u32(len) ‖ algorithm_id ‖ u32(algorithm_version) )

defmodule EpochTokenReference do
  @domain "yepochs.epoch-token.v1"

  def mint(parent_ids, source_epochs, {algorithm_id, algorithm_version})
      when is_list(parent_ids) and is_list(source_epochs) and is_binary(algorithm_id) and
             is_integer(algorithm_version) and algorithm_version > 0 do
    parents = parent_ids |> Enum.uniq() |> Enum.sort()
    epochs = source_epochs |> Enum.uniq() |> Enum.sort()

    payload =
      @domain <>
        framed_list(parents) <>
        framed_list(epochs) <>
        framed(algorithm_id) <> <<algorithm_version::unsigned-big-32>>

    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  defp framed_list(items),
    do: <<length(items)::unsigned-big-32>> <> Enum.map_join(items, &framed/1)

  defp framed(bin), do: <<byte_size(bin)::unsigned-big-32>> <> bin
end

alg = {"yepochs.snapshot", 3}

vectors = [
  {"V1 single parent, single epoch", ["commit:aaa"], ["epoch:E1"], alg},
  {"V2 two parents, one epoch (same-epoch opener)", ["commit:bbb", "commit:aaa"], ["epoch:E1"], alg},
  {"V3 two parents, two epochs (CROSS-EPOCH opener)", ["commit:bbb", "commit:aaa"],
   ["epoch:E2", "epoch:E1"], alg},
  {"V4 V3 with inputs pre-sorted — MUST equal V3", ["commit:aaa", "commit:bbb"],
   ["epoch:E1", "epoch:E2"], alg},
  {"V5 V3 with a duplicate epoch — MUST equal V3", ["commit:bbb", "commit:aaa"],
   ["epoch:E2", "epoch:E1", "epoch:E1"], alg},
  {"V6 V1 at algorithm version 2 — MUST differ from V1", ["commit:aaa"], ["epoch:E1"],
   {"yepochs.snapshot", 2}},
  {"V7 V1 under a different algorithm id — MUST differ from V1", ["commit:aaa"], ["epoch:E1"],
   {"yepochs.other", 3}},
  {"V8 ⛔ the FRAMING case: naive concatenation would collide with V9", ["ab", "c"], ["x"], alg},
  {"V9 ⛔ the FRAMING case: naive concatenation would collide with V8", ["a", "bc"], ["x"], alg},
  {"V10 empty parents (a root opener)", [], ["epoch:E1"], alg}
]

results =
  for {name, parents, epochs, algorithm} <- vectors do
    {name, EpochTokenReference.mint(parents, epochs, algorithm)}
  end

IO.puts("## Conformance vectors — sha256, lowercase hex\n")
Enum.each(results, fn {n, t} -> IO.puts("#{String.pad_trailing(n, 52)} #{t}") end)

get = fn label -> results |> Enum.find(&String.starts_with?(elem(&1, 0), label)) |> elem(1) end

IO.puts("\n## Required relations")
IO.puts("V4 == V3 (sorting is applied)          : #{get.("V4") == get.("V3")}")
IO.puts("V5 == V3 (epochs deduplicated)         : #{get.("V5") == get.("V3")}")
IO.puts("V6 != V1 (version is bound)            : #{get.("V6") != get.("V1")}")
IO.puts("V7 != V1 (algorithm id is bound)       : #{get.("V7") != get.("V1")}")
IO.puts("V2 != V3 (source epoch set is bound)   : #{get.("V2") != get.("V3")}")
IO.puts("⭐ V8 != V9 (LENGTH FRAMING WORKS)      : #{get.("V8") != get.("V9")}")

IO.puts("\n## Control: the unframed draft formula COLLIDES on V8/V9")
naive = fn parents, epochs, {id, v} ->
  :crypto.hash(:sha256, Enum.join(Enum.sort(parents)) <> Enum.join(Enum.sort(epochs)) <> id <> to_string(v))
  |> Base.encode16(case: :lower)
end
n8 = naive.(["ab", "c"], ["x"], alg)
n9 = naive.(["a", "bc"], ["x"], alg)
IO.puts("naive V8 == naive V9                   : #{n8 == n9}   <- ⛔ TRUE means the draft was collision-capable")
