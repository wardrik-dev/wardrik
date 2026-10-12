defmodule Wardrik.AgentOperation do
  @moduledoc """
  An operation on one agent: its request names the agent, and a caller takes
  it only where their grant allows `action/0` on that agent.

  A module implements this beside one of `Wardrik.Query` or
  `Wardrik.Command`, which say what the operation does; this says what it
  does it to. `Wardrik.Subject` decides the grant against the agent's ID, so
  an agent the caller does not reach is one that does not exist to them.
  """

  @doc "The agent `request` acts on."
  @callback subject(request :: struct()) :: Wardrik.AgentID.t()

  @doc "What a grant must allow on the agent for its holder to take it."
  @callback action() :: Wardrik.Grant.action()

  @doc "The error for the agent `id`, where none runs, or none the caller reaches."
  @spec not_found(Wardrik.AgentID.t()) :: Wardrik.Error.t()
  def not_found(%Wardrik.AgentID{} = id),
    do: Wardrik.Error.new(:not_found, "No agent runs under #{id}.")
end
