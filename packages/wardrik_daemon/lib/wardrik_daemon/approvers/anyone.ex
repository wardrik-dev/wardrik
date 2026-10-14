defmodule WardrikDaemon.Approvers.Anyone do
  @moduledoc """
  Anyone in a channel decides what its agents wait on, as its
  `approvers: anyone` says. See `WardrikDaemon.Approvers`.
  """

  defstruct []

  @type t() :: %__MODULE__{}

  defimpl WardrikDaemon.Approvers do
    def decides?(_anyone, _among), do: true
    def asked(_anyone), do: []
    def described(_anyone), do: "anyone in it decides"
  end
end
