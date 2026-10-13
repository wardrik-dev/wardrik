defmodule Wardrik.Operations.RevokeToken do
  @moduledoc """
  Stops the token `id` working through the host's `Wardrik.Tokens`, and
  ends what is open on it.
  """

  @behaviour Wardrik.DeploymentOperation
  @behaviour Wardrik.Command

  alias Wardrik.Change
  alias Wardrik.Deployment
  alias Wardrik.Error
  alias Wardrik.Tokens

  @enforce_keys [:id]
  defstruct [:id]

  @type t() :: %__MODULE__{id: String.t()}

  @impl Wardrik.DeploymentOperation
  def subject(_request), do: Deployment.new()

  @impl Wardrik.DeploymentOperation
  def action, do: :define

  @impl Wardrik.Command
  def plan(%__MODULE__{id: id} = request, _caller) do
    with {:ok, module} <- Tokens.module() do
      if Enum.any?(module.list(), &(&1.id == id)),
        do: {:ok, Change.new(request)},
        else: {:error, not_found(id)}
    end
  end

  @impl Wardrik.Command
  def make(%Change{request: %__MODULE__{id: id}} = change, _caller) do
    with {:ok, module} <- Tokens.module() do
      case module.revoke(id) do
        :ok -> {:ok, nil, change.effect}
        {:error, :not_found} -> {:error, not_found(id)}
      end
    end
  end

  defp not_found(id), do: Error.new(:not_found, "No token has the id #{id}.")

  defimpl Wardrik.Effect do
    def preview(%{id: id}), do: %{"revoking_token" => %{"id" => id}}
    def audit(%{id: id}), do: [{:token_revoked, id}]
  end
end
