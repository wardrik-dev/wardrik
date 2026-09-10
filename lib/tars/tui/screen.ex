defmodule Tars.TUI.Screen do
  @moduledoc """
  The side-effecting surface `Tars.TUI` needs from a terminal.

  Three operations: append text, overwrite a one-line status, erase it. That
  is the whole terminal contract, which is what keeps layout problems inside
  `Tars.TUI.View` rather than in cursor arithmetic.

  Deliberately *not* `Owl.LiveScreen`. LiveScreen repaints by moving the
  cursor up and clearing lines, which erases a line the user is part way
  through typing — it cannot share a terminal with a blocking `IO.gets/1`.

  Behind a behaviour so the TUI's event handling can be tested without a tty.
  """

  @callback write(Owl.Data.t()) :: :ok
  @callback status(Owl.Data.t()) :: :ok
  @callback clear_status() :: :ok
end

defmodule Tars.TUI.Screen.Terminal do
  @moduledoc """
  `Tars.TUI.Screen` over plain stdout.

  The status line is rewritten in place with a carriage return and an
  erase-to-end-of-line, so it never scrolls and never leaves a trail.
  """

  @behaviour Tars.TUI.Screen

  # \r moves to column 0; \e[2K erases the whole line.
  @erase_line "\r\e[2K"

  @impl true
  def write(data), do: IO.write(Owl.Data.to_chardata(data))

  @impl true
  def status(data), do: IO.write([@erase_line, Owl.Data.to_chardata(data)])

  @impl true
  def clear_status, do: IO.write(@erase_line)
end
