defmodule Wardrik.Operations.Define do
  @moduledoc """
  Defines an agent, or defines it again: the host's `Wardrik.Definition`
  reads `definition` into a spec, which runs under the caller's ceiling
  ahead of its own hooks. The answer is the agent's snapshot, `:created`
  where it did not run before.
  """

  @behaviour Wardrik.AgentOperation
  @behaviour Wardrik.Command

  require Logger

  alias Wardrik.Agent
  alias Wardrik.Change
  alias Wardrik.Definition
  alias Wardrik.Error
  alias Wardrik.Fleet
  alias Wardrik.Grant
  alias Wardrik.Resource

  @enforce_keys [:agent, :definition]
  defstruct [:agent, :definition]

  @type t() :: %__MODULE__{agent: Wardrik.AgentID.t(), definition: map()}

  @impl Wardrik.AgentOperation
  def subject(%__MODULE__{agent: id}), do: id

  @impl Wardrik.AgentOperation
  def action, do: :define

  @impl Wardrik.Command
  def plan(%__MODULE__{agent: id} = request, _caller) do
    with {:ok, _module} <- definitions(),
         do: {:ok, Change.new(request, [{:agent_defined, id}])}
  end

  @impl Wardrik.Command
  def make(%Change{request: %__MODULE__{agent: id, definition: fields}}, caller) do
    with {:ok, module} <- definitions(),
         {:ok, spec} <- read(module, id, fields, caller.grant) do
      if spec.id != id,
        do: raise(ArgumentError, "#{inspect(module)} wrote a spec for #{spec.id}, not #{id}")

      run(%{spec | hooks: Grant.held(caller.grant, spec.hooks)})
    end
  end

  defp definitions do
    case Definition.module(:put) do
      {:ok, module} -> {:ok, module}
      :unsupported -> {:error, Error.new(:unsupported, "This server does not define agents.")}
    end
  end

  defp read(module, id, fields, grant) do
    case module.put(id, fields, grant) do
      {:ok, spec} -> {:ok, spec}
      {:error, :conflict, message} -> {:error, Error.new(:conflict, message)}
      {:error, message} -> {:error, Error.new(:invalid, message)}
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
end
