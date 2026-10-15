defmodule Wardrik.Scope do
  @moduledoc """
  Everything one run needs that nobody configures.

  `Wardrik.LLM.Config` is supplied by the caller and says what an agent is;
  a scope is what the system builds around it to actually run a turn, and says
  what this particular run may do. The split is the point: a config can be
  written down, shared and reused, while a scope belongs to one run and carries
  the things that change per run.

      scope = Wardrik.Scope.root(config, ~A"acme/@jon/assistant", name: "turn")
      Wardrik.Event.emit(scope.source, %Event.TurnStarted{messages: [Wardrik.Agent.Message.new("hello")]})

  Work the turn spawns takes a child scope, so its events land in the same
  stream under a child span and it inherits the same authority:

      branch = Wardrik.Scope.child(scope, name: "web_search")

  Work that should run under a different model or tool set takes that config
  where it is used, such as `Wardrik.Subagent.run/3`, rather than carrying it on
  a scope of its own.

  ## What a scope carries

  | Field | What it decides |
  | --- | --- |
  | `:config` | which model, and what it can call |
  | `:source` | which agent the work is for, where its events go, and which span they belong to |
  | `:sender` | who asked for the work: the `Wardrik.Principal` who sent the messages a turn answers; see "Who asked" |
  | `:batch` | which batch of tool calls the work belongs to; see `batch/2` |
  | `:labels` | what the run has read, as `Wardrik.Label`s, for its hooks to weigh; see `Wardrik.Call.label/2` |
  | `:deadline` | when the work must stop |
  | `:hooks` | whether a tool call may run, and a model call be made |
  | `:retry` | whether a model call that failed is asked again |
  | `:host` | the `Wardrik.Host` the agent runs on, whose seams an operation a tool calls asks, whose credentials a call resolves, and whose dispatch every model call goes through |

  `:hooks` to `:retry` are the seams a host reaches through for one
  agent. Each defaults to something inert, so a deployment that needs none of
  them configures none of them and no branch in the runtime has to handle
  their absence. `:host` is the deployment's, handed to every agent as it
  starts, and `Wardrik.Host.new/1`, which offers no seam, where a run is
  given none.

  ## Who asked

  An agent's ID says whose the work is; `:sender` says who asked for it.
  A turn answers the messages of one sender at a time, and runs under a
  scope naming them, so a tool can act as the person who asked rather than
  as the agent's owner: with the `Wardrik.Grant` `Wardrik.Grants` answers
  for them, say. `nil` is a turn nobody asked for, as one a trigger starts.
  Work the turn spawns keeps its sender.

      scope = Wardrik.Scope.root(config, ~A"acme/assistant", sender: maria)
      Wardrik.Scope.child(scope).sender == maria

  ## Deadlines

  A deadline is an instant, not a duration, so it survives being passed down
  through however many layers of delegation without anyone recomputing it.
  Give one as a duration and it is resolved once:

      scope = Wardrik.Scope.root(config, ~A"acme/@jon/assistant", timeout: :timer.minutes(10))
      Wardrik.Scope.remaining_ms(scope)

  `with_timeout/2` only ever narrows. Work cannot award itself more time than
  it was given, which is what makes a deadline worth setting at the top.

  ## Spans

  `span/3` runs work in a child span and announces both ends, so a subscriber
  can build the tree and close every node:

      Wardrik.Scope.span(scope, "web_search", fn branch ->
        Search.run(query, branch)
      end)

  It emits `Wardrik.Event.SpanStarted`, runs the function, and emits
  `Wardrik.Event.SpanFinished` whether the function returns,
  raises, throws or exits.

  `open/2` and `close/2` are the same two ends apart, for a combinator whose
  branches may be killed before they can report anything:

      branches = Enum.map(inputs, &{&1, Wardrik.Scope.open(scope, name(&1))})
      # in each task:   Wardrik.Scope.closing(branch, &run(input, &1))
      # in the parent:  Wardrik.Scope.close(branch, {:error, reason})

  A span starts when the work is admitted, which under a bounded fan-out is
  before a concurrency slot frees: twenty queued branches announce themselves
  as twenty, and their elapsed time runs from there.

  Closing is at-least-once — take the first close for a span and ignore any
  later one.
  """

  alias Wardrik.Event
  alias Wardrik.Event.Bus
  alias Wardrik.Event.Source
  alias Wardrik.LLM.Config
  alias Wardrik.Trace

  @enforce_keys [:config, :source, :host]
  defstruct [
    :config,
    :source,
    :host,
    :sender,
    :deadline,
    :retry,
    :journal,
    :batch,
    hooks: [],
    labels: [],
    ledger: %Wardrik.Ledger.None{}
  ]

  # An agent carries `:timeout` rather than `:deadline`, and resolves it when
  # each turn's scope is built.
  @seams [:hooks, :retry, :ledger, :timeout]

  @typedoc "The config a run was given, where its events go, and what it may do."
  @type t() :: %__MODULE__{
          config: Config.t(),
          source: Source.t(),
          host: Wardrik.Host.t(),
          sender: Wardrik.Principal.t() | nil,
          deadline: integer() | nil,
          hooks: [Wardrik.Hook.t()],
          retry: Wardrik.LLM.Retry.t() | nil,
          ledger: Wardrik.Ledger.t(),
          journal: pid() | nil,
          batch: String.t() | nil,
          labels: [Wardrik.Label.t()]
        }

  @typedoc "How a span ended."
  @type outcome() :: :ok | {:error, term()}

  @doc """
  The `root/3` options a host supplies that an agent keeps for every turn it
  runs. Who the work is for is named by the agent's ID; everything else
  `root/3` takes belongs to one run.
  """
  @spec seams() :: [atom()]
  def seams, do: @seams

  @doc """
  A scope at the root of a new trace.

  Options:

    * `:name` - what to call the span, passed to `Wardrik.Event.Source.root/2`
    * `:sender` - the `Wardrik.Principal` who asked for the work, or `nil`
      where nobody did
    * `:host` - the `Wardrik.Host` the work runs on, `Wardrik.Host.new/1`
      where none is given
    * `:timeout` - how long the whole run may take, resolved to a deadline
    * `:deadline` - the same thing as a monotonic instant, for a caller that
      already holds one
    * `:hooks` - the `Wardrik.Hook`s every call is checked against, `[]` to
      allow everything
    * `:retry` - a `Wardrik.LLM.Retry`, or `nil` to ask a failed model call
      again after the waits the config's `:retries` lists
    * `:ledger` - a `Wardrik.Ledger` module, which records each tool call before
      it runs, or `nil` to record none
    * `:journal` - the process a turn under this scope hands each batch of
      tool calls to before running it, so a turn lost part way can be
      replayed from there. `Wardrik.Agent` is one. Not inherited by `child/2`
  """
  @spec root(Config.t(), Bus.agent_id(), keyword()) :: t()
  def root(%Config{} = config, %Wardrik.AgentID{} = agent_id, opts \\ []) do
    %__MODULE__{
      config: config,
      source: Source.root(agent_id, opts),
      host: Keyword.get_lazy(opts, :host, &Wardrik.Host.new/0),
      sender: Keyword.get(opts, :sender),
      hooks: Keyword.get(opts, :hooks) || [],
      retry: Keyword.get(opts, :retry),
      ledger: Keyword.get(opts, :ledger, %Wardrik.Ledger.None{}),
      journal: Keyword.get(opts, :journal),
      deadline: Keyword.get(opts, :deadline)
    }
    |> with_timeout(Keyword.get(opts, :timeout, :infinity))
  end

  @doc """
  A scope for work that `scope` spawned: same authority and topic, a child span.

  Mints the span without announcing it; `span/3` is what announces one.

  Options are passed to `Wardrik.Event.Source.child/2`, and `:timeout` narrows the
  deadline for this branch alone.

  The child has no journal: work a turn spawns, a delegation's own turns
  included, is replayed as the one call of that turn it belongs to.
  """
  @spec child(t(), keyword()) :: t()
  def child(%__MODULE__{} = scope, opts \\ []) do
    %{scope | source: Source.child(scope.source, opts), journal: nil}
    |> with_timeout(Keyword.get(opts, :timeout, :infinity))
  end

  @doc """
  The scope a turn running under `scope` runs its `round`th batch of tool
  calls under, `0` for the first.

  The batch is named by the turn's own span and the round, and every scope
  under it keeps that name, so the calls of each round of a turn, and those of
  each delegation's own turn, are named apart. A turn resumed or replayed
  keeps its span, and names each batch as it did the first time.
  """
  @spec batch(t(), non_neg_integer()) :: t()
  def batch(%__MODULE__{source: source} = scope, round) when is_integer(round) and round >= 0,
    do: %{scope | batch: source.trace.span_id <> "/" <> Integer.to_string(round)}

  @doc """
  The agent the work is for. Its org and user say who the work is done for.

      %Wardrik.AgentID{org: org, user: user} = Wardrik.Scope.agent_id(scope)
  """
  @spec agent_id(t()) :: Bus.agent_id()
  def agent_id(%__MODULE__{source: source}), do: source.agent_id

  @doc """
  Narrows this scope's deadline to at most `ms` from now.

  Never widens one: work handed a deadline cannot give itself more time, so a
  caller can hand a scope to code it did not write and still know when it ends.
  """
  @spec with_timeout(t(), timeout()) :: t()
  def with_timeout(%__MODULE__{} = scope, :infinity), do: scope

  def with_timeout(%__MODULE__{} = scope, ms) when is_integer(ms) and ms >= 0 do
    %{scope | deadline: earliest(scope.deadline, instant(ms))}
  end

  defp earliest(nil, proposed), do: proposed
  defp earliest(current, proposed), do: min(current, proposed)

  defp instant(ms) do
    System.monotonic_time() + System.convert_time_unit(ms, :millisecond, :native)
  end

  @doc """
  How long this scope has left, or `:infinity` when it has no deadline.

  Zero once the deadline has passed, so a caller can pass it straight to
  anything taking a timeout without checking for a negative.
  """
  @spec remaining_ms(t()) :: timeout()
  def remaining_ms(%__MODULE__{deadline: nil}), do: :infinity

  def remaining_ms(%__MODULE__{deadline: deadline}) do
    deadline
    |> Kernel.-(System.monotonic_time())
    |> System.convert_time_unit(:native, :millisecond)
    |> max(0)
  end

  @doc "Whether this scope's deadline has passed."
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{} = scope), do: remaining_ms(scope) == 0

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
    Event.emit(branch.source, %Event.SpanStarted{name: name})
    branch
  end

  @doc "Ends a span opened by `open/2`, reporting how it went and how long it took."
  @spec close(t(), outcome()) :: :ok
  def close(%__MODULE__{source: source}, outcome) do
    Event.emit(source, %Event.SpanFinished{
      outcome: outcome,
      duration_ms: Trace.elapsed_ms(source.trace)
    })
  end

  @doc """
  Runs `fun` in a span already opened by `open/2` and closes it.

  `outcome` reads the span's outcome from what `fun` returned. It defaults to
  the rule `span/3` uses; pass one where a return value says more about how the
  work went than its tag does.
  """
  @spec closing(t(), (t() -> result), (result -> outcome())) :: result when result: term()
  def closing(%__MODULE__{} = branch, fun, outcome \\ &outcome/1) when is_function(fun, 1) do
    result = fun.(branch)
    close(branch, outcome.(result))
    result
  catch
    kind, reason ->
      close(branch, {:error, reason})
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp outcome({:error, reason}), do: {:error, reason}
  defp outcome(_result), do: :ok
end
