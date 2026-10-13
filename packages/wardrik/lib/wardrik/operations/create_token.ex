defmodule Wardrik.Operations.CreateToken do
  @moduledoc """
  Makes a token through the host's `Wardrik.Tokens`, carrying `grant`, acting
  for `for`, or for itself where `nil`. It answers the secret this once;
  the audit records the token, never the secret.

  A token acting for a person whose scope names another person's agents,
  `acme/@maria/` for `jon`, is refused: it would act as one on what is the
  other's. A scope naming no person, an org's or every agent, is theirs to
  act within.
  """

  @behaviour Wardrik.DeploymentOperation
  @behaviour Wardrik.Command

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Change
  alias Wardrik.Deployment
  alias Wardrik.Error
  alias Wardrik.Host
  alias Wardrik.Operations.TokenCreated
  alias Wardrik.Principal
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
    with :ok <- issued(request), do: {:ok, Change.new(request)}
  end

  defp issued(%__MODULE__{for: nil}), do: :ok

  defp issued(%__MODULE__{for: for, grant: grant}) do
    case Prefix.user(grant.scope) do
      nil ->
        :ok

      user ->
        if user == Principal.id(for),
          do: :ok,
          else:
            {:error,
             Error.new(
               :invalid,
               "A token for #{Principal.id(for)} cannot reach #{grant.scope}, which is #{user}'s."
             )}
    end
  end

  @impl Wardrik.Command
  def make(%Change{request: %__MODULE__{name: name, grant: grant, for: for}}, caller) do
    case Host.tokens(caller.host).create(caller.host, name, grant, for) do
      {:ok, secret, token} ->
        made = %TokenCreated{token: token}
        {:created, %{"secret" => secret, "token" => Wardrik.Resource.token(token)}, made}

      {:error, message} ->
        {:error, Error.new(:invalid, message)}

      :unsupported ->
        {:error, Tokens.unsupported()}
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
