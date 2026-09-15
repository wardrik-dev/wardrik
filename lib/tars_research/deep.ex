defmodule TarsResearch.Deep do
  @moduledoc """
  Research a topic by splitting it across angles, one agent each, then
  combining what comes back.

      Tars.LLM.Config.new(tools: [TarsBrave.WebSearch, TarsResearch.Deep])

  The agent reaches it as the `deep_research` tool. It is also an ordinary
  `Tars.Workflow.Step`, so a deployment can run it directly or use it inside a
  larger workflow:

      TarsResearch.Deep.run(%{topic: "the WASM component model"}, scope, [])

  ## Angles of your own

  `tool/1` builds the same tool with angles chosen for a deployment. Each is a
  map naming the angle and, optionally, what makes it different:

      TarsResearch.Deep.tool(
        angles: [
          %{
            angle: "pricing and packaging",
            prompt: "Think like a pricing analyst. Compare list price against effective price."
          },
          %{angle: "recent developments"}
        ]
      )

  `:prompt` is added to the researcher's persona rather than replacing it, so
  it says what is different about this angle and the research discipline is
  still there. A malformed angle raises where the config is built.

  These are defaults. A caller that supplies its own angles overrides them,
  and its angles arrive as plain names with the default persona.

  ## What it needs

  Nothing. Researchers run with the calling agent's model and tools, minus
  this one, so a deployment says what research can reach by choosing the
  agent's tools and nothing has to be configured twice. Dropping this tool
  from the researchers' set also means a sweep cannot start another sweep.

  Give the agent a search tool, or research is limited to what the model
  already knows.

  ## Gaps

  Angles are independent, so an angle that fails, crashes, or runs over time
  is reported as a gap and the rest are still synthesised. Only a sweep where
  every angle failed is an error.

  ## Extracting this package

  When research moves out into `tars_research`, three things change and
  nothing else:

    1. `lib/tars_research/` and `test/tars_research/` move into the new
       project, which declares `{:tars, "~> 0.1"}` itself.
    2. Tars depends on it, first as `{:tars_research, path: "packs/tars_research"}`
       and later as a version.
    3. Any setting it grows becomes `config :tars_research, ...` instead of
       the nested `config :tars, TarsResearch, ...` key.

  Nothing in `Tars` itself is touched, because core names no workflow.
  """

  @behaviour Tars.Tool
  @behaviour Tars.Workflow.Step

  alias Tars.Subagent
  alias Tars.Workflow

  @typedoc "One angle to research, and optionally what makes it different."
  @type angle() :: %{required(:angle) => String.t(), optional(:prompt) => String.t()}

  # Long enough for a full sweep: branches are capped at five minutes each by
  # `Tars.Workflow.fan_out/4`, and synthesis runs a turn of its own after them.
  @timeout :timer.minutes(10)

  @impl Tars.Tool
  def tool, do: tool([])

  @impl Tars.Tool
  def timeout, do: @timeout

  @doc """
  Builds the tool with angles, or a branch limit, of your own.

  Options are `:angles` and `:max_concurrency`. Angles are checked here, so a
  malformed one raises at `Tars.LLM.Config.new/1` rather than part way through
  a sweep.
  """
  @spec tool(keyword()) :: ReqLLM.Tool.t()
  def tool(opts) when is_list(opts) do
    Workflow.as_tool({__MODULE__, Keyword.put(opts, :angles, configured(opts))},
      name: "deep_research",
      description: """
      Research a topic thoroughly by splitting it across several angles, investigating each one separately and at the same time, then combining the findings into one report.

      Use it when one search will not settle the question: a market, the state of a technology, a competitive landscape, a decision with several dimensions. For a single fact, search directly instead.

      Each angle goes to its own agent with the same tools you have. Returns the combined report plus any angles that could not be finished, so a partial answer is still an answer.
      """,
      parameter_schema: [
        topic: [
          type: :string,
          required: true,
          doc: "What to research, stated as you would to a colleague. One topic, not several."
        ],
        angles: [
          type: {:list, :string},
          doc:
            "The angles to split the work across, one agent each. Leave it out to use the defaults. Supply your own when the topic has obvious dimensions worth separating."
        ]
      ]
    )
  end

  @doc """
  Researches `topic` across its angles and returns the report.

  Options are `:angles` and `:max_concurrency`, which defaults to five.
  """
  @impl Tars.Workflow.Step
  def run(%{topic: topic} = args, scope, opts) do
    scope
    |> Workflow.fan_out(
      briefs(args, opts),
      fn brief, branch ->
        Subagent.run(branch, "Topic: #{topic}\nYour angle: #{brief.angle}",
          system: persona(brief),
          except_tools: ["deep_research"]
        )
      end,
      name: & &1.angle,
      max_concurrency: Keyword.get(opts, :max_concurrency, 5)
    )
    |> synthesise(topic, scope)
  end

  defp synthesise(outcomes, topic, scope) do
    case Workflow.split(outcomes) do
      {[], gaps} ->
        {:error, {:no_findings, describe(gaps)}}

      {findings, gaps} ->
        # Synthesis reads what the researchers found. Anything it looked up
        # itself would be a sixth opinion nobody asked for.
        with {:ok, report} <-
               Subagent.run(scope, findings_prompt(topic, findings),
                 name: "synthesis",
                 system: synthesist_persona(),
                 tools: []
               ) do
          {:ok, %{"topic" => topic, "report" => report, "gaps" => describe(gaps)}}
        end
    end
  end

  # A caller that named its own angles gets them as plain names. Only a
  # deployment attaches a persona, because a caller supplies strings through a
  # JSON schema and should not be writing personas for its own subagents.
  defp briefs(%{angles: [_first | _rest] = angles}, _opts),
    do: Enum.map(angles, &%{angle: &1, prompt: nil})

  defp briefs(_args, opts), do: configured(opts)

  defp configured(opts) do
    opts
    |> Keyword.get(:angles, default_angles())
    |> normalise!()
  end

  defp normalise!(angles) when is_list(angles), do: Enum.map(angles, &normalise_one!/1)

  defp normalise_one!(%{angle: angle} = spec) when is_binary(angle) do
    case Map.keys(spec) -- [:angle, :prompt] do
      [] ->
        %{angle: angle, prompt: Map.get(spec, :prompt)}

      unknown ->
        raise ArgumentError,
              "unknown angle keys #{inspect(unknown)}, expected :angle or :prompt"
    end
  end

  defp normalise_one!(other) do
    raise ArgumentError,
          "expected an angle as %{angle: name, prompt: note}, got: #{inspect(other)}"
  end

  defp default_angles do
    [
      %{angle: "current state and recent developments"},
      %{angle: "the main players and how they differ"},
      %{angle: "concrete numbers: pricing, scale, growth, benchmarks"},
      %{angle: "criticism, risks and open problems"},
      %{angle: "where this appears to be heading"}
    ]
  end

  defp persona(%{prompt: nil}), do: researcher_persona()
  defp persona(%{prompt: prompt}), do: researcher_persona() <> "\n\n" <> prompt

  defp researcher_persona do
    """
    You are a researcher covering one angle of a larger question, alongside others taking the rest.

    Search for what you need rather than answering from memory. Name the source of every substantive claim. Stay on your angle and leave the rest to the others. Where you found nothing, say so plainly rather than filling the gap with what you would have expected.
    """
  end

  defp synthesist_persona do
    """
    You combine several researchers' reports into one.

    Say what is established, where the reports disagree, and what is still unknown. Carry each claim's source through. Leave out an angle that added nothing rather than padding the report with it, and never add a finding the reports do not support.
    """
  end

  defp findings_prompt(topic, findings) do
    """
    Topic: #{topic}

    #{Enum.map_join(findings, "\n\n", fn {brief, report} -> "## #{brief.angle}\n\n#{report}" end)}
    """
  end

  defp describe(gaps),
    do:
      Enum.map(gaps, fn {brief, reason} ->
        %{"angle" => brief.angle, "reason" => inspect(reason)}
      end)
end
