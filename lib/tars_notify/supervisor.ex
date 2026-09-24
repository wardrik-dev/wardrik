defmodule TarsNotify.Supervisor do
  @moduledoc """
  Runs `TarsNotify`: the tasks deliveries run in, `TarsNotify.Dispatcher`,
  and a `TarsNotify.Slack.Socket` for each app-level token a Slack target
  holds. The daemon starts it when `config.yaml` names a target.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    sockets =
      for token <- TarsNotify.Slack.app_tokens(), do: {TarsNotify.Slack.Socket, app_token: token}

    children =
      [{Task.Supervisor, name: TarsNotify.TaskSupervisor}, TarsNotify.Dispatcher] ++ sockets

    Supervisor.init(children, strategy: :one_for_one)
  end
end
