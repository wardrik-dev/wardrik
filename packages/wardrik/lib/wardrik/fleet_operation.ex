defmodule Wardrik.FleetOperation do
  @moduledoc """
  An operation on every agent under a `Wardrik.AgentID.Prefix`: its request
  names the prefix, and a caller takes it only where their grant reaches the
  whole prefix and allows `action/0`.

  A module implements this beside one of `Wardrik.Query` or
  `Wardrik.Command`, as `Wardrik.AgentOperation` is for one agent.
  `Wardrik.Subject` decides the grant against the prefix, so a prefix outside
  the caller's scope is one with nothing under it, to them.
  """

  @doc "The prefix `request` acts under."
  @callback subject(request :: struct()) :: Wardrik.AgentID.Prefix.t()

  @doc "What a grant must allow under the prefix for its holder to take it."
  @callback action() :: Wardrik.Grant.action()
end
