defmodule Wardrik.Catalog.Tools do
  @moduledoc """
  The catalog's operations on an agent, offered to that agent as tools, so
  it can read and change itself as any surface could: see its definition,
  and set and remove its own triggers. A tool source, named with the
  agent's ID:

      Wardrik.LLM.Config.new(tools: [{Wardrik.Catalog.Tools, ~A"acme/watch"}])

  Each operation of `Wardrik.Catalog` is a tool named for it, `.` written
  `_`, as `agent_trigger_set`, described by its summary, taking its input.
  A call builds the operation's request of the agent, its conversation's
  agent where a conversation calls it, and runs it as the agent itself, a
  `:agent` principal granted only to read and change that agent, through
  `Wardrik.Query` or `Wardrik.Command`, as every surface does: the audit
  records the agent as who made a change, and an agent another surface
  declares, as a file does, answers as it would there. A change is gated,
  so it waits on a person unless the agent's policy allows it.
  """

  @behaviour Wardrik.Tool

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Caller
  alias Wardrik.Catalog
  alias Wardrik.Command
  alias Wardrik.Error
  alias Wardrik.Grant
  alias Wardrik.Principal
  alias Wardrik.Query
  alias Wardrik.Resource

  @impl Wardrik.Tool
  def tools(%AgentID{} = agent) do
    for {module, runner} <- operations(),
        do: tool(module, runner, AgentID.put_external_id(agent, nil))
  end

  @impl Wardrik.Tool
  def annotations(%AgentID{}, name) do
    if name in Enum.map(Catalog.agent_commands(), &tool_name/1),
      do: %{gated: true},
      else: %{}
  end

  defp operations do
    Enum.map(Catalog.agent_queries(), &{&1, Query}) ++
      Enum.map(Catalog.agent_commands(), &{&1, Command})
  end

  defp tool(module, runner, agent) do
    Wardrik.Tool.new!(
      name: tool_name(module),
      description: module.summary(),
      parameter_schema: module.input(),
      run: {__MODULE__, :run, [module, runner, agent]}
    )
  end

  defp tool_name(module), do: String.replace(module.name(), ".", "_")

  @doc false
  @spec run(module(), module(), AgentID.t(), map(), Wardrik.Tool.Context.t()) ::
          {:ok, term()} | {:error, map()}
  def run(module, runner, agent, input, _context) do
    with {:ok, request} <- module.new(agent, input),
         {status, answer} when status in [:ok, :created] <- runner.run(request, caller(agent)) do
      {:ok, answer || "done"}
    else
      {:error, %Error{} = error} -> {:error, Resource.error(error)}
    end
  end

  defp caller(agent) do
    {:ok, grant} = Grant.new(Prefix.of(agent), [:read, :define])
    Caller.new(Principal.new(:agent, to_string(agent)), grant)
  end
end
