defmodule Wardrik.Operations.Define do
  @moduledoc """
  Defines an agent, or defines it again: the host's `Wardrik.Definition`
  reads `definition` into a spec, which runs under the caller's ceiling
  ahead of its own hooks. The answer is the agent's snapshot, `:created`
  where it did not run before.
  """

  @behaviour Wardrik.AgentOperation
  @behaviour Wardrik.Catalog.Entry
  @behaviour Wardrik.Command

  require Logger

  alias Wardrik.Agent
  alias Wardrik.Change
  alias Wardrik.Error
  alias Wardrik.Fleet
  alias Wardrik.Grant
  alias Wardrik.Host
  alias Wardrik.Resource

  @enforce_keys [:agent, :definition]
  defstruct [:agent, :definition]

  @type t() :: %__MODULE__{agent: Wardrik.AgentID.t(), definition: map()}

  @impl Wardrik.Catalog.Entry
  def name, do: "agent.define"

  @impl Wardrik.Catalog.Entry
  def summary,
    do:
      "Define the agent with a whole definition: what it is for, its instructions, model, " <>
        "tools and triggers. An agent defined already is given the new definition in place " <>
        "of its old one, and one that does not run yet starts."

  @impl Wardrik.Catalog.Entry
  def input, do: WardrikProtocol.schema("input_agent_define")

  @impl Wardrik.Catalog.Entry
  def new(%Wardrik.AgentID{} = agent, %{"definition" => %{} = definition}),
    do: {:ok, %__MODULE__{agent: agent, definition: definition}}

  def new(_agent, _input),
    do: {:error, Error.new(:invalid, "An agent is defined with its definition")}

  @impl Wardrik.Catalog.Entry
  def labels(%{"labels" => labels}), do: labels

  @impl Wardrik.AgentOperation
  def subject(%__MODULE__{agent: id}), do: id

  @impl Wardrik.AgentOperation
  def action, do: :define

  @impl Wardrik.Command
  def plan(%__MODULE__{} = request, _caller), do: {:ok, Change.new(request)}

  @impl Wardrik.Command
  def make(%Change{request: %__MODULE__{agent: id, definition: fields}} = change, caller) do
    module = Host.definitions(caller.host)

    with {:ok, spec} <- read(caller.host, id, fields, caller.grant) do
      if spec.id != id,
        do: raise(ArgumentError, "#{inspect(module)} wrote a spec for #{spec.id}, not #{id}")

      with {result, snapshot} <- run(%{spec | hooks: Grant.held(caller.grant, spec.hooks)}),
           do: {result, snapshot, change.effect}
    end
  end

  defp read(host, id, fields, grant) do
    case Host.definitions(host).put(host, id, fields, grant) do
      {:ok, spec} -> {:ok, spec}
      {:error, :conflict, message} -> {:error, Error.new(:conflict, message)}
      {:error, message} -> {:error, Error.new(:invalid, message)}
      :unsupported -> {:error, Error.new(:unsupported, "This server does not define agents.")}
    end
  end

  defp run(spec) do
    created = Fleet.lookup(spec.id) == nil

    case Fleet.put(spec) do
      {:ok, _pid} ->
        {if(created, do: :created, else: :ok),
         Resource.snapshot(spec.id, Agent.snapshot(spec.id))}

      {:error, reason} ->
        Logger.warning("#{spec.id} did not start: #{inspect(reason)}")
        {:error, Error.new(:unavailable, "#{spec.id} did not start.")}
    end
  end

  defimpl Wardrik.Effect do
    def preview(%{agent: id, definition: definition}),
      do: %{"defining" => %{"agent" => to_string(id), "definition" => definition}}

    def audit(%{agent: id}), do: [{:agent_defined, id}]
  end
end
