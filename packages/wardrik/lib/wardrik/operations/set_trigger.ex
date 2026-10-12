defmodule Wardrik.Operations.SetTrigger do
  @moduledoc """
  Sets one of an agent's triggers, as `wardrik_protocol`'s
  `trigger_definition.json` describes it. A trigger is part of the agent's
  definition, so the host's `Wardrik.Definition` sets it; the answer is the
  trigger, `:created` where the agent had none of that name.
  """

  @behaviour Wardrik.AgentOperation
  @behaviour Wardrik.Command

  alias Wardrik.Change
  alias Wardrik.Definition
  alias Wardrik.Error
  alias Wardrik.Operations.ReadDefinition

  @enforce_keys [:agent, :name, :fields]
  defstruct [:agent, :name, :fields]

  @type t() :: %__MODULE__{agent: Wardrik.AgentID.t(), name: String.t(), fields: map()}

  @impl Wardrik.AgentOperation
  def subject(%__MODULE__{agent: id}), do: id

  @impl Wardrik.AgentOperation
  def action, do: :define

  @impl Wardrik.Command
  def plan(%__MODULE__{} = request, _caller) do
    with {:ok, _module} <- definitions(), do: {:ok, Change.new(request)}
  end

  @impl Wardrik.Command
  def make(%Change{request: %__MODULE__{agent: id, name: name, fields: fields}} = change, _caller) do
    with {:ok, module} <- definitions() do
      case module.put_trigger(id, name, fields) do
        {:ok, :created, trigger} -> {:created, %{"trigger" => trigger}, change.effect}
        {:ok, :changed, trigger} -> {:ok, %{"trigger" => trigger}, change.effect}
        {:error, :not_found} -> {:error, ReadDefinition.undefined(id)}
        {:error, :conflict, message} -> {:error, Error.new(:conflict, message)}
        {:error, message} -> {:error, Error.new(:invalid, message)}
      end
    end
  end

  defp definitions do
    case Definition.module(:put_trigger) do
      {:ok, module} -> {:ok, module}
      :unsupported -> {:error, Error.new(:unsupported, "This server keeps no triggers.")}
    end
  end

  defimpl Wardrik.Effect do
    def preview(%{agent: id, name: name, fields: fields}),
      do: %{"setting" => %{"agent" => to_string(id), "trigger" => Map.put(fields, "name", name)}}

    def audit(%{agent: id, name: name}), do: [{:trigger_set, id, name}]
  end
end
