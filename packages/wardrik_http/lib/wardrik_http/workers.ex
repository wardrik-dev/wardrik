defmodule WardrikHTTP.Workers do
  @moduledoc """
  Tools that run in other processes, offered by tool workers: programs that
  hold a WebSocket to `GET /v1/workers` open and answer calls over it as MCP
  servers do (see `WardrikHTTP.Worker`).

  It is a `Wardrik.Tool` source, named with the ID of the agent it serves:

      Wardrik.LLM.Config.new(tools: [{WardrikHTTP.Workers, id}])

  An agent file or definition names it as `workers/*`. The agent is offered
  the tools of every connected worker whose token may `:serve` it, each named
  `workers__<name>`, as an MCP server's tools are named for their server, so
  a policy governs them as `workers/*` or `workers/refund_order`.

  A tool is bound to the token that offers it. Workers under one token that
  offer a tool of the same name are one pool, and a call goes to any of
  them. Where workers under another token offer that name to the same agent,
  the agent is offered the tool of the token whose worker connected first,
  and the others are refused, so a second token can neither take a share of
  the calls nor change what the model is told the tool does. Their offer is
  logged.

  A call says whose it is: `_meta.agent` is the agent it is made for, as the
  ID the worker's token was checked against, with its `org`, its `user`
  where it works for one, and its `name`:

      {"key": "acme/@jon/assistant", "org": "acme", "user": "jon", "name": "assistant"}

  Wardrik writes it, never the model, so a worker serving many agents can
  answer each with what is theirs alone. A call made in a turn also carries
  the turn's run, as `_meta.run`, the id its events carry, and its
  `Wardrik.Ledger.idempotency_key/2` as `_meta.idempotencyKey`. It waits for
  the worker's answer for `WardrikHTTP.Config.worker_timeout/0`. A call's
  events name the token whose worker answered it.

  A worker gone before it answers, or one that answers late, leaves its call
  in doubt, since it may already have done what it does. Such a call runs
  again under the same key on a worker connected then, where every worker in
  the agent's reach that offers the tool marks it `readOnlyHint` or
  `idempotentHint`, and waits for a person otherwise, as a call that began
  before its agent was lost does; see `Wardrik.Call.Pipeline`. A call the
  agent stops, by `Wardrik.LLM.ToolRunner.kill_call/2`, its turn's deadline or
  the turn ending, is cancelled at its worker; see `WardrikHTTP.Worker`.

  A worker's tool is gated unless every worker offering it marks it
  `readOnlyHint`, as a client of an MCP server asks before a tool that may
  change something: a call to one waits on a person unless a hook allows it
  by name.

  The group of workers is a child the host starts after Wardrik and
  `WardrikHTTP.Access` in its own tree, and before `WardrikHTTP.Listener`:

      children = [Wardrik, WardrikHTTP.Access, WardrikHTTP.Workers]
  """

  @behaviour Wardrik.Tool

  require Logger

  alias Wardrik.AgentID
  alias Wardrik.Tool.Result
  alias WardrikHTTP.Access
  alias WardrikHTTP.Token
  alias WardrikHTTP.Worker.Tool

  @group "workers"
  @prefix "workers__"

  @doc false
  def child_spec(_opts), do: Group.child_spec(name: __MODULE__)

  @doc """
  Offers `tools` from the calling process, a worker's socket holding `token`
  that connected at `since`, in microseconds of system time, in place of
  what it offered before, until it exits.
  """
  @spec offer(Token.t(), [Tool.t()], integer()) :: :ok
  def offer(%Token{} = token, tools, since) when is_list(tools) and is_integer(since) do
    _ = Group.leave(__MODULE__, @group)
    contested(token, tools)
    Group.join(__MODULE__, @group, %{token: token, tools: tools, since: since})
  end

  defp contested(token, tools) do
    names = MapSet.new(tools, & &1.name)

    for {_worker, %{token: other, tools: offered}} <- Group.members(__MODULE__, @group),
        other.id != token.id,
        %Tool{name: name} <- offered,
        name in names,
        uniq: true do
      Logger.warning(
        "A worker under token #{token.name} offers #{name}, which token #{other.name} offers too. " <>
          "An agent both reach is offered the one whose worker connected first."
      )
    end
  end

  @doc "The tools the connected workers offer the agent `id`, one of each name."
  @impl Wardrik.Tool
  def tools(%AgentID{} = id) do
    id
    |> offered()
    |> Enum.uniq_by(& &1.tool.name)
    |> Enum.map(&build(&1.tool, id))
  end

  @doc """
  What holds for a worker's tool, from what the workers in reach of the agent
  `id` is offered say of it: a call waits on a person unless a hook
  allows it by name, unless every one marks the tool read-only, since
  anything else a worker does may change something; a call in doubt runs
  again where every one marks it read-only or idempotent; its answers are
  labelled `"outside"` unless `WardrikHTTP.Config.trusted_workers?/0` says
  workers are the deployment's own, since a worker can pass on anything it
  reads; and a call may take the worker's wait twice, once more in doubt,
  and a little.
  """
  @impl Wardrik.Tool
  def annotations(%AgentID{} = id, @prefix <> name) do
    offered = for %{tool: tool} <- offered(id), tool.name == name, do: tool

    %{
      gated: offered == [] or not Enum.all?(offered, & &1.read_only),
      in_doubt:
        if(offered != [] and Enum.all?(offered, &(&1.in_doubt == :rerun)), do: :rerun, else: :ask),
      labels: workers_labels(),
      timeout: 2 * WardrikHTTP.Config.worker_timeout() + :timer.seconds(5)
    }
  end

  def annotations(_id, _name),
    do: %{gated: true, labels: workers_labels()}

  defp workers_labels, do: if(WardrikHTTP.Config.trusted_workers?(), do: [], else: ["outside"])

  @doc false
  @spec call(AgentID.t(), String.t(), map(), Wardrik.Tool.Context.t()) :: Result.t()
  def call(%AgentID{} = id, name, input, %Wardrik.Tool.Context{} = context) do
    case for(%{tool: %Tool{name: ^name}} = offer <- offered(id), do: offer) do
      [] -> none(name, context)
      offers -> ask(Enum.random(offers), name, input, meta(id, context))
    end
  end

  defp none(name, %Wardrik.Tool.Context{in_doubt: true}),
    do: {:in_doubt, "No worker offers #{name} now to run it again."}

  defp none(name, %Wardrik.Tool.Context{}),
    do: Result.error(:no_worker, "No worker offers #{name} now, so it did not run.")

  defp ask(%{worker: worker, token: token}, name, input, meta) do
    served = %{id: token.id, name: token.name}
    ref = Process.monitor(worker)
    send(worker, {:call, self(), ref, name, input, meta})

    receive do
      {^ref, {:ok, result}} ->
        Process.demonitor(ref, [:flush])
        {:ok, result, served_by: served}

      {:DOWN, ^ref, :process, _pid, _reason} ->
        {:in_doubt, "The worker running #{name} went away before it answered.", served_by: served}
    after
      WardrikHTTP.Config.worker_timeout() ->
        Process.demonitor(ref, [:flush])
        send(worker, {:cancel, ref})
        {:in_doubt, "#{name} did not answer in time.", served_by: served}
    end
  end

  defp meta(id, %Wardrik.Tool.Context{scope: scope, idempotency_key: idempotency_key}) do
    %{
      "agent" => agent(id),
      "run" => scope.source.trace.trace_id,
      "idempotencyKey" => idempotency_key
    }
  end

  defp agent(%AgentID{org: org, user: user, name: name} = id) do
    Map.reject(
      %{"key" => to_string(id), "org" => org, "user" => user, "name" => name},
      &is_nil(elem(&1, 1))
    )
  end

  # What the workers in reach of the agent `id` offer it: each tool under the
  # token whose worker offering it connected first.
  defp offered(id) do
    offers =
      for {worker, %{token: token, tools: tools, since: since}} <-
            Group.members(__MODULE__, @group),
          Access.authorize(token.grant, :serve, id) == :ok,
          tool <- tools,
          do: %{worker: worker, token: token, tool: tool, since: since}

    owners =
      offers
      |> Enum.group_by(& &1.tool.name)
      |> Map.new(fn {name, offers} -> {name, Enum.min_by(offers, &{&1.since, &1.token.id})} end)

    Enum.filter(offers, &(owners[&1.tool.name].token.id == &1.token.id))
  end

  defp build(%Tool{} = tool, id) do
    Wardrik.Tool.new!(
      name: @prefix <> tool.name,
      description: (tool.description || tool.name) <> "\n\nFrom a tool worker.",
      parameter_schema: tool.input_schema,
      run: {__MODULE__, :call, [id, tool.name]}
    )
  end
end
