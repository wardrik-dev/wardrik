defmodule WardrikSlack.Answers do
  @moduledoc """
  Handles presses of the buttons `WardrikSlack.Waiting` posts.

    * Approve and Deny call `WardrikChannel.decide/2` with the typed note, then show who decided.
    * Show link tells only the person who pressed it where to sign in.
  """

  alias Wardrik.Error
  alias WardrikChannel.Answer
  alias WardrikChannel.Workspace
  alias WardrikSlack.API
  alias WardrikSlack.Blocks
  alias WardrikSlack.Messages
  alias WardrikSlack.Waiting

  @doc "Handles a `block_actions` payload from a waiting call's buttons. Returns `:ignored` for any other."
  @spec answer(Workspace.t(), map()) :: :ok | :ignored
  def answer(
        workspace,
        %{"actions" => [%{"action_id" => action, "value" => value} | _rest]} = payload
      ) do
    case JSON.decode(value) do
      {:ok, %{"g" => _agent, "i" => _interrupt} = button} ->
        respond(workspace, payload, action, button)

      _unreadable ->
        :ignored
    end
  end

  def answer(_workspace, _payload), do: :ignored

  defp respond(workspace, payload, action, %{"i" => interrupt} = button) do
    member = Messages.sender(workspace, get_in(payload, ["user", "id"]))
    reply = pressed(action, workspace, member, button, note(payload, interrupt))

    API.respond(
      payload["response_url"],
      reply(reply, payload, button, member),
      req_options(workspace)
    )
  end

  defp pressed("wardrik_link", workspace, member, button, _note) do
    with {:ok, scope} <- Workspace.member_scope(workspace, member),
         {:ok, %Wardrik.Authorization{url: url}} <-
           Wardrik.Agent.authorization(scope, call(button) ++ held(button)) do
      {:said, "Sign in at #{url}"}
    else
      {:error, %Error{message: message}} -> {:said, message}
      {:error, why} -> {:said, why}
    end
  end

  defp pressed(action, workspace, member, button, note) do
    answer = %Answer{
      member: member,
      agent: button["g"],
      conversation: button["c"],
      interrupt: button["i"],
      asked_by: button["a"],
      decision: decision(action, note)
    }

    case WardrikChannel.decide(workspace, answer) do
      {:ok, _decision} -> {:decided, action, note}
      {:error, message} -> {:said, message}
    end
  end

  defp call(button), do: [agent: button["g"], interrupt: button["i"]]

  # A notice's call is in the agent's own conversation, which is named by none.
  defp held(%{"c" => conversation}) when is_binary(conversation),
    do: [conversation: conversation]

  defp held(_button), do: []

  defp decision("wardrik_approve", note), do: {:approve, note}
  defp decision("wardrik_deny", note), do: {:deny, note}

  defp reply({:said, text}, _payload, _button, _member), do: Blocks.ephemeral(text)

  defp reply({:decided, action, note}, payload, button, member) do
    verb = if action == "wardrik_approve", do: "Approved", else: "Denied"
    said = if note, do: ": " <> note, else: ""
    line = Blocks.context("#{verb} `#{button["n"]}` by <@#{member.id}>#{said}")

    %{
      replace_original: true,
      text: "#{verb} #{button["n"]}",
      blocks: without_buttons(payload, button["i"], line)
    }
  end

  defp without_buttons(payload, interrupt, line) do
    buttons = Waiting.buttons_block(interrupt)
    note = Waiting.note_block(interrupt)

    payload
    |> get_in(["message", "blocks"])
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"block_id" => ^buttons} -> [line]
      %{"block_id" => ^note} -> []
      block -> [block]
    end)
  end

  defp note(payload, interrupt) do
    case get_in(payload, ["state", "values", Waiting.note_block(interrupt), "note", "value"]) do
      text when is_binary(text) -> present(String.trim(text))
      _nothing -> nil
    end
  end

  defp present(""), do: nil
  defp present(text), do: text

  defp req_options(%Workspace{channel: channel}), do: API.req_options(channel)
end
