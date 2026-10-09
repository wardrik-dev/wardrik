defmodule WardrikChannel.Supervisor do
  @moduledoc """
  Runs each channel: the tasks channels run their work under, then what each
  channel's adapter runs, such as its connection to the medium. Each channel
  is written down where `WardrikChannel.channel/1` finds it by its name as it
  starts. `WardrikChannel.Replies`, which posts in the channels' threads, is
  started before it:

      children = [Wardrik, WardrikChannel.Replies, {WardrikChannel.Supervisor, opts}]

      {WardrikChannel.Supervisor,
       channels: [slack: {WardrikSlack, token: "xoxb-…", app_token: "xapp-…"}]}

  Options:

    * `:channels` - each channel by name, as its adapter and the options its
      `config/1` answered; each is started with `:name` and `:context`, its
      `WardrikChannel.Context`, added
    * `:offered`, `:creatable`, `:create`, `:start` and `:approvers` - the
      host's answers to which agents may answer in a channel's rooms, to
      creating one, to starting a thread's agent, and to who may answer what
      an agent asks there, as `WardrikChannel.Context` takes them; none, and
      none created or started, by default
  """

  alias WardrikChannel.Context

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    opts =
      Keyword.validate!(opts,
        channels: [],
        offered: {Context, :none, []},
        creatable: {Context, :no, []},
        create: {Context, :refuse, []},
        start: {Context, :unstarted, []},
        approvers: {Context, :none, []}
      )

    channels =
      for {name, {adapter, channel}} <- opts[:channels] do
        context = %Context{
          channel: to_string(name),
          offered: opts[:offered],
          creatable: opts[:creatable],
          create: opts[:create],
          start: opts[:start],
          approvers: opts[:approvers]
        }

        :ok = WardrikChannel.put_channel(adapter, channel, context)
        spec = adapter.child_spec([name: name, context: context] ++ channel)
        Supervisor.child_spec(spec, id: {:channel, name})
      end

    Supervisor.init([{Task.Supervisor, name: WardrikChannel.tasks()} | channels],
      strategy: :one_for_one
    )
  end
end
