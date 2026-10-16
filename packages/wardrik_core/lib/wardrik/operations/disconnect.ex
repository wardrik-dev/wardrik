defmodule Wardrik.Operations.Disconnect do
  @moduledoc """
  Forgets an owner's account, through the host's `Wardrik.Connections`, so
  the next call that needs it asks them to connect again. The answer is the
  connection as it was: held by the owner, a person or an org.
  """

  @behaviour Wardrik.FleetOperation
  @behaviour Wardrik.Command

  alias Wardrik.Change
  alias Wardrik.Connections
  alias Wardrik.Connections.Connection
  alias Wardrik.Connections.Owner
  alias Wardrik.Error
  alias Wardrik.Host

  @enforce_keys [:owner, :provider]
  defstruct [:owner, :provider]

  @type t() :: %__MODULE__{owner: Wardrik.AgentID.Prefix.t(), provider: String.t()}

  @impl Wardrik.FleetOperation
  def subject(%__MODULE__{owner: owner}), do: owner

  @impl Wardrik.FleetOperation
  def action, do: :define

  @impl Wardrik.Command
  def plan(%__MODULE__{} = request, _caller), do: {:ok, Change.new(request)}

  @impl Wardrik.Command
  def make(%Change{request: %__MODULE__{owner: owner, provider: provider}} = change, caller) do
    whose = Owner.owner_of(owner)

    case Connections.disconnect(Host.connections(caller.host), provider, whose) do
      :ok ->
        {:ok, %Connection{provider: provider, held_by: held_by(whose)}, change.effect}

      {:error, :not_found} ->
        {:error, Error.new(:not_found, "#{owner} holds no #{provider}.")}

      {:error, _reason} ->
        {:error, Error.new(:unavailable, "#{provider} could not be forgotten now.")}

      :unsupported ->
        {:error, Wardrik.Connections.None.unsupported()}
    end
  end

  @impl Wardrik.Command
  def render(_connection), do: nil

  # An owner forgets only an account of their own.
  defp held_by({_org, _user}), do: :person
  defp held_by(org) when is_binary(org), do: :org

  defimpl Wardrik.Effect do
    def preview(%{owner: owner, provider: provider}),
      do: %{"disconnecting" => %{"owner" => to_string(owner), "provider" => provider}}

    def audit(%{owner: owner, provider: provider}), do: [{:secret_removed, provider, owner}]
  end
end
