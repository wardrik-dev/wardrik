defmodule Wardrik.Core do
  @moduledoc """
  Everything core runs, under one supervisor, kept in the store started
  before it. In order:

    * `Wardrik.LLM.Catalog`, `Wardrik.Event.Bus`, `Wardrik.Event.Log`,
      `Wardrik.Credential`, which tells a call parked on a credential it is
      available, `Wardrik.Audit`, which writes to the host's store,
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

  An application embedding Wardrik starts `Wardrik`, of the `wardrik`
  package, which starts this after the store and the packages around it. A
  host that puts its own tree together, as the daemon does, starts it after
  the store, and hands the same `Wardrik.Host` to each surface it starts
  after it:

      children = [
        {WardrikStore, store},
        {Wardrik.Core, host: host},
        {MyApp.Endpoint, host: host}
      ]

  Nothing of the host, its store included, is kept where a node finds it:
  it travels in the options of what is started with it, and in each scope
  a surface acts in.

  A node runs one: core's own processes, as the event bus, the event log and
  the tool runner, are registered under their module names. To run several
  on one machine, run several nodes.

  As it starts, it loads every module of core, of the store, and of each
  application depending on either. The store reads what it keeps back
  without making atoms, and an agent's kept state names the fields of their
  structs, which a node loading code as it is first called, as in dev and
  tests, has not made yet. A release has loaded them all as it booted.

  ## Options

    * `:fleet` - the options of `Wardrik.Fleet.Supervisor`.
    * `:host` - the `Wardrik.Host` every agent is handed as it starts, for
      the store it keeps its state in, the definition it runs on and the
      operations its tools call. Required.
    * `:cluster` - the children that connect this node to others, started
      before the fleet. None by default.

          {Wardrik.Core, cluster: [WardrikDaemon.Cluster, WardrikDaemon.Cluster.Quorum]}
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    opts = Keyword.validate!(opts, [:host, cluster: [], fleet: []])
    host = Keyword.fetch!(opts, :host)
    :ok = load_kept()

    children =
      [
        Wardrik.LLM.Catalog,
        Wardrik.Event.Bus,
        Wardrik.Event.Log,
        Wardrik.Credential,
        {Wardrik.Audit, store: Wardrik.Host.store(host), name: Wardrik.Host.audit(host)},
        Wardrik.LLM.ToolRunner,
        Wardrik.Tasks
      ] ++
        opts[:cluster] ++
        [{Wardrik.Fleet.Supervisor, Keyword.put(opts[:fleet], :host, host)}]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @kept [:wardrik_core]

  defp load_kept do
    for {app, _description, _vsn} <- Application.loaded_applications(),
        app in @kept or
          Enum.any?(Application.spec(app, :applications), &(&1 in @kept)),
        do: app |> Application.spec(:modules) |> Code.ensure_all_loaded()

    :ok
  end
end
