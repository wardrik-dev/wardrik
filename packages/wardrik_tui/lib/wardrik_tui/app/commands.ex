defmodule WardrikTUI.App.Commands do
  @moduledoc """
  Execution of parsed commands, including fleet changes and confirmations.
  """
  import Breeze.View, only: [assign: 2]

  alias Wardrik.Agent
  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Audit
  alias Wardrik.Caller
  alias Wardrik.Change
  alias Wardrik.Command, as: Operation
  alias Wardrik.Error
  alias Wardrik.Fleet
  alias Wardrik.Operations.Ask
  alias Wardrik.Operations.Cancel
  alias Wardrik.Operations.CancelAgents
  alias Wardrik.Operations.Forget
  alias Wardrik.Operations.Move
  alias Wardrik.Operations.Spawn
  alias Wardrik.Operations.SpawnOn
  alias Wardrik.Operations.Stop
  alias WardrikConsole.Nodes
  alias WardrikTUI.App.Connection
  alias WardrikTUI.App.Display
  alias WardrikTUI.App.Interaction
  alias WardrikTUI.App.Prompt
  alias WardrikTUI.Command
  alias WardrikTUI.View
  @default_denial "Denied by the person watching."

  # Reads a line as the prompt would, records it, and acts on it. A line that
  # named no command, or gave one the wrong thing, is put back for correction.
  def run_line(term, line) do
    command = Command.parse(line, term.assigns.parked != [])
    term = Prompt.remember(term, line, command)

    case command do
      :quit ->
        {:stop, term}

      {mistake, _word} when mistake in [:unknown, :usage] ->
        {:noreply, command |> apply_command(term) |> Prompt.put_draft(String.trim(line))}

      command ->
        {:noreply, apply_command(command, term)}
    end
  end

  defp apply_command(:blank, term), do: term

  defp apply_command(:confirm, term), do: confirm(term)

  # Anything but `/confirm` drops a removal or a move that was waiting on it.
  defp apply_command(command, %{assigns: %{confirm: pending}} = term) when pending != nil do
    cancelled = View.cancelled(elem(pending, 0))
    apply_command(command, term |> assign(confirm: nil) |> Display.append(cancelled))
  end

  defp apply_command({:stop, nil}, term), do: interrupt(term)

  defp apply_command({:stop, target}, term), do: stop(term, target)

  defp apply_command({:shutdown, name}, term), do: with_id(term, name, &shutdown(term, &1, name))

  defp apply_command({:rm, target, confirmed?}, term), do: remove(term, target, confirmed?)

  defp apply_command({:approve, selector, nil}, term), do: decide(term, selector, :approve)

  defp apply_command({:approve, selector, note}, term),
    do: decide(term, selector, {:approve, note})

  defp apply_command(:fleet, term), do: Interaction.show_fleet(term)

  defp apply_command(:help, term), do: Interaction.open_help(term)

  defp apply_command({:deny, selector, reason}, term),
    do: decide(term, selector, {:deny, reason || @default_denial})

  defp apply_command({:spawn, name, options, prompt, mode}, term),
    do: with_id(term, name, &spawn_agent(term, &1, name, options, prompt, mode))

  defp apply_command({:move, nil, _options}, term), do: Interaction.pick(term, "/move", [])

  defp apply_command({:move, name, options}, term) when map_size(options) == 0 do
    if Node.list() == [],
      do: Interaction.flash(term, View.only_node()),
      else: with_id(term, name, &Interaction.pick(term, "/move", [to_string(&1)]))
  end

  defp apply_command({:move, name, options}, term),
    do: with_id(term, name, &move_agent(term, &1, options))

  defp apply_command({:connect, nil}, term), do: Interaction.pick(term, "/connect", [])

  defp apply_command({:connect, name}, term), do: connect(term, name)

  defp apply_command({:filter, query}, term), do: Interaction.filter(term, query)

  defp apply_command(:next, term), do: Interaction.next_attention(term)

  defp apply_command({:find, query}, term), do: Interaction.open_search(term, query || "")

  defp apply_command(:tools, term), do: Interaction.open_tools(term)

  defp apply_command({:copy, what}, term), do: Interaction.copy_text(term, what)

  defp apply_command({:ask, text}, term), do: ask(term, text)

  defp apply_command({:usage, name}, term),
    do: Display.append(term, View.usage(Command.find(name)))

  defp apply_command({:unknown, word}, term),
    do: Display.append(term, View.unknown_command(word, Command.suggest(word)))

  # An agent already running under the ID is connected to rather than
  # started again, or, in the background, left alone and named.
  defp spawn_agent(term, id, name, options, prompt, mode) do
    with {:ok, placement} <- placement(options),
         {:ok, %{"from" => from}} <- Operation.run(spawning(id, placement), caller(term)) do
      pid = Fleet.whereis(id)

      if from == "running",
        do: existing_agent(term, id, name, pid, prompt, mode),
        else: started(term, id, name, pid, prompt, mode)
    else
      {:error, %Error{message: message}} -> Display.append(term, View.error(message))
      {:error, reason} -> Display.append(term, placement_error(reason, "/spawn"))
    end
  end

  defp spawning(id, []), do: %Spawn{agent: id}
  defp spawning(id, node: node), do: %SpawnOn{agent: id, node: node}

  defp started(term, id, _name, pid, prompt, :attach),
    do: term |> Connection.switch(pid, id) |> Display.append(View.spawned(id)) |> ask_if(prompt)

  defp started(term, id, name, pid, prompt, :background) do
    term
    |> Connection.refresh_fleet()
    |> Display.append(View.spawned_background(id, name))
    |> ask_elsewhere(pid, id, prompt)
  end

  defp existing_agent(%{assigns: %{agent_id: id}} = term, id, name, _pid, prompt, mode),
    do: term |> Display.append(View.already_running(id, name, mode)) |> ask_if(prompt)

  defp existing_agent(term, id, name, pid, prompt, :attach),
    do:
      term
      |> Connection.switch(pid, id)
      |> Display.append(View.already_running(id, name, :attach))
      |> ask_if(prompt)

  defp existing_agent(term, id, name, pid, prompt, :background),
    do:
      term
      |> Display.append(View.already_running(id, name, :background))
      |> ask_elsewhere(pid, id, prompt)

  defp ask_if(term, nil), do: term

  defp ask_if(term, prompt), do: ask(term, prompt)

  # A prompt for an agent this client is not attached to.
  defp ask_elsewhere(term, _pid, _id, nil), do: term

  defp ask_elsewhere(term, _pid, id, prompt) do
    case asked(term, id, prompt) do
      {:ok, _answer} -> Display.append(term, View.sent_to(id, prompt))
      {:error, %Error{type: :not_found}} -> Display.append(term, View.no_such_agent(id))
    end
  catch
    :exit, _reason -> Display.append(term, View.unavailable(id))
  end

  # An agent whose turn is running or waiting is not moved until `/confirm`,
  # after what the move would interrupt has been shown.
  defp move_agent(term, id, options) do
    with {:ok, [node: node]} <- placement(options),
         {:ok, change} <- Operation.plan(%Move{agent: id, node: node}, caller(term)) do
      case Operation.preview(change) do
        %{"moving" => %{"from" => here, "to" => here}} ->
          Display.append(term, View.already_on(id, node))

        %{"moving" => %{"interrupting" => doing}} ->
          term
          |> assign(confirm: {:move, change})
          |> Display.append(View.move_preview(id, node, interrupted(doing)))

        _nothing_to_interrupt ->
          move_now(term, change)
      end
    else
      {:error, %Error{type: :not_found}} -> Display.append(term, View.no_such_agent(id))
      {:error, %Error{message: message}} -> Display.append(term, View.error(message))
      {:error, reason} -> Display.append(term, placement_error(reason, "/move"))
    end
  end

  defp interrupted("turn"), do: :running
  defp interrupted("calls"), do: :parked

  defp move_now(term, %Change{request: %Move{agent: id, node: node}} = change) do
    case Operation.make(change, caller(term)) do
      {:ok, _answer} ->
        term
        |> adopt(id, Fleet.whereis(id))
        |> Connection.refresh_fleet()
        |> Display.append(View.moved(id, node))

      {:error, %Error{message: message}} ->
        Display.append(term, View.error(message))
    end
  end

  defp placement_error({:no_such_node, name}, _command),
    do: View.no_such_node(name, [node() | Node.list()])

  defp placement_error({:unknown_options, keys}, command),
    do: View.unknown_options(keys, Command.find(command))

  # The attached agent is addressed by its new process from here on.
  defp adopt(%{assigns: %{agent_id: id}} = term, id, pid), do: Connection.reconnect(term, pid)

  defp adopt(term, _id, _pid), do: term

  defp placement(%{"node" => name} = options) when map_size(options) == 1 do
    case Nodes.find(name, [node() | Node.list()]) do
      nil -> {:error, {:no_such_node, name}}
      node -> {:ok, [node: node]}
    end
  end

  defp placement(options) when map_size(options) == 0, do: {:ok, []}

  defp placement(options), do: {:error, {:unknown_options, Map.keys(options) -- ["node"]}}

  # A name that is an agent's, in this client's org or as a whole ID, is
  # connected to. Otherwise the fleet is searched for it.
  defp connect(term, name) do
    case id(term, name) do
      {:ok, id} ->
        if id == term.assigns.agent_id or Fleet.whereis(id) != nil,
          do: Connection.connect_id(term, id),
          else: search(term, name, View.no_such_agent(id))

      {:error, message} ->
        search(term, name, View.error(message))
    end
  end

  # One agent whose ID holds `name` is the one meant; several are offered to
  # pick from. Where none does, `none` is said.
  defp search(term, name, none) do
    case matching(name) do
      [] -> Display.append(term, none)
      [member] -> Connection.connect_id(term, member.id)
      _several -> Interaction.pick(term, "/connect", [], String.trim_leading(name, "/"))
    end
  end

  defp matching(name) do
    text = name |> String.trim_leading("/") |> String.downcase()
    Enum.filter(Fleet.list(), &String.contains?(String.downcase(to_string(&1.id)), text))
  end

  # A name is read as `Wardrik.AgentID.expand/2` reads it, in this client's
  # `:org`. A leading slash is tolerated, as is an ID nothing holds, which the
  # lookup then reports.
  defp id(term, name), do: name |> String.trim_leading("/") |> AgentID.expand(term.assigns.org)

  # Acts on the agent `name` names, or says why it names none.
  defp with_id(term, name, act) do
    case id(term, name) do
      {:ok, id} -> act.(id)
      {:error, message} -> Display.append(term, View.error(message))
    end
  end

  # `/stop NAME` interrupts one agent, and `/stop PREFIX/` every agent under a
  # prefix. Both leave the agents running.
  defp stop(term, target) do
    target = String.trim_leading(target, "/")

    if String.ends_with?(target, "/"),
      do: stop_under(term, target),
      else: with_id(term, target, &stop_one(term, &1))
  end

  # This client may cancel every agent, so a cancel under a prefix it can
  # name always answers.
  defp stop_under(term, target) do
    case Prefix.expand(target, term.assigns.org) do
      {:ok, prefix} ->
        {:ok, %{"cancelled" => cancelled}} =
          Operation.run(%CancelAgents{prefix: prefix}, caller(term))

        Display.append(term, View.stopped_under(prefix, length(cancelled)))

      {:error, message} ->
        Display.append(term, View.error(message))
    end
  end

  defp stop_one(term, id) do
    case Operation.run(%Cancel{agent: id}, caller(term)) do
      {:ok, _answer} -> Display.append(term, View.stopped(id))
      {:error, %Error{type: :not_found}} -> Display.append(term, View.no_such_agent(id))
    end
  end

  # Stops an agent and keeps its store, so `/spawn` brings it back as it was.
  # The attached agent may be shut down; the status row then says so.
  defp shutdown(term, id, name) do
    case Operation.run(%Stop{agent: id}, caller(term)) do
      {:ok, _answer} ->
        term |> Connection.refresh_fleet() |> Display.append(View.shut_down(id, name))

      {:error, %Error{type: :not_found}} ->
        Display.append(term, View.no_such_agent(id))
    end
  end

  # Prefix removal always previews exact targets. A single named agent may
  # be removed at once with `--yes`. The attached agent is left out and named.
  defp remove(term, target, confirmed?) do
    target = String.trim_leading(target, "/")

    if String.ends_with?(target, "/"),
      do: remove_under(term, target),
      else: with_id(term, target, &remove_one(term, &1, target, confirmed?))
  end

  defp remove_under(%{assigns: %{agent_id: attached}} = term, target) do
    case Prefix.expand(target, term.assigns.org) do
      {:ok, prefix} ->
        ids = prefix |> Fleet.list() |> Enum.map(& &1.id)

        case {List.delete(ids, attached), if(attached in ids, do: attached)} do
          {[], nil} -> Display.append(term, View.nothing_under(target))
          {[], skipped} -> Display.append(term, View.attached(skipped))
          {ids, skipped} -> preview(term, target, ids, skipped)
        end

      {:error, message} ->
        Display.append(term, View.error(message))
    end
  end

  defp remove_one(%{assigns: %{agent_id: attached}} = term, id, target, confirmed?) do
    cond do
      id == attached -> Display.append(term, View.attached(attached))
      Fleet.whereis(id) == nil -> Display.append(term, View.no_such_agent(id))
      confirmed? -> forget_all(term, [id])
      true -> preview(term, target, [id], nil)
    end
  end

  defp preview(term, target, ids, skipped) do
    term
    |> assign(confirm: {:rm, ids})
    |> Display.append(View.removal_preview(target, ids, skipped))
  end

  defp confirm(%{assigns: %{confirm: {:rm, ids}}} = term) do
    term |> assign(confirm: nil) |> forget_all(ids)
  end

  defp confirm(%{assigns: %{confirm: {:move, change}}} = term) do
    term |> assign(confirm: nil) |> move_now(change)
  end

  defp confirm(term), do: Interaction.flash(term, View.nothing_to_confirm())

  defp forget_all(term, ids) do
    {removed, failed} =
      Enum.split_with(
        ids,
        &match?({:ok, _answer}, Operation.run(%Forget{agent: &1}, caller(term)))
      )

    term = assign(term, views: Map.drop(term.assigns.views, removed))

    case failed do
      [] -> term |> Connection.refresh_fleet() |> Display.append(View.forgotten(ids))
      failed -> term |> Connection.refresh_fleet() |> Display.append(View.not_removed(failed))
    end
  end

  # Each call is answered on its own. With one call waiting, a decision with no
  # selector is for it; with several, it has to say which, or `all`.
  def decide(%{assigns: %{parked: []}} = term, _selector, _decision),
    do: Display.append(term, View.nothing_to_answer())

  def decide(%{assigns: %{running?: true}} = term, _selector, _decision),
    do: Display.append(term, View.decision_pending())

  def decide(term, selector, decision) do
    calls = term.assigns.parked

    case chosen(calls, selector) do
      {:ok, chosen} ->
        accept_decision(term, chosen, decision)

      :ambiguous ->
        Display.append(term, View.choose(calls))

      :none ->
        Display.append(term, View.no_such_call(selector))
    end
  end

  defp accept_decision(term, chosen, decision) do
    case Agent.decide(term.assigns.agent, decisions(chosen, decision), by: term.assigns.principal) do
      :ok ->
        remaining = term.assigns.parked -- chosen

        term
        |> assign(parked: remaining, running?: true)
        |> Display.append(View.decided(chosen, decision, length(remaining)))

      {:error, _reason} ->
        Display.append(term, View.decision_pending())
    end
  catch
    :exit, _reason ->
      term |> assign(available?: false) |> Display.append(View.unavailable(term.assigns.agent_id))
  end

  defp chosen([only], nil), do: {:ok, [only]}

  defp chosen(_calls, nil), do: :ambiguous

  defp chosen(calls, :all), do: {:ok, calls}

  defp chosen(calls, number) do
    case Integer.parse(number) do
      {n, ""} when n >= 1 and n <= length(calls) -> {:ok, [Enum.at(calls, n - 1)]}
      _other -> :none
    end
  end

  defp decisions(calls, decision),
    do: Map.new(calls, fn {call, _prompt} -> {call.id, decision} end)

  defp ask(%{assigns: %{available?: false, agent_id: id}} = term, _text),
    do: Display.append(term, View.unavailable(id))

  defp ask(term, text) do
    :ok = Agent.ask(term.assigns.agent, text)

    cond do
      term.assigns.running? -> steer(term, text, :running)
      term.assigns.parked != [] -> steer(term, text, :parked)
      true -> Display.question(term, text)
    end
  end

  defp steer(term, text, how) do
    term
    |> assign(queued: term.assigns.queued + 1)
    |> Display.append_lines(["", View.steered(text, how)])
  end

  def interrupt(term) do
    Agent.interrupt(term.assigns.agent)
    :ok = record(term, {:agent_cancelled, term.assigns.agent_id})
    term
  end

  defp asked(term, id, text) do
    with {:ok, ask} <- Ask.new(id, %{"content" => text}), do: Operation.run(ask, caller(term))
  end

  # Whoever uses this client holds the node, as a shell on it does.
  defp caller(term), do: Caller.root(term.assigns.principal)

  # A change this client made, recorded for the person using it.
  defp record(term, action), do: Audit.record(action, term.assigns.principal)
end
