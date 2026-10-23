defmodule Wardrik do
  @moduledoc """
  Agents your app runs, and the operations people and programs reach them through.

      wardrik = Wardrik.new(name: MyApp.Wardrik, store: store, deployment: "acme-prod")

      children = [{WardrikStore, store}, {Wardrik, wardrik}]

      scope = Wardrik.as(wardrik, principal, statements)
  """

  use Supervisor

  alias Wardrik.Catalog
  alias Wardrik.Error
  alias Wardrik.Runner
  alias Wardrik.Scope
  alias WardrikCore.Principal

  @enforce_keys [:name, :store, :deployment, :authorizer, :retention, :backend, :catalog]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          name: atom(),
          store: WardrikStore.t(),
          deployment: String.t(),
          authorizer: {module(), term()},
          retention: pos_integer() | :infinity,
          backend: {module(), keyword()},
          catalog: Catalog.t()
        }

  @doc """
  Describes a Wardrik. Takes `:name`, `:store`, `:deployment` (`"local"` unless set), `:authorizer`,
  a `Wardrik.Authorizer` as `{module, config}` (`Wardrik.Statements` unless set), `:retention`, the
  days events are kept (30 unless set), and `:backend`, where agents are kept (the store unless set).
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    opts =
      Keyword.validate!(opts, [
        :name,
        :store,
        :backend,
        deployment: "local",
        authorizer: {Wardrik.Statements, []},
        retention: 30
      ])

    store = Keyword.fetch!(opts, :store)

    %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      store: store,
      deployment: opts[:deployment],
      authorizer: opts[:authorizer],
      retention: opts[:retention],
      backend: opts[:backend] || {WardrikStore.Durable, store: store},
      catalog: Catalog.new()
    }
  end

  @doc "Starts what `wardrik` runs: its agents, and their events."
  @spec start_link(t()) :: Supervisor.on_start()
  def start_link(%__MODULE__{name: name} = wardrik),
    do: Supervisor.start_link(__MODULE__, wardrik, name: name)

  @doc "Returns the scope `principal` acts in, allowed what `grants` say to the authorizer."
  @spec as(t(), Principal.t(), term()) :: Scope.t()
  def as(%__MODULE__{} = wardrik, %Principal{} = principal, grants \\ []),
    do: %Scope{wardrik: wardrik, principal: principal, grants: grants}

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
  to `wardrik`'s.
  """
  @spec start_agent(t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_agent(%__MODULE__{} = wardrik, opts),
    do:
      WardrikCore.start_agent(
        agents(wardrik),
        Keyword.put(opts, :events, {WardrikEvents, events(wardrik)})
      )

  @doc "Returns the name of `wardrik`'s `WardrikCore` instance."
  @spec agents(t()) :: atom()
  def agents(%__MODULE__{name: name}), do: Module.concat(name, Agents)

  @doc "Returns the name of `wardrik`'s `WardrikEvents`."
  @spec events(t()) :: atom()
  def events(%__MODULE__{name: name}), do: Module.concat(name, Events)

  @impl Supervisor
  def init(wardrik) do
    children = [
      {WardrikEvents,
       name: events(wardrik),
       store: wardrik.store,
       deployment: wardrik.deployment,
       retention: wardrik.retention},
      {WardrikCore, name: agents(wardrik), backend: wardrik.backend}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
