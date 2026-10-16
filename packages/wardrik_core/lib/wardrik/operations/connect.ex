defmodule Wardrik.Operations.Connect do
  @moduledoc """
  Connects an account for an owner before any agent asks for it, through
  the host's `Wardrik.Connections`: a `Wardrik.Connections.Connecting`, with
  the link to authorize it at, or none where they hold it already. Nothing parks on it. The connection is recorded in
  the audit once it is held, as whoever asked for it.
  """

  @behaviour Wardrik.FleetOperation
  @behaviour Wardrik.Command

  alias Wardrik.Change
  alias Wardrik.Connections
  alias Wardrik.Connections.Connecting
  alias Wardrik.Connections.Owner
  alias Wardrik.Error
  alias Wardrik.Host
  alias Wardrik.Resource

  @enforce_keys [:owner, :provider]
  defstruct [:owner, :provider]

  @type t() :: %__MODULE__{owner: Wardrik.AgentID.Prefix.t(), provider: String.t()}

  @impl Wardrik.FleetOperation
  def subject(%__MODULE__{owner: owner}), do: owner

  @impl Wardrik.FleetOperation
  def action, do: :define

  @impl Wardrik.Command
  def plan(request, _caller), do: {:ok, Change.new(request)}

  @impl Wardrik.Command
  def make(%Change{request: %__MODULE__{owner: owner, provider: provider}} = change, caller) do
    connections = Host.connections(caller.host)

    case Connections.connect(connections, provider, Owner.owner_of(owner), by: caller.principal) do
      {:ok, :held} ->
        {:ok, %Connecting{provider: provider, authorization: nil}, change.effect}

      {:ok, link} ->
        {:ok, %Connecting{provider: provider, authorization: link}, change.effect}

      {:error, :not_found} ->
        {:error, Error.new(:not_found, "No account named #{provider} is offered.")}

      {:error, _reason} ->
        {:error, Error.new(:unavailable, "#{provider} could not start a sign-in now.")}

      :unsupported ->
        {:error, Wardrik.Connections.None.unsupported()}
    end
  end

  @impl Wardrik.Command
  def render(connecting), do: Resource.connecting(connecting)

  defimpl Wardrik.Effect do
    def preview(%{owner: owner, provider: provider}),
      do: %{"connecting" => %{"owner" => to_string(owner), "provider" => provider}}

    def audit(_connect), do: []
  end
end
