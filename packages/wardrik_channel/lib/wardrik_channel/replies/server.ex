defmodule WardrikChannel.Replies.Server do
  @moduledoc """
  The process behind one room's `WardrikChannel.Replies`: it subscribes to
  the log of each thread's agent, and posts what each new event asks for,
  writing down how far it has posted.

  Started by `WardrikChannel.Replies.follow/4` under the supervisor
  `WardrikChannel.Replies` runs.
  """

  use DurableServer, vsn: 1

  require Logger

  alias Wardrik.Agent
  alias Wardrik.AgentID
  alias Wardrik.Event.Log
  alias Wardrik.Event.Log.Entry
  alias WardrikChannel.Context
  alias WardrikChannel.Outbound
  alias WardrikChannel.Replies.State
  alias WardrikNotify.Notice

  @first_backoff 1_000
  @max_backoff 60_000
  @attempts 8

  @source "wardrik://local/agents/"

  @impl DurableServer
  def dump_state(%State{} = state), do: state |> Map.from_struct() |> Map.delete(:retries)

  @impl DurableServer
  def load_state(_old_vsn, dumped), do: struct!(State, dumped)

  # DurableServer's callback type leaves out the continue its server takes
  # from `init`.
  @dialyzer {:nowarn_function, init: 1}
  @impl DurableServer
  def init(%State{} = state), do: {:ok, state, {:continue, :open}, permanent: true}

  @impl DurableServer
  def handle_continue(:open, state) do
    Enum.each(state.threads, fn {_thread, followed} -> :ok = Log.subscribe(followed.agent) end)
    {:noreply, Enum.reduce(Map.keys(state.threads), state, &advance(&2, &1)), sync: true}
  end

  # The log is subscribed to before its head is read, so nothing written
  # after the head is missed.
  @impl DurableServer
  def handle_call({:follow, thread, %AgentID{} = agent}, _from, state) do
    if State.followed?(state, thread) do
      {:reply, :ok, state}
    else
      :ok = Log.subscribe(agent)
      head = Log.head(agent, Log.oldest(agent, consistent: true) - 1)
      {:reply, :ok, State.follow(state, thread, agent, head), sync: true}
    end
  end

  @impl DurableServer
  def handle_info(%Entry{sequence: nil}, state), do: {:noreply, state}

  def handle_info(%Entry{event: %{"source" => @source <> id}, sequence: sequence}, state) do
    with {:ok, agent} <- AgentID.parse(id),
         thread when is_binary(thread) <- State.thread_of(state, agent),
         true <- sequence > state.threads[thread].through,
         false <- Map.has_key?(state.retries, thread) do
      {:noreply, advance(state, thread), sync: true}
    else
      _behind_or_waiting -> {:noreply, state}
    end
  end

  def handle_info({:retry, thread}, state) do
    if State.followed?(state, thread),
      do: {:noreply, advance(state, thread), sync: true},
      else: {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Posts what the thread's log holds past what has been posted, until it
  # ends or a post is refused.
  defp advance(state, thread) do
    followed = state.threads[thread]

    case Log.read(followed.agent, starting_after: followed.through) do
      {:gap, oldest} -> advance(State.skip(state, thread, oldest), thread)
      {:ok, []} -> state
      {:ok, events} -> posted(state, thread, events)
    end
  end

  defp posted(state, thread, []), do: advance(state, thread)

  defp posted(state, thread, [event | rest]) do
    {post, next} = State.take(state, thread, event)

    case post(state, thread, post) do
      :ok ->
        posted(%{next | retries: Map.delete(next.retries, thread)}, thread, rest)

      {:error, reason} ->
        attempt = Map.get(state.retries, thread, 0) + 1

        if attempt >= @attempts do
          Logger.warning(
            "#{state.channel} gave up posting in #{state.room} after #{attempt} attempts: " <>
              inspect(reason)
          )

          posted(%{next | retries: Map.delete(next.retries, thread)}, thread, rest)
        else
          backoff = min(@first_backoff * Integer.pow(2, attempt - 1), @max_backoff)
          Process.send_after(self(), {:retry, thread}, backoff)
          %{state | retries: Map.put(state.retries, thread, attempt)}
        end
    end
  end

  defp post(_state, _thread, :none), do: :ok

  defp post(state, thread, {:reply, text, answering}),
    do: deliver(state, thread, {:reply, text, answering})

  defp post(state, thread, {:failed, reason}) do
    agent = state.threads[thread].agent
    notice = %Notice{agent: agent, kind: :failed, at: DateTime.utc_now(), reason: reason}
    deliver(state, thread, {:notice, notice})
  end

  # The calls are read from the agent as they are posted, and only those
  # still waiting are: the log does not say what a call asks.
  defp post(state, thread, {:parked, ids}) do
    agent = state.threads[thread].agent

    with parked when is_list(parked) <- Agent.parked(agent),
         [_ | _] = calls <- Enum.filter(parked, fn {call, _prompt} -> call.id in ids end) do
      deliver(state, thread, {:notice, Notice.parked(agent, calls)})
    else
      _none_waiting -> :ok
    end
  end

  defp deliver(state, thread, body) do
    case WardrikChannel.channel(state.channel) do
      {:ok, {adapter, options, context}} ->
        outbound = %Outbound{
          room: state.room,
          thread: thread,
          body: body,
          approvers: Context.approvers(context)
        }

        with {:ok, _posted} <- adapter.deliver(outbound, options), do: :ok

      :error ->
        {:error, :unknown_channel}
    end
  end
end
