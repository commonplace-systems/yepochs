# Totality audit: for every (document shape x edit kind x direction), record what
# the library ACTUALLY does. Every cell must be either a defined sensible
# behaviour or a demonstrated impossibility. A cell that raises, or returns an
# untyped error, is neither -- and is the finding.
alias Yelixer.{Doc, Encoding, BlockStore}
alias Yelixer.Types.{Text, Array, YMap, XMLElement, XMLFragment, XMLText}
alias Yepochs.{Algorithm, Bridge, Snapshotter}

# A locally-authored Doc keeps items in client_pending and has an EMPTY type
# registry; snapshot replay iterates that registry, so such a doc snapshots to
# nothing. One round-trip materializes it. Measured -- see the probe notes.
materialized = fn %Doc{} = d ->
  {:ok, m} = Encoding.apply_update(Doc.new(client_id: d.client_id), Encoding.encode_update(d))
  m
end

replica = fn base, client ->
  d = Doc.new(client_id: client)
  {:ok, d} = Encoding.apply_update(d, Encoding.encode_update(base))
  d
end

delta = fn doc, since -> Encoding.encode_diff(doc, BlockStore.state_vector(since.store)) end

# ---- document shapes -------------------------------------------------------
shapes = [
  {"text-clean", fn -> Doc.new(client_id: 100) |> Text.insert("t", 0, "hello") end},
  {"text-tombstoned",
   fn ->
     Doc.new(client_id: 100) |> Text.insert("t", 0, "hello world") |> Text.delete("t", 5, 6)
   end},
  {"map-clean",
   fn -> Doc.new(client_id: 100) |> YMap.set("m", "a", "1") |> YMap.set("m", "b", "2") end},
  {"map-tombstoned",
   fn -> Doc.new(client_id: 100) |> YMap.set("m", "a", "1") |> YMap.set("m", "a", "2") end},
  {"array-clean", fn -> Doc.new(client_id: 100) |> Array.insert("a", 0, ["x", "y"]) end},
  {"array-tombstoned",
   fn ->
     Doc.new(client_id: 100) |> Array.insert("a", 0, ["x", "y", "z"]) |> Array.delete("a", 1, 1)
   end},
  {"xmltext", fn -> Doc.new(client_id: 100) |> XMLText.insert("x", 0, "hi") end},
  {"xmlelement-attrs",
   fn ->
     Doc.new(client_id: 100)
     |> XMLElement.new_element("e", "p")
     |> XMLElement.set_attribute("e", "k", "v")
   end},
  {"xmlelement-child",
   fn ->
     Doc.new(client_id: 100)
     |> XMLElement.new_element("e", "p")
     |> XMLElement.insert_child("e", 0, :text)
   end},
  {"xmlfragment-child",
   fn ->
     Doc.new(client_id: 100)
     |> XMLFragment.new_fragment("f")
     |> XMLFragment.insert_child("f", 0, {:element, "b"})
   end},
  {"multi-type",
   fn ->
     Doc.new(client_id: 100)
     |> Text.insert("t", 0, "ab")
     |> YMap.set("m", "k", "v")
     |> Array.insert("a", 0, ["q"])
   end},
  {"empty", fn -> Doc.new(client_id: 100) end}
]

# ---- edit kinds ------------------------------------------------------------
edits = [
  {"text-insert", fn d -> Text.insert(d, "t", 0, "Z") end},
  {"text-delete", fn d -> Text.delete(d, "t", 0, 1) end},
  {"map-set", fn d -> YMap.set(d, "m", "new", "9") end},
  {"map-delete", fn d -> YMap.delete(d, "m", "a") end},
  {"array-insert", fn d -> Array.insert(d, "a", 0, ["N"]) end},
  {"array-delete", fn d -> Array.delete(d, "a", 0, 1) end},
  {"xmltext-ins", fn d -> XMLText.insert(d, "x", 0, "Z") end},
  {"xml-attr-set", fn d -> XMLElement.set_attribute(d, "e", "k2", "v2") end},
  {"xml-add-kid", fn d -> XMLElement.insert_child(d, "e", 0, :text) end},
  {"new-type", fn d -> Text.insert(d, "brand-new", 0, "fresh") end}
]

