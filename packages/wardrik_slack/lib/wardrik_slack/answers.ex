defmodule WardrikSlack.Answers do
  @moduledoc """
  What a press of a button `WardrikSlack.Notices` posted does.

  Each button carries who may press it, as the target that posted it named
  them: each by `@handle`, email address or Slack user id; anyone in the
  channel may where it named nobody. An email address needs the app's
  `users:read.email` scope.
  """

  require Logger

  @doc """
  Answers a button press, from the `block_actions` payload Slack sends over
  Socket Mode: decides the call, and replaces the message's buttons with who
  decided it; or, for Show link, tells the person pressing alone where to
  connect the account; or tells them why nothing happened.

  `opts` are the channel's: `:token`, which looks up a presser's email
  address where an approver is named by one, and `:req_options`, merged into
  each request.
  """
  @spec answer(map(), keyword()) :: :ok | :ignored
  def answer(payload, opts \\ [])

  def answer(%{"actions" => [%{"action_id" => action, "value" => value} | _]} = payload, opts)
      when action in ["wardrik_approve", "wardrik_deny", "wardrik_link"] do
    user = Map.get(payload, "user", %{})

    with {:ok, %{"a" => text, "c" => call, "n" => name, "p" => approvers}} <- JSON.decode(value),
         {:ok, agent} <- Wardrik.AgentID.parse(text) do
      reply =
        cond do
          not approver?(user, approvers, opts) ->
            ephemeral("Only this channel's approvers can answer that.")

          action == "wardrik_link" ->
            ephemeral(link(agent, call))

          true ->
            decide(payload, action, user, agent, call, name)
        end

      respond(payload["response_url"], reply, Keyword.get(opts, :req_options, []))
    else
      _unreadable -> :ignored
    end
  end

  def answer(_payload, _opts), do: :ignored

  # An approver is named by `@handle`, email address or user id. The
  # presser's email address is looked up only where no handle or id matched.
  defp approver?(_user, [], _opts), do: true

  defp approver?(user, approvers, opts) do
    {emails, named} = Enum.split_with(approvers, &email?/1)

    Enum.any?(named, &(&1 == user["id"] or &1 == "@" <> to_string(user["username"]))) or
      (emails != [] and email(user, opts) in Enum.map(emails, &String.downcase/1))
  end

  defp email?("@" <> _handle), do: false
  defp email?(approver), do: String.contains?(approver, "@")

  defp email(user, opts) do
    case WardrikSlack.post(
           "users.info",
           Keyword.fetch!(opts, :token),
           %{user: user["id"]},
           Keyword.get(opts, :req_options, [])
         ) do
      {:ok, %{"user" => %{"profile" => %{"email" => email}}}} -> String.downcase(email)
      _unknown -> nil
    end
  end

  # Read from the agent as the person presses, so it is never in a message
  # anyone else can see.
  defp link(agent, call) do
    case Wardrik.Agent.parked(agent) do
      {:error, :not_found} -> "#{agent} is not running."
      calls -> calls |> Enum.find(fn {parked, _prompt} -> parked.id == call end) |> link_text()
    end
  end

  defp link_text({%{link: %{url: url, code: code}}, _prompt}) when is_binary(code),
    do: "Enter `#{code}` at #{url}"

  defp link_text({%{link: %{url: url}}, _prompt}), do: "Open #{url}"
  defp link_text(_answered), do: "That is no longer waiting on anyone to connect."

  defp decide(payload, action, user, agent, call, name) do
    reason = reason(payload, call)
    decision = decision(action, reason, user["username"] || user["name"] || user["id"])
    by = Wardrik.Principal.new(:slack, user["id"], name: user["username"] || user["name"])

    case Wardrik.Agent.decide(agent, %{call => decision}, by: by) do
      :ok -> decided(payload, action, reason, user, call, name)
      {:error, :not_found} -> ephemeral("#{agent} is not running.")
      {:error, :unrecorded} -> ephemeral("#{agent} could not record that, so it was not taken.")
      {:error, _not_waiting} -> ephemeral("That was already answered.")
    end
  end

  defp decision("wardrik_approve", _reason, _who), do: :approve
  defp decision(_deny, nil, who), do: {:deny, "Denied in Slack by #{who}."}
  defp decision(_deny, reason, who), do: {:deny, "Denied in Slack by #{who}: #{reason}"}

  # What was written in the call's box as the button was pressed, where
  # anything was.
  defp reason(payload, call) do
    case get_in(payload, [
           "state",
           "values",
           WardrikSlack.Notices.reason_block(call),
           "reason",
           "value"
         ]) do
      text when is_binary(text) -> if String.trim(text) == "", do: nil, else: String.trim(text)
      _nothing -> nil
    end
  end

  # The message keeps what it asked, and the answered call's box and buttons
  # give way to who answered it, and what they said.
  defp decided(payload, action, reason, user, call, name) do
    verb = if action == "wardrik_approve", do: "Approved", else: "Denied"
    why = if verb == "Denied" and reason, do: ": " <> reason, else: ""
    line = WardrikSlack.Notices.context("#{verb} `#{name}` — <@#{user["id"]}>#{why}")
    box = WardrikSlack.Notices.reason_block(call)

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

  defp ephemeral(text), do: %{response_type: "ephemeral", replace_original: false, text: text}

  defp respond(nil, _reply, _req_options), do: :ok

  defp respond(url, reply, req_options) do
    case Req.post(url, Keyword.merge([json: reply], req_options)) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      other ->
        Logger.warning("Could not update a Slack message: #{inspect(other)}")
        :ok
    end
  end
end
