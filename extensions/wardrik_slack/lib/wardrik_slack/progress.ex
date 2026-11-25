defmodule WardrikSlack.Progress do
  @moduledoc """
  Shows a run's steps in its thread, in one message, and ends that message when the run does.

    * For a run someone asked for, the message is a Slack stream: each step is a task, with its
      details under it. Slack adds each update's details to what it shows, so only new details
      are sent, up to 8,000 characters for the whole message.
    * A stream lasts at most 10 minutes. A run with no asker, or one that outlasts its stream,
      shows its steps in a message that is edited instead.
    * The reply is posted on its own, after the stream ends.

  The progress ID is `"stream:TS"` or `"message:TS"`, the message's timestamp.
  """

  alias Wardrik.Chat.Outbound
  alias Wardrik.Chat.Step
  alias Wardrik.Chat.Workspace
  alias WardrikSlack.API
  alias WardrikSlack.Blocks

  require Logger

  @ended ~w(message_not_in_streaming_state message_not_found)
  @quiet 10
  @details_budget 8_000
  @details_tail 200

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
  Ends the stream of `outbound`'s run, if it has one. Always returns `:ok`: Slack ends a stream
  on its own after 10 minutes, and what follows is posted either way.
  """
  @spec finish(Workspace.t(), Outbound.t()) :: :ok
  def finish(workspace, %Outbound{progress: "stream:" <> ts} = outbound) do
    with {:error, reason} <-
           API.post_in(workspace, "chat.stopStream", %{channel: outbound.room, ts: ts}) do
      Logger.debug("Slack didn't end the stream #{ts}: #{inspect(reason)}")
    end

    :ok
  end

  def finish(_workspace, _outbound), do: :ok

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
    shown = Enum.sum_by(steps, & &1.shown)
    {tasks, _budget} = Enum.map_reduce(steps, @details_budget - shown, &task(&1, &2, now))
    tasks
  end

  defp task(step, budget, now) do
    task = %{
      type: "task_update",
      id: step.id,
      title: title(step, now),
      status: task_status(step.status)
    }

    add_details(task, Step.unshown(step), budget)
  end

  defp add_details(task, "", budget), do: {task, budget}

  defp add_details(task, details, budget) do
    length = String.length(details)

    if length <= budget,
      do: {Map.put(task, :details, details), budget - length},
      else: {task, budget}
  end

  defp task_status(:running), do: "in_progress"
  defp task_status(:failed), do: "error"
  defp task_status(_done_or_waiting), do: "complete"

  defp message(steps) do
    now = DateTime.utc_now()
    lines = Enum.map_join(steps, "\n", &line(&1, now))
    %{text: "Working…", blocks: [Blocks.markdown(lines)]}
  end

  defp line(%Step{details: ""} = step, now), do: "#{icon(step.status)} #{title(step, now)}"

  defp line(step, now) do
    tail = String.slice(step.details, -@details_tail, @details_tail)
    "#{icon(step.status)} #{title(step, now)}\n> " <> String.replace(tail, "\n", " ")
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
