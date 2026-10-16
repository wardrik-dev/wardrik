defmodule Wardrik.Operations.RemoveServer do
  @moduledoc """
  Removes an MCP server an owner added, through the host's
  `Wardrik.Servers`: its agents lose its tools on their next turn, and every
  connection to it is stopped. The answer is the server as it was.
  """

  @behaviour Wardrik.Catalog.Entry
  @behaviour Wardrik.FleetOperation
  @behaviour Wardrik.Command

  alias Wardrik.Change
  alias Wardrik.Error
  alias Wardrik.Host

  @enforce_keys [:owner, :name]
  defstruct [:owner, :name]

  @type t() :: %__MODULE__{owner: Wardrik.AgentID.Prefix.t(), name: String.t()}

  @impl Wardrik.Catalog.Entry
  def name, do: "servers.remove"

  @impl Wardrik.Catalog.Entry
  def summary, do: "Remove an MCP server the owner added, so their agents can no longer call it."

  @impl Wardrik.Catalog.Entry
  def input, do: WardrikProtocol.schema("input_servers_remove")

  @impl Wardrik.Catalog.Entry
  def new(owner, %{"name" => name}) when is_binary(name),
    do: {:ok, %__MODULE__{owner: owner, name: name}}

  def new(_owner, _input), do: {:error, Error.new(:invalid, "A server is removed by its name")}

  @impl Wardrik.Catalog.Entry
  def labels(_answer), do: []

  @impl Wardrik.FleetOperation
  def subject(%__MODULE__{owner: owner}), do: owner

  @impl Wardrik.FleetOperation
  def action, do: :define

  @impl Wardrik.Command
  def plan(request, _caller), do: {:ok, Change.new(request)}

  @impl Wardrik.Command
  def make(%Change{request: %__MODULE__{owner: owner, name: name}} = change, caller) do
    servers = Host.servers(caller.host)

    with listed when is_list(listed) <- Wardrik.Servers.list(servers, owner),
         :ok <- Wardrik.Servers.remove(servers, owner, name: name, by: caller.principal) do
      {:ok, Enum.find(listed, &(&1.name == name)), change.effect}
    else
      {:error, %Error{} = error} -> {:error, error}
      :unsupported -> {:error, Wardrik.Servers.None.unsupported()}
    end
  end

  @impl Wardrik.Command
  def render(_server), do: nil

  defimpl Wardrik.Effect do
    def preview(%{owner: owner, name: name}),
      do: %{"removing" => %{"owner" => to_string(owner), "server" => name}}

    def audit(%{owner: owner, name: name}),
      do: [{:server_removed, Wardrik.Servers.Key.new(owner, name)}]
  end
end
