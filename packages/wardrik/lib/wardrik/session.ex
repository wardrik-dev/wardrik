defmodule Wardrik.Session do
  @moduledoc """
  Someone acting through `Wardrik`: the host the agents run on, the
  `Wardrik.Principal` acting, and the `Wardrik.Grant` they act with, or
  `nil` where the host's `Wardrik.Grants` gives them one for each agent or
  prefix they act on.

      session = Wardrik.as(wardrik, maria)

  A surface that knows its callers by a grant of their own, as the HTTP API
  knows a token's, makes one with it:

      session = Wardrik.Session.new(host: host, principal: principal, grant: grant)

  ## An agent's session

  An agent acting through its tools has a session too, made with
  `agent/1`: the `:agent` principal of its ID, whose `reply_to` names it, so
  a message it sends another agent with `Wardrik.agent_ask/4` is answered
  back to it as a message of its own; see "Answering another agent" in
  `Wardrik.Agent`. Other sessions follow the agent's log for its answer, and
  name no agent there.
  """

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Caller

  @enforce_keys [:host, :principal]
  defstruct [:host, :principal, :grant, reply_to: []]

  @type t() :: %__MODULE__{
          host: Wardrik.Host.t(),
          principal: Wardrik.Principal.t() | nil,
          grant: Wardrik.Grant.t() | nil,
          reply_to: [AgentID.t()]
        }

  @doc """
  The session of `:principal` on `:host`, acting with `:grant`, or with what
  the host's `Wardrik.Grants` gives them where it is left out.
  """
  @spec new(
          host: Wardrik.Host.t(),
          principal: Wardrik.Principal.t() | nil,
          grant: Wardrik.Grant.t()
        ) ::
          t()
  def new(opts) do
    opts = Keyword.validate!(opts, [:host, :principal, :grant])
    struct!(__MODULE__, opts)
  end

  @doc """
  The session of `:principal` on `:host`, who may do anything to every
  agent: one who holds the node itself, as a shell on it, or the terminal
  client.
  """
  @spec root(host: Wardrik.Host.t(), principal: Wardrik.Principal.t()) :: t()
  def root(opts) do
    opts = Keyword.validate!(opts, [:host, :principal])
    {:ok, grant} = Wardrik.Grant.new(Prefix.all())

    new(
      host: Keyword.fetch!(opts, :host),
      principal: Keyword.fetch!(opts, :principal),
      grant: grant
    )
  end

  @doc """
  The session of the agent `:id`, acting through its tools with `:grant`, on
  `:host`: known as the `:agent` principal of its ID, and answered back where
  it asks another agent something.
  """
  @spec agent(id: AgentID.t(), grant: Wardrik.Grant.t(), host: Wardrik.Host.t()) :: t()
  def agent(opts) do
    opts = Keyword.validate!(opts, [:id, :grant, :host])
    id = Keyword.fetch!(opts, :id)

    %{
      new(
        host: Keyword.fetch!(opts, :host),
        principal: Wardrik.Principal.new(:agent, to_string(id)),
        grant: Keyword.fetch!(opts, :grant)
      )
      | reply_to: [id]
    }
  end

  @doc """
  The caller `session` is to what it acts on, `subject`: with its own grant,
  or with the first the host gives its principal that reaches `subject`.
  """
  @spec caller(t(), AgentID.t() | Prefix.t()) :: {:ok, Caller.t()} | {:error, Wardrik.Error.t()}
  def caller(%__MODULE__{grant: nil} = session, subject),
    do: Wardrik.Host.caller(session.host, principal: session.principal, subject: subject)

  def caller(%__MODULE__{} = session, _subject),
    do: {:ok, Caller.new(principal: session.principal, grant: session.grant, host: session.host)}
end
