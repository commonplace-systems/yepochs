defmodule Yepochs.Crossing do
  @moduledoc """
  The result of crossing one edit between a bridge's endpoints. Spec r2 §15.1.

  ⭐ **Crossing is the operation that provides the Bridge guarantee**: every
  valid edit over the supported data model, authored at either endpoint, can be
  deterministically applied at the other. Strict translation and positional
  re-authoring are its two implementation paths, not two outcomes the caller
  chooses between.
  """

  alias Yepochs.Algorithm
  alias Yepochs.Bridge

  @enforce_keys [:from_epoch, :to_epoch, :update, :mode, :outcome, :bridge_delta, :algorithm]
  defstruct @enforce_keys

  @type mode :: :translated | :reauthored | :absorbed
  @type outcome :: :applied | :absorbed

  @type t :: %__MODULE__{
          from_epoch: String.t(),
          to_epoch: String.t(),
          update: binary(),
          mode: mode(),
          outcome: outcome(),
          bridge_delta: Bridge.Delta.t(),
          algorithm: Algorithm.t()
        }
end
