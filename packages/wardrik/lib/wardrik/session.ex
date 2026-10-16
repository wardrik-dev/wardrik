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
  """

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Caller

  @enforce_keys [:host, :principal]
  defstruct [:host, :principal, :grant]

  @type t() :: %__MODULE__{
          host: Wardrik.Host.t(),
          principal: Wardrik.Principal.t() | nil,
          grant: Wardrik.Grant.t() | nil
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
  The caller `session` is to an operation on `subject`: with its own grant,
  or with the first the host gives its principal that reaches `subject`.
  The deployment itself is reached by a grant over every agent, which a
  principal without one may not act on.
  """
  @spec caller(t(), AgentID.t() | Prefix.t() | Wardrik.Deployment.t()) ::
          {:ok, Caller.t()} | {:error, Wardrik.Error.t()}
  def caller(%__MODULE__{grant: nil} = session, %Wardrik.Deployment{}) do
    with {:error, _none} <-
           Wardrik.Host.caller(session.host, principal: session.principal, subject: Prefix.all()),
         do: {:error, Wardrik.Error.new(:forbidden, "This caller may not act on the deployment.")}
  end

  def caller(%__MODULE__{grant: nil} = session, subject),
    do: Wardrik.Host.caller(session.host, principal: session.principal, subject: subject)

  def caller(%__MODULE__{} = session, _subject),
    do: {:ok, Caller.new(principal: session.principal, grant: session.grant, host: session.host)}
end
