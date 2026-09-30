defmodule WardrikDaemon.CLI.Terminal do
  @moduledoc """
  The terminal a command was typed in, as `bin/wardrik` describes it: how
  wide it is, and whether it takes colour.

  The node answering a command has no terminal of its own, so the script puts
  one argument ahead of the command's, `--terminal=WIDTH,colour` or
  `--terminal=WIDTH,plain`. It takes colour where standard output is a
  terminal and `NO_COLOR` is not set. A command given no such argument, as
  from a test or `wardrik remote`, writes plain text 80 columns wide.
  """

  @typedoc "How wide the terminal is, and whether it takes colour."
  @type t() :: %__MODULE__{width: pos_integer(), colour?: boolean()}

  defstruct width: 80, colour?: false

  @doc "The terminal `args` open with, if they do, and the command's own arguments after it."
  @spec read([String.t()]) :: {t(), [String.t()]}
  def read(["--terminal=" <> described | args]) do
    [width, colour] = String.split(described, ",", parts: 2)
    {%__MODULE__{width: width(width), colour?: colour == "colour"}, args}
  end

  def read(args), do: {%__MODULE__{}, args}

  # COLUMNS is whatever the environment held, so a width that does not read
  # is the usual one.
  defp width(text) do
    case Integer.parse(text) do
      {width, ""} when width > 0 -> width
      _other -> 80
    end
  end

  @doc "Writes `data` and a newline to `device`, in colour where the terminal takes it."
  @spec puts(t(), Owl.Data.t(), IO.device()) :: :ok
  def puts(%__MODULE__{colour?: colour?}, data, device \\ :stdio),
    do: IO.puts(device, WardrikConsole.Ansi.chardata(data, colour?))
end
