defmodule WardrikSlack.Home do
  @moduledoc """
  Fills the app's Home tab in Slack each time a member opens it.

  By default the page is `WardrikSlack.Home.Agents`: the agents the member can use here, and the
  calls they're waiting on. To show your own page, name a module with the channel's `:home`
  option:

      slack: {WardrikSlack, ..., home: {MyApp.SlackHome, []}}

      defmodule MyApp.SlackHome do
        @behaviour WardrikSlack.Home

        @impl true
        def blocks(%WardrikSlack.Home.Request{} = request, _opts) do
          [WardrikSlack.Blocks.section("*Welcome to MyApp*")] ++
            WardrikSlack.Home.Agents.blocks(request, [])
        end
      end

  `home: false` leaves the tab alone. Slack shows at most 100 blocks.

  Needs `home_tab_enabled: true` in the app's manifest, and the `app_home_opened` event.
  """

  alias Wardrik.Chat.Workspace
  alias WardrikSlack.API
  alias WardrikSlack.Home.Request
  alias WardrikSlack.Messages

  require Logger

  @max_blocks 100

  @doc "Returns the Block Kit blocks of the member's Home tab."
  @callback blocks(Request.t(), opts :: term()) :: [map()]

  @doc "Handles `app_home_opened` on the Home tab. Returns `:ignored` for any other event."
  @spec event(Workspace.t(), map(), String.t() | nil) :: :ok | :ignored
  def event(workspace, %{"type" => "app_home_opened", "tab" => "home", "user" => user}, _bot) do
    case page(workspace) do
      {module, opts} -> publish(workspace, user, module, opts)
      false -> :ok
    end
  end

  def event(_workspace, _event, _bot), do: :ignored

  defp page(%Workspace{channel: channel}),
    do: Keyword.get(channel.options, :home, {WardrikSlack.Home.Agents, []})

  defp publish(workspace, user, module, opts) do
    request = %Request{workspace: workspace, member: Messages.sender(workspace, user)}
    blocks = module.blocks(request, opts)
    view = %{user_id: user, view: %{type: "home", blocks: Enum.take(blocks, @max_blocks)}}

    case API.post_in(workspace, "views.publish", view) do
      {:ok, _published} -> :ok
      {:error, reason} -> Logger.warning("Slack didn't take the Home tab: #{inspect(reason)}")
    end

    :ok
  end
end
