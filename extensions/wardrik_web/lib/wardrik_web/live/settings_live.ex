defmodule WardrikWeb.SettingsLive do
  @moduledoc false
  use Phoenix.LiveView

  import WardrikWeb.Components

  alias WardrikWeb.Form
  alias WardrikWeb.SettingPage

  @impl true
  def mount(_params, _session, socket) do
    page = SettingPage.fetch!(socket.assigns.live_action)
    source = socket.assigns.dashboard.settings[page.key]

    socket =
      assign(socket,
        page: page,
        page_title: page.label,
        source: source,
        owners: [],
        owner: nil,
        items: [],
        params: %{},
        added: nil,
        error: nil
      )

    {:ok, if(source, do: described(socket), else: socket)}
  end

  defp described(%{assigns: %{source: {module, opts}, scope: scope}} = socket) do
    schema = module.schema(opts)

    common =
      if Code.ensure_loaded?(module) and function_exported?(module, :common, 1),
        do: module.common(opts),
        else: schema["required"] || []

    assign(socket,
      owners: module.owners(scope, opts),
      columns: module.columns(opts),
      schema: schema,
      common: common
    )
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{source: nil}} = socket), do: {:noreply, socket}

  def handle_params(params, _uri, socket) do
    owner = params["owner"] || List.first(socket.assigns.owners)
    {:noreply, load(assign(socket, :owner, owner))}
  end

  @impl true
  def handle_event("owner", %{"owner" => owner}, socket) do
    to =
      WardrikWeb.path(socket.assigns.dashboard, [socket.assigns.page.path], %{"owner" => owner})

    {:noreply, push_patch(socket, to: to)}
  end

  def handle_event("change", %{"input" => params}, socket),
    do: {:noreply, assign(socket, :params, params)}

  def handle_event("dismiss", _params, socket), do: {:noreply, assign(socket, :added, nil)}

  def handle_event("add", %{"input" => params}, socket) do
    %{source: {module, opts}, scope: scope, owner: owner, schema: schema} = socket.assigns

    with {:ok, input} <- read(schema, params, socket.assigns.page.noun),
         {:ok, added} <- module.add(scope, owner, input, opts) do
      {:noreply,
       socket
       |> assign(params: %{}, added: added)
       |> put_flash(:info, "Added #{input["name"]}.")
       |> load()}
    else
      {:error, error} -> {:noreply, put_flash(socket, :error, message(error))}
    end
  end

  def handle_event("remove", %{"name" => name}, socket) do
    %{source: {module, opts}, scope: scope, owner: owner} = socket.assigns

    case module.remove(scope, owner, name, opts) do
      :ok -> {:noreply, load(put_flash(socket, :info, "Removed #{name}."))}
      {:error, error} -> {:noreply, put_flash(socket, :error, message(error))}
    end
  end

  def handle_event(event, value, socket),
    do: {:noreply, assign(socket, :params, Form.handle(event, value, socket.assigns.params))}

  defp read(schema, params, noun) do
    case Form.read(schema, params) do
      :none -> {:error, "Fill in the #{noun}'s required fields."}
      read -> read
    end
  end

  defp load(%{assigns: %{source: {module, opts}, scope: scope, owner: owner}} = socket) do
    case module.list(scope, owner, opts) do
      {:ok, items} -> assign(socket, items: items, error: nil)
      {:error, error} -> assign(socket, items: [], error: message(error))
    end
  end

  defp removable?(item, owner), do: !item["fixed"] and (item["owner"] || owner) == owner

  defp more?(schema, common), do: Enum.any?(Map.keys(schema["properties"]), &(&1 not in common))

  defp cell(value) when is_list(value), do: Enum.join(value, " ")
  defp cell(nil), do: "—"
  defp cell(value) when is_binary(value), do: value
  defp cell(value), do: Jason.encode!(value)

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
    <.owner_picker owners={@owners} owner={@owner} />
    <div :if={@error} class="flash error" role="alert">{@error}</div>

    <div :if={!@error} class="card">
      <table class="list stack">
        <thead>
          <tr>
            <th>Name</th><th :for={{label, _key} <- @columns}>{label}</th><th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={item <- @items}>
            <td class="lead">
              <code>{item["name"]}</code>
              <div :if={item["owner"] && item["owner"] != @owner} class="sub">
                Belongs to {item["owner"]}
              </div>
            </td>
            <td :for={{label, key} <- @columns} data-label={label}>{cell(item[key])}</td>
            <td class="num">
              <span :if={item["fixed"]} class="sub">{item["fixed"]}</span>
              <button
                :if={removable?(item, @owner)}
                class="btn small danger"
                phx-click="remove"
                phx-value-name={item["name"]}
                data-confirm={"Remove #{item["name"]}?"}
              >
                Remove
              </button>
            </td>
          </tr>
        </tbody>
      </table>
      <div :if={@items == []} class="empty">No {@page.noun}s{@owner && " for #{@owner}"}.</div>
    </div>

    <div :if={@added} class="card">
      <header>
        Added <button class="btn small" phx-click="dismiss">Done</button>
      </header>
      <div class="body"><.json value={@added} /></div>
    </div>

    <form :if={!@error} id="settings-form" class="card" phx-change="change" phx-submit="add">
      <header>New {@page.noun}</header>
      <div class="body">
        <Form.fields schema={@schema} params={@params} only={@common} />
        <details :if={more?(@schema, @common)} class="group">
          <summary><b>More settings</b></summary>
          <Form.fields schema={@schema} params={@params} except={@common} />
        </details>
        <button class="btn primary">Add {@page.noun}</button>
      </div>
    </form>
    """
  end
end
