defmodule Tars.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    fleet = fleet()
    Tars.Event.Bus.put_transport(if fleet == [], do: :local, else: :cluster)

    children =
      [
        Tars.Event.Bus,
        Tars.LLM.ToolRunner,
        {Task.Supervisor, name: Tars.TaskSupervisor}
      ] ++ fleet

    Supervisor.start_link(children, strategy: :one_for_one, name: Tars.Supervisor)
  end

  # Set `enabled?: false` to run without durable agents and without a cluster.
  # `Tars.Event.Bus` then delivers to this node only.
  defp fleet do
    opts = Application.get_env(:tars, Tars.Fleet, [])

    if Keyword.get(opts, :enabled?, true), do: [{Tars.Fleet.Supervisor, opts}], else: []
  end
end
