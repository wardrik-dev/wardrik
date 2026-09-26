defmodule WardrikTUI.App.Commands do
  @moduledoc """
  Execution of parsed commands, including fleet changes and confirmations.
  """
  import Breeze.View, only: [assign: 2]

  alias Wardrik.Agent
  alias Wardrik.Fleet
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

  defp apply_command({:shutdown, name}, term), do: shutdown(term, name)

  defp apply_command({:rm, target, confirmed?}, term), do: remove(term, target, confirmed?)

  defp apply_command({:approve, selector}, term), do: decide(term, selector, :approve)

  defp apply_command(:fleet, term), do: Interaction.show_fleet(term)

  defp apply_command(:help, term), do: Interaction.open_help(term)

  defp apply_command({:deny, selector, reason}, term),
    do: decide(term, selector, {:deny, reason || @default_denial})

  defp apply_command({:spawn, name, options, prompt, mode}, term),
    do: spawn_agent(term, name, options, prompt, mode)

  defp apply_command({:move, nil, _options}, term), do: Interaction.pick(term, "/move", [])

  defp apply_command({:move, name, options}, term) when map_size(options) == 0 do
    if Node.list() == [],
      do: Interaction.flash(term, View.only_node()),
      else: Interaction.pick(term, "/move", [key(term, name)])
  end

  defp apply_command({:move, name, options}, term), do: move_agent(term, name, options)

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

  # An agent already running under the key is connected to rather than
  # started again, or, in the background, left alone and named.
  defp spawn_agent(term, name, options, prompt, mode) do
    key = key(term, name)

    case placement(options) do
      {:ok, placement} ->
        case Fleet.whereis(key) do
          nil -> start_agent(term, key, name, placement, prompt, mode)
          pid -> existing_agent(term, key, name, pid, prompt, mode)
        end

      {:error, reason} ->
        Display.append(term, placement_error(reason, "/spawn"))
    end
  end

  defp start_agent(term, key, name, placement, prompt, mode) do
    case Fleet.spawn(key, term.assigns.spawn_opts ++ placement) do
      {:ok, pid} -> started(term, key, name, pid, prompt, mode)
      {:error, reason} -> Display.append(term, fleet_error(reason, placement[:node]))
    end
  end

  defp started(term, key, _name, pid, prompt, :attach),
    do: term |> Connection.switch(pid, key) |> Display.append(View.spawned(key)) |> ask_if(prompt)

  defp started(term, key, name, pid, prompt, :background) do
    term
    |> Connection.refresh_fleet()
    |> Display.append(View.spawned_background(key, name))
    |> ask_elsewhere(pid, key, prompt)
  end

  defp existing_agent(%{assigns: %{agent_id: key}} = term, key, name, _pid, prompt, mode),
    do: term |> Display.append(View.already_running(key, name, mode)) |> ask_if(prompt)

  defp existing_agent(term, key, name, pid, prompt, :attach),
    do:
      term
      |> Connection.switch(pid, key)
      |> Display.append(View.already_running(key, name, :attach))
      |> ask_if(prompt)

  defp existing_agent(term, key, name, pid, prompt, :background),
    do:
      term
      |> Display.append(View.already_running(key, name, :background))
      |> ask_elsewhere(pid, key, prompt)

  defp ask_if(term, nil), do: term

  defp ask_if(term, prompt), do: ask(term, prompt)

  # A prompt for an agent this client is not attached to.
  defp ask_elsewhere(term, _pid, _key, nil), do: term

  defp ask_elsewhere(term, pid, key, prompt) do
    case Agent.ask(pid, prompt) do
      :ok -> Display.append(term, View.sent_to(key, prompt))
      {:error, :not_found} -> Display.append(term, View.no_such_agent(key))
    end
  catch
    :exit, _reason -> Display.append(term, View.unavailable(key))
  end

  # An agent whose turn is running or waiting is not moved until `/confirm`,
  # after what the move would interrupt has been shown.
  defp move_agent(term, name, options) do
    key = key(term, name)

    case placement(options) do
      {:ok, [node: node]} ->
        case Fleet.lookup(key) do
          nil ->
            Display.append(term, View.no_such_agent(key))

          %{status: status} when status in [:running, :parked] ->
            term
            |> assign(confirm: {:move, key, node})
            |> Display.append(View.move_preview(key, node, status))

          _idle ->
            move_now(term, key, node)
        end

      {:error, reason} ->
        Display.append(term, placement_error(reason, "/move"))
    end
  end

  defp move_now(term, key, node) do
    case Fleet.move(key, node) do
      {:ok, pid} ->
        term
        |> adopt(key, pid)
        |> Connection.refresh_fleet()
        |> Display.append(View.moved(key, node))

      {:error, reason} ->
        Display.append(term, fleet_error(reason, node))
    end
  end

  defp placement_error({:no_such_node, name}, _command),
    do: View.no_such_node(name, [node() | Node.list()])

  defp placement_error({:unknown_options, keys}, command),
    do: View.unknown_options(keys, Command.find(command))

  defp fleet_error({:erpc, reason}, node), do: View.unreachable(node, reason)

  defp fleet_error(reason, _node), do: View.error(reason)

  # The attached agent is addressed by its new process from here on.
  defp adopt(%{assigns: %{agent_id: key}} = term, key, pid), do: Connection.reconnect(term, pid)

  defp adopt(term, _key, _pid), do: term

  defp placement(%{"node" => name} = options) when map_size(options) == 1 do
    case node_named(name) do
      nil -> {:error, {:no_such_node, name}}
      node -> {:ok, [node: node]}
    end
  end

  defp placement(options) when map_size(options) == 0, do: {:ok, []}

  defp placement(options), do: {:error, {:unknown_options, Map.keys(options) -- ["node"]}}

  # A node by its full name, or by the part before the `@`.
  defp node_named(name) do
    Enum.find([node() | Node.list()], fn node ->
      Atom.to_string(node) in [name, "#{name}@#{host(node)}"]
    end)
  end

  defp host(node), do: node |> Atom.to_string() |> String.split("@", parts: 2) |> List.last()

  # A name that is an agent's, in this client's scope or as a whole key, is
  # connected to. Otherwise the fleet is searched for it: one agent whose key
  # holds it is the one meant; several are offered to pick from.
  defp connect(term, name) do
    key = key(term, name)

    if key == term.assigns.agent_id or Fleet.whereis(key) != nil do
      Connection.connect_key(term, key)
    else
      case matching(name) do
        [] -> Display.append(term, View.no_such_agent(key))
        [member] -> Connection.connect_key(term, member.key)
        _several -> Interaction.pick(term, "/connect", [], String.trim_leading(name, "/"))
      end
    end
  end

  defp matching(name) do
    text = name |> String.trim_leading("/") |> String.downcase()
    Enum.filter(Fleet.list(), &String.contains?(String.downcase(&1.key), text))
  end

  # A bare name is an agent beside this client's own, under the same org and
  # user; `org/user/name` is any agent in the fleet. A leading slash is
  # tolerated, as is a key nothing holds, which the lookup then reports.
  defp key(term, target) do
    case target |> String.trim_leading("/") |> String.split("/") do
      [name] -> Fleet.key(name, term.assigns.spawn_opts)
      parts -> Enum.join(parts, "/")
    end
  end

  # `/stop NAME` interrupts one agent, and `/stop PREFIX/` every agent under a
  # prefix. Both leave the agents running.
  defp stop(term, target) do
    target = String.trim_leading(target, "/")

    if String.ends_with?(target, "/") do
      Display.append(term, View.stopped_under(target, Fleet.kill(target)))
    else
      key = key(term, target)

      case Agent.interrupt(key) do
        :ok -> Display.append(term, View.stopped(key))
        {:error, :not_found} -> Display.append(term, View.no_such_agent(key))
      end
    end
  end

  # Stops an agent and keeps its store, so `/spawn` brings it back as it was.
  # The attached agent may be shut down; the status row then says so.
  defp shutdown(term, name) do
    key = key(term, name)

    case Fleet.stop(key) do
      :ok -> term |> Connection.refresh_fleet() |> Display.append(View.shut_down(key, name))
      {:error, :noproc} -> Display.append(term, View.no_such_agent(key))
      {:error, reason} -> Display.append(term, View.error(reason))
    end
  end

  # Prefix removal always previews exact targets. A single named agent may
  # be removed at once with `--yes`. The attached agent is left out and named.
  defp remove(term, target, confirmed?) do
    target = String.trim_leading(target, "/")
    prefix? = String.ends_with?(target, "/")

    case targets(term, target, prefix?) do
      {[], nil} when prefix? -> Display.append(term, View.nothing_under(target))
      {[], nil} -> Display.append(term, View.no_such_agent(key(term, target)))
      {[], attached} -> Display.append(term, View.attached(attached))
      {keys, _skipped} when confirmed? and not prefix? -> forget_all(term, keys)
      {keys, skipped} -> preview(term, target, keys, skipped)
    end
  end

  defp targets(%{assigns: %{agent_id: attached}}, prefix, true) do
    keys = prefix |> Fleet.list() |> Enum.map(& &1.key)
    {List.delete(keys, attached), if(attached in keys, do: attached)}
  end

  defp targets(%{assigns: %{agent_id: attached}} = term, name, false) do
    key = key(term, name)

    cond do
      key == attached -> {[], attached}
      Fleet.whereis(key) -> {[key], nil}
      true -> {[], nil}
    end
  end

  defp preview(term, target, keys, skipped) do
    term
    |> assign(confirm: {:rm, keys})
    |> Display.append(View.removal_preview(target, keys, skipped))
  end

  defp confirm(%{assigns: %{confirm: {:rm, keys}}} = term) do
    term |> assign(confirm: nil) |> forget_all(keys)
  end

  defp confirm(%{assigns: %{confirm: {:move, key, node}}} = term) do
    term |> assign(confirm: nil) |> move_now(key, node)
  end

  defp confirm(term), do: Interaction.flash(term, View.nothing_to_confirm())

  defp forget_all(term, keys) do
    {removed, failed} = Enum.split_with(keys, &(Fleet.forget(&1) == :ok))
    term = assign(term, views: Map.drop(term.assigns.views, removed))

    case failed do
      [] -> term |> Connection.refresh_fleet() |> Display.append(View.forgotten(keys))
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

  defp ask(%{assigns: %{available?: false, agent_id: key}} = term, _text),
    do: Display.append(term, View.unavailable(key))

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
    term
  end
end
