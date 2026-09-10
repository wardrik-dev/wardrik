defmodule Tars.Workflow do
  @moduledoc """
  Runs steps: many at once, or one after another.

  Tars ships this and `Tars.Workflow.Step`, and no workflows. A workflow is a
  step someone else wrote, and it reaches an agent the same way a tool does, by
  being named in a config:

      Tars.LLM.Config.new(tools: [TarsBrave.WebSearch, TarsResearch.Deep])

  There is no separate list and no registry, because a workflow an agent cannot
  call is just a function the deployment calls itself. `as_tool/2` builds the
  tool that makes one callable.

  ## Fanning out

  `fan_out/4` runs one step over many inputs concurrently and reports one
  outcome per input, whatever happened to it. A branch that returns an error,
  crashes, or runs over time all arrive the same way, so a dead branch is a gap
  the caller decides about rather than the end of the run.

      scope
      |> Tars.Workflow.fan_out(angles, fn angle, branch ->
        Tars.Subagent.run(branch, config, prompt(angle))
      end)
      |> Tars.Workflow.split()

  `max_concurrency: 1` runs the same branches one at a time.

  ## Going in order

  `sequence/3` feeds each step the previous step's result and stops at the
  first error, because a stage whose input never arrived has nothing to do.

      Tars.Workflow.sequence(scope, input, [Fetch, {Summarise, config: config}, Publish])

  For work that depends on more than one earlier result, write it out. The
  call graph is the dependency graph:

      with {:ok, a} <- Step.invoke(Recon, args, scope),
           {:ok, b} <- Step.invoke(Baseline, args, scope) do
        Step.invoke(Compare, %{recon: a, baseline: b}, scope)
      end

  ## Spans

  Both combinators create the child span their work runs under, so a step
  author cannot forget and the event tree is right by construction. One
  subscription to the agent sees every level of it.
  """

  alias Tars.Scope
  alias Tars.Tool.Result
  alias Tars.Workflow.Step

  @max_concurrency 5
  @timeout :timer.minutes(5)

  @typedoc "What one branch of a fan-out reported, alongside the input it was given."
  @type outcome() :: {term(), Step.result()}

  @doc """
  Builds the tool an agent calls to reach `step`.

  Takes the same options as `ReqLLM.Tool.new!/1` and supplies the callback, so
  a workflow declares what the model sees and nothing else:

      @impl Tars.Tool
      def tool do
        Tars.Workflow.as_tool(__MODULE__,
          name: "deep_research",
          description: "...",
          parameter_schema: [topic: [type: :string, required: true, doc: "..."]]
        )
      end

  It is an ordinary function, so a workflow whose name and schema are only
  known at runtime is built exactly the same way.

  Raises on a bad schema, which happens at `Tars.LLM.Config.new/1` and so is
  heard at construction rather than mid-turn.
  """
  @spec as_tool(Step.t(), keyword()) :: ReqLLM.Tool.t()
  def as_tool(step, opts) when is_list(opts) do
    ReqLLM.Tool.new!(Keyword.put(opts, :callback, {__MODULE__, :call, [step]}))
  end

  @doc """
  Runs `step` as the tool call currently in progress.

  This is what `as_tool/2` points a callback at. It finds the scope of the call in
  progress, so everything the step spawns is attributed to the agent that asked
  for it. The answer comes back as a `Tars.Tool.Result`, so a workflow that
  fails reports the failure to the model instead of failing the turn.
  """
  @spec call(Step.t(), map() | keyword()) :: Result.t() | {:error, String.t()}
  def call(step, args) do
    case Scope.Context.current() do
      nil ->
        {:error, "#{inspect(step)} was called outside a tool call"}

      %Scope{} = scope ->
        step |> Step.invoke(Map.new(args), scope) |> to_result()
    end
  end

  @doc """
  Runs `step` over every input at once and reports what each one did.

  Outcomes come back in input order, each paired with its input. Options:

    * `:max_concurrency` - how many branches at once, `#{@max_concurrency}` by default
    * `:timeout` - how long one branch may take, five minutes by default
    * `:name` - a function from an input to its span name

  Without `:name`, an input that is a string or an atom names its own span and
  anything else falls back to its position.
  """
  @spec fan_out(Scope.t(), Enumerable.t(), Step.t(), keyword()) :: [outcome()]
  def fan_out(%Scope{} = scope, inputs, step, opts \\ []) do
    name = Keyword.get(opts, :name)

    Tars.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      Enum.with_index(inputs),
      fn {input, index} ->
        branch = Scope.child(scope, name: branch_name(name, input, index))
        {input, Step.invoke(step, input, branch)}
      end,
      ordered: true,
      max_concurrency: Keyword.get(opts, :max_concurrency, @max_concurrency),
      timeout: Keyword.get(opts, :timeout, @timeout),
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Enum.map(fn
      {:ok, outcome} -> outcome
      {:exit, {{input, _index}, reason}} -> {input, {:error, reason}}
    end)
  end

  @doc """
  Runs each step in turn, feeding it the one before it, and stops at the first
  error.

  Each step runs under its own child span, named after its module.
  """
  @spec sequence(Scope.t(), term(), [Step.t()]) :: Step.result()
  def sequence(%Scope{} = scope, input, steps) when is_list(steps) do
    steps
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, input}, fn {step, index}, {:ok, input} ->
      stage = Scope.child(scope, name: Step.name(step, index))

      case Step.invoke(step, input, stage) do
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
