defmodule Yepochs.Rebase do
  @moduledoc """
  Positional re-authoring. Spec r2 §19.

  Recovers the **observable effect** of an edit by comparing the source state
  before and after it, then re-authoring that effect against a destination
  state using type-specific logic.

  ⛔ **It does not preserve** original item identities, byte identity of the
  original update, original Yjs authorship, or operation-level intent beyond the
  supported observable diff (§19.3). It is the normal crossing fallback, not a
  lesser form of translation — but the loss is real and is reported as
  `mode: :reauthored`.

  Determinism requires an explicit author id: a caller supplying randomness has
  chosen non-content-addressable output.

  ## Coverage in 0.1

  Adapters for **Y.Text**, **Y.Map** and **Y.Array**. A named type has two
  storage planes and both are diffed; the sequence plane is classified by the
  content it holds rather than by the type registry.

  ⛔ **That classification is load-bearing.** `Text.to_string/2` renders an array
  plane as `""`, so a text-only adapter sees no difference between two different
  arrays and reports `:absorbed` — returning an empty update for a real edit. A
  wrong answer, not an error, and the same shape as the type-registry trap in
  `Yepochs.Snapshotter`.
  """

  alias Yelixer.Doc
  alias Yelixer.Encoding
  alias Yelixer.BlockStore
  alias Yelixer.Types.Array
  alias Yelixer.Types.Text
  alias Yelixer.Types.YMap
  alias Yepochs.Algorithm
  alias Yepochs.Error

  defmodule Result do
    @moduledoc "Outcome of a positional re-authoring. Spec §19.1."
    @enforce_keys [:update, :outcome, :algorithm]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            update: binary(),
            outcome: :applied | :absorbed,
            algorithm: Yepochs.Algorithm.t()
          }
  end

  @type type_name :: String.t()

  @spec rebase(Doc.t(), Doc.t(), Doc.t(), keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
  def rebase(%Doc{} = before, %Doc{} = edited, %Doc{} = target, opts) do
    with {:ok, author} <- fetch_author(opts) do
      names = Enum.sort(Enum.uniq(type_names(before) ++ type_names(edited)))
      apply_planes(names, before, edited, %{target | client_id: author}, target)
    end
  end

  defp fetch_author(opts) do
    case Keyword.get(opts, :author) do
      id when is_integer(id) and id >= 0 -> {:ok, id}
      _ -> {:error, Error.new(:invalid_rebase_input, :rebase, path: [:author])}
    end
  end

  # ⚠️ Derived from the STORE, not from `doc.types`. The registry records what it
  # was TOLD, not what the document HOLDS -- the same trap that makes
  # `Yelixer.Doc.snapshot_update/1` emit an empty snapshot. Trusting it here once
  # made a delete look like an absorbed no-op.
  defp type_names(%Doc{types: types, store: store}) do
    from_store =
      store
      |> BlockStore.all_items()
      |> Enum.flat_map(fn
        %{parent: {:named, name}} -> [name]
        _ -> []
      end)

    (Map.keys(types) ++ from_store) |> Enum.uniq() |> Enum.reject(&synthetic?/1)
  end

  defp synthetic?(name) do
    String.starts_with?(name, "__sub:") or String.contains?(name, "::child::") or
      String.ends_with?(name, "::children")
  end

  defp apply_planes(names, before, edited, doc, target) do
    Enum.reduce_while(names, {:ok, doc, false}, fn name, {:ok, doc, changed?} ->
      case apply_type(name, before, edited, doc) do
        {:ok, doc, c} -> {:cont, {:ok, doc, changed? or c}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _doc, false} ->
        {:ok, %Result{update: <<>>, outcome: :absorbed, algorithm: Algorithm.rebase()}}

      {:ok, doc, true} ->
        {:ok,
         %Result{
           update: Encoding.encode_diff(doc, BlockStore.state_vector(target.store)),
           outcome: :applied,
           algorithm: Algorithm.rebase()
         }}

      {:error, _} = error ->
        error
    end
  end

  defp apply_type(name, before, edited, doc) do
    with {:ok, doc, seq?} <- apply_sequence(name, before, edited, doc),
         {:ok, doc, map?} <- apply_map(name, before, edited, doc) do
      {:ok, doc, seq? or map?}
    end
  end

  # The sequence plane is classified by the CONTENT it holds, never by the type
  # registry: an array rendered through the text API is indistinguishable from an
  # empty one.
  defp apply_sequence(name, before, edited, doc) do
    case {plane_kind(before, name), plane_kind(edited, name)} do
      {:empty, :empty} -> {:ok, doc, false}
      {:text, k} when k in [:text, :empty] -> apply_text(name, before, edited, doc)
      {:empty, :text} -> apply_text(name, before, edited, doc)
      {:array, k} when k in [:array, :empty] -> apply_array(name, before, edited, doc)
      {:empty, :array} -> apply_array(name, before, edited, doc)
      {a, b} -> {:error, Error.new(:unsupported_crossing_content, :rebase, details: %{type: name, before: a, after: b})}
    end
  end

  defp plane_kind(%Doc{store: store}, name) do
    store
    |> BlockStore.get_sequence(name)
    |> Enum.reject(&(&1.deleted or &1.parent_sub != nil))
    |> Enum.map(& &1.content)
    |> case do
      [] -> :empty
      contents -> if Enum.all?(contents, &match?({:string, _}, &1)), do: :text, else: :array
    end
  end

  defp apply_text(name, before, edited, doc) do
    b = Text.to_string(before, name)
    e = Text.to_string(edited, name)
    current = Text.to_string(doc, name)

    cond do
      b == e -> {:ok, doc, false}
      current == e -> {:ok, doc, false}
      true -> place_text(name, doc, current, b, e)
    end
  end

  defp place_text(name, doc, current, before_text, after_text) do
    {prefix, removed, inserted} = diff_string(before_text, after_text)

    if applicable_string?(current, prefix, removed) do
      at = String.length(prefix)
      doc = if removed != "", do: Text.delete(doc, name, at, String.length(removed)), else: doc
      doc = if inserted != "", do: Text.insert(doc, name, at, inserted), else: doc
      {:ok, doc, true}
    else
      {:error,
       Error.new(:rebase_conflict, :rebase,
         details: %{type: name, expected_prefix: prefix, removed: removed}
       )}
    end
  end

  defp applicable_string?(current, prefix, removed) do
    String.starts_with?(current, prefix) and
      String.starts_with?(String.slice(current, String.length(prefix)..-1//1), removed)
  end

  defp apply_array(name, before, edited, doc) do
    b = Array.to_list(before, name)
    e = Array.to_list(edited, name)
    current = Array.to_list(doc, name)

    cond do
      b == e ->
        {:ok, doc, false}

      current == e ->
        {:ok, doc, false}

      true ->
        {prefix, removed, inserted} = diff_list(b, e)
        at = length(prefix)

        if applicable_list?(current, prefix, removed) do
          doc = if removed != [], do: Array.delete(doc, name, at, length(removed)), else: doc
          doc = if inserted != [], do: Array.insert(doc, name, at, inserted), else: doc
          {:ok, doc, true}
        else
          {:error,
           Error.new(:rebase_conflict, :rebase, details: %{type: name, removed: removed})}
        end
    end
  end

  defp applicable_list?(current, prefix, removed) do
    List.starts_with?(current, prefix) and
      List.starts_with?(Enum.drop(current, length(prefix)), removed)
  end

  # The map plane: keys are unordered, so the diff is per key rather than
  # positional, and each key is checked against the destination independently.
  defp apply_map(name, before, edited, doc) do
    b = map_entries(before, name)
    e = map_entries(edited, name)

    changed_keys =
      (Map.keys(b) ++ Map.keys(e))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.filter(fn k -> Map.get(b, k) != Map.get(e, k) end)

    Enum.reduce_while(changed_keys, {:ok, doc, false}, fn key, {:ok, doc, changed?} ->
      desired = Map.get(e, key)
      current = YMap.get(doc, name, key)

      cond do
        current == desired -> {:cont, {:ok, doc, changed?}}
        desired == nil -> {:cont, {:ok, YMap.delete(doc, name, key), true}}
        true -> {:cont, {:ok, YMap.set(doc, name, key, desired), true}}
      end
    end)
  end

  defp map_entries(%Doc{store: store} = doc, name) do
    store
    |> BlockStore.all_items()
    |> Enum.filter(fn item ->
      match?({:named, ^name}, item.parent) and item.parent_sub != nil and not item.deleted
    end)
    |> Map.new(fn item -> {item.parent_sub, YMap.get(doc, name, item.parent_sub)} end)
  end

  # Longest common prefix and suffix, yielding one replaced middle.
  defp diff_string(before_text, after_text) do
    prefix = common_prefix_string(before_text, after_text, "")
    b_rest = String.replace_prefix(before_text, prefix, "")
    a_rest = String.replace_prefix(after_text, prefix, "")
    suffix = common_suffix_string(b_rest, a_rest)

    {prefix, String.replace_suffix(b_rest, suffix, ""), String.replace_suffix(a_rest, suffix, "")}
  end

  defp common_prefix_string(<<c::utf8, a::binary>>, <<c::utf8, b::binary>>, acc),
    do: common_prefix_string(a, b, acc <> <<c::utf8>>)

  defp common_prefix_string(_, _, acc), do: acc

  defp common_suffix_string(a, b) do
    a |> String.reverse() |> common_prefix_string(String.reverse(b), "") |> String.reverse()
  end

  defp diff_list(before_list, after_list) do
    prefix = common_prefix_list(before_list, after_list, [])
    b_rest = Enum.drop(before_list, length(prefix))
    a_rest = Enum.drop(after_list, length(prefix))
    suffix = common_prefix_list(Enum.reverse(b_rest), Enum.reverse(a_rest), []) |> Enum.reverse()

    {prefix, Enum.take(b_rest, length(b_rest) - length(suffix)),
     Enum.take(a_rest, length(a_rest) - length(suffix))}
  end

  defp common_prefix_list([h | a], [h | b], acc), do: common_prefix_list(a, b, [h | acc])
  defp common_prefix_list(_, _, acc), do: Enum.reverse(acc)
end
