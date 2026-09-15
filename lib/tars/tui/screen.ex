defmodule Tars.TUI.Screen do
  @moduledoc """
  The side-effecting surface `Tars.TUI` needs from a terminal.

  Five operations: claim the terminal and release it, append text, draw a
  one-line status, erase it. That is the whole contract, which keeps layout
  problems inside `Tars.TUI.View` rather than in cursor arithmetic.

  Deliberately *not* `Owl.LiveScreen`. LiveScreen repaints by moving the cursor
  up and clearing lines, which erases a line the user is part way through
  typing — it cannot share a terminal with a blocking `IO.gets/1`.

  Behind a behaviour so the TUI's event handling can be tested without a tty.
  """

  @typedoc "The terminal's height, or `nil` where there is no terminal to ask."
  @type rows() :: pos_integer() | nil

  @callback open(rows()) :: :ok
  @callback close(rows()) :: :ok
  @callback write(Owl.Data.t()) :: :ok
  @callback status(Owl.Data.t(), rows()) :: :ok
  @callback clear_status(rows()) :: :ok
end

defmodule Tars.TUI.Screen.Terminal do
  @moduledoc """
  `Tars.TUI.Screen` over plain stdout.

  The bottom row is reserved for the status line and everything else scrolls
  above it. `open/0` sets the terminal's scrolling region to exclude that row,
  so ordinary output — the transcript, the prompt, and the characters the
  terminal echoes as they are typed — can never reach it. The status line is
  drawn there by absolute position, between a save and a restore of the cursor,
  so the row being typed on is never written to and the caret never moves.

  `close/0` gives the row back. It runs from `Tars.TUI.terminate/2`, which is
  why the TUI traps exits; a terminal left with a scrolling region after a
  `SIGKILL` is repaired with `reset`.

  The height is passed in rather than asked for. `:io.rows/1` answers through
  the group leader, and the reader process holds a `get_line` request open
  against that same group leader for as long as it waits for input — so a
  height asked for mid-turn can come back `nil` and quietly drop the status
  line back into the transcript. `Tars.TUI` resolves it once, before the reader
  starts.

  Without a terminal — piped output, a test — there is no region to reserve and
  the status line is rewritten in place instead, which is harmless when nobody
  is typing.
  """

  @behaviour Tars.TUI.Screen

  # \r moves to column 0; \e[2K erases the whole line.
  @erase_line "\r\e[2K"
  @save_cursor "\e7"
  @restore_cursor "\e8"
  @reset_region "\e[r"
  @show_cursor "\e[?25h"

  @impl true
  def open(nil), do: :ok
  def open(rows), do: IO.write([region(1, rows - 1), at(rows - 1)])

  @impl true
  def close(rows) do
    if rows, do: IO.write([@save_cursor, at(rows), @erase_line, @restore_cursor])

    IO.write([@reset_region, @show_cursor])
  end

  @impl true
  def write(data), do: IO.write(Owl.Data.to_chardata(data))

  @impl true
  def status(data, rows), do: on_status_row(Owl.Data.to_chardata(data), rows)

  @impl true
  def clear_status(rows), do: on_status_row([], rows)

  defp on_status_row(chardata, nil), do: IO.write([@erase_line, chardata])

  defp on_status_row(chardata, rows) do
    IO.write([@save_cursor, at(rows), @erase_line, chardata, @restore_cursor])
  end

  defp region(top, bottom), do: "\e[#{top};#{bottom}r"

  defp at(row), do: "\e[#{row};1H"
end
