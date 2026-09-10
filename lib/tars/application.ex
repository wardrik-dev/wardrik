defmodule Tars.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Tars.Event.Bus,
      {Task.Supervisor, name: Tars.TaskSupervisor},
      {Tars.Agent.Supervisor, []}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Tars.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
