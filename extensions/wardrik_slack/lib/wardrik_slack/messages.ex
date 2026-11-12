defmodule WardrikSlack.Messages do
  @moduledoc """
  Passes messages posted in Slack channels to `Wardrik.Chat.received/2`, and reacts to them.

    * A message the agent takes gets :eyes:, then :white_check_mark: once it's answered.
    * A message the agent couldn't take gets a reply in its thread saying why.

  Ignores edits, deletions, bots, direct messages, and people from another workspace.
  """

  alias Wardrik.Chat.Inbound
  alias Wardrik.Chat.Member
  alias Wardrik.Chat.Workspace
  alias WardrikSlack.API

  @posted [nil, "thread_broadcast", "file_share"]

  @doc """
  Passes a `message` event to the room's agent. `bot` is the app's own member ID.

  Returns `{:asked, {agent, conversation}}`, `:ignored`, or `{:error, message}` after replying
  with it.
  """
  @spec event(Workspace.t(), map(), String.t()) ::
          {:asked, {String.t(), String.t()}} | :ignored | {:error, String.t()}
  def event(workspace, %{"type" => "message", "user" => user} = event, bot)
      when is_binary(user) do
    if posted?(workspace, event, bot), do: ask(workspace, event, bot), else: :ignored
  end

  def event(_workspace, _event, _bot), do: :ignored

  defp posted?(%Workspace{installation: installation}, event, bot) do
    event["subtype"] in @posted and is_nil(event["bot_id"]) and event["user"] != bot and
      event["channel_type"] in ["channel", "group"] and
      (event["user_team"] || event["team"] || installation.workspace) == installation.workspace
  end

  defp ask(workspace, %{"channel" => room, "ts" => ts} = event, bot) do
    mention = "<@#{bot}>"
    text = Map.get(event, "text", "")

    inbound = %Inbound{
      room: room,
      thread: thread(event["thread_ts"], ts),
      id: ts,
      sender: sender(workspace, event["user"]),
      text: text |> String.replace(mention, "") |> String.trim(),
      mentioned?: String.contains?(text, mention)
    }

    case Wardrik.Chat.received(workspace, inbound) do
      {:asked, conversation} ->
        react(workspace, "reactions.add", room, ts, "eyes")
        {:asked, conversation}

      :ignored ->
        :ignored

      {:error, message} ->
        say(workspace, room, inbound.thread || ts, ":warning: " <> message)
        {:error, message}
    end
  end

  defp thread(nil, _ts), do: nil
  defp thread(ts, ts), do: nil
  defp thread(thread, _ts), do: thread

  @doc "Swaps :eyes: for :white_check_mark: on the answered messages `ids`."
  @spec answered(Workspace.t(), String.t(), [String.t()]) :: :ok
  def answered(workspace, room, ids) do
    for ts <- ids do
      react(workspace, "reactions.remove", room, ts, "eyes")
      react(workspace, "reactions.add", room, ts, "white_check_mark")
    end

    :ok
  end

  @doc "Removes :eyes: from the messages `ids`, when a run stops before answering."
  @spec stopped(Workspace.t(), String.t(), [String.t()]) :: :ok
  def stopped(workspace, room, ids) do
    for ts <- ids, do: react(workspace, "reactions.remove", room, ts, "eyes")
    :ok
  end

  @doc """
  Returns the member `user`, with the name Slack shows for them, and their email address if
  they're in the workspace.
  """
  @spec sender(Workspace.t(), String.t()) :: Member.t()
  def sender(%Workspace{installation: installation} = workspace, user) do
    case API.read_in(workspace, "users.info", %{user: user}) do
      {:ok, %{"user" => found}} ->
        %Member{id: user, name: name(found), email: email(found, installation.workspace)}

      _unknown ->
        %Member{id: user}
    end
  end

  # Someone from another workspace, over Slack Connect, has an address that workspace vouches for.
  defp email(%{"team_id" => workspace, "profile" => %{"email" => email}}, workspace)
       when is_binary(email),
       do: email

  defp email(_user, _workspace), do: nil

  defp name(user) do
    profile = Map.get(user, "profile", %{})

    Enum.find(
      [profile["display_name"], profile["real_name"], user["name"]],
      &(is_binary(&1) and &1 != "")
    )
  end

  defp react(workspace, method, room, ts, name) do
    _reacted = API.post_in(workspace, method, %{channel: room, timestamp: ts, name: name})
    :ok
  end

  defp say(workspace, room, thread, text) do
    _said =
      API.post_in(workspace, "chat.postMessage", %{channel: room, thread_ts: thread, text: text})

    :ok
  end
end
