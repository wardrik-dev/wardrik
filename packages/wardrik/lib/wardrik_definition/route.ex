defmodule WardrikDefinition.Route do
  @moduledoc """
  Where one agent's notices go, and which of them: its definition's
  `notify`, which `WardrikNotify` reads as each event comes.

  `:on` lists the kinds of `WardrikNotify.Notice` sent: `:parked` and `:failed`
  by default, and `:finished` for an agent whose answers someone reads
  elsewhere, as a scheduled one's usually are.
  """

  @enforce_keys [:targets]
  defstruct [:targets, on: [:parked, :failed]]

  @type kind() :: :parked | :failed | :finished

  @type t() :: %__MODULE__{targets: [String.t()], on: [kind()]}

  @doc "Every kind a route may send."
  @spec kinds() :: [kind()]
  def kinds, do: [:parked, :failed, :finished]
end
