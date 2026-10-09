defmodule WardrikChannel.Supervisor do
  @moduledoc """
  Runs each channel: the tasks channels run their work under, then what each
  channel's adapter runs, such as its connection to the medium.

      {WardrikChannel.Supervisor,
       channels: [slack: {WardrikSlack, token: "xoxb-…", app_token: "xapp-…"}]}

  Options:

    * `:channels` - each channel by name, as its adapter and the options its
      `config/1` answered; each is started with `:name` added
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    opts = Keyword.validate!(opts, channels: [])

    channels =
      for {name, {adapter, channel}} <- opts[:channels],
          do:
            Supervisor.child_spec(adapter.child_spec([name: name] ++ channel),
              id: {:channel, name}
            )

    Supervisor.init([{Task.Supervisor, name: WardrikChannel.tasks()} | channels],
      strategy: :one_for_one
    )
  end
end
