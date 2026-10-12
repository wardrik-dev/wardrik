defmodule Wardrik do
  @moduledoc """
  The supervisor of everything Wardrik runs. In order:

    * The store's settings, kept where every read and write finds them; see
      `WardrikStore.configure/1`, and the host's definitions module, kept where
      every operation finds it; see `Wardrik.Definition.configure/1`.
    * `Wardrik.LLM.Catalog`, `Wardrik.Event.Bus`, `Wardrik.Event.Log`,
      `Wardrik.Audit`, `Wardrik.LLM.ToolRunner`, and `Wardrik.Tasks`.
    * What `:cluster` names, which connects this node to others before the
      fleet starts.
    * `Wardrik.Fleet.Supervisor`, with `:fleet`, which starts the store first.

  Each child depends on the ones before it: an agent joins the bus as it
  starts and writes its log from what the bus delivers, and runs its turns
  under the task supervisor. A child that restarts restarts every child after
  it, so an agent never holds a membership of a bus that is gone. The catalog
  load is a task that exits once done and is not started again.

  The `:wardrik` application starts it by default, with the store, the fleet
  and the definitions module as the application's environment holds them:

      config :wardrik, WardrikStore, adapter: WardrikStore.EKV, data_dir: "/var/lib/wardrik"
      config :wardrik, Wardrik.Fleet, log: false
      config :wardrik, definitions: MyApp.Definitions

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
      `WardrikStore.EKV` with its defaults where none is given. See
      `WardrikStore`.
    * `:fleet` - the options of `Wardrik.Fleet.Supervisor`.
    * `:definitions` - the `Wardrik.Definition` that agents' definitions go
      to, whichever surface they come from. None by default, where no
      operation defines an agent.
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
    opts = Keyword.validate!(opts, cluster: [], store: [], fleet: [], definitions: nil)

    children =
      [
        %{id: {WardrikStore, :settings}, start: {WardrikStore, :configure, [opts[:store]]}},
        %{
          id: {Wardrik.Definition, :module},
          start: {Wardrik.Definition, :configure, [opts[:definitions]]}
        },
        Wardrik.LLM.Catalog,
        Wardrik.Event.Bus,
        Wardrik.Event.Log,
        Wardrik.Audit,
        Wardrik.LLM.ToolRunner,
        Wardrik.Tasks
      ] ++
        opts[:cluster] ++
        [{Wardrik.Fleet.Supervisor, Keyword.put(opts[:fleet], :store, opts[:store])}]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
