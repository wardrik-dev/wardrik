defmodule WardrikChannel.Workspace do
  @moduledoc """
  A channel as it acts in one workspace it is installed in: the channel's
  `WardrikChannel.Context` and the `WardrikChannel.Installation`. An
  adapter makes one for each thing it hears, with `new/2`, and hands it to
  `WardrikChannel.received/2` and `WardrikChannel.Rooms`.

  The host's answers in the context are each given the installation, so a
  host that serves many owners answers for the one it was installed for.
  """

  alias Wardrik.AgentID
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

  @doc "The agents that may answer in a room of the workspace."
  @spec offered(t()) :: [Offer.t()]
  def offered(%__MODULE__{context: context} = workspace), do: call(context.offered, workspace)

  @doc "Whether someone in a room of the workspace may create an agent to answer there."
  @spec creatable?(t()) :: boolean()
  def creatable?(%__MODULE__{context: context} = workspace),
    do: call(context.creatable, workspace)

  @doc "Creates an agent for the room `name`, as `by` asked."
  @spec create(t(), String.t(), Principal.t() | nil) :: {:ok, Offer.t()} | {:error, String.t()}
  def create(%__MODULE__{context: context} = workspace, name, by),
    do: call(context.create, workspace, [name, by])

  @doc "Starts `agent`, which answers in a thread of the workspace's, where it is not running."
  @spec start(t(), AgentID.t()) :: {:ok, pid()} | {:error, String.t()}
  def start(%__MODULE__{context: context} = workspace, %AgentID{} = agent),
    do: call(context.start, workspace, [agent])

  @doc "Who decides what an agent asks in the workspace's threads."
  @spec approvers(t()) :: WardrikChannel.Approvers.t()
  def approvers(%__MODULE__{context: context} = workspace),
    do: call(context.approvers, workspace)

  defp call({module, function, args}, %__MODULE__{installation: installation}, more \\ []),
    do: apply(module, function, args ++ [installation | more])
end
