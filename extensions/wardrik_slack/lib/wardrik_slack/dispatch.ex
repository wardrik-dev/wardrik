defmodule WardrikSlack.Dispatch do
  @moduledoc """
  Routes what Slack sends, over Socket Mode or HTTP, within the workspace it came from.

  | Slack sends                              | Handled by               |
  | ---------------------------------------- | ------------------------ |
  | a message                                | `WardrikSlack.Messages`  |
  | the bot joining or leaving a channel     | `WardrikSlack.Rooms`     |
  | a room's button or menu                  | `WardrikSlack.Rooms`     |
  | a waiting call's button                  | `WardrikSlack.Answers`   |
  | `app_uninstalled` or `tokens_revoked`    | forgets the workspace    |

  Anything from a workspace the channel isn't added to is logged and ignored.
  """

  require Logger

  alias WardrikChannel.Channel
  alias WardrikSlack.Answers
  alias WardrikSlack.Messages
  alias WardrikSlack.Rooms

  @doc "Handles an `event_callback`."
  @spec event(Channel.t(), map()) :: term()
  def event(channel, %{"team_id" => team, "event" => %{"type" => type}})
      when type in ["app_uninstalled", "tokens_revoked"] do
    WardrikChannel.Channel.uninstall(channel, team)
  end

  def event(channel, %{"team_id" => team, "event" => %{"type" => type} = event} = callback) do
    handler = if type == "message", do: Messages, else: Rooms
    within(channel, team, &handler.event(&1, event, bot(callback)))
  end

  def event(_channel, _callback), do: :ignored

  @doc "Handles a button press or a menu choice."
  @spec interactive(Channel.t(), map()) :: term()
  def interactive(
        channel,
        %{"team" => %{"id" => team}, "actions" => [%{"action_id" => action} | _rest]} = payload
      ) do
    handler = if String.starts_with?(action, "wardrik_room"), do: Rooms, else: Answers
    within(channel, team, &handler.answer(&1, payload))
  end

  def interactive(_channel, _payload), do: :ignored

  defp bot(%{"authorizations" => [%{"user_id" => bot} | _rest]}), do: bot
  defp bot(_callback), do: nil

  defp within(channel, team, act) do
    case WardrikChannel.workspace(channel, team) do
      {:ok, workspace} ->
        act.(workspace)

      :error ->
        Logger.warning("#{channel.name} isn't added to the Slack workspace #{team}.")
        :ignored
    end
  end
end
