defmodule WardrikSlack.Threads do
  @moduledoc """
  A message posted in a Slack channel, handed to `WardrikChannel.received/2`
  as a message in a room's thread, and what the bot says of it there.

  Each thread under a message is a conversation of its own with the Slack
  channel's agent; see `WardrikChannel`. A message the agent is asked gets
  :eyes:, which turns to :white_check_mark: once the agent has answered it;
  one it could not be asked gets a reply in its thread saying why.

  Passed over: an edit, a deletion or any other change Slack reports as a
  message, a bot's message, the app's own, a direct message, and a message
  from someone in another workspace, in a channel shared with it.

  Its sender is named as a `:slack` principal, with the name Slack shows for
  them, looked up once for each person while the connection stays open.
  """

  alias Wardrik.Principal
  alias WardrikChannel.Inbound

  # Slack reports a reply also posted to the channel, and a file posted with
  # words, as messages of these kinds; anything else with a kind is a change.
  @posted [nil, "thread_broadcast", "file_share"]

  @doc """
  Acts on a `message` event: asks the agent of its thread, or passes it
  over.

  `opts` are the channel's: `:context`, `:bot`, the bot's user id, `:team`,
  its workspace's id, `:people`, the table names are kept in, `:token` and
  `:req_options`.
  """
  @spec message(map(), keyword()) :: {:asked, Wardrik.AgentID.t()} | :ignored | {:error, term()}
  def message(%{"type" => "message", "user" => user, "channel" => room, "ts" => ts} = event, opts)
      when is_binary(user) do
    if posted?(event, opts), do: ask(event, user, room, ts, opts), else: :ignored
  end

  def message(_event, _opts), do: :ignored

  defp posted?(event, opts) do
    event["subtype"] in @posted and is_nil(event["bot_id"]) and event["user"] != opts[:bot] and
      event["channel_type"] in ["channel", "group"] and
      (event["user_team"] || event["team"] || opts[:team]) == opts[:team]
  end

  defp ask(event, user, room, ts, opts) do
    context = Keyword.fetch!(opts, :context)
    mention = "<@#{opts[:bot]}>"
    text = Map.get(event, "text", "")

    inbound = %Inbound{
      channel: context.channel,
      room: room,
      thread: thread(event["thread_ts"], ts),
      id: ts,
      sender: sender(user, opts),
      text: text |> String.replace(mention, "") |> String.trim(),
      mentioned?: String.contains?(text, mention)
    }

    case WardrikChannel.received(context, inbound) do
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

  defp react(method, room, ts, name, opts) do
    _reacted = slack(method, %{channel: room, timestamp: ts, name: name}, opts)
    :ok
  end

  defp say(room, thread, text, opts) do
    _said = slack("chat.postMessage", %{channel: room, thread_ts: thread, text: text}, opts)
    :ok
  end

  defp sender(user, opts) do
    case :ets.lookup(Keyword.fetch!(opts, :people), user) do
      [{^user, name}] ->
        Principal.new(:slack, user, name: name)

      [] ->
        name = named(user, opts)
        :ets.insert(Keyword.fetch!(opts, :people), {user, name})
        Principal.new(:slack, user, name: name)
    end
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
