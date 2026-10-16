defmodule Wardrik.Operations.ListTokens do
  @moduledoc "Every token the host's `Wardrik.Tokens` keeps, oldest first; never a secret."

  @behaviour Wardrik.DeploymentOperation
  @behaviour Wardrik.Query

  alias Wardrik.Deployment
  alias Wardrik.Host
  alias Wardrik.Tokens

  defstruct []

  @type t() :: %__MODULE__{}

  @impl Wardrik.DeploymentOperation
  def subject(_request), do: Deployment.new()

  @impl Wardrik.DeploymentOperation
  def action, do: :read

  @impl Wardrik.Query
  def run(_request, caller) do
    case Tokens.list(Host.tokens(caller.host)) do
      :unsupported -> {:error, Wardrik.Tokens.None.unsupported()}
      tokens -> {:ok, tokens}
    end
  end

  @impl Wardrik.Query
  def render(tokens), do: %{"tokens" => Enum.map(tokens, &Wardrik.Resource.token/1)}
end
