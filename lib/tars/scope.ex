defmodule Tars.Scope do
  @moduledoc """
  Everything one run needs that nobody configures.

  `Tars.LLM.Config` is supplied by the caller and says what an agent is;
  a scope is what the system builds around it to actually run a turn, and says
  what this particular run may do. The split is the point: a config can be
  written down, shared and reused, while a scope belongs to one run and carries
  the things that change per run.

      scope = Tars.Scope.root(config, "acme/jon/assistant", name: "turn", user: user, org: org)
      Tars.Event.emit(scope.source, {:turn_started, ["hello"]})

  Work the turn spawns takes a child scope, so its events land in the same
  stream under a child span and it inherits the same authority:

      branch = Tars.Scope.child(scope, name: "web_search")

  Work that should run under a different model or tool set takes that config
  where it is used, such as `Tars.Subagent.run/3`, rather than carrying it on
  a scope of its own.

  ## What a scope carries

  | Field | What it decides |
  | --- | --- |
  | `:config` | which model, and what it can call |
  | `:source` | where events go, and which span they belong to |
  | `:user`, `:org` | who the work is being done for |
  | `:deadline` | when the work must stop |
  | `:policy` | whether a tool call may run |
  | `:dispatch` | what a model call actually is, and who pays for it |
  | `:credentials` | where a secret a tool names comes from |

  The last five are the seams a host reaches through. Each defaults to
  something inert, so a deployment that needs none of them configures none of
  them and no branch in the runtime has to handle their absence.

  ## Deadlines

  A deadline is an instant, not a duration, so it survives being passed down
  through however many layers of delegation without anyone recomputing it.
  Give one as a duration and it is resolved once:

      scope = Tars.Scope.root(config, "acme/jon/assistant", timeout: :timer.minutes(10))
      Tars.Scope.remaining_ms(scope)

  `with_timeout/2` only ever narrows. Work cannot award itself more time than
  it was given, which is what makes a deadline worth setting at the top.

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
  defstruct [:config, :source, :user, :org, :deadline, :policy, :dispatch, :credentials]

  # An agent carries `:timeout` rather than `:deadline`, and resolves it when
  # each turn's scope is built.
  @seams [:policy, :dispatch, :credentials, :timeout]

  @typedoc "The config a run was given, where its events go, and what it may do."
  @type t() :: %__MODULE__{
          config: Config.t(),
          source: Source.t(),
          user: term(),
          org: term(),
          deadline: integer() | nil,
          policy: Tars.Policy.t() | nil,
          dispatch: module() | nil,
          credentials: module() | nil
        }

  @typedoc "How a span ended."
  @type outcome() :: :ok | {:error, term()}

  @doc """
  The `root/3` options a host supplies that an agent keeps for every turn it
  runs. Who the work is for is named by the agent's key; everything else
  `root/3` takes belongs to one run.
  """
  @spec seams() :: [atom()]
  def seams, do: @seams

  @doc """
  A scope at the root of a new trace.

  Options:

    * `:name` - what to call the span, passed to `Tars.Event.Source.root/2`
    * `:user` - who the work is for, as the host's own value
    * `:org` - which tenant it belongs to, as the host's own value
    * `:timeout` - how long the whole run may take, resolved to a deadline
    * `:deadline` - the same thing as a monotonic instant, for a caller that
      already holds one
    * `:policy` - a `Tars.Policy`, a module or `{module, value}`, or `nil` to
      allow everything
    * `:dispatch` - a `Tars.LLM.Dispatch` module, or `nil` to call the provider
      as configured
    * `:credentials` - a `Tars.Credential` module, or `nil` to resolve none
  """
  @spec root(Config.t(), Bus.agent_id(), keyword()) :: t()
  def root(%Config{} = config, agent_id, opts \\ []) do
    %__MODULE__{
      config: config,
      source: Source.root(agent_id, opts),
      user: Keyword.get(opts, :user),
      org: Keyword.get(opts, :org),
      policy: Keyword.get(opts, :policy),
      dispatch: Keyword.get(opts, :dispatch),
      credentials: Keyword.get(opts, :credentials),
      deadline: Keyword.get(opts, :deadline)
    }
    |> with_timeout(Keyword.get(opts, :timeout, :infinity))
  end

  @doc """
  A scope for work that `scope` spawned: same authority and topic, a child span.

  Mints the span without announcing it; `span/3` is what announces one.

  Options are passed to `Tars.Event.Source.child/2`, and `:timeout` narrows the
  deadline for this branch alone.
  """
  @spec child(t(), keyword()) :: t()
  def child(%__MODULE__{} = scope, opts \\ []) do
    %{scope | source: Source.child(scope.source, opts)}
    |> with_timeout(Keyword.get(opts, :timeout, :infinity))
  end

  @doc """
  Puts the user this scope acts for.

  Takes the host's own value, so a caller hands over the struct it already has
  rather than translating it into something this library invented.

      scope |> Tars.Scope.put_user(current_user) |> Tars.Scope.put_org(org)
  """
  @spec put_user(t(), term()) :: t()
  def put_user(%__MODULE__{} = scope, user), do: %{scope | user: user}

  @doc "Puts the organisation this scope acts for, the same way as `put_user/2`."
  @spec put_org(t(), term()) :: t()
  def put_org(%__MODULE__{} = scope, org), do: %{scope | org: org}

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
