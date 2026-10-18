defmodule Wardrik.Caller do
  @moduledoc """
  Who acts on the agents, what they may do, and the host they run on: the
  `Wardrik.Principal` a change is recorded as made by, the `Wardrik.Grant`
  that decides whether they may make it, and the `Wardrik.Host` whose seams
  answer for it.

      caller = Wardrik.Caller.new(principal: Wardrik.Principal.new(:user, "jon"), grant: grant, host: host)
      :ok = Wardrik.Agent.decide(id, %{"call_1" => :approve}, caller)

  A surface knows its callers its own way, by a token, a shell account or a
  chat user, and answers each with one of these, carrying the host it was
  started with. One that knows someone by their principal alone asks the
  host what they may do with `Wardrik.Host.caller/2`.
  """

  alias Wardrik.Grant
  alias Wardrik.Host
  alias Wardrik.Principal

  @enforce_keys [:principal, :grant, :host]
  defstruct [:principal, :grant, :host]

  @type t() :: %__MODULE__{principal: Principal.t() | nil, grant: Grant.t(), host: Host.t()}

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
