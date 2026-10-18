defmodule Wardrik.Spawned do
  @moduledoc """
  An agent `Wardrik.agent_spawn/3` started, as the fleet lists it, and what
  it started from:

    * `:running` - it ran already, and nothing happened
    * `:store` - it slept, and woke with what it had
    * `:definition` - the host defines it, and it started on that
      definition, with whatever it had stored
    * `:new` - nothing defined it, and the host defined it as it started
  """

  @enforce_keys [:member, :from]
  defstruct [:member, :from]

  @type t() :: %__MODULE__{
          member: Wardrik.Fleet.Member.t(),
          from: :running | :store | :definition | :new
        }
end
