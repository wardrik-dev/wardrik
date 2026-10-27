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
    :channels,
    :notify,
    :declarations,
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
    :trusted_workers
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
          trusted_workers: boolean()
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
  connects to each. `:channels` are the chat apps people reach agents through, by name, each a
  `Wardrik.Channel` as `{module, opts}`. `:notify` names where agents' notices may go, as
  `Wardrik.Notify` describes. `:declarations` are agents something outside the API defines, as
  `Wardrik.Declarations` describes. `:workspace` shares trees of files beyond their owners, as
  `Wardrik.Workspaces` describes. `:triggers` takes `WardrikTriggers`' `:req_options`, for reading
  feeds, and `:reconcile`.

  What a definition names, it finds here: `:capabilities`, the tools it offers by name, as
  `[files: {MyApp.Files, []}]`, and `:policies`, as `[careful: [ask: ["github/*"]]]`. Each MCP
  server is a tool too, as `github/*`. `:middleware` wraps every agent's calls, and `:idle_timeout`
  is how many seconds a defined agent may have nothing to do before it sleeps, 900 unless set, or
  `:infinity`. `:defaults` is what every definition is given where it says nothing, as
  `%{"model" => "anthropic:claude-haiku-4-5"}`, however it was defined. `:trusted_workers` is
  `true` where tool workers' answers are the deployment's own, so they aren't labelled `"outside"`.
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
  def grant(%Scope{grants: grants} = scope, opts) when is_list(grants),
    do: %{scope | grants: grants ++ [Wardrik.Statement.new(opts)]}

  defp statements([{key, _value} | _rest] = opts) when key in [:roles, :actions, :resources],
    do: [Wardrik.Statement.new(opts)]

  defp statements(grants), do: grants

  @doc """
  Runs the operation `id`, like `agent.ask`, in `scope`, with `input` as the operation's input
  schema describes it.

      Wardrik.run(scope, "agent.ask", %{"agent" => "acme/triage", "content" => "What's on fire?"})
      #=> {:ok, %{"message" => %{"id" => "msg_Xq3f...", "cursor" => "eyJhY21lL3RyaWFnZSI6NDF9"}}}
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
  to the Wardrik `instance`'s. `:policy` is the agent's own `WardrikPolicy`, or the rules to build it
  from. The agent is held to it and to the Wardrik's, and the strictest decides.

      Wardrik.start_agent(MyApp.Wardrik,
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

  @doc """
  Returns the plug that serves the pages a sign-in comes back to, with its options, for a surface
  to mount at the `:oauth` `page`. Returns `nil` where the Wardrik `instance` signs no one in.

      Wardrik.sign_in_pages(MyApp.Wardrik)
      #=> {WardrikOAuth.Plug, MyApp.Wardrik.OAuth}
  """
  @spec sign_in_pages(atom() | t()) :: {module(), term()} | nil
  def sign_in_pages(instance), do: instance |> Instance.fetch!() |> pages()

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
