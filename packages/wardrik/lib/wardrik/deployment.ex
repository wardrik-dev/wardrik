defmodule Wardrik.Deployment do
  @moduledoc """
  The deployment itself, as what a `Wardrik.DeploymentOperation` acts on:
  where its agents run, and what runs beside them. Only a caller whose grant
  reaches every agent may act on it, so a caller held to an org or a person
  never learns, nor changes, where any agent runs.
  """

  defstruct []

  @type t() :: %__MODULE__{}

  @doc "The deployment."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "The deployment's nodes: this one, and every one connected to it."
  @spec nodes() :: [node()]
  def nodes, do: [Node.self() | Node.list()]

  @doc "`:ok` where `node` is one of the deployment's, as `nodes/0` answers them, or why not."
  @spec node(node()) :: :ok | {:error, Wardrik.Error.t()}
  def node(node) when is_atom(node) do
    if node in nodes(),
      do: :ok,
      else: {:error, Wardrik.Error.new(:invalid, "#{node} is not a node of this deployment.")}
  end
end

defimpl Wardrik.Subject, for: Wardrik.Deployment do
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Error
  alias Wardrik.Grant

  def authorize(_deployment, %Grant{scope: scope, can: can}, action) do
    if Prefix.covers?(scope, Prefix.all()) and action in can,
      do: :ok,
      else: {:error, Error.new(:forbidden, "This caller may not act on the deployment.")}
  end
end
