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
  a policy governs them as `workers/*` or `workers/refund_order`. Workers that
  offer a tool of the same name are one pool, and a call goes to any of them.

  A call says whose it is: `_meta.agent` is the agent it is made for, as the
  ID the worker's token was checked against, with its `org`, its `user`
  where it works for one, and its `name`:

      {"key": "acme/@jon/assistant", "org": "acme", "user": "jon", "name": "assistant"}

  Wardrik writes it, never the model, so a worker serving many agents can
  answer each with what is theirs alone. A call made in a turn also carries
  the turn's run, as `_meta.run`, the id its events carry, and its
  `Wardrik.Ledger.idempotency_key/2` as `_meta.idempotencyKey`. It waits for
  the worker's answer for `WardrikHTTP.Config.worker_timeout/0`. A worker gone before it answers, or one
  that answers late, fails the call, and the model is told it may already
  have done what it does. A call that began before its agent was lost runs
  again under the same key where every worker in the agent's reach that
  offers the tool marks it `readOnlyHint` or `idempotentHint`, and waits for a
  person otherwise; see `Wardrik.Tool.Annotations`.

  A worker's tool is gated unless every worker offering it marks it
  `readOnlyHint`, as a client of an MCP server asks before a tool that may
  change something: a call to one waits on a person unless a hook allows it
  by name.

  The group of workers is a child the host names among core's, with
  `WardrikHTTP.Access`, and starts before `WardrikHTTP.Listener`:

      config :wardrik, :children, [WardrikHTTP.Access, WardrikHTTP.Workers]
  """

  @behaviour Wardrik.Tool

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
  Offers `tools` from the calling process, a worker's socket holding `token`,
  in place of what it offered before, until it exits.
  """
  @spec offer(Token.t(), [Tool.t()]) :: :ok
  def offer(%Token{} = token, tools) when is_list(tools) do
    _ = Group.leave(__MODULE__, @group)
    Group.join(__MODULE__, @group, %{token: token, tools: tools})
  end

  @doc "The tools the connected workers offer the agent `id`, one of each name."
  @impl Wardrik.Tool
  def tools(%AgentID{} = id) do
    id
    |> offered()
    |> Enum.uniq_by(fn {_worker, tool} -> tool.name end)
    |> Enum.map(fn {_worker, tool} -> build(tool, id) end)
  end

  @doc """
  What holds for a worker's tool, from what the workers in reach of the agent
  `id` is offered say of it: a call waits on a person unless a hook
  allows it by name, unless every one marks the tool read-only, since
  anything else a worker does may change something; a call in doubt runs
  again where every one marks it read-only or idempotent; its answers are
  content from outside unless `WardrikHTTP.Config.trusted_workers?/0` says
  workers are the deployment's own, since a worker can pass on anything it
  reads; and a call may take the worker's wait, and a little.
  """
  @impl Wardrik.Tool
  def annotations(%AgentID{} = id, @prefix <> name) do
    offered = for {_worker, tool} <- offered(id), tool.name == name, do: tool

    %{
      gated: offered == [] or not Enum.all?(offered, & &1.read_only),
      in_doubt:
        if(offered != [] and Enum.all?(offered, &(&1.in_doubt == :rerun)), do: :rerun, else: :ask),
      outside: not WardrikHTTP.Config.trusted_workers?(),
      timeout: WardrikHTTP.Config.worker_timeout() + :timer.seconds(5)
    }
  end

  def annotations(_id, _name),
    do: %{gated: true, outside: not WardrikHTTP.Config.trusted_workers?()}

  @doc false
  @spec call(AgentID.t(), String.t(), map(), Wardrik.Tool.Context.t()) :: Result.t()
  def call(%AgentID{} = id, name, input, %Wardrik.Tool.Context{} = context) do
    case for({worker, tool} <- offered(id), tool.name == name, do: worker) do
      [] -> Result.error(:no_worker, "No worker offers #{name} now, so it did not run.")
      workers -> ask(Enum.random(workers), name, input, meta(id, context))
    end
  end

  defp ask(worker, name, input, meta) do
    ref = Process.monitor(worker)
    send(worker, {:call, self(), ref, name, input, meta})

    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, _pid, _reason} ->
        Result.error(
          :worker_gone,
          "The worker running #{name} went away before it answered, " <>
            "and may already have done what it does."
        )
    after
      WardrikHTTP.Config.worker_timeout() ->
        Process.demonitor(ref, [:flush])
        send(worker, {:cancel, ref})

        Result.error(
          :timeout,
          "#{name} did not answer in time, and may already have done what it does."
        )
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

  defp offered(id) do
    for {worker, %{token: token, tools: tools}} <- Group.members(__MODULE__, @group),
        Access.authorize(token.grant, :serve, id) == :ok,
        tool <- tools,
        do: {worker, tool}
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
