defmodule Wardrik.Operations.CreateToken do
  @moduledoc """
  Makes a token through the host's `Wardrik.Tokens`, carrying `grant`, acting
  for `for`, or for itself where `nil`. It answers the secret this once;
  the audit records the token, never the secret.
  """

  @behaviour Wardrik.DeploymentOperation
  @behaviour Wardrik.Command

  alias Wardrik.Change
  alias Wardrik.Deployment
  alias Wardrik.Error
  alias Wardrik.Operations.TokenCreated
  alias Wardrik.Tokens

  @enforce_keys [:name, :grant]
  defstruct [:name, :grant, :for]

  @type t() :: %__MODULE__{
          name: String.t(),
          grant: Wardrik.Grant.t(),
          for: Wardrik.Principal.t() | nil
        }

  @impl Wardrik.DeploymentOperation
  def subject(_request), do: Deployment.new()

  @impl Wardrik.DeploymentOperation
  def action, do: :define

  @impl Wardrik.Command
  def plan(request, _caller) do
    with {:ok, _module} <- Tokens.module(), do: {:ok, Change.new(request)}
  end

  @impl Wardrik.Command
  def make(%Change{request: %__MODULE__{name: name, grant: grant, for: for}}, _caller) do
    with {:ok, module} <- Tokens.module() do
      case module.create(name, grant, for) do
        {:ok, secret, token} ->
          made = %TokenCreated{token: token}
          {:created, %{"secret" => secret, "token" => Wardrik.Resource.token(token)}, made}

        {:error, message} ->
          {:error, Error.new(:invalid, message)}
      end
    end
  end

  defimpl Wardrik.Effect do
    alias Wardrik.Event.Codec.Value
    alias Wardrik.Principal

    def preview(%{name: name, grant: grant, for: for}) do
      token =
        %{"name" => name, "scope" => to_string(grant.scope)}
        |> Map.put("can", Enum.map(grant.can, &to_string/1))
        |> Value.put("for", for && Principal.id(for))

      %{"creating_token" => token}
    end

    def audit(_request), do: []
  end
end
