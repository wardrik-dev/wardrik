defmodule WardrikWeb.Router do
  @moduledoc """
  Adds the dashboard to a Phoenix router.

      import WardrikWeb.Router

      scope "/" do
        pipe_through :browser
        wardrik_dashboard "/wardrik", resolver: {MyAppWeb.WardrikResolver, []}
      end

    * The pipeline must fetch the session and check CSRF tokens. Phoenix's `:browser` pipeline
      does both.
    * The endpoint must serve the LiveView socket with the session:
      `socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]`.
  """

  @schema NimbleOptions.new!(
            resolver: [
              type: {:tuple, [:atom, :any]},
              required: true,
              doc: "The `WardrikWeb.Resolver` to use, as `{module, opts}`."
            ],
            on_mount: [
              type: {:list, :any},
              default: [],
              doc:
                "Your `on_mount` hooks, for example the one that loads the signed-in user. They run before the resolver."
            ],
            extensions: [
              type: {:list, :atom},
              default: [],
              doc: "The `WardrikWeb.Extension` modules to add."
            ],
            settings: [
              type: :keyword_list,
              keys: Enum.map(WardrikWeb.SettingPage.keys(), &{&1, [type: :mod_arg]}),
              default: [],
              doc: """
              The settings pages to turn on, as `{module, opts}` for each page. `:servers`,
              `:secrets`, `:notify_targets` and `:oauth_apps` take a `WardrikWeb.Settings`.
              `:connections` takes a `WardrikWeb.Connections`.
              """
            ],
            socket_path: [
              type: :string,
              default: "/live",
              doc: "The path of the endpoint's LiveView socket."
            ],
            sign_in: [
              type: :string,
              default: "/",
              doc: "The path to redirect to when the resolver refuses access."
            ],
            live_session: [
              type: :atom,
              default: :wardrik_web,
              doc:
                "The name of the live session. Set a different name for each dashboard if you mount more than one."
            ]
          )

  @doc """
  Mounts the dashboard at `path`.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """
  defmacro wardrik_dashboard(path, opts) do
    quote bind_quoted: [path: path, opts: opts] do
      {session_name, hooks, dashboard} =
        __MODULE__
        |> Phoenix.Router.scoped_path(path)
        |> WardrikWeb.Router.__dashboard__(opts)

      scope path, alias: false, as: false do
        get "/assets/:asset", WardrikWeb.Assets, :show

        live_session session_name,
          on_mount: hooks ++ [{WardrikWeb.Mount, dashboard}],
          root_layout: {WardrikWeb.Layouts, :root},
          layout: {WardrikWeb.Layouts, :app} do
          live "/", WardrikWeb.AgentsLive
          live "/new", WardrikWeb.NewAgentLive
          live "/agents/:agent", WardrikWeb.AgentLive
          live "/approvals", WardrikWeb.ApprovalsLive
          live "/audit", WardrikWeb.AuditLive
          live "/nodes", WardrikWeb.NodesLive
          live "/operations", WardrikWeb.OperationsLive
          live "/operations/:operation", WardrikWeb.OperationLive

          for page <- WardrikWeb.SettingPage.all() do
            live "/#{page.path}",
                 if(page.key == :connections,
                   do: WardrikWeb.ConnectionsLive,
                   else: WardrikWeb.SettingsLive
                 ),
                 page.key
          end

          for page <- WardrikWeb.Dashboard.pages(dashboard),
              do: live("/x/#{page.path}", page.live)
        end
      end
    end
  end

  @doc false
  @spec __dashboard__(String.t(), keyword()) :: {atom(), [term()], WardrikWeb.Dashboard.t()}
  def __dashboard__(prefix, opts) do
    opts = NimbleOptions.validate!(opts, @schema)
    {name, opts} = Keyword.pop!(opts, :live_session)
    {hooks, opts} = Keyword.pop!(opts, :on_mount)
    opts = Keyword.update!(opts, :settings, &Map.new/1)
    {name, hooks, struct!(WardrikWeb.Dashboard, [prefix: prefix] ++ opts)}
  end
end
