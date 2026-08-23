# What XML shapes can actually cross? An adapter is only useful for content the
# snapshot path can carry, so measure the substrate before building one.
alias Yelixer.{Doc, Encoding}
alias Yelixer.Types.{XMLElement, XMLFragment, XMLText}

mat = fn d ->
  {:ok, m} = Encoding.apply_update(Doc.new(client_id: d.client_id), Encoding.encode_update(d))
  m
end

probe = fn name, build ->
  d =
    try do
      mat.(build.())
    rescue
      e -> {:build_error, e}
    end

  case d do
    {:build_error, e} ->
      IO.puts("#{String.pad_trailing(name, 30)} BUILD FAILED: #{inspect(e.__struct__)}")

    doc ->
      nested = Doc.nested_subtype_names(doc)

      snap =
        case Doc.snapshot_update(%{doc | client_id: 0}) do
          {:error, r} -> "REFUSED #{inspect(elem(r, 0))}"
          {b, dm} -> "ok #{byte_size(b)}B dm=#{map_size(dm)}"
        end

      case Yepochs.Snapshotter.snapshot(doc, []) do
        {:ok, s} ->
          IO.puts(
            "#{String.pad_trailing(name, 30)} nested=#{length(nested)}  yelixer=#{snap}  yepochs=OK spans=#{length(s.derivation.spans)}"
          )

        {:error, e} ->
          IO.puts(
            "#{String.pad_trailing(name, 30)} nested=#{length(nested)}  yelixer=#{snap}  yepochs=#{e.code} #{inspect(e.details)}"
          )
      end
  end
end

probe.("xml text only", fn -> XMLText.insert(Doc.new(client_id: 100), "xt", 0, "hello") end)

probe.("xml element, no children", fn ->
  Doc.new(client_id: 100) |> XMLElement.new_element("el", "div")
end)

probe.("xml element + attributes", fn ->
  d = Doc.new(client_id: 100) |> XMLElement.new_element("el", "div")
  XMLElement.set_attribute(d, "el", "class", "big")
end)

probe.("xml element + child", fn ->
  d = Doc.new(client_id: 100) |> XMLElement.new_element("el", "div")
  XMLElement.insert_child(d, "el", 0, {:element, "span"})
end)

probe.("xml fragment + child", fn ->
  d = Doc.new(client_id: 100) |> XMLFragment.new_fragment("frag")
  XMLFragment.insert_child(d, "frag", 0, {:text, "hi"})
end)
