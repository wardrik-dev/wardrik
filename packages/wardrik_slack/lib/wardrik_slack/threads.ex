defmodule WardrikSlack.Threads do
  @moduledoc """
  A message posted in a Slack channel, handed to `WardrikChannel.received/2`
  as a message in a room's thread, and what the bot says of it there.

  Each thread under a message is a conversation of its own with the Slack
  channel's agent; see `WardrikChannel`. A message the agent is asked gets
  :eyes:, which turns to :white_check_mark: once the agent has answered it,
  and is taken away where its run is stopped; one it could not be asked
  gets a reply in its thread saying why.

  Passed over: an edit, a deletion or any other change Slack reports as a
  message, a bot's message, the app's own, a direct message, and a message
  from someone in another workspace, in a channel shared with it.

  Its sender is named as a principal of the workspace, with the name Slack
  shows for them, looked up once for each person while the node runs.
  """

  alias WardrikChannel.Inbound

  # Slack reports a reply also posted to the channel, and a file posted with
  # words, as messages of these kinds; anything else with a kind is a change.
  @posted [nil, "thread_broadcast", "file_share"]

  @doc """
  Acts on a `message` event: asks the agent of its thread, or passes it
  over. `opts` are as `WardrikSlack.Dispatch` hands them on.
  """
  @spec event(map(), keyword()) :: {:asked, Wardrik.AgentID.t()} | :ignored | {:error, term()}
  def event(%{"type" => "message", "user" => user, "channel" => room, "ts" => ts} = event, opts)
      when is_binary(user) do
    if posted?(event, opts), do: ask(event, user, room, ts, opts), else: :ignored
  end

  def event(_event, _opts), do: :ignored

  defp posted?(event, opts) do
    event["subtype"] in @posted and is_nil(event["bot_id"]) and event["user"] != opts[:bot] and
      event["channel_type"] in ["channel", "group"] and
      (event["user_team"] || event["team"] || opts[:team]) == opts[:team]
  end

  defp ask(event, user, room, ts, opts) do
    workspace = Keyword.fetch!(opts, :workspace)
    mention = "<@#{opts[:bot]}>"
    text = Map.get(event, "text", "")

    inbound = %Inbound{
      room: room,
      thread: thread(event["thread_ts"], ts),
      id: ts,
      sender: sender(user, opts),
      text: text |> String.replace(mention, "") |> String.trim(),
      mentioned?: String.contains?(text, mention)
    }

    case WardrikChannel.received(workspace, inbound) do
      {:asked, agent} ->
        react("reactions.add", room, ts, "eyes", opts)
        {:asked, agent}

      :ignored ->
        :ignored

      {:error, message} ->
        say(room, inbound.thread || ts, ":warning: " <> message, opts)
        {:error, message}
    end
  end

  # A message that starts a thread carries its own ts as the thread's once
  # replied to.
  defp thread(nil, _ts), do: nil
  defp thread(ts, ts), do: nil
  defp thread(thread, _ts), do: thread

  @doc """
  Marks the messages an answer answers, which had :eyes:, with
  :white_check_mark:. A reaction Slack refuses, such as one already there,
  is passed over: the answer has been posted either way.
  """
  @spec answered(String.t(), [String.t()], keyword()) :: :ok
  def answered(room, ids, opts) do
    Enum.each(ids, fn ts ->
      react("reactions.remove", room, ts, "eyes", opts)
      react("reactions.add", room, ts, "white_check_mark", opts)
    end)
  end

  @doc """
  Takes :eyes: from the messages a run stopped before it answered. A
  reaction Slack refuses is passed over, as `answered/3` passes it.
  """
  @spec stopped(String.t(), [String.t()], keyword()) :: :ok
  def stopped(room, ids, opts),
    do: Enum.each(ids, &react("reactions.remove", room, &1, "eyes", opts))

  defp react(method, room, ts, name, opts) do
    _reacted = slack(method, %{channel: room, timestamp: ts, name: name}, opts)
    :ok
  end

  defp say(room, thread, text, opts) do
    _said = slack("chat.postMessage", %{channel: room, thread_ts: thread, text: text}, opts)
    :ok
  end

  defp sender(user, opts) do
    %{installation: installation} = Keyword.fetch!(opts, :workspace)
    key = {__MODULE__, installation.channel, installation.workspace, user}

    name =
      case :persistent_term.get(key, :unknown) do
        :unknown ->
          name = named(user, opts)
          :persistent_term.put(key, name)
          name

        name ->
          name
      end

    installation |> WardrikChannel.Member.new(user) |> WardrikChannel.principal(name: name)
  end

  # The name Slack shows for someone: the one they chose, their full name,
  # or their handle; none where Slack does not say.
  defp named(user, opts) do
    case slack("users.info", %{user: user}, opts) do
      {:ok, %{"user" => found}} ->
        profile = Map.get(found, "profile", %{})

        Enum.find(
          [profile["display_name"], profile["real_name"], found["name"]],
          &(is_binary(&1) and &1 != "")
        )

      _unknown ->
        nil
    end
  end

  defp slack(method, body, opts),
    do:
      WardrikSlack.post(
        method,
        Keyword.fetch!(opts, :token),
        body,
        Keyword.get(opts, :req_options, [])
      )
end
