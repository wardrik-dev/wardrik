defmodule WardrikDaemon.CLI.Terminal do
  @moduledoc """
  The terminal a command writes to: its width, colour, and whether someone types at it.

    * Colour if stdout is a terminal, `NO_COLOR` is unset and `TERM` isn't `dumb`.
    * Otherwise plain text, 80 columns wide.
    * Input if `WARDRIK_INPUT` is `1`, which `bin/wardrik` sets for a terminal.
  """

  alias WardrikDaemon.Console.Ansi

  defstruct width: 80, colour?: false, input?: false

  @type t() :: %__MODULE__{width: pos_integer(), colour?: boolean(), input?: boolean()}

  @doc "Returns the terminal standard output is, with `env`, the environment, saying whether it takes colour and input."
  @spec new(%{String.t() => String.t()}) :: t()
  def new(env) do
    input? = env["WARDRIK_INPUT"] == "1"

    case :io.columns() do
      {:ok, width} -> %__MODULE__{width: width, colour?: colour?(env), input?: input?}
      {:error, _not_a_terminal} -> %__MODULE__{input?: input?}
    end
  end

  @doc "Asks for a line with `prompt`. Returns `nil` for none."
  @spec ask(t(), String.t()) :: String.t() | nil
  def ask(terminal, prompt) do
    IO.write(Ansi.chardata(prompt, terminal.colour?))
    typed(IO.gets(""))
  end

  @doc "Asks for a line with `prompt`, not showing what's typed where it can. Returns `nil` for none."
  @spec secret(t(), String.t()) :: String.t() | nil
  def secret(terminal, prompt) do
    IO.write(Ansi.chardata(prompt, terminal.colour?))

    if Process.whereis(:user) == Process.group_leader() and
         :shell.start_interactive({:noshell, :raw}) == :ok do
      line = :io.get_password()
      :ok = :shell.start_interactive({:noshell, :cooked})
      IO.write("\n")
      typed(line)
    else
      typed(IO.gets(""))
    end
  end

  defp typed(line) when is_binary(line) or is_list(line) do
    case line |> IO.chardata_to_string() |> String.trim() do
      "" -> nil
      line -> line
    end
  end

  defp typed(_eof), do: nil

  @doc "Writes `data` and a newline, styled if the terminal takes colour."
  @spec puts(t(), Owl.Data.t()) :: :ok
  def puts(%__MODULE__{colour?: colour?}, data), do: IO.puts(Ansi.chardata(data, colour?))

  @doc "Writes each of `lines`."
  @spec lines(t(), [Owl.Data.t()]) :: :ok
  def lines(terminal, lines), do: Enum.each(lines, &puts(terminal, &1))

  defp colour?(%{"NO_COLOR" => _set}), do: false
  defp colour?(%{"TERM" => "dumb"}), do: false
  defp colour?(_env), do: true
end
