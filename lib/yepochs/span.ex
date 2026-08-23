defmodule Yepochs.Span do
  @moduledoc """
  One clock-interval correspondence between a bridge's two endpoints.
  Spec r2 §8.1.

  For offset `n` where `0 <= n < length`:

      {left_client, left_clock + n} corresponds to {right_client, right_clock + n}

  ⭐ `left` and `right` are a **stable orientation, not a direction of travel**.
  For a fresh snapshot derivation the left side is the origin (old) document and
  the right side is the newly derived one — but once attached to a bridge the
  names refer only to that bridge's endpoint orientation, and edits cross in
  either direction (§6.6).

  Intervals, not item-start pairs, are the durable primitive (§27.1): Yjs may
  consolidate or split structs while retaining references to clocks inside their
  logical ranges, so a mapping keyed on item starts cannot answer a reference
  into the middle of a multi-clock item.
  """

  alias Yepochs.Error

  @enforce_keys [:left_client, :left_clock, :right_client, :right_clock, :length]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          left_client: non_neg_integer(),
          left_clock: non_neg_integer(),
          right_client: non_neg_integer(),
          right_clock: non_neg_integer(),
          length: pos_integer()
        }

  @typedoc "A Yjs coordinate. Spec §6.1."
  @type item_ref :: {non_neg_integer(), non_neg_integer()}

  @doc "Largest Yjs-safe integer. Coordinates and interval ends must not exceed it."
  @spec max_safe_integer() :: pos_integer()
  def max_safe_integer, do: Bitwise.bsl(1, 53) - 1

  @coordinate_fields [:left_client, :left_clock, :right_client, :right_clock]

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(fields) when is_list(fields) do
    with :ok <- validate_coordinates(fields),
         :ok <- validate_length(fields),
         :ok <- validate_no_overflow(fields) do
      {:ok,
       %__MODULE__{
         left_client: Keyword.fetch!(fields, :left_client),
         left_clock: Keyword.fetch!(fields, :left_clock),
         right_client: Keyword.fetch!(fields, :right_client),
         right_clock: Keyword.fetch!(fields, :right_clock),
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
      v when is_integer(v) and v > 0 -> if safe_non_neg?(v), do: :ok, else: invalid(:length)
      _ -> invalid(:length)
    end
  end

  defp safe_non_neg?(v), do: is_integer(v) and v >= 0 and v <= max_safe_integer()

  # The half-open interval [clock, clock + length) must keep its last occupied
  # clock inside the safe range on both sides.
  defp validate_no_overflow(fields) do
    len = Keyword.fetch!(fields, :length)

    cond do
      Keyword.fetch!(fields, :left_clock) + len - 1 > max_safe_integer() -> invalid(:left_clock)
      Keyword.fetch!(fields, :right_clock) + len - 1 > max_safe_integer() -> invalid(:right_clock)
      true -> :ok
    end
  end

  defp invalid(field), do: {:error, Error.new(:invalid_derivation, :derivation, path: [field])}

  @doc "Exclusive end of the left interval. Spec §6.2."
  @spec left_end(t()) :: non_neg_integer()
  def left_end(%__MODULE__{} = s), do: s.left_clock + s.length

  @doc "Exclusive end of the right interval. Spec §6.2."
  @spec right_end(t()) :: non_neg_integer()
  def right_end(%__MODULE__{} = s), do: s.right_clock + s.length

  @doc """
  Canonical ordering key. r2 §9 sorts LEFT-first: left client, left clock, right
  client, then right clock. (r1 sorted target-first; the canonical order of the
  same logical derivation therefore changed between revisions.)
  """
  @spec sort_key(t()) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def sort_key(%__MODULE__{} = s), do: {s.left_client, s.left_clock, s.right_client, s.right_clock}

  @doc "Exchanges the two sides. Reorienting is presentation, not a new relationship (§13)."
  @spec flip(t()) :: t()
  def flip(%__MODULE__{} = s) do
    %__MODULE__{
      left_client: s.right_client,
      left_clock: s.right_clock,
      right_client: s.left_client,
      right_clock: s.left_clock,
      length: s.length
    }
  end
end