# Observable content, identity-free: every live item's parent key, parent_sub and
# content, as a multiset. Two docs holding the same observable Yjs value have
# equal multisets even though their item identities differ -- which is exactly
# what a correct crossing must achieve at the destination.
observable = fn %Doc{} = d ->
  d.store
  |> BlockStore.all_items()
  |> Enum.reject(& &1.deleted)
  |> Enum.map(fn i -> {inspect(i.parent), i.parent_sub, inspect(i.content)} end)
  |> Enum.sort()
end

safe = fn f ->
  try do
    f.()
  rescue
    e -> {:raised, Exception.message(e) |> String.slice(0, 90)}
  catch
    k, v -> {:caught, inspect({k, v}) |> String.slice(0, 90)}
  end
end

rows =
  for {sname, sbuild} <- shapes, {ename, ebuild} <- edits do
    result =
      safe.(fn ->
        src = materialized.(sbuild.())

        case Snapshotter.snapshot(src) do
          {:error, e} ->
            {:no_bridge, e.code, e.details}

          {:ok, snap} ->
            {:ok, dest} = Encoding.apply_update(Doc.new(client_id: 0), snap.update)

            case Bridge.attach(snap.derivation, "ep:origin", "ep:derived", Algorithm.snapshot()) do
              {:error, e} ->
                {:no_bridge, e.code, :attach}

              {:ok, bridge} ->
                r = replica.(src, 777)

                case safe.(fn -> ebuild.(r) end) do
                  {:raised, m} ->
                    {:edit_impossible, m}

                  {:caught, m} ->
                    {:edit_impossible, m}

                  edited ->
                    upd = delta.(edited, src)
                    # NOTE: a no-op edit is crossed too, not skipped. "Cross an
                    # update that changes nothing" is a case like any other.
                    noop? = observable.(edited) == observable.(r)

                    out =
                      safe.(fn ->
                        Yepochs.cross(bridge, upd, src, dest,
                          from: :left,
                          author: 5150,
                          receipt_ref: "probe"
                        )
                      end)

                    case out do
                      {:ok, c} ->
                        # THE VERDICT IS THE DESTINATION, not the byte count.
                        # Apply the crossed update and require the destination to
                        # hold the same observable content as the edited source.
                        case Encoding.apply_update(dest, c.update) do
                          {:ok, dest_after} ->
                            if observable.(dest_after) == observable.(edited) do
                              {:crossed, c.mode, if(noop?, do: :noop_edit, else: :effective)}
                            else
                              {:WRONG_AT_DESTINATION, c.mode,
                               %{
                                 dest: length(observable.(dest_after)),
                                 src: length(observable.(edited))
                               }}
                            end

                          other ->
                            {:DEST_REJECTED_UPDATE, c.mode, inspect(other) |> String.slice(0, 60)}
                        end

                      {:error, e} ->
                        {:refused, e.code}

                      other ->
                        other
                    end
                end
            end
        end
      end)

    {sname, ename, result}
  end

IO.puts("shape | edit | outcome")
IO.puts("---|---|---")

Enum.each(rows, fn {s, e, r} -> IO.puts("#{s} | #{e} | #{inspect(r) |> String.slice(0, 120)}") end)

IO.puts("\n=== TALLY ===")

rows
|> Enum.map(fn {_, _, r} -> elem(r, 0) end)
|> Enum.frequencies()
|> Enum.sort_by(&elem(&1, 1), :desc)
|> Enum.each(fn {k, v} -> IO.puts("#{k}: #{v}") end)

IO.puts("\n=== UNCLASSIFIED (raise/catch = neither defined nor proven impossible) ===")

bad =
  Enum.filter(rows, fn {_, _, r} ->
    elem(r, 0) in [:raised, :caught, :WRONG_AT_DESTINATION, :DEST_REJECTED_UPDATE]
  end)

if bad == [],
  do: IO.puts("none"),
  else: Enum.each(bad, fn {s, e, r} -> IO.puts("#{s} / #{e}: #{inspect(r)}") end)
