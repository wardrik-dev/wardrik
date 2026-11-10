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
  slot :actions

  def head(assigns) do
    ~H"""
    <header class="head">
      <div>
        <div :if={@crumb != []} class="crumb">{render_slot(@crumb)}</div>
        <h1>{@title}</h1>
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
