defmodule WardrikSlack.Dispatch do
  @moduledoc """
  What Slack sends a channel, over Socket Mode or HTTP alike, handed to what
  acts on it in the workspace it came from.

  An event names its workspace by `team_id`, and a button press by its
  `team`; each is acted on in the `WardrikChannel.Workspace` of the
  channel's installation there, and passed over, with a warning, where the
  channel is not installed there. A message goes to `WardrikSlack.Threads`;
  the app taken out of the workspace, or its tokens revoked, forgets the
  installation; any other event, such as the bot invited into a room, goes
  to `WardrikSlack.Rooms`. A press of a button that binds a room goes to
  `WardrikSlack.Rooms`, and any other to `WardrikSlack.Answers`.

  Each is handed the workspace as `:workspace`, its installation's `:token`,
  the id Slack gives it as `:team`, the bot's user id there as `:bot`, and
  `:req_options`.
  """

  require Logger

  alias WardrikChannel.Installations
  alias WardrikChannel.Workspace

  @doc "Acts on an event callback, as Slack sends one: the event, and its workspace's `team_id`."
  @spec event(map(), keyword()) :: term()
  def event(%{"team_id" => team, "event" => %{"type" => type}}, opts)
      when type in ["app_uninstalled", "tokens_revoked"] do
    context = Keyword.fetch!(opts, :context)
    Installations.delete(context.installations, context.channel, team)
  end

  def event(%{"team_id" => team, "event" => %{"type" => type} = event}, opts) do
    handler = if type == "message", do: WardrikSlack.Threads, else: WardrikSlack.Rooms
    within(team, opts, &handler.event(event, &1))
  end

  def event(_callback, _opts), do: :ignored

  @doc "Acts on a button press, or a choice from a menu, as Slack sends one."
  @spec interactive(map(), keyword()) :: term()
  def interactive(%{"team" => %{"id" => team}} = payload, opts) do
    handler =
      case payload do
        %{"actions" => [%{"action_id" => "wardrik_room" <> _} | _]} -> WardrikSlack.Rooms
        _other -> WardrikSlack.Answers
      end

    within(team, opts, &handler.answer(payload, &1))
  end

  def interactive(_payload, _opts), do: :ignored

  defp within(team, opts, act) do
    context = Keyword.fetch!(opts, :context)
    req_options = Keyword.get(opts, :req_options, [])

    with {:ok, workspace} <- Workspace.new(context, team),
         {:ok, bot} <- WardrikSlack.bot(workspace.installation, req_options) do
      act.(
        workspace: workspace,
        token: workspace.installation.token,
        team: team,
        bot: bot,
        req_options: req_options
      )
    else
      :error ->
        Logger.warning("#{context.channel} is not installed in the Slack workspace #{team}")
        :ignored

      {:error, reason} ->
        Logger.warning(
          "Slack did not say which bot #{context.channel} posts as: #{inspect(reason)}"
        )

        :ignored
    end
  end
end
