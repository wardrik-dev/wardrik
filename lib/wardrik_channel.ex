defmodule WardrikChannel do
  @moduledoc """
  Lets people talk to Wardrik's agents from chat apps, such as Slack.

  A *channel* is one chat app Wardrik runs, under a name you choose. A *room* is a place in it,
  such as a Slack channel.

      config :my_app, MyApp.AgentRuntime,
        channels: [
          slack:
            {WardrikSlack,
             token: "xoxb-...",
             signing_secret: "...",
             owner: "acme",
             identities: {MyApp.ChatMembers, []}}
        ]

  Each member acts as whoever your app's `WardrikChannel.Identities` says they are. Your
  authorizer decides what they may ask, read and decide. See `WardrikChannel.Workspace`.

  An agent answers in a channel when its definition lists it:

      Wardrik.Agent.define(scope, "agt_01JF8X5RQ2", model: "anthropic:claude-haiku-4-5", channels: ["slack"])

  Mention the bot in a room to start a thread. Reply in the thread to go on. Each thread is its own
  conversation, as `slack.T0123.C024BE91L.1696.1234`, and the agent keeps a history of it. Calls the agent waits on are
  posted in the thread for someone to decide. Whoever asked may always decide their own calls, if
  your authorizer allows it. See `WardrikChannel.Rooms` and `WardrikChannel.Replies`.

  ## Options

  Every channel takes these. Its adapter reads the rest.

  #{NimbleOptions.docs(WardrikChannel.Channel.schema())}

  Raises on start if an option is invalid, if neither or both of `:token` and `:installations`
  are given, or if the channel's name isn't lower-case letters, digits and `-`, starting with a
  letter.

  ## Writing an adapter

  An adapter is a package, such as `wardrik_slack`, that does `use WardrikChannel`. It speaks the
  chat app's protocol and nothing else: it implements `c:deliver/2`, and
  `c:Wardrik.Channel.request/2` to take what the chat app sends. Each callback takes what it acts
  on, then the `WardrikChannel.Channel`:

      defmodule MyChat do
        use WardrikChannel

        @impl Wardrik.Channel
        def request(%{path: "events", body: body}, opts) do
          channel = WardrikChannel.channel(__MODULE__, opts)
          event = JSON.decode!(body)

          with {:ok, workspace} <- WardrikChannel.workspace(channel, event["team"]) do
            WardrikChannel.received(workspace, %WardrikChannel.Inbound{
              room: event["room"],
              id: event["id"],
              sender: %WardrikChannel.Member{id: event["user"]},
              text: event["text"],
              mentioned?: event["mentioned"]
            })
          end

          %{status: 200, headers: %{}, body: ""}
        end

        @impl WardrikChannel
        def deliver(%WardrikChannel.Outbound{} = outbound, channel) do
          # Post outbound.body in outbound.room, in outbound.thread
          :ok
        end
      end

  Hand each button press to `decide/2`. `use WardrikChannel` defines `child_spec/1`,
  `c:children/1` and `c:Wardrik.Channel.notify/4`. Each can be overridden.
  """

  alias Wardrik.Channel.Installation
  alias Wardrik.Error
  alias WardrikChannel.Answer
  alias WardrikChannel.Binding
  alias WardrikChannel.Channel
  alias WardrikChannel.Inbound
  alias WardrikChannel.Outbound
  alias WardrikChannel.Replies
  alias WardrikChannel.Rooms
  alias WardrikChannel.Workspace

  @doc "Posts `outbound` in its thread. Returning an error has it tried again later."
  @callback deliver(Outbound.t(), Channel.t()) :: :ok | {:error, term()}

  @doc "Returns extra children to run, such as a connection to the chat app. `[]` by default."
  @callback children(Channel.t()) :: [Supervisor.child_spec() | {module(), term()}]

  @doc "Returns the URL where someone acting for the install's owner adds the chat app to their workspace."
  @callback install_url(WardrikChannel.Install.t(), Channel.t()) ::
              {:ok, String.t()} | {:error, String.t()}

  @doc """
  Finishes adding the chat app to a workspace, for the install's owner, from its `query`.
  Returns the installation and where to send the person next.
  """
  @callback installed(WardrikChannel.Install.t(), Channel.t()) ::
              {:ok, Installation.t(), String.t() | nil} | {:error, String.t()}

  @doc "Removes the chat app from `workspace`, where the chat app allows it, and forgets the workspace."
  @callback uninstall(workspace :: String.t(), Channel.t()) :: :ok | {:error, String.t()}

  @optional_callbacks install_url: 2, installed: 2, uninstall: 2

  defmacro __using__(_opts) do
    quote do
      @behaviour WardrikChannel
      @behaviour Wardrik.Channel

      @impl Wardrik.Channel
      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {WardrikChannel.Supervisor, :start_link, [{__MODULE__, opts}]},
          type: :supervisor
        }
      end

      @impl WardrikChannel
      def children(_channel), do: []

      @impl Wardrik.Channel
      def notify(notification, opts), do: WardrikChannel.notify(__MODULE__, notification, opts)

      defoverridable child_spec: 1, children: 1, notify: 2
    end
  end

  @doc """
  Posts a `Wardrik.Channel.Notification` through `adapter`. See `c:Wardrik.Channel.notify/2`.

  Posts in the notification's workspace, the one the agent's resolver gives. Returns
  `{:skip, why}` if the channel isn't added there.
  """
  @spec notify(module(), Wardrik.Channel.Notification.t(), keyword()) ::
          :ok | {:skip, String.t()} | {:error, term()}
  def notify(
        adapter,
        %Wardrik.Channel.Notification{workspace: workspace, room: room, notice: notice},
        opts
      ) do
    channel = Channel.new(adapter, opts)

    case Channel.installation(channel, workspace) do
      {:ok, installation} ->
        adapter.deliver(
          %Outbound{installation: installation, room: room, thread: nil, body: {:notice, notice}},
          channel
        )

      :error ->
        {:skip, "but #{channel.name} isn't added to the workspace #{workspace}"}
    end
  end

  @doc "Returns `adapter`'s channel, built from the options Wardrik passes it."
  @spec channel(module(), keyword()) :: Channel.t()
  def channel(adapter, opts), do: Channel.new(adapter, opts)

  @doc "Returns the channel in workspace `id`, or `:error` if it isn't added there."
  @spec workspace(Channel.t(), String.t()) :: {:ok, Workspace.t()} | :error
  def workspace(channel, id), do: Workspace.new(channel, id)

  @doc """
  Sends `inbound` to the room's agent, as its sender, and has the reply posted in its thread.

  The agent is asked when:

    * the message mentions the bot
    * the room's agent answers every message
    * the message replies in a thread the agent already answers in

  Returns `{:asked, {agent, conversation}}`, `:ignored` if no agent answers, or
  `{:error, message}`, as when your app doesn't know the sender or the authorizer refuses them.

  If the agent is waiting on calls, the message queues behind them and the calls are posted again.
  """
  @spec received(Workspace.t(), Inbound.t()) ::
          {:asked, {String.t(), String.t()}} | :ignored | {:error, String.t()}
  def received(%Workspace{} = workspace, %Inbound{} = inbound) do
    thread = inbound.thread || inbound.id

    with %Binding{} = binding <- Rooms.get(workspace, inbound.room),
         true <- answers?(workspace, binding, inbound, thread) do
      ask(workspace, binding, inbound, thread)
    else
      _unanswered -> :ignored
    end
  end

  defp answers?(_workspace, _binding, %Inbound{mentioned?: true}, _thread), do: true
  defp answers?(_workspace, %Binding{answers: :everything}, _inbound, _thread), do: true
  defp answers?(_workspace, _binding, %Inbound{thread: nil}, _thread), do: false

  defp answers?(workspace, binding, _inbound, thread),
    do: Rooms.started?(workspace, room: binding.room, thread: thread)

  defp ask(workspace, %Binding{room: room, agent: agent}, inbound, thread) do
    conversation = Workspace.conversation(workspace, room: room, thread: thread)
    held = [room: room, agent: agent, conversation: conversation]

    with {:ok, scope} <- Workspace.member_scope(workspace, inbound.sender),
         :ok <- Rooms.start(workspace, room: room, thread: thread),
         :ok <- Replies.follow(workspace, held),
         waiting? = waiting?(scope, agent, conversation),
         {:ok, _message} <-
           Wardrik.Agent.ask(scope, agent, [content: inbound.text, id: inbound.id],
             conversation: conversation
           ) do
      if waiting?, do: Replies.remind(workspace, held)
      {:asked, {agent, conversation}}
    else
      {:error, %Error{message: message}} -> {:error, message}
      {:error, why} -> {:error, why}
    end
  end

  defp waiting?(scope, agent, conversation),
    do:
      match?(
        {:ok, %Wardrik.Agent{status: :parked}},
        Wardrik.Agent.read(scope, agent, conversation: conversation)
      )

  @doc """
  Approves or denies a call the agent waits on, as `answer`'s member.

      WardrikChannel.decide(workspace, %WardrikChannel.Answer{
        member: member,
        agent: "agt_01JF8X5RQ2",
        conversation: "slack.T0123.C024BE91L.1696.1234",
        interrupt: "int_1",
        decision: {:approve, "Looks fine."}
      })
      #=> {:ok, %Wardrik.Decision{}}

  Build the `WardrikChannel.Answer` from what the adapter put on the button, from a
  `WardrikChannel.Waiting`.

  The member acts as whoever the channel's `:identities` says they are. The authorizer decides,
  from the context `WardrikChannel.Workspace.deciding_scope/2` gives it. A refusal is
  `{:error, deciding}`, the channel's `:deciding` message. A member your app doesn't know is told
  why.
  """
  @spec decide(Workspace.t(), Answer.t()) :: {:ok, Wardrik.Decision.t()} | {:error, String.t()}
  def decide(workspace, %Answer{decision: decision} = answer) do
    with {:ok, scope} <- Workspace.deciding_scope(workspace, answer),
         do: decided(workspace, answered(scope, answer, decision))
  end

  defp call(%Answer{agent: agent, interrupt: interrupt}), do: [agent: agent, interrupt: interrupt]

  defp held(%Answer{conversation: conversation}), do: given(:conversation, conversation)

  defp decided(_workspace, {:ok, [decision]}), do: {:ok, decision}

  defp decided(workspace, {:error, %Error{type: type}}) when type in [:forbidden, :not_found],
    do: {:error, workspace.channel.deciding}

  defp decided(_workspace, {:error, %Error{message: message}}), do: {:error, message}

  defp answered(scope, answer, {:approve, note}),
    do: Wardrik.Agent.approve(scope, call(answer) ++ given(:note, note), held(answer))

  defp answered(scope, answer, {:deny, reason}),
    do: Wardrik.Agent.deny(scope, call(answer) ++ given(:reason, reason), held(answer))

  defp given(_key, nil), do: []
  defp given(key, value), do: [{key, value}]
end
