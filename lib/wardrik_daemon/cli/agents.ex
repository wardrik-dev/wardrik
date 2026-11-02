defmodule WardrikDaemon.CLI.Agents do
  @moduledoc "The commands on agents: listing, showing, asking, following and stopping them."

  alias Wardrik.AgentID
  alias WardrikDaemon.CLI.Clock
  alias WardrikDaemon.CLI.Command
  alias WardrikDaemon.CLI.Context
  alias WardrikDaemon.CLI.Follow
  alias WardrikDaemon.CLI.Table
  alias WardrikDaemon.Console.Markdown
  alias WardrikDaemon.Owners

  @group "Agents"

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
          "A QUERY is words that must all match: text in the ID, name:, org:, user:, node:,",
          "status:idle, status:running, status:parked or status:asleep, and attention, an agent",
          "waiting on a person."
        ],
        run: &listed/3
      },
      %Command{
        name: "agent show",
        group: @group,
        arguments: "AGENT",
        count: 1,
        summary: "what an agent is, and what it does now",
        run: &shown/3
      },
      %Command{
        name: "agent ask",
        shortcut: "ask",
        group: @group,
        arguments: "AGENT MESSAGE",
        switches: [no_wait: :boolean],
        count: {2, :any},
        summary: "send an agent a message, and follow its answer",
        details: [
          "Its reasoning shows faint as it comes, then its answer, with each tool call it makes.",
          "It follows the turn until it ends or waits on a person; Ctrl-C stops following, and the",
          "agent carries on. --no-wait only sends it."
        ],
        run: &asked/3
      },
      %Command{
        name: "agent follow",
        shortcut: "follow",
        group: @group,
        arguments: "AGENT",
        count: 1,
        summary: "follow what an agent does, until Ctrl-C",
        details: ["With --json, each event as the HTTP API streams it, a line each."],
        run: fn [agent], _flags, cx -> Follow.events(cx, Context.agent(cx, agent)) end
      },
      %Command{
        name: "agent history",
        group: @group,
        arguments: "AGENT",
        count: 1,
        summary: "an agent's conversation",
        run: &history/3
      },
      change("agent clear", "empty an agent's conversation", "agent.clear", "Cleared"),
      change("agent start", "start an agent that sleeps", "agent.spawn", "Started"),
      change("agent stop", "stop an agent until something wakes it", "agent.stop", "Stopped"),
      %Command{
        name: "agent cancel",
        group: @group,
        arguments: "AGENT...",
        switches: [all: :boolean],
        count: {0, :any},
        summary: "stop the turn an agent runs or waits in",
        details: [
          "Several AGENTs stop each one's turn, and --all those of every agent there is. The",
          "messages waiting behind a turn go too."
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
        count: 1,
        summary: "the tool calls an agent is running now",
        run: &calls/3
      },
      %Command{
        name: "agent kill",
        group: @group,
        arguments: "AGENT CALL",
        count: 2,
        summary: "stop one tool call an agent is running",
        run: &killed/3
      },
      %Command{
        name: "agent move",
        group: @group,
        arguments: "AGENT NODE",
        count: 2,
        summary: "start an agent again on another node of the cluster",
        run: &moved/3
      }
    ]
  end

  defp change(name, summary, operation, said) do
    %Command{
      name: name,
      group: @group,
      arguments: "AGENT",
      count: 1,
      summary: summary,
      run: fn [agent], _flags, cx ->
        id = Context.agent(cx, agent)

        with {:ok, answer} <- Context.call(cx, operation, %{"agent" => id}),
             do: Context.done(cx, answer, "#{said} #{id}.")
      end
    }
  end

  defp cancelled([], %{all: true}, cx), do: cancelled_all(cx, %{})

  defp cancelled([agent], flags, cx) when not is_map_key(flags, :all),
    do: cancelled_one(cx, Context.agent(cx, agent))

  defp cancelled([_ | _] = agents, flags, cx) when not is_map_key(flags, :all),
    do: cancelled_all(cx, %{"agents" => Enum.map(agents, &Context.agent(cx, &1))})

  defp cancelled(_arguments, _flags, _cx),
    do: {:error, "Usage: wardrik agent cancel AGENT..., or --all alone"}

  defp cancelled_one(cx, id) do
    with {:ok, answer} <- Context.call(cx, "agent.cancel", %{"agent" => id}),
         do: Context.done(cx, answer, "Stopped the turn of #{id}.")
  end

  defp cancelled_all(cx, input) do
    with {:ok, %{"cancelled" => ids} = answer} <- Context.call(cx, "agents.cancel", input),
         do: Context.done(cx, answer, stopped(ids))
  end

  defp stopped([]), do: "No agent was taking a turn."
  defp stopped(ids), do: "Stopped the turns of #{Enum.join(ids, ", ")}."

  defp listed(query, flags, cx) do
    with {:ok, %{"agents" => all}} <- Context.call(cx, "agents.list", %{}) do
      agents = Enum.filter(all, &matches?(&1, query))

      Table.show(cx, %{"agents" => agents},
        header: ["AGENT", "STATUS", "QUEUED", "NEXT RUN", "SPENT TODAY", "CONVERSATIONS"],
        rows: rows(agents, Map.get(flags, :all, false)),
        empty: if(query == [], do: "No agents yet.", else: "No agents match.")
      )
    end
  end

  defp rows(agents, true), do: for(agent <- agents, do: row(agent, agent["spent_today"], nil))

  defp rows(agents, false) do
    {conversations, own} = Enum.split_with(agents, &AgentID.conversation?(&1["id"]))
    by_agent = Enum.group_by(conversations, &AgentID.agent(&1["id"]))

    for agent <- own do
      held = Map.get(by_agent, agent["id"], [])
      spent = Enum.reduce(held, agent["spent_today"], &added(&2, &1["spent_today"]))
      row(agent, spent, if(held != [], do: length(held)))
    end
  end

  defp row(agent, spent, conversations),
    do: [
      agent["id"],
      agent["status"],
      queued(agent["pending"]),
      Clock.from_now(agent["next_run"]),
      spent(spent),
      conversations
    ]

  defp added(%{"tokens" => tokens, "usd" => usd}, %{"tokens" => more, "usd" => more_usd}),
    do: %{"tokens" => tokens + more, "usd" => usd + more_usd}

  defp added(spent, _none), do: spent

  defp spent(%{"tokens" => tokens, "usd" => usd}), do: spent(tokens, usd, usd > 0)
  defp spent(_none), do: nil

  defp spent(0, _usd, false), do: nil
  defp spent(tokens, _usd, false), do: "#{Clock.amount(tokens)} tokens"

  defp spent(tokens, usd, true),
    do: "#{Clock.amount(tokens)} tokens, $#{:erlang.float_to_binary(usd / 1, decimals: 2)}"

  defp matches?(agent, query), do: Enum.all?(query, &matches_word?(agent, &1))

  defp matches_word?(agent, "attention"), do: agent["status"] == "parked"
  defp matches_word?(agent, "status:" <> status), do: agent["status"] == status
  defp matches_word?(agent, "node:" <> node), do: agent["node"] == node
  defp matches_word?(agent, "name:" <> name), do: id(agent).name == name
  defp matches_word?(agent, "org:" <> org), do: org(id(agent)) == org
  defp matches_word?(agent, "user:" <> user), do: user(id(agent)) in [user, "@" <> user]
  defp matches_word?(agent, text), do: String.contains?(agent["id"], text)

  defp id(agent) do
    {:ok, id} = AgentID.parse(agent["id"])
    id
  end

  defp org(%AgentID{owner: owner}), do: Owners.org(owner)

  defp user(%AgentID{owner: owner}) do
    case Owners.person(owner) do
      nil -> nil
      person -> "@" <> person
    end
  end

  defp queued(pending) when pending in [nil, 0], do: nil
  defp queued(pending), do: pending

  defp shown([agent], _flags, cx) do
    id = Context.agent(cx, agent)

    with {:ok, read} <- Context.call(cx, "agent.read", %{"agent" => id}),
         {:ok, %{"definition" => definition, "missing" => missing}} <-
           Context.call(cx, "agent.definition", %{"agent" => id}) do
      Context.show(cx, %{"agent" => read, "definition" => definition}, fn _answer ->
        Table.pairs(cx, [
          {"agent", id},
          {"status", read["status"]},
          {"description", definition["description"]},
          {"model", definition["model"]},
          {"tools", Enum.join(Map.get(definition, "tools", []), ", ")},
          {"policy", policy(definition["policy"])},
          {"triggers",
           definition |> Map.get("triggers", []) |> Enum.map_join(", ", & &1["name"])},
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

  defp asked([agent | words], %{no_wait: true}, cx) do
    id = Context.agent(cx, agent)
    input = %{"agent" => id, "content" => Enum.join(words, " ")}

    with {:ok, answer} <- Context.call(cx, "agent.ask", input),
         do: Context.done(cx, answer, "Sent it to #{id}.")
  end

  defp asked([agent | words], _flags, cx),
    do: Follow.turn(cx, agent: Context.agent(cx, agent), text: Enum.join(words, " "))

  defp history([agent], _flags, cx) do
    with {:ok, %{"items" => items} = answer} <-
           Context.call(cx, "agent.timeline", %{"agent" => Context.agent(cx, agent)}) do
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
    id = Context.agent(cx, agent)

    with {:ok, answer} <- Context.call(cx, "agent.forget", %{"agent" => id}),
         do: Context.done(cx, answer, "Removed #{id}.")
  end

  defp calls([agent], _flags, cx) do
    with {:ok, %{"calls" => calls} = answer} <-
           Context.call(cx, "agent.calls", %{"agent" => Context.agent(cx, agent)}) do
      Table.show(cx, answer,
        header: ["CALL", "TOOL", "RUNNING FOR"],
        rows:
          for(call <- calls, do: [call["id"], call["name"], "#{div(call["elapsed_ms"], 1000)}s"]),
        empty: "It runs no tool calls now."
      )
    end
  end

  defp killed([agent, call], _flags, cx) do
    input = %{"agent" => Context.agent(cx, agent), "call" => call}

    with {:ok, answer} <- Context.call(cx, "agent.kill", input),
         do: Context.done(cx, answer, "Stopped #{call}.")
  end

  defp moved([agent, node], _flags, cx) do
    id = Context.agent(cx, agent)

    with {:ok, answer} <- Context.call(cx, "agent.move", %{"agent" => id, "node" => node}),
         do: Context.done(cx, answer, "Moved #{id} to #{node}.")
  end
end
