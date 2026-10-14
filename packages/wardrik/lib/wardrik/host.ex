defmodule Wardrik.Host do
  @moduledoc """
  What the host running Wardrik answers that core cannot: the store
  everything is kept in, where agents' definitions are kept, which accounts
  people connect, where secrets come from, how callers' tokens are made,
  where requests for triggers go, what each principal may do, and where
  agents' files are kept.

  `:store` is a `WardrikStore`, the one the host started, or
  `WardrikStore.None`'s where it names none, which raises on the first read
  or write. Each of the others is a value implementing one protocol, which
  carries its own settings, such as the store it keeps things in:

  | Field | Protocol | None |
  | --- | --- | --- |
  | `:definitions` | `Wardrik.Definition` | `%Wardrik.Definition.None{}` |
  | `:connections` | `Wardrik.Connections` | `%Wardrik.Connections.None{}` |
  | `:credentials` | `Wardrik.Credentials` | `%Wardrik.Credentials.None{}` |
  | `:tokens` | `Wardrik.Tokens` | `%Wardrik.Tokens.None{}` |
  | `:triggers` | `Wardrik.Triggers` | `%Wardrik.Triggers.None{}` |
  | `:grants` | `Wardrik.Grants` | `%Wardrik.Grants.None{}` |
  | `:workspace` | `Wardrik.Workspace` | `%Wardrik.Workspace.None{}` |

  A host names its store and the seams it offers once, as it starts
  `Wardrik`, and hands the same host to whatever surface it starts after it:

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
        {Wardrik, host: host},
        {MyApp.Endpoint, host: host}
      ]

  A seam it does not name is its None, which answers each function with
  `:unsupported`, or with what having none means in that function's own
  terms, as `[]` grants; so every field is always a value its protocol
  answers for, and an operation asks it without first asking whether there
  is one.

  The host travels with the work, never with what is stored: each
  `Wardrik.Caller` carries it to the operation it calls, and each agent is
  handed it as it starts, wakes or restarts on another node (see
  `Wardrik.Agent`). A node runs one `Wardrik`, so one host; see `Wardrik`.

  A caller is made here for someone known by a principal, holding the grant
  the host's `Wardrik.Grants` gives them, or for someone who holds the node:

      {:ok, caller} = Wardrik.Host.caller(host, principal: maria, subject: ~A"acme/triage")
      caller = Wardrik.Host.root(host, principal: Wardrik.Principal.new(:terminal, "jon"))

  The accessors answer each seam's value, so code that runs an operation's
  work names the field, never an implementation.
  """

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Caller
  alias Wardrik.Error
  alias Wardrik.Grant

  defstruct store: WardrikStore.new(adapter: WardrikStore.None),
            definitions: %Wardrik.Definition.None{},
            connections: %Wardrik.Connections.None{},
            credentials: %Wardrik.Credentials.None{},
            tokens: %Wardrik.Tokens.None{},
            triggers: %Wardrik.Triggers.None{},
            grants: %Wardrik.Grants.None{},
            workspace: %Wardrik.Workspace.None{},
            audit: Wardrik.Audit

  @type t() :: %__MODULE__{
          store: WardrikStore.t(),
          definitions: Wardrik.Definition.t(),
          connections: Wardrik.Connections.t(),
          credentials: Wardrik.Credentials.t(),
          tokens: Wardrik.Tokens.t(),
          triggers: Wardrik.Triggers.t(),
          grants: Wardrik.Grants.t(),
          workspace: Wardrik.Workspace.t(),
          audit: GenServer.name()
        }

  @seams [:definitions, :connections, :credentials, :tokens, :triggers, :grants, :workspace]

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
  The seams a configuration names, as `new/1` takes them: each a module and
  the fields of its struct, as an application's configuration holds them,
  where no struct can be written.

      config :wardrik, Wardrik.Host, definitions: {MyApp.Definitions, []}
  """
  @spec configured([{atom(), {module(), keyword()}}]) :: keyword()
  def configured(seams) when is_list(seams),
    do: for({seam, {module, fields}} <- seams, do: {seam, struct!(module, fields)})

  @doc """
  The person or system `:principal` names as a caller of an operation on
  `:subject`, an agent or the agents under a prefix: holding the first grant
  the host's `Wardrik.Grants` gives them whose scope reaches it. `:not_found`
  where none does, or where nobody is known, a `nil` principal, as for a
  turn nobody asked for: a subject outside a caller's reach is one that does
  not exist to them.

      {:ok, caller} = Wardrik.Host.caller(host, principal: maria, subject: ~A"acme/triage")
      Wardrik.Command.run(%Wardrik.Operations.Decide{agent: ~A"acme/triage", decisions: decisions}, caller)
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
  defp granted(host, principal), do: Wardrik.Grants.grants(grants(host), principal)

  @doc """
  A caller known as `:principal` who may do anything to every agent: one who
  holds the node itself, as a shell on it, or the terminal client. See
  `Wardrik.Caller.root/1`.
  """
  @spec root(t(), keyword()) :: Caller.t()
  def root(%__MODULE__{} = host, opts) do
    opts = Keyword.validate!(opts, [:principal])
    Caller.root(principal: Keyword.fetch!(opts, :principal), host: host)
  end

  @doc "The `WardrikStore` everything is kept in."
  @spec store(t()) :: WardrikStore.t()
  def store(%__MODULE__{store: store}), do: store

  @doc "The `Wardrik.Definition` agents' definitions go to."
  @spec definitions(t()) :: Wardrik.Definition.t()
  def definitions(%__MODULE__{definitions: definitions}), do: definitions

  @doc "The `Wardrik.Connections` the accounts people and orgs connect are asked of."
  @spec connections(t()) :: Wardrik.Connections.t()
  def connections(%__MODULE__{connections: connections}), do: connections

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
  The name of the `Wardrik.Audit` log `Wardrik` starts for this host, which
  surfaces record changes in; `Wardrik.Audit` unless `:audit` names
  another.
  """
  @spec audit(t()) :: GenServer.name()
  def audit(%__MODULE__{audit: audit}), do: audit

  @doc "The `Wardrik.Workspace` agents' files are kept in."
  @spec workspace(t()) :: Wardrik.Workspace.t()
  def workspace(%__MODULE__{workspace: workspace}), do: workspace

  @doc "The `Wardrik.Grants` that says what each principal may do."
  @spec grants(t()) :: Wardrik.Grants.t()
  def grants(%__MODULE__{grants: grants}), do: grants
end
