defmodule WardrikChannel.Workspace do
  @moduledoc """
  A channel as it acts in one workspace it is installed in: the channel's
  `WardrikChannel.Context` and the `WardrikChannel.Installation`. An
  adapter makes one for each thing it hears, with `new/2`, and hands it to
  `WardrikChannel.received/2`, and a `WardrikChannel.Room` of it to
  `WardrikChannel.Rooms`.

  The agents a workspace offers are those the host's `Wardrik.Definitions`
  keep whose definitions name the channel among their `channels`, of the
  orgs it offers, that its installation's owner covers (see
  `WardrikChannel.Installation.covers?/2`). An agent created in one of its
  rooms is defined from the `defaults` of its org's definitions, as a
  definition the host wrote, and offered in the channel.
  """

  alias Wardrik.AgentID
  alias Wardrik.Definition
  alias Wardrik.Definitions
  alias Wardrik.Fleet
  alias Wardrik.Host
  alias Wardrik.Principal
  alias WardrikChannel.Context
  alias WardrikChannel.Installation
  alias WardrikChannel.Installations
  alias WardrikChannel.Offer

  @enforce_keys [:context, :installation]
  defstruct [:context, :installation]

  @type t() :: %__MODULE__{context: Context.t(), installation: Installation.t()}

  @doc """
  The context's channel in the workspace the medium knows as `workspace`,
  where it is installed there.
  """
  @spec new(Context.t(), String.t()) :: {:ok, t()} | :error
  def new(%Context{channel: channel, installations: installations} = context, workspace) do
    with {:ok, installation} <- Installations.fetch(installations, channel, workspace),
         do: {:ok, %__MODULE__{context: context, installation: installation}}
  end

  @doc "The agents that may answer in a room of the workspace, sorted by ID."
  @spec offered(t()) :: [Offer.t()]
  def offered(%__MODULE__{context: context, installation: installation}) do
    for %Definition{id: id, channels: channels, description: description} <-
          Definitions.list(Host.definitions(context.host), Wardrik.Resource.parse!("*")),
        context.channel in channels,
        context.orgs == :all or id.org in context.orgs,
        Installation.covers?(installation, id),
        do: %Offer{agent: id, description: description}
  end

  @doc """
  Whether someone in a room of the workspace may create an agent to answer
  there: where the channel creates them, in an org its installation's
  owner covers, and the org's `defaults` name a policy their calls are held
  to.
  """
  @spec creatable?(t()) :: boolean()
  def creatable?(%__MODULE__{context: context, installation: installation} = workspace) do
    # The org's defaults, as any agent of the org reads them.
    any = AgentID.new!("agent", org: org(context))

    context.creates and Installation.covers?(installation, any) and
      is_map_key(defaults(workspace, any), "policy")
  end

  @doc """
  Creates an agent for the room `name`, named after it, in the channel's
  org, from its org's `defaults`, offered in the channel. It is kept as a
  definition the host wrote, and recorded in `Wardrik.Audit` as defined by
  `:by`, who asked.
  """
  @spec create(t(), String.t(), by: Principal.t() | nil) ::
          {:ok, Offer.t()} | {:error, String.t()}
  def create(%__MODULE__{context: context} = workspace, name, opts \\ []) do
    opts = Keyword.validate!(opts, [:by])
    description = "Answers in ##{name}."
    definitions = Host.definitions(context.host)

    with {:ok, id} <- created(name, org(context)),
         :ok <- unkept(definitions, id, context.channel),
         fields =
           Map.merge(defaults(workspace, id), %{
             "channels" => [context.channel],
             "description" => description
           }),
         read = Definitions.context(definitions, id),
         {:ok, definition} <- Definition.read(fields, id: id, source: :defaults, context: read),
         {:ok, spec} <- Definition.spec(definition, id, context: read, host: context.host),
         :ok <- Definitions.put(definitions, definition),
         {:ok, _pid} <- Fleet.put(spec) do
      :ok = Wardrik.Audit.record(Host.audit(context.host), {:agent_defined, id}, by: opts[:by])
      {:ok, %Offer{agent: id, description: description}}
    else
      {:error, :conflict, message} -> {:error, message}
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, "The agent did not start: #{inspect(reason)}"}
    end
  end

  # An agent's name, from the room's, in the channel's own org.
  defp created(room, org) do
    name = room |> String.downcase() |> String.replace(~r/[^a-z0-9_-]+/u, "-") |> String.trim("-")

    case AgentID.new(name, org: org) do
      {:ok, id} -> {:ok, id}
      {:error, _message} -> {:error, "#{inspect(room)} makes no agent's name."}
    end
  end

  defp unkept(definitions, id, channel) do
    case Definitions.get(definitions, id) do
      {:error, :not_found} ->
        :ok

      {:ok, _definition} ->
        {:error,
         "#{id} is there already. Whoever runs Wardrik can offer it here by adding " <>
           "`channels: [#{channel}]` to it."}
    end
  end

  defp org(%Context{orgs: [org | _rest]}), do: org
  defp org(%Context{org: org}), do: org

  defp defaults(%__MODULE__{context: context}, id),
    do: Definitions.context(Host.definitions(context.host), id).defaults

  @doc """
  Starts `agent`, which answers in a thread of the workspace's, where it is
  not running: it takes the spec its definition, or that of the agent it is
  a conversation of, writes as it starts. One neither running nor defined
  is not started.
  """
  @spec start(t(), AgentID.t()) :: {:ok, pid()} | {:error, String.t()}
  def start(%__MODULE__{context: context, installation: installation}, %AgentID{} = agent) do
    with %Fleet.Member{} <- Fleet.lookup(agent, host: context.host),
         {:ok, pid} <- Fleet.spawn(agent) do
      {:ok, pid}
    else
      nil -> {:error, "#{Installation.shown(installation, agent)} is not defined."}
      {:error, reason} -> {:error, "#{agent} did not start: #{inspect(reason)}"}
    end
  end

  @doc "How an agent comes to answer in the workspace's rooms, as said where none does."
  @spec offering(t()) :: String.t()
  def offering(%__MODULE__{context: context}),
    do:
      "Whoever runs Wardrik can offer an agent here by adding `channels: [#{context.channel}]` " <>
        "to its definition."

  @doc "Who else may decide what an agent asks there, as said to someone refused."
  @spec deciding(t()) :: String.t()
  def deciding(%__MODULE__{}),
    do: "The channel's approvers name who else may, and whoever runs Wardrik answers it too."

  @doc "Who decides what an agent asks in the workspace's threads."
  @spec approvers(t()) :: WardrikChannel.Approvers.t()
  def approvers(%__MODULE__{context: context}), do: context.approvers
end
