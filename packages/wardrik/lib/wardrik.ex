defmodule Wardrik do
  @moduledoc """
  The supervisor of everything Wardrik runs. In order:

    * `Wardrik.LLM.Catalog`, `Wardrik.Event.Bus`, `Wardrik.Event.Log`,
      `Wardrik.LLM.ToolRunner`, and `Wardrik.TaskSupervisor`.
    * What `config :wardrik, :cluster` names, which connects this node to
      others before the fleet starts.
    * `Wardrik.Fleet.Supervisor`, with `config :wardrik, Wardrik.Fleet`, which
      starts the store first.
    * What `config :wardrik, :children` names, once the fleet is up.

  The `:wardrik` application starts it by default. A host that starts it in
  its own tree instead, after the repo its store is kept in, says so:

      config :wardrik, start: :host
      config :wardrik, Wardrik.Store, adapter: WardrikEcto.Store, repo: MyApp.Repo

      children = [MyApp.Repo, Wardrik, MyAppWeb.Endpoint]

  The application then starts nothing, and `Wardrik` reads the same
  configuration when the host's supervisor starts it.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(_opts \\ []), do: Supervisor.start_link(__MODULE__, [], name: Wardrik.Supervisor)

  @impl true
  def init([]) do
    children =
      [
        Wardrik.LLM.Catalog,
        Wardrik.Event.Bus,
        Wardrik.Event.Log,
        Wardrik.LLM.ToolRunner,
        {Task.Supervisor, name: Wardrik.TaskSupervisor}
      ] ++
        Application.get_env(:wardrik, :cluster, []) ++
        [{Wardrik.Fleet.Supervisor, Application.get_env(:wardrik, Wardrik.Fleet, [])}] ++
        Application.get_env(:wardrik, :children, [])

    Supervisor.init(children, strategy: :one_for_one)
  end
end
