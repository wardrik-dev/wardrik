defmodule Wardrik.Operations.RemoveTrigger do
  @moduledoc """
  Removes one of an agent's triggers, through the host's
  `Wardrik.Definition`, which keeps them with the agent's definition.
  """

  @behaviour Wardrik.AgentOperation
  @behaviour Wardrik.Command

  alias Wardrik.Change
  alias Wardrik.Definition
  alias Wardrik.Error

  @enforce_keys [:agent, :name]
  defstruct [:agent, :name]

  @type t() :: %__MODULE__{agent: Wardrik.AgentID.t(), name: String.t()}

  @impl Wardrik.AgentOperation
  def subject(%__MODULE__{agent: id}), do: id

  @impl Wardrik.AgentOperation
  def action, do: :define

  @impl Wardrik.Command
  def plan(%__MODULE__{agent: id, name: name} = request, _caller) do
    with {:ok, _module} <- definitions(),
         do: {:ok, Change.new(request, [{:trigger_removed, id, name}])}
  end

  @impl Wardrik.Command
  def make(%Change{request: %__MODULE__{agent: id, name: name}}, _caller) do
    with {:ok, module} <- definitions() do
      case module.delete_trigger(id, name) do
        :ok -> {:ok, nil}
        {:error, :not_found} -> {:error, Error.new(:not_found, "#{id} has no trigger #{name}.")}
        {:error, :conflict, message} -> {:error, Error.new(:conflict, message)}
      end
    end
  end

  defp definitions do
    case Definition.module(:delete_trigger) do
      {:ok, module} -> {:ok, module}
      :unsupported -> {:error, Error.new(:unsupported, "This server keeps no triggers.")}
    end
  end
end
