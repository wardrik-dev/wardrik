defmodule WardrikNotify.Supervisor do
  @moduledoc """
  Runs `WardrikNotify`: the tasks deliveries run in, `WardrikNotify.Dispatcher`,
  and a `WardrikNotify.Slack.Socket` for each app-level token a Slack target
  holds. The daemon starts it when `config.yaml` names a target.

  `:routes` is where the dispatcher finds its routes as it starts; see
  `WardrikNotify.Dispatcher`.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    opts = Keyword.validate!(opts, routes: nil)

    sockets =
      for token <- WardrikNotify.Slack.app_tokens(),
          do: {WardrikNotify.Slack.Socket, app_token: token}

    children =
      [
        {Task.Supervisor, name: WardrikNotify.TaskSupervisor},
        {WardrikNotify.Dispatcher, routes: opts[:routes]}
      ] ++ sockets

    Supervisor.init(children, strategy: :one_for_one)
  end
end
