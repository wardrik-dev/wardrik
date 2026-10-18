defmodule WardrikWorkflow do
  @moduledoc """
  Runs steps: many at once, or one after another.

  It ships no workflows. A workflow is a `WardrikWorkflow.Step` someone
  writes, and it reaches an agent the same way a tool does, by being named in
  a config:

      Wardrik.LLM.Config.new(tools: [WardrikBrave.WebSearch, WardrikResearch.Deep])

  There is no separate list and no registry, because a workflow an agent cannot
  call is just a function the deployment calls itself. `as_tool/2` builds the
  tool that makes one callable.

  ## Fanning out

  `fan_out/4` runs one step over many inputs concurrently and reports one
  outcome per input, whatever happened to it. A branch that returns an error,
  crashes, or runs over time all arrive the same way, so a dead branch is a gap
  the caller decides about rather than the end of the run.

      run
      |> WardrikWorkflow.fan_out(angles, fn angle, branch ->
        Wardrik.Subagent.run(branch, config, prompt(angle))
      end)
      |> WardrikWorkflow.split()

  `max_concurrency: 1` runs the same branches one at a time.

  ## Going in order

  `sequence/3` feeds each step the previous step's result and stops at the
  first error, because a stage whose input never arrived has nothing to do.

      WardrikWorkflow.sequence(run, input, [Fetch, {Summarise, config: config}, Publish])

  For work that depends on more than one earlier result, write it out. The
  call graph is the dependency graph:

      with {:ok, a} <- Step.invoke(Recon, args, run),
           {:ok, b} <- Step.invoke(Baseline, args, run) do
        Step.invoke(Compare, %{recon: a, baseline: b}, run)
      end

  ## Spans

  Both combinators open the child span their work runs under and close it
  afterwards, so a step author cannot forget and the event tree is right by
  construction. A branch killed at the timeout is closed by the fan-out. One
  subscription to the agent sees every level of it.
  """

  alias Wardrik.Run
  alias Wardrik.Subagent
  alias Wardrik.Tool.Result
  alias WardrikWorkflow.Step

  @max_concurrency 5
  @timeout :timer.minutes(5)

  @typedoc "What one branch of a fan-out reported, alongside the input it was given."
  @type outcome() :: {term(), Step.result()}

  @doc """
  Builds the tool an agent calls to reach `step`.

  Takes the options of `Wardrik.Tool.new!/1` and supplies what runs it, so a
  workflow declares what the model sees and nothing else:

      @impl Wardrik.Tool
      def tool do
        WardrikWorkflow.as_tool(__MODULE__,
          name: "deep_research",
          description: "...",
          schema: [topic: [type: :string, required: true, doc: "..."]]
        )
      end

  It is an ordinary function, so a workflow whose name and schema are only
  known at runtime is built exactly the same way.

  Raises on a bad schema, which happens at `Wardrik.LLM.Config.new/1` and so is
  heard at construction rather than mid-turn.
  """
  @spec as_tool(Step.t(), keyword()) :: Wardrik.Tool.t()
  def as_tool(step, opts) when is_list(opts) do
    Wardrik.Tool.new!(Keyword.put(opts, :run, {__MODULE__, :handle, [step]}))
  end

  @doc """
  Runs `step` for a call to the tool `as_tool/2` built, with the call's
  `input` and `context`.

  The step runs under the context's run, so everything it spawns is
  attributed to the agent that asked for it. It answers with a
  `Wardrik.Tool.Result`, so a workflow that fails reports the failure to the
  model instead of failing the turn.
  """
  @spec handle(Step.t(), map() | keyword(), Wardrik.Tool.Context.t()) :: Wardrik.Tool.Result.t()
  def handle(step, input, %Wardrik.Tool.Context{run: %Run{} = run}),
    do: step |> Step.invoke(Map.new(input), run) |> to_result()

  @doc """
  Runs `step` over every input at once and reports what each one did.

  Outcomes come back in input order, each paired with its input. The branches
  run under a task supervisor of the fan-out's own, linked to the caller, so
  they go with it. Options:

    * `:max_concurrency` - how many branches at once, `#{@max_concurrency}` by default
    * `:timeout` - how long one branch may take, five minutes by default
    * `:name` - a function from an input to its span name

  Without `:name`, an input that is a string or an atom names its own span and
  anything else falls back to its position.
  """
  @spec fan_out(Run.t(), Enumerable.t(), Step.t(), keyword()) :: [outcome()]
  def fan_out(%Run{} = run, inputs, step, opts \\ []) do
    name = Keyword.get(opts, :name)
    {:ok, supervisor} = Task.Supervisor.start_link()

    outcomes =
      supervisor
      |> Task.Supervisor.async_stream_nolink(
        branches(run, inputs, name),
        fn {input, branch} ->
          Subagent.watching(fn ->
            {input, Run.closing(branch, &Step.invoke(step, input, &1))}
          end)
        end,
        ordered: true,
        max_concurrency: Keyword.get(opts, :max_concurrency, @max_concurrency),
        timeout: Keyword.get(opts, :timeout, @timeout),
        on_timeout: :kill_task,
        zip_input_on_exit: true
      )
      |> Enum.map(fn
        {:ok, {outcome, read}} -> read(outcome, read)
        {:exit, {{input, branch}, reason}} -> reap(input, branch, reason)
      end)

    :ok = Supervisor.stop(supervisor)
    outcomes
  end

  # What a branch's delegates read marks the process that fanned out, as a
  # delegate run here would; see `Wardrik.Subagent`.
  defp read(outcome, labels) do
    :ok = Subagent.read(labels)
    outcome
  end

  defp branches(run, inputs, name) do
    inputs
    |> Enum.with_index()
    |> Enum.map(fn {input, index} ->
      {input, Run.open(run, branch_name(name, input, index))}
    end)
  end

  defp reap(input, branch, reason) do
    Run.close(branch, {:error, reason})
    {input, {:error, reason}}
  end

  @doc """
  Runs each step in turn, feeding it the one before it, and stops at the first
  error.

  Each step runs under its own child span, named after its module.
  """
  @spec sequence(Run.t(), term(), [Step.t()]) :: Step.result()
  def sequence(%Run{} = run, input, steps) when is_list(steps) do
    steps
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, input}, fn {step, index}, {:ok, input} ->
      case Run.span(run, Step.name(step, index), &Step.invoke(step, input, &1)) do
        {:ok, output} -> {:cont, {:ok, output}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Splits fan-out outcomes into what landed and what did not.

  Both lists keep input order and pair each value with the input that produced
  it, so a gap can still say which branch it was.
  """
  @spec split([outcome()]) :: {[{term(), term()}], [{term(), term()}]}
  def split(outcomes) when is_list(outcomes) do
    {done, failed} = Enum.split_with(outcomes, &match?({_input, {:ok, _value}}, &1))

    {Enum.map(done, fn {input, {:ok, value}} -> {input, value} end),
     Enum.map(failed, fn {input, {:error, reason}} -> {input, reason} end)}
  end

  defp branch_name(nil, input, _index) when is_binary(input), do: input
  defp branch_name(nil, input, _index) when is_atom(input), do: to_string(input)
  defp branch_name(nil, _input, index), do: "branch_#{index}"
  defp branch_name(name, input, _index), do: name.(input)

  defp to_result({:ok, value}), do: Result.ok(value)
  defp to_result({:error, reason}), do: Result.error(reason)
end
