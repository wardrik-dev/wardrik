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

  @doc """
  A menu for choosing an owner, such as an org or a person. Choosing one sends the `"owner"`
  event with `%{"owner" => owner}`.
  """
  attr :owners, :list, required: true
  attr :owner, :string, required: true

  def owner_picker(assigns) do
    ~H"""
    <form :if={length(@owners) > 1} id="owner-picker" class="filters" phx-change="owner">
      <label class="check" for="owner-select">Owner</label>
      <select id="owner-select" name="owner">
        <option :for={owner <- @owners} value={owner} selected={owner == @owner}>{owner}</option>
      </select>
    </form>
    """
  end

  @doc "Says a settings page is off, and how to turn it on."
  attr :key, :atom, required: true
  attr :behaviour, :atom, required: true

  def off(assigns) do
    ~H"""
    <div class="card">
      <header>This page is off</header>
      <div class="body">
        <p>
          To turn it on, implement <code>{inspect(@behaviour)}</code>
          in your app. Then add it to the dashboard in your router:
        </p>
        <pre class="json">{snippet(@key)}</pre>
      </div>
    </div>
    """
  end

  defp snippet(key) do
    """
    wardrik_dashboard "/wardrik",
      resolver: {MyAppWeb.WardrikResolver, []},
      settings: [#{key}: {MyApp.Wardrik#{Macro.camelize(to_string(key))}, []}]\
    """
  end

  @doc "Returns an error's message."
  @spec message(Wardrik.Error.t() | String.t()) :: String.t()
  def message(%{message: message}), do: message
  def message(message) when is_binary(message), do: message

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

  @doc "A size in bytes, in the largest unit that keeps it at 1 or more: `512 B`, `1.8 MB`."
  @spec bytes(integer() | nil) :: String.t()
  def bytes(nil), do: "—"
  def bytes(count) when count < 1024, do: "#{count} B"

  def bytes(count), do: scaled(count / 1024, ~w(KB MB GB TB))

  defp scaled(value, [_unit | rest]) when value >= 1024 and rest != [],
    do: scaled(value / 1024, rest)

  defp scaled(value, [unit | _rest]),
    do: "#{:erlang.float_to_binary(value, decimals: if(value < 10, do: 1, else: 0))} #{unit}"

  @doc """
  A small line chart of `values`, oldest first. Hover a point to see its value.

  `:format` turns a value into the text the tooltip shows. Set `:max` for a fixed scale from 0
  to `:max`. Without it, the scale fits the values, so small changes are visible.
  """
  attr :values, :list, required: true
  attr :label, :string, required: true
  attr :format, :any, default: nil
  attr :max, :any, default: nil

  def spark(assigns) do
    values = assigns.values
    assigns = assign(assigns, :format, assigns.format || (&number/1))
    count = max(length(values), 2)
    {low, high} = scale(values, assigns.max)
    step = 100 / (count - 1)

    points =
      values
      |> Enum.with_index()
      |> Enum.map(fn {value, index} ->
        {Float.round(index * step, 2), Float.round(30 - (value - low) / (high - low) * 28, 2),
         value}
      end)

    line = Enum.map_join(points, " ", fn {x, y, _value} -> "#{x},#{y}" end)

    area =
      case points do
        [{first, _y, _value} | _rest] ->
          {last, _y, _value} = List.last(points)
          "#{first},31 #{line} #{last},31"

        [] ->
          ""
      end

    assigns = assign(assigns, points: points, line: line, area: area, step: step)

    ~H"""
    <svg class="spark" viewBox="0 0 100 32" preserveAspectRatio="none" role="img" aria-label={@label}>
      <polygon :if={@area != ""} class="area" points={@area} />
      <polyline :if={length(@points) > 1} class="line" points={@line} />
      <rect
        :for={{x, _y, value} <- @points}
        class="hit"
        x={x - @step / 2}
        y="0"
        width={@step}
        height="32"
      >
        <title>{@format.(value)}</title>
      </rect>
    </svg>
    """
  end

  defp scale(_values, max) when is_number(max), do: {0, max}
  defp scale([], _max), do: {0, 1}

  defp scale(values, nil) do
    {low, high} = Enum.min_max(values)
    pad = if high == low, do: max(abs(high) * 0.1, 1), else: (high - low) * 0.15
    {low - pad, high + pad}
  end

  @doc """
  A bar that shows `count` as a share of `limit`, with both numbers and the percentage.

  At 80% or more the bar turns red and says it's near the limit. Set `:warn` to `false` for a
  share that isn't a limit.
  """
  attr :label, :string, required: true
  attr :count, :integer, required: true
  attr :limit, :integer, required: true
  attr :format, :any, default: &WardrikWeb.Components.number/1
  attr :warn, :boolean, default: true
  attr :tip, :string, default: nil, doc: "explains the bar, shown on hover or focus"

  def meter(assigns) do
    percent = if assigns.limit > 0, do: assigns.count * 100 / assigns.limit, else: 0
    assigns = assign(assigns, percent: percent, high: assigns.warn and percent >= 80)

    ~H"""
    <div class={["meter", @high && "high"]}>
      <div class="meter-text">
        <span>{@label}<.tip :if={@tip} text={@tip} /></span>
        <span class="num">
          {@format.(@count)} of {@format.(@limit)} · {percent_text(@percent)}<span :if={@high}> · near the limit</span>
        </span>
      </div>
      <div class="meter-track">
        <div class="meter-fill" style={"width: #{min(@percent, 100)}%"}></div>
      </div>
    </div>
    """
  end

  @doc "A small ⓘ mark that shows `text` on hover or keyboard focus."
  attr :text, :string, required: true

  def tip(assigns) do
    ~H"""
    <span class="tip" tabindex="0" role="note" aria-label={@text} data-tip={@text}>i</span>
    """
  end

  defp percent_text(percent) when percent > 0 and percent < 1, do: "<1%"
  defp percent_text(percent), do: "#{round(percent)}%"

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
