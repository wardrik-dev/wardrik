defmodule Wardrik.Operations.SetTrigger do
  @moduledoc """
  Sets one of an agent's triggers, as `wardrik_protocol`'s
  `trigger_definition.json` describes it. A trigger is part of the agent's
  definition, so the host's `Wardrik.Definition` sets it; the answer is the
  trigger, `:created` where the agent had none of that name.
  """

  @behaviour Wardrik.AgentOperation
  @behaviour Wardrik.Catalog.Entry
  @behaviour Wardrik.Command

  alias Wardrik.Change
  alias Wardrik.Error
  alias Wardrik.Host
  alias Wardrik.Operations.ReadDefinition

  @enforce_keys [:agent, :name, :fields]
  defstruct [:agent, :name, :fields]

  @type t() :: %__MODULE__{agent: Wardrik.AgentID.t(), name: String.t(), fields: map()}

  @impl Wardrik.Catalog.Entry
  def name, do: "agent.trigger.set"

  @impl Wardrik.Catalog.Entry
  def summary,
    do:
      "Set one of the agent's triggers, by name: when it is asked something, on a clock, " <>
        "from a feed, or by a webhook. A trigger of that name is replaced."

  @impl Wardrik.Catalog.Entry
  def input, do: WardrikProtocol.schema("input_agent_trigger_set")

  @impl Wardrik.Catalog.Entry
  def new(%Wardrik.AgentID{} = agent, %{"name" => name, "trigger" => %{} = fields})
      when is_binary(name),
      do: {:ok, %__MODULE__{agent: agent, name: name, fields: fields}}

  def new(_agent, _input),
    do: {:error, Error.new(:invalid, "A trigger is set with its name and the trigger")}

  @impl Wardrik.Catalog.Entry
  def labels(_answer), do: []

  @impl Wardrik.AgentOperation
  def subject(%__MODULE__{agent: id}), do: id

  @impl Wardrik.AgentOperation
  def action, do: :define

  @impl Wardrik.Command
  def plan(%__MODULE__{} = request, _caller), do: {:ok, Change.new(request)}

  @impl Wardrik.Command
  def make(%Change{request: %__MODULE__{agent: id, name: name, fields: fields}} = change, caller) do
    case Host.definitions(caller.host).put_trigger(id, name, fields) do
      {:ok, :created, trigger} -> {:created, %{"trigger" => trigger}, change.effect}
      {:ok, :changed, trigger} -> {:ok, %{"trigger" => trigger}, change.effect}
      {:error, :not_found} -> {:error, ReadDefinition.undefined(id)}
      {:error, :conflict, message} -> {:error, Error.new(:conflict, message)}
      {:error, message} -> {:error, Error.new(:invalid, message)}
      :unsupported -> {:error, Error.new(:unsupported, "This server keeps no triggers.")}
    end
  end

  defimpl Wardrik.Effect do
    def preview(%{agent: id, name: name, fields: fields}),
      do: %{"setting" => %{"agent" => to_string(id), "trigger" => Map.put(fields, "name", name)}}

    def audit(%{agent: id, name: name}), do: [{:trigger_set, id, name}]
  end
end
