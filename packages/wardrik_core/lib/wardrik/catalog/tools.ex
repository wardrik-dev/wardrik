defmodule Wardrik.Catalog.Tools do
  @moduledoc """
  How `Wardrik.Catalog`'s operations are offered to an agent as tools, by two
  tool sources, each named with the agent's ID:

  | Source | Offers | On |
  | --- | --- | --- |
  | `Wardrik.Catalog.Self` | the operations on an agent, as `self_trigger_set` | the agent itself |
  | `Wardrik.Catalog.Agents` | the operations on an agent, as `agent_trigger_set`, taking the `agent` they act on, and those on the agents under a prefix, as `agents_list` | the agents of its org |

  Each tool is described by its operation's summary, and takes its input. A
  call builds the operation's request and runs it through `Wardrik.Query` or
  `Wardrik.Command`, as every surface does, as the calling agent, a caller
  made with `Wardrik.Caller.agent/1` on the host the call's scope carries:
  the audit records the agent as who made
  a change, an agent another surface declares, as a file does, answers as it
  would there, and an agent it sends a message answers it back with a
  message of its own (see `Wardrik.Operations.Ask`).

  The caller's grant lets it read, send messages to and define what its
  source reaches, and never more. Its ceiling is the calling agent's own
  hooks: an agent it defines is held to every policy and budget that holds
  the agent that defined it, ahead of its own, and so is never looser.

  A change is gated, so it waits on a person unless the agent's policy
  allows it by the tool's name. An answer that shows an agent's conversation
  labels the call with the labels of that agent's history (see
  `c:Wardrik.Catalog.Entry.labels/1`), so content from outside that one agent
  read is outside content to the agent that reads it.
  """

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Caller
  alias Wardrik.Catalog
  alias Wardrik.Catalog.Tools.Offering
  alias Wardrik.Command
  alias Wardrik.Error
  alias Wardrik.Grant
  alias Wardrik.Host
  alias Wardrik.Query
  alias Wardrik.Resource
  alias Wardrik.Scope

  @doc """
  The catalog's operations on an agent, offered to an agent reaching
  `reach`, queries then commands.
  """
  @spec agent_operations(Prefix.t()) :: [Offering.t()]
  def agent_operations(reach),
    do:
      offered(Catalog.agent_queries(), Query, reach) ++
        offered(Catalog.agent_commands(), Command, reach)

  @doc """
  The catalog's operations on the agents under a prefix, offered to an agent
  reaching `reach`.
  """
  @spec fleet_operations(Prefix.t()) :: [Offering.t()]
  def fleet_operations(reach), do: offered(Catalog.fleet_queries(), Query, reach)

  defp offered(modules, runner, reach),
    do: Enum.map(modules, &%Offering{module: &1, runner: runner, reach: reach})

  @doc """
  The annotations of the tool named `name`, where `commands` names a
  source's tools that change something: those wait on a person.
  """
  @spec annotations([String.t()], String.t()) :: map()
  def annotations(commands, name),
    do: if(name in commands, do: %{gated: true}, else: %{})

  @doc """
  The tool for `offering`'s operation, named `:name`, taking `:schema`,
  which `:run`, a `{module, function, args}`, answers.
  """
  @spec tool(Offering.t(), name: String.t(), schema: map(), run: {module(), atom(), list()}) ::
          ReqLLM.Tool.t()
  def tool(%Offering{module: module}, opts) do
    opts = Keyword.validate!(opts, [:name, :schema, :run])

    Wardrik.Tool.new!(
      name: Keyword.fetch!(opts, :name),
      description: module.summary(),
      parameter_schema: Keyword.fetch!(opts, :schema),
      run: Keyword.fetch!(opts, :run)
    )
  end

  @doc """
  Runs `offering`'s operation on `subject` with `:input`, for the call
  `:context` is of, as the calling agent: the tool's answer, labelled with
  what it holds.

  The agent may read, send messages to and define the agents its reach
  covers, under its own hooks as ceiling, on the host the call's scope
  carries. A read or a message is the asker's as well: where someone asked
  for the turn, it reaches only what both the agent and they may, as the
  host's `Wardrik.Grants` say of them, so an agent never reads or messages
  for someone what they could not themselves. A change is the agent's own,
  held to its ceiling and asked of a person as its policy says.
  """
  @spec run(Offering.t(), AgentID.t() | Prefix.t(),
          input: map(),
          context: Wardrik.Tool.Context.t()
        ) ::
          Wardrik.Tool.answer()
  def run(%Offering{module: module, runner: runner} = offering, subject, opts) do
    opts = Keyword.validate!(opts, [:input, :context])

    with {:ok, caller} <- caller(offering, subject, Keyword.fetch!(opts, :context)),
         {:ok, request} <- module.new(subject, Keyword.fetch!(opts, :input)),
         {status, answer} when status in [:ok, :created] <- runner.run(request, caller) do
      {:ok, answer || "done", labels: module.labels(answer)}
    else
      {:error, %Error{} = error} -> {:error, Resource.error(error)}
    end
  end

  defp caller(%Offering{module: module, reach: reach}, subject, context) do
    %Wardrik.Tool.Context{scope: scope, sender: sender} = context
    {:ok, own} = Grant.new(reach, [:read, :message, :define], scope.hooks)

    with {:ok, grant} <- asked(own, sender, subject, module.action(), scope.host),
         do: {:ok, Caller.agent(id: Scope.agent_id(scope), grant: grant, host: scope.host)}
  end

  # A turn nobody asked for is the agent's own.
  defp asked(own, nil, _subject, _action, _host), do: {:ok, own}

  defp asked(own, sender, subject, action, host) when action in [:read, :message] do
    with {:ok, %Caller{grant: theirs}} <- Host.caller(host, principal: sender, subject: subject) do
      case Grant.within(own, theirs) do
        {:ok, grant} -> {:ok, grant}
        :error -> {:error, Error.new(:forbidden, "Whoever asked may not #{action} #{subject}.")}
      end
    end
  end

  defp asked(own, _sender, _subject, _action, _host), do: {:ok, own}
end
