defmodule Yepochs.Bridge.Delta do
  @moduledoc """
  The append-only result of one successful crossing. Spec r2 §8.4.

  Its correspondence spans are **already oriented to the bridge's left and right
  endpoints**, and may be empty for an absorbed edit. Its receipt is mandatory
  regardless (§17).
  """

  alias Yepochs.Crossing.Receipt
  alias Yepochs.Derivation

  @enforce_keys [:correspondence, :receipt]
  defstruct @enforce_keys

  @type t :: %__MODULE__{correspondence: Derivation.t(), receipt: Receipt.t()}
end
