defmodule Wardrik do
  @moduledoc """
  Runs your app's agents, holds them to policies, and records what they do.

  Application integration fragment. Start the required processes before calling these functions.
  See the [package README](https://github.com/wardrik-dev/wardrik#readme) for complete setup.

      defmodule MyApp.AgentRuntime do
        use Wardrik, otp_app: :my_app
      end

      children = [MyApp.AgentRuntime]

      scope = MyApp.AgentRuntime.as("user_42")
      Wardrik.Agent.stream(scope, "agt_01JF8X5RQ2", "What's on today?") |> Enum.each(&IO.write/1)

  ## Configuration

  Each place overrides the one before it:

      # 1. config/runtime.exs
      config :my_app, MyApp.AgentRuntime, store: {Wardrik.Store.EKV, data_dir: "/var/lib/my_app"}

      # 2. The supervision tree
      children = [{MyApp.AgentRuntime, deployment: "production"}]

      # 3. init/1, for what's only known at runtime
      @impl Wardrik
      def init(config), do: {:ok, Keyword.put(config, :vault_keys, [System.fetch_env!("WARDRIK_KEY")])}

  See `start_link/1` for every option.
  """

  @behaviour Wardrik.Server

  use Supervisor

  alias Wardrik.Error
  alias Wardrik.Instance
  alias Wardrik.Runner
  alias Wardrik.Scope
  alias Wardrik.Setup
  alias WardrikCore.Principal

  @typedoc "A person, or whom an agent works for. Build one with `principal/2`."
  @type principal() :: WardrikCore.Principal.t()

  @entry {:or, [:atom, {:tuple, [:atom, :any]}]}
  @named {:or,
          [
            {:list, {:tuple, [{:or, [:atom, :string]}, :any]}},
            {:map, {:or, [:atom, :string]}, :any}
          ]}
  @timeout {:or, [:pos_integer, {:in, [:infinity]}]}

  @schema NimbleOptions.new!(
            name: [type: :atom, required: true, doc: "What Wardrik is reached by."],
            store: [
              type: {:or, [{:struct, Wardrik.Store}, {:tuple, [:atom, :keyword_list]}]},
              doc: "Where agents and events are kept, as `{adapter, opts}`. In memory unless set."
            ],
            deployment: [
              type: :string,
              default: "local",
              doc: "The deployment's name in each event's `source`."
            ],
            policy: [
              type: {:or, [{:struct, Wardrik.Policy}, :keyword_list, {:map, :any, :any}]},
              doc: "The policy every agent is held to, as `[deny: [\"shell/*\"]]`."
            ],
            vault_keys: [
              type: {:list, :string},
              default: [],
              doc: "Keys to seal secrets with. No secrets are kept without them."
            ],
            credentials: [
              type: @entry,
              doc:
                "Where tools get credentials, a `WardrikCore.Credentials`. The vault unless set."
            ],
            key_source: [
              type: @entry,
              doc: "Where code gets API keys, a `WardrikCore.Keys`. The environment unless set."
            ],
            grants: [
              type: {:tuple, [:atom, :any]},
              doc:
                "Where OAuth grants come from, a `Wardrik.Vault.Grants`. `Wardrik.OAuth` unless set."
            ],
            oauth: [
              type: :keyword_list,
              doc: "Services people sign in to. Needs `:vault_keys`.",
              keys: [
                page: [
                  type: :string,
                  required: true,
                  doc: "Where sign-ins return, as `\"https://agents.example.com/oauth\"`."
                ],
                resolver: [
                  type: :mod_arg,
                  doc: """
                  The `Wardrik.OAuth.Resolver` that gives each person's providers.
                  `Wardrik.OAuth.Apps` unless set.
                  """
                ],
                providers: [
                  type: {:list, {:tuple, [{:or, [:atom, :string]}, :keyword_list]}},
                  default: [],
                  doc: """
                  The deployment's OAuth apps, by name, each as `Wardrik.OAuth.Provider` takes
                  it, less `:key`, with its `:client_secret`. Held by `"deployment"`. See
                  `Wardrik.OAuth.Apps`.
                  """
                ],
                client_name: [
                  type: :string,
                  doc: "The name a service shows for clients Wardrik registers."
                ],
                req_options: [
                  type: :keyword_list,
                  default: [],
                  doc: "Extra options for every `Req` request."
                ]
              ]
            ],
            mcp: [
              type: {:list, {:tuple, [{:or, [:atom, :string]}, :keyword_list]}},
              default: [],
              doc: "MCP servers to start, as `[github: [transport: ...]]`. See `Wardrik.MCP`."
            ],
            capabilities: [
              type: @named,
              default: [],
              doc: "Tools definitions name, as `[files: {MyApp.Files, []}]`."
            ],
            policies: [
              type: @named,
              default: [],
              doc: "Policies definitions name, as `[careful: [ask: [\"github/*\"]]]`."
            ],
            defaults: [
              type: {:map, {:or, [:atom, :string]}, :any},
              default: %{},
              doc:
                "Defaults for every definition, as `%{\"model\" => \"anthropic:claude-haiku-4-5\"}`."
            ],
            middleware: [type: {:list, @entry}, default: [], doc: "Wraps every agent's calls."],
            idle_timeout: [
              type: {:or, [:pos_integer, :float, {:in, [:infinity]}]},
              default: 900,
              doc: "Seconds a defined agent idles before it sleeps, or `:infinity`."
            ],
            channels: [
              type: @named,
              default: [],
              doc: "Chat apps, as `[slack: {WardrikSlack, opts}]`. See `Wardrik.Channel`."
            ],
            notify: [
              type: :keyword_list,
              default: [],
              doc: "Where notices go. See `Wardrik.Notify`."
            ],
            declarations: [
              type: :mod_arg,
              doc: "Agents defined outside the API. See `Wardrik.Declarations`."
            ],
            resolver: [
              type: :mod_arg,
              required: true,
              doc: "The `Wardrik.Resolver` that says what each agent gets, as `{module, config}`."
            ],
            triggers: [
              type: :keyword_list,
              default: [],
              doc: "Options for `Wardrik.Triggers`.",
              keys: [
                req_options: [type: :keyword_list, doc: "`Req` options for reading feeds."],
                reconcile: [
                  type: @timeout,
                  doc: "Milliseconds between rereading every trigger, or `:infinity`."
                ]
              ]
            ],
            listeners: [
              type: {:list, @entry},
              default: [],
              doc: "Listeners to start. See `Wardrik.Listener`."
            ],
            sinks: [
              type: {:list, @entry},
              default: [],
              doc: "Where to send every kept event. See `Wardrik.Sink`."
            ],
            authorizer: [
              type: :mod_arg,
              required: true,
              doc: "The `Wardrik.Authorizer` that says who may do what, as `{module, config}`."
            ],
            retention: [type: @timeout, default: 30, doc: "Days events are kept, or `:infinity`."],
            backend: [
              type: {:tuple, [:atom, :keyword_list]},
              doc: "Where agents are kept. The store unless set."
            ],
            agents: [
              type: :keyword_list,
              default: [],
              doc: """
              Where agents run in a cluster, and how idle ones keep memory. Each new agent, and
              each one a lost node ran, starts on the node with the most room under these limits.
              With none set, it starts on the node that asked.
              """,
              keys: [
                max_per_node: [
                  type: :pos_integer,
                  doc: """
                  Most agents and conversations a node runs. A node at it takes no more, so leave
                  room for a lost node's agents on the rest.
                  """
                ],
                max_memory: [
                  type: {:in, 1..100},
                  doc: "Percent of the machine's memory above which a node takes no new agents."
                ],
                max_cpu: [
                  type: :pos_integer,
                  doc: """
                  CPU percent above which a node takes no new agents. Above 100 counts a run queue
                  longer than the cores.
                  """
                ],
                hibernate_after: [
                  type: :pos_integer,
                  doc: "Seconds idle before an agent's process compacts its memory."
                ]
              ]
            ],
            discovery_interval_ms: [
              type: :pos_integer,
              doc: "Milliseconds between looks for agents no node runs. `30_000` unless set."
            ],
            trusted_workers: [
              type: :boolean,
              default: false,
              doc: "`true` to trust tool workers' answers, not label them `\"outside\"`."
            ],
            egress: [
              type: {:fun, 1},
              default: &Wardrik.Egress.public/1,
              doc: "Which URLs may be reached. See `Wardrik.Egress`."
            ],
            prices: [
              type: {:map, {:or, [:atom, :string]}, :keyword_list},
              default: %{},
              doc: "Model prices the catalog lacks. See `Wardrik.Setup.price/2`."
            ],
            model_options: [
              type: :keyword_list,
              default: [],
              doc: """
              Options for every agent's model calls, as `ReqLLM` takes them, such as
              `[temperature: 0.2]`. An agent's own `model_options` merge over them.
              """
            ]
          )

  @derive {Inspect, except: [:vault_keys, :oauth, :mcp]}
  @enforce_keys [
    :name,
    :store,
    :vault_keys,
    :credentials,
    :key_source,
    :grants,
    :oauth,
    :mcp,
    :listeners,
    :sinks,
    :channels,
    :notify,
    :declarations,
    :resolver,
    :defaults,
    :triggers,
    :deployment,
    :authorizer,
    :retention,
    :backend,
    :agents,
    :policy,
    :capabilities,
    :policies,
    :middleware,
    :idle_timeout,
    :trusted_workers,
    :egress,
    :prices,
    :model_options
  ]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          name: atom(),
          store: Wardrik.Store.t(),
          vault_keys: [String.t()],
          credentials: WardrikCore.Context.entry() | nil,
          key_source: WardrikCore.Context.entry() | nil,
          grants: {module(), term()} | nil,
          oauth: keyword() | nil,
          mcp: [{atom() | String.t(), keyword()}],
          listeners: [module() | {module(), keyword()}],
          sinks: [module() | {module(), keyword()}],
          channels: %{String.t() => {module(), keyword()}},
          notify: %{targets: %{String.t() => {module(), keyword()}}, retries: keyword()},
          declarations: {module(), term()} | nil,
          resolver: {module(), term()},
          defaults: map(),
          triggers: keyword(),
          deployment: String.t(),
          authorizer: {module(), term()},
          retention: pos_integer() | :infinity,
          backend: {module(), keyword()},
          policy: Wardrik.Policy.t() | nil,
          capabilities: %{String.t() => WardrikCore.Context.entry()},
          policies: %{String.t() => Wardrik.Policy.t()},
          middleware: [WardrikCore.Context.entry()],
          idle_timeout: number() | :infinity,
          trusted_workers: boolean(),
          egress: (String.t() -> :ok | {:error, String.t()}),
          prices: %{String.t() => WardrikCore.price()},
          model_options: keyword(),
          agents: keyword()
        }

  @doc """
  Sets options known only at runtime.

      @impl Wardrik
      def init(config), do: {:ok, Keyword.put(config, :vault_keys, [System.fetch_env!("WARDRIK_KEY")])}
  """
  @callback init(config :: keyword()) :: {:ok, keyword()}

  defmacro __using__(opts) do
    otp_app = Keyword.get(opts, :otp_app)
    Wardrik.Instance.using(otp_app)
  end

  @doc """
  Starts Wardrik. Raises `NimbleOptions.ValidationError` on a bad option.

      Wardrik.start_link(
        name: MyApp.AgentRuntime,
        authorizer: {MyApp.Authorizer, []},
        resolver: {MyApp.Agents, []},
        store: {Wardrik.Store.EKV, data_dir: "/var/lib/my_app"},
        vault_keys: [System.fetch_env!("WARDRIK_KEY")],
        policy: [deny: ["shell/*"]],
        prices: %{"zai_coding_plan:glm-5.1" => [priced_as: "zai:glm-5.1", markup: 0.1]}
      )

  Stores:

      store: {Wardrik.Store.EKV, data_dir: "/var/lib/my_app"}
      store: {Wardrik.Store.Ecto, repo: MyApp.Repo}
      store: {Wardrik.Store.Ecto, url: "postgres://user:pass@db.example.com/my_app"}

  ## Options

  #{NimbleOptions.docs(@schema)}
  """
  @spec start_link(keyword() | t()) :: Supervisor.on_start()
  def start_link(%__MODULE__{name: name} = wardrik),
    do: Supervisor.start_link(__MODULE__, wardrik, name: name)

  def start_link(opts) when is_list(opts) do
    opts
    |> new()
    |> start_link()
  end

  @doc false
  @spec new(keyword()) :: t()
  def new(opts) do
    opts
    |> NimbleOptions.validate!(@schema)
    |> Setup.wardrik()
  end

  @doc "Returns `start_link/1`'s options as a `NimbleOptions` schema."
  @spec schema() :: NimbleOptions.t()
  def schema, do: @schema

  @doc """
  Returns a principal, with attributes your authorizer may read.

      Wardrik.principal("user_42", %{name: "Maria"})
  """
  @spec principal(String.t(), map()) :: principal()
  def principal(id, attributes \\ %{}), do: %Principal{id: id, attributes: attributes}

  @doc """
  Returns the name of the API key `model` needs, or `nil`.

      Wardrik.key_name("zai_coding_plan:glm-5.1")
      #=> "ZAI_API_KEY"
  """
  @spec key_name(String.t()) :: String.t() | nil
  def key_name(model), do: WardrikCore.Keys.key_name(model)

  @doc """
  Returns a cursor from the last sequence read in each `{agent, conversation}` log.

      Wardrik.cursor(%{{"agt_01JF8X5RQ2", nil} => 41, {"agt_01JF8X5RQ2", "C1"} => 3})
  """
  @spec cursor(%{Wardrik.EventLog.log() => non_neg_integer()}) :: String.t()
  def cursor(positions), do: Wardrik.EventLog.Cursor.encode(positions)

  @doc "Returns the positions in `cursor`, or `:error`. The reverse of `cursor/1`."
  @spec positions(String.t()) :: {:ok, %{Wardrik.EventLog.log() => non_neg_integer()}} | :error
  def positions(cursor) do
    case Wardrik.EventLog.Cursor.decode(cursor) do
      {:ok, positions} -> {:ok, positions}
      {:error, _reason} -> :error
    end
  end

  @doc """
  Checks a definition's `policy`. Returns `:ok` or why it's invalid.

      Wardrik.check_policy(%{"judge" => %{"questions" => [%{"question" => "Publish?"}]}})
      #=> {:error, "a question decides nothing; give it deny, ask or allow"}
  """
  @spec check_policy(map()) :: :ok | {:error, String.t()}
  def check_policy(policy) do
    case Wardrik.Policy.decode(policy) do
      {:ok, _policy} -> :ok
      {:error, message} -> {:error, message}
    end
  end

  @doc """
  Returns the scope `principal` acts in. Every operation takes one.

      scope = Wardrik.as(MyApp.AgentRuntime, "user_42")

  ## Options

    * `:actor` - who acts for `principal`, as `{:agent, id}` or `{:channel, name}`.
    * `:context` - what your authorizer may read. `%{}` unless set.
  """
  @spec as(atom() | t(), Principal.t() | String.t(), keyword()) :: Scope.t()
  def as(instance, principal, opts \\ []) do
    opts = Keyword.validate!(opts, actor: nil, context: %{})

    Scope.new(__MODULE__,
      wardrik: Instance.name(instance),
      principal: principal,
      actor: opts[:actor],
      context: opts[:context]
    )
  end

  @doc """
  Runs an operation by ID, with the protocol's JSON input.

      Wardrik.run(scope, "agent.ask", %{"agent" => "agt_01JF8X5RQ2", "content" => "What's on fire?"})
      #=> {:ok, %{"message" => %{"id" => "msg_Xq3f...", "cursor" => "W1siYWd0XzAxSkY4WDVSUTIiLG51bGwsNDFdXQ"}}}
  """
  @spec run(Scope.t(), String.t(), map()) :: {:ok, term()} | {:error, Error.t()}
  def run(%Scope{} = scope, id, input), do: Runner.run(scope, id, input)

  @impl Wardrik.Server
  def run(%Wardrik.Server.Request{scope: scope, operation: id, input: input}),
    do: run(scope, id, input)

  @doc """
  Streams an operation by ID. The stream yields `{event, cursor}` and follows new events.

      {:ok, stream} = Wardrik.stream(scope, "events.list", %{"agents" => ["agt_01JF8X5RQ2"]})
  """
  @spec stream(Scope.t(), String.t(), map()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def stream(%Scope{} = scope, id, input), do: Runner.stream(scope, id, input)

  @impl Wardrik.Server
  def stream(%Wardrik.Server.Request{scope: scope, operation: id, input: input}),
    do: stream(scope, id, input)

  @impl Wardrik.Server
  def follow(%Wardrik.Server.Follow{} = follow, opts) do
    opts =
      if follow.conversation,
        do: Keyword.put(opts, :conversation, follow.conversation),
        else: opts

    Wardrik.Answers.follow(follow.scope, follow.agent, follow.input, opts)
  end

  @impl Wardrik.Server
  def offer(scope, tools), do: Wardrik.Workers.offer(scope, tools)

  @impl Wardrik.Server
  def answer(call, message), do: Wardrik.Workers.answer(call, message)

  @doc """
  Starts an agent from code, with `WardrikCore.start_agent/2`'s options and its own `:policy`.

  It's also held to what it resolves to, and Wardrik's `:policy`.

      Wardrik.start_agent(MyApp.AgentRuntime,
        agent_id: "agt_books",
        model: "anthropic:claude-haiku-4-5",
        policy: [ask: ["books/pay_bill"]]
      )
  """
  @spec start_agent(atom() | t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_agent(instance, opts) do
    wardrik = Instance.fetch!(instance)

    with {:ok, resolved} <-
           Wardrik.Resolver.resolve(wardrik, %Wardrik.Resolver.Request{
             agent: Keyword.fetch!(opts, :agent_id)
           }) do
      held = Wardrik.Resolution.hold(opts, resolved)
      agents = agents(wardrik)
      WardrikCore.start_agent(agents, Setup.agent(wardrik, held))
    end
  end

  @doc """
  Resolves awake agents again. Returns a line for each it couldn't update.

      Wardrik.refresh(MyApp.AgentRuntime)
      Wardrik.refresh(MyApp.AgentRuntime, agents: ["agt_scout"])
      #=> []
  """
  @spec refresh(atom() | t(), keyword()) :: [String.t()]
  def refresh(instance, opts \\ []) do
    opts = Keyword.validate!(opts, [:agents])
    wardrik = Instance.fetch!(instance)
    Wardrik.Resolution.refresh(wardrik, refreshing(opts))
  end

  defp refreshing(agents: ids), do: ids
  defp refreshing([]), do: :all

  @doc """
  Starts `principal`'s sign-in to `provider`, or returns the one under way.

      Wardrik.sign_in(MyApp.AgentRuntime, "github", Wardrik.principal("user_42"))
      #=> {:ok, %{url: "https://github.com/login/oauth/authorize?..."}}

  Send the person to `url`. A device sign-in also gives the `code` to enter there. Needs `:oauth`.
  """
  @spec sign_in(atom() | t(), String.t(), Principal.t()) ::
          {:ok, %{required(:url) => String.t(), optional(:code) => String.t()}} | {:error, term()}
  def sign_in(instance, provider, %Principal{} = principal) do
    instance
    |> Instance.fetch!()
    |> oauth()
    |> Wardrik.OAuth.authorize(provider, principal)
  end

  @doc """
  Returns the browser sign-in whose URL carries `state` while it's under way: its `provider` and
  the `principal` it's for, whether they or an agent waiting on them started it. `:error` once
  it has ended, or without `:oauth`.

      Wardrik.started_sign_in(MyApp.AgentRuntime, "1lnrCkd...")
      #=> {:ok, %{provider: "github", principal: %WardrikCore.Principal{id: "user_42"}}}
  """
  @spec started_sign_in(atom() | t(), String.t()) ::
          {:ok, %{provider: String.t(), principal: Principal.t()}} | :error
  def started_sign_in(instance, state) do
    case Instance.fetch!(instance) do
      %__MODULE__{oauth: nil} ->
        :error

      wardrik ->
        wardrik
        |> oauth()
        |> Wardrik.OAuth.started(state)
        |> started()
    end
  end

  defp started({:ok, flow}), do: {:ok, Map.take(flow, [:provider, :principal])}
  defp started(:error), do: :error

  @doc """
  Returns whether `principal`'s sign-in to `provider` is under way.

      Wardrik.signing_in?(MyApp.AgentRuntime, "github", Wardrik.principal("user_42"))
      #=> true

  `false` once it's finished, declined or expired, and always without `:oauth`.
  """
  @spec signing_in?(atom() | t(), String.t(), Principal.t()) :: boolean()
  def signing_in?(instance, provider, %Principal{} = principal) do
    case Instance.fetch!(instance) do
      %__MODULE__{oauth: nil} ->
        false

      wardrik ->
        wardrik
        |> oauth()
        |> Wardrik.OAuth.signing_in?(provider, principal)
    end
  end

  @doc """
  Forgets the client Wardrik registered for the OAuth app `key`. Call it when you delete that app.

      :ok = Wardrik.forget_client(MyApp.AgentRuntime, "linear/app_1")
  """
  @spec forget_client(atom() | t(), String.t()) :: :ok | {:error, term()}
  def forget_client(instance, key) do
    instance
    |> Instance.fetch!()
    |> oauth()
    |> Wardrik.OAuth.forget_client(key)
  end

  @doc """
  Returns the sign-in pages' plug, to mount at `:oauth`'s `page`. `nil` without `:oauth`.

  `principal` is called with the conn, and returns who is at the browser, or `nil`.

      Wardrik.sign_in_pages(MyApp.AgentRuntime, {MyApp.Session, :principal, []})
  """
  @spec sign_in_pages(atom() | t(), mfa()) :: {module(), term()} | nil
  def sign_in_pages(instance, principal) do
    instance
    |> Instance.fetch!()
    |> pages(principal)
  end

  @doc """
  Finishes a browser sign-in from its callback `params`.

      Wardrik.finish_sign_in(MyApp.AgentRuntime, params, as: current_principal)
      #=> {:ok, %{provider: "github", principal: %WardrikCore.Principal{id: "user_7"}}}

  For an app that serves the callback page itself. Only whoever started it can finish it.
  """
  @spec finish_sign_in(atom() | t(), map(), keyword()) ::
          {:ok, %{provider: String.t(), principal: Principal.t()}} | {:error, term()}
  def finish_sign_in(instance, params, opts) do
    instance
    |> Instance.fetch!()
    |> oauth()
    |> Wardrik.OAuth.finish(params, opts)
  end

  @doc "Returns Wardrik's OAuth Client ID Metadata Document. The sign-in pages serve it at `/client`."
  @spec client_document(atom() | t()) :: map()
  def client_document(instance) do
    instance
    |> Instance.fetch!()
    |> oauth()
    |> Wardrik.OAuth.client_document()
  end

  defp pages(%__MODULE__{oauth: nil}, _principal), do: nil

  defp pages(wardrik, principal),
    do: {Wardrik.OAuth.Plug, Wardrik.OAuth.Plug.init(oauth: oauth(wardrik), principal: principal)}

  @doc false
  @spec agents(t()) :: atom()
  def agents(%__MODULE__{name: name}), do: Module.concat(name, Agents)

  @doc false
  @spec events(t()) :: atom()
  def events(%__MODULE__{name: name}), do: Module.concat(name, Events)

  @doc false
  @spec vault(t()) :: atom()
  def vault(%__MODULE__{name: name}), do: Module.concat(name, Vault)

  @doc false
  @spec oauth(t()) :: atom()
  def oauth(%__MODULE__{name: name}), do: Module.concat(name, OAuth)

  @doc """
  Returns the name of the instance's `Wardrik.MCP`.

      Wardrik.MCP.add(Wardrik.mcp(MyApp.AgentRuntime), "acme:linear", opts)
  """
  @spec mcp(atom() | t()) :: atom()
  def mcp(%__MODULE__{name: name}), do: mcp(name)
  def mcp(name) when is_atom(name), do: Module.concat(name, MCP)

  @doc false
  @spec triggers(t()) :: atom()
  def triggers(%__MODULE__{name: name}), do: Module.concat(name, Triggers)

  @impl Supervisor
  def init(%__MODULE__{} = wardrik) do
    registry =
      {Registry, keys: :unique, name: Instance.registry(wardrik.name), meta: [wardrik: wardrik]}

    Supervisor.init([registry | Wardrik.Children.children(wardrik)], strategy: :rest_for_one)
  end
end
