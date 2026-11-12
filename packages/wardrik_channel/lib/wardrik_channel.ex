defmodule WardrikChannel do
  @moduledoc """
  Talk to Wardrik agents from chat apps, such as Slack. See the README to set one up.

      config :my_app, MyApp.AgentRuntime,
        channels: [
          slack:
            {WardrikSlack,
             token: "xoxb-...",
             signing_secret: "...",
             owner: "acme",
             identities: {MyApp.ChatMembers, []}}
        ]

  ## Options

  Every channel takes these. Its adapter reads the rest.

  #{NimbleOptions.docs(WardrikChannel.Channel.schema())}

  Give either `:token` and `:owner`, or `:installations`. The name is lower-case letters, digits
  and `-`, starting with a letter. Raises on start otherwise.

  ## Writing an adapter

  An adapter speaks one chat app's protocol. It does `use WardrikChannel`, takes requests in
  `c:Wardrik.Channel.request/2`, and posts in `c:deliver/2`:

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

    * Pass each approve or deny button press to `decide/2`.
    * `use WardrikChannel` defines `child_spec/1`, `c:children/1` and
      `c:Wardrik.Channel.notify/2`. Each can be overridden.
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

  @doc """
  Posts `outbound` in its thread. `{:skip, why}` declines it, as for a notice its thread already
  shows. An error has it tried again later.
  """
  @callback deliver(Outbound.t(), Channel.t()) :: :ok | {:skip, String.t()} | {:error, term()}

  @doc "Returns extra children to run, such as a connection to the chat app. `[]` by default."
  @callback children(Channel.t()) :: [Supervisor.child_spec() | {module(), term()}]

  @doc "Returns the URL where someone adds the chat app to their workspace."
  @callback install_url(WardrikChannel.Install.t(), Channel.t()) ::
              {:ok, String.t()} | {:error, String.t()}

  @doc """
  Finishes adding the chat app from the redirect's `query`. Returns the installation and where
  to send the person next.
  """
  @callback installed(WardrikChannel.Install.t(), Channel.t()) ::
              {:ok, Installation.t(), String.t() | nil} | {:error, String.t()}

  @doc "Removes the chat app from `workspace`, where the chat app allows it."
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
  Posts a `Wardrik.Channel.Notification` through `adapter`, in its workspace.

  Returns `{:skip, why}` if the channel isn't added to that workspace.
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
  Asks the room's agent `inbound`, and posts the reply in its thread.

  The agent is asked when the message mentions the bot, when the room answers every message, or
  when it replies in a thread the agent answers in.

    * `{:asked, {agent, conversation}}` - asked.
    * `:ignored` - no agent answers it.
    * `{:error, message}` - to tell the sender, such as when your app doesn't know them.
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
  Approves or denies a call the agent waits on, as the member who pressed the button.

      WardrikChannel.decide(workspace, %WardrikChannel.Answer{
        member: member,
        agent: "agt_01JF8X5RQ2",
        conversation: "slack.T0123.C024BE91L.1696.1234",
        interrupt: "int_1",
        decision: {:approve, "Looks fine."}
      })
      #=> {:ok, %Wardrik.Decision{}}

  Build the `WardrikChannel.Answer` from what the adapter put on the button. Returns
  `{:error, message}` to tell the member, such as the channel's `:deciding` message if refused.
  """
  @spec decide(Workspace.t(), Answer.t()) :: {:ok, Wardrik.Decision.t()} | {:error, String.t()}
  def decide(workspace, %Answer{decision: decision} = answer) do
    with {:ok, scope} <- Workspace.deciding_scope(workspace, answer),
         do: decided(workspace, answered(scope, answer, decision))
  end

  defp call(%Answer{agent: agent, interrupt: interrupt, conversation: conversation}),
    do: [agent: agent, interrupt: interrupt] ++ given(:conversation, conversation)

  defp decided(_workspace, {:ok, [decision]}), do: {:ok, decision}

  defp decided(workspace, {:error, %Error{type: type}}) when type in [:forbidden, :not_found],
    do: {:error, workspace.channel.deciding}

  defp decided(_workspace, {:error, %Error{message: message}}), do: {:error, message}

  defp answered(scope, answer, {:approve, note}),
    do: Wardrik.Agent.approve(scope, call(answer) ++ given(:note, note))

  defp answered(scope, answer, {:deny, reason}),
    do: Wardrik.Agent.deny(scope, call(answer) ++ given(:reason, reason))

  defp given(_key, nil), do: []
  defp given(key, value), do: [{key, value}]
end
