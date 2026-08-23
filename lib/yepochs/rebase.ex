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

  The Y.Text adapter is implemented. Other planes are refused with
  `:unsupported_crossing_content` rather than silently dropped — §10.2's rule
  against flattening applies here too.
  """

  alias Yelixer.Doc
  alias Yelixer.Encoding
  alias Yelixer.Types.Text
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
    with {:ok, author} <- fetch_author(opts),
         {:ok, changes} <- text_diffs(before, edited) do
      apply_changes(changes, target, author)
    end
  end

  defp fetch_author(opts) do
    case Keyword.get(opts, :author) do
      id when is_integer(id) and id >= 0 -> {:ok, id}
      _ -> {:error, Error.new(:invalid_rebase_input, :rebase, path: [:author])}
    end
  end

  # Every named type whose visible text differs between before and edited.
  defp text_diffs(%Doc{} = before, %Doc{} = edited) do
    names = type_names(before) ++ type_names(edited)

    names
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      b = Text.to_string(before, name)
      e = Text.to_string(edited, name)

      cond do
        b == e -> {:cont, {:ok, acc}}
        true -> {:cont, {:ok, acc ++ [{name, b, e}]}}
      end
    end)
  end

  # ⚠️ Derived from the STORE, not from `doc.types`. The type registry is
  # populated by the type API and by decoding, but a doc can hold content under
  # a name the registry never learned -- the same trap that makes
  # `Yelixer.Doc.snapshot_update/1` emit an empty snapshot (see
  # `Yepochs.Snapshotter`). Trusting the registry here made a delete look like
  # an absorbed no-op: a wrong answer, not an error.
  defp type_names(%Doc{types: types, store: store}) do
    from_store =
      store
      |> Yelixer.BlockStore.all_items()
      |> Enum.flat_map(fn
        %{parent: {:named, name}} -> [name]
        _ -> []
      end)

    (Map.keys(types) ++ from_store)
    |> Enum.uniq()
    |> Enum.reject(fn n ->
      String.starts_with?(n, "__sub:") or String.contains?(n, "::child::") or
        String.ends_with?(n, "::children")
    end)
  end

  defp apply_changes([], _target, _author) do
    # §19.2: the observable effect is already true at the destination.
    {:ok, %Result{update: <<>>, outcome: :absorbed, algorithm: Algorithm.rebase()}}
  end

  defp apply_changes(changes, %Doc{} = target, author) do
    base = %{target | client_id: author}

    Enum.reduce_while(changes, {:ok, base, false}, fn {name, before_text, after_text},
                                                      {:ok, doc, _changed?} ->
      current = Text.to_string(doc, name)

      case reauthor_text(doc, name, current, before_text, after_text) do
        {:ok, doc, changed?} -> {:cont, {:ok, doc, changed?}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _doc, false} ->
        {:ok, %Result{update: <<>>, outcome: :absorbed, algorithm: Algorithm.rebase()}}

      {:ok, doc, true} ->
        {:ok,
         %Result{
           update: Encoding.encode_diff(doc, Yelixer.BlockStore.state_vector(target.store)),
           outcome: :applied,
           algorithm: Algorithm.rebase()
         }}

      {:error, _} = error ->
        error
    end
  end

  # A single contiguous replacement, located by common prefix and suffix. This
  # is the whole of the 0.1 Y.Text adapter's competence, and it is total only
  # over edits of that shape -- §22 `:rebase_conflict` is for the rest.
  defp reauthor_text(doc, name, current, before_text, after_text) do
    {prefix, removed, inserted} = diff(before_text, after_text)

    cond do
      # Already satisfied at the destination.
      current == after_text ->
        {:ok, doc, false}

      # The destination must still contain what the edit expects to replace.
      not applicable?(current, prefix, removed) ->
        {:error,
         Error.new(:rebase_conflict, :rebase,
           details: %{type: name, expected_prefix: prefix, removed: removed}
         )}

      true ->
        doc = if removed != "", do: Text.delete(doc, name, byte_size(prefix), String.length(removed)), else: doc
        doc = if inserted != "", do: Text.insert(doc, name, byte_size(prefix), inserted), else: doc
        {:ok, doc, true}
    end
  end

  defp applicable?(current, prefix, removed) do
    String.starts_with?(current, prefix) and
      String.starts_with?(String.slice(current, String.length(prefix)..-1//1), removed)
  end

  # Longest common prefix and suffix, yielding one replaced middle.
  defp diff(before_text, after_text) do
    prefix = common_prefix(before_text, after_text, "")
    b_rest = String.replace_prefix(before_text, prefix, "")
    a_rest = String.replace_prefix(after_text, prefix, "")
    suffix = common_suffix(b_rest, a_rest)

    {prefix, String.replace_suffix(b_rest, suffix, ""), String.replace_suffix(a_rest, suffix, "")}
  end

  defp common_prefix(<<c::utf8, a::binary>>, <<c::utf8, b::binary>>, acc),
    do: common_prefix(a, b, acc <> <<c::utf8>>)

  defp common_prefix(_, _, acc), do: acc

  defp common_suffix(a, b) do
    a
    |> String.reverse()
    |> common_prefix(String.reverse(b), "")
    |> String.reverse()
  end
end
