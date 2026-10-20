defmodule WardrikChannel.Replies.Server do
  @moduledoc """
  The process behind one room's `WardrikChannel.Replies`: it runs a
  `WardrikChannel.Replies.Follower` for each thread, on the log of the
  thread's agent, posts what each entry a follower hands it asks for, and
  writes down the cursor past it; and it shows what the agent is doing as
  its log says it changed.

  Started by `WardrikChannel.Replies.follow/3` under the supervisor
  `WardrikChannel.Replies` runs, which hands it the channels, and how it
  shows statuses, as it starts: it keeps its own `WardrikChannel.Channel` in
  memory, and writes none of it down. A room whose channel is not among
  them does not start. Its followers act as the deployment,
  `Wardrik.Principal.deployment/0`, which the host's `Wardrik.Issuer`
  allows `agent.events` on the threads' agents.
  """

  use DurableServer, vsn: 1

  require Logger

  alias Wardrik.Agent
  alias Wardrik.Agent.Activity
  alias Wardrik.Agent.Activity.Presenter
  alias Wardrik.AgentAddress
  alias Wardrik.Principal
  alias Wardrik.Thread
  alias WardrikChannel.Channel
  alias WardrikChannel.Outbound
  alias WardrikChannel.Replies.Follower
  alias WardrikChannel.Replies.State
  alias WardrikChannel.Workspace
  alias WardrikNotify.Notice

  @first_backoff 1_000
  @max_backoff 60_000
  @attempts 8

  @types ~w(wardrik.run.started wardrik.run.completed wardrik.run.interrupted wardrik.run.failed
            wardrik.run.cancelled wardrik.interrupt.resolved wardrik.activity.changed)

  @impl DurableServer
  def dump_state(%State{} = state),
    do:
      state
      |> Map.from_struct()
      |> Map.drop([:retries, :posting, :showing, :statuses, :followers])

  @impl DurableServer
  def load_state(_old_vsn, dumped), do: struct!(State, dumped)

  # DurableServer's callback type leaves out the continue its server takes
  # from `init`.
  @dialyzer {:nowarn_function, init: 2}
  @impl DurableServer
  def init(%State{channel: channel} = state, %{channels: channels, showing: showing}) do
    {:ok, followers} = DynamicSupervisor.start_link(strategy: :one_for_one)
    state = State.posting(state, Map.fetch!(channels, channel), showing, followers)
    {:ok, state, {:continue, :open}, permanent: true}
  end

  @impl DurableServer
  def handle_continue(:open, state) do
    for {thread, _followed} <- state.threads, do: follow(state, thread)
    {:noreply, state}
  end

  def handle_continue({:posted, from}, state) do
    GenServer.reply(from, :ok)
    {:noreply, state}
  end

  # A new thread posts what its agent's log holds from where it stands now.
  @impl DurableServer
  def handle_call({:follow, thread, %Thread{} = agent}, _from, state) do
    if State.followed?(state, thread) do
      {:reply, :ok, state}
    else
      scope = Wardrik.as(host(state), Principal.deployment())
      head = Wardrik.events_head!(scope, resources: [AgentAddress.resource(agent)])
      state = State.follow(state, thread, agent, head)
      follow(state, thread)
      {:reply, :ok, state, sync: true}
    end
  end

  def handle_call({:cursor, thread}, _from, state),
    do: {:reply, state.threads[thread].cursor, state}

  # A change in what an agent is doing says only that it changed: what it
  # is doing is read from the agent as it is shown.
  def handle_call(
        {:event, thread, %Wardrik.Event.ActivityChanged{}, _cursor},
        _from,
        state
      ),
      do: {:reply, :ok, changed(state, thread)}

  def handle_call({:event, thread, %{cloudevent: event}, cursor}, from, state),
    do: posting(state, thread, {event, cursor, from}, 1)

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

  # The followers' supervisor gave up: the room starts again, from the
  # cursors it wrote down.
  @impl DurableServer
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, {:error, reason}, state}

  def handle_info({:retry, thread}, state) do
    {{attempt, held}, retries} = Map.pop(state.retries, thread)
    posting(%{state | retries: retries}, thread, held, attempt + 1)
  end

  def handle_info({:status, thread, tag}, state) do
    case state.statuses[thread] do
      {^tag, :shown, label} -> {:noreply, standing(state, thread, label)}
      {^tag, _changed_or_standing, _label} -> {:noreply, show(state, thread)}
      _stale -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp follow(state, thread) do
    follower =
      {Follower,
       host: host(state),
       principal: Principal.deployment(),
       resources: [AgentAddress.resource(state.threads[thread].agent)],
       types: @types,
       server: self(),
       thread: thread}

    {:ok, _pid} = DynamicSupervisor.start_child(state.followers, follower)
  end

  # The logs, and the agents, are the host's the room's channel runs on.
  defp host(%State{posting: %Channel{context: context}}), do: context.host

  # Posts the entry a thread's follower handed over, then answers the
  # follower; a post the channel refuses is tried again, waiting longer each
  # time, while the follower waits.
  defp posting(state, thread, {event, cursor, from} = held, attempt) do
    {post, next} = State.take(state, thread, event, cursor)

    case post(state, thread, post) do
      :ok ->
        posted(cleared(next, thread, post), from)

      {:error, reason} when attempt >= @attempts ->
        Logger.warning(
          "#{state.channel} gave up posting in #{state.room} after #{attempt} attempts: " <>
            inspect(reason)
        )

        posted(next, from)

      {:error, _reason} ->
        backoff = min(@first_backoff * Integer.pow(2, attempt - 1), @max_backoff)
        Process.send_after(self(), {:retry, thread}, backoff)
        {:noreply, put_in(state.retries[thread], {attempt, held})}
    end
  end

  # The follower is answered once the cursor past its entry is written down.
  defp posted(state, from), do: {:noreply, state, {:continue, {:posted, from}}, sync: true}

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
    case Agent.status(state.threads[thread].agent, host: host(state)) do
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

    with parked when is_list(parked) <- Agent.parked(agent, host: host(state)),
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
