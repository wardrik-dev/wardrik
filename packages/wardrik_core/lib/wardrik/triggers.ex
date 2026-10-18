defprotocol Wardrik.Triggers do
  @moduledoc """
  The triggers a request from outside reaches, such as a webhook a service
  sends when something happens there: the host's module checks the request
  and asks the agent.

  A host names the value once, as the `:triggers` of its `Wardrik.Host`,
  and `Wardrik.agent_trigger_deliver/4` hands it each request, whichever surface
  it came from. The value carries what its implementation needs, such as
  where each trigger's secret is found:

      Wardrik.Host.new(triggers: WardrikTrigger.new(secrets: secrets))

  A host that takes none has `Wardrik.Triggers.None`, which answers
  `:unsupported`, and so does `Deliver`.

  The request is checked by the trigger itself, against a secret it and the
  sender share, so whoever sends it holds no credential of the server's. The
  implementation answers:

    * `{:ok, :asked}` - the request was new, and the agent was asked
    * `{:ok, :seen}` - the trigger has had this request before, so the agent
      was not asked again
    * `{:error, :not_found}` - the agent has no trigger of that name that
      takes requests
    * `{:error, :forbidden, message}` - the request is not the sender's: its
      signature does not match. `Deliver` answers it as `:not_found`
    * `{:error, :unavailable, message}` - it could not be delivered now, so a
      sender that tries again delivers it later
  """

  @typedoc "A request as it arrived: its headers, names in lower case, and its body."
  @type request() :: %{headers: [{String.t(), String.t()}], body: binary()}

  @doc "Delivers the `:request` `opts` name to the trigger `name` of the agent `id`."
  @spec deliver(t(), Wardrik.AgentID.t(), String.t(), request: request()) ::
          {:ok, :asked | :seen}
          | {:error, :not_found}
          | {:error, :forbidden | :unavailable, String.t()}
          | :unsupported
  def deliver(triggers, id, name, opts)
end
