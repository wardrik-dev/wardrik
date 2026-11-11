defmodule WardrikDaemon.Web.CeilingsLive do
  @moduledoc false
  use Phoenix.LiveView

  import WardrikWeb.Components

  alias WardrikDaemon.Allowed
  alias WardrikDaemon.Ceiling

  @impl true
  def mount(_params, _session, socket) do
    daemon = socket.endpoint.config(:daemon)
    orgs = Enum.uniq([daemon.config.org | Enum.sort(Map.keys(daemon.config.orgs))])

    {:ok,
     assign(socket,
       page_title: "Ceilings",
       daemon: daemon,
       owners: orgs,
       ceilings: [],
       error: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket),
    do:
      {:noreply,
       socket |> assign(:owner, params["owner"] || socket.assigns.daemon.config.org) |> load()}

  @impl true
  def handle_event("owner", %{"owner" => owner}, socket),
    do:
      {:noreply,
       push_patch(socket,
         to: WardrikWeb.path(socket.assigns.dashboard, ["x", "ceilings"], %{"owner" => owner})
       )}

  defp load(socket) do
    %{daemon: daemon, owner: owner, scope: scope} = socket.assigns

    with :ok <- Allowed.owned(daemon, scope, owner, {"ceiling.read", :ceiling}),
         {:ok, ceilings} <- Ceiling.list(daemon, owner) do
      assign(socket, ceilings: ceilings, error: nil)
    else
      {:error, error} -> assign(socket, ceilings: [], error: error.message)
    end
  end

  # A ceiling limits dollars, tokens or both. Show each limit it sets.
  defp limits(ceiling) do
    for {unit, limit} <- ceiling["limit"],
        do: {unit, ceiling["spent"][unit] || 0, limit + (ceiling["granted"][unit] || 0)}
  end

  defp amount("usd", value), do: usd(value)
  defp amount("tokens", value), do: tokens(value) <> " tokens"

  defp period("total"), do: "In total"
  defp period(per), do: "Per #{per}"

  defp exhausted("ask"), do: "Ask for approval"
  defp exhausted("deny"), do: "Refuse model calls"
  defp exhausted("continue"), do: "Keep running"

  @impl true
  def render(assigns) do
    ~H"""
    <.head
      title="Ceilings"
      lead="Spending limits shared by all of an org's agents. They come from the org's policy in config.yaml."
    />
    <.owner_picker owners={@owners} owner={@owner} />
    <div :if={@error} class="flash error" role="alert">{@error}</div>

    <div :if={!@error and @ceilings == []} class="card empty">
      {@owner} has no ceilings. To add one, set a budget in the org's policy.
    </div>

    <div :for={ceiling <- @ceilings} class="card">
      <header>
        <code>{ceiling["ceiling"]}</code>
        <span class="node-meta">
          {period(ceiling["per"])}<span :if={ceiling["starts_over"]}> · starts over {ceiling["starts_over"]}</span>
        </span>
      </header>
      <div class="body">
        <div class="meters">
          <.meter
            :for={{unit, spent, limit} <- limits(ceiling)}
            label={if unit == "usd", do: "Spent", else: "Tokens"}
            count={spent}
            limit={limit}
            format={&amount(unit, &1)}
          />
        </div>
        <dl class="facts" style="margin-top: 14px">
          <dt>At the limit</dt><dd>{exhausted(ceiling["on_exhausted"])}</dd>
          <dt :if={ceiling["granted"] != %{}}>Granted</dt>
          <dd :if={ceiling["granted"] != %{}}>
            {Enum.map_join(ceiling["granted"], ", ", fn {unit, value} -> amount(unit, value) end)} more, approved this period
          </dd>
        </dl>
      </div>
    </div>
    """
  end
end
