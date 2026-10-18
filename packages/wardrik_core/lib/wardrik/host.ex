defmodule Wardrik.Host do
  @moduledoc """
  What the host running Wardrik answers that core cannot: the store
  everything is kept in, where agents' definitions are kept, which accounts
  people connect, which MCP servers they add, where secrets come from, how
  callers' tokens are made, where requests for triggers go, what each
  principal may do, where agents' files are kept, and what each model call
  actually is.

  `:store` is a `WardrikStore`, the one the host started, or
  `WardrikStore.None`'s where it names none, which raises on the first read
  or write. Each of the others is a value implementing one protocol, which
  carries its own settings, such as the store it keeps things in:

  | Field | Protocol | Default |
  | --- | --- | --- |
  | `:definitions` | `Wardrik.Definition` | `%Wardrik.Definition.None{}` |
  | `:connections` | `Wardrik.Connections` | `%Wardrik.Connections.None{}` |
  | `:servers` | `Wardrik.Servers` | `%Wardrik.Servers.None{}` |
  | `:credentials` | `Wardrik.Credentials` | `%Wardrik.Credentials.None{}` |
  | `:tokens` | `Wardrik.Tokens` | `%Wardrik.Tokens.None{}` |
  | `:triggers` | `Wardrik.Triggers` | `%Wardrik.Triggers.None{}` |
  | `:grants` | `Wardrik.Grants` | `%Wardrik.Grants.None{}` |
  | `:workspace` | `Wardrik.Workspace` | `%Wardrik.Workspace.None{}` |
  | `:dispatch` | `Wardrik.LLM.Dispatch` | `%Wardrik.LLM.Dispatch.Direct{}` |

  `Wardrik`, of the `wardrik` package, builds the host of an application
  embedding Wardrik from its options. A host that puts its own tree
  together names its store and the seams it offers once, as it starts
  `Wardrik.Core`, and hands the same host to whatever surface it starts after it:

      store = WardrikStore.new(adapter: WardrikEcto.Store, repo: MyApp.Repo)

      host =
        Wardrik.Host.new(
          store: store,
          definitions: %MyApp.Definitions{store: store},
          grants: %MyApp.Grants{admins: ["maria"]}
        )

      children = [
        MyApp.Repo,
        {WardrikStore, store},
        {Wardrik.Core, host: host},
        {MyApp.Endpoint, host: host}
      ]

  A seam it does not name is its default: a None, which answers each
  function with `:unsupported`, or with what having none means in that
  function's own terms, as `[]` grants, and for `:dispatch` `Direct`, which
  makes each model call as it stands. So every field is always a value its
  protocol answers for, and code asks it without first asking whether
  there is one.

  The host travels with the work, never with what is stored: each
  `Wardrik.Caller` carries it to what it acts on, and each agent is
  handed it as it starts, wakes or restarts on another node (see
  `Wardrik.Agent`). A node runs one `Wardrik.Core`, so one host; see `Wardrik.Core`.

  A caller is made here for someone known by a principal, holding the grant
  the host's `Wardrik.Grants` gives them:

      {:ok, caller} = Wardrik.Host.caller(host, principal: maria, subject: ~A"acme/triage")

  The accessors answer each seam's value, so code that acts on the agents
  names the field, never an implementation.
  """

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Caller
  alias Wardrik.Error
  alias Wardrik.Grant
  alias Wardrik.Principal

  defstruct store: %WardrikStore.None{},
            definitions: %Wardrik.Definition.None{},
            connections: %Wardrik.Connections.None{},
            servers: %Wardrik.Servers.None{},
            credentials: %Wardrik.Credentials.None{},
            tokens: %Wardrik.Tokens.None{},
            triggers: %Wardrik.Triggers.None{},
            grants: %Wardrik.Grants.None{},
            workspace: %Wardrik.Workspace.None{},
            dispatch: %Wardrik.LLM.Dispatch.Direct{},
            audit: Wardrik.Audit

  @type t() :: %__MODULE__{
          store: WardrikStore.t(),
          definitions: Wardrik.Definition.t(),
          connections: Wardrik.Connections.t(),
          servers: Wardrik.Servers.t(),
          credentials: Wardrik.Credentials.t(),
          tokens: Wardrik.Tokens.t(),
          triggers: Wardrik.Triggers.t(),
          grants: Wardrik.Grants.t(),
          workspace: Wardrik.Workspace.t(),
          dispatch: Wardrik.LLM.Dispatch.t(),
          audit: GenServer.name()
        }

  @seams [
    :definitions,
    :connections,
    :servers,
    :credentials,
    :tokens,
    :triggers,
    :grants,
    :workspace,
    :dispatch
  ]

  @doc """
  The host keeping everything in the `:store` `opts` names, offering the
  seams it names, each by its value, and the None of each it leaves out.

      Wardrik.Host.new(store: store, tokens: %WardrikHTTP.Tokens{store: store})
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    opts = Keyword.validate!(opts, [:store, :audit | @seams])
    struct!(__MODULE__, opts)
  end

  @doc """
  The person or system `:principal` names as a caller acting on
  `:subject`, an agent or the agents under a prefix: holding the first grant
  the host's `Wardrik.Grants` gives them whose scope reaches it. `:not_found`
  where none does, or where nobody is known, a `nil` principal, as for a
  turn nobody asked for: a subject outside a caller's reach is one that does
  not exist to them.

  An agent, as its `:agent` principal names it, is core's own: it may read
  and message its owner's agents, as `Wardrik.AgentID.Prefix.owner/1` names
  them, whatever the host's grants say, so a turn one agent asks of another
  reads and messages for it what it could itself.

      {:ok, caller} = Wardrik.Host.caller(host, principal: maria, subject: ~A"acme/triage")
      :ok = Wardrik.Agent.decide(~A"acme/triage", decisions, caller)
  """
  @spec caller(t(), keyword()) :: {:ok, Caller.t()} | {:error, Error.t()}
  def caller(%__MODULE__{} = host, opts) do
    opts = Keyword.validate!(opts, [:principal, :subject])
    principal = Keyword.fetch!(opts, :principal)
    subject = Keyword.fetch!(opts, :subject)

    case Enum.find(granted(host, principal), &Prefix.covers?(&1.scope, subject)) do
      %Grant{} = grant ->
        {:ok, Caller.new(principal: principal, grant: grant, host: host)}

      nil ->
        {:error, Error.new(:not_found, "Nothing at #{subject} is within this caller's reach.")}
    end
  end

  defp granted(_host, nil), do: []

  defp granted(host, principal),
    do:
      own(Principal.type(principal), principal) ++ Wardrik.Grants.grants(grants(host), principal)

  defp own(:agent, principal) do
    {:ok, grant} =
      Grant.new(Prefix.owner(AgentID.parse!(Principal.id(principal))), [:read, :message])

    [grant]
  end

  defp own(_type, _principal), do: []

  @doc "The `WardrikStore` everything is kept in."
  @spec store(t()) :: WardrikStore.t()
  def store(%__MODULE__{store: store}), do: store

  @doc "The `Wardrik.Definition` agents' definitions go to."
  @spec definitions(t()) :: Wardrik.Definition.t()
  def definitions(%__MODULE__{definitions: definitions}), do: definitions

  @doc "The `Wardrik.Connections` the accounts people and orgs connect are asked of."
  @spec connections(t()) :: Wardrik.Connections.t()
  def connections(%__MODULE__{connections: connections}), do: connections

  @doc "The `Wardrik.Servers` the MCP servers orgs and people add are asked of."
  @spec servers(t()) :: Wardrik.Servers.t()
  def servers(%__MODULE__{servers: servers}), do: servers

  @doc "The `Wardrik.Credentials` tools' credentials and providers' keys are resolved through."
  @spec credentials(t()) :: Wardrik.Credentials.t()
  def credentials(%__MODULE__{credentials: credentials}), do: credentials

  @doc "The `Wardrik.Tokens` callers' tokens are made, listed and revoked through."
  @spec tokens(t()) :: Wardrik.Tokens.t()
  def tokens(%__MODULE__{tokens: tokens}), do: tokens

  @doc "The `Wardrik.Triggers` requests from outside are delivered to."
  @spec triggers(t()) :: Wardrik.Triggers.t()
  def triggers(%__MODULE__{triggers: triggers}), do: triggers

  @doc """
  The name of the `Wardrik.Audit` log `Wardrik.Core` starts for this host, which
  surfaces record changes in; `Wardrik.Audit` unless `:audit` names
  another.
  """
  @spec audit(t()) :: GenServer.name()
  def audit(%__MODULE__{audit: audit}), do: audit

  @doc "The `Wardrik.Workspace` agents' files are kept in."
  @spec workspace(t()) :: Wardrik.Workspace.t()
  def workspace(%__MODULE__{workspace: workspace}), do: workspace

  @doc "The `Wardrik.LLM.Dispatch` every model call is admitted and settled through."
  @spec dispatch(t()) :: Wardrik.LLM.Dispatch.t()
  def dispatch(%__MODULE__{dispatch: dispatch}), do: dispatch

  @doc "The `Wardrik.Grants` that says what each principal may do."
  @spec grants(t()) :: Wardrik.Grants.t()
  def grants(%__MODULE__{grants: grants}), do: grants
end
