defmodule WardrikSlack.Assistant do
  @moduledoc """
  Handles Slack's agent experience: the app's Messages tab, opened from Slack's top bar.

  Each conversation there is a thread of the app's direct messages, answered as any direct
  message is.

    * When a member opens the Messages tab, it suggests the first four prompts of the channel's
      `:prompts`. See `Wardrik.Chat.Prompts`. An app on Slack's older assistant experience gets
      them as each thread starts instead.
    * Stop, shown while a run streams its steps, stops that run with `Wardrik.Chat.stop/3`. If
      the member may not, they're told why, and the run carries on.

  Needs the `assistant:write` scope, and the `app_home_opened` and `agent_session_stopped` events.
  """

  alias Wardrik.Chat.Member
  alias Wardrik.Chat.Workspace
  alias WardrikSlack.API
  alias WardrikSlack.Messages

  require Logger

  @prompts 4

  @doc """
  Handles `app_home_opened` on the Messages tab, `agent_session_stopped`, and the older
  `assistant_thread_started`. Returns `:ignored` for any other event.
  """
  @spec event(Workspace.t(), map(), String.t() | nil) :: :ok | :ignored
  def event(
        workspace,
        %{"type" => "app_home_opened", "tab" => "messages", "channel" => channel, "user" => user},
        _bot
      ),
      do: suggest(workspace, user, %{channel_id: channel})

  def event(
        workspace,
        %{"type" => "assistant_thread_started", "assistant_thread" => thread},
        _bot
      ),
      do:
        suggest(workspace, thread["user_id"], %{
          channel_id: thread["channel_id"],
          thread_ts: thread["thread_ts"]
        })

  def event(
        workspace,
        %{"type" => "agent_session_stopped", "channel" => room, "thread_ts" => thread} = event,
        _bot
      ) do
    member = Messages.sender(workspace, event["user"])

    case Wardrik.Chat.stop(workspace, member, room: room, thread: thread) do
      :ok -> :ok
      :not_running -> set_active(workspace, room, thread)
      {:error, why} -> refuse_stop(workspace, event, why)
    end
  end

  def event(_workspace, _event, _bot), do: :ignored

  defp suggest(workspace, user, where) do
    workspace
    |> Wardrik.Chat.suggest_prompts(%Member{id: user})
    |> Enum.take(@prompts)
    |> post_prompts(workspace, where)
  end

  defp post_prompts([], _workspace, _where), do: :ok

  defp post_prompts(prompts, workspace, where) do
    suggested = Map.put(where, :prompts, Enum.map(prompts, &%{title: &1, message: &1}))

    case API.post_in(workspace, "assistant.threads.setSuggestedPrompts", suggested) do
      {:ok, _set} ->
        :ok

      {:error, "static_prompts_configured"} ->
        :ok

      {:error, reason} ->
        Logger.warning("Slack didn't take the suggested prompts: #{inspect(reason)}")
    end

    :ok
  end

  # A run that may not be stopped carries on, so its session stays processing.
  defp refuse_stop(workspace, %{"channel" => room, "thread_ts" => thread, "user" => user}, why) do
    _told =
      API.post_in(workspace, "chat.postEphemeral", %{
        channel: room,
        thread_ts: thread,
        user: user,
        text: why
      })

    :ok
  end

  # Slack shows the session as working until the app says otherwise.
  defp set_active(workspace, room, thread) do
    _set =
      API.post_in(workspace, "agents.sessions.setStatus", %{
        channel_id: room,
        thread_ts: thread,
        status: "active"
      })

    :ok
  end
end
