defmodule WardrikChannel.Supervisor do
  @moduledoc """
  Runs each channel: the tasks channels run their work under, then what each
  channel's adapter runs, such as its connection to the medium.
  `WardrikChannel.Replies`, which posts in the channels' threads, is started
  before it, with the same settings, as `WardrikChannel.attach/2` has them:

      settings = [channels: [slack: {WardrikSlack, app_token: "xapp-…"}], installations: installations]

      children = [
        {Wardrik.Core, host: host},
        {WardrikChannel.Replies, host: host, settings: settings},
        {WardrikChannel.Supervisor, host: host, settings: settings}
      ]

  Options:

    * `:host` - the `Wardrik.Host` it runs the channels on; required
    * `:settings` - the channels to run, as `WardrikChannel.attach/2` takes
      them, which it makes on the host with `WardrikChannel.channels/2`;
      each adapter's `child_spec/1` is given the channel's options, its
      `:name` and its `:context`
    * `:replies` - the `WardrikChannel.Replies` that posts in their threads,
      `WardrikChannel.Replies.supervisor/0` unless given
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    opts = Keyword.validate!(opts, [:host, :replies, settings: []])
    made = WardrikChannel.channels(opts[:settings], Keyword.take(opts, [:host, :replies]))

    channels =
      for {name, %WardrikChannel.Channel{} = channel} <- made do
        spec = channel.adapter.child_spec(WardrikChannel.Channel.options(channel))
        Supervisor.child_spec(spec, id: {:channel, name})
      end

    Supervisor.init([{Task.Supervisor, name: WardrikChannel.tasks()} | channels],
      strategy: :one_for_one
    )
  end
end
