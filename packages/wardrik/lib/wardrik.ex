defmodule Wardrik do
  @moduledoc """
  Wardrik inside an application: agents kept in the application's own store,
  started in its own tree, and reached as the people it knows.

  `new/1` reads the options once, into a value the application starts and
  makes its callers with:

      wardrik =
        Wardrik.new(
          store: Wardrik.store(repo: MyApp.Repo),
          grants: %MyApp.Grants{},
          context: Wardrik.context(tools: [MyApp.Tools.Search])
        )

      children = [MyApp.Repo, {Wardrik, wardrik}, MyAppWeb.Endpoint]

      {:ok, caller} = Wardrik.caller(wardrik, principal: maria, subject: agent)
      Wardrik.Command.run(%Wardrik.Operations.Cancel{agent: agent}, caller)

  `{Wardrik, wardrik}` starts, in order, under `:rest_for_one`, so a restart
  of one restarts everything after it:

  | Child | What it runs |
  | --- | --- |
  | the store | where everything is kept |
  | `Wardrik.Core` | the agents |
  | the meters | what budgets count in |
  | the triggers | clocks, feeds and webhooks |

  Each agent's definition is kept in the store, read against what
  `:context` lets it name, and so are the files it works on.

  The store is a value of its own, made by `store/1`, so a seam that keeps
  something, such as a vault of credentials, is made with the same one. So
  is the context, made by `context/1`, so an application can read it
  differently for each agent. A
  surface the application starts after Wardrik, such as the HTTP API, takes
  the store or `host/1`. A node runs one Wardrik, since core's own
  processes are registered under their module names.

  ## Options

    * `:store` - where everything is kept, as `store/1` makes it. Required.
    * `:context` - what each agent's definition may name: `context/1`'s, or
      a value of the application's own implementing
      `WardrikDefinition.Contexts`, which gives each agent its context.
      `context([])` by default.
    * `:grants`, `:credentials`, `:connections`, `:servers`, `:tokens`,
      `:triggers`, `:dispatch` - the host's seams, each a value implementing
      core's protocol of that name, as `Wardrik.Host` lists them. One left
      out is that protocol's None: no grants, no credentials, and so on.
    * `:fleet` - the options of `Wardrik.Fleet.Supervisor`.
  """

  use Supervisor

  alias WardrikDefinition.Context

  @enforce_keys [:host]
  defstruct [:host, fleet: []]

  @type t() :: %__MODULE__{host: Wardrik.Host.t(), fleet: keyword()}

  @seams [:grants, :credentials, :connections, :servers, :tokens, :triggers, :dispatch]

  # The setting that names each store.
  @stores [
    repo: WardrikEcto.Store,
    url: WardrikEcto.Store,
    bucket: WardrikS3.Store,
    data_dir: WardrikStore.EKV
  ]

  @doc """
  Wardrik as `opts` describe it, made without starting anything. Raises
  where an option is not one of those above, or where `:store` is missing.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    opts = Keyword.validate!(opts, [:store, fleet: [], context: context([])] ++ @seams)
    store = Keyword.fetch!(opts, :store)

    host =
      Wardrik.Host.new(
        [
          store: store,
          definitions: %WardrikDefinition.Kept{store: store, contexts: opts[:context]},
          workspace: %WardrikWorkspace.Backend.Store{store: store}
        ] ++ Keyword.take(opts, @seams)
      )

    %__MODULE__{host: host, fleet: opts[:fleet]}
  end

  @doc """
  The store `settings` name, made without starting anything. One of:

    * `repo: MyApp.Repo` - in Postgres, through an Ecto repo the application
      starts before Wardrik, whose table a migration of its own creates with
      `Wardrik.Migration`. `url:` names a database for a repo of the store's
      own instead.
    * `bucket: "wardrik"` - in an S3 bucket, with its `endpoint`, `region`,
      `access_key_id` and `secret_access_key`, under a `prefix`.
    * `data_dir: "/var/lib/my_app/wardrik"` - on each node's disk, for an
      application that adds `{:ekv, "~> 0.4.3"}` to its dependencies.

  `discovery_interval_ms` is how often a node looks for agents no node
  holds. Raises where `settings` name no store, or more than one.

      Wardrik.store(repo: MyApp.Repo)
  """
  @spec store(keyword()) :: WardrikStore.t()
  def store(settings) do
    case Enum.uniq(for {key, store} <- @stores, Keyword.has_key?(settings, key), do: store) do
      [adapter] ->
        WardrikStore.new([adapter: adapter] ++ settings)

      _none_or_several ->
        raise ArgumentError,
              "Wardrik.store/1 names one store, by repo:, url:, bucket: or data_dir:, " <>
                "and #{inspect(settings)} does not"
    end
  end

  @doc """
  What a definition may name, as the fields of `WardrikDefinition.Context`
  in `fields`: the `tools` the application ships, the MCP `servers`, the
  `policies`, and so on. `sources` names `self`, an agent's operations on
  itself, and `agents`, those on the other agents of its org, unless
  given.

      Wardrik.context(tools: [MyApp.Tools.Search])
  """
  @spec context(keyword()) :: Context.t()
  def context(fields) do
    struct!(
      Context,
      Keyword.merge(
        [sources: [self: Wardrik.Catalog.Self, agents: Wardrik.Catalog.Agents]],
        fields
      )
    )
  end

  @doc "The `Wardrik.Host` the agents run on, for a surface started after Wardrik."
  @spec host(t()) :: Wardrik.Host.t()
  def host(%__MODULE__{host: host}), do: host

  @doc """
  The caller `:principal` is to an operation on `:subject`, an agent or the
  agents under a prefix, holding the first grant `:grants` gives them that
  reaches it, or `:not_found` where none does. See `Wardrik.Host.caller/2`.
  """
  @spec caller(t(), keyword()) :: {:ok, Wardrik.Caller.t()} | {:error, Wardrik.Error.t()}
  def caller(%__MODULE__{host: host}, opts), do: Wardrik.Host.caller(host, opts)

  @doc "The child that runs `wardrik`."
  @spec child_spec(t()) :: Supervisor.child_spec()
  def child_spec(%__MODULE__{} = wardrik),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [wardrik]}, type: :supervisor}

  @doc "Starts `wardrik`, as `child_spec/1` does."
  @spec start_link(t()) :: Supervisor.on_start()
  def start_link(%__MODULE__{} = wardrik),
    do: Supervisor.start_link(__MODULE__, wardrik, name: __MODULE__)

  @impl true
  def init(%__MODULE__{host: host, fleet: fleet}) do
    store = Wardrik.Host.store(host)

    children = [
      {WardrikStore, store},
      {Wardrik.Core, host: host, fleet: fleet},
      {WardrikPolicy.Supervisor, store: store},
      {WardrikTrigger, store: store}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
