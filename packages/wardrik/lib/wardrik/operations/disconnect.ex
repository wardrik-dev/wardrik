defmodule Wardrik.Operations.Disconnect do
  @moduledoc """
  Forgets an owner's account, through the host's `Wardrik.Connections`, so
  the next call that needs it asks them to connect again.
  """

  @behaviour Wardrik.FleetOperation
  @behaviour Wardrik.Command

  alias Wardrik.Change
  alias Wardrik.Connections
  alias Wardrik.Error

  @enforce_keys [:owner, :provider]
  defstruct [:owner, :provider]

  @type t() :: %__MODULE__{owner: Wardrik.AgentID.Prefix.t(), provider: String.t()}

  @impl Wardrik.FleetOperation
  def subject(%__MODULE__{owner: owner}), do: owner

  @impl Wardrik.FleetOperation
  def action, do: :define

  @impl Wardrik.Command
  def plan(%__MODULE__{} = request, _caller) do
    with {:ok, _module} <- Connections.module(), do: {:ok, Change.new(request)}
  end

  @impl Wardrik.Command
  def make(%Change{request: %__MODULE__{owner: owner, provider: provider}} = change, _caller) do
    with {:ok, module} <- Connections.module() do
      case module.disconnect(provider, Connections.owner_of(owner)) do
        :ok ->
          {:ok, nil, change.effect}

        {:error, :not_found} ->
          {:error, Error.new(:not_found, "#{owner} holds no #{provider}.")}

        {:error, _reason} ->
          {:error, Error.new(:unavailable, "#{provider} could not be forgotten now.")}
      end
    end
  end

  defimpl Wardrik.Effect do
    def preview(%{owner: owner, provider: provider}),
      do: %{"disconnecting" => %{"owner" => to_string(owner), "provider" => provider}}

    def audit(%{owner: owner, provider: provider}), do: [{:secret_removed, provider, owner}]
  end
end
