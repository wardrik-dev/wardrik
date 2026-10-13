defmodule Wardrik.Operations.Connect do
  @moduledoc """
  Connects an account for an owner before any agent asks for it, through
  the host's `Wardrik.Connections`: the link to authorize it at, or that
  they hold it already. Nothing parks on it. The connection is recorded in
  the audit once it is held, as whoever asked for it.
  """

  @behaviour Wardrik.FleetOperation
  @behaviour Wardrik.Command

  alias Wardrik.Change
  alias Wardrik.Connections
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

    case connections.connect(provider, Connections.owner_of(owner), caller.principal) do
      {:ok, :held} ->
        {:ok, Resource.connecting(provider, nil), change.effect}

      {:ok, link} ->
        {:ok, Resource.connecting(provider, link), change.effect}

      {:error, :not_found} ->
        {:error, Error.new(:not_found, "No account named #{provider} is offered.")}

      {:error, _reason} ->
        {:error, Error.new(:unavailable, "#{provider} could not start a sign-in now.")}

      :unsupported ->
        {:error, Connections.unsupported()}
    end
  end

  defimpl Wardrik.Effect do
    def preview(%{owner: owner, provider: provider}),
      do: %{"connecting" => %{"owner" => to_string(owner), "provider" => provider}}

    def audit(_connect), do: []
  end
end
