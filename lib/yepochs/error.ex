defmodule Yepochs.Error do
  @moduledoc """
  Structured failure. Spec §22.

  Errors carry data, not preformatted English as their only diagnostic. Reference
  lists and paths are deterministically ordered so that two runs over the same
  bad input produce the same error term.
  """

  @enforce_keys [:code, :phase]
  defstruct [:code, :phase, :path, :refs, details: %{}]

  @type code ::
          :invalid_epoch_ref
          | :invalid_derivation
          | :bridge_endpoint_mismatch
          | :malformed_update
          | :unsupported_content
          | :unsupported_translation_feature
          | :unsupported_crossing_content
          | :missing_endpoint_state
          | :receipt_conflict
          | :missing_anchor
          | :missing_operation_target
          | :target_identity_collision
          | :incompatible_algorithm
          | :limit_exceeded
          | :invalid_rebase_input
          | :rebase_conflict

  @type phase ::
          :derivation | :bridge | :preflight | :translate | :snapshot | :rebase | :cross

  @type t :: %__MODULE__{
          code: code(),
          phase: phase(),
          path: [atom() | non_neg_integer()] | nil,
          refs: [{non_neg_integer(), non_neg_integer()}] | nil,
          details: map()
        }

  @spec new(code(), phase(), keyword()) :: t()
  def new(code, phase, opts \\ []) do
    %__MODULE__{
      code: code,
      phase: phase,
      path: Keyword.get(opts, :path),
      refs: Keyword.get(opts, :refs),
      details: Keyword.get(opts, :details, %{})
    }
  end
end
