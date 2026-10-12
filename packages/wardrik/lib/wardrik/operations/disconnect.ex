defmodule Wardrik.Operations.Disconnect do
  @moduledoc """
  Forgets an owner's account, through the host's `Wardrik.Connections`, so
  the next call that needs it asks them to connect again.
  """

  @behaviour Wardrik.Command

  alias Wardrik.Change
  alias Wardrik.Connections
  alias Wardrik.Error

  @enforce_keys [:owner, :provider]
  defstruct [:owner, :provider]

  @type t() :: %__MODULE__{owner: Wardrik.AgentID.Prefix.t(), provider: String.t()}

  @doc "The owner's agents, which a caller reaches to change their connections."
  @spec subject(t()) :: Wardrik.AgentID.Prefix.t()
  def subject(%__MODULE__{owner: owner}), do: owner

  @doc "What a grant must allow on them."
  @spec action() :: Wardrik.Grant.action()
  def action, do: :define

  @impl Wardrik.Command
  def plan(%__MODULE__{owner: owner, provider: provider} = request, _caller) do
    with {:ok, _module} <- Connections.module(),
         do: {:ok, Change.new(request, [{:secret_removed, provider, owner}])}
  end

  @impl Wardrik.Command
  def make(%Change{request: %__MODULE__{owner: owner, provider: provider}}, _caller) do
    with {:ok, module} <- Connections.module() do
      case module.disconnect(provider, Connections.owner_of(owner)) do
        :ok ->
          {:ok, nil}

        {:error, :not_found} ->
          {:error, Error.new(:not_found, "#{owner} holds no #{provider}.")}

        {:error, _reason} ->
          {:error, Error.new(:unavailable, "#{provider} could not be forgotten now.")}
      end
    end
  end
end
