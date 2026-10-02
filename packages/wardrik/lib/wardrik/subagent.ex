defmodule Wardrik.Subagent do
  @moduledoc """
  Runs one bounded task on another agent and returns its answer.

  A delegation is a single turn, so it needs no process and no conversation of
  its own: it is a function call that happens to take a while. By default it
  runs as the caller does, with the same model and the same tools, and its
  events publish to the caller's agent.

      Wardrik.Subagent.run(scope, "Summarise what changed this week")

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

      Wardrik.Subagent.run(scope, prompt, system: "You are a researcher.", except_tools: ["x"])
      Wardrik.Subagent.run(scope, prompt, name: "synthesis", tools: [])

  `:tools` and `:except_tools` compose: the set is replaced, then narrowed.

  Each call gets its own span, inheriting the scope's name unless `:name` is
  supplied.
  This keeps repeated and concurrent delegations on the same scope distinct.

  Returns the delegate's final assistant text. For work that should outlive the
  call and hold a conversation, start a `Wardrik.Agent` instead.

  ## Content from outside

  A delegate begins tainted where `scope` is (see `Wardrik.LLM.Turn`), and one
  whose turn read content from outside marks the process that ran it, since
  its answer may carry what it read. The tool call whose work ran it is
  tainted by the mark, as one that read the content itself is (see
  `Wardrik.Call.taint/1`), and `Wardrik.Workflow.fan_out/4` carries a branch's
  mark back to the process that fanned out. `watching/1` says whether the
  delegates a function ran left one.

  ## Events

  A delegation announces itself on its own span:
  `{:delegation_started, prompt}` before the turn and
  `{:delegation_finished, outcome, ms}` after it, where `outcome` is what the
  call returns. Both are `:lifecycle` events, so `Wardrik.Delegation` can follow
  a turn's delegations without its token stream.
  """

  alias ReqLLM.Context
  alias Wardrik.Event
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.Message
  alias Wardrik.LLM.Turn
  alias Wardrik.Scope
  alias Wardrik.Tool
  alias Wardrik.Trace

  @read_outside :wardrik_read_outside

  @doc "Runs `prompt` as one turn under `scope`."
  @spec run(Scope.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run(%Scope{} = scope, prompt, opts \\ []) when is_binary(prompt) do
    config = config(scope.config, opts)

    name = Keyword.get(opts, :name) || scope.source.trace.name || "delegate"
    Scope.span(scope, name, &delegate(%{&1 | config: config}, prompt))
  end

  defp delegate(delegate, prompt) do
    started_at = System.monotonic_time()
    Event.emit(delegate.source, {:delegation_started, prompt})
    outcome = answer(delegate, prompt)
    Event.emit(delegate.source, {:delegation_finished, outcome, Trace.elapsed_ms(started_at)})
    outcome
  end

  @doc """
  Runs `fun`, and answers what it returned with whether a delegate it ran read
  content from outside. The mark this process held before stays, joined with
  what `fun` left.
  """
  @spec watching((-> result)) :: {result, boolean()} when result: term()
  def watching(fun) when is_function(fun, 0) do
    before = Process.delete(@read_outside) || false
    result = fun.()
    read_outside? = Process.get(@read_outside, false)
    if before or read_outside?, do: Process.put(@read_outside, true)
    {result, read_outside?}
  end

  @doc false
  @spec read_outside() :: :ok
  def read_outside do
    Process.put(@read_outside, true)
    :ok
  end

  defp answer(delegate, prompt) do
    turn = delegate |> Turn.new(Context.new([Context.user(prompt)])) |> Turn.run()
    if turn.tainted, do: read_outside()

    case turn do
      %Turn{state: :done, messages: messages} -> {:ok, final_text(messages)}
      # A bounded delegation has no agent process to retain and resume a park.
      # Report the blocked work without executing the unapproved tool.
      %Turn{state: :waiting} -> {:error, :approval_required}
      %Turn{state: :failed, error: reason} -> {:error, reason}
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
  # one is gated or answers with content from outside, holds in the delegate.
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

  # The last assistant message that actually said something. A turn that ended
  # in tool calls alone leaves nothing to report, which is an empty answer
  # rather than an error.
  defp final_text(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{role: :assistant} = message -> presence(Message.text(message))
      _message -> nil
    end)
  end

  defp presence(""), do: nil
  defp presence(text), do: text
end
