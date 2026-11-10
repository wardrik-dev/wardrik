defmodule WardrikWeb.Layouts do
  @moduledoc false
  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias WardrikWeb.Dashboard

  @doc "The HTML document: assets, CSRF token and socket path."
  def root(assigns) do
    {js, css} = WardrikWeb.Assets.names()
    assigns = assign(assigns, js: js, css: css)

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <meta name="wardrik-socket" content={@dashboard.socket_path} />
        <title>{assigns[:page_title] || "Wardrik"}</title>
        <link rel="stylesheet" href={WardrikWeb.path(@dashboard, ["assets", @css])} />
        <script defer src={WardrikWeb.path(@dashboard, ["assets", @js])}>
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @doc "The layout of each page: navigation and flash messages."
  def app(assigns) do
    assigns = assign(assigns, :pages, Dashboard.pages(assigns.dashboard))

    ~H"""
    <div class="shell" id="wardrik-shell" phx-window-keydown={close_menu()} phx-key="Escape">
      <header class="topbar">
        <button
          class="menu"
          type="button"
          aria-label="Menu"
          aria-controls="wardrik-nav"
          aria-expanded="false"
          phx-click={open_menu()}
        >
          <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true">
            <path
              d="M4 7h16M4 12h16M4 17h16"
              stroke="currentColor"
              stroke-width="1.75"
              stroke-linecap="round"
            />
          </svg>
        </button>
        <.link class="wordmark" navigate={WardrikWeb.path(@dashboard, [])}>
          <span>Wardrik<span class="dot">.</span></span><small>operators</small>
        </.link>
      </header>
      <div class="scrim" phx-click={close_menu()} aria-hidden="true"></div>
      <nav class="side" id="wardrik-nav" aria-label="Dashboard" phx-click={close_menu()}>
        <.link class="wordmark" navigate={WardrikWeb.path(@dashboard, [])}>
          <span>Wardrik<span class="dot">.</span></span><small>operators</small>
        </.link>
        <.nav dashboard={@dashboard} here={@here} to={[]} label="Agents" also={["agents"]} />
        <.nav dashboard={@dashboard} here={@here} to={["approvals"]} label="Approvals" />
        <.nav dashboard={@dashboard} here={@here} to={["audit"]} label="Audit" />
        <.nav dashboard={@dashboard} here={@here} to={["nodes"]} label="Nodes" />
        <.nav dashboard={@dashboard} here={@here} to={["operations"]} label="Operations" />
        <div :if={@pages != []} class="group">More</div>
        <.nav
          :for={page <- @pages}
          dashboard={@dashboard}
          here={@here}
          to={["x", page.path]}
          label={page.label}
        />
      </nav>
      <main class="main">
        <div
          :if={msg = Phoenix.Flash.get(@flash, :info)}
          class="flash info"
          role="status"
          phx-click="lv:clear-flash"
          phx-value-key="info"
          title="Dismiss"
        >
          {msg}<span class="close" aria-hidden="true">×</span>
        </div>
        <div
          :if={msg = Phoenix.Flash.get(@flash, :error)}
          class="flash error"
          role="alert"
          phx-click="lv:clear-flash"
          phx-value-key="error"
          title="Dismiss"
        >
          {msg}<span class="close" aria-hidden="true">×</span>
        </div>
        {@inner_content}
      </main>
    </div>
    """
  end

  # The menu slides in only on narrow screens. On wide screens the attribute has no effect.
  defp open_menu,
    do:
      JS.set_attribute({"data-menu", "open"}, to: "#wardrik-shell")
      |> JS.set_attribute({"aria-expanded", "true"}, to: "#wardrik-shell .menu")
      |> JS.focus_first(to: "#wardrik-nav")

  defp close_menu,
    do:
      JS.remove_attribute("data-menu", to: "#wardrik-shell")
      |> JS.set_attribute({"aria-expanded", "false"}, to: "#wardrik-shell .menu")

  attr :dashboard, Dashboard, required: true
  attr :here, :string, required: true
  attr :to, :list, required: true
  attr :label, :string, required: true
  attr :also, :list, default: []

  defp nav(assigns) do
    path = WardrikWeb.path(assigns.dashboard, assigns.to)
    also = Enum.map(assigns.also, &WardrikWeb.path(assigns.dashboard, [&1]))

    on =
      assigns.here == path or
        (assigns.to != [] and String.starts_with?(assigns.here, path <> "/")) or
        Enum.any?(also, &String.starts_with?(assigns.here, &1 <> "/"))

    assigns = assign(assigns, path: path, on: on)

    ~H"""
    <.link class={["nav", @on && "on"]} navigate={@path} aria-current={@on && "page"}>
      {@label}
    </.link>
    """
  end
end
