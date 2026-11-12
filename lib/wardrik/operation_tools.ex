defmodule Wardrik.OperationTools do
  @moduledoc """
  Tools made from Wardrik's operations, so an agent can look into and run the deployment.

      tools: ["agents/*", "ops/read", "ops/agent.stop", "ops/deployment.reload"]

    * `ops/read` gives every operation that only reads, such as `agent_runs`, `agent_resolved`,
      `audit_list`, `interrupts_list` and `deployment_runtime`. It leaves out the reads
      `agents/*` gives (`agents_list`, `agent_read` and the definition), and streams.
    * `ops/ID` gives one operation, such as `ops/agent.runs` or `ops/agent.stop`. Name only the
      ones an agent needs: each tool's description and schema go into every model call.

  Each tool is named after its operation, with `_` for `.`: `agent.runs` is `agent_runs`. Its
  arguments are the operation's input.

    * Each acts for the agent's resolved principal, with actor `{:agent, id}`. Your authorizer
      decides, as for `Wardrik.run/3`. An agent with no principal can use none of them.
    * Changes are gated: they ask a person unless the policy allows them by name.
    * Approving, denying and deciding calls are never tools. A person decides them.
    * Defining agents, their triggers and messages to them are `agents/*` tools. See
      `Wardrik.AgentTools`.
  """

  @behaviour WardrikCore.Capability

  alias WardrikCore.Tool

  # Operations agents/* gives, with its own rules.
  @agent_tools ~w(agents.list agent.read agent.definition agent.define agent.trigger_set
                  agent.trigger_remove agent.ask)

  # A person decides calls, and outside callers deliver hooks and chat messages.
  @never ~w(agent.decide agent.approve agent.deny hook.deliver hook.deliver_with_secret
            channel.deliver)

  @doc "Returns whether `id` names an operation an agent may be given as `ops/ID`."
  @spec offered?(String.t()) :: boolean()
  def offered?(id) do
    case WardrikProtocol.operation(id) do
      %{stream: false} -> id not in @agent_tools and id not in @never
      _none -> false
    end
  end

  @impl WardrikCore.Capability
  def tools(%WardrikCore.Context{agent_id: id, principal: principal}, opts) do
    me = %{wardrik: Keyword.fetch!(opts, :wardrik), id: id, principal: principal}

    opts |> Keyword.fetch!(:operations) |> operations() |> Enum.map(&tool(me, &1))
  end

  defp operations(:read),
    do:
      for(
        %{effect: "read", id: id} = operation <- WardrikProtocol.operations(),
        offered?(id),
        do: operation
      )

  defp operations(id), do: [WardrikProtocol.operation(id)]

  defp tool(me, operation) do
    Tool.new!(
      name: String.replace(operation.id, ".", "_"),
      description: described(operation),
      schema: operation.input,
      run: fn args, _context -> run(me, operation.id, args) end,
      annotations: annotations(operation.effect)
    )
  end

  defp described(%{summary: summary, description: nil}), do: summary <> "."

  defp described(%{summary: summary, description: description}),
    do: summary <> ". " <> description

  defp annotations("read"), do: [read_only: true, idempotent: true]
  defp annotations("destructive"), do: [gated: true, destructive: true]
  defp annotations("change"), do: [gated: true]

  defp run(%{principal: nil, id: id}, _operation, _input),
    do: {:error, "#{id} acts for no one, so it can't run operations."}

  defp run(me, operation, input) do
    scope = Wardrik.as(me.wardrik, me.principal, actor: {:agent, me.id})

    case Wardrik.run(scope, operation, input) do
      {:ok, nil} -> {:ok, %{"ok" => true}}
      {:ok, output} -> {:ok, output}
      {:error, error} -> {:error, error.message}
    end
  end
end
