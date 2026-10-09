defmodule WardrikSlack.Rooms do
  @moduledoc """
  A Slack channel coming to have an agent answer in it, as
  `WardrikChannel.Rooms` sets out.

  When the bot is invited into a Slack channel, it says which agent answers
  there: the one the channel offers, or a button for each to choose among.
  Where the channel offers none, it says nothing, so a Slack channel it only
  posts notices in stays as it was.
  Either way the message then says when it answers, with a button to answer
  when mentioned and one to answer every message. Taking the bot out of the
  Slack channel unbinds it.

  Whoever invited the bot, chose the agent, or took the bot out is who the
  change is recorded as made by, as a `:slack` principal.
  """

  alias Wardrik.AgentID
  alias Wardrik.Principal
  alias WardrikChannel.Room

  @max_buttons 5

  @doc """
  Acts on an event Slack sent: the bot invited into a Slack channel, or taken
  out of one. Others are passed over.

  `opts` are the channel's: `:context`, `:bot`, the bot's user id, `:token`
  and `:req_options`.
  """
  @spec event(map(), keyword()) :: :ok | :ignored | {:error, term()}
  def event(%{"type" => "member_joined_channel", "user" => bot, "channel" => room} = event, opts) do
    if bot == opts[:bot] do
      context = Keyword.fetch!(opts, :context)

      case WardrikChannel.Rooms.joined(context, room, slack(event["inviter"])) do
        {:bound, bound} -> post(room, bound(bound), opts)
        {:choose, []} -> :ignored
        {:choose, agents} -> post(room, choose(agents), opts)
      end
    else
      :ignored
    end
  end

  def event(%{"type" => type, "channel" => room} = event, opts)
      when type in ["channel_left", "group_left"] do
    WardrikChannel.Rooms.left(Keyword.fetch!(opts, :context), room, slack(event["actor_id"]))
  end

  def event(_event, _opts), do: :ignored

  @doc """
  Answers a press of a button this posted: binds the room to the agent
  chosen, or changes when it answers, and replaces the message with what it
  now says.
  """
  @spec answer(map(), keyword()) :: :ok | :ignored
  def answer(%{"actions" => [%{"action_id" => action} = pressed | _]} = payload, opts)
      when action in ["wardrik_room_agent", "wardrik_room_answers"] do
    context = Keyword.fetch!(opts, :context)
    room = get_in(payload, ["channel", "id"])
    user = Map.get(payload, "user", %{})
    by = slack(user["id"], user["username"] || user["name"])

    reply =
      case act(action, value(pressed), context, room, by) do
        {:ok, bound} -> Map.merge(%{replace_original: true}, bound(bound))
        {:error, :not_offered} -> WardrikSlack.ephemeral("That agent is no longer offered here.")
        {:error, :not_bound} -> WardrikSlack.ephemeral("No agent answers here; invite me again.")
        :error -> WardrikSlack.ephemeral("That does not read as an agent.")
      end

    WardrikSlack.respond(payload["response_url"], reply, Keyword.get(opts, :req_options, []))
  end

  def answer(_payload, _opts), do: :ignored

  defp act("wardrik_room_agent", text, context, room, by) do
    case AgentID.parse(to_string(text)) do
      {:ok, agent} -> WardrikChannel.Rooms.chose(context, room, agent, by)
      {:error, _message} -> :error
    end
  end

  defp act("wardrik_room_answers", "everything", context, room, by),
    do: WardrikChannel.Rooms.answers(context, room, :everything, by)

  defp act("wardrik_room_answers", _mentions, context, room, by),
    do: WardrikChannel.Rooms.answers(context, room, :mentions, by)

  # A button carries its value; a menu, the option chosen.
  defp value(%{"value" => value}), do: value
  defp value(%{"selected_option" => %{"value" => value}}), do: value
  defp value(_pressed), do: nil

  # -- messages --------------------------------------------------------------

  @doc false
  @spec bound(Room.t()) :: %{text: String.t(), blocks: [map()]}
  def bound(%Room{agent: agent, answers: answers}) do
    when_ = if answers == :everything, do: "to every message", else: "when mentioned"
    text = "I'll answer here as *#{agent}*, #{when_}."

    %{
      text: text,
      blocks: [
        section(text),
        WardrikSlack.actions("wardrik_room", [
          answers_button("When mentioned", "mentions", answers == :mentions),
          answers_button("Every message", "everything", answers == :everything)
        ]),
        context_line("Take me out of this channel to stop.")
      ]
    }
  end

  @doc false
  @spec choose([AgentID.t()]) :: %{text: String.t(), blocks: [map()]}
  def choose(agents) do
    text = "Which agent should answer here?"
    %{text: text, blocks: [section(text), WardrikSlack.actions("wardrik_room", picker(agents))]}
  end

  defp picker(agents) when length(agents) <= @max_buttons,
    do:
      Enum.map(agents, fn agent ->
        button(to_string(agent), "wardrik_room_agent", to_string(agent), nil)
      end)

  defp picker(agents) do
    options =
      Enum.map(agents, &%{text: plain(to_string(&1)), value: to_string(&1)})

    [
      %{
        type: "static_select",
        action_id: "wardrik_room_agent",
        placeholder: plain("Choose an agent"),
        options: options
      }
    ]
  end

  defp answers_button(label, value, current?),
    do: button(label, "wardrik_room_answers", value, if(current?, do: "primary"))

  defp button(label, action, value, style) do
    %{type: "button", text: plain(label), action_id: action, value: value}
    |> then(fn button -> if style, do: Map.put(button, :style, style), else: button end)
  end

  defp plain(text), do: %{type: "plain_text", text: text}
  defp section(text), do: %{type: "section", text: %{type: "mrkdwn", text: text}}
  defp context_line(text), do: %{type: "context", elements: [%{type: "mrkdwn", text: text}]}

  defp post(room, message, opts) do
    case WardrikSlack.post(
           "chat.postMessage",
           Keyword.fetch!(opts, :token),
           Map.put(message, :channel, room),
           Keyword.get(opts, :req_options, [])
         ) do
      {:ok, _reply} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp slack(id, name \\ nil)
  defp slack(nil, _name), do: nil
  defp slack(id, name), do: Principal.new(:slack, id, name: name)
end
