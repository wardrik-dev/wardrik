defmodule Wardrik do
  @moduledoc """
  The supervisor of everything Wardrik runs. In order:

    * The store's settings, kept where every read and write finds them; see
      `Wardrik.Store.configure/1`.
    * `Wardrik.LLM.Catalog`, `Wardrik.Event.Bus`, `Wardrik.Event.Log`,
      `Wardrik.LLM.ToolRunner`, and `Wardrik.Tasks`.
    * What `:cluster` names, which connects this node to others before the
      fleet starts.
    * `Wardrik.Fleet.Supervisor`, with `:fleet`, which starts the store first.

  Each child depends on the ones before it: an agent joins the bus as it
  starts and writes its log from what the bus delivers, and runs its turns
  under the task supervisor. A child that restarts restarts every child after
  it, so an agent never holds a membership of a bus that is gone. The catalog
  load is a task that exits once done and is not started again.

  The `:wardrik` application starts it by default, with the store and the
  fleet as the application's environment holds them:

      config :wardrik, Wardrik.Store, adapter: Wardrik.Store.EKV, data_dir: "/var/lib/wardrik"
      config :wardrik, Wardrik.Fleet, log: false

  A host that starts it in its own tree instead, after the repo its store is
  kept in, says so, and hands it its options:

      config :wardrik, start: :host

      children = [
        MyApp.Repo,
        {Wardrik, store: [adapter: WardrikEcto.Store, repo: MyApp.Repo]},
        MyAppWeb.Endpoint
      ]

  The application then starts nothing. What runs on the fleet goes after it
  in the host's tree, which starts it once the fleet is up.

  ## Options

    * `:store` - the store's adapter, under `:adapter`, and its options;
      `Wardrik.Store.EKV` with its defaults where none is given. See
      `Wardrik.Store`.
    * `:fleet` - the options of `Wardrik.Fleet.Supervisor`.
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
    opts = Keyword.validate!(opts, cluster: [], store: [], fleet: [])

    children =
      [
        %{id: {Wardrik.Store, :settings}, start: {Wardrik.Store, :configure, [opts[:store]]}},
        Wardrik.LLM.Catalog,
        Wardrik.Event.Bus,
        Wardrik.Event.Log,
        Wardrik.LLM.ToolRunner,
        Wardrik.Tasks
      ] ++
        opts[:cluster] ++
        [{Wardrik.Fleet.Supervisor, Keyword.put(opts[:fleet], :store, opts[:store])}]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
