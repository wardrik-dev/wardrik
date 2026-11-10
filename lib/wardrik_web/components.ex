defmodule WardrikWeb.Components do
  @moduledoc """
  The dashboard's pieces, for extension pages to look like its own.

      import WardrikWeb.Components

      <.head title="Fleet" lead="What every agent spent." />
      <.status value="parked" />
  """

  use Phoenix.Component

  alias WardrikWeb.Dashboard

  @doc "A page's heading, with a breadcrumb and actions."
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

  @doc "A state, such as an agent's status or a run's, as a coloured pill."
  attr :value, :string, required: true

  def status(assigns) do
    ~H"""
    <span class={["pill", @value]}>{@value}</span>
    """
  end

  @doc "Whether the view follows new events."
  attr :live, :boolean, required: true
  attr :stopped, :string, default: nil

  def live(assigns) do
    ~H"""
    <span class={["live", !@live && "off"]} title={@stopped}>
      {if @live, do: "Live", else: "Not following"}
    </span>
    """
  end

  @doc "Any JSON value, formatted."
  attr :value, :any, required: true

  def json(assigns) do
    ~H"""
    <pre class="json">{Jason.encode!(@value, pretty: true)}</pre>
    """
  end

  @doc "The LiveComponents the dashboard's extensions show in `slot`, given `assigns`."
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

  def usd(dollars) when dollars < 0.01,
    do: "$" <> :erlang.float_to_binary(dollars / 1, decimals: 4)

  def usd(dollars), do: "$" <> :erlang.float_to_binary(dollars / 1, decimals: 2)

  @doc "A cost in micro-USD, in dollars."
  @spec micro_usd(non_neg_integer() | nil) :: String.t()
  def micro_usd(nil), do: "—"
  def micro_usd(micro), do: usd(micro / 1.0e6)

  @doc "A count, with thousands separated."
  @spec number(integer() | nil) :: String.t()
  def number(nil), do: "—"

  def number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  @doc "A token count, shortened past a thousand: `8.4k`, `1.2M`."
  @spec tokens(integer() | nil) :: String.t()
  def tokens(nil), do: "—"
  def tokens(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  def tokens(n) when n >= 1000, do: "#{Float.round(n / 1000, 1)}k"
  def tokens(n), do: number(n)

  @doc "A duration in milliseconds, in its largest two units: `850 ms`, `4.2s`, `3m 10s`, `6d 20h`."
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

  @doc "An ISO 8601 time, as how long ago it was."
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
