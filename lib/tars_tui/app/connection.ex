defmodule TarsTUI.App.Connection do
  @moduledoc """
  Agent subscriptions, fleet observation, and saved per-agent views.
  """
  import Breeze.View, only: [assign: 2, reset: 2, put_implicit: 4]

  alias Tars.Agent
  alias Tars.Delegation
  alias Tars.Event
  alias Tars.Fleet
  alias TarsTUI.Activity
  alias TarsTUI.App.Conversation
  alias TarsTUI.App.Display
  alias TarsTUI.App.Frames
  alias TarsTUI.App.TermState
  alias TarsTUI.Fleet.Filter
  alias TarsTUI.View

  # -- delegations -----------------------------------------------------------

  # The agent a panel row belongs to: its own key, or the key before the
  # delegation's span.
  def agent_of(nil), do: nil

  def agent_of(value), do: value |> String.split("\t", parts: 2) |> hd()

  # Shows an agent's delegations under its row. Another agent's come from its
  # snapshot and then its lifecycle events; the attached agent's are folded
  # here already.
  def expand(term, nil), do: term

  def expand(%{assigns: %{expanded: expanded, agent_id: agent_id}} = term, key) do
    cond do
      Map.has_key?(expanded, key) ->
        term

      key == agent_id ->
        term |> assign(expanded: Map.put(expanded, key, nil)) |> Frames.tick()

      true ->
        case Enum.find(term.assigns.fleet, &(&1.key == key)) do
          nil ->
            term

          member ->
            :ok = Event.Bus.subscribe(key, level: :lifecycle)

            term
            |> assign(expanded: Map.put(expanded, key, followed(member.pid)))
            |> Frames.tick()
        end
    end
  end

  defp followed(pid) do
    case Agent.snapshot(pid) do
      %{delegations: %Delegation{} = delegations} -> delegations
      _other -> Delegation.new()
    end
  catch
    :exit, _reason -> Delegation.new()
  end

  # Hides an agent's delegations until `l`, and stops following an agent that
  # is not the attached one. The cursor lands on the agent.
  def collapse(term, nil), do: term

  def collapse(%{assigns: %{expanded: expanded, agent_id: agent_id}} = term, key) do
    term = assign(term, collapsed: MapSet.put(term.assigns.collapsed, key))

    if Map.has_key?(expanded, key) do
      if key != agent_id, do: Event.Bus.unsubscribe(key)
      assign(term, expanded: Map.delete(expanded, key), highlighted: key)
    else
      term
    end
  end

  # Every agent in the fleet is expanded unless it was collapsed; one gone
  # from the fleet is no longer followed.
  defp expand_all(term, fleet) do
    keys = Enum.map(fleet, & &1.key)
    gone = Map.keys(term.assigns.expanded) -- keys
    Enum.each(gone, &if(&1 != term.assigns.agent_id, do: Event.Bus.unsubscribe(&1)))

    term =
      assign(term,
        expanded: Map.drop(term.assigns.expanded, gone),
        collapsed: MapSet.intersection(term.assigns.collapsed, MapSet.new(keys))
      )

    Enum.reduce(fleet, term, fn member, term ->
      if MapSet.member?(term.assigns.collapsed, member.key),
        do: term,
        else: expand(term, member.key)
    end)
  end

  # An agent this client was attached to stays followed if it is expanded,
  # and one it attaches to is followed through its own subscription instead.
  defp refollow(term, old, key) do
    expanded = term.assigns.expanded

    if Map.has_key?(expanded, old) and old != key do
      :ok = Event.Bus.subscribe(old, level: :lifecycle)
      kept = term.assigns.views |> Map.get(old, %{}) |> Map.get(:delegations, Delegation.new())
      assign(term, expanded: Map.put(expanded, old, kept))
    else
      term
    end
  end

  # Subscribes to `agent`'s events and shows its conversation: the transcript
  # kept from the last time this client watched it, brought up to date, or a
  # replay of the whole conversation. `agent_id` is what the events are
  # published under.
  def attach(term, agent, agent_id) do
    # `:raw` delivers `{:tool_call, chunk}` with its arguments.
    :ok = Event.Bus.subscribe(agent_id, level: :raw)

    case snapshot(agent) do
      {:ok, snapshot} -> attach_snapshot(term, agent, agent_id, snapshot)
      {:error, _reason} -> assign(term, available?: false)
    end
  end

  defp snapshot(agent) do
    case Agent.snapshot(agent) do
      {:error, reason} -> {:error, reason}
      snapshot -> {:ok, snapshot}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp attach_snapshot(term, agent, agent_id, snapshot) do
    %{
      status: %{state: state, pending: pending, model: model},
      context: %{messages: messages},
      parked: parked,
      generation: generation,
      trace_id: trace_id
    } = snapshot

    term =
      term
      |> assign(
        agent: agent,
        agent_id: agent_id,
        highlighted: agent_id,
        model: model,
        generation: generation,
        trace_id: trace_id,
        activity: Activity.new(),
        running?: state == :running,
        queued: pending,
        available?: true,
        confirm: nil
      )

    case Map.pop(term.assigns.views, agent_id) do
      {nil, _views} ->
        term |> fresh(messages) |> Display.parked_notice(parked)

      {%{generation: ^generation} = kept, views} ->
        term |> assign(views: views) |> restore(kept, messages, parked)

      {_deleted, views} ->
        term |> assign(views: views) |> fresh(messages) |> Display.parked_notice(parked)
    end
    |> assign(
      parked: parked,
      delegations: Map.get(snapshot, :delegations, Delegation.new()),
      unseen: Map.delete(term.assigns.unseen, agent_id)
    )
  end

  defp fresh(term, messages) do
    display = Conversation.new(TermState.width(term), term.assigns.model)

    term
    |> assign(display |> Conversation.restored_assigns() |> Map.put(:seen, length(messages)))
    |> reset("prompt")
    |> reset("log")
    |> Display.playback(messages)
  end

  # What was kept comes back as it was, and the messages the conversation
  # gained meanwhile are replayed under a note. A park that happened while
  # away is announced as it would have been live.
  defp restore(term, kept, messages, parked) do
    unseen = Enum.drop(messages, kept.seen)
    same_turn? = term.assigns.trace_id == kept.trace_id
    activity = if same_turn?, do: kept.activity, else: Activity.new()
    restored = Conversation.restored_assigns(kept)

    term
    |> assign(Map.put(restored, :seen, length(messages)))
    |> assign(activity: activity)
    |> restore_prompt(kept.prompt)
    |> put_implicit("log", TarsTUI.Scroll, kept.scroll)
    |> away(unseen)
    |> Display.parked_notice(if(kept.parked != parked, do: parked, else: []))
  end

  defp restore_prompt(term, prompt) when map_size(prompt) == 0, do: reset(term, "prompt")

  defp restore_prompt(term, prompt),
    do: put_implicit(term, "prompt", Breeze.Implicit.Textarea, prompt)

  defp away(term, []), do: term

  defp away(term, messages) do
    term |> Display.append(View.away(length(messages))) |> Display.playback(messages)
  end

  # Keeps the view of the attached agent for the next time it is connected to.
  defp keep(term) do
    term = Display.settle(term)
    seen = seen(term)

    kept =
      term.assigns
      |> Conversation.from_assigns()
      |> Map.merge(%{
        seen: seen,
        scroll: TermState.implicit_state(term, "log"),
        prompt: TermState.implicit_state(term, "prompt")
      })

    assign(term, views: Map.put(term.assigns.views, term.assigns.agent_id, kept))
  end

  # How many messages the conversation holds now, or the count last known when
  # the agent cannot be asked.
  defp seen(%{assigns: %{agent: agent, seen: seen}}) do
    case Agent.get_context(agent) do
      %ReqLLM.Context{messages: messages} -> length(messages)
      {:error, :not_found} -> seen
    end
  catch
    :exit, _reason -> seen
  end

  def connect_key(%{assigns: %{agent_id: key}} = term, key),
    do: Display.append(term, View.connected(key))

  def connect_key(term, key) do
    case Fleet.whereis(key) do
      nil ->
        Display.append(term, View.no_such_agent(key))

      pid ->
        term |> switch(pid, key) |> Display.append(View.connected(key))
    end
  end

  # Leaves the agent this client is attached to for `pid`, registered under
  # `key`, keeping the view of the one it leaves. The agent is addressed by pid
  # from here on: the registry is eventually consistent, so a key may not yet
  # resolve on this node for an agent that just started on another.
  def switch(term, pid, key) do
    old = term.assigns.agent_id
    Event.Bus.unsubscribe(old)
    if Map.has_key?(term.assigns.expanded, key), do: Event.Bus.unsubscribe(key)

    term |> keep() |> attach(pid, key) |> refresh_fleet() |> refollow(old, key)
  end

  def refresh_fleet(term) do
    fleet = Fleet.list()

    term
    |> assign(fleet: fleet, fleet_due?: false, unseen: unseen(term, fleet))
    |> follow(fleet)
    |> expand_all(fleet)
  end

  # An agent other than the attached one that was running or waiting and is
  # idle now finished a turn this client did not watch; how it ended is kept
  # until the client connects to it. An agent gone from the fleet is dropped.
  defp unseen(%{assigns: %{fleet: previous, unseen: unseen, agent_id: attached}}, fleet) do
    before = Map.new(previous, &{&1.key, &1.status})

    fleet
    |> Enum.reduce(unseen, fn member, unseen ->
      if member.key != attached and member.status == :idle and
           Map.get(before, member.key) in [:running, :parked],
         do: Map.put(unseen, member.key, member.outcome || :ok),
         else: unseen
    end)
    |> Map.take(Enum.map(fleet, & &1.key))
  end

  # -- attention and filtering ------------------------------------------------

  def attention(%{fleet: fleet, unseen: unseen}),
    do: Enum.filter(fleet, &TarsTUI.Fleet.attention?(&1, unseen))

  # The agents the panel shows: those passing the filter, in key order.
  def shown(%{fleet: fleet, unseen: unseen, filter: filter}) do
    Enum.filter(fleet, &Filter.match?(filter, &1, TarsTUI.Fleet.attention?(&1, unseen)))
  end

  # The attached agent as the fleet has it now. A new process under the same
  # key, after a move or a restart, is adopted; a key the fleet no longer holds
  # means the agent is not running, unless it is a local process that was never
  # in the fleet.
  defp follow(term, fleet) do
    %{agent: agent, agent_id: key} = term.assigns

    case Enum.find(fleet, &(&1.key == key)) do
      nil ->
        assign(term, available?: alive?(agent))

      %{pid: pid} when pid == agent ->
        if term.assigns.available?, do: term, else: reconnect(term, pid)

      %{pid: pid} when is_pid(agent) ->
        term |> reconnect(pid) |> followed(pid)

      %{pid: pid} ->
        assign(term, agent: pid, available?: true)
    end
  end

  def reconnect(term, pid), do: term |> keep() |> attach(pid, term.assigns.agent_id)

  defp followed(term, pid),
    do: Display.append(term, View.followed(term.assigns.agent_id, node(pid)))

  defp alive?(pid) when is_pid(pid) and node(pid) == node(), do: Process.alive?(pid)

  defp alive?(_agent), do: false
end
