defmodule Yepochs.Span do
  @moduledoc """
  One clock-interval correspondence between a target Yepoch and a source Yepoch.

  Spec §8.1. For offset `n` where `0 <= n < length`:

      {target_client, target_clock + n} derives from {source_client, source_clock + n}

  Intervals, not item-start pairs, are the durable mapping primitive (§27.1).
  Yjs may consolidate or split structs while retaining references to clocks
  inside their logical ranges, so a mapping keyed on item starts cannot answer
  a reference into the middle of a multi-clock item.
  """

  alias Yepochs.Error

  @enforce_keys [
    :target_client,
    :target_clock,
    :source_client,
    :source_clock,
    :length
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          target_client: non_neg_integer(),
          target_clock: non_neg_integer(),
          source_client: non_neg_integer(),
          source_clock: non_neg_integer(),
          length: pos_integer()
        }

  @typedoc "A Yjs coordinate. Spec §6.1."
  @type item_ref :: {non_neg_integer(), non_neg_integer()}

  @doc """
  Largest Yjs-safe integer. Coordinates and interval ends must not exceed it.
  """
  @spec max_safe_integer() :: pos_integer()
  def max_safe_integer, do: Bitwise.bsl(1, 53) - 1

  @coordinate_fields [:target_client, :target_clock, :source_client, :source_clock]

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(fields) when is_list(fields) do
    with :ok <- validate_coordinates(fields),
         :ok <- validate_length(fields),
         :ok <- validate_no_overflow(fields) do
      {:ok,
       %__MODULE__{
         target_client: Keyword.fetch!(fields, :target_client),
         target_clock: Keyword.fetch!(fields, :target_clock),
         source_client: Keyword.fetch!(fields, :source_client),
         source_clock: Keyword.fetch!(fields, :source_clock),
         length: Keyword.fetch!(fields, :length)
       }}
    end
  end

  defp validate_coordinates(fields) do
    Enum.reduce_while(@coordinate_fields, :ok, fn field, :ok ->
      if safe_non_neg?(Keyword.fetch!(fields, field)),
        do: {:cont, :ok},
        else: {:halt, invalid(field)}
    end)
  end

  defp validate_length(fields) do
    case Keyword.fetch!(fields, :length) do
      value when is_integer(value) and value > 0 -> if safe_non_neg?(value), do: :ok, else: invalid(:length)
      _ -> invalid(:length)
    end
  end

  defp safe_non_neg?(value) do
    is_integer(value) and value >= 0 and value <= max_safe_integer()
  end

  # The half-open interval [clock, clock + length) must keep its last occupied
  # clock inside the safe range on both sides.
  defp validate_no_overflow(fields) do
    length = Keyword.fetch!(fields, :length)

    cond do
      Keyword.fetch!(fields, :target_clock) + length - 1 > max_safe_integer() ->
        invalid(:target_clock)

      Keyword.fetch!(fields, :source_clock) + length - 1 > max_safe_integer() ->
        invalid(:source_clock)

      true ->
        :ok
    end
  end

  defp invalid(field) do
    {:error, Error.new(:invalid_derivation, :derivation, path: [field])}
  end

  @doc "Exclusive end of the target interval. Spec §6.2."
  @spec target_end(t()) :: non_neg_integer()
  def target_end(%__MODULE__{} = span), do: span.target_clock + span.length

  @doc "Exclusive end of the source interval. Spec §6.2."
  @spec source_end(t()) :: non_neg_integer()
  def source_end(%__MODULE__{} = span), do: span.source_clock + span.length

  @doc """
  Canonical ordering key. Spec §9 sorts by target client, target clock, source
  client, then source clock.
  """
  @spec sort_key(t()) :: {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def sort_key(%__MODULE__{} = span) do
    {span.target_client, span.target_clock, span.source_client, span.source_clock}
  end
end
