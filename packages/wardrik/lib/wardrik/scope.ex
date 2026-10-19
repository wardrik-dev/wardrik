defmodule Wardrik.Scope do
  @moduledoc """
  Who acts through `Wardrik`, and where: the `Wardrik.Host` the agents run
  on, and the `Wardrik.Token` saying who acts and what they may do. It is
  the first argument of every function of `Wardrik`, as a Phoenix scope is
  of a context's.

  `Wardrik.as/3` makes one, with the token the host's `Wardrik.Issuer`
  issues someone it knows:

      scope = Wardrik.as(wardrik, maria)

  A surface that holds a token for its callers, as the HTTP API holds a
  bearer token's, makes one with it:

      scope = Wardrik.Scope.new(host, token)

  ## An agent's scope

  An agent acting through its tools acts in a scope too, which `agent/2`
  names it in, so a message it sends another agent with
  `Wardrik.agent_ask/4` is answered back to it as a message of its own;
  see "Answering another agent" in `Wardrik.Agent`. Other scopes follow the
  agent's log for its answer, and name no agent there.
  """

  @enforce_keys [:host, :token]
  defstruct [:host, :token, reply_to: []]

  @type t() :: %__MODULE__{
          host: Wardrik.Host.t(),
          token: Wardrik.Token.t(),
          reply_to: [Wardrik.AgentAddress.t()]
        }

  @doc "The scope of `token` on `host`."
  @spec new(Wardrik.Host.t(), Wardrik.Token.t()) :: t()
  def new(%Wardrik.Host{} = host, %Wardrik.Token{} = token),
    do: %__MODULE__{host: host, token: token}

  @doc "`scope`, as the agent `id` acts in it: answered back where it asks another agent something."
  @spec agent(t(), Wardrik.AgentAddress.t()) :: t()
  def agent(%__MODULE__{} = scope, id), do: %{scope | reply_to: [id]}
end
