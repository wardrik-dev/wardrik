defmodule Tars.Subagent do
  @moduledoc """
  Runs one bounded task on another agent and returns its answer.

  A delegation is a single turn, so it needs no process and no conversation of
  its own: it is a function call that happens to take a while. Its events
  publish to the delegating agent under a child span, so one subscription sees
  the whole tree.

      Tars.Subagent.run(scope, researcher_config, "Research competitor pricing",
        name: "researcher")

  Returns the delegate's final assistant text. For work that should outlive the
  call and hold a conversation, start a `Tars.Agent` instead.
  """

  alias ReqLLM.Context
  alias Tars.LLM
  alias Tars.Scope

  @doc """
  Runs `prompt` on a turn configured by `config`, under a child of `parent`.

  Options are passed to `Tars.Scope.child/3`; `:name` labels the span.
  """
  @spec run(Scope.t(), LLM.Config.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def run(%Scope{} = parent, %LLM.Config{} = config, prompt, opts \\ [])
      when is_binary(prompt) do
    scope = Scope.child(parent, config, opts)

    with {:ok, messages} <- LLM.Turn.run(scope, Context.new([Context.user(prompt)])) do
      {:ok, final_text(messages)}
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
