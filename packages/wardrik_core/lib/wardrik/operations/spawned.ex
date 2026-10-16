defmodule Wardrik.Operations.Spawned do
  @moduledoc """
  An agent started: as the fleet lists it now, and what it started from,
  `:running` where it ran already, `:store` where it woke from what it had,
  `:definition` where the host defines it, or `:new` where it was defined as
  it started. See `Wardrik.Operations.Spawning`.
  """

  @enforce_keys [:agent, :from]
  defstruct [:agent, :from]

  @type from() :: :running | :store | :definition | :new

  @type t() :: %__MODULE__{agent: Wardrik.Fleet.Member.t(), from: from()}
end
