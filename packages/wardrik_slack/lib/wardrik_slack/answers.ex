defmodule WardrikSlack.Answers do
  @moduledoc """
  What a press of a button `WardrikSlack.Notices` posted does.

  The person pressing is the principal `WardrikChannel.principal/3` makes of
  them, in the workspace they pressed it in, and may do what the host's
  `Wardrik.Grants` says, as `Wardrik.Host.caller/2` answers it on the host
  the channel's context carries: they decide a call with `Wardrik.agent_approve/4` or
  `Wardrik.agent_deny/4`, so where their grant allows `:decide` on the
  agent, or where they asked for the turn that waits; and they are shown
  where to connect an account where their grant allows `:decide`.
  """

  alias Wardrik.Error
  alias WardrikChannel.Workspace

  @refused "Only whoever asked, or the approvers here, can answer that. "

  @doc """
  Answers a button press, from the `block_actions` payload Slack sends:
  decides the call, and replaces the message's buttons with who decided it;
  or, for Show link, tells the person pressing alone where to connect the
  account; or tells them why nothing happened. `opts` are as
  `WardrikSlack.Dispatch` hands them on.
  """
  @spec answer(map(), keyword()) :: :ok | :ignored
  def answer(payload, opts \\ [])

  def answer(%{"actions" => [%{"action_id" => action, "value" => value} | _]} = payload, opts)
      when action in ["wardrik_approve", "wardrik_deny", "wardrik_link"] do
    user = Map.get(payload, "user", %{})

    with {:ok, %{"a" => text, "c" => call, "n" => name}} <- JSON.decode(value),
         {:ok, agent} <- Wardrik.AgentID.parse(text) do
      %{context: context, installation: installation} =
        workspace = Keyword.fetch!(opts, :workspace)

      by =
        installation
        |> WardrikChannel.Member.new(user["id"])
        |> WardrikChannel.principal(name: user["username"] || user["name"])

      reply =
        case Wardrik.Host.caller(context.host,
               principal: by,
               subject: agent
             ) do
          {:ok, caller} -> pressed(action, payload, {user, caller}, agent, call, name)
          {:error, _unreached} -> :refused
        end
        |> refused(workspace)

      WardrikSlack.respond(payload["response_url"], reply, Keyword.get(opts, :req_options, []))
    else
      _unreadable -> :ignored
    end
  end

  def answer(_payload, _opts), do: :ignored

  # A press refused says who else may answer, as the host says.
  defp refused(:refused, workspace),
    do: WardrikSlack.ephemeral(@refused <> Workspace.deciding(workspace))

  defp refused(reply, _workspace), do: reply

  defp pressed("wardrik_link", _payload, {_user, caller}, agent, call, _name) do
    if Wardrik.Grant.allows?(caller.grant, :decide, agent),
      do: WardrikSlack.ephemeral(link(agent, call)),
      else: :refused
  end

  defp pressed(action, payload, {user, caller}, agent, call, name) do
    note = note(payload, call)

    session =
      Wardrik.Session.new(host: caller.host, principal: caller.principal, grant: caller.grant)

    case decide(
           action,
           session,
           agent,
           call,
           note,
           user["username"] || user["name"] || user["id"]
         ) do
      {:ok, _decided} -> decided(payload, action, note, user, call, name)
      {:error, %Error{type: :forbidden}} -> :refused
      {:error, %Error{type: :not_found}} -> WardrikSlack.ephemeral("That agent is not running.")
      {:error, %Error{type: :conflict}} -> WardrikSlack.ephemeral("That was already answered.")
      {:error, %Error{message: message}} -> WardrikSlack.ephemeral(message)
    end
  end

  # Read from the agent as the person presses, so it is never in a message
  # anyone else can see.
  defp link(agent, call) do
    case Wardrik.Agent.parked(agent) do
      {:error, :not_found} -> "That agent is not running."
      calls -> calls |> Enum.find(fn {parked, _prompt} -> parked.id == call end) |> link_text()
    end
  end

  defp link_text({%{link: %{url: url, code: code}}, _prompt}) when is_binary(code),
    do: "Enter `#{code}` at #{url}"

  defp link_text({%{link: %{url: url}}, _prompt}), do: "Open #{url}"
  defp link_text(_answered), do: "That is no longer waiting on anyone to connect."

  defp decide("wardrik_approve", session, agent, call, nil, _who),
    do: Wardrik.agent_approve(session, agent, call)

  defp decide("wardrik_approve", session, agent, call, note, _who),
    do: Wardrik.agent_approve(session, agent, call, note: note)

  defp decide(_deny, session, agent, call, nil, who),
    do: Wardrik.agent_deny(session, agent, call, reason: "Denied in Slack by #{who}.")

  defp decide(_deny, session, agent, call, note, who),
    do: Wardrik.agent_deny(session, agent, call, reason: "Denied in Slack by #{who}: #{note}")

  # What was written in the call's box as the button was pressed, where
  # anything was.
  defp note(payload, call) do
    case get_in(payload, [
           "state",
           "values",
           WardrikSlack.Notices.note_block(call),
           "note",
           "value"
         ]) do
      text when is_binary(text) -> if String.trim(text) == "", do: nil, else: String.trim(text)
      _nothing -> nil
    end
  end

  # The message keeps what it asked, and the answered call's box and buttons
  # give way to who answered it, and what they said.
  defp decided(payload, action, note, user, call, name) do
    verb = if action == "wardrik_approve", do: "Approved", else: "Denied"
    said = if note, do: ": " <> note, else: ""
    line = WardrikSlack.Notices.context("#{verb} `#{name}` — <@#{user["id"]}>#{said}")
    box = WardrikSlack.Notices.note_block(call)

    blocks =
      payload
      |> get_in(["message", "blocks"])
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"block_id" => "wardrik:" <> ^call} -> [line]
        %{"block_id" => ^box} -> []
        block -> [block]
      end)

    %{replace_original: true, text: "#{verb} #{name}", blocks: blocks}
  end
end
