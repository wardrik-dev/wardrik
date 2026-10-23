defmodule Wardrik do
  @moduledoc """
  Agents, governed: the agents your app runs, the policies they're held to, and the operations
  people and programs reach them through.

      wardrik = Wardrik.new(name: MyApp.Wardrik, data_dir: "/var/lib/my_app")

      children = [{Wardrik, wardrik}]

      scope = Wardrik.as(wardrik, "acme/@maria", statements)
  """

  use Supervisor

  alias Wardrik.Catalog
  alias Wardrik.Error
  alias Wardrik.Runner
  alias Wardrik.Scope
  alias Wardrik.Setup
  alias WardrikCore.Principal

  @derive {Inspect, except: [:keys, :oauth, :mcp]}
  @enforce_keys [
    :name,
    :store,
    :own_store,
    :keys,
    :oauth,
    :mcp,
    :triggers,
    :deployment,
    :authorizer,
    :retention,
    :backend,
    :policy,
    :capabilities,
    :policies,
    :middleware,
    :idle_timeout,
    :catalog
  ]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          name: atom(),
          store: WardrikStore.t(),
          own_store: boolean(),
          keys: [String.t()],
          oauth: keyword() | nil,
          mcp: keyword() | nil,
          triggers: keyword(),
          deployment: String.t(),
          authorizer: {module(), term()},
          retention: pos_integer() | :infinity,
          backend: {module(), keyword()},
          policy: WardrikPolicy.t() | nil,
          capabilities: %{String.t() => WardrikCore.Context.entry()},
          policies: %{String.t() => WardrikPolicy.t()},
          middleware: [WardrikCore.Context.entry()],
          idle_timeout: pos_integer() | :infinity,
          catalog: Catalog.t()
        }

  @doc """
  Describes a Wardrik. Takes `:name`, and where it keeps agents and events: `:data_dir`, a directory
  on disk, or `:store`, a `WardrikStore` you run yourself. Given neither, it keeps them in memory,
  gone when it stops.

  It also takes `:deployment` (`"local"` unless set), `:authorizer`, a `Wardrik.Authorizer` as
  `{module, config}` (`Wardrik.Statements` unless set), `:retention`, the days events are kept (30
  unless set), `:backend`, where agents are kept (the store unless set), and `:policy`, the
  `WardrikPolicy` every agent is held to, or the rules to build it from.

  Given `:keys`, it keeps credentials sealed with them, and gives them to every agent's tools. Given
  `:oauth` too, as `WardrikOAuth` takes its `:page`, `:providers` and `:req_options`, people sign in
  to give agents their accounts, and the calls waiting on a sign-in carry on once it's done.

  Given `:mcp`, the MCP servers its agents may call, as `WardrikMCP` takes its `:servers`, it
  connects to each. `:triggers` takes `WardrikTriggers`' `:req_options`, for reading feeds, and
  `:reconcile`.

  What a definition names, it finds here: `:capabilities`, the tools it offers by name, as
  `[files: {MyApp.Files, []}]`, and `:policies`, as `[careful: [ask: ["github/*"]]]`. Each MCP
  server is a tool too, as `github/*`. `:middleware` wraps every agent's calls, and `:idle_timeout`
  is how many seconds a defined agent may have nothing to do before it sleeps, 900 unless set, or
  `:infinity`.
  """
  @spec new(keyword()) :: t()
  def new(opts), do: Setup.wardrik(opts)

  @doc "Starts what `wardrik` runs: its store, unless you run it, its agents, and their events."
  @spec start_link(t()) :: Supervisor.on_start()
  def start_link(%__MODULE__{name: name} = wardrik),
    do: Supervisor.start_link(__MODULE__, wardrik, name: name)

  @doc "Returns the scope `principal` acts in, allowed what `grants` say to the authorizer."
  @spec as(t(), Principal.t() | String.t(), term()) :: Scope.t()
  def as(wardrik, principal, grants \\ [])

  def as(%__MODULE__{} = wardrik, %Principal{} = principal, grants),
    do: %Scope{wardrik: wardrik, principal: principal, grants: grants}

  def as(%__MODULE__{} = wardrik, id, grants) when is_binary(id),
    do: as(wardrik, %Principal{id: id}, grants)

  @doc """
  Runs the operation `id`, like `agent.ask`, in `scope`, with `input` as the operation's input
  schema describes it.

      {:ok, %{"message" => %{"cursor" => cursor}}} =
        Wardrik.run(scope, "agent.ask", %{"agent" => "acme/triage", "content" => "What's on fire?"})
  """
  @spec run(Scope.t(), String.t(), map()) :: {:ok, term()} | {:error, Error.t()}
  def run(%Scope{} = scope, id, input), do: Runner.run(scope, id, input, :handlers)

  @doc """
  Streams what the operation `id` reads, as `{event, cursor}`, reading on and then following, for an
  operation that can be streamed, like `events.list`.
  """
  @spec stream(Scope.t(), String.t(), map()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def stream(%Scope{} = scope, id, input), do: Runner.run(scope, id, input, :streams)

  @doc """
  Starts the agent `opts` describe, as `WardrikCore.start_agent/2` takes them, writing its events
  to `wardrik`'s. `:policy` is the agent's own `WardrikPolicy`, or the rules to build it from. The
  agent is held to it and to `wardrik`'s, and the strictest decides.

      Wardrik.start_agent(wardrik,
        agent_id: "acme/books",
        model: "anthropic:claude-haiku-4-5",
        policy: [ask: ["books/pay_bill"]]
      )
  """
  @spec start_agent(t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_agent(%__MODULE__{} = wardrik, opts),
    do: WardrikCore.start_agent(agents(wardrik), Setup.agent(wardrik, opts))

  @doc "Returns the name of `wardrik`'s `WardrikCore` instance."
  @spec agents(t()) :: atom()
  def agents(%__MODULE__{name: name}), do: Module.concat(name, Agents)

  @doc "Returns the name of `wardrik`'s `WardrikEvents`."
  @spec events(t()) :: atom()
  def events(%__MODULE__{name: name}), do: Module.concat(name, Events)

  @doc "Returns the name of `wardrik`'s `WardrikVault`, which it runs when given `:keys`."
  @spec vault(t()) :: atom()
  def vault(%__MODULE__{name: name}), do: Module.concat(name, Vault)

  @doc "Returns the name of `wardrik`'s `WardrikOAuth`, which it runs when given `:oauth`."
  @spec oauth(t()) :: atom()
  def oauth(%__MODULE__{name: name}), do: Module.concat(name, OAuth)

  @doc """
  Returns the name of `wardrik`'s `WardrikMCP`, which it runs when given `:mcp`. Give an agent a
  server's tools by it:

      Wardrik.start_agent(wardrik,
        agent_id: "acme/triage",
        model: "anthropic:claude-haiku-4-5",
        capabilities: [{WardrikMCP, name: Wardrik.mcp(wardrik), servers: [:github]}]
      )
  """
  @spec mcp(t()) :: atom()
  def mcp(%__MODULE__{name: name}), do: Module.concat(name, MCP)

  @doc "Returns the name of `wardrik`'s `WardrikTriggers`."
  @spec triggers(t()) :: atom()
  def triggers(%__MODULE__{name: name}), do: Module.concat(name, Triggers)

  @impl Supervisor
  def init(wardrik),
    do: Supervisor.init(Wardrik.Children.children(wardrik), strategy: :rest_for_one)
end
