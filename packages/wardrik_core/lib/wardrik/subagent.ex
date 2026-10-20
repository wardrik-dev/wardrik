defmodule Wardrik.Subagent do
  @moduledoc """
  Runs one bounded task on another agent and returns its answer.

  A delegation is a single turn, so it needs no process and no conversation of
  its own: it is a function call that happens to take a while. By default it
  runs as the caller does, with the same model and the same tools, and its
  events publish to the caller's agent.

      Wardrik.Subagent.run(run, "Summarise what changed this week")

  ## Changing what the delegate can do

  | Option | Effect |
  | --- | --- |
  | `:name` | run under a child span with this name |
  | `:system` | replace the persona |
  | `:except_tools` | drop these tools, by name, from the ones inherited |
  | `:tools` | replace the tool set entirely, given as `t:Wardrik.Tool.spec/0` values |
  | `:model` | replace the model |
  | `:generation` | replace the generation options, such as a reasoning budget |
  | `:config` | replace the whole config, ignoring the five above |

      Wardrik.Subagent.run(run, prompt, system: "You are a researcher.", except_tools: ["x"])
      Wardrik.Subagent.run(run, prompt, name: "synthesis", tools: [])

  `:tools` and `:except_tools` compose: the set is replaced, then narrowed.

  Each call gets its own span, inheriting the run's name unless `:name` is
  supplied.
  This keeps repeated and concurrent delegations on the same run distinct.

  Returns the delegate's final assistant text. For work that should outlive the
  call and hold a conversation, start a `Wardrik.Agent` instead.

  ## What a delegate read

  A delegate begins with the labels `run` carries (see `Wardrik.Label`), and
  marks the process that ran it with the labels its turn ended with, since
  its answer may carry what it read. The tool call whose work ran it is
  labelled with them, as one that read the content itself is (see
  `Wardrik.Call.label/2`), and `read/1` carries the labels of delegates run
  in other processes back to this one. `watching/1` says which labels the
  delegates a function ran left.

  ## Events

  A delegation announces itself on its own span:
  `Wardrik.Bus.DelegationStarted` before the turn and
  `Wardrik.Bus.DelegationFinished` after it, where `outcome` is what the
  call returns. Both are `:lifecycle` events, so a client can follow a turn's
  delegations without its token stream.
  """

  alias Wardrik.Bus

  alias Wardrik.Bus.Event
  alias Wardrik.Conversation
  alias Wardrik.Conversation.User
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.Turn
  alias Wardrik.Run
  alias Wardrik.Tool
  alias Wardrik.Trace

  @read :wardrik_read_labels

  @doc "Runs `prompt` as one turn under `run`."
  @spec run(Run.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run(%Run{} = run, prompt, opts \\ []) when is_binary(prompt) do
    config = config(run.config, opts)

    name = Keyword.get(opts, :name) || run.source.trace.name || "delegate"
    Run.span(run, name, &delegate(%{&1 | config: config}, prompt))
  end

  defp delegate(delegate, prompt) do
    started_at = System.monotonic_time()
    Event.emit(delegate.source, %Bus.DelegationStarted{prompt: prompt})
    outcome = answer(delegate, prompt)

    Event.emit(delegate.source, %Bus.DelegationFinished{
      outcome: outcome,
      duration_ms: Trace.elapsed_ms(started_at)
    })

    outcome
  end

  @doc """
  Runs `fun`, and answers what it returned with the labels of what the
  delegates it ran read. The labels this process held before stay, joined
  with what `fun` left.
  """
  @spec watching((-> result)) :: {result, [Wardrik.Label.t()]} when result: term()
  def watching(fun) when is_function(fun, 0) do
    before = Process.delete(@read) || []
    result = fun.()
    read = Process.get(@read, [])
    Process.put(@read, Wardrik.Label.union(before, read))
    {result, read}
  end

  @doc """
  Marks this process with `labels` that delegates read in another, as one run
  here would have: for a function that runs work in tasks, such as a fan-out,
  with what `watching/1` answered in each.
  """
  @spec read([Wardrik.Label.t()]) :: :ok
  def read(labels) when is_list(labels) do
    Process.put(@read, Wardrik.Label.union(Process.get(@read, []), labels))
    :ok
  end

  defp answer(delegate, prompt) do
    turn = delegate |> Turn.new(Conversation.new([User.new(prompt)])) |> Turn.run()
    :ok = read(turn.labels)

    case Wardrik.Turn.status(turn) do
      {:done, messages, _labels} -> {:ok, Conversation.answer(messages)}
      # A bounded delegation has no agent process to retain and resume a park.
      # Report the blocked work without executing the unapproved tool.
      :waiting -> {:error, :approval_required}
      {:failed, reason} -> {:error, reason}
    end
  end

  defp config(config, opts) do
    case Keyword.fetch(opts, :config) do
      {:ok, %Config{} = config} ->
        config

      :error ->
        config |> put_tools(opts) |> put_model(opts) |> put_system(opts) |> put_generation(opts)
    end
  end

  # The specs are kept, so what each declares of its tools, such as whether
  # one is gated or what its answers hold, holds in the delegate.
  defp put_tools(config, opts) do
    config =
      case Keyword.fetch(opts, :tools) do
        {:ok, tools} ->
          Tool.resolve!(tools)
          %{config | tools: tools, except_tools: []}

        :error ->
          config
      end

    %{
      config
      | except_tools: Enum.uniq(config.except_tools ++ Keyword.get(opts, :except_tools, []))
    }
  end

  defp put_system(config, opts) do
    case Keyword.fetch(opts, :system) do
      {:ok, system} -> %{config | system: system}
      :error -> config
    end
  end

  defp put_generation(config, opts) do
    case Keyword.fetch(opts, :generation) do
      {:ok, generation} -> %{config | generation: generation}
      :error -> config
    end
  end

  defp put_model(config, opts) do
    case Keyword.fetch(opts, :model) do
      {:ok, model_spec} -> %{config | model_spec: model_spec}
      :error -> config
    end
  end
end
