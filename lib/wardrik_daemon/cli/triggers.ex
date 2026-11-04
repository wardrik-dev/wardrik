defmodule WardrikDaemon.CLI.Triggers do
  @moduledoc false

  alias WardrikDaemon.CLI.Clock
  alias WardrikDaemon.CLI.Command
  alias WardrikDaemon.CLI.Context
  alias WardrikDaemon.CLI.Table

  @group "Triggers"
  @fields [:every, :timezone, :prompt, :prompt_file, :feed, :overlap]

  @doc "Returns the commands on triggers."
  @spec commands() :: [Command.t()]
  def commands do
    [
      %Command{
        name: "trigger ls",
        group: @group,
        arguments: "AGENT",
        count: 1,
        summary: "an agent's triggers, and when each runs",
        run: &listed/3
      },
      %Command{
        name: "trigger set",
        group: @group,
        arguments: "AGENT NAME",
        switches: Enum.map(@fields, &{&1, :string}),
        count: 2,
        summary: "set one of an agent's triggers",
        details: [
          "--every takes a cron expression, as \"0 9 * * 1-5\", or an interval, as 30m, read in",
          "--timezone. --prompt is what it asks, or --prompt-file a file of the agent's to follow.",
          "--feed watches an RSS or Atom feed. --overlap is skip, queue or settle.",
          "An agent a file declares keeps its file's triggers on the next reload."
        ],
        run: &set/3
      },
      %Command{
        name: "trigger rm",
        group: @group,
        arguments: "AGENT NAME",
        count: 2,
        summary: "remove one of an agent's triggers",
        run: &removed/3
      }
    ]
  end

  defp listed([agent], _flags, cx) do
    with {:ok, id} <- Context.agent(cx, agent),
         {:ok, %{"definition" => definition} = read} <-
           Context.call(cx, "agent.definition", %{"agent" => id}) do
      triggers = Map.get(definition, "triggers", [])
      next = Map.get(read, "next_runs", %{})

      rows =
        for trigger <- triggers,
            do: [
              trigger["name"],
              runs(trigger),
              Clock.from_now(next[trigger["name"]]),
              asks(trigger)
            ]

      Table.show(cx, %{"triggers" => triggers, "next_runs" => next},
        header: ["TRIGGER", "RUNS", "NEXT", "ASKS"],
        rows: rows,
        empty: "No triggers."
      )
    end
  end

  defp runs(%{"every" => every, "timezone" => zone}), do: "every #{every} (#{zone})"
  defp runs(%{"every" => every}), do: "every #{every}"
  defp runs(%{"webhook" => _webhook}), do: "on a webhook"
  defp runs(_trigger), do: ""

  defp asks(%{"prompt_file" => file}), do: "follows #{file}"

  defp asks(%{"prompt" => prompt}) when byte_size(prompt) > 60,
    do: String.slice(prompt, 0, 59) <> "…"

  defp asks(%{"prompt" => prompt}), do: prompt
  defp asks(_trigger), do: ""

  defp set([agent, name], flags, cx) do
    fields =
      for {key, value} <- flags, key in @fields, into: %{}, do: {Atom.to_string(key), value}

    with {:ok, id} <- Context.agent(cx, agent),
         input = Map.merge(fields, %{"agent" => id, "trigger" => name}),
         {:ok, answer} <- Context.call(cx, "agent.trigger_set", input),
         do: Context.done(cx, answer, "Set #{name}.")
  end

  defp removed([agent, name], _flags, cx) do
    with {:ok, id} <- Context.agent(cx, agent),
         {:ok, answer} <-
           Context.call(cx, "agent.trigger_remove", %{"agent" => id, "trigger" => name}),
         do: Context.done(cx, answer, "Removed #{name}.")
  end
end
