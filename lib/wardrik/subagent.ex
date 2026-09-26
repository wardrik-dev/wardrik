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

  defp answer(delegate, prompt) do
    case delegate |> Turn.new(Context.new([Context.user(prompt)])) |> Turn.run() do
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

  defp put_tools(config, opts) do
    tools =
      case Keyword.fetch(opts, :tools) do
        {:ok, tools} -> Tool.resolve!(tools)
        :error -> Config.tools(config)
      end

    except = Keyword.get(opts, :except_tools, [])

    %{config | tools: Enum.reject(tools, &(&1.name in except))}
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
