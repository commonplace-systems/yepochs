defmodule Yepochs.Translation do
  @moduledoc """
  The result of a successful strict translation. Spec r2 §15.3.

  `carried` holds identity spans for the intervals the update authored, in
  **local orientation**: left is the authored endpoint, right is the
  destination (§15.4). `cross/5` reorients them to bridge-left/bridge-right
  before putting them in its delta.

  ⛔ **The caller MUST NOT apply that delta until the translated update has been
  accepted by the destination document.**
  """

  alias Yepochs.Algorithm
  alias Yepochs.Derivation

  @enforce_keys [:update, :carried, :algorithm]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          update: binary(),
          carried: Derivation.t(),
          algorithm: Algorithm.t()
        }
end
