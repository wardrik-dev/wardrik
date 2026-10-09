defmodule WardrikChannel.Supervisor do
  @moduledoc """
  Runs each channel: the tasks channels run their work under, then what each
  channel's adapter runs, such as its connection to the medium.

      {WardrikChannel.Supervisor,
       channels: [slack: {WardrikSlack, token: "xoxb-…", app_token: "xapp-…"}]}

  Options:

    * `:channels` - each channel by name, as its adapter and the options its
      `config/1` answered; each is started with `:name` and `:context`, its
      `WardrikChannel.Context`, added
    * `:offered`, `:creatable` and `:create` - the host's answers to which
      agents may answer in a channel's rooms, and to creating one, as
      `WardrikChannel.Context` takes them; none, and none created, by
      default
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
        create: {Context, :refuse, []}
      )

    channels =
      for {name, {adapter, channel}} <- opts[:channels] do
        context = %Context{
          channel: to_string(name),
          offered: opts[:offered],
          creatable: opts[:creatable],
          create: opts[:create]
        }

        spec = adapter.child_spec([name: name, context: context] ++ channel)
        Supervisor.child_spec(spec, id: {:channel, name})
      end

    Supervisor.init([{Task.Supervisor, name: WardrikChannel.tasks()} | channels],
      strategy: :one_for_one
    )
  end
end
