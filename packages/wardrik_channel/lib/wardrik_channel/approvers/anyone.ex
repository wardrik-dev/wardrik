defmodule WardrikChannel.Approvers.Anyone do
  @moduledoc """
  Anyone in a channel decides what its agents wait on, as its
  `approvers: anyone` says. See `WardrikChannel.Approvers`.
  """

  defstruct []

  @type t() :: %__MODULE__{}

  defimpl WardrikChannel.Approvers do
    def decides?(_anyone, _include?), do: true
    def asked(_anyone), do: []
    def described(_anyone), do: "anyone in it decides"
  end
end
