defmodule Wardrik do
  @moduledoc """
  The supervisor of everything Wardrik runs. In order:

    * `Wardrik.LLM.Catalog`, `Wardrik.Event.Bus`, `Wardrik.Event.Log`,
      `Wardrik.LLM.ToolRunner`, and `Wardrik.TaskSupervisor`.
    * What `:cluster` names, which connects this node to others before the
      fleet starts.
    * `Wardrik.Fleet.Supervisor`, with `config :wardrik, Wardrik.Fleet`, which
      starts the store first.

  The `:wardrik` application starts it by default. A host that starts it in
  its own tree instead, after the repo its store is kept in, says so:

      config :wardrik, start: :host
      config :wardrik, Wardrik.Store, adapter: WardrikEcto.Store, repo: MyApp.Repo

      children = [MyApp.Repo, Wardrik, MyAppWeb.Endpoint]

  The application then starts nothing, and `Wardrik` reads the same
  configuration when the host's supervisor starts it. What runs on the fleet
  goes after it in the host's tree, which starts it once the fleet is up.

  ## Options

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
    opts = Keyword.validate!(opts, cluster: [])

    children =
      [
        Wardrik.LLM.Catalog,
        Wardrik.Event.Bus,
        Wardrik.Event.Log,
        Wardrik.LLM.ToolRunner,
        {Task.Supervisor, name: Wardrik.TaskSupervisor}
      ] ++
        opts[:cluster] ++
        [{Wardrik.Fleet.Supervisor, Application.get_env(:wardrik, Wardrik.Fleet, [])}]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
