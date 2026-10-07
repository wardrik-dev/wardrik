defmodule WardrikConsole do
  @moduledoc """
  Wardrik on a plain terminal: text written a line at a time and never
  redrawn, for any surface that writes to one.

    * `WardrikConsole.Markdown` renders streamed markdown a line at a time, and
      `WardrikConsole.Table` holds and lays out the tables in it.
    * `WardrikConsole.Printer` turns an agent's events into the lines they
      complete.
    * `WardrikConsole.Filter` reads a query that picks agents from the fleet.
    * `WardrikConsole.Nodes` names nodes the way a person writes them.

  Styled text is `Owl.Data` throughout.

  This module is a subscriber that prints one agent's events as they happen:

      {:ok, _pid} = WardrikConsole.start_link(agent_id: ~A"acme/@jon/assistant")

  Each line is written to the group leader of the process that started it, as
  `WardrikConsole.Printer` completes it, and laid out to `:width` columns, the
  terminal's own where it has one and 80 otherwise. Several can run at once
  beside other listeners, and none of them are known to `Wardrik.Agent` or
  `Wardrik.LLM.Turn`.
  """
  use GenServer

  alias Wardrik.Event
  alias Wardrik.Event.Bus
  alias WardrikConsole.Printer

  @doc "Starts a subscriber printing `:agent_id`'s events, laid out to `:width` columns."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {agent_id, opts} = Keyword.pop!(opts, :agent_id)
    {width, opts} = Keyword.pop_lazy(opts, :width, fn -> Owl.IO.columns() || 80 end)
    GenServer.start_link(__MODULE__, {agent_id, width}, opts)
  end

  @impl true
  def init({agent_id, width}) do
    :ok = Bus.subscribe(agent_id)
    {:ok, Printer.new(width: width)}
  end

  @impl true
  def handle_info(%Event{} = event, printer) do
    {lines, printer} = Printer.event(printer, event)
    Enum.each(lines, &Owl.IO.puts/1)
    {:noreply, printer}
  end

  def handle_info(_message, printer), do: {:noreply, printer}
end
