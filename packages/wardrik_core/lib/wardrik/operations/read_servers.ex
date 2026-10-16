defmodule Wardrik.Operations.ReadServers do
  @moduledoc """
  The MCP servers an owner added, through the host's `Wardrik.Servers`:
  each one's name, URL and how its agents sign in to it, a
  `Wardrik.Servers.Listed`.
  """

  @behaviour Wardrik.Catalog.Entry
  @behaviour Wardrik.FleetOperation
  @behaviour Wardrik.Query

  alias Wardrik.Host
  alias Wardrik.Resource

  @enforce_keys [:owner]
  defstruct [:owner]

  @type t() :: %__MODULE__{owner: Wardrik.AgentID.Prefix.t()}

  @impl Wardrik.Catalog.Entry
  def name, do: "servers.list"

  @impl Wardrik.Catalog.Entry
  def summary, do: "List the MCP servers the owner added for their agents."

  @impl Wardrik.Catalog.Entry
  def input, do: WardrikProtocol.schema("input_servers_list")

  @impl Wardrik.Catalog.Entry
  def new(owner, _input), do: {:ok, %__MODULE__{owner: owner}}

  @impl Wardrik.Catalog.Entry
  def labels(_answer), do: []

  @impl Wardrik.FleetOperation
  def subject(%__MODULE__{owner: owner}), do: owner

  @impl Wardrik.FleetOperation
  def action, do: :read

  @impl Wardrik.Query
  def run(%__MODULE__{owner: owner}, caller) do
    case Wardrik.Servers.list(Host.servers(caller.host), owner) do
      :unsupported -> {:error, Wardrik.Servers.None.unsupported()}
      servers -> {:ok, servers}
    end
  end

  @impl Wardrik.Query
  def render(servers), do: Resource.servers(servers)
end
