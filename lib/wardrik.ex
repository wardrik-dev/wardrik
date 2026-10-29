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

  @behaviour Wardrik.Server

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
          own_store: boolean(),
          keys: [String.t()],
          oauth: keyword() | nil,
          mcp: keyword() | nil,
          listeners: [module() | {module(), keyword()}],
          channels: %{String.t() => {module(), keyword()}},
          notify: %{targets: %{String.t() => {module(), keyword()}}, retries: keyword()},
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
          idle_timeout: pos_integer() | :infinity,
          trusted_workers: boolean(),
          egress: (String.t() -> :ok | {:error, String.t()}),
          prices: %{String.t() => WardrikCore.Usage.price()}
        }

  @doc """
  Runs as a Wardrik made with `use Wardrik` starts, with its options, to give those only known as it
  runs, like a secret from the environment.

      @impl Wardrik
      def init(config), do: {:ok, Keyword.put(config, :keys, [System.fetch_env!("WARDRIK_KEY")])}
  """
  @callback init(config :: keyword()) :: {:ok, keyword()}

  defmacro __using__(opts), do: Wardrik.Instance.using(Keyword.get(opts, :otp_app))

  @doc """
  Starts a Wardrik. Takes `:name`, and where it keeps agents and events: `:data_dir`, a directory
  on disk, `:store`, one `store/1` builds, as `[repo: MyApp.Repo]`, which it runs itself, or a
  store you run yourself. Given neither, it keeps them in memory, gone when it stops.

  It also takes `:deployment` (`"local"` unless set), `:authorizer`, a `Wardrik.Authorizer` as
  `{module, config}` (`Wardrik.Statements` unless set), `:retention`, the days events are kept (30
  unless set), `:backend`, where agents are kept (the store unless set), `:discovery_interval_ms`,
  how often a node looks in the store for agents no node runs (30 seconds unless set), and `:policy`, the
  `WardrikPolicy` every agent is held to, or the rules to build it from.

  Given `:keys`, it keeps credentials sealed with them, and gives them to every agent's tools. Given
  `:oauth` too, as `WardrikOAuth` takes its `:page`, `:providers`, `:client_name` and
  `:req_options`, people sign in to give agents their accounts, and the calls waiting on a sign-in
  carry on once it's done.

  Given `:mcp`, the MCP servers its agents may call, as `WardrikMCP` takes its `:servers`, it
  connects to each; a server's own `:orgs` lists the orgs whose agents reach it, every org's
  unless it says. `:channels` are the chat apps people reach agents through, by name, each a
  `Wardrik.Channel` as `{module, opts}`. `:notify` names where agents' notices may go, as
  `Wardrik.Notify` describes. `:declarations` are agents something outside the API defines, as
  `Wardrik.Declarations` describes. `:orgs` gives each org settings of its own, as `Wardrik.Orgs`
  describes. `:workspace` shares trees of files beyond their owners, as
  `Wardrik.Workspaces` describes. `:triggers` takes `WardrikTriggers`' `:req_options`, for reading
  feeds, and `:reconcile`.

  What a definition names, it finds here: `:capabilities`, the tools it offers by name, as
  `[files: {MyApp.Files, []}]`, and `:policies`, as `[careful: [ask: ["github/*"]]]`. Each MCP
  server is a tool too, as `github/*`. `:middleware` wraps every agent's calls, and `:idle_timeout`
  is how many seconds a defined agent may have nothing to do before it sleeps, 900 unless set, or
  `:infinity`. `:defaults` is what every definition is given where it says nothing, as
  `%{"model" => "anthropic:claude-haiku-4-5"}`, however it was defined. `:trusted_workers` is
  `true` where tool workers' answers are the deployment's own, so they aren't labelled `"outside"`.
  `:egress` says which URLs it reaches where its users name them, as the servers an owner adds and
  the sign-ins they lead to: `Wardrik.Egress.public/1` unless set. `:prices` says what models cost
  where the model catalog has no price, or not the one to count, by spec, as `Wardrik.Setup.price/2`
  reads each:

      prices: %{"zai_coding_plan:glm-5.1" => [priced_as: "zai:glm-5.1", markup: 0.1]}

  Every agent's spending, budgets, ceilings and events count them.
  """
  @spec start_link(keyword() | t()) :: Supervisor.on_start()
  def start_link(%__MODULE__{name: name} = wardrik),
    do: Supervisor.start_link(__MODULE__, wardrik, name: name)

  def start_link(opts) when is_list(opts), do: opts |> Setup.wardrik() |> start_link()

  @doc false
  @spec new(keyword()) :: t()
  def new(opts), do: Setup.wardrik(opts)

  @doc """
  Returns a store for a Wardrik to keep everything in: your app's own Postgres, through its Ecto
  repo, as `[repo: MyApp.Repo]`, or a database of its own, as `[url: "postgres://..."]`. Give it as
  `:store`, and the Wardrik runs it.
  """
  @spec store(keyword()) :: WardrikStore.t()
  def store(opts), do: WardrikStore.Ecto.new(opts)

  @doc """
  Returns the principal `id` names, as `acme/@maria`, with `attributes`, such as a name to show.

      Wardrik.principal("acme/@maria", %{name: "Maria"})
  """
  @spec principal(String.t(), map()) :: Principal.t()
  def principal(id, attributes \\ %{}), do: %Principal{id: id, attributes: attributes}

  @doc """
  Returns the name of the key a call to `model` takes, as its provider names it, or `nil`. A key of
  that name in the vault, the deployment's or an owner's, is what the call is made with.

      Wardrik.key_name("zai_coding_plan:glm-5.1")
      #=> "ZAI_API_KEY"
  """
  @spec key_name(String.t()) :: String.t() | nil
  def key_name(model), do: WardrikCore.Keys.key_name(model)

  @doc """
  Returns the cursor that stands past `positions`, each log's last sequence read, by its agent's or
  conversation's ID, for `events.list` to read on from.
  """
  @spec cursor(%{String.t() => non_neg_integer()}) :: String.t()
  def cursor(positions), do: WardrikEvents.Cursor.encode(positions)

  @doc "Returns the positions a cursor stands past, each log's last sequence read, by its ID."
  @spec positions(String.t()) :: {:ok, %{String.t() => non_neg_integer()}} | :error
  def positions(cursor) do
    case WardrikEvents.Cursor.decode(cursor) do
      {:ok, positions} -> {:ok, positions}
      {:error, _reason} -> :error
    end
  end

  @doc """
  Returns `:ok` where a definition's `policy` reads, or what it would refuse, as defining the agent
  would say it.

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
  Returns the scope `principal` acts in on the Wardrik `instance`, allowed what `grants` say: a list
  of `Wardrik.Statement`s, or the options of one. Nothing is allowed unless it's granted.

      scope = Wardrik.as(MyApp.Wardrik, "acme/@maria", roles: [:reader], resources: ["acme/agent/*"])
  """
  @spec as(atom() | t(), Principal.t() | String.t(), term()) :: Scope.t()
  def as(instance, principal, grants \\ [])

  def as(instance, principal, grants),
    do: Scope.new(__MODULE__, Instance.name(instance), principal, grants)

  @doc """
  Returns the scope an API token's `secret` acts in on the Wardrik `instance`, or an `unauthorized`
  error where it isn't one, or has expired.

      {:ok, scope} = Wardrik.authenticate(MyApp.Wardrik, secret)
  """
  @spec authenticate(atom() | t(), String.t()) :: {:ok, Scope.t()} | {:error, Error.t()}
  @impl Wardrik.Server
  def authenticate(instance, secret),
    do: Wardrik.Operations.Tokens.authenticate(Instance.fetch!(instance), secret)

  @doc """
  Seals `value` as the secret `name` of `owner`, an org, as `acme`, or a person, as `acme/@maria`,
  for their agents' tools and servers, and records it in the audit. It needs `:keys`, and takes
  `if_vsn:`, to write over only the version read.

      :ok = Wardrik.put_secret(MyApp.Wardrik, "acme", "crm-key", System.fetch_env!("CRM_KEY"))
  """
  @spec put_secret(atom() | t(), String.t(), String.t(), binary(), keyword()) ::
          :ok | {:error, term()}
  def put_secret(instance, owner, name, value, opts \\ []),
    do: Wardrik.Sealed.put(instance, owner, name, value, opts)

  @doc "Unseals the secret `name` of `owner`."
  @spec fetch_secret(atom() | t(), String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch_secret(instance, owner, name), do: Wardrik.Sealed.fetch(instance, owner, name)

  @doc """
  Unseals the secret `name` of `owner`, with its kind, `:secret` or `:grant` for an account someone
  connected, and its version, for `put_secret/5`'s `if_vsn:`.
  """
  @spec lookup_secret(atom() | t(), String.t(), String.t()) ::
          {:ok, WardrikVault.kind(), binary(), term()}
          | {:error, term()}
          | {:error, WardrikVault.kind(), term()}
  def lookup_secret(instance, owner, name), do: Wardrik.Sealed.lookup(instance, owner, name)

  @doc "Removes the secret `name` of `owner`, and records it in the audit. Removing none is `:ok`."
  @spec delete_secret(atom() | t(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete_secret(instance, owner, name), do: Wardrik.Sealed.delete(instance, owner, name)

  @doc """
  Lists every secret as `{owner, name, kind}`, or the names `owner` holds. It reads no secret, and
  needs no key.
  """
  @spec list_secrets(atom() | t()) :: [{String.t(), String.t(), WardrikVault.kind()}]
  def list_secrets(instance), do: Wardrik.Sealed.list(instance)

  @spec list_secrets(atom() | t(), String.t()) :: [String.t()]
  def list_secrets(instance, owner), do: Wardrik.Sealed.list(instance, owner)

  @doc """
  Allows `scope` more, as `Wardrik.Statement.new/1` takes it.

      MyApp.Wardrik.as("acme/@maria") |> Wardrik.grant(roles: [:approver], resources: ["acme/agent/*"])
  """
  @spec grant(Scope.t(), keyword()) :: Scope.t()
  def grant(scope, opts), do: Scope.grant(scope, opts)

  @doc """
  Runs the operation `id`, like `agent.ask`, in `scope`, with `input` as the operation's input
  schema describes it.

      Wardrik.run(scope, "agent.ask", %{"agent" => "acme/triage", "content" => "What's on fire?"})
      #=> {:ok, %{"message" => %{"id" => "msg_Xq3f...", "cursor" => "eyJhY21lL3RyaWFnZSI6NDF9"}}}
  """
  @spec run(Scope.t(), String.t(), map()) :: {:ok, term()} | {:error, Error.t()}
  @impl Wardrik.Server
  def run(%Scope{} = scope, id, input), do: Runner.run(scope, id, input, :handlers)

  @doc """
  Streams what the operation `id` reads, as `{event, cursor}`, reading on and then following, for an
  operation that can be streamed, like `events.list`.
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
  Starts the agent `opts` describe, as `WardrikCore.start_agent/2` takes them, writing its events
  to the Wardrik `instance`'s. `:policy` is the agent's own `WardrikPolicy`, or the rules to build it
  from. The agent is held to it, to its org's, and to the Wardrik's, and the strictest decides.

      Wardrik.start_agent(MyApp.Wardrik,
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
  Brings the awake agents of the org `:org` to its settings as `:orgs` gives them now, and returns
  what it couldn't, a line each. Those asleep take them as they wake.

      Wardrik.refresh(MyApp.Wardrik, org: "acme")
      #=> []
  """
  @spec refresh(atom() | t(), keyword()) :: [String.t()]
  def refresh(instance, opts) do
    opts = Keyword.validate!(opts, [:org])
    Wardrik.Orgs.refresh(Instance.fetch!(instance), Keyword.fetch!(opts, :org))
  end

  @doc """
  Returns the plug that serves the pages a sign-in comes back to, with its options, for a surface
  to mount at the `:oauth` `page`. Returns `nil` where the Wardrik `instance` signs no one in.

      Wardrik.sign_in_pages(MyApp.Wardrik)
      #=> {WardrikOAuth.Plug, MyApp.Wardrik.OAuth}
  """
  @spec sign_in_pages(atom() | t()) :: {module(), term()} | nil
  def sign_in_pages(instance), do: instance |> Instance.fetch!() |> pages()

  @doc """
  Finishes the browser sign-in a callback's `params` name, with the `state` and `code` or `error` it
  carried, for an app that serves the page itself. Returns the provider signed in to.
  """
  @spec finish_sign_in(atom() | t(), map()) :: {:ok, String.t()} | {:error, term()}
  def finish_sign_in(instance, params),
    do: instance |> Instance.fetch!() |> oauth() |> WardrikOAuth.finish(params)

  @doc """
  Returns the Client ID Metadata Document a service reads the Wardrik by, served at its sign-in
  page's `/client`, for an app that serves it itself.
  """
  @spec client_document(atom() | t()) :: map()
  def client_document(instance),
    do: instance |> Instance.fetch!() |> oauth() |> WardrikOAuth.client_document()

  defp pages(%__MODULE__{oauth: nil}), do: nil
  defp pages(wardrik), do: {WardrikOAuth.Plug, WardrikOAuth.Plug.init(oauth: oauth(wardrik))}

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
