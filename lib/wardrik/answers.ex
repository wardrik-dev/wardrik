defmodule Wardrik.Answers do
  @moduledoc """
  Follows the run that answers a message, from the agent's log: its text as it streams, and how it
  ends. It follows from before the message is sent, so it misses nothing.
  """

  alias Wardrik.Error
  alias Wardrik.Instance
  alias Wardrik.Operations.Types
  alias Wardrik.Reply
  alias Wardrik.Scope

  @ended ~w(wardrik.run.failed wardrik.run.cancelled wardrik.run.deadline_exceeded)
  @timeout :timer.minutes(10)

  @doc """
  Sends `input` to the agent, and returns what its answer brings, in order: `{:text, chunk}`, then
  `{:done, %Wardrik.Reply{}}`, `{:waiting, interrupts}` or `{:failed, reason}`.
  """
  @spec follow(Scope.t(), String.t() | struct(), term(), keyword()) :: Enumerable.t()
  def follow(scope, agent, input, opts) do
    id = Types.path(agent)
    timeout = Keyword.get(opts, :timeout, @timeout)

    Stream.resource(
      fn -> started(scope, id, agent, input) end,
      &next(&1, timeout),
      &stopped/1
    )
  end

  @doc "Sends `input` to the agent, and returns its answer once its run ends."
  @spec reply(Scope.t(), String.t() | struct(), term(), keyword()) ::
          {:ok, Reply.t()} | {:waiting, [Wardrik.Interrupt.t()]} | {:error, Error.t()}
  def reply(scope, agent, input, opts) do
    scope
    |> follow(agent, input, opts)
    |> Enum.reduce(nil, &ended/2)
  rescue
    error in Error -> {:error, error}
  end

  @doc "Sends what the agent's answer brings to `pid`, as `{Wardrik, ref, item}`, and returns `ref`."
  @spec send_to(Scope.t(), String.t() | struct(), term(), pid(), keyword()) :: {:ok, reference()}
  def send_to(scope, agent, input, pid, opts) do
    ref = make_ref()

    {:ok, _task} =
      Task.start(fn ->
        scope
        |> follow(agent, input, opts)
        |> Enum.each(&send(pid, {Wardrik, ref, &1}))
      end)

    {:ok, ref}
  end

  defp started(%Scope{wardrik: instance} = scope, id, agent, input) do
    events = instance |> Instance.fetch!() |> Wardrik.events()
    {:ok, _page} = allowed(Wardrik.Agent.events(scope, agent, limit: 1))
    :ok = WardrikEvents.subscribe(events, [id])

    case Wardrik.Agent.ask(scope, agent, input) do
      {:ok, message} ->
        %{events: events, agent: id, message: message.id, run: nil, text: [], done: false}

      {:error, error} ->
        :ok = WardrikEvents.unsubscribe(events, [id])
        raise error
    end
  end

  defp allowed({:ok, page}), do: {:ok, page}
  defp allowed({:error, error}), do: raise(error)

  defp next(%{done: true} = state, _timeout), do: {:halt, state}

  defp next(%{agent: agent} = state, timeout) do
    receive do
      {WardrikEvents, ^agent, event} -> seen(event, state)
    after
      timeout -> {[{:failed, :timeout}], %{state | done: true}}
    end
  end

  defp seen(%{"type" => "wardrik.run.started", "data" => %{"run" => run}}, %{run: nil} = state) do
    if state.message in Map.get(run, "message_ids", []),
      do: {[], %{state | run: run["id"]}},
      else: {[], state}
  end

  defp seen(event, %{run: run} = state) when is_binary(run) do
    if trace(event) == run, do: ours(event, state), else: {[], state}
  end

  defp seen(_event, state), do: {[], state}

  defp ours(%{"type" => "wardrik.message.delta", "data" => %{"delta" => text}}, state),
    do: {[{:text, text}], %{state | text: [state.text | text]}}

  defp ours(%{"type" => "wardrik.run.completed"}, state) do
    reply = %Reply{message: state.message, run: state.run, text: IO.iodata_to_binary(state.text)}
    {[{:done, reply}], %{state | done: true}}
  end

  defp ours(
         %{"type" => "wardrik.run.interrupted", "data" => %{"interrupts" => interrupts}},
         state
       ),
       do:
         {[{:waiting, Enum.map(interrupts, &Wardrik.Interrupt.from_json/1)}],
          %{state | done: true}}

  defp ours(%{"type" => type, "data" => data}, state) when type in @ended,
    do: {[{:failed, Map.get(data, "error", type)}], %{state | done: true}}

  defp ours(_event, state), do: {[], state}

  defp stopped(%{events: events, agent: agent}) do
    :ok = WardrikEvents.unsubscribe(events, [agent])
    flush(agent)
  end

  defp flush(agent) do
    receive do
      {WardrikEvents, ^agent, _event} -> flush(agent)
    after
      0 -> :ok
    end
  end

  defp trace(%{"traceparent" => "00-" <> rest}), do: rest |> String.split("-", parts: 2) |> hd()
  defp trace(_event), do: nil

  defp ended({:done, reply}, _acc), do: {:ok, reply}
  defp ended({:waiting, interrupts}, _acc), do: {:waiting, interrupts}

  defp ended({:failed, reason}, _acc),
    do: {:error, Error.new(:unavailable, "The run failed: #{inspect(reason)}")}

  defp ended({:text, _chunk}, acc), do: acc
end
