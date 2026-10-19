defmodule WardrikChannel.Replies.Server do
  @moduledoc """
  The process behind one room's `WardrikChannel.Replies`: it subscribes to
  the log of each thread's agent, and posts what each new event asks for,
  writing down how far it has posted, and shows what the agent is doing as
  its log says it changed.

  Started by `WardrikChannel.Replies.follow/3` under the supervisor
  `WardrikChannel.Replies` runs, which hands it the channels, and how it
  shows statuses, as it starts: it keeps its own `WardrikChannel.Channel` in
  memory, and writes none of it down. A room whose channel is not among
  them does not start.
  """

  use DurableServer, vsn: 1

  require Logger

  alias Wardrik.Agent
  alias Wardrik.Agent.Activity
  alias Wardrik.Agent.Activity.Presenter
  alias Wardrik.AgentID
  alias Wardrik.Event.Log
  alias Wardrik.Event.Log.Entry
  alias WardrikChannel.Channel
  alias WardrikChannel.Outbound
  alias WardrikChannel.Replies.State
  alias WardrikChannel.Workspace
  alias WardrikNotify.Notice

  @first_backoff 1_000
  @max_backoff 60_000
  @attempts 8

  @source "wardrik://local/agents/"

  @impl DurableServer
  def dump_state(%State{} = state),
    do: state |> Map.from_struct() |> Map.drop([:retries, :posting, :showing, :statuses])

  @impl DurableServer
  def load_state(_old_vsn, dumped), do: struct!(State, dumped)

  # DurableServer's callback type leaves out the continue its server takes
  # from `init`.
  @dialyzer {:nowarn_function, init: 2}
  @impl DurableServer
  def init(%State{channel: channel} = state, %{channels: channels, showing: showing}),
    do:
      {:ok, State.posting(state, Map.fetch!(channels, channel), showing), {:continue, :open},
       permanent: true}

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
      store = store(state)
      head = Log.head(store, agent, Log.oldest(store, agent, consistent: true) - 1)
      {:reply, :ok, State.follow(state, thread, agent, head), sync: true}
    end
  end

  @impl DurableServer
  def handle_cast({:remind, thread}, state) do
    with true <- State.followed?(state, thread),
         {:error, reason} <- post(state, thread, {:parked, :all}) do
      Logger.warning(
        "#{state.channel} could not remind #{state.room} what waits: #{inspect(reason)}"
      )
    end

    {:noreply, state}
  end

  # A change in what an agent is doing says only that it changed: what it
  # is doing is read from the agent as it is shown.
  @impl DurableServer
  def handle_info(
        %Entry{
          event: %{"type" => "wardrik.activity.changed", "source" => @source <> id},
          sequence: nil
        },
        state
      ) do
    with {:ok, agent} <- AgentID.parse(id),
         thread when is_binary(thread) <- State.thread_of(state, agent) do
      {:noreply, changed(state, thread)}
    else
      _unfollowed -> {:noreply, state}
    end
  end

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

  def handle_info({:status, thread, tag}, state) do
    case state.statuses[thread] do
      {^tag, :shown, label} -> {:noreply, standing(state, thread, label)}
      {^tag, _changed_or_standing, _label} -> {:noreply, show(state, thread)}
      _stale -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A change while a status may not yet change is shown once it may.
  defp changed(state, thread) do
    case state.statuses[thread] do
      {tag, :shown, label} -> put_in(state.statuses[thread], {tag, :changed, label})
      {_tag, :changed, _label} -> state
      _standing_or_none -> show(state, thread)
    end
  end

  # An agent idle, or waiting on a person, has nothing shown: what is posted
  # in the thread takes away what was.
  defp show(state, thread) do
    case Agent.status(state.threads[thread].agent, host: state.posting.context.host) do
      %{state: :running, activity: %Activity{doing: doing} = activity} when doing != :idle ->
        show(state, thread, Presenter.label(state.showing.presenter, activity))

      _idle_parked_or_gone ->
        %{state | statuses: Map.delete(state.statuses, thread)}
    end
  end

  # Changes that come back to the words shown show nothing new.
  defp show(state, thread, label) do
    case state.statuses[thread] do
      {_tag, :changed, ^label} ->
        standing(state, thread, label)

      _new_or_due ->
        _shown = deliver(state, thread, {:status, label})
        wake(state, thread, :shown, label, state.showing.throttle)
    end
  end

  defp standing(state, thread, label),
    do: wake(state, thread, :standing, label, state.showing.refresh - state.showing.throttle)

  defp wake(state, thread, status, label, ms) do
    tag = make_ref()
    Process.send_after(self(), {:status, thread, tag}, ms)
    put_in(state.statuses[thread], {tag, status, label})
  end

  # Posts what the thread's log holds past what has been posted, until it
  # ends or a post is refused.
  defp advance(state, thread) do
    followed = state.threads[thread]

    case Log.read(store(state), followed.agent, starting_after: followed.through) do
      {:gap, oldest} -> advance(State.skip(state, thread, oldest), thread)
      {:ok, []} -> state
      {:ok, events} -> posted(state, thread, events)
    end
  end

  # The logs are in the store of the host the room's channel runs on.
  defp store(%State{posting: %Channel{context: context}}), do: Wardrik.Host.store(context.host)

  defp posted(state, thread, []), do: advance(state, thread)

  defp posted(state, thread, [event | rest]) do
    {post, next} = State.take(state, thread, event)

    case post(state, thread, post) do
      :ok ->
        next = %{next | retries: Map.delete(next.retries, thread)}
        posted(cleared(next, thread, post), thread, rest)

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

  # What is posted in a thread takes its status away, which is a change: what
  # the agent is doing is shown again once it may be, whatever the words.
  defp cleared(state, _thread, :none), do: state

  defp cleared(state, thread, _posted) do
    case state.statuses[thread] do
      {tag, status, _label} -> changed(put_in(state.statuses[thread], {tag, status, nil}), thread)
      nil -> state
    end
  end

  defp post(_state, _thread, :none), do: :ok

  defp post(state, thread, {:reply, text, answering}),
    do: deliver(state, thread, {:reply, text, answering})

  defp post(state, thread, {:connected, provider}),
    do: deliver(state, thread, {:reply, "Connected #{provider}.", []})

  defp post(state, thread, {:decided, line}), do: deliver(state, thread, {:reply, line, []})

  defp post(state, thread, {:stopped, answering}) do
    _cleared = deliver(state, thread, {:stopped, answering})
    :ok
  end

  defp post(state, thread, {:failed, reason}) do
    agent = state.threads[thread].agent
    notice = %Notice{agent: agent, kind: :failed, at: DateTime.utc_now(), reason: reason}
    deliver(state, thread, {:notice, notice})
  end

  # The calls are read from the agent as they are posted, and only those
  # still waiting are: the log does not say what a call asks.
  defp post(state, thread, {:parked, ids}) do
    agent = state.threads[thread].agent

    with parked when is_list(parked) <- Agent.parked(agent, host: state.posting.context.host),
         [_ | _] = calls <- Enum.filter(parked, &waiting?(&1, ids)) do
      deliver(state, thread, {:notice, Notice.parked(agent, calls)}, :approvers)
    else
      _none_waiting -> :ok
    end
  end

  defp waiting?(_parked, :all), do: true
  defp waiting?({call, _prompt}, ids), do: call.id in ids

  # The workspace's installation is found as each post is made, so one taken
  # out is posted in no more.
  defp deliver(%State{posting: %Channel{} = channel} = state, thread, body, to \\ :room) do
    with {:ok, workspace} <- workspace(channel, state) do
      approvers = workspace |> Workspace.approvers() |> WardrikChannel.Approvers.asked()

      outbound = %Outbound{
        installation: workspace.installation,
        room: state.room,
        thread: thread,
        body: body,
        approvers: approvers,
        to: if(approvers == [], do: :room, else: to)
      }

      with {:ok, _posted} <- channel.adapter.deliver(outbound, channel.options), do: :ok
    end
  end

  defp workspace(%Channel{context: context}, %State{workspace: workspace}) do
    case Workspace.new(context, workspace) do
      {:ok, workspace} -> {:ok, workspace}
      :error -> {:error, :not_installed}
    end
  end
end
