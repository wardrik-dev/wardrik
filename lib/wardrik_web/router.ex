defmodule WardrikWeb.Router do
  @moduledoc """
  Mounts the dashboard in a Phoenix router.

      import WardrikWeb.Router

      scope "/" do
        pipe_through :browser
        wardrik_dashboard "/wardrik", resolver: {MyAppWeb.WardrikResolver, []}
      end

    * The pipeline must fetch the session and protect from forgery, as Phoenix's `:browser`
      pipeline does.
    * The endpoint must serve LiveView's socket, with the session:
      `socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]`.
  """

  @schema NimbleOptions.new!(
            resolver: [
              type: {:tuple, [:atom, :any]},
              required: true,
              doc: "`{module, opts}`, the `WardrikWeb.Resolver` that gives each person's scope."
            ],
            on_mount: [
              type: {:list, :any},
              default: [],
              doc:
                "Your own `on_mount` hooks, run before the resolver, such as the one that signs people in."
            ],
            extensions: [
              type: {:list, :atom},
              default: [],
              doc: "The `WardrikWeb.Extension` modules to show."
            ],
            socket_path: [
              type: :string,
              default: "/live",
              doc: "The path of the endpoint's LiveView socket."
            ],
            sign_in: [
              type: :string,
              default: "/",
              doc: "Where a person the resolver refuses is sent."
            ],
            live_session: [
              type: :atom,
              default: :wardrik_web,
              doc: "The live session's name. Set it to mount two dashboards in one router."
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
        WardrikWeb.Router.__dashboard__(Phoenix.Router.scoped_path(__MODULE__, path), opts)

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

          for page <- WardrikWeb.Dashboard.pages(dashboard),
              do: live("/x/#{page.path}", page.live)
        end
      end
    end
  end

  @doc false
  def __dashboard__(prefix, opts) do
    opts = NimbleOptions.validate!(opts, @schema)
    {name, opts} = Keyword.pop!(opts, :live_session)
    {hooks, opts} = Keyword.pop!(opts, :on_mount)
    {name, hooks, struct!(WardrikWeb.Dashboard, [prefix: prefix] ++ opts)}
  end
end
