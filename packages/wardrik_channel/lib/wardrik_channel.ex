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
          signing_secret: ${SLACK_SIGNING_SECRET}
        globex-slack:
          type: slack
          org: globex
          token: ${GLOBEX_SLACK_BOT_TOKEN}

  ## Workspaces

  A channel is installed in workspaces, such as the Slack workspaces a
  Slack app was added to. Each is a `WardrikChannel.Installation`, owned by
  whom it was installed for, holding the token the channel acts there with,
  and kept where the host keeps such secrets, as its
  `WardrikChannel.Installations` say. A channel whose config names a
  `token` is installed in the one workspace that token reaches,
  `WardrikChannel.Installations.Config`. A host that serves many owners
  installs one app in each of their workspaces: it sends someone to
  `install_url/3` for their own, and hands the medium's answer to
  `install/3`.

  Everything an adapter hears is of one workspace, and it acts there
  through a `WardrikChannel.Workspace`: rooms, threads and people are
  each of their workspace.

  ## Adapters

  An adapter is a module implementing this behaviour, in a package of its
  own. It names itself in its application's environment, under
  `:wardrik_channels`, so whatever starts channels finds it by its type
  without naming it:

      # mix.exs of wardrik_slack
      def application,
        do: [env: [wardrik_channels: [slack: WardrikSlack]]]

  `discover/0` lists the types the loaded applications name, which a host
  reads once, as it starts.

  ## What an adapter does

    * `config/1` reads a channel's settings, as `config.yaml` writes them
      less the keys every channel takes, and answers the options its other
      callbacks take, or where they do not read.
    * `child_spec/1` is what a channel runs, such as its connection to the
      medium, started by `WardrikChannel.Supervisor` with the channel's
      options, its `:name`, and its `WardrikChannel.Context`.
    * `deliver/2` posts a `WardrikChannel.Outbound` in a room.
    * `include?/3` says whether names `config.yaml` gives, as `approvers`
      name people, include someone it knows, in its own terms.
    * `request/2` answers what the medium sends over HTTP, such as the
      events of every workspace it is installed in.
    * `install_url/2` is where someone is sent to install it in a
      workspace of theirs, and `install/3` answers the medium sending them
      back, installing it.

  ## HTTP

  A host serves each channel's requests where the medium sends them, such
  as under `/channels/slack/`, without reading them: it hands each to
  `request/2` with the channel, and sends back the `WardrikChannel.Response`
  it answers. What the medium sends is checked by the adapter, by whatever
  proof it carries, such as a signature over the body; so the body is
  handed over as it was sent.

      response =
        WardrikChannel.request(channels["slack"], %{
          method: "POST",
          path: ["events"],
          headers: conn.req_headers,
          body: raw_body
        })

  Installing is the host's to authorize: it serves `install/3` only to
  someone signed in, for the owner they act for, and the adapter refuses
  an answer to an install started for another.

  ## People

  Someone writing in a room, or pressing a button, is the
  `Wardrik.Principal` `principal/2` makes of them, a `WardrikChannel.Member`
  of their workspace, and may do
  what the host's
  `Wardrik.Grants` says that principal may, such as message the agent a
  room answers with, or decide what an agent asks: `Wardrik.Host.caller/2`,
  on the host its context carries, finds them a grant, and they act through
  `Wardrik` as a `Wardrik.Session` holding it. A host whose grants
  give someone nothing has every room ignore what they post, saying why. A
  host that grants by what `config.yaml` names people, as a channel's
  approvers, asks `include?/3` with the channel's adapter and options, and
  `WardrikChannel.Approvers` whether they decide.

  ## Starting channels

  `channels/2` makes, once, what each configured channel runs on, a
  `WardrikChannel.Channel` by its name. The host hands the same map to
  `WardrikChannel.Replies` and to `WardrikChannel.Supervisor` as they
  start, and serves each one's requests, so nothing about a channel is kept
  where a node finds it:

      channels =
        WardrikChannel.channels([slack: {WardrikSlack, options}],
          host: host,
          installations: installations
        )

      children = [
        {WardrikChannel.Replies, channels: channels},
        {WardrikChannel.Supervisor, channels: channels}
      ]

  ## Rooms

  An adapter tells `WardrikChannel.Rooms` when its bot is invited into a
  room or taken out of one, and what was chosen there, handing it the
  `WardrikChannel.Room`. See `WardrikChannel.Rooms` for how a room comes to have
  an agent.

  ## Threads

  An adapter hands each message posted in a room to `received/2`, with its
  workspace. Each
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
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Error
  alias WardrikChannel.Binding
  alias WardrikChannel.Channel
  alias WardrikChannel.Context
  alias WardrikChannel.Inbound
  alias WardrikChannel.Member
  alias WardrikChannel.Outbound
  alias WardrikChannel.Replies
  alias WardrikChannel.Request
  alias WardrikChannel.Response
  alias WardrikChannel.Room
  alias WardrikChannel.Rooms
  alias WardrikChannel.Workspace

  @typedoc "A channel as configured: its adapter, and the options its `config/1` answered."
  @type channel() :: {module(), keyword()}

  @typedoc "The channels a node runs, by name."
  @type channels() :: %{String.t() => Channel.t()}

  @doc """
  Reads a channel's settings, as `config.yaml` writes them, less the keys
  every channel takes: `type`, `token`, `approvers`, `admins` and `create`. Answers
  the options its callbacks take, or the key that does not read, as a path
  within the channel, and why.
  """
  @callback config(settings :: map()) :: {:ok, keyword()} | {:error, [String.t()], String.t()}

  @doc "What the channel runs, given its options, its `:name` and its `:context`."
  @callback child_spec(keyword()) :: Supervisor.child_spec()

  @doc """
  Posts `outbound` in its room, in its installation's workspace, as the
  channel whose options these are.
  """
  @callback deliver(Outbound.t(), keyword()) :: {:ok, term()} | {:error, term()}

  @doc """
  Whether `names`, as `config.yaml` names people in the channel, such as by
  handle or email address, include `member`, as the channel whose options
  these are.
  """
  @callback include?(names :: [String.t()], Member.t(), keyword()) :: boolean()

  @doc """
  Answers what the medium sent the channel over HTTP, given its options,
  its `:name` and its `:context`. A request it cannot show came from the
  medium is refused.
  """
  @callback request(Request.t(), keyword()) :: Response.t()

  @doc """
  Where someone is sent to install the channel in a workspace of theirs,
  for `owner`, given its options, its `:name`, its `:context`, and
  `:return_to`, where the browser goes once it is installed, if anywhere.
  """
  @callback install_url(owner :: Prefix.t(), keyword()) ::
              {:ok, String.t()} | {:error, String.t()}

  @doc """
  Answers the medium sending someone back from installing the channel, as
  someone acting for `owner`: keeps the installation in the context's
  `WardrikChannel.Installations` where the install was started for `owner`,
  and refuses it otherwise.
  """
  @callback install(owner :: Prefix.t(), Request.t(), keyword()) :: Response.t()

  @doc """
  Every adapter the loaded applications name, by its type. Read once, as a
  host starts, and handed to what reads its channels' settings.
  """
  @spec discover() :: %{String.t() => module()}
  def discover do
    for {app, _description, _version} <- Application.loaded_applications(),
        {type, module} <- Application.get_env(app, :wardrik_channels, []),
        into: %{},
        do: {to_string(type), module}
  end

  @doc "The task supervisor a channel runs its work under."
  @spec tasks() :: atom()
  def tasks, do: WardrikChannel.TaskSupervisor

  @doc """
  The `Wardrik.Principal` of `member`: of type `:channel`, known as
  `channel/workspace/id`, so the same id in two channels, or two
  workspaces, are two people, and every channel names its people alike.
  Options: `:name`, the name the channel shows for them.

      WardrikChannel.principal(member, name: "jon")
      #=> a principal of type :channel, known as "slack/T0123/U024BE7LH", by name "jon"
  """
  @spec principal(Member.t(), keyword()) :: Wardrik.Principal.t()
  def principal(%Member{installation: installation, id: id}, opts \\ []) do
    opts = Keyword.validate!(opts, [:name])

    Wardrik.Principal.new(:channel, "#{installation.channel}/#{installation.workspace}/#{id}",
      name: opts[:name]
    )
  end

  @doc """
  The channel, the workspace and the id of someone `principal/2` made a
  principal of.

      WardrikChannel.person(WardrikChannel.principal(member))
      #=> {"slack", "T0123", "U024BE7LH"}
  """
  @spec person(Wardrik.Principal.t()) :: {String.t(), String.t(), String.t()}
  def person(principal) do
    [channel, workspace, user] = String.split(Wardrik.Principal.id(principal), "/", parts: 3)
    {channel, workspace, user}
  end

  @doc """
  What each of `configured`, channels by name as their adapters and the
  options their `config/1` answered, runs on: a `WardrikChannel.Channel`
  by its name, whose `WardrikChannel.Context` `opts` fill in.

  Options are the context's: `:host` and `:installations`, required, and
  `:offered`, `:creatable`, `:create`, `:start`, `:approvers`,
  `:offering`, `:deciding` and `:replies`, each as `WardrikChannel.Context`
  describes it.
  """
  @spec channels([{atom() | String.t(), channel()}], keyword()) :: channels()
  def channels(configured, opts) do
    opts =
      Keyword.validate!(opts, [
        :host,
        :installations,
        :offered,
        :creatable,
        :create,
        :start,
        :approvers,
        :offering,
        :deciding,
        :replies
      ])

    for {name, {adapter, options}} <- configured, into: %{} do
      name = to_string(name)
      context = struct!(Context, [channel: name] ++ opts)
      {name, %Channel{name: name, adapter: adapter, options: options, context: context}}
    end
  end

  @doc """
  Whether `names`, as `config.yaml` names people in `channel`, include
  `member`, as its adapter's `include?/3` says, with its options; never
  for `[]`.
  """
  @spec include?(channel(), [String.t()], Member.t()) :: boolean()
  def include?(_channel, [], %Member{}), do: false

  def include?({adapter, options}, names, %Member{} = member) when is_list(names),
    do: adapter.include?(names, member, options)

  @doc """
  Answers `request`, which the medium sent `channel` over HTTP, as a map of
  the fields of a `WardrikChannel.Request`, through its adapter.
  """
  @spec request(Channel.t(), map()) :: Response.t()
  def request(%Channel{} = channel, request) when is_map(request),
    do: channel.adapter.request(struct!(Request, request), Channel.options(channel))

  @doc """
  Where someone acting for `owner` is sent to install `channel` in a
  workspace of theirs. Options: `:return_to`, where the browser goes once
  it is installed.
  """
  @spec install_url(Channel.t(), Prefix.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def install_url(%Channel{} = channel, %Prefix{} = owner, opts \\ []) do
    opts = Keyword.validate!(opts, [:return_to])
    channel.adapter.install_url(owner, Channel.options(channel) ++ opts)
  end

  @doc """
  Answers the medium sending someone acting for `owner` back from
  installing `channel`, as `request/2` takes a request: installs it in
  their workspace, for `owner`, where `install_url/3` was asked for
  `owner`.
  """
  @spec install(Channel.t(), Prefix.t(), map()) :: Response.t()
  def install(%Channel{} = channel, %Prefix{} = owner, request) when is_map(request),
    do: channel.adapter.install(owner, struct!(Request, request), Channel.options(channel))

  @doc """
  A message was posted in a room of the workspace: asks the agent of
  its thread, starting it where it is not running, and has
  `WardrikChannel.Replies` post what it answers. Where the agent waits on a
  person, the message waits behind the calls it waits on, and they are posted
  in the thread again. Answers the agent asked, or
  `:ignored` for a message in a room no agent answers in, or one the room's
  agent does not answer.

  The message is the sender's, asked with `Wardrik.agent_ask/4` as
  every surface asks an agent, holding what the host's `Wardrik.Grants`
  give them: a room says which agent answers, and the sender's grants
  whether they may reach it. One who may not is told so, and the agent is
  neither started nor asked.
  """
  @spec received(Workspace.t(), Inbound.t()) ::
          {:asked, AgentID.t()} | :ignored | {:error, String.t()}
  def received(%Workspace{} = workspace, %Inbound{} = inbound) do
    thread = inbound.thread || inbound.id
    room = Room.new(workspace, inbound.room)

    with %Binding{} = binding <- Rooms.get(room),
         agent = conversation(binding, thread),
         true <- answers?(binding, inbound, agent) do
      ask(room, inbound, thread, agent)
    else
      _unanswered -> :ignored
    end
  end

  # Whether the agent waited on a person is asked before the message, so a
  # turn the message starts, and parks, is not taken for one already waiting.
  defp ask(%Room{workspace: workspace} = room, inbound, thread, agent) do
    with {:ok, session} <- reached(workspace.context, inbound.sender, agent),
         {:ok, _pid} <- Workspace.start(workspace, agent),
         :ok <- Replies.follow(room, thread, agent),
         waiting? = match?([_ | _], Wardrik.Agent.parked(agent, host: session.host)),
         {:ok, _message} <- Wardrik.agent_ask(session, agent, inbound.text, id: inbound.id) do
      if waiting?, do: Replies.remind(room, thread)
      {:asked, agent}
    else
      {:error, %Error{type: :not_found}} -> {:error, "#{agent} stopped before it could be asked."}
      {:error, %Error{message: message}} -> {:error, message}
      {:error, message} -> {:error, message}
    end
  end

  defp reached(%Context{host: host}, sender, agent) do
    case Wardrik.Host.caller(host, principal: sender, subject: agent) do
      {:ok, caller} ->
        {:ok, Wardrik.Session.new(host: host, principal: sender, grant: caller.grant)}

      {:error, _unreached} ->
        {:error, "#{AgentID.put_external_id(agent, nil)} is not one you may reach from here."}
    end
  end

  @doc "The agent that answers in `thread` of the room `binding` binds."
  @spec conversation(Binding.t(), String.t()) :: AgentID.t()
  def conversation(%Binding{room: room, agent: agent}, thread),
    do: AgentID.put_external_id(agent, room <> "-" <> thread)

  defp answers?(_binding, %Inbound{mentioned?: true}, _agent), do: true
  defp answers?(%Binding{answers: :everything}, _inbound, _agent), do: true
  defp answers?(_binding, %Inbound{thread: nil}, _agent), do: false
  defp answers?(_binding, _inbound, agent), do: Wardrik.Fleet.stored?(agent)
end
