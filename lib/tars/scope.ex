defmodule Tars.Scope do
  @moduledoc """
  Everything one run needs that nobody configures.

  `Tars.LLM.Config` is supplied by the caller; a scope is what the system
  builds around it to actually run a turn. Today that is the event source.
  Deadlines, cancellation, and store handles belong here too as they arrive,
  which keeps them out of the configuration a caller writes.

      scope = Tars.Scope.root(config, :assistant, name: "turn")
      Tars.Event.emit(scope.source, {:turn_started, ["hello"]})

  Work the turn spawns takes a child scope, so its events land in the same
  stream under a child span:

      branch = Tars.Scope.child(scope, name: "web_search")

  Work that should run under a different model or tool set takes that config
  where it is used, such as `Tars.Subagent.run/3`, rather than carrying it on
  a scope of its own.

  ## Spans

  `span/3` runs work in a child span and announces both ends, so a subscriber
  can build the tree and close every node:

      Tars.Scope.span(scope, "web_search", fn branch ->
        Search.run(query, branch)
      end)

  It emits `{:span_started, name}`, runs the function, and emits
  `{:span_finished, outcome, duration_ms}` whether the function returns,
  raises, throws or exits.

  `open/2` and `close/2` are the same two ends apart, for a combinator whose
  branches may be killed before they can report anything:

      branches = Enum.map(inputs, &{&1, Tars.Scope.open(scope, name(&1))})
      # in each task:   Tars.Scope.closing(branch, &run(input, &1))
      # in the parent:  Tars.Scope.close(branch, {:error, reason})

  A span starts when the work is admitted, which under a bounded
  `Tars.Workflow.fan_out/4` is before a concurrency slot frees: twenty queued
  branches announce themselves as twenty, and their elapsed time runs from
  there.

  Closing is at-least-once — take the first close for a span and ignore any
  later one.
  """

  alias Tars.Event
  alias Tars.Event.Bus
  alias Tars.Event.Source
  alias Tars.LLM.Config
  alias Tars.Trace

  @enforce_keys [:config, :source]
  defstruct [:config, :source]

  @typedoc "The config a run was given, and where its events go."
  @type t() :: %__MODULE__{config: Config.t(), source: Source.t()}

  @typedoc "How a span ended."
  @type outcome() :: :ok | {:error, term()}

  @doc """
  A scope at the root of a new trace.

  Options are passed to `Tars.Event.Source.root/2`.
  """
  @spec root(Config.t(), Bus.agent_id(), keyword()) :: t()
  def root(%Config{} = config, agent_id, opts \\ []) do
    %__MODULE__{config: config, source: Source.root(agent_id, opts)}
  end

  @doc """
  A scope for work that `scope` spawned: same config and topic, a child span.

  Mints the span without announcing it; `span/3` is what announces one.

  Options are passed to `Tars.Event.Source.child/2`.
  """
  @spec child(t(), keyword()) :: t()
  def child(%__MODULE__{} = scope, opts \\ []) do
    %{scope | source: Source.child(scope.source, opts)}
  end

  @doc """
  Runs `fun` in a child span named `name`, announcing both ends.

  `fun` receives the branch scope, and its return value is passed straight
  back. An `{:error, reason}` return closes the span as a failure, anything
  else as a success. A raise, throw or exit closes it as a failure and is
  re-raised unchanged.
  """
  @spec span(t(), String.t(), (t() -> result)) :: result when result: term()
  def span(%__MODULE__{} = scope, name, fun) when is_function(fun, 1) do
    scope |> open(name) |> closing(fun)
  end

  @doc """
  Begins a span, for work whose end is reported elsewhere.

  Pair with `closing/2` in the process doing the work, or `close/2` in one
  reporting on its behalf.
  """
  @spec open(t(), String.t()) :: t()
  def open(%__MODULE__{} = scope, name) do
    branch = child(scope, name: name)
    Event.emit(branch.source, {:span_started, name})
    branch
  end

  @doc "Ends a span opened by `open/2`, reporting how it went and how long it took."
  @spec close(t(), outcome()) :: :ok
  def close(%__MODULE__{source: source}, outcome) do
    Event.emit(source, {:span_finished, outcome, Trace.elapsed_ms(source.trace)})
  end

  @doc """
  Runs `fun` in a span already opened by `open/2` and closes it.

  Outcomes are derived as in `span/3`.
  """
  @spec closing(t(), (t() -> result)) :: result when result: term()
  def closing(%__MODULE__{} = branch, fun) when is_function(fun, 1) do
    result = fun.(branch)
    close(branch, outcome(result))
    result
  catch
    kind, reason ->
      close(branch, {:error, reason})
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp outcome({:error, reason}), do: {:error, reason}
  defp outcome(_result), do: :ok
end
