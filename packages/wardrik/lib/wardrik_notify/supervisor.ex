defmodule WardrikNotify.Supervisor do
  @moduledoc """
  Runs `WardrikNotify`: the tasks deliveries run in, and
  `WardrikNotify.Dispatcher`. `WardrikNotify.attach/2` makes it a child of
  the host, which `Wardrik` starts:

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
    * `:host` - the `Wardrik.Host` it was attached to, as `Wardrik` starts
      it; `WardrikNotify.attach/2` has read its routes from it
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    opts = Keyword.validate!(opts, [:routes, :backoff, :host, targets: [], req_options: []])

    children = [
      {Task.Supervisor, name: WardrikNotify.TaskSupervisor},
      {WardrikNotify.Dispatcher, Keyword.delete(opts, :host)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
