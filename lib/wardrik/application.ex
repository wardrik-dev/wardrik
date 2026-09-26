defmodule Wardrik.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Wardrik.LLM.Catalog,
        Wardrik.Event.Bus,
        Wardrik.Event.Log,
        Wardrik.LLM.ToolRunner,
        {Task.Supervisor, name: Wardrik.TaskSupervisor}
      ] ++
        Application.get_env(:wardrik, :cluster, []) ++
        [
          {Wardrik.Fleet.Supervisor, Application.get_env(:wardrik, Wardrik.Fleet, [])},
          Wardrik.Access
        ] ++
        Application.get_env(:wardrik, :children, [])

    Supervisor.start_link(children, strategy: :one_for_one, name: Wardrik.Supervisor)
  end
end
