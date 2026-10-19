defmodule WardrikTUI.Components.FleetPanel do
  @moduledoc "Fleet rows and their sidebar or overlay container."
  use Breeze.Component
  import Breeze.Blocks
  alias WardrikConsole.Filter
  alias WardrikTUI.{Delegation, Render, Text}

  # The fleet panel: its heading and the list of rows, wherever it is placed.
  defp fleet_panel(assigns) do
    ~H"""
    <box class="block w-full h-1 overflow-hidden">{@heading}</box>
    <box class={"block w-full h-#{@rows_height} overflow-hidden"}>
      <.list
        id="fleet"
        br-change="highlight"
        list-selected={@highlighted}
        selected-indicator=" "
        class="height-full scrollbar-mute-100 border-line border-surface focus:border-primary"
        item_class="selected:bg-surface selected:text-muted"
      >
        <:item :for={{value, row} <- @fleet_rows} value={value}>{row}</:item>
      </.list>
    </box>
    """
  end

  # Over the panes, at the right, as tall as its rows need.
  defp overlay_class(rows, width, height) do
    rows_height = min(length(rows) + 2, max(height - 5, 3))

    "fixed right-1 top-1 width-#{width} height-#{rows_height + 1} layer-40 bg-panel " <>
      "overflow-hidden padding-left-1"
  end

  defp heading(_assigns, _shown, 0), do: ""

  defp heading(assigns, shown, width) do
    WardrikTUI.Fleet.heading(
      length(shown),
      length(assigns.fleet),
      Enum.count(assigns.fleet, &WardrikTUI.Fleet.attention?(&1, assigns.unseen)),
      Filter.describe(assigns.filter),
      width
    )
  end

  # One list item per agent shown, as `{id, row}`, and under an expanded
  # agent one per delegation, as `{{id, span_id}, row}`; each clipped to the
  # space inside the panel's gutter, the list's border and its selection
  # column.
  defp fleet_rows(_assigns, _shown, 0, _overlay?), do: []

  defp fleet_rows(assigns, shown, panel_width, overlay?) do
    now = System.system_time(:millisecond)
    ambiguous = WardrikTUI.Fleet.ambiguous(assigns.fleet)
    width = panel_width - 4

    Enum.flat_map(shown, fn member ->
      rows =
        Enum.map(delegation_texts(assigns, member.id, now), fn {value, text} ->
          text = Text.truncate(text, width)
          {value, Render.line(if(overlay?, do: WardrikTUI.Fleet.fill(text, width), else: text))}
        end)

      opts = [
        ambiguous: ambiguous,
        unseen: Map.get(assigns.unseen, member.id),
        delegations: Delegation.summary(WardrikTUI.Fleet.followed(assigns, member.id)),
        pad?: overlay?
      ]

      [{member.id, WardrikTUI.Fleet.row(member, assigns.agent_id, width, opts)} | rows]
    end)
  end

  # The delegation rows under one agent, unclipped, as `{value, text}`.
  defp delegation_texts(assigns, id, now) do
    case WardrikTUI.Fleet.expanded_delegations(assigns, id) do
      nil ->
        []

      delegations ->
        records = Delegation.list(delegations)
        count = length(records)

        records
        |> Enum.with_index(1)
        |> Enum.map(fn {record, index} ->
          depth = Delegation.depth(delegations, record.span_id)

          {{id, record.span_id}, WardrikTUI.Fleet.delegation(record, depth, index == count, now)}
        end)
    end
  end

  attr :fleet, :list, required: true
  attr :shown, :list, required: true
  attr :agent_id, :any, required: true
  attr :unseen, :map, required: true
  attr :filter, :any, required: true
  attr :expanded, :any, required: true
  attr :followed, :map, required: true
  attr :delegations, :any, default: nil
  attr :highlighted, :any, default: nil
  attr :width, :integer, required: true
  attr :height, :integer, required: true
  attr :overlay, :boolean, default: false

  def fleet(assigns) do
    rows = fleet_rows(assigns, assigns.shown, assigns.width, assigns.overlay)

    class =
      if assigns.overlay,
        do: overlay_class(rows, assigns.width, assigns.height),
        else: "block overflow-hidden padding-left-1 w-#{assigns.width} h-#{assigns.height}"

    assigns =
      assign(assigns,
        fleet_rows: rows,
        heading: heading(assigns, assigns.shown, assigns.width),
        rows_height: if(assigns.overlay, do: length(rows) + 2, else: assigns.height - 1),
        class: class
      )

    ~H"""
    <box class={@class}>
      <.fleet_panel
        heading={@heading}
        rows_height={@rows_height}
        highlighted={@highlighted}
        fleet_rows={@fleet_rows}
      />
    </box>
    """
  end
end
