defmodule Wardrik.Operations.RemoveTrigger do
  @moduledoc """
  Removes one of an agent's triggers, through the host's
  `Wardrik.Definition`, which keeps them with the agent's definition.
  """

  @behaviour Wardrik.AgentOperation
  @behaviour Wardrik.Catalog.Entry
  @behaviour Wardrik.Command

  alias Wardrik.Change
  alias Wardrik.Error
  alias Wardrik.Host

  @enforce_keys [:agent, :name]
  defstruct [:agent, :name]

  @type t() :: %__MODULE__{agent: Wardrik.AgentID.t(), name: String.t()}

  @impl Wardrik.Catalog.Entry
  def name, do: "agent.trigger.remove"

  @impl Wardrik.Catalog.Entry
  def summary, do: "Remove one of the agent's triggers, by name."

  @impl Wardrik.Catalog.Entry
  def input, do: WardrikProtocol.schema("input_agent_trigger_remove")

  @impl Wardrik.Catalog.Entry
  def new(%Wardrik.AgentID{} = agent, %{"name" => name}) when is_binary(name),
    do: {:ok, %__MODULE__{agent: agent, name: name}}

  def new(_agent, _input), do: {:error, Error.new(:invalid, "A trigger is removed by its name")}

  @impl Wardrik.Catalog.Entry
  def labels(_answer), do: []

  @impl Wardrik.AgentOperation
  def subject(%__MODULE__{agent: id}), do: id

  @impl Wardrik.AgentOperation
  def action, do: :define

  @impl Wardrik.Command
  def plan(%__MODULE__{} = request, _caller), do: {:ok, Change.new(request)}

  @impl Wardrik.Command
  def make(%Change{request: %__MODULE__{agent: id, name: name}} = change, caller) do
    case Wardrik.Definition.delete_trigger(Host.definitions(caller.host), id, name) do
      :ok -> {:ok, nil, change.effect}
      {:error, :not_found} -> {:error, Error.new(:not_found, "#{id} has no trigger #{name}.")}
      {:error, :conflict, message} -> {:error, Error.new(:conflict, message)}
      :unsupported -> {:error, Error.new(:unsupported, "This server keeps no triggers.")}
    end
  end

  defimpl Wardrik.Effect do
    def preview(%{agent: id, name: name}),
      do: %{"removing" => %{"agent" => to_string(id), "trigger" => name}}

    def audit(%{agent: id, name: name}), do: [{:trigger_removed, id, name}]
  end
end
