defmodule Wardrik.Caller do
  @moduledoc """
  Who asks for an operation, what they may do, and the host it runs on: the
  `Wardrik.Principal` a change is recorded as made by, the `Wardrik.Grant`
  that decides whether they may make it, and the `Wardrik.Host` whose seams
  the operation asks.

      caller = Wardrik.Caller.new(principal: Wardrik.Principal.new(:user, "jon"), grant: grant, host: host)
      {:ok, snapshot} = Wardrik.Query.run(%Wardrik.Operations.ReadAgent{agent: id}, caller)

  A surface knows its callers its own way, by a token, a shell account or a
  chat user, and answers each with one of these, carrying the host it was
  started with. One that knows someone by their principal alone asks the
  host what they may do with `Wardrik.Host.caller/2`.

  ## An agent as caller

  An agent calling an operation through its tools is a caller too, made with
  `agent/1`: the `:agent` principal of its ID, whose `reply_to` names it, so
  a message it sends another agent with `Wardrik.Operations.Ask` is answered
  back to it as a message of its own; see `Wardrik.Agent`. Other callers
  follow the agent's log for its answer, and name no agent there.
  """

  alias Wardrik.Grant
  alias Wardrik.Host
  alias Wardrik.Principal

  @enforce_keys [:principal, :grant, :host]
  defstruct [:principal, :grant, :host, reply_to: []]

  @type t() :: %__MODULE__{
          principal: Principal.t() | nil,
          grant: Grant.t(),
          host: Host.t(),
          reply_to: [Wardrik.AgentID.t()]
        }

  @doc """
  A caller known as `:principal`, or `nil` where none is known, holding
  `:grant`, on `:host`.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    opts = Keyword.validate!(opts, [:principal, :grant, :host])

    %__MODULE__{
      principal: Keyword.fetch!(opts, :principal),
      grant: Keyword.fetch!(opts, :grant),
      host: Keyword.fetch!(opts, :host)
    }
  end

  @doc """
  The agent `:id`, calling an operation through its tools, holding `:grant`,
  on `:host`: known as the `:agent` principal of its ID, and answered back
  where it asks another agent something.
  """
  @spec agent(keyword()) :: t()
  def agent(opts) do
    opts = Keyword.validate!(opts, [:id, :grant, :host])
    id = Keyword.fetch!(opts, :id)

    caller =
      new(
        principal: Principal.new(:agent, to_string(id)),
        grant: Keyword.fetch!(opts, :grant),
        host: Keyword.fetch!(opts, :host)
      )

    %{caller | reply_to: [id]}
  end

  @doc """
  A caller known as `:principal` who may do anything to every agent, on
  `:host`: one who holds the node itself, as a shell on it, or the terminal
  client.
  """
  @spec root(keyword()) :: t()
  def root(opts) do
    opts = Keyword.validate!(opts, [:principal, :host])
    {:ok, grant} = Grant.new(Wardrik.AgentID.Prefix.all())

    new(
      principal: Keyword.fetch!(opts, :principal),
      grant: grant,
      host: Keyword.fetch!(opts, :host)
    )
  end
end
