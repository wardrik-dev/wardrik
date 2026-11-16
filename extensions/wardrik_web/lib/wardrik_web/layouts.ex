defmodule WardrikWeb.Layouts do
  @moduledoc false
  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias WardrikWeb.Dashboard

  @doc "The HTML document: assets, CSRF token and socket path."
  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
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

  @doc "The layout of each dashboard page: navigation and flash messages."
  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    assigns = assign(assigns, :pages, Dashboard.pages(assigns.dashboard))

    ~H"""
    <.shell dashboard={@dashboard} flash={@flash} label="operators" home={[]} content={@inner_content}>
      <.nav dashboard={@dashboard} here={@here} to={["chat"]} label="Chat" />
      <.nav dashboard={@dashboard} here={@here} to={[]} label="Agents" also={["agents"]} />
      <.nav dashboard={@dashboard} here={@here} to={["approvals"]} label="Approvals" />
      <.nav dashboard={@dashboard} here={@here} to={["audit"]} label="Audit" />
      <.nav dashboard={@dashboard} here={@here} to={["nodes"]} label="Nodes" />
      <.nav dashboard={@dashboard} here={@here} to={["operations"]} label="Operations" />
      <div class="group">Settings</div>
      <.nav
        :for={page <- WardrikWeb.SettingPage.all()}
        dashboard={@dashboard}
        here={@here}
        to={[page.path]}
        label={page.label}
        off={!Map.has_key?(@dashboard.settings, page.key)}
      />
      <div :if={@pages != []} class="group">More</div>
      <.nav
        :for={page <- @pages}
        dashboard={@dashboard}
        here={@here}
        to={["x", page.path]}
        label={page.label}
      />
      <:foot>
        <a href="https://wardrik.dev" target="_blank" rel="noopener">Documentation ↗</a>
      </:foot>
    </.shell>
    """
  end

  @doc """
  The layout of the chat page: the agents to chat with, and the open agent's conversations.

  It reads `@chats`, `@agent` and `@conversation` from the page.
  """
  @spec chat(map()) :: Phoenix.LiveView.Rendered.t()
  def chat(assigns) do
    ~H"""
    <.shell
      dashboard={@dashboard}
      flash={@flash}
      label="chat"
      home={["chat"]}
      content={@inner_content}
    >
      <button :if={@agent} class="btn new" type="button" phx-click="new">New chat</button>
      <div class="group">Agents</div>
      <%= for chat <- @chats do %>
        <.link
          class={["nav", chat.id == @agent && !@conversation && "on"]}
          navigate={WardrikWeb.path(@dashboard, ["chat", chat.id])}
          aria-current={chat.id == @agent && !@conversation && "page"}
          title={chat.id}
        >
          {chat.name}
        </.link>
        <.link
          :for={conversation <- chat.conversations}
          :if={chat.id == @agent}
          class={["nav", "sub", conversation == @conversation && "on"]}
          navigate={WardrikWeb.path(@dashboard, ["chat", chat.id], %{"conversation" => conversation})}
          aria-current={conversation == @conversation && "page"}
          title={conversation}
        >
          {chat_label(conversation)}
        </.link>
      <% end %>
      <:foot>
        <.link navigate={WardrikWeb.path(@dashboard, [])}>Dashboard</.link>
        <a href="https://wardrik.dev" target="_blank" rel="noopener">Documentation ↗</a>
      </:foot>
    </.shell>
    """
  end

  # The chat page names a chat it starts by when, as "web 2026-11-16 06:38:01 k3fq".
  defp chat_label("web " <> <<stamp::binary-size(16), _rest::binary>> = conversation) do
    case NaiveDateTime.from_iso8601(stamp <> ":00") do
      {:ok, _at} -> stamp
      {:error, _not_ours} -> conversation
    end
  end

  defp chat_label(conversation), do: conversation

  attr :dashboard, Dashboard, required: true
  attr :flash, :map, required: true
  attr :label, :string, required: true
  attr :home, :list, required: true
  attr :content, :any, required: true
  slot :inner_block, required: true
  slot :foot, required: true

  defp shell(assigns) do
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
        <.wordmark dashboard={@dashboard} home={@home} label={@label} />
      </header>
      <div class="scrim" phx-click={close_menu()} aria-hidden="true"></div>
      <nav class="side" id="wardrik-nav" aria-label="Dashboard" phx-click={close_menu()}>
        <.wordmark dashboard={@dashboard} home={@home} label={@label} />
        {render_slot(@inner_block)}
        <div class="foot">{render_slot(@foot)}</div>
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
        {@content}
      </main>
    </div>
    """
  end

  attr :dashboard, Dashboard, required: true
  attr :home, :list, required: true
  attr :label, :string, required: true

  defp wordmark(assigns) do
    ~H"""
    <.link class="wordmark" navigate={WardrikWeb.path(@dashboard, @home)}>
      <span>Wardrik<span class="dot">.</span></span><small>{@label}</small>
    </.link>
    """
  end

  # The menu slides in only on narrow screens. On wide screens the attribute has no effect.
  defp open_menu do
    %JS{}
    |> JS.set_attribute({"data-menu", "open"}, to: "#wardrik-shell")
    |> JS.set_attribute({"aria-expanded", "true"}, to: "#wardrik-shell .menu")
    |> JS.focus_first(to: "#wardrik-nav")
  end

  defp close_menu do
    %JS{}
    |> JS.remove_attribute("data-menu", to: "#wardrik-shell")
    |> JS.set_attribute({"aria-expanded", "false"}, to: "#wardrik-shell .menu")
  end

  attr :dashboard, Dashboard, required: true
  attr :here, :string, required: true
  attr :to, :list, required: true
  attr :label, :string, required: true
  attr :also, :list, default: []
  attr :off, :boolean, default: false

  defp nav(assigns) do
    path = WardrikWeb.path(assigns.dashboard, assigns.to)
    also = Enum.map(assigns.also, &WardrikWeb.path(assigns.dashboard, [&1]))

    on =
      assigns.here == path or
        (assigns.to != [] and String.starts_with?(assigns.here, path <> "/")) or
        Enum.any?(also, &String.starts_with?(assigns.here, &1 <> "/"))

    assigns = assign(assigns, path: path, on: on)

    ~H"""
    <.link class={["nav", @on && "on", @off && "off"]} navigate={@path} aria-current={@on && "page"}>
      {@label}<span :if={@off} class="tag">off</span>
    </.link>
    """
  end
end
