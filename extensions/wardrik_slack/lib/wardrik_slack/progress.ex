defmodule WardrikSlack.Progress do
  @moduledoc """
  Shows a run's steps in its thread, in one message, and ends that message when the run does.

    * For a run someone asked for, the message is a Slack stream: each step is a task, and the
      reply is written into the same message when the run ends.
    * A stream lasts at most 10 minutes. A run with no asker, or one that outlasts its stream,
      shows its steps in a message that is edited instead.

  The progress ID is `"stream:TS"` or `"message:TS"`, the message's timestamp.
  """

  alias Wardrik.Chat.Outbound
  alias Wardrik.Chat.Step
  alias Wardrik.Chat.Workspace
  alias WardrikSlack.API
  alias WardrikSlack.Blocks

  @ended ~w(message_not_in_streaming_state message_not_found)
  @quiet 10
  @max_markdown 12_000

  @doc """
  Shows the steps of `outbound`, a `{:progress, steps}`. Returns the progress ID of a message it
  started.
  """
  @spec show(Workspace.t(), Outbound.t()) :: :ok | {:ok, String.t()} | {:error, term()}
  def show(workspace, %Outbound{body: {:progress, steps}, progress: progress} = outbound),
    do: show(workspace, outbound, progress, steps)

  defp show(workspace, %Outbound{asker: asker} = outbound, nil, steps) when is_binary(asker) do
    stream = %{
      channel: outbound.room,
      thread_ts: outbound.thread,
      recipient_user_id: asker,
      recipient_team_id: workspace.installation.workspace,
      task_display_mode: "timeline",
      chunks: tasks(steps)
    }

    case API.post_in(workspace, "chat.startStream", stream) do
      {:ok, %{"ts" => ts}} -> {:ok, "stream:" <> ts}
      {:error, _refused} -> post_message(workspace, outbound, steps)
    end
  end

  defp show(workspace, outbound, nil, steps), do: post_message(workspace, outbound, steps)

  defp show(workspace, outbound, "stream:" <> ts, steps) do
    appended = %{channel: outbound.room, ts: ts, chunks: tasks(steps)}

    case API.post_in(workspace, "chat.appendStream", appended) do
      {:ok, _appended} -> :ok
      {:error, ended} when ended in @ended -> post_message(workspace, outbound, steps)
      {:error, reason} -> {:error, reason}
    end
  end

  defp show(workspace, outbound, "message:" <> ts, steps) do
    edited =
      steps
      |> message()
      |> Map.merge(%{channel: outbound.room, ts: ts})

    with {:ok, _edited} <- API.post_in(workspace, "chat.update", edited), do: :ok
  end

  @doc """
  Ends the stream of `outbound`'s run, with `text` written at its end if not `nil`. Returns
  `:unfinished` if the run has no stream, or its stream already ended.
  """
  @spec finish(Workspace.t(), Outbound.t(), String.t() | nil) ::
          :finished | :unfinished | {:error, term()}
  def finish(workspace, %Outbound{progress: "stream:" <> ts} = outbound, text) do
    stopped = %{channel: outbound.room, ts: ts, chunks: markdown(text)}

    case API.post_in(workspace, "chat.stopStream", stopped) do
      {:ok, _stopped} -> :finished
      {:error, ended} when ended in @ended -> :unfinished
      {:error, reason} -> {:error, reason}
    end
  end

  def finish(_workspace, _outbound, _text), do: :unfinished

  defp markdown(nil), do: []

  defp markdown(text),
    do: [%{type: "markdown_text", text: Blocks.clip(text, @max_markdown)}]

  defp post_message(workspace, outbound, steps) do
    posted =
      steps
      |> message()
      |> Map.merge(%{channel: outbound.room, thread_ts: outbound.thread})

    with {:ok, %{"ts" => ts}} <- API.post_in(workspace, "chat.postMessage", posted),
         do: {:ok, "message:" <> ts}
  end

  defp tasks(steps) do
    now = DateTime.utc_now()
    Enum.map(steps, &task(&1, now))
  end

  defp task(step, now) do
    task = %{
      type: "task_update",
      id: step.id,
      title: title(step, now),
      status: task_status(step.status)
    }

    if step.details, do: Map.put(task, :details, step.details), else: task
  end

  defp task_status(:running), do: "in_progress"
  defp task_status(:failed), do: "error"
  defp task_status(_done_or_waiting), do: "complete"

  defp message(steps) do
    now = DateTime.utc_now()
    lines = Enum.map_join(steps, "\n", &line(&1, now))
    %{text: "Working…", blocks: [Blocks.markdown(lines)]}
  end

  defp line(step, now) do
    said = "#{icon(step.status)} #{title(step, now)}"
    if step.details, do: said <> "\n  _" <> step.details <> "_", else: said
  end

  defp icon(:running), do: ":hourglass_flowing_sand:"
  defp icon(:waiting), do: ":raised_hand:"
  defp icon(:done), do: ":white_check_mark:"
  defp icon(:failed), do: ":x:"

  defp title(%Step{status: :running} = step, now) do
    if DateTime.diff(now, step.since) >= @quiet,
      do: "#{step.title} · #{Step.duration(step, now)}",
      else: step.title
  end

  defp title(step, _now), do: step.title
end
