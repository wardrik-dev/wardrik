defmodule Wardrik.Operations.AddServer do
  @moduledoc """
  Adds an MCP server for an owner's agents, through the host's
  `Wardrik.Servers`: the `Wardrik.Servers.Server`, with the link where
  someone signs in to it first, or none where its agents can call it now. Recorded in the audit once it is added, as
  whoever asked for it.
  """

  @behaviour Wardrik.Catalog.Entry
  @behaviour Wardrik.FleetOperation
  @behaviour Wardrik.Command

  alias Wardrik.Change
  alias Wardrik.Error
  alias Wardrik.Host
  alias Wardrik.Resource

  @enforce_keys [:owner, :name, :fields]
  defstruct [:owner, :name, :fields]

  @type t() :: %__MODULE__{owner: Wardrik.AgentID.Prefix.t(), name: String.t(), fields: map()}

  @impl Wardrik.Catalog.Entry
  def name, do: "servers.add"

  @impl Wardrik.Catalog.Entry
  def summary,
    do:
      "Add an MCP server for the owner's agents, by its URL and how they sign in to it; " <>
        "answers where to sign in, where someone has to first."

  @impl Wardrik.Catalog.Entry
  def input, do: WardrikProtocol.schema("input_servers_add")

  @impl Wardrik.Catalog.Entry
  def new(owner, %{"name" => name} = input) when is_binary(name),
    do: {:ok, %__MODULE__{owner: owner, name: name, fields: Map.delete(input, "name")}}

  def new(_owner, _input),
    do: {:error, Error.new(:invalid, "A server is added with its name, its URL and its auth")}

  @impl Wardrik.Catalog.Entry
  def labels(_answer), do: []

  @impl Wardrik.FleetOperation
  def subject(%__MODULE__{owner: owner}), do: owner

  @impl Wardrik.FleetOperation
  def action, do: :define

  @impl Wardrik.Command
  def plan(request, _caller), do: {:ok, Change.new(request)}

  @impl Wardrik.Command
  def make(%Change{request: %__MODULE__{} = request} = change, caller) do
    case Wardrik.Servers.add(Host.servers(caller.host), request.owner,
           name: request.name,
           fields: request.fields,
           by: caller.principal
         ) do
      {:ok, :connected} -> {:created, added(request, nil), change.effect}
      {:ok, link} -> {:created, added(request, link), change.effect}
      {:error, %Error{} = error} -> {:error, error}
      :unsupported -> {:error, Wardrik.Servers.None.unsupported()}
    end
  end

  defp added(%__MODULE__{name: name, fields: fields}, link) do
    [{auth, how}] = Map.to_list(fields["auth"])

    %Wardrik.Servers.Server{
      name: name,
      url: fields["url"],
      auth: auth,
      secret: how["name"],
      header: how["header"],
      scheme: how["scheme"],
      scopes: how["scopes"],
      only: fields["only"],
      except: fields["except"],
      authorization: link
    }
  end

  @impl Wardrik.Command
  def render(added), do: Resource.server_added(added)

  defimpl Wardrik.Effect do
    def preview(%{owner: owner, name: name, fields: fields}),
      do: %{"adding" => %{"owner" => to_string(owner), "server" => name, "url" => fields["url"]}}

    def audit(%{owner: owner, name: name, fields: fields}),
      do: [{:server_added, Wardrik.Servers.Key.new(owner, name), fields["url"]}]
  end
end
