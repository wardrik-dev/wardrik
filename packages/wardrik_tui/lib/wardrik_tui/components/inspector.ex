defmodule WardrikTUI.Components.Inspector do
  @moduledoc "Scrollable tool and delegation details."
  use Breeze.Component
  alias WardrikTUI.{Delegation, Exchange, Text, Transcript, View}
  @faint [:faint, :light_black]

  # The inspector sits centred over the panes, as tall as its lines need.
  @inspector_width 80

  defp inspector_size(rows, width, height) do
    {min(width - 6, @inspector_width) |> max(20), min(rows + 2, height - 2) |> max(5)}
  end

  defp inspector(%{inspecting: nil}, _width, _height), do: {"", ""}

  defp inspector(%{inspecting: {:delegation, id, span_id}} = assigns, width, height) do
    now = System.system_time(:millisecond)
    delegations = assigns.delegations || Delegation.new()

    lines =
      case Delegation.fetch(delegations, span_id) do
        nil -> [Text.tag("this delegation is no longer shown · Esc closes", @faint)]
        record -> View.inspector(record, Delegation.activity(delegations, span_id), id, now)
      end

    inspector_box(lines, width, height)
  end

  defp inspector(%{inspecting: {:tool, index, _origin}} = assigns, width, height) do
    lines =
      case Exchange.at(assigns.tools, index) do
        nil -> [Text.tag("this tool call is no longer shown · Esc closes", @faint)]
        exchange -> View.tool_inspector(exchange, index)
      end

    inspector_box(lines, width, height)
  end

  # The lines laid out in a box centred over the panes, as tall as they need.
  defp inspector_box(lines, width, height) do
    {w, _h} = inspector_size(1, width, height)
    transcript = Transcript.append_all(Transcript.new(w - 4, pad?: true), lines)
    {_w, h} = inspector_size(Transcript.rows(transcript), width, height)

    {Transcript.source(transcript),
     "fixed center width-#{w} height-#{h} layer-50 bg-panel border-rounded border-primary " <>
       "overflow-scroll scrollbar-mute-100 padding-left-1"}
  end

  attr :inspecting, :any, required: true
  attr :tools, :any, required: true
  attr :delegations, :any, default: nil
  attr :width, :integer, required: true
  attr :height, :integer, required: true

  def inspector(assigns) do
    {source, class} = inspector(assigns, assigns.width, assigns.height)
    assigns = assign(assigns, source: source, class: class)

    ~H"""
    <box id="inspector" focusable implicit={WardrikTUI.Scroll} class={@class}>{@source}</box>
    """
  end
end
