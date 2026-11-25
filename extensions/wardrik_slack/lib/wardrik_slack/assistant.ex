defmodule WardrikSlack.Assistant do
  @moduledoc """
  Handles Slack's agent pane, which members open from the app's entry in Slack's top bar.

  Each conversation in the pane is a thread of the app's direct messages, answered as any direct
  message is. When one starts, it suggests the first four prompts of the channel's `:prompts`.
  See `Wardrik.Chat.Prompts`. Needs the `assistant:write` scope.
  """

  alias Wardrik.Chat.Member
  alias Wardrik.Chat.Workspace
  alias WardrikSlack.API

  require Logger

  @prompts 4

  @doc "Handles an `assistant_thread_started` event. Returns `:ignored` for any other."
  @spec event(Workspace.t(), map(), String.t() | nil) :: :ok | :ignored
  def event(
        workspace,
        %{"type" => "assistant_thread_started", "assistant_thread" => thread},
        _bot
      ) do
    prompts = Wardrik.Chat.suggest_prompts(workspace, %Member{id: thread["user_id"]})
    suggest(workspace, thread, prompts)
  end

  def event(_workspace, _event, _bot), do: :ignored

  defp suggest(_workspace, _thread, []), do: :ok

  defp suggest(workspace, %{"channel_id" => channel, "thread_ts" => thread}, prompts) do
    suggested = %{
      channel_id: channel,
      thread_ts: thread,
      prompts:
        prompts
        |> Enum.take(@prompts)
        |> Enum.map(&%{title: &1, message: &1})
    }

    with {:error, reason} <-
           API.post_in(workspace, "assistant.threads.setSuggestedPrompts", suggested) do
      Logger.warning("Slack didn't take the suggested prompts: #{inspect(reason)}")
    end

    :ok
  end
end
