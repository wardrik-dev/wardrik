defmodule WardrikChannel.Supervisor do
  @moduledoc """
  Runs each channel: the tasks channels run their work under, then what each
  channel's adapter runs, such as its connection to the medium.
  `WardrikChannel.Replies`, which posts in the channels' threads, is started
  before it, with the same channels:

      channels =
        WardrikChannel.channels(
          [slack: {WardrikSlack, token: "xoxb-…", app_token: "xapp-…"}],
          host: host
        )

      children = [
        {Wardrik.Core, host: host},
        {WardrikChannel.Replies, channels: channels},
        {WardrikChannel.Supervisor, channels: channels}
      ]

  Options:

    * `:channels` - the channels to run, as `WardrikChannel.channels/2`
      makes them; each adapter's `child_spec/1` is given the channel's
      options, its `:name` and its `:context`
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    opts = Keyword.validate!(opts, [:channels])

    channels =
      for {name, {adapter, options, context}} <- Keyword.fetch!(opts, :channels) do
        spec = adapter.child_spec([name: name, context: context] ++ options)
        Supervisor.child_spec(spec, id: {:channel, name})
      end

    Supervisor.init([{Task.Supervisor, name: WardrikChannel.tasks()} | channels],
      strategy: :one_for_one
    )
  end
end
