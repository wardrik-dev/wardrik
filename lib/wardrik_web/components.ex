defmodule WardrikWeb.Components do
  @moduledoc """
  Components and formatting helpers for dashboard pages.

  Use them in extension pages to match the look of the dashboard.

      import WardrikWeb.Components

      <.head title="Fleet" lead="Runs and cost for each agent." />
      <.status value="parked" />
  """

  use Phoenix.Component

  alias WardrikWeb.Dashboard

  @doc "A page heading, with an optional breadcrumb, badge and action buttons."
  attr :title, :string, required: true
  attr :lead, :string, default: nil
  slot :crumb
  slot :badge
  slot :actions

  def head(assigns) do
    ~H"""
    <header class="head">
      <div class="title">
        <div :if={@crumb != []} class="crumb">{render_slot(@crumb)}</div>
        <h1>{@title} <span :if={@badge != []} class="badge">{render_slot(@badge)}</span></h1>
        <p :if={@lead}>{@lead}</p>
      </div>
      <div :if={@actions != []} class="actions">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc "A status label for an agent or a run."
  attr :value, :string, required: true

  def status(assigns) do
    ~H"""
    <span class={["pill", @value]}>{@value}</span>
    """
  end

  @doc "Shows whether the page is receiving live updates."
  attr :live, :boolean, required: true
  attr :stopped, :string, default: nil

  def live(assigns) do
    ~H"""
    <span class={["live", !@live && "off"]} title={@stopped}>
      {if @live, do: "Live", else: "Not live"}
    </span>
    """
  end

  @doc "A JSON value, pretty-printed."
  attr :value, :any, required: true

  def json(assigns) do
    ~H"""
    <pre class="json">{Jason.encode!(@value, pretty: true)}</pre>
    """
  end

  @doc """
  A list of events. Each row shows the time, the event type and a short preview. Click a row to
  see the full event.

  Set `:agent` to show a link to each event's agent. The link needs `:dashboard`.
  """
  attr :events, :list, required: true
  attr :empty, :string, default: "No events."
  attr :dashboard, :any, default: nil
  attr :agent, :boolean, default: false

  def events(assigns) do
    ~H"""
    <div class="rows">
      <div :if={@events == []} class="card empty">{@empty}</div>
      <details :for={event <- @events} class="row" id={"event-" <> (event["id"] || "")}>
        <summary>
          <span class="when" title={event["time"]}>{ago(event["time"])}</span>
          <code class="type">{String.replace_prefix(event["type"] || "", "wardrik.", "")}</code>
          <.link
            :if={@agent && @dashboard && event["agent"]}
            class="agent"
            navigate={WardrikWeb.path(@dashboard, ["agents", event["agent"]])}
          >
            {event["agent"]}
          </.link>
          <span class="preview">{preview(event["data"], event["agent"])}</span>
        </summary>
        <div class="row-body"><.json value={event} /></div>
      </details>
    </div>
    """
  end

  @doc """
  Shows a flash message from a LiveComponent.

  LiveView only shows a component's flash when the component navigates. This function sends the
  message to the parent LiveView, which shows it.
  """
  @spec flash(Phoenix.LiveView.Socket.t(), :info | :error, String.t()) ::
          Phoenix.LiveView.Socket.t()
  def flash(socket, kind, message) do
    send(self(), {__MODULE__, :flash, kind, message})
    socket
  end

  @doc "Describes what an agent is doing, given the latest event of its current run."
  @spec doing_text(map()) :: String.t()
  def doing_text(%{"type" => "wardrik.run.interrupted"} = item) do
    case length(item["interrupts"] || []) do
      1 -> "Waiting for approval of 1 tool call"
      n -> "Waiting for approval of #{n} tool calls"
    end
  end

  def doing_text(%{"type" => "wardrik.message.retrying"} = item),
    do: "Retrying the model call#{attempt(item)}"

  def doing_text(%{"type" => "wardrik.tool_call.retrying", "tool" => %{"name" => name}} = item),
    do: "Retrying #{name}#{attempt(item)}"

  def doing_text(%{"type" => "wardrik.tool_call.started", "tool" => %{"name" => name}}),
    do: "Calling #{name}"

  def doing_text(%{"type" => "wardrik.tool_call.completed", "tool" => %{"name" => name}}),
    do: "Finished #{name}"

  def doing_text(%{"type" => "wardrik.tool_call.denied", "tool" => %{"name" => name}}),
    do: "#{name} was denied"

  def doing_text(%{"type" => "wardrik.step.started", "step" => %{"name" => name}}),
    do: "Running step #{name}"

  def doing_text(%{"type" => "wardrik.message.started"}), do: "Generating a response"
  def doing_text(%{"type" => "wardrik.run.resumed"}), do: "Resuming a run"
  def doing_text(%{"type" => "wardrik.run.started"}), do: "Starting a run"
  def doing_text(%{"type" => type}), do: String.replace_prefix(type, "wardrik.", "")

  defp attempt(%{"attempt" => attempt, "attempts" => attempts}),
    do: " (attempt #{attempt} of #{attempts})"

  defp attempt(_item), do: ""

  @doc "A one-line preview of event data. It shows the first three plain values, except `except`."
  @spec preview(term(), String.t() | nil) :: String.t()
  def preview(data, except \\ nil) do
    data
    |> leaves()
    |> Enum.reject(&(&1 == except))
    |> Enum.take(3)
    |> Enum.join(" · ")
    |> String.slice(0, 140)
  end

  defp leaves(%{} = map),
    do: map |> Enum.sort_by(&elem(&1, 0)) |> Enum.flat_map(fn {_key, value} -> leaves(value) end)

  defp leaves(list) when is_list(list), do: Enum.flat_map(list, &leaves/1)
  defp leaves(value) when is_binary(value) and value != "", do: [value]
  defp leaves(value) when is_number(value) or is_boolean(value), do: [to_string(value)]
  defp leaves(_value), do: []

  @doc "Renders the extensions' panels for `slot`, passing them `assigns`."
  attr :dashboard, Dashboard, required: true
  attr :slot, :atom, required: true
  attr :scope, :any, required: true
  attr :assigns, :map, default: %{}

  def panels(assigns) do
    ~H"""
    <.live_component
      :for={module <- Dashboard.panels(@dashboard, @slot)}
      module={module}
      id={"#{@slot}-#{inspect(module)}"}
      dashboard={@dashboard}
      scope={@scope}
      {@assigns}
    />
    """
  end

  @doc "A cost in dollars."
  @spec usd(number() | nil) :: String.t()
  def usd(nil), do: "—"
  def usd(0), do: "$0"
  def usd(+0.0), do: "$0"

  def usd(dollars) when dollars < 0.01,
    do: "$" <> :erlang.float_to_binary(dollars / 1, decimals: 4)

  def usd(dollars), do: "$" <> :erlang.float_to_binary(dollars / 1, decimals: 2)

  @doc "A cost given in micro-USD, formatted in dollars."
  @spec micro_usd(non_neg_integer() | nil) :: String.t()
  def micro_usd(nil), do: "—"
  def micro_usd(micro), do: usd(micro / 1.0e6)

  @doc "A number with thousands separators."
  @spec number(integer() | nil) :: String.t()
  def number(nil), do: "—"

  def number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  @doc "A token count, abbreviated above a thousand: `8.4k`, `1.2M`."
  @spec tokens(integer() | nil) :: String.t()
  def tokens(nil), do: "—"
  def tokens(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  def tokens(n) when n >= 1000, do: "#{Float.round(n / 1000, 1)}k"
  def tokens(n), do: number(n)

  @doc "A duration in milliseconds, shown in its two largest units: `850 ms`, `4.2s`, `3m 10s`, `6d 20h`."
  @spec took(non_neg_integer() | nil) :: String.t()
  def took(nil), do: "—"
  def took(ms) when ms < 1000, do: "#{ms} ms"
  def took(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  def took(ms), do: two(div(ms, 1000), [{86_400, "d"}, {3600, "h"}, {60, "m"}, {1, "s"}])

  defp two(s, [{size, _unit}, {next, next_unit} | rest]) when s < size,
    do: two(s, [{next, next_unit} | rest])

  defp two(s, [{size, unit}, {next, next_unit} | _rest]) do
    case div(rem(s, size), next) do
      0 -> "#{div(s, size)}#{unit}"
      more -> "#{div(s, size)}#{unit} #{more}#{next_unit}"
    end
  end

  @doc "An ISO 8601 time, shown as time ago, for example `5m ago`."
  @spec ago(String.t() | nil, DateTime.t()) :: String.t()
  def ago(time, now \\ DateTime.utc_now())
  def ago(nil, _now), do: "—"

  def ago(time, now) do
    case DateTime.from_iso8601(time) do
      {:ok, at, _offset} -> since(DateTime.diff(now, at))
      {:error, _reason} -> time
    end
  end

  defp since(seconds) when seconds < 0, do: "in " <> span(-seconds)
  defp since(seconds) when seconds < 5, do: "just now"
  defp since(seconds), do: span(seconds) <> " ago"

  defp span(s) when s < 60, do: "#{s}s"
  defp span(s) when s < 3600, do: "#{div(s, 60)}m"
  defp span(s) when s < 86_400, do: "#{div(s, 3600)}h"
  defp span(s), do: "#{div(s, 86_400)}d"
end
