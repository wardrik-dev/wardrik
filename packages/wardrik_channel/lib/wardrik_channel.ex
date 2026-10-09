defmodule WardrikChannel do
  @moduledoc """
  A chat medium Wardrik's agents are reached through, such as Slack: the
  behaviour each one's adapter implements, and how the adapters a release
  holds are found.

  A *channel* is one configured instance of an adapter, under a name of the
  deployment's own: one Slack workspace's app, say, with its tokens. A *room*
  is a place in it, such as a Slack channel.

      channels:
        slack:
          type: slack
          token: ${SLACK_BOT_TOKEN}
          app_token: ${SLACK_APP_TOKEN}
        globex-slack:
          type: slack
          org: globex
          token: ${GLOBEX_SLACK_BOT_TOKEN}

  ## Adapters

  An adapter is a module implementing this behaviour, in a package of its
  own. It names itself in its application's environment, under
  `:wardrik_channels`, so whatever starts channels finds it by its type
  without naming it:

      # mix.exs of wardrik_slack
      def application,
        do: [env: [wardrik_channels: [slack: WardrikSlack]]]

  `adapters/0` lists the types the loaded applications name, and `adapter/1`
  finds one.

  ## What an adapter does

    * `config/1` reads a channel's settings, as `config.yaml` writes them
      with `type` and `org` taken out, and answers the options its other
      callbacks take, or where they do not read.
    * `child_spec/1` is what a channel runs, such as its connection to the
      medium, started by `WardrikChannel.Supervisor` with the channel's
      options, its `:name`, and its `WardrikChannel.Context`.
    * `deliver/2` posts a `WardrikChannel.Outbound` in a room.

  ## Rooms

  An adapter tells `WardrikChannel.Rooms` when its bot is invited into a
  room or taken out of one, and what was chosen there, handing it the
  channel's context. See `WardrikChannel.Rooms` for how a room comes to have
  an agent.

  ## Threads

  An adapter hands each message posted in a room to `received/2`. Each
  thread in a room is a conversation of its own with the room's agent: an
  agent under the room's agent's ID, answering for the room and the thread,
  so every thread runs on one definition and no two rooms share one. A
  message posted in the room itself starts a thread where it mentions the
  bot, or where the room's agent answers everything; a reply in a thread
  reaches its agent where that thread has one already, or mentions the bot,
  or the room's agent answers everything. What the agent answers is posted
  in the thread by `WardrikChannel.Replies`.

  `WardrikChannel.Notices` is a `WardrikNotify` target that posts notices in
  a room through a channel's adapter.
  """

  alias Wardrik.AgentID
  alias WardrikChannel.Context
  alias WardrikChannel.Inbound
  alias WardrikChannel.Outbound
  alias WardrikChannel.Replies
  alias WardrikChannel.Room
  alias WardrikChannel.Rooms

  @typedoc "A channel: its adapter, and the options its `config/1` answered."
  @type channel() :: {module(), keyword()}

  @doc """
  Reads a channel's settings, as `config.yaml` writes them, less `type` and
  `org`. Answers the options its callbacks take, or the key that does not
  read, as a path within the channel, and why.
  """
  @callback config(settings :: map()) :: {:ok, keyword()} | {:error, [String.t()], String.t()}

  @doc "What the channel runs, given its options, its `:name` and its `:context`."
  @callback child_spec(keyword()) :: Supervisor.child_spec()

  @doc "Posts `outbound` in its room, as the channel whose options these are."
  @callback deliver(Outbound.t(), keyword()) :: {:ok, term()} | {:error, term()}

  @doc "Every adapter the loaded applications name, by its type."
  @spec adapters() :: %{String.t() => module()}
  def adapters do
    for {app, _description, _version} <- Application.loaded_applications(),
        {type, module} <- Application.get_env(app, :wardrik_channels, []),
        into: %{},
        do: {to_string(type), module}
  end

  @doc "The adapter of `type`, where a loaded application names one."
  @spec adapter(String.t()) :: {:ok, module()} | :error
  def adapter(type) when is_binary(type), do: Map.fetch(adapters(), type)

  @doc "The task supervisor a channel runs its work under."
  @spec tasks() :: atom()
  def tasks, do: WardrikChannel.TaskSupervisor

  @doc """
  A message was posted in a room of the context's channel: asks the agent of
  its thread, starting it where it is not running, and has
  `WardrikChannel.Replies` post what it answers. Answers the agent asked, or
  `:ignored` for a message in a room no agent answers in, or one the room's
  agent does not answer.
  """
  @spec received(Context.t(), Inbound.t()) ::
          {:asked, AgentID.t()} | :ignored | {:error, String.t()}
  def received(%Context{} = context, %Inbound{} = inbound) do
    thread = inbound.thread || inbound.id

    with %Room{} = room <- Rooms.get(context, inbound.room),
         agent = conversation(room, thread),
         true <- answers?(room, inbound, agent) do
      ask(context, inbound, thread, agent)
    else
      _unanswered -> :ignored
    end
  end

  defp ask(context, inbound, thread, agent) do
    with {:ok, _pid} <- Context.start(context, agent),
         :ok <- Replies.follow(context.channel, inbound.room, thread, agent),
         :ok <- Wardrik.Agent.ask(agent, inbound.text, id: inbound.id, sender: inbound.sender) do
      {:asked, agent}
    else
      {:error, :not_found} -> {:error, "#{agent} stopped before it could be asked."}
      {:error, message} -> {:error, message}
    end
  end

  @doc "The agent that answers in `thread` of the room `room` is bound as."
  @spec conversation(Room.t(), String.t()) :: AgentID.t()
  def conversation(%Room{room: room, agent: agent}, thread),
    do: AgentID.put_external_id(agent, room <> "-" <> thread)

  defp answers?(_room, %Inbound{mentioned?: true}, _agent), do: true
  defp answers?(%Room{answers: :everything}, _inbound, _agent), do: true
  defp answers?(_room, %Inbound{thread: nil}, _agent), do: false
  defp answers?(_room, _inbound, agent), do: Wardrik.Fleet.stored?(agent)

  @doc """
  The channel named `name` among those `WardrikChannel.Supervisor` runs on
  this node: its adapter, the options its `config/1` answered, and its
  `WardrikChannel.Context`.
  """
  @spec channel(String.t()) :: {:ok, {module(), keyword(), Context.t()}} | :error
  def channel(name) when is_binary(name) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      nil -> :error
      channel -> {:ok, channel}
    end
  end

  @doc false
  @spec put_channel(module(), keyword(), Context.t()) :: :ok
  def put_channel(adapter, options, %Context{channel: name} = context),
    do: :persistent_term.put({__MODULE__, name}, {adapter, options, context})
end
