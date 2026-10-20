defmodule Wardrik.Host do
  @moduledoc """
  What the host running Wardrik answers that core cannot: the store
  everything is kept in, where agents' definitions are kept, which accounts
  people connect, which MCP servers they add, where secrets come from, how
  callers' tokens are kept, where requests for triggers go, what token each
  principal acts with, where agents' files are kept, what each model call
  actually is, what makes it, and what runs agents' turns.

  `:store` is a `WardrikStore`, the one the host started, or
  `WardrikStore.None`'s where it names none, which raises on the first read
  or write. Each of the others is a value implementing one protocol, which
  carries its own settings, such as the store it keeps things in:

  | Field | Protocol | Default |
  | --- | --- | --- |
  | `:definitions` | `Wardrik.Specs` | `%Wardrik.Specs.None{}` |
  | `:connections` | `Wardrik.Connections` | `%Wardrik.Connections.None{}` |
  | `:servers` | `Wardrik.Servers` | `%Wardrik.Servers.None{}` |
  | `:credentials` | `Wardrik.Credentials` | `%Wardrik.Credentials.None{}` |
  | `:tokens` | `Wardrik.Tokens` | `%Wardrik.Tokens.None{}` |
  | `:triggers` | `Wardrik.Triggers` | `%Wardrik.Triggers.None{}` |
  | `:issuer` | `Wardrik.Issuer` | `%Wardrik.Issuer.None{}` |
  | `:workspace` | `Wardrik.Workspace` | `%Wardrik.Workspace.None{}` |
  | `:dispatch` | `Wardrik.LLM.Dispatch` | `%Wardrik.LLM.Dispatch.Direct{}` |
  | `:llm` | `Wardrik.LLM.Client` | `%Wardrik.LLM.ReqLLM{}` |
  | `:runtimes` | `Wardrik.Runtime`, a list of them | `[%Wardrik.LLM.Runtime{}]` |

  `Wardrik`, of the `wardrik` package, builds the host of an application
  embedding Wardrik from its options. A host that puts its own tree
  together names its store and the seams it offers once, as it starts
  `Wardrik.Core`, and hands the same host to whatever surface it starts after it:

      store = WardrikStore.new(adapter: WardrikEcto.Store, repo: MyApp.Repo)

      host =
        Wardrik.Host.new(
          store: store,
          definitions: %MyApp.Specs{store: store},
          issuer: %MyApp.Issuer{admins: ["maria"]}
        )

      children = [
        MyApp.Repo,
        {WardrikStore, store},
        {Wardrik.Core, host: host},
        {MyApp.Endpoint, host: host}
      ]

  A seam it does not name is its default: a None, which answers each
  function with `:unsupported`, or with what having none means in that
  function's own terms, as a token allowing nothing; for `:dispatch`
  `Direct`, which makes each model call as it stands; for `:llm`
  `Wardrik.LLM.ReqLLM`, which reaches every provider ReqLLM does; and for
  `:runtimes` `Wardrik.LLM.Runtime`, whose turns ask a model. So every
  field is always a value its protocol answers for, and code asks it
  without first asking whether there is one.

  `:expires` is how long a token the host makes lasts, by its kind, in
  seconds: `:api`, one made for the HTTP API with `Wardrik.tokens_create/4`,
  90 days unless given; `:session`, one its `:issuer` issues through
  `Wardrik.as/3`, 12 hours unless given. Naming one keeps the other's
  default.

  The host travels with the work, never with what is stored: each scope a
  surface acts in carries it to what it acts on, and each agent is handed
  it as it starts, wakes or restarts on another node (see `Wardrik.Agent`).
  A node runs one `Wardrik.Core`, so one host; see `Wardrik.Core`.

  The accessors answer each seam's value, so code that acts on the agents
  names the field, never an implementation.

  ## What packages add

  Beside its seams, a host holds what the packages it runs add to it, each
  empty until one does:

  | Field | What it holds |
  | --- | --- |
  | `:tools` | the tools a definition names, each a module implementing `Wardrik.Tool`, by its name |
  | `:sources` | the tool sources a definition names as `name/*`, by that name: each a module implementing `Wardrik.Tool`'s `tools/1`, handed the agent's ID, or a value of a package's own, as `WardrikDefinition.Source` reads them |
  | `:settings` | what a package's module is handed as it runs, such as a key a tool searches with, by the module: held here, never in the store |
  | `:routes` | what the host serves over HTTP, each a plug and its options, by the segments of its path |
  | `:children` | what `Wardrik` starts after its own, in order, each `{module, opts}` |

  A package adds to them in an `attach/2` of its own, which takes the host
  and the package's options, checked with `Keyword.validate!/2`, and answers
  the host with what it adds, through `register/3` and `child/2`: it is a
  `Wardrik.Plugin`. One
  attached after another starts after it:

      defmodule MyApp.Search do
        def attach(host, opts \\ []) do
          opts = Keyword.validate!(opts, [:index])

          host
          |> Wardrik.Host.register(:tools, [{"search", MyApp.Search.Tool}])
          |> Wardrik.Host.child({MyApp.Search.Index, opts})
        end
      end

      host = Wardrik.Host.new(store: store) |> MyApp.Search.attach(index: "docs")

  `Wardrik` starts each child with `host:` the host it starts with, so a
  child is handed what everything attached after it added too.
  """

  @expires [api: 90 * 86_400, session: 12 * 3_600]

  defstruct store: %WardrikStore.None{},
            definitions: %Wardrik.Specs.None{},
            connections: %Wardrik.Connections.None{},
            servers: %Wardrik.Servers.None{},
            credentials: %Wardrik.Credentials.None{},
            tokens: %Wardrik.Tokens.None{},
            triggers: %Wardrik.Triggers.None{},
            issuer: %Wardrik.Issuer.None{},
            workspace: %Wardrik.Workspace.None{},
            dispatch: %Wardrik.LLM.Dispatch.Direct{},
            llm: %Wardrik.LLM.ReqLLM{},
            runtimes: [%Wardrik.LLM.Runtime{}],
            tools: %{},
            sources: %{},
            settings: %{},
            routes: [],
            children: [],
            audit: Wardrik.Audit,
            expires: @expires

  @typedoc "What the host serves at a path, given as its segments: a plug and its options."
  @type route() :: {[String.t()], {module(), term()}}

  @type t() :: %__MODULE__{
          store: WardrikStore.t(),
          definitions: Wardrik.Specs.t(),
          connections: Wardrik.Connections.t(),
          servers: Wardrik.Servers.t(),
          credentials: Wardrik.Credentials.t(),
          tokens: Wardrik.Tokens.t(),
          triggers: Wardrik.Triggers.t(),
          issuer: Wardrik.Issuer.t(),
          workspace: Wardrik.Workspace.t(),
          dispatch: Wardrik.LLM.Dispatch.t(),
          llm: Wardrik.LLM.Client.t(),
          runtimes: [Wardrik.Runtime.t()],
          tools: %{String.t() => module()},
          sources: %{String.t() => module() | struct()},
          settings: %{module() => keyword()},
          routes: [route()],
          children: [{module(), keyword()}],
          audit: GenServer.name(),
          expires: [api: pos_integer(), session: pos_integer()]
        }

  @seams [
    :definitions,
    :connections,
    :servers,
    :credentials,
    :tokens,
    :triggers,
    :issuer,
    :workspace,
    :dispatch,
    :llm,
    :runtimes
  ]

  @doc """
  The host keeping everything in the `:store` `opts` names, offering the
  seams it names, each by its value, and the None of each it leaves out.

      Wardrik.Host.new(store: store, tokens: %WardrikHTTP.Tokens{store: store})
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    opts = Keyword.validate!(opts, [:store, :audit, :expires | @seams])

    struct!(
      __MODULE__,
      Keyword.update(opts, :expires, @expires, &Keyword.validate!(&1, @expires))
    )
  end

  @doc "The `WardrikStore` everything is kept in."
  @spec store(t()) :: WardrikStore.t()
  def store(%__MODULE__{store: store}), do: store

  @doc "The `Wardrik.Specs` the agents it defines start from."
  @spec definitions(t()) :: Wardrik.Specs.t()
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

  @doc "The `Wardrik.LLM.Client` every model call is made through."
  @spec llm(t()) :: Wardrik.LLM.Client.t()
  def llm(%__MODULE__{llm: llm}), do: llm

  @doc """
  The runtime of the host's `:runtimes` whose `Wardrik.Runtime.key/1` is
  `key`, which runs the turns of the agents whose settings name it.
  """
  @spec runtime(t(), String.t()) :: Wardrik.Runtime.t()
  def runtime(%__MODULE__{runtimes: runtimes}, key) do
    Enum.find(runtimes, &(Wardrik.Runtime.key(&1) == key)) ||
      raise ArgumentError, "the host runs no runtime #{inspect(key)}"
  end

  @doc "The runtimes the host runs, the first reading every definition that names none of theirs."
  @spec runtimes(t()) :: [Wardrik.Runtime.t()]
  def runtimes(%__MODULE__{runtimes: runtimes}), do: runtimes

  @doc "The tools a definition names, by name."
  @spec tools(t()) :: %{String.t() => module()}
  def tools(%__MODULE__{tools: tools}), do: tools

  @doc "The tool sources a definition names as `name/*`, by name."
  @spec sources(t()) :: %{String.t() => module() | struct()}
  def sources(%__MODULE__{sources: sources}), do: sources

  @doc """
  What the host hands `module` as it runs, as a package registered it
  under `:settings`, or nothing where it registered none. A tool reads its
  own through the host of the run it is called in.
  """
  @spec settings(t(), module()) :: keyword()
  def settings(%__MODULE__{settings: settings}, module), do: Map.get(settings, module, [])

  @doc "What the host serves over HTTP, in the order it was registered."
  @spec routes(t()) :: [route()]
  def routes(%__MODULE__{routes: routes}), do: routes

  @doc "What `Wardrik` starts after its own, in order."
  @spec children(t()) :: [{module(), keyword()}]
  def children(%__MODULE__{children: children}), do: children

  @doc """
  `host` with `entries` added to `field`: to `:tools`, `:sources` or
  `:routes`, each a name and its value; to `:settings`, each a module and
  what it is handed; to `:runtimes`, each a runtime, named by its
  `Wardrik.Runtime.key/1`, after those it runs. Raises where a name is
  taken.

      Wardrik.Host.register(host, :sources, [{"workers", WardrikHTTP.Workers}])
  """
  @spec register(t(), :tools, [{String.t(), module()}]) :: t()
  @spec register(t(), :sources, [{String.t(), module() | struct()}]) :: t()
  @spec register(t(), :settings, [{module(), keyword()}]) :: t()
  @spec register(t(), :routes, [route()]) :: t()
  @spec register(t(), :runtimes, [Wardrik.Runtime.t()]) :: t()
  def register(%__MODULE__{} = host, field, entries)
      when field in [:tools, :sources, :settings, :routes, :runtimes] do
    held = Map.fetch!(host, field)
    names = Enum.map(Enum.to_list(held) ++ entries, &name(field, &1))

    case names -- Enum.uniq(names) do
      [] -> Map.put(host, field, added(field, held, entries))
      [taken | _] -> raise ArgumentError, "the host's #{field} has #{inspect(taken)} already"
    end
  end

  defp name(:runtimes, runtime), do: Wardrik.Runtime.key(runtime)
  defp name(_field, {name, _value}), do: name

  defp added(field, held, entries) when field in [:routes, :runtimes], do: held ++ entries
  defp added(_field, held, entries), do: Map.merge(held, Map.new(entries))

  @doc """
  `host` with `child` among its children, after those added before it.
  `Wardrik` starts it with `host:` the host it starts with among its
  options.
  """
  @spec child(t(), {module(), keyword()}) :: t()
  def child(%__MODULE__{children: children} = host, {_module, _opts} = child),
    do: %{host | children: children ++ [child]}

  @doc "The `Wardrik.Issuer` that issues each principal the token it acts with."
  @spec issuer(t()) :: Wardrik.Issuer.t()
  def issuer(%__MODULE__{issuer: issuer}), do: issuer

  @doc "How long a token of `kind` the host makes lasts, in seconds."
  @spec expires(t(), :api | :session) :: pos_integer()
  def expires(%__MODULE__{expires: expires}, kind), do: Keyword.fetch!(expires, kind)
end
