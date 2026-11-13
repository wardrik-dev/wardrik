defmodule WardrikDaemon.CLI.Agents do
  @moduledoc false

  alias WardrikDaemon.CLI.Clock
  alias WardrikDaemon.CLI.Command
  alias WardrikDaemon.CLI.Context
  alias WardrikDaemon.CLI.Follow
  alias WardrikDaemon.CLI.Table
  alias WardrikDaemon.Console.Markdown

  @group "Agents"
  @conversation [conversation: :string]

  @doc "Returns the commands on agents."
  @spec commands() :: [Command.t()]
  def commands do
    [
      %Command{
        name: "agent ls",
        shortcut: "ls",
        group: @group,
        arguments: "[QUERY]",
        switches: [all: :boolean],
        count: {0, :any},
        summary: "list the agents, and what each is doing",
        details: [
          "Each agent's conversations, as a Slack thread's, are counted; --all lists them too.",
          "A QUERY is words that must all match: text in the name or ID, name:, org:, node:,",
          "user:, as user:acme/@jon, status:idle, status:running, status:parked or status:asleep,",
          "and attention, an agent waiting on a person."
        ],
        run: &listed/3
      },
      %Command{
        name: "agent show",
        group: @group,
        arguments: "AGENT",
        switches: @conversation,
        count: 1,
        summary: "what an agent is, and what it does now",
        run: &shown/3
      },
      %Command{
        name: "agent ask",
        shortcut: "ask",
        group: @group,
        arguments: "AGENT [MESSAGE]",
        switches: [no_wait: :boolean] ++ @conversation,
        count: {1, :any},
        summary: "send an agent a message, and follow its answer",
        details: [
          "Prints the answer as it comes, with each tool call. Ctrl-C stops following; the agent",
          "carries on. --no-wait only sends it. --conversation ID sends it to one conversation.",
          "With no MESSAGE at a terminal, it's written in $VISUAL or $EDITOR."
        ],
        run: &asked/3
      },
      %Command{
        name: "agent follow",
        shortcut: "follow",
        group: @group,
        arguments: "AGENT",
        switches: @conversation,
        count: 1,
        summary: "follow what an agent does, until Ctrl-C",
        details: ["With --json, each event as the HTTP API streams it, a line each."],
        run: &followed/3
      },
      %Command{
        name: "agent history",
        group: @group,
        arguments: "AGENT",
        switches: @conversation,
        count: 1,
        summary: "an agent's conversation",
        run: &history/3
      },
      change(
        "agent clear",
        "empty an agent's history",
        {"agent.clear", @conversation},
        "Cleared"
      ),
      change("agent start", "start an agent that sleeps", {"agent.spawn", []}, "Started"),
      change(
        "agent stop",
        "stop an agent until something wakes it",
        {"agent.stop", @conversation},
        "Stopped"
      ),
      %Command{
        name: "agent cancel",
        group: @group,
        arguments: "AGENT...",
        switches: [all: :boolean] ++ @conversation,
        count: {0, :any},
        summary: "stop the turn an agent runs or waits in",
        details: [
          "--all stops every agent's turn. Messages queued behind a turn are dropped too."
        ],
        run: &cancelled/3
      },
      %Command{
        name: "agent rm",
        group: @group,
        arguments: "AGENT",
        count: 1,
        summary: "remove an agent, and everything it had",
        details: ["An agent a file declares stays; remove its file and reload instead."],
        run: &removed/3
      },
      %Command{
        name: "agent calls",
        group: @group,
        arguments: "AGENT",
        switches: @conversation,
        count: 1,
        summary: "the tool calls an agent is running now",
        run: &calls/3
      },
      %Command{
        name: "agent kill",
        group: @group,
        arguments: "AGENT CALL",
        switches: @conversation,
        count: 2,
        summary: "stop one tool call an agent is running",
        run: &killed/3
      },
      %Command{
        name: "agent move",
        group: @group,
        arguments: "AGENT NODE",
        switches: @conversation,
        count: 2,
        summary: "start an agent again on another node of the cluster",
        run: &moved/3
      }
    ]
  end

  defp change(name, summary, {operation, switches}, said) do
    %Command{
      name: name,
      group: @group,
      arguments: "AGENT",
      switches: switches,
      count: 1,
      summary: summary,
      run: fn [agent], flags, cx ->
        with {:ok, id} <- Context.agent(cx, agent),
             input = Context.conversation(%{"agent" => id}, flags),
             {:ok, answer} <- Context.call(cx, operation, input),
             do: Context.done(cx, answer, "#{said} #{agent}.")
      end
    }
  end

  defp followed([agent], flags, cx) do
    with {:ok, id} <- Context.agent(cx, agent),
         do: Follow.events(cx, agent: id, name: agent, conversation: flags[:conversation])
  end

  defp cancelled([], %{all: true} = flags, cx) when not is_map_key(flags, :conversation),
    do: cancelled_all(cx, %{})

  defp cancelled([agent], flags, cx) when not is_map_key(flags, :all) do
    with {:ok, id} <- Context.agent(cx, agent),
         {:ok, answer} <-
           Context.call(cx, "agent.cancel", Context.conversation(%{"agent" => id}, flags)),
         do: Context.done(cx, answer, "Stopped the turn of #{agent}.")
  end

  defp cancelled([_ | _] = agents, flags, cx)
       when not is_map_key(flags, :all) and not is_map_key(flags, :conversation) do
    with {:ok, ids} <- Context.agents(cx, agents), do: cancelled_all(cx, %{"agents" => ids})
  end

  defp cancelled(_arguments, _flags, _cx),
    do:
      {:error, "Usage: wardrik agent cancel AGENT [--conversation ID], AGENT..., or --all alone"}

  defp cancelled_all(cx, input) do
    with {:ok, %{"cancelled" => ids} = answer} <- Context.call(cx, "agents.cancel", input) do
      names = if ids == [], do: %{}, else: Context.names(cx)
      Context.done(cx, answer, stopped(Enum.map(ids, &shown(names, &1))))
    end
  end

  defp stopped([]), do: "No agent was taking a turn."
  defp stopped(names), do: "Stopped the turns of #{Enum.join(names, ", ")}."

  defp shown(names, id), do: get_in(names, [id, "shown"]) || id

  defp listed(query, flags, cx) do
    with {:ok, %{"agents" => all}} <- Context.call(cx, "agents.list", %{}) do
      names = Context.names(cx)
      agents = Enum.filter(all, &matches?(&1, names[&1["id"]], query))

      Table.show(cx, %{"agents" => agents},
        header: ["AGENT", "STATUS", "QUEUED", "NEXT RUN", "SPENT TODAY", "CONVERSATIONS"],
        rows: rows(agents, names, Map.get(flags, :all, false)),
        empty: if(query == [], do: "No agents yet.", else: "No agents match.")
      )
    end
  end

  defp rows(agents, names, true),
    do:
      for(
        agent <- agents,
        do: row(shown(names, agent["id"]), agent, agent["spent_today"], agent["conversation"])
      )

  defp rows(agents, names, false) do
    {conversations, own} = Enum.split_with(agents, &Map.has_key?(&1, "conversation"))
    by_agent = Enum.group_by(conversations, & &1["id"])

    for agent <- own do
      held = Map.get(by_agent, agent["id"], [])
      spent = Enum.reduce(held, agent["spent_today"], &added(&2, &1["spent_today"]))
      row(shown(names, agent["id"]), agent, spent, if(held != [], do: length(held)))
    end
  end

  defp row(name, agent, spent, conversations),
    do: [
      name,
      status(agent["status"]),
      queued(agent["pending"]),
      Clock.from_now(agent["next_run"]),
      spent(spent),
      conversations
    ]

  defp status("running"), do: {"running", :cyan}
  defp status("parked"), do: {"parked", :yellow}
  defp status("asleep"), do: {"asleep", :light_black}
  defp status("unreadable"), do: {"unreadable", :red}
  defp status(status), do: status

  defp added(%{"tokens" => tokens, "usd" => usd}, %{"tokens" => more, "usd" => more_usd}),
    do: %{"tokens" => tokens + more, "usd" => usd + more_usd}

  defp added(spent, _none), do: spent

  defp spent(%{"tokens" => tokens, "usd" => usd}), do: spent(tokens, usd, usd > 0)
  defp spent(_none), do: nil

  defp spent(0, _usd, false), do: nil
  defp spent(tokens, _usd, false), do: "#{Clock.amount(tokens)} tokens"

  defp spent(tokens, usd, true),
    do: "#{Clock.amount(tokens)} tokens, $#{:erlang.float_to_binary(usd / 1, decimals: 2)}"

  defp matches?(agent, named, query),
    do: Enum.all?(query, &matches_word?(agent, named || %{}, &1))

  defp matches_word?(agent, _named, "attention"), do: agent["status"] in ["parked", "unreadable"]
  defp matches_word?(agent, _named, "status:" <> status), do: agent["status"] == status
  defp matches_word?(agent, _named, "node:" <> node), do: agent["node"] == node
  defp matches_word?(_agent, named, "name:" <> name), do: named["name"] == name
  defp matches_word?(_agent, named, "org:" <> org), do: named["org"] == org
  defp matches_word?(_agent, named, "user:" <> user), do: named["owner"] == user

  defp matches_word?(agent, named, text),
    do: String.contains?(agent["id"], text) or String.contains?(named["name"] || "", text)

  defp queued(pending) when pending in [nil, 0], do: nil
  defp queued(pending), do: pending

  defp shown([agent], flags, cx) do
    with {:ok, id} <- Context.agent(cx, agent),
         {:ok, read} <-
           Context.call(cx, "agent.read", Context.conversation(%{"agent" => id}, flags)),
         {:ok, %{"definition" => definition, "missing" => missing}} <-
           Context.call(cx, "agent.definition", %{"agent" => id}) do
      Context.show(cx, %{"agent" => read, "definition" => definition}, fn _answer ->
        Table.pairs(cx, [
          {"agent", agent},
          {"id", id},
          {"conversation", flags[:conversation]},
          {"status", read["status"]},
          {"problem", read["problem"]},
          {"description", definition["description"]},
          {"model", definition["model"]},
          {"tools", Enum.join(Map.get(definition, "tools", []), ", ")},
          {"policy", policy(definition["policy"])},
          {"triggers", Enum.map_join(Map.get(definition, "triggers", []), ", ", & &1["name"])},
          {"channels", Enum.join(Map.get(definition, "channels", []), ", ")},
          {"missing", Enum.join(missing, ", ")}
        ])

        waiting(cx, read["interrupts"])
      end)
    end
  end

  defp waiting(_cx, []), do: :ok

  defp waiting(cx, interrupts) do
    Context.puts(cx, Owl.Data.tag("Waiting on a person for:", [:bright, :yellow]))
    Enum.each(interrupts, &Context.puts(cx, interrupt(&1)))
  end

  defp interrupt(interrupt),
    do: [
      "  ? ",
      interrupt["name"] || "the model",
      "  ",
      interrupt["id"],
      "  ",
      interrupt["message"]
    ]

  defp policy(nil), do: nil
  defp policy(name) when is_binary(name), do: name
  defp policy(_rules), do: "its own rules"

  defp asked([agent], flags, %{terminal: %{input?: true}} = cx) do
    with {:ok, editor} <- editor(cx) do
      case written(cx, editor, agent) do
        "" -> {:error, "The message was empty, so nothing was sent."}
        message -> asked([agent, message], flags, cx)
      end
    end
  end

  defp asked([_agent], _flags, cx),
    do: {:error, "Give the message: #{cx.program} ask AGENT MESSAGE"}

  defp asked([agent | words], %{no_wait: true} = flags, cx) do
    with {:ok, id} <- Context.agent(cx, agent),
         input = %{"agent" => id, "content" => Enum.join(words, " ")},
         {:ok, answer} <- Context.call(cx, "agent.ask", Context.conversation(input, flags)),
         do: Context.done(cx, answer, "Sent it to #{agent}.")
  end

  defp asked([agent | words], flags, cx) do
    with {:ok, id} <- Context.agent(cx, agent),
         do:
           Follow.turn(cx,
             agent: id,
             name: agent,
             conversation: flags[:conversation],
             text: Enum.join(words, " ")
           )
  end

  # The message, written in the person's editor. What the VM runs has no terminal of its own, so
  # an editor that draws in one, as vi does, is given the VM's: on Linux, the device its stdin is.
  # Elsewhere, an editor that opens a window of its own, as `code --wait`, still works.
  defp editor(cx) do
    editor = cx.env["VISUAL"] || cx.env["EDITOR"] || "vi"
    program = hd(String.split(editor, " ", parts: 2))

    if System.find_executable(program),
      do: {:ok, editor},
      else:
        {:error,
         "There's no #{editor} here to write the message in. Set $VISUAL or $EDITOR, or give the message: #{cx.program} ask AGENT MESSAGE"}
  end

  defp written(cx, editor, agent) do
    editor =
      case cx.terminal.tty? and File.read_link("/proc/self/fd/0") do
        {:ok, "/dev/" <> _tty = tty} -> "#{editor} __FILE__ < #{tty} > #{tty}"
        _none -> editor
      end

    "\n<!-- Write the message to #{agent} above. An empty message isn't sent. -->\n"
    |> Owl.IO.open_in_editor(editor: editor, format: "md")
    |> String.replace(~r/<!--.*?-->/s, "")
    |> String.trim()
  end

  defp history([agent], flags, cx) do
    with {:ok, id} <- Context.agent(cx, agent),
         {:ok, %{"items" => items} = answer} <-
           Context.call(cx, "agent.timeline", Context.conversation(%{"agent" => id}, flags)) do
      Context.show(cx, answer, fn _answer -> Enum.each(items, &said(cx, &1)) end)
    end
  end

  defp said(cx, %{"kind" => "user"} = item),
    do: Context.puts(cx, [Owl.Data.tag("› ", :cyan), sender(item["sender"]), item["text"] || ""])

  defp said(cx, %{"kind" => "run", "status" => status, "steps" => steps}) do
    Enum.each(steps, &step(cx, &1))
    ended(cx, status)
    Context.puts(cx, "")
  end

  defp said(_cx, _item), do: :ok

  defp sender(sender) when is_binary(sender), do: Owl.Data.tag(sender <> ": ", :light_black)
  defp sender(_sender), do: []

  defp ended(_cx, "completed"), do: :ok
  defp ended(cx, status), do: Context.puts(cx, Owl.Data.tag("[#{status}]", :yellow))

  defp step(cx, %{"type" => "text", "text" => text}) do
    {lines, buffer} = Markdown.push(Markdown.new(), text)
    {rest, _buffer} = Markdown.flush(buffer)
    Enum.each(lines ++ rest, &markdown(cx, &1))
  end

  defp step(cx, %{"type" => "tool", "name" => name, "status" => status}),
    do: Context.puts(cx, ["  ", tool_mark(status), " ", name])

  defp step(_cx, _step), do: :ok

  defp markdown(cx, %WardrikDaemon.Console.Table{} = table) do
    table
    |> WardrikDaemon.Console.Table.lines(cx.terminal.width)
    |> Enum.each(&Context.puts(cx, &1))
  end

  defp markdown(cx, line), do: Context.puts(cx, line)

  defp tool_mark("ok"), do: Owl.Data.tag("✓", :green)
  defp tool_mark(_status), do: Owl.Data.tag("✗", :red)

  defp removed([agent], _flags, cx) do
    with {:ok, id} <- Context.agent(cx, agent),
         {:ok, answer} <- Context.call(cx, "agent.forget", %{"agent" => id}),
         do: Context.done(cx, answer, "Removed #{agent}.")
  end

  defp calls([agent], flags, cx) do
    with {:ok, id} <- Context.agent(cx, agent),
         {:ok, %{"calls" => calls} = answer} <-
           Context.call(cx, "agent.calls", Context.conversation(%{"agent" => id}, flags)) do
      Table.show(cx, answer,
        header: ["CALL", "TOOL", "RUNNING FOR"],
        rows:
          for(call <- calls, do: [call["id"], call["name"], "#{div(call["elapsed_ms"], 1000)}s"]),
        empty: "It runs no tool calls now."
      )
    end
  end

  defp killed([agent, call], flags, cx) do
    with {:ok, id} <- Context.agent(cx, agent),
         input = Context.conversation(%{"agent" => id, "call" => call}, flags),
         {:ok, answer} <- Context.call(cx, "agent.kill", input),
         do: Context.done(cx, answer, "Stopped #{call}.")
  end

  defp moved([agent, node], flags, cx) do
    with {:ok, id} <- Context.agent(cx, agent),
         input = Context.conversation(%{"agent" => id, "node" => node}, flags),
         {:ok, answer} <- Context.call(cx, "agent.move", input),
         do: Context.done(cx, answer, "Moved #{agent} to #{node}.")
  end
end
