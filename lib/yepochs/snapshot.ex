defmodule Yepochs.Snapshot do
  @moduledoc """
  A deterministic re-authoring of a document's observable state into a fresh
  Yjs identity space. Spec r2 §10.1.

  ⭐ **It deliberately carries no target Yepoch reference.** The caller commonly
  learns that reference only after storing or hashing the snapshot artifact —
  keeping the derivation endpoint-free is what avoids a content-addressing
  cycle (§6.6).
  """

  alias Yepochs.Algorithm
  alias Yepochs.Derivation

  @enforce_keys [:update, :derivation, :algorithm]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          update: binary(),
          derivation: Derivation.t(),
          algorithm: Algorithm.t()
        }
end
