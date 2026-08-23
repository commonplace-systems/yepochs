defmodule Yepochs.Limits do
  @moduledoc """
  Deterministic resource limits for untrusted input. Spec r2 §23.

  Yjs updates and bridge maps may be hostile. Every public decoding operation
  takes an explicit limit set, and ⛔ **a limit failure returns
  `:limit_exceeded` with no partial derivation or update** — refusing late is
  the same as not refusing.

  The limits are *deterministic*: they depend only on the input, never on
  elapsed time, memory pressure, or process state, so the same input is
  accepted or rejected identically on every node. §23 also forbids creating
  atoms from wire strings, executing stored module names, fetching network
  resources, and using caller process state as implicit input — all of which
  this library observes.
  """

  alias Yepochs.Error

  defstruct max_update_bytes: 8_388_608,
            max_structs: 100_000,
            max_spans: 100_000,
            max_delete_intervals: 100_000,
            max_depth: 64,
            max_output_bytes: 16_777_216

  @type t :: %__MODULE__{
          max_update_bytes: pos_integer(),
          max_structs: non_neg_integer(),
          max_spans: non_neg_integer(),
          max_delete_intervals: non_neg_integer(),
          max_depth: pos_integer(),
          max_output_bytes: pos_integer()
        }

  @doc "Limits with §23's defaults, overridden by `opts`."
  @spec new(keyword() | t()) :: t()
  def new(%__MODULE__{} = limits), do: limits
  def new(opts) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc "Pulls a limit set out of a caller's options, defaulting to §23's values."
  @spec from_opts(keyword()) :: t()
  def from_opts(opts), do: opts |> Keyword.get(:limits, []) |> new()

  @doc "`:ok` when `actual` is within `limit`, else a `:limit_exceeded` error."
  @spec check(t(), atom(), non_neg_integer(), atom()) :: :ok | {:error, Error.t()}
  def check(%__MODULE__{} = limits, key, actual, phase) do
    allowed = Map.fetch!(limits, key)

    if actual <= allowed do
      :ok
    else
      {:error,
       Error.new(:limit_exceeded, phase, details: %{limit: key, allowed: allowed, actual: actual})}
    end
  end
end
