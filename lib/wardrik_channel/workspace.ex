defmodule WardrikChannel.Workspace do
  @moduledoc """
  A channel in one place it's added to, such as one Slack workspace.

  Adapters get one for each request with `WardrikChannel.workspace/2`.

  People in the workspace act in Wardrik as themselves, with the channel as their actor,
  `{:channel, name}`. Wardrik's `Wardrik.Authorizer` decides what they may do, from what the
  channel puts in the scope's `context`:

    * `:installation` - `%{owner: owner, workspace: workspace}`, always.
    * `:asked_by` - when deciding, the principal ID that asked in the conversation, where known.
    * `:approver` - when deciding, whether the member is one of the installation's approvers.
      The adapter is asked only then.

  The workspace offers the owner's agents whose definitions list the channel in `channels`.
  """

  alias Wardrik.AgentID
  alias Wardrik.Channel.Installation
  alias WardrikChannel.Answer
  alias WardrikChannel.Channel
  alias WardrikChannel.Member
  alias WardrikChannel.Offer
  alias WardrikCore.Principal

  @enforce_keys [:channel, :installation]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{channel: Channel.t(), installation: Installation.t()}

  @doc "Returns the channel in workspace `id`, or `:error` if it isn't added there."
  @spec new(Channel.t(), String.t()) :: {:ok, t()} | :error
  def new(%Channel{} = channel, id) do
    with {:ok, installation} <- Channel.installation(channel, id),
         do: {:ok, %__MODULE__{channel: channel, installation: installation}}
  end

  @doc "Returns the channel's own scope, as the workspace, `slack:T0123`, with the channel as actor."
  @spec scope(t()) :: Wardrik.Scope.t()
  def scope(%__MODULE__{channel: channel, installation: installation} = workspace),
    do: acting(workspace, %Principal{id: channel.name <> ":" <> installation.workspace}, %{})

  @doc "Returns `member`'s scope, with the channel as actor."
  @spec member_scope(t(), Member.t()) :: Wardrik.Scope.t()
  def member_scope(workspace, member), do: acting(workspace, principal(workspace, member), %{})

  @doc """
  Returns the scope `answer`'s member decides calls in: `member_scope/2`, with `:asked_by` and
  `:approver` in its context.
  """
  @spec deciding_scope(t(), Answer.t()) :: Wardrik.Scope.t()
  def deciding_scope(workspace, %Answer{member: member, asked_by: asked_by}) do
    known = if asked_by, do: %{asked_by: asked_by}, else: %{}

    acting(
      workspace,
      principal(workspace, member),
      Map.put(known, :approver, approver?(workspace, member))
    )
  end

  defp acting(%__MODULE__{channel: channel, installation: installation}, principal, context) do
    Wardrik.Scope.new(channel.server,
      wardrik: channel.wardrik,
      principal: principal,
      actor: {:channel, channel.name},
      context:
        Map.put(context, :installation, %{
          owner: installation.owner,
          workspace: installation.workspace
        })
    )
  end

  @doc "Returns who `member` is to Wardrik, as `slack:T0123/U024BE7LH`."
  @spec principal(t(), Member.t()) :: Principal.t()
  def principal(%__MODULE__{channel: channel, installation: installation}, %Member{} = member) do
    id = "#{channel.name}:#{installation.workspace}/#{member.id}"
    %Principal{id: id, attributes: %{name: member.name}}
  end

  @doc "Returns whether `member` is one of the installation's approvers."
  @spec approver?(t(), Member.t()) :: boolean()
  def approver?(%__MODULE__{installation: %Installation{approvers: :anyone}}, _member), do: true
  def approver?(%__MODULE__{installation: %Installation{approvers: []}}, _member), do: false

  def approver?(%__MODULE__{channel: channel, installation: installation}, member),
    do:
      channel.adapter.include?(
        %WardrikChannel.Membership{
          installation: installation,
          names: installation.approvers,
          member: member
        },
        channel
      )

  @doc "Returns the agents that may answer in the workspace's rooms, sorted by ID."
  @spec offered(t()) :: [Offer.t()]
  def offered(%__MODULE__{installation: installation} = workspace) do
    scope = scope(workspace)
    {:ok, agents} = Wardrik.Agents.list(scope)

    agents
    |> Enum.map(& &1.id)
    |> Enum.filter(&Installation.owns?(installation, &1))
    |> Enum.reject(&AgentID.conversation?/1)
    |> Enum.flat_map(&offer(scope, workspace, &1))
  end

  defp offer(scope, %__MODULE__{channel: channel}, id) do
    case Wardrik.Agent.definition(scope, id) do
      {:ok, %Wardrik.Definition{channels: channels} = definition, _missing}
      when is_list(channels) ->
        if channel.name in channels,
          do: [
            %Offer{agent: id, name: definition.display_name, description: definition.description}
          ],
          else: []

      _undefined ->
        []
    end
  end

  @doc """
  Returns the ID of the conversation `:agent` holds for `:thread` of `:room`.

      WardrikChannel.Workspace.conversation(workspace,
        agent: "acme/triage",
        room: "C024BE91L",
        thread: "1696.1234"
      )
      #=> "acme/triage/slack.T0123.C024BE91L.1696.1234"
  """
  @spec conversation(t(), agent: String.t(), room: String.t(), thread: String.t()) :: String.t()
  def conversation(workspace, opts) do
    room = Keyword.fetch!(opts, :room)

    Keyword.fetch!(opts, :agent) <>
      "/" <> prefix(workspace, room) <> Keyword.fetch!(opts, :thread)
  end

  @doc """
  Returns the thread of `:room` that `:conversation` holds.

      WardrikChannel.Workspace.thread(workspace,
        room: "C024BE91L",
        conversation: "acme/triage/slack.T0123.C024BE91L.1696.1234"
      )
      #=> "1696.1234"
  """
  @spec thread(t(), room: String.t(), conversation: String.t()) :: String.t()
  def thread(workspace, opts) do
    {:ok, %AgentID{conversation: held}} = AgentID.parse(Keyword.fetch!(opts, :conversation))
    String.replace_prefix(held, prefix(workspace, Keyword.fetch!(opts, :room)), "")
  end

  @doc "Returns a pattern matching the logs of every conversation in `room`, for any agent."
  @spec logs(t(), String.t()) :: String.t()
  def logs(%__MODULE__{installation: installation} = workspace, room),
    do: installation.owner <> "/*/" <> prefix(workspace, room) <> "*"

  defp prefix(%__MODULE__{channel: channel, installation: installation}, room),
    do: Enum.join([channel.name, installation.workspace, room, ""], ".")
end
