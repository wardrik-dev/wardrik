defmodule Wardrik do
  @moduledoc """
  Agents, governed: the agents your app runs, the policies they're held to, and the operations
  people and programs reach them through.

      defmodule MyApp.AgentRuntime do
        use Wardrik, otp_app: :my_app
      end

      children = [MyApp.AgentRuntime]

      scope = MyApp.AgentRuntime.as("acme/@maria", roles: [:owner], resources: ["acme/@maria/*"])
      Wardrik.Agent.stream(scope, "acme/@maria/assistant", "What's on today?") |> Enum.each(&IO.write/1)

  ## Options

  Each place overrides the one before it:

      # 1. config/runtime.exs
      config :my_app, MyApp.AgentRuntime, store: {WardrikStore.EKV, data_dir: "/var/lib/my_app"}

      # 2. The supervision tree
      children = [{MyApp.AgentRuntime, deployment: "production"}]

      # 3. init/1, for what's only known at runtime
      @impl Wardrik
      def init(config), do: {:ok, Keyword.put(config, :keys, [System.fetch_env!("WARDRIK_KEY")])}

  See `start_link/1` for every option.
  """

  @behaviour Wardrik.Server

  @typedoc "Who acts through Wardrik, or whom an agent works for. Build one with `principal/2`."
  @type principal() :: WardrikCore.Principal.t()

  use Supervisor

  alias Wardrik.Error
  alias Wardrik.Instance
  alias Wardrik.Runner
  alias Wardrik.Scope
  alias Wardrik.Setup
  alias WardrikCore.Principal

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
              type: {:or, [{:struct, WardrikStore}, {:tuple, [:atom, :keyword_list]}]},
              doc: "Where agents and their events are kept, as `{adapter, opts}`. See above."
            ],
            deployment: [
              type: :string,
              default: "local",
              doc: "The deployment's name in each event's `source`."
            ],
            policy: [
              type: {:or, [{:struct, WardrikPolicy}, :keyword_list, {:map, :any, :any}]},
              doc:
                "The `WardrikPolicy` every agent is held to, or its rules, as `[deny: [\"shell/*\"]]`."
            ],
            keys: [
              type: {:list, :string},
              default: [],
              doc: "Keys to seal secrets with. Without them, no secrets are kept."
            ],
            credentials: [
              type: @entry,
              doc:
                "The `WardrikCore.Credentials` tools fetch a person's credentials from, as " <>
                  "`{module, opts}`. The vault unless set."
            ],
            key_source: [
              type: @entry,
              doc:
                "The `WardrikCore.Keys` code fetches API keys from, as `{module, opts}`. " <>
                  "`Wardrik.Keys` unless set."
            ],
            deployment_keys: [
              type: :boolean,
              default: false,
              doc:
                "`true` to let every agent use the deployment's API keys where its owner holds " <>
                  "none. A host that doesn't set it gets no fallback. Read by `Wardrik.Keys`."
            ],
            grants: [
              type: {:tuple, [:atom, :any]},
              doc:
                "The `WardrikVault.Grants` that renews and asks for accounts people connect, as " <>
                  "`{module, opts}`. `WardrikOAuth` with `:oauth`, unless set."
            ],
            oauth: [
              type: :keyword_list,
              doc: "Services people sign in to. Needs `:keys`.",
              keys: [
                page: [
                  type: :string,
                  required: true,
                  doc: "Where sign-ins come back to, as `\"https://agents.example.com/oauth\"`."
                ],
                providers: [
                  type: {:list, {:tuple, [{:or, [:atom, :string]}, :keyword_list]}},
                  default: [],
                  doc: "Providers to start with, by name. See `WardrikOAuth.Provider`."
                ],
                client_name: [
                  type: :string,
                  doc: "The name a service shows for a client Wardrik registers."
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
              doc:
                "MCP servers agents may call, as `[github: [transport: ..., orgs: [\"acme\"]]]`. " <>
                  "See `WardrikMCP`."
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
                "What every definition gets where it says nothing, as " <>
                  "`%{\"model\" => \"anthropic:claude-haiku-4-5\"}`."
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
            orgs: [type: :mod_arg, doc: "Per-org settings. See `Wardrik.Orgs`."],
            workspace: [
              type: :keyword_list,
              doc: "File trees shared beyond their owners. See `Wardrik.Workspaces`."
            ],
            triggers: [
              type: :keyword_list,
              default: [],
              doc: "Options for `WardrikTriggers`.",
              keys: [
                req_options: [type: :keyword_list, doc: "`Req` options for reading feeds."],
                reconcile: [
                  type: @timeout,
                  doc:
                    "Milliseconds between each node reading every trigger again, or `:infinity`."
                ]
              ]
            ],
            listeners: [
              type: {:list, @entry},
              default: [],
              doc: "Listeners to start. See `Wardrik.Listener`."
            ],
            authorizer: [
              type: :mod_arg,
              default: {Wardrik.Statements, []},
              doc: "Decides what each scope may do, as `{module, config}`."
            ],
            retention: [type: @timeout, default: 30, doc: "Days events are kept, or `:infinity`."],
            backend: [
              type: {:tuple, [:atom, :keyword_list]},
              doc: "Where agents are kept. The store unless set."
            ],
            discovery_interval_ms: [
              type: :pos_integer,
              doc: "How often a node looks for agents no node runs. `30_000` unless set."
            ],
            trusted_workers: [
              type: :boolean,
              default: false,
              doc: "`true` to treat tool workers' answers as the deployment's own."
            ],
            egress: [
              type: {:fun, 1},
              default: &Wardrik.Egress.public/1,
              doc: "Which URLs users may point it at."
            ],
            prices: [
              type: {:map, {:or, [:atom, :string]}, :keyword_list},
              default: %{},
              doc: "Model prices the catalog lacks, per million tokens. See below."
            ]
          )

  @derive {Inspect, except: [:keys, :oauth, :mcp]}
  @enforce_keys [
    :name,
    :store,
    :keys,
    :credentials,
    :key_source,
    :grants,
    :oauth,
    :mcp,
    :listeners,
    :channels,
    :notify,
    :declarations,
    :orgs,
    :workspace,
    :defaults,
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
    :trusted_workers,
    :egress,
    :prices
  ]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          name: atom(),
          store: WardrikStore.t(),
          keys: [String.t()],
          credentials: WardrikCore.Context.entry() | nil,
          key_source: WardrikCore.Context.entry() | nil,
          grants: {module(), term()} | nil,
          oauth: keyword() | nil,
          mcp: [{atom() | String.t(), keyword()}],
          listeners: [module() | {module(), keyword()}],
          channels: %{String.t() => {module(), keyword()}},
          notify: %{
            targets: %{String.t() => {module(), keyword()}},
            retries: keyword(),
            req_options: keyword()
          },
          declarations: {module(), term()} | nil,
          orgs: {module(), term()} | nil,
          workspace: %{String.t() => %{read: [String.t()], write: [String.t()]}},
          defaults: map(),
          triggers: keyword(),
          deployment: String.t(),
          authorizer: {module(), term()},
          retention: pos_integer() | :infinity,
          backend: {module(), keyword()},
          policy: WardrikPolicy.t() | nil,
          capabilities: %{String.t() => WardrikCore.Context.entry()},
          policies: %{String.t() => WardrikPolicy.t()},
          middleware: [WardrikCore.Context.entry()],
          idle_timeout: number() | :infinity,
          trusted_workers: boolean(),
          egress: (String.t() -> :ok | {:error, String.t()}),
          prices: %{String.t() => WardrikCore.Usage.price()}
        }

  @doc """
  Fills in options only known at runtime, before the module starts.

      @impl Wardrik
      def init(config), do: {:ok, Keyword.put(config, :keys, [System.fetch_env!("WARDRIK_KEY")])}
  """
  @callback init(config :: keyword()) :: {:ok, keyword()}

  defmacro __using__(opts), do: Wardrik.Instance.using(Keyword.get(opts, :otp_app))

  @doc """
  Starts Wardrik.

      Wardrik.start_link(
        name: MyApp.AgentRuntime,
        store: {WardrikStore.EKV, data_dir: "/var/lib/my_app"},
        keys: [System.fetch_env!("WARDRIK_KEY")],
        policy: [deny: ["shell/*"]]
      )

  ## Store

  Where agents and their events are kept. In memory unless set, and gone when it stops.

      # On disk
      store: {WardrikStore.EKV, data_dir: "/var/lib/my_app"}

      # In your app's Postgres; create the table with WardrikStore.Ecto.Migration
      store: {WardrikStore.Ecto, repo: MyApp.Repo}

      # In a Postgres of its own, which migrates itself
      store: {WardrikStore.Ecto, url: "postgres://user:pass@db.example.com/my_app"}

      # A store you've built; one already running is left as it is
      store: WardrikStore.EKV.new(name: MyApp.Store, data_dir: "/var/lib/my_app")

  `WardrikStore.Ecto` needs `:ecto_sql` and `:postgrex` in your deps.

  ## Options

  #{NimbleOptions.docs(@schema)}

  ### Prices

      prices: %{"zai_coding_plan:glm-5.1" => [priced_as: "zai:glm-5.1", markup: 0.1]}

  See `Wardrik.Setup.price/2`.
  """
  @spec start_link(keyword() | t()) :: Supervisor.on_start()
  def start_link(%__MODULE__{name: name} = wardrik),
    do: Supervisor.start_link(__MODULE__, wardrik, name: name)

  def start_link(opts) when is_list(opts), do: opts |> new() |> start_link()

  @doc false
  @spec new(keyword()) :: t()
  def new(opts), do: opts |> NimbleOptions.validate!(@schema) |> Setup.wardrik()

  @doc "Returns the options `start_link/1` takes, as a `NimbleOptions` schema, for a host that reads them from a file."
  @spec schema() :: NimbleOptions.t()
  def schema, do: @schema

  @doc """
  Returns the principal with `id`, such as `"acme/@maria"`, and optional `attributes`.

      Wardrik.principal("acme/@maria", %{name: "Maria"})
  """
  @spec principal(String.t(), map()) :: principal()
  def principal(id, attributes \\ %{}), do: %Principal{id: id, attributes: attributes}

  @doc """
  Returns the name of the API key `model`'s provider needs, or `nil`.

  Calls to `model` use the owner's secret of that name, or the deployment's with
  `deployment_keys: true`. See `Wardrik.Keys`.

      Wardrik.key_name("zai_coding_plan:glm-5.1")
      #=> "ZAI_API_KEY"
  """
  @spec key_name(String.t()) :: String.t() | nil
  def key_name(model), do: WardrikCore.Keys.key_name(model)

  @doc """
  Returns a cursor for `events.list` to read on from.

  `positions` maps each agent or conversation ID to the last sequence read from its log.

      Wardrik.cursor(%{"acme/triage" => 41})
  """
  @spec cursor(%{String.t() => non_neg_integer()}) :: String.t()
  def cursor(positions), do: WardrikEvents.Cursor.encode(positions)

  @doc "Returns the positions in `cursor`, or `:error` if it isn't one. The reverse of `cursor/1`."
  @spec positions(String.t()) :: {:ok, %{String.t() => non_neg_integer()}} | :error
  def positions(cursor) do
    case WardrikEvents.Cursor.decode(cursor) do
      {:ok, positions} -> {:ok, positions}
      {:error, _reason} -> :error
    end
  end

  @doc """
  Checks a definition's `policy`.

  Returns `:ok`, or the error defining the agent would give.

      Wardrik.check_policy(%{"judge" => %{"questions" => [%{"question" => "Publish?"}]}})
      #=> {:error, "a question decides nothing; give it deny, ask or allow"}
  """
  @spec check_policy(map()) :: :ok | {:error, String.t()}
  def check_policy(policy) do
    case WardrikPolicy.decode(policy) do
      {:ok, _policy} -> :ok
      {:error, message} -> {:error, message}
    end
  end

  @doc """
  Returns the scope `principal` acts in on `instance`.

  `grants` is a list of `Wardrik.Statement`s, or the options for one. Nothing is allowed unless
  it's granted.

      scope = Wardrik.as(MyApp.AgentRuntime, "acme/@maria", roles: [:reader], resources: ["acme/agent/*"])
  """
  @spec as(atom() | t(), Principal.t() | String.t(), term()) :: Scope.t()
  def as(instance, principal, grants \\ [])

  def as(instance, principal, grants),
    do: Scope.new(__MODULE__, Instance.name(instance), principal, grants)

  @doc """
  Returns the scope of the API token `secret` on `instance`.

  Returns an `unauthorized` error if the token is unknown or has expired.

      {:ok, scope} = Wardrik.authenticate(MyApp.AgentRuntime, secret)
  """
  @spec authenticate(atom() | t(), String.t()) :: {:ok, Scope.t()} | {:error, Error.t()}
  @impl Wardrik.Server
  def authenticate(instance, secret),
    do: Wardrik.Operations.Tokens.authenticate(Instance.fetch!(instance), secret)

  @doc """
  Seals `value` as `owner`'s secret `name`, and records it in the audit.

  `owner` is an org, as `"acme"`, or a person, as `"acme/@maria"`. Their agents' tools and servers
  can use the secret. Returns `{:error, :no_keys}` if Wardrik was started without `:keys`.

      :ok = Wardrik.put_secret(MyApp.AgentRuntime, "acme", "ANTHROPIC_API_KEY", key, kind: :api_key)

  ## Options

    * `:kind` - what it's for, as `:api_key` or `:client_secret`. It's read only for that. See
      `t:WardrikVault.kind/0`.
    * `:if_vsn` - only write if the secret is still at this version. See `lookup_secret/3`.
  """
  @spec put_secret(atom() | t(), String.t(), String.t(), binary(), keyword()) ::
          :ok | {:error, term()}
  def put_secret(instance, owner, name, value, opts \\ []),
    do: Wardrik.Sealed.put(instance, owner, name, value, opts)

  @doc "Returns `owner`'s secret `name`, unsealed."
  @spec fetch_secret(atom() | t(), String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch_secret(instance, owner, name), do: Wardrik.Sealed.fetch(instance, owner, name)

  @doc """
  Returns `owner`'s secret `name`, unsealed, with its kind and version.

  The kind is `:secret`, or `:grant` for an account someone connected. Pass the version to
  `put_secret/5` as `:if_vsn`.
  """
  @spec lookup_secret(atom() | t(), String.t(), String.t()) ::
          {:ok, WardrikVault.kind(), binary(), term()}
          | {:error, term()}
          | {:error, WardrikVault.kind(), term()}
  def lookup_secret(instance, owner, name), do: Wardrik.Sealed.lookup(instance, owner, name)

  @doc "Removes `owner`'s secret `name`, and records it in the audit. Returns `:ok` if there's none."
  @spec delete_secret(atom() | t(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete_secret(instance, owner, name), do: Wardrik.Sealed.delete(instance, owner, name)

  @doc """
  Lists every secret as `{owner, name, kind}`, or with `owner`, the names of theirs.

  Values aren't unsealed. Returns `[]` if Wardrik was started without `:keys`.
  """
  @spec list_secrets(atom() | t()) :: [{String.t(), String.t(), WardrikVault.kind()}]
  def list_secrets(instance), do: Wardrik.Sealed.list(instance)

  @spec list_secrets(atom() | t(), String.t()) :: [String.t()]
  def list_secrets(instance, owner), do: Wardrik.Sealed.list(instance, owner)

  @doc """
  Adds a statement to `scope`. `opts` are as `Wardrik.Statement.new/1` takes them.

      MyApp.AgentRuntime.as("acme/@maria") |> Wardrik.grant(roles: [:approver], resources: ["acme/agent/*"])
  """
  @spec grant(Scope.t(), keyword()) :: Scope.t()
  def grant(scope, opts), do: Scope.grant(scope, opts)

  @doc """
  Runs the operation `id`, such as `"agent.ask"`, in `scope`.

  `input` follows the operation's input schema.

      Wardrik.run(scope, "agent.ask", %{"agent" => "acme/triage", "content" => "What's on fire?"})
      #=> {:ok, %{"message" => %{"id" => "msg_Xq3f...", "cursor" => "eyJhY21lL3RyaWFnZSI6NDF9"}}}
  """
  @spec run(Scope.t(), String.t(), map()) :: {:ok, term()} | {:error, Error.t()}
  @impl Wardrik.Server
  def run(%Scope{} = scope, id, input), do: Runner.run(scope, id, input, :handlers)

  @doc """
  Streams the operation `id`, such as `"events.list"`, in `scope`.

  The stream yields `{event, cursor}`. It reads what's there, then follows new events.

      {:ok, stream} = Wardrik.stream(scope, "events.list", %{"resources" => ["acme/*"]})
  """
  @spec stream(Scope.t(), String.t(), map()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  @impl Wardrik.Server
  def stream(%Scope{} = scope, id, input), do: Runner.run(scope, id, input, :streams)

  @impl Wardrik.Server
  def follow(scope, agent, input, opts), do: Wardrik.Answers.follow(scope, agent, input, opts)

  @impl Wardrik.Server
  def offer(scope, tools), do: Wardrik.Workers.offer(scope, tools)

  @impl Wardrik.Server
  def answer(call, message), do: Wardrik.Workers.answer(call, message)

  @doc """
  Starts an agent on `instance`.

  `opts` are as `WardrikCore.start_agent/2` takes them. `:policy` is the agent's own
  `WardrikPolicy`, or its rules. The agent is held to its own policy, its org's and Wardrik's.
  The strictest decides.

      Wardrik.start_agent(MyApp.AgentRuntime,
        agent_id: "acme/books",
        model: "anthropic:claude-haiku-4-5",
        policy: [ask: ["books/pay_bill"]]
      )
  """
  @spec start_agent(atom() | t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_agent(instance, opts) do
    wardrik = Instance.fetch!(instance)
    org = Wardrik.Orgs.org(Keyword.fetch!(opts, :agent_id))

    with {:ok, settings} <- Wardrik.Orgs.settings(wardrik, org) do
      held = Wardrik.Orgs.hold(opts, wardrik, org, settings)
      WardrikCore.start_agent(agents(wardrik), Setup.agent(wardrik, held))
    end
  end

  @doc """
  Applies the org's current settings to its awake agents.

  Sleeping agents pick them up when they wake. Returns a line for each agent it couldn't update.

      Wardrik.refresh(MyApp.AgentRuntime, org: "acme")
      #=> []
  """
  @spec refresh(atom() | t(), keyword()) :: [String.t()]
  def refresh(instance, opts) do
    opts = Keyword.validate!(opts, [:org])
    Wardrik.Orgs.refresh(Instance.fetch!(instance), Keyword.fetch!(opts, :org))
  end

  @doc """
  Returns the plug for sign-in callback pages, as `{plug, opts}`, or `nil` without `:oauth`.

  Mount it at the `:oauth` option's `page`. `principal` is `{module, function, args}`, called with
  the conn, returning who your app knows is at the browser, or `nil`. See `WardrikOAuth.Plug`.

      Wardrik.sign_in_pages(MyApp.AgentRuntime, {MyApp.Session, :principal, []})
  """
  @spec sign_in_pages(atom() | t(), mfa()) :: {module(), term()} | nil
  def sign_in_pages(instance, principal),
    do: instance |> Instance.fetch!() |> pages(principal)

  @doc """
  Finishes a browser sign-in from its callback `params`, for the principal `as` names.

      Wardrik.finish_sign_in(MyApp.AgentRuntime, params, as: current_principal)
      #=> {:ok, %{provider: "github", principal: %WardrikCore.Principal{id: "acme/@jon"}}}

  Use it if your app serves the callback page itself. `params` holds `"state"`, and `"code"` or
  `"error"`. Only the principal who started the sign-in can finish it. See `WardrikOAuth.finish/3`.
  """
  @spec finish_sign_in(atom() | t(), map(), keyword()) ::
          {:ok, %{provider: String.t(), principal: Principal.t()}} | {:error, term()}
  def finish_sign_in(instance, params, opts),
    do: instance |> Instance.fetch!() |> oauth() |> WardrikOAuth.finish(params, opts)

  @doc """
  Returns Wardrik's OAuth Client ID Metadata Document.

  The sign-in pages serve it at `/client`. Use it if your app serves the document itself.
  """
  @spec client_document(atom() | t()) :: map()
  def client_document(instance),
    do: instance |> Instance.fetch!() |> oauth() |> WardrikOAuth.client_document()

  defp pages(%__MODULE__{oauth: nil}, _principal), do: nil

  defp pages(wardrik, principal),
    do: {WardrikOAuth.Plug, WardrikOAuth.Plug.init(oauth: oauth(wardrik), principal: principal)}

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

  @doc false
  @spec mcp(t()) :: atom()
  def mcp(%__MODULE__{name: name}), do: Module.concat(name, MCP)

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
