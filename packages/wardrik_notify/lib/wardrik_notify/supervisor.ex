defmodule WardrikNotify.Supervisor do
  @moduledoc """
  Runs `WardrikNotify`: the tasks deliveries run in, `WardrikNotify.Dispatcher`,
  and a `WardrikNotify.Slack.Socket` for each app-level token a Slack target
  holds. The daemon starts it when `config.yaml` names a target.

      {WardrikNotify.Supervisor,
       targets: [audit: {WardrikNotify.Webhook, url: "https://hooks.example.com/wardrik"}]}

  Options:

    * `:targets` - each target by name, with the module that delivers to it
      and its options; see `WardrikNotify`. None by default.
    * `:req_options` - merged into every HTTP request a target makes, unless
      the target sets its own: the seam a test routes them through.
    * `:routes` - where the dispatcher finds its routes as it starts, and
      `:backoff` how long it waits before trying a failed delivery again, in
      milliseconds; see `WardrikNotify.Dispatcher`.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    opts = Keyword.validate!(opts, [:routes, :backoff, targets: [], req_options: []])

    sockets =
      for token <- WardrikNotify.Slack.app_tokens(opts[:targets]),
          do:
            {WardrikNotify.Slack.Socket,
             [app_token: token] ++ Keyword.take(opts, [:targets, :req_options])}

    children =
      [
        {Task.Supervisor, name: WardrikNotify.TaskSupervisor},
        {WardrikNotify.Dispatcher, opts}
      ] ++ sockets

    Supervisor.init(children, strategy: :one_for_one)
  end
end
