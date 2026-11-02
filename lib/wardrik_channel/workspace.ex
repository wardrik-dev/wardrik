defmodule WardrikChannel.Workspace do
  @moduledoc """
  A channel in one place it's added to, such as one Slack workspace.

  Adapters get one for each request with `WardrikChannel.workspace/2`.

  Members act in Wardrik as the principal the channel's `WardrikChannel.Identities` gives, with
  the channel as their actor, `{:channel, name}`. Wardrik's `Wardrik.Authorizer` decides what
  they may do, from what the channel puts in the scope's `context`:

    * `:installation` - `%{owner: owner, workspace: workspace}`, always.
    * `:asked_by` - when deciding, the principal ID that asked in the conversation, where known.

  The workspace offers the agents the authorizer lets a member read whose definitions list the
  channel in `channels`.
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

  @doc """
  Returns the channel's own scope, for what no member asked, such as posting replies. It acts
  for the installation's owner, with the channel as actor.
  """
  @spec scope(t()) :: Wardrik.Scope.t()
  def scope(%__MODULE__{installation: installation} = workspace),
    do: acting(workspace, %Principal{id: installation.owner}, %{})

  @doc "Returns `member`'s scope, with the channel as actor, or what to tell them if they may not act."
  @spec member_scope(t(), Member.t()) :: {:ok, Wardrik.Scope.t()} | {:error, String.t()}
  def member_scope(workspace, member) do
    with {:ok, principal} <- identify(workspace, member),
         do: {:ok, acting(workspace, principal, %{})}
  end

  @doc """
  Returns the scope `answer`'s member decides calls in: `member_scope/2`, with `:asked_by` in its
  context where known.
  """
  @spec deciding_scope(t(), Answer.t()) :: {:ok, Wardrik.Scope.t()} | {:error, String.t()}
  def deciding_scope(workspace, %Answer{member: member, asked_by: asked_by}) do
    known = if asked_by, do: %{asked_by: asked_by}, else: %{}

    with {:ok, principal} <- identify(workspace, member),
         do: {:ok, acting(workspace, principal, known)}
  end

  @doc "Returns who `member` is in your app, from the channel's `:identities`, or why they may not act."
  @spec identify(t(), Member.t()) :: {:ok, Principal.t()} | {:error, String.t()}
  def identify(%__MODULE__{channel: channel, installation: installation}, %Member{} = member),
    do: Channel.identify(channel, installation.workspace, member)

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

  @doc """
  Returns the agents that may answer in the workspace's rooms, sorted by ID: those the authorizer
  lets `member` read, or the channel's own scope without one. A member who may not act is offered
  none.
  """
  @spec offered(t(), Member.t() | nil) :: [Offer.t()]
  def offered(workspace, member \\ nil)

  def offered(workspace, nil), do: offered_in(workspace, scope(workspace))

  def offered(workspace, %Member{} = member) do
    case member_scope(workspace, member) do
      {:ok, scope} -> offered_in(workspace, scope)
      {:error, _why} -> []
    end
  end

  defp offered_in(workspace, scope) do
    case Wardrik.Agents.list(scope) do
      {:ok, agents} ->
        agents
        |> Enum.map(& &1.id)
        |> Enum.reject(&AgentID.conversation?/1)
        |> Enum.flat_map(&offer(scope, workspace, &1))

      {:error, _error} ->
        []
    end
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
  def logs(workspace, room), do: "*/" <> prefix(workspace, room) <> "*"

  defp prefix(%__MODULE__{channel: channel, installation: installation}, room),
    do: Enum.join([channel.name, installation.workspace, room, ""], ".")
end
