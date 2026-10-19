defprotocol Wardrik.AgentAddress do
  @moduledoc """
  What an agent's process is addressed by: a `Wardrik.AgentID`, or one of
  its `Wardrik.Thread`s. `Wardrik.Fleet` starts, finds and stops one by it,
  its events are published and logged under it, and the `agent_*`
  functions of `Wardrik` act on it.

  Each has a resource of its own, which a `Wardrik.Statement` reaches and
  which it acts as, and an agent, whose definition it runs on.

      Wardrik.AgentAddress.agent(Wardrik.Thread.parse!("acme/triage/C1-1696.1234"))
      #=> ~A"acme/triage"

  Its text is what `to_string/1` writes, and `Wardrik.AgentID.address/1`
  reads it back.
  """

  @doc "The resource `address` names, as a `Wardrik.Statement` names it."
  @spec resource(t()) :: Wardrik.Resource.t()
  def resource(address)

  @doc "The agent `address` is, or is a thread of."
  @spec agent(t()) :: Wardrik.AgentID.t()
  def agent(address)
end
