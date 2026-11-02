defmodule WardrikResearch.Deep do
  @moduledoc """
  The `deep_research` tool. Researchers run at once, then a subagent with no tools combines their
  findings.

  Returns `%{"topic" => ..., "report" => ..., "gaps" => [%{"angle" => ..., "reason" => ...}]}`.
  """

  alias WardrikCore.Context

  @timeout :timer.minutes(8)
  @max_concurrency 5
  @max_rounds 12

  @angles [
    %{angle: "current state and recent developments"},
    %{angle: "the main players and how they differ"},
    %{angle: "concrete numbers: pricing, scale, growth, benchmarks"},
    %{angle: "criticism, risks and open problems"},
    %{angle: "where this appears to be heading"}
  ]

  @description """
  Research a topic thoroughly by splitting it across several angles, investigating each one separately and at the same time, then combining the findings into one report.

  Use it when one search won't settle the question: a market, the state of a technology, a competitive landscape, a decision with several dimensions. For a single fact, search directly instead.

  Each angle goes to its own researcher with the same tools you have. Answers the combined report and any angles that couldn't be finished, so a partial answer is still an answer.
  """

  @researcher """
  You're a researcher covering one angle of a larger question, alongside others taking the rest.

  Search for what you need rather than answering from memory. Name the source of every substantive claim. Stay on your angle and leave the rest to the others. Where you found nothing, say so plainly rather than filling the gap with what you'd have expected.
  """

  @synthesist """
  You combine several researchers' reports into one.

  Say what's established, where the reports disagree, and what's still unknown. Carry each claim's source through. Leave out an angle that added nothing rather than padding the report with it, and never add a finding the reports don't support.
  """

  @doc "Returns the tool. Raises `ArgumentError` on a bad angle. See `WardrikResearch` for `opts`."
  @spec tool(keyword()) :: WardrikCore.Tool.t()
  def tool(opts) do
    opts =
      opts
      |> Keyword.validate!(
        angles: @angles,
        max_concurrency: @max_concurrency,
        timeout: @timeout,
        max_rounds: @max_rounds
      )
      |> Keyword.update!(:angles, &Enum.map(&1, fn angle -> brief!(angle) end))

    WardrikCore.Tool.new!(
      name: "deep_research",
      description: @description,
      schema: [
        topic: [
          type: :string,
          required: true,
          doc: "What to research, stated as you would to a colleague. One topic, not several."
        ],
        angles: [
          type: {:list, :string},
          doc:
            "The angles to split the work across, one researcher each. Leave it out for the usual ones. Give your own where the topic has dimensions worth separating."
        ]
      ],
      run: &run(&1, &2, opts),
      annotations: [read_only: true, open_world: true, timeout: opts[:timeout] * 2]
    )
  end

  defp brief!(%{angle: angle} = brief) when is_binary(angle) do
    case Map.keys(brief) -- [:angle, :prompt] do
      [] ->
        %{angle: angle, prompt: Map.get(brief, :prompt)}

      [key | _rest] ->
        raise ArgumentError, "An angle takes :angle and :prompt, not #{inspect(key)}."
    end
  end

  defp brief!(angle),
    do: raise(ArgumentError, "An angle is %{angle: name, prompt: note}, not #{inspect(angle)}.")

  defp run(%{topic: topic} = args, context, opts) do
    briefs = briefs(args, opts)

    researched =
      briefs
      |> Task.async_stream(&research(context, topic, &1, opts),
        max_concurrency: opts[:max_concurrency],
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, outcome} -> outcome end)

    measured = Enum.reduce(researched, %{}, &added(&2, measurements(&1)))
    outcomes = Enum.zip(briefs, researched)
    found = for {brief, {:ok, answer, _measured}} <- outcomes, do: {brief, answer}
    gaps = for {brief, {:error, reason, _measured}} <- outcomes, do: gap(brief, reason)

    combined(context, topic, found, gaps, measured, opts)
  end

  defp briefs(%{angles: [_angle | _rest] = angles}, _opts),
    do: Enum.map(angles, &%{angle: &1, prompt: nil})

  defp briefs(_args, opts), do: opts[:angles]

  defp research(context, topic, brief, opts),
    do:
      WardrikCore.subagent(context, "Topic: #{topic}\nYour angle: #{brief.angle}",
        name: "researcher: #{brief.angle}",
        instructions: persona(brief),
        except_tools: ["deep_research"],
        max_rounds: opts[:max_rounds],
        timeout: opts[:timeout]
      )

  defp persona(%{prompt: nil}), do: @researcher
  defp persona(%{prompt: prompt}), do: @researcher <> "\n" <> prompt

  defp combined(context, _topic, [], gaps, measured, _opts) do
    why = Enum.map_join(gaps, "; ", &"#{&1["angle"]}: #{&1["reason"]}")
    {:error, "Every angle failed. #{why}", Context.measure(context, measured)}
  end

  defp combined(context, topic, found, gaps, measured, opts) do
    case WardrikCore.subagent(context, findings(topic, found),
           name: "synthesis",
           instructions: @synthesist,
           capabilities: [],
           timeout: opts[:timeout]
         ) do
      {:ok, report, more} ->
        labels = found |> Enum.flat_map(fn {_brief, answer} -> answer.labels end) |> Enum.uniq()
        output = %{"topic" => topic, "report" => report.text, "gaps" => gaps}

        {:ok, %ReqLLM.ToolResult{output: output, metadata: %{labels: Enum.sort(labels)}},
         Context.measure(context, added(measured, more))}

      {:error, reason, more} ->
        {:error, "The findings couldn't be brought together: #{said(reason)}",
         Context.measure(context, added(measured, more))}
    end
  end

  defp findings(topic, found) do
    reports =
      Enum.map_join(found, "\n\n", fn {brief, answer} -> "## #{brief.angle}\n\n#{answer.text}" end)

    "Topic: #{topic}\n\n#{reports}"
  end

  defp gap(brief, reason), do: %{"angle" => brief.angle, "reason" => said(reason)}

  defp said(:timeout), do: "it ran out of time"
  defp said({:exit, _reason}), do: "it crashed"
  defp said(:max_rounds), do: "it made as many model calls as it may"
  defp said(reason) when is_binary(reason), do: reason
  defp said(reason), do: inspect(reason)

  defp measurements({_outcome, _answer, measured}), do: measured

  defp added(measured, more),
    do: Map.merge(measured, more, fn _key, held, also -> held + also end)
end
