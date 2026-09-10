defmodule Tars.Subagent do
  @moduledoc """
  Runs one bounded task on another agent and returns its answer.

  A delegation is a single turn, so it needs no process and no conversation of
  its own: it is a function call that happens to take a while. By default it
  runs as the caller does, with the same model and the same tools, and its
  events publish to the caller's agent.

      Tars.Subagent.run(scope, "Summarise what changed this week")

  ## Changing what the delegate can do

  | Option | Effect |
  | --- | --- |
  | `:name` | run under a child span with this name |
  | `:system` | replace the persona |
  | `:except_tools` | drop these tools, by name, from the ones inherited |
  | `:tools` | replace the tool set entirely, given as `t:Tars.Tool.spec/0` values |
  | `:model` | replace the model |
  | `:config` | replace the whole config, ignoring the four above |

      Tars.Subagent.run(scope, prompt, system: "You are a researcher.", except_tools: ["x"])
      Tars.Subagent.run(scope, prompt, name: "synthesis", tools: [])

  `:tools` and `:except_tools` compose: the set is replaced, then narrowed.

  Without `:name` the turn runs in the scope it was given, so work already
  fanned out by `Tars.Workflow.fan_out/4` lands on its branch's span rather
  than a redundant one below it.

  Returns the delegate's final assistant text. For work that should outlive the
  call and hold a conversation, start a `Tars.Agent` instead.
  """

  alias ReqLLM.Context
  alias Tars.LLM
  alias Tars.Scope
  alias Tars.Tool

  @doc "Runs `prompt` as one turn under `scope`."
  @spec run(Scope.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run(%Scope{} = scope, prompt, opts \\ []) when is_binary(prompt) do
    delegate = %{named(scope, opts[:name]) | config: config(scope.config, opts)}

    with {:ok, messages} <- LLM.Turn.run(delegate, Context.new([Context.user(prompt)])) do
      {:ok, final_text(messages)}
    end
  end

  defp named(scope, nil), do: scope
  defp named(scope, name), do: Scope.child(scope, name: name)

  defp config(config, opts) do
    case Keyword.fetch(opts, :config) do
      {:ok, %LLM.Config{} = config} -> config
      :error -> config |> put_tools(opts) |> put_model(opts) |> put_system(opts)
    end
  end

  defp put_tools(config, opts) do
    tools =
      case Keyword.fetch(opts, :tools) do
        {:ok, tools} -> Tool.resolve!(tools)
        :error -> config.tools
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
      %{role: :assistant} = message -> presence(text(message))
      _message -> nil
    end)
  end

  defp text(%{content: parts}) when is_list(parts) do
    parts
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join(& &1.text)
  end

  defp text(%{content: content}) when is_binary(content), do: content
  defp text(_message), do: ""

  defp presence(""), do: nil
  defp presence(text), do: text
end
