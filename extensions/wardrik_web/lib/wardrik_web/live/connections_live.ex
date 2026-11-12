defmodule WardrikWeb.ConnectionsLive do
  @moduledoc false
  use Phoenix.LiveView

  import WardrikWeb.Components

  alias WardrikWeb.SettingPage

  @every 5_000

  @impl true
  def mount(_params, _session, socket) do
    page = SettingPage.fetch!(:connections)
    source = socket.assigns.dashboard.settings[:connections]
    if connected?(socket) and source, do: :timer.send_interval(@every, :refresh)

    socket =
      assign(socket,
        page: page,
        page_title: page.label,
        source: source,
        connections: [],
        signing_in: nil,
        error: nil
      )

    {:ok, if(source, do: load(socket), else: socket)}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("connect", %{"provider" => provider}, socket) do
    %{source: {module, opts}, scope: scope} = socket.assigns

    case module.connect(scope, provider, opts) do
      {:ok, %{"connected" => true}} ->
        {:noreply, socket |> put_flash(:info, "#{provider} is already connected.") |> load()}

      {:ok, connecting} ->
        {:noreply, socket |> assign(:signing_in, connecting) |> load()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, message(error))}
    end
  end

  def handle_event("pair", %{"provider" => provider, "code" => code}, socket) do
    %{source: {module, opts}, scope: scope} = socket.assigns

    case module.pair(scope, provider, String.trim(code), opts) do
      :ok ->
        {:noreply,
         socket
         |> assign(:signing_in, nil)
         |> put_flash(:info, "Connected #{provider}.")
         |> load()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, message(error))}
    end
  end

  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, :signing_in, nil)}

  def handle_event("disconnect", %{"provider" => provider}, socket) do
    %{source: {module, opts}, scope: scope} = socket.assigns

    case module.disconnect(scope, provider, opts) do
      :ok -> {:noreply, socket |> put_flash(:info, "Disconnected #{provider}.") |> load()}
      {:error, error} -> {:noreply, put_flash(socket, :error, message(error))}
    end
  end

  defp load(%{assigns: %{source: {module, opts}, scope: scope}} = socket) do
    case module.list(scope, opts) do
      {:ok, connections} -> socket |> assign(connections: connections, error: nil) |> finished()
      {:error, error} -> assign(socket, connections: [], error: message(error))
    end
  end

  # A sign-in with a code finishes on the service's side. Close the card once it's connected.
  defp finished(%{assigns: %{signing_in: %{"provider" => provider}}} = socket) do
    if Enum.any?(socket.assigns.connections, &(&1["provider"] == provider and &1["connected"])),
      do: assign(socket, :signing_in, nil),
      else: socket
  end

  defp finished(socket), do: socket

  defp state(%{"connected" => true}), do: "ok"
  defp state(%{"signing_in" => true}), do: "waiting"
  defp state(_connection), do: "asleep"

  defp label(%{"connected" => true}), do: "connected"
  defp label(%{"signing_in" => true}), do: "signing in"
  defp label(_connection), do: "not connected"

  @impl true
  def render(%{source: nil} = assigns) do
    ~H"""
    <.head title={@page.label} lead={@page.lead} />
    <.off key={@page.key} behaviour={@page.behaviour} />
    """
  end

  def render(assigns) do
    ~H"""
    <.head title={@page.label} lead={@page.lead} />
    <div :if={@error} class="flash error" role="alert">{@error}</div>

    <div :if={@signing_in} class="card" id="signing-in">
      <header>
        Connect {@signing_in["provider"]}
        <button class="btn small" phx-click="cancel">Cancel</button>
      </header>
      <div class="body">
        <%= if code = get_in(@signing_in, ["authorization", "code"]) do %>
          <p>
            Open the sign-in page and enter the code <code>{code}</code>. This page updates when you
            finish.
          </p>
          <a
            class="btn primary"
            href={@signing_in["authorization"]["url"]}
            target="_blank"
            rel="noopener"
          >
            Open the sign-in page ↗
          </a>
        <% else %>
          <p>
            Open the sign-in page and sign in. The page then shows a code. Enter the code here to
            finish.
          </p>
          <a
            class="btn primary"
            href={@signing_in["authorization"]["url"]}
            target="_blank"
            rel="noopener"
          >
            Open the sign-in page ↗
          </a>
          <form id="pair-form" class="filters" phx-submit="pair" style="margin-top: 14px">
            <input type="hidden" name="provider" value={@signing_in["provider"]} />
            <input
              type="text"
              name="code"
              placeholder="XXXX-XXXX"
              aria-label="Code"
              autocomplete="off"
            />
            <button class="btn primary">Finish</button>
          </form>
        <% end %>
      </div>
    </div>

    <div :if={!@error} class="card">
      <table class="list stack">
        <thead>
          <tr>
            <th>Account</th><th>Status</th><th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={connection <- @connections}>
            <td class="lead"><code>{connection["provider"]}</code></td>
            <td data-label="Status">
              <span class={["pill", state(connection)]}>{label(connection)}</span>
            </td>
            <td class="num">
              <button
                :if={!connection["connected"]}
                class="btn small primary"
                phx-click="connect"
                phx-value-provider={connection["provider"]}
              >
                Connect
              </button>
              <button
                :if={connection["connected"]}
                class="btn small danger"
                phx-click="disconnect"
                phx-value-provider={connection["provider"]}
                data-confirm={"Disconnect #{connection["provider"]}? Agents can no longer call it as you."}
              >
                Disconnect
              </button>
            </td>
          </tr>
        </tbody>
      </table>
      <div :if={@connections == []} class="empty">
        There are no accounts to connect. Add an OAuth app first.
      </div>
    </div>
    """
  end
end
