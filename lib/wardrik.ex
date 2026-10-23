defmodule Wardrik do
  @moduledoc """
  Agents, governed: the agents your app runs, the policies they're held to, and the operations
  people and programs reach them through.

      defmodule MyApp.Wardrik do
        use Wardrik, otp_app: :my_app
      end

      children = [MyApp.Wardrik]

      scope = MyApp.Wardrik.as("acme/@maria", roles: [:owner], resources: ["acme/@maria/*"])
      Wardrik.Agent.stream(scope, "acme/@maria/assistant", "What's on today?") |> Enum.each(&IO.write/1)

  `use Wardrik` reads its options from `config :my_app, MyApp.Wardrik`, then those it's started
  with, then `c:init/1`. See `start_link/1` for every option.
  """

  use Supervisor

  alias Wardrik.Error
  alias Wardrik.Instance
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
    :listeners,
    :triggers,
    :deployment,
    :authorizer,
    :retention,
    :backend,
    :policy,
    :capabilities,
    :policies,
    :middleware,
    :idle_timeout
  ]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          name: atom(),
          store: WardrikStore.t(),
          own_store: boolean(),
          keys: [String.t()],
          oauth: keyword() | nil,
          mcp: keyword() | nil,
          listeners: [module() | {module(), keyword()}],
          triggers: keyword(),
          deployment: String.t(),
          authorizer: {module(), term()},
          retention: pos_integer() | :infinity,
          backend: {module(), keyword()},
          policy: WardrikPolicy.t() | nil,
          capabilities: %{String.t() => WardrikCore.Context.entry()},
          policies: %{String.t() => WardrikPolicy.t()},
          middleware: [WardrikCore.Context.entry()],
          idle_timeout: pos_integer() | :infinity
        }

  @doc """
  Runs as a Wardrik made with `use Wardrik` starts, with its options, to give those only known as it
  runs, like a secret from the environment.

      @impl Wardrik
      def init(config), do: {:ok, Keyword.put(config, :keys, [System.fetch_env!("WARDRIK_KEY")])}
  """
  @callback init(config :: keyword()) :: {:ok, keyword()}

  defmacro __using__(opts) do
    otp_app = Keyword.get(opts, :otp_app)

    quote do
      @behaviour Wardrik

      @doc "Starts this Wardrik, with the options its config doesn't give. See `Wardrik.start_link/1`."
      @spec start_link(keyword()) :: Supervisor.on_start()
      def start_link(opts \\ []) do
        {:ok, config} = init(Keyword.merge(unquote(app_config(otp_app)), opts))
        Wardrik.start_link([name: __MODULE__] ++ Keyword.delete(config, :name))
      end

      @doc false
      def child_spec(opts),
        do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}

      @doc "Returns the scope `principal` acts in here. See `Wardrik.as/3`."
      @spec as(WardrikCore.Principal.t() | String.t(), term()) :: Wardrik.Scope.t()
      def as(principal, grants \\ []), do: Wardrik.as(__MODULE__, principal, grants)

      @doc "Returns the scope an API token's `secret` acts in here. See `Wardrik.authenticate/2`."
      @spec authenticate(String.t()) :: {:ok, Wardrik.Scope.t()} | {:error, Wardrik.Error.t()}
      def authenticate(secret), do: Wardrik.authenticate(__MODULE__, secret)

      @impl Wardrik
      def init(config), do: {:ok, config}

      defoverridable init: 1
    end
  end

  defp app_config(nil), do: []

  defp app_config(otp_app),
    do: quote(do: Application.get_env(unquote(otp_app), __MODULE__, []))

  @doc """
  Starts a Wardrik. Takes `:name`, and where it keeps agents and events: `:data_dir`, a directory
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
  @spec start_link(keyword() | t()) :: Supervisor.on_start()
  def start_link(%__MODULE__{name: name} = wardrik),
    do: Supervisor.start_link(__MODULE__, wardrik, name: name)

  def start_link(opts) when is_list(opts), do: opts |> Setup.wardrik() |> start_link()

  @doc false
  @spec new(keyword()) :: t()
  def new(opts), do: Setup.wardrik(opts)

  @doc """
  Returns the scope `principal` acts in on the Wardrik `instance`, allowed what `grants` say: a list
  of `Wardrik.Statement`s, or the options of one. Nothing is allowed unless it's granted.

      scope = Wardrik.as(MyApp.Wardrik, "acme/@maria", roles: [:reader], resources: ["acme/agent/*"])
  """
  @spec as(atom() | t(), Principal.t() | String.t(), term()) :: Scope.t()
  def as(instance, principal, grants \\ [])

  def as(instance, %Principal{} = principal, grants),
    do: %Scope{wardrik: Instance.name(instance), principal: principal, grants: statements(grants)}

  def as(instance, id, grants) when is_binary(id), do: as(instance, %Principal{id: id}, grants)

  @doc """
  Returns the scope an API token's `secret` acts in on the Wardrik `instance`, or an `unauthorized`
  error where it isn't one, or has expired.

      {:ok, scope} = Wardrik.authenticate(MyApp.Wardrik, secret)
  """
  @spec authenticate(atom() | t(), String.t()) :: {:ok, Scope.t()} | {:error, Error.t()}
  def authenticate(instance, secret),
    do: Wardrik.Operations.Tokens.authenticate(Instance.fetch!(instance), secret)

  @doc """
  Allows `scope` more, as `Wardrik.Statement.new/1` takes it.

      MyApp.Wardrik.as("acme/@maria") |> Wardrik.grant(roles: [:approver], resources: ["acme/agent/*"])
  """
  @spec grant(Scope.t(), keyword()) :: Scope.t()
  def grant(%Scope{grants: grants} = scope, opts) when is_list(grants),
    do: %{scope | grants: grants ++ [Wardrik.Statement.new(opts)]}

  defp statements([{key, _value} | _rest] = opts) when key in [:roles, :actions, :resources],
    do: [Wardrik.Statement.new(opts)]

  defp statements(grants), do: grants

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
  @spec start_agent(atom() | t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_agent(instance, opts) do
    wardrik = Instance.fetch!(instance)
    WardrikCore.start_agent(agents(wardrik), Setup.agent(wardrik, opts))
  end

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
  def init(%__MODULE__{} = wardrik) do
    registry =
      {Registry, keys: :unique, name: Instance.registry(wardrik.name), meta: [wardrik: wardrik]}

    Supervisor.init([registry | Wardrik.Children.children(wardrik)], strategy: :rest_for_one)
  end
end
