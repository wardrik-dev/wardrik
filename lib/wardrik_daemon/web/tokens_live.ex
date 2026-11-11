defmodule WardrikDaemon.Web.TokensLive do
  @moduledoc false
  use Phoenix.LiveView

  import WardrikWeb.Components

  alias WardrikDaemon.Allowed
  alias WardrikDaemon.Tokens
  alias WardrikWeb.Form

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Tokens",
        daemon: socket.endpoint.config(:daemon),
        schema: WardrikDaemon.HTTP.schema("token_input"),
        tokens: [],
        params: %{},
        created: nil,
        error: nil
      )

    {:ok, load(socket)}
  end

  @impl true
  def handle_event("change", %{"input" => params}, socket),
    do: {:noreply, assign(socket, :params, params)}

  def handle_event("create", %{"input" => params}, socket) do
    %{daemon: daemon, scope: scope, schema: schema} = socket.assigns

    with {:ok, input} <- read(schema, params),
         {:ok, input} <- WardrikDaemon.HTTP.checked("token_input", input),
         :ok <- Allowed.authorized(scope, "token.create", {:token, input["subject"]}),
         {:ok, created} <- Tokens.issue(daemon.store, input) do
      {:noreply, socket |> assign(params: %{}, created: created) |> load()}
    else
      {:error, %{message: message}} -> {:noreply, put_flash(socket, :error, message)}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    %{daemon: daemon, scope: scope} = socket.assigns

    case Allowed.authorized(scope, "token.delete", {:token, id}) do
      :ok ->
        :ok = Tokens.revoke(daemon.store, id)
        {:noreply, socket |> put_flash(:info, "Revoked the token.") |> load()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("dismiss", _params, socket), do: {:noreply, assign(socket, :created, nil)}

  def handle_event(event, value, socket),
    do: {:noreply, assign(socket, :params, Form.handle(event, value, socket.assigns.params))}

  defp read(schema, params) do
    case Form.read(schema, params) do
      :none -> {:error, "Enter a name and who the token acts as."}
      read -> read
    end
  end

  defp load(socket) do
    %{daemon: daemon, scope: scope} = socket.assigns

    case Allowed.authorized(scope, "token.read", {:token, "*"}) do
      :ok ->
        assign(socket, tokens: Enum.map(Tokens.list(daemon.store), &Tokens.json/1), error: nil)

      {:error, error} ->
        assign(socket, tokens: [], error: error.message)
    end
  end

  defp expired?(%{"expires" => expires}) do
    {:ok, at, _offset} = DateTime.from_iso8601(expires)
    DateTime.before?(at, DateTime.utc_now())
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.head title="Tokens" lead="API tokens for the CLI, the SDKs and the dashboard. A token's secret is shown once, when you create it." />
    <div :if={@error} class="flash error" role="alert">{@error}</div>

    <div :if={@created} class="card created">
      <header>
        New token: {@created["name"]}
        <button class="btn small" phx-click="dismiss">Done</button>
      </header>
      <div class="body">
        <p class="sub" style="margin-top: 0">Copy the secret now. It isn't shown again.</p>
        <pre class="json">{@created["secret"]}</pre>
      </div>
    </div>

    <div :if={!@error} class="card">
      <table class="list stack">
        <thead><tr><th>Name</th><th>Acts as</th><th>Expires</th><th></th></tr></thead>
        <tbody>
          <tr :for={token <- Enum.sort_by(@tokens, & &1["expires"], :desc)}>
            <td class="lead">
              <b>{token["name"]}</b>
              <div class="sub"><code>{token["id"]}</code></div>
            </td>
            <td data-label="Acts as">
              <code>{token["subject"]}</code>
              <div :if={token["groups"] != []} class="sub">{Enum.join(token["groups"], ", ")}</div>
            </td>
            <td data-label="Expires" class={["when", expired?(token) && "bad"]} title={token["expires"]}>
              {if expired?(token), do: "expired", else: ago(token["expires"])}
            </td>
            <td class="num">
              <button
                class="btn small danger"
                phx-click="revoke"
                phx-value-id={token["id"]}
                data-confirm={"Revoke #{token["name"]}? It stops working at once."}
              >
                Revoke
              </button>
            </td>
          </tr>
        </tbody>
      </table>
      <div :if={@tokens == []} class="empty">No tokens.</div>
    </div>

    <form :if={!@error} id="token-form" class="card" phx-change="change" phx-submit="create">
      <header>Create a token</header>
      <div class="body">
        <Form.fields schema={@schema} params={@params} />
        <button class="btn primary">Create token</button>
      </div>
    </form>
    """
  end
end
