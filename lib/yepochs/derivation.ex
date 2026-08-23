defmodule Yepochs.Derivation do
  @moduledoc """
  An endpoint-free, canonical set of clock spans. Spec §6.5, §8.2, §9.

  Each span pairs coordinates at the two endpoints: `origin/old <-> derived/new`.
  Derivation provenance is directed — the new representation was produced from
  the old one — but ⭐ **the correspondence itself is a partial bijection and can
  be looked up in either direction** (r2 §6.5). Despite the provenance-oriented
  name, the value is mathematically an endpoint-free correspondence, and a bridge
  may monotonically union derivations produced by crossings in either direction
  once their spans are oriented to its left and right endpoints (§8.2).

  Keeping a derivation endpoint-free is what avoids a content-addressing cycle
  (§6.6): a caller can build the derivation, place it in an object, hash that
  object, and only then attach the resulting Yepoch reference.
  """

  alias Yepochs.Error
  alias Yepochs.Span

  @format_version 1

  @enforce_keys [:format_version, :spans]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          format_version: pos_integer(),
          spans: [Span.t()]
        }

  @spec format_version() :: pos_integer()
  def format_version, do: @format_version

  @spec new([Span.t()]) :: {:ok, t()} | {:error, Error.t()}
  def new(spans) when is_list(spans) do
    derivation = %__MODULE__{format_version: @format_version, spans: spans}

    case validate(derivation) do
      :ok -> {:ok, derivation}
      {:error, _} = error -> error
    end
  end

  @doc """
  Spec §9. Enforces the format version, span wellformedness, and — the part
  that carries the semantics — that neither side contains overlapping mapped
  intervals, so the derivation is a partial bijection at every mapped clock
  (invariant 4).
  """
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{format_version: v}) when v != @format_version do
    {:error, Error.new(:invalid_derivation, :derivation, path: [:format_version])}
  end

  def validate(%__MODULE__{spans: spans}) when is_list(spans) do
    with :ok <- validate_spans(spans),
         :ok <- validate_no_overlap(spans, :left),
         :ok <- validate_no_overlap(spans, :right) do
      :ok
    end
  end

  def validate(_), do: {:error, Error.new(:invalid_derivation, :derivation)}

  defp validate_spans(spans) do
    spans
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {span, index}, :ok ->
      case span do
        %Span{} = s ->
          # Re-run the field rules, so a struct built by hand rather than
          # through Span.new/1 cannot smuggle a bad coordinate in.
          case Span.new(
                 right_client: s.right_client,
                 right_clock: s.right_clock,
                 left_client: s.left_client,
                 left_clock: s.left_clock,
                 length: s.length
               ) do
            {:ok, _} -> {:cont, :ok}
            {:error, err} -> {:halt, {:error, %{err | path: [index | err.path || []]}}}
          end

        _ ->
          {:halt, {:error, Error.new(:invalid_derivation, :derivation, path: [index])}}
      end
    end)
  end

  # Two intervals on the same side and same client may touch but never overlap.
  defp validate_no_overlap(spans, side) do
    {client_key, clock_key} =
      case side do
        :right -> {:right_client, :right_clock}
        :left -> {:left_client, :left_clock}
      end

    spans
    |> Enum.group_by(&Map.fetch!(&1, client_key))
    |> Enum.reduce_while(:ok, fn {_client, group}, :ok ->
      group
      |> Enum.sort_by(&Map.fetch!(&1, clock_key))
      |> adjacent_pairs()
      |> Enum.find(fn {a, b} ->
        Map.fetch!(a, clock_key) + a.length > Map.fetch!(b, clock_key)
      end)
      |> case do
        nil -> {:cont, :ok}
        _ -> {:halt, {:error, Error.new(:invalid_derivation, :derivation, path: [side])}}
      end
    end)
  end

  defp adjacent_pairs(list), do: Enum.zip(list, Enum.drop(list, 1))

  @doc """
  Spec §9. Validates, sorts into canonical order, and coalesces spans that are
  contiguous on *both* sides with matching client IDs.

  Normalization never reorders semantic content, fills gaps, or infers a
  mapping — a gap in coverage is a fact about the derivation, and preflight is
  where it is allowed to matter (§14).
  """
  @spec normalize(t()) :: {:ok, t()} | {:error, Error.t()}
  def normalize(%__MODULE__{} = derivation) do
    case validate(derivation) do
      :ok ->
        spans =
          derivation.spans
          |> Enum.sort_by(&Span.sort_key/1)
          |> coalesce()

        {:ok, %__MODULE__{format_version: @format_version, spans: spans}}

      {:error, _} = error ->
        error
    end
  end

  defp coalesce([]), do: []

  defp coalesce([first | rest]) do
    {acc, last} =
      Enum.reduce(rest, {[], first}, fn span, {acc, pending} ->
        if contiguous?(pending, span) do
          {acc, %Span{pending | length: pending.length + span.length}}
        else
          {[pending | acc], span}
        end
      end)

    Enum.reverse([last | acc])
  end

  defp contiguous?(%Span{} = a, %Span{} = b) do
    a.right_client == b.right_client and
      a.left_client == b.left_client and
      Span.right_end(a) == b.right_clock and
      Span.left_end(a) == b.left_clock
  end

  @doc """
  Exchanges left and right coordinates in every span, then normalizes.

  Fails if the input is not a valid partial bijection — a reoriented mapping is
  only meaningful when each side is unambiguous. For every valid derivation,
  `invert(invert(d)) == normalize(d)` (§13). Reorienting swaps presentation, not
  capability: the same edits can cross in both directions (invariant 6).
  """
  @spec invert(t()) :: {:ok, t()} | {:error, Error.t()}
  def invert(%__MODULE__{} = derivation) do
    case validate(derivation) do
      :ok ->
        derivation.spans
        |> Enum.map(&Span.flip/1)
        |> then(&%__MODULE__{format_version: @format_version, spans: &1})
        |> normalize()

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Portable wire value. Spec §8.5: string keys, safe non-negative integers, a
  canonically sorted span list, and no Elixir module names or atoms derived
  from input.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = derivation) do
    %{
      "version" => derivation.format_version,
      "spans" => Enum.map(Enum.sort_by(derivation.spans, &Span.sort_key/1), &span_to_map/1)
    }
  end

  defp span_to_map(%Span{} = s) do
    %{
      "right_client" => s.right_client,
      "right_clock" => s.right_clock,
      "left_client" => s.left_client,
      "left_clock" => s.left_clock,
      "length" => s.length
    }
  end

  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(%{"version" => @format_version, "spans" => spans}) when is_list(spans) do
    spans
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      case span_from_map(raw) do
        {:ok, span} -> {:cont, {:ok, [span | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> new(Enum.reverse(reversed))
      {:error, _} = error -> error
    end
  end

  def from_map(%{"version" => _}),
    do: {:error, Error.new(:invalid_derivation, :derivation, path: [:format_version])}

  def from_map(_), do: {:error, Error.new(:invalid_derivation, :derivation)}

  defp span_from_map(%{
         "right_client" => tc,
         "right_clock" => tk,
         "left_client" => sc,
         "left_clock" => sk,
         "length" => len
       }) do
    Span.new(
      right_client: tc,
      right_clock: tk,
      left_client: sc,
      left_clock: sk,
      length: len
    )
  end

  defp span_from_map(_), do: {:error, Error.new(:invalid_derivation, :derivation, path: [:spans])}
end
