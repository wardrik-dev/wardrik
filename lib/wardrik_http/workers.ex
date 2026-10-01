defmodule WardrikHTTP.Workers do
  @moduledoc """
  Tools that run in other processes, offered by tool workers: programs that
  hold a WebSocket to `GET /v1/workers` open and answer calls over it as MCP
  servers do (see `WardrikHTTP.Worker`).

  It is a `Wardrik.Tool` source, named with the key of the agent it serves:

      Wardrik.LLM.Config.new(tools: [{WardrikHTTP.Workers, "acme/triage"}])

  An agent file or definition names it as `workers/*`. The agent is offered
  the tools of every connected worker whose token may `:serve` it, each named
  `workers__<name>`, as an MCP server's tools are named for their server, so
  a policy governs them as `workers/*` or `workers/refund_order`. Workers that
  offer a tool of the same name are one pool, and a call goes to any of them.

  A call carries its `Wardrik.Ledger.idempotency_key/2` as
  `_meta.idempotencyKey`, and waits for the worker's answer for
  `WardrikHTTP.Config.worker_timeout/0`. A worker gone before it answers, or one
  that answers late, fails the call, and the model is told it may already
  have done what it does. A call that began before its agent was lost runs
  again under the same key where every worker in the agent's reach that
  offers the tool marks it `readOnlyHint` or `idempotentHint`, and waits for a
  person otherwise; see `c:Wardrik.Tool.in_doubt/2`.

  The group of workers is a child the host starts before `WardrikHTTP.Listener`:

      children = [WardrikHTTP.Workers, WardrikHTTP.Listener]
  """

  @behaviour Wardrik.Tool

  alias Wardrik.Access
  alias Wardrik.Tool.Result
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

  @doc "The tools the connected workers offer the agent under `key`, one of each name."
  @impl Wardrik.Tool
  def tools(key) when is_binary(key) do
    key
    |> offered()
    |> Enum.uniq_by(fn {_worker, tool} -> tool.name end)
    |> Enum.map(fn {_worker, tool} -> build(tool, key) end)
  end

  @doc "How long a batch holding a call to a worker may take: the worker's wait, and a little."
  @impl Wardrik.Tool
  def timeout, do: WardrikHTTP.Config.worker_timeout() + :timer.seconds(5)

  @doc """
  `:rerun` for a tool that every worker in reach of the agent under `key`
  offering it marks read-only or idempotent, `:ask` otherwise.
  """
  @impl Wardrik.Tool
  def in_doubt(key, @prefix <> name) when is_binary(key) do
    case for({_worker, tool} <- offered(key), tool.name == name, do: tool.in_doubt) do
      [] -> :ask
      answers -> if Enum.all?(answers, &(&1 == :rerun)), do: :rerun, else: :ask
    end
  end

  def in_doubt(_key, _name), do: :ask

  @doc """
  Whether what a worker's tool answers is content from outside: unless
  `WardrikHTTP.Config.trusted_workers?/0` says workers are the deployment's
  own, since a worker can pass on anything it reads.
  """
  @impl Wardrik.Tool
  def outside_content?(_key, _name), do: not WardrikHTTP.Config.trusted_workers?()

  @doc false
  @spec call(String.t(), String.t(), Wardrik.Call.t()) :: Wardrik.Call.t()
  def call(key, name, %Wardrik.Call{} = call) do
    case for({worker, tool} <- offered(key), tool.name == name, do: worker) do
      [] -> Result.error(:no_worker, "No worker offers #{name} now, so it did not run.")
      workers -> ask(Enum.random(workers), name, call)
    end
    |> then(&Wardrik.Call.answer(call, &1))
  end

  defp ask(worker, name, call) do
    ref = Process.monitor(worker)
    send(worker, {:call, self(), ref, name, call.target.arguments, meta(call)})

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

  # A call outside a turn has no key to be idempotent under.
  defp meta(%Wardrik.Call{scope: nil}), do: %{}
  defp meta(call), do: %{"idempotencyKey" => Wardrik.Ledger.idempotency_key(call)}

  defp offered(key) do
    for {worker, %{token: token, tools: tools}} <- Group.members(__MODULE__, @group),
        Access.authorize(token.grant, :serve, key) == :ok,
        tool <- tools,
        do: {worker, tool}
  end

  defp build(%Tool{} = tool, key) do
    Wardrik.Tool.new!(
      name: @prefix <> tool.name,
      description: (tool.description || tool.name) <> "\n\nFrom a tool worker.",
      parameter_schema: tool.input_schema,
      call: {__MODULE__, :call, [key, tool.name]}
    )
  end
end
