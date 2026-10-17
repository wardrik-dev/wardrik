defmodule WardrikSlack.Rooms do
  @moduledoc """
  A Slack channel coming to have an agent answer in it, as
  `WardrikChannel.Rooms` sets out, and what the bot says there as it does.

  Invited into a Slack channel, the bot always says where things stand:

    * the one agent offered answers there now: what it is for, how to reach
      it, a button to have it answer every message or only when mentioned,
      and a menu to use another agent or stop it answering there
    * several are offered: each with what it is for, and a button to use it
    * none is, and one may be created: a button to create one for the Slack
      channel, from the deployment's defaults
    * none is, and none may be created: who can offer one, and a button to
      look again once they have

  Taking the bot out of the Slack channel unbinds it. Whoever invited the
  bot, chose, or pressed is who each change is recorded as made by, as a
  principal of the workspace.
  """

  alias Wardrik.AgentID
  alias WardrikChannel.Offer
  alias WardrikChannel.Room
  alias WardrikChannel.Workspace

  @max_buttons 5

  @doc """
  Acts on an event Slack sent: the bot invited into a Slack channel, or taken
  out of one. Others are passed over. `opts` are as `WardrikSlack.Dispatch`
  hands them on.
  """
  @spec event(map(), keyword()) :: :ok | :ignored | {:error, term()}
  def event(%{"type" => "member_joined_channel", "user" => bot, "channel" => room} = event, opts) do
    if bot == opts[:bot] do
      workspace = Keyword.fetch!(opts, :workspace)

      workspace
      |> WardrikChannel.Rooms.joined(room, name(room, opts), sender(event["inviter"], opts))
      |> message(workspace, opts)
      |> post(room, opts)
    else
      :ignored
    end
  end

  def event(%{"type" => type, "channel" => room} = event, opts)
      when type in ["channel_left", "group_left"] do
    WardrikChannel.Rooms.left(
      Keyword.fetch!(opts, :workspace),
      room,
      sender(event["actor_id"], opts)
    )
  end

  def event(_event, _opts), do: :ignored

  @doc """
  Answers a press of a button, or a choice from a menu, this posted, and
  replaces the message with what the Slack channel shows now.
  """
  @spec answer(map(), keyword()) :: :ok | :ignored
  def answer(
        %{"actions" => [%{"action_id" => "wardrik_room_" <> action} = pressed | _]} = payload,
        opts
      )
      when action in ["agent", "answers", "create", "more"] do
    workspace = Keyword.fetch!(opts, :workspace)
    %{"id" => room} = channel = Map.get(payload, "channel", %{})
    user = Map.get(payload, "user", %{})
    by = sender(user["id"], opts, user["username"] || user["name"])
    name = channel["name"] || room

    reply =
      case act(action, value(pressed), workspace, {room, name}, by) do
        {:error, message} when is_binary(message) -> WardrikSlack.ephemeral(message)
        shown -> Map.put(message(shown, workspace, opts), :replace_original, true)
      end

    WardrikSlack.respond(payload["response_url"], reply, Keyword.get(opts, :req_options, []))
  end

  def answer(_payload, _opts), do: :ignored

  defp act("agent", text, workspace, {room, _name}, by) do
    with {:ok, agent} <- AgentID.parse(to_string(text)),
         {:ok, bound, offer} <- WardrikChannel.Rooms.chose(workspace, room, agent, by) do
      {:bound, bound, offer}
    else
      {:error, :not_offered} -> {:error, "That agent is no longer offered here."}
      {:error, _not_an_id} -> {:error, "That does not read as an agent."}
    end
  end

  defp act("answers", answers, workspace, {room, name}, by) do
    answers = if answers == "everything", do: :everything, else: :mentions

    case WardrikChannel.Rooms.answers(workspace, room, answers, by) do
      {:ok, bound, offer} -> {:bound, bound, offer}
      {:error, :not_bound} -> WardrikChannel.Rooms.choices(workspace, name)
    end
  end

  defp act("create", name, workspace, {room, _name}, by) do
    with {:ok, bound, offer} <-
           WardrikChannel.Rooms.create(workspace, room, to_string(name), by),
         do: {:bound, bound, offer}
  end

  defp act("more", "stop", workspace, {room, _name}, by) do
    :ok = WardrikChannel.Rooms.left(workspace, room, by)
    :stopped
  end

  defp act("more", _choose, workspace, {_room, name}, _by),
    do: WardrikChannel.Rooms.choices(workspace, name)

  # A button carries its value; a menu, the option chosen.
  defp value(%{"value" => value}), do: value
  defp value(%{"selected_option" => %{"value" => value}}), do: value
  defp value(_pressed), do: nil

  # -- messages --------------------------------------------------------------

  @doc false
  @spec message(WardrikChannel.Rooms.shown() | :stopped, Workspace.t(), keyword()) ::
          %{text: String.t(), blocks: [map()]}
  def message({:bound, %Room{agent: agent, answers: answers}, offer}, workspace, opts) do
    text = ":wave: *#{agent}* answers here now."

    {how, toggle} =
      if answers == :everything,
        do:
          {"It answers every message here, each in a thread of its own.",
           button("Answer only when mentioned", "wardrik_room_answers", "mentions")},
        else:
          {"Mention <@#{opts[:bot]}> and it answers in a thread under your message.",
           button("Answer every message", "wardrik_room_answers", "everything")}

    %{
      text: text,
      blocks:
        [section(text)] ++
          described(offer) ++
          [
            section(how <> " " <> approving(asked(workspace))),
            WardrikSlack.actions("wardrik_room", [toggle, more()])
          ]
    }
  end

  def message({:choose, offers}, _workspace, _opts) do
    text = "Which agent should answer here? It answers when mentioned; you can change that after."
    %{text: text, blocks: [section(text) | choose(offers)]}
  end

  def message({:create, name}, workspace, _opts) do
    text = "No agent answers in Slack here yet."

    %{
      text: text,
      blocks: [
        section(text),
        WardrikSlack.actions("wardrik_room", [
          button("Create an agent for ##{name}", "wardrik_room_create", name, "primary")
        ]),
        context_line(
          "It starts from this deployment's defaults, and answers when mentioned. Whoever runs " <>
            "Wardrik can change what it does later, or offer an agent they have here by adding " <>
            "`channels: [#{workspace.context.channel}]` to its file."
        )
      ]
    }
  end

  def message(:none, workspace, _opts) do
    text =
      "No agent answers in Slack here yet. Whoever runs Wardrik can offer one by adding " <>
        "`channels: [#{workspace.context.channel}]` to its agent file."

    look_again = button("Look again", "wardrik_room_more", "choose")
    %{text: text, blocks: [section(text), WardrikSlack.actions("wardrik_room", [look_again])]}
  end

  def message(:stopped, _workspace, _opts) do
    text = "No agent answers here now."
    choose = button("Choose an agent", "wardrik_room_more", "choose")
    %{text: text, blocks: [section(text), WardrikSlack.actions("wardrik_room", [choose])]}
  end

  defp described(%Offer{description: description}) when is_binary(description),
    do: [context_line("_#{description}_")]

  defp described(_offer), do: []

  defp choose(offers) when length(offers) <= @max_buttons do
    for %Offer{agent: agent, description: description} <- offers do
      line = if description, do: "*#{agent}*\n#{description}", else: "*#{agent}*"
      Map.put(section(line), :accessory, button("Use", "wardrik_room_agent", to_string(agent)))
    end
  end

  defp choose(offers) do
    options =
      for %Offer{agent: agent, description: description} <- offers do
        option = %{text: plain(to_string(agent)), value: to_string(agent)}
        if description, do: Map.put(option, :description, plain(clip(description))), else: option
      end

    select = %{
      type: "static_select",
      action_id: "wardrik_room_agent",
      placeholder: plain("Choose an agent"),
      options: options
    }

    [WardrikSlack.actions("wardrik_room", [select])]
  end

  defp more do
    %{
      type: "overflow",
      action_id: "wardrik_room_more",
      options: [
        %{text: plain("Use another agent"), value: "choose"},
        %{text: plain("Stop answering here"), value: "stop"}
      ]
    }
  end

  defp button(label, action, value, style \\ nil) do
    button = %{type: "button", text: plain(label), action_id: action, value: value}
    if style, do: Map.put(button, :style, style), else: button
  end

  # An option's description is at most 75 characters.
  defp clip(text),
    do: if(String.length(text) > 75, do: String.slice(text, 0, 74) <> "…", else: text)

  defp plain(text), do: %{type: "plain_text", text: text}
  defp section(text), do: %{type: "section", text: %{type: "mrkdwn", text: text}}
  defp context_line(text), do: %{type: "context", elements: [%{type: "mrkdwn", text: text}]}

  # -- Slack -----------------------------------------------------------------

  # The Slack channel's name, for an agent created for it, or its id where
  # Slack does not say.
  defp name(room, opts) do
    case WardrikSlack.post(
           "conversations.info",
           Keyword.fetch!(opts, :token),
           %{channel: room},
           Keyword.get(opts, :req_options, [])
         ) do
      {:ok, %{"channel" => %{"name" => name}}} -> name
      _unknown -> room
    end
  end

  defp post(message, room, opts) do
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

  defp sender(id, opts, name \\ nil)
  defp sender(nil, _opts, _name), do: nil

  defp sender(id, opts, name),
    do: WardrikChannel.principal(Keyword.fetch!(opts, :workspace).installation, id, name)

  defp asked(workspace),
    do: workspace |> Workspace.approvers() |> WardrikChannel.Approvers.asked()

  defp approving([]), do: "A call that needs approval waits here for someone to approve it."

  defp approving(approvers),
    do:
      "A call that needs approval is sent to #{WardrikSlack.Approvers.named(approvers)} " <>
        "to approve, and the thread says so."
end
