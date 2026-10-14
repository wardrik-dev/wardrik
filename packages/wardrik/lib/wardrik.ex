defmodule Wardrik do
  @moduledoc """
  Everything Wardrik runs, under one supervisor, kept in the store the host
  started before it. In order:

    * `Wardrik.LLM.Catalog`, `Wardrik.Event.Bus`, `Wardrik.Event.Log`,
      `Wardrik.Audit`, which writes to the host's store,
      `Wardrik.LLM.ToolRunner`, and `Wardrik.Tasks`.
    * What `:cluster` names, which connects this node to others before the
      fleet starts.
    * `Wardrik.Fleet.Supervisor`, with `:fleet` and `:host`, which keeps the
      fleet in the host's store, and hands every agent the host as it
      starts.

  Each child depends on the ones before it: an agent joins the bus as it
  starts and writes its log from what the bus delivers, and runs its turns
  under the task supervisor. A child that restarts restarts every child after
  it, so an agent never holds a membership of a bus that is gone. The catalog
  load is a task that exits once done and is not started again.

  The `:wardrik` application starts it by default, after the store, with the
  store, the fleet and the host's seams as the application's environment
  holds them:

      config :wardrik, WardrikStore, adapter: WardrikStore.EKV, data_dir: "/var/lib/wardrik"
      config :wardrik, Wardrik.Fleet, log: false
      config :wardrik, Wardrik.Host,
        definitions: {MyApp.Definitions, []},
        grants: {MyApp.Grants, admins: ["maria"]}

  Each seam is named by its module and the fields of its struct, as
  `Wardrik.Host.configured/1` reads them.

  A host that starts it in its own tree instead, after the repo its store is
  kept in, says so, and hands it its options, and the same `Wardrik.Host` to
  each surface it starts after it:

      config :wardrik, start: :host

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
        {MyAppWeb.Endpoint, host: host}
      ]

  The application then starts nothing. What runs on the fleet goes after it
  in the host's tree, which starts it once the fleet is up.

  Nothing of the host, its store included, is kept where a node finds it:
  it travels in the options of what is started with it, and in each
  `Wardrik.Caller`, so two instances on one node each answer with their own.

  ## Options

    * `:fleet` - the options of `Wardrik.Fleet.Supervisor`.
    * `:host` - the `Wardrik.Host` every agent is handed as it starts, for
      the store it keeps its state in, the definition it runs on and the
      operations its tools call. Required.
    * `:cluster` - the children that connect this node to others, started
      before the fleet. None by default.

          {Wardrik, cluster: [WardrikDaemon.Cluster, WardrikDaemon.Cluster.Quorum]}
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []),
    do: Supervisor.start_link(__MODULE__, opts, name: Wardrik.Supervisor)

  @impl true
  def init(opts) do
    opts = Keyword.validate!(opts, [:host, cluster: [], fleet: []])
    host = Keyword.fetch!(opts, :host)

    children =
      [
        Wardrik.LLM.Catalog,
        Wardrik.Event.Bus,
        Wardrik.Event.Log,
        {Wardrik.Audit, store: Wardrik.Host.store(host), name: Wardrik.Host.audit(host)},
        Wardrik.LLM.ToolRunner,
        Wardrik.Tasks
      ] ++
        opts[:cluster] ++
        [{Wardrik.Fleet.Supervisor, Keyword.put(opts[:fleet], :host, host)}]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
