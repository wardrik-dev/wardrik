defmodule WardrikChannel.Workspace do
  @moduledoc """
  A channel in one workspace it's added to, such as one Slack workspace. Adapters get one with
  `WardrikChannel.workspace/2`.

  A member's scope, which your `Wardrik.Authorizer` sees, has:

    * `principal` - who `WardrikChannel.Identities` says the member is.
    * `actor` - `{:channel, name}`.
    * `context.installation` - `%{owner: owner, workspace: workspace}`.
    * `context.asked_by` - when deciding, the ID of who asked, where known.
  """

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

  @doc "Returns the channel's own scope, used when no member asked, such as to post replies."
  @spec scope(t()) :: Wardrik.Scope.t()
  def scope(%__MODULE__{installation: installation} = workspace),
    do: acting(workspace, %Principal{id: installation.owner}, %{})

  @doc "Returns `member`'s scope, or what to tell them if your app doesn't know them."
  @spec member_scope(t(), Member.t()) :: {:ok, Wardrik.Scope.t()} | {:error, String.t()}
  def member_scope(workspace, member) do
    with {:ok, principal} <- identify(workspace, member),
         do: {:ok, acting(workspace, principal, %{})}
  end

  @doc "Returns `member_scope/2` for the answer's member, with `:asked_by` in its context."
  @spec deciding_scope(t(), Answer.t()) :: {:ok, Wardrik.Scope.t()} | {:error, String.t()}
  def deciding_scope(workspace, %Answer{member: member, asked_by: asked_by}) do
    known = if asked_by, do: %{asked_by: asked_by}, else: %{}

    with {:ok, principal} <- identify(workspace, member),
         do: {:ok, acting(workspace, principal, known)}
  end

  @doc "Returns who `member` is in your app, or what to tell them if unknown."
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
  Returns the agents that list this channel and that `member` may read, sorted by ID. Without a
  member, uses the channel's own scope.
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
        |> Enum.filter(&(&1.conversation == nil))
        |> Enum.flat_map(&offer(scope, workspace, &1.id))

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
  Returns the conversation ID of `:thread` in `:room`.

      WardrikChannel.Workspace.conversation(workspace, room: "C024BE91L", thread: "1696.1234")
      #=> "slack.T0123.C024BE91L.1696.1234"
  """
  @spec conversation(t(), room: String.t(), thread: String.t()) :: String.t()
  def conversation(workspace, opts),
    do: prefix(workspace, Keyword.fetch!(opts, :room)) <> Keyword.fetch!(opts, :thread)

  @doc """
  Returns the thread of `:room` that `:conversation` holds. The reverse of `conversation/2`.

      WardrikChannel.Workspace.thread(workspace,
        room: "C024BE91L",
        conversation: "slack.T0123.C024BE91L.1696.1234"
      )
      #=> "1696.1234"
  """
  @spec thread(t(), room: String.t(), conversation: String.t()) :: String.t()
  def thread(workspace, opts) do
    held = Keyword.fetch!(opts, :conversation)
    String.replace_prefix(held, prefix(workspace, Keyword.fetch!(opts, :room)), "")
  end

  defp prefix(%__MODULE__{channel: channel, installation: installation}, room),
    do: Enum.join([channel.name, installation.workspace, room, ""], ".")
end
