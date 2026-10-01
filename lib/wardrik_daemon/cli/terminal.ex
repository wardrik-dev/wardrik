defmodule WardrikDaemon.CLI.Terminal do
  @moduledoc """
  The terminal a command was typed in, as `bin/wardrik` describes it: how
  wide it is, whether it takes colour, and whether a person can type into it.

  The node answering a command has no terminal of its own, so the script puts
  one argument ahead of the command's, such as `--terminal=120,colour,input`.
  It takes colour where standard output is a terminal and `NO_COLOR` is not
  set, and says `input` where standard input is a terminal too, and
  `no-input` where not. A command given no such argument, as from a test or
  `wardrik remote`, writes plain text 80 columns wide and reads nothing.

  `live?` is whether the command runs live, over `bin/wardrikd rpc`, where it
  writes each line to the terminal as it goes and can read what is typed
  there. Over `erl_call` it can do neither; see `WardrikDaemon.CLI.live/1`.
  """

  @typedoc "How wide the terminal is, whether it takes colour and input, and whether the command runs live."
  @type t() :: %__MODULE__{
          width: pos_integer(),
          colour?: boolean(),
          input?: boolean(),
          live?: boolean()
        }

  defstruct width: 80, colour?: false, input?: false, live?: false

  @doc "The terminal `args` open with, if they do, and the command's own arguments after it."
  @spec read([String.t()]) :: {t(), [String.t()]}
  def read(["--terminal=" <> described | args]) do
    [width | facts] = String.split(described, ",")
    {%__MODULE__{width: width(width), colour?: "colour" in facts, input?: "input" in facts}, args}
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

  @doc """
  Writes `data` and a newline to `device`, in colour where the terminal takes
  it. `data` can be a function that lays it out at the terminal's width.
  """
  @spec puts(t(), Owl.Data.t() | (pos_integer() -> Owl.Data.t()), IO.device()) :: :ok
  def puts(terminal, data, device \\ :stdio)

  def puts(%__MODULE__{} = terminal, layout, device) when is_function(layout, 1),
    do: puts(terminal, layout.(terminal.width), device)

  def puts(%__MODULE__{colour?: colour?}, data, device),
    do: IO.puts(device, WardrikConsole.Ansi.chardata(data, colour?))

  @doc """
  Reads a line typed at the terminal after `prompt`, without showing it, for a
  command running live where someone can type: the line, or `nil` where
  nothing was typed.

  The VM a live command reads through, the caller's over `bin/wardrikd rpc`,
  leaves the terminal to echo what is typed, and cannot stop it. So it reads
  the terminal raw, which echoes nothing, for that one line, and goes back to
  reading it a line at a time after. Input this node reads itself, as a test
  captures it, has no terminal to hide it from, and is read as it is.
  """
  @spec secret(t(), Owl.Data.t()) :: {:ok, String.t() | nil} | {:error, String.t()}
  def secret(%__MODULE__{} = terminal, prompt) do
    prompt = WardrikConsole.Ansi.chardata(prompt, terminal.colour?)

    case node(Process.group_leader()) do
      reader when reader == node() -> {:ok, typed(IO.gets(prompt))}
      reader -> hidden(reader, prompt)
    end
  end

  defp hidden(reader, prompt) do
    with :ok <- reading(reader, :raw) do
      IO.write(prompt)
      # Read through the group leader, the caller's, not this node's own user.
      line = :io.get_password(Process.group_leader())
      :ok = reading(reader, :cooked)
      IO.write("\n")
      {:ok, typed(line)}
    end
  end

  defp reading(reader, mode) do
    case :erpc.call(reader, :shell, :start_interactive, [{:noshell, mode}]) do
      :ok -> :ok
      {:error, _reason} -> {:error, "This terminal cannot hide what is typed; pipe the value in."}
    end
  end

  defp typed(line) when is_binary(line) or is_list(line) do
    case line |> IO.chardata_to_string() |> String.trim_trailing("\n") do
      "" -> nil
      line -> line
    end
  end

  defp typed(_eof_or_error), do: nil
end
