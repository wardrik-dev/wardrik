defmodule Tars.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Tars.LLM.Catalog,
        Tars.Event.Bus,
        Tars.LLM.ToolRunner,
        {Task.Supervisor, name: Tars.TaskSupervisor},
        {Tars.Fleet.Supervisor, Application.get_env(:tars, Tars.Fleet, [])}
      ] ++ Application.get_env(:tars, :children, [])

    Supervisor.start_link(children, strategy: :one_for_one, name: Tars.Supervisor)
  end
end
