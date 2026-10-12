defmodule Wardrik.Operations.Connect do
  @moduledoc """
  Connects an account for an owner before any agent asks for it, through
  the host's `Wardrik.Connections`: the link to authorize it at, or that
  they hold it already. Nothing parks on it. The connection is recorded in
  the audit once it is held, as whoever asked for it.
  """

  @behaviour Wardrik.Command

  alias Wardrik.Change
  alias Wardrik.Connections
  alias Wardrik.Error
  alias Wardrik.Resource

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
  def plan(request, _caller) do
    with {:ok, _module} <- Connections.module(), do: {:ok, Change.new(request)}
  end

  @impl Wardrik.Command
  def make(%Change{request: %__MODULE__{owner: owner, provider: provider}}, caller) do
    with {:ok, module} <- Connections.module() do
      case module.connect(provider, Connections.owner_of(owner), caller.principal) do
        {:ok, :held} ->
          {:ok, Resource.connecting(provider, nil)}

        {:ok, link} ->
          {:ok, Resource.connecting(provider, link)}

        {:error, :not_found} ->
          {:error, Error.new(:not_found, "No account named #{provider} is offered.")}

        {:error, _reason} ->
          {:error, Error.new(:unavailable, "#{provider} could not start a sign-in now.")}
      end
    end
  end
end
