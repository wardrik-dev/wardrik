defmodule WardrikWeb.Layouts do
  @moduledoc false
  use Phoenix.Component

  alias WardrikWeb.Dashboard

  @doc "The page around the dashboard: its assets, CSRF token and socket path."
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

  @doc "The frame around each page: navigation and flash."
  def app(assigns) do
    assigns = assign(assigns, :pages, Dashboard.pages(assigns.dashboard))

    ~H"""
    <div class="shell">
      <nav class="side" aria-label="Dashboard">
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
        <div :if={msg = Phoenix.Flash.get(@flash, :info)} class="flash info" role="status">{msg}</div>
        <div :if={msg = Phoenix.Flash.get(@flash, :error)} class="flash error" role="alert">
          {msg}
        </div>
        {@inner_content}
      </main>
    </div>
    """
  end

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
