defmodule WardrikDaemon.CLI.Terminal do
  @moduledoc """
  The terminal a command writes to: its width, colour, and whether someone types at it.

    * Colour if stdout is a terminal, `NO_COLOR` is unset and `TERM` isn't `dumb`.
    * Otherwise plain text, 80 columns wide.
    * Input if `WARDRIK_INPUT` is `1`, which `bin/wardrik` sets for a terminal.
    * `:tty?` - whether stdout is a terminal.
    * `:live` - the `Owl.LiveScreen` that redraws lines in place, where stdout is a terminal.
  """

  alias WardrikDaemon.Console.Ansi

  defstruct width: 80, colour?: false, input?: false, tty?: false, live: nil

  @type t() :: %__MODULE__{
          width: pos_integer(),
          colour?: boolean(),
          input?: boolean(),
          tty?: boolean(),
          live: GenServer.server() | nil
        }

  @doc "Returns the terminal standard output is, with `env`, the environment, saying whether it takes colour and input."
  @spec new(%{String.t() => String.t()}) :: t()
  def new(env) do
    input? = env["WARDRIK_INPUT"] == "1"

    case :io.columns() do
      {:ok, width} ->
        %__MODULE__{
          width: width,
          colour?: colour?(env),
          input?: input?,
          tty?: true,
          live: Process.whereis(Owl.LiveScreen)
        }

      {:error, _not_a_terminal} ->
        %__MODULE__{input?: input?}
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
    case String.trim(IO.chardata_to_string(line)) do
      "" -> nil
      line -> line
    end
  end

  defp typed(_eof), do: nil

  @doc """
  Runs `fun` under a spinner labelled `label`, where there's a live screen, and returns what it
  returns: `:ok`, `{:ok, value}`, `:error` or `{:error, reason}`. The spinner is left as a line
  saying how it went, as `Owl.Spinner.run/2` leaves it.
  """
  @spec spinning(t(), Owl.Data.t(), (-> result)) :: result when result: term()
  def spinning(%__MODULE__{live: nil}, _label, fun), do: fun.()

  def spinning(%__MODULE__{live: screen}, label, fun) do
    result =
      Owl.Spinner.run(fun,
        labels: [processing: label, ok: label, error: label],
        live_screen_server: screen
      )

    # What's written next goes straight to the terminal, below the spinner.
    :ok = Owl.LiveScreen.flush(screen)
    result
  end

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
