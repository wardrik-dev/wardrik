defmodule TarsTUI.Clipboard do
  @moduledoc """
  Puts text on the system clipboard through the first tool found of
  `wl-copy`, `xclip`, `xsel` and `pbcopy`.

  `copy/1` answers `:ok`, `{:error, :no_clipboard}` when none is installed, or
  `{:error, {:exit, status}}` when the tool failed.
  """

  @tools [
    {"wl-copy", []},
    {"xclip", ["-selection", "clipboard"]},
    {"xsel", ["--clipboard", "--input"]},
    {"pbcopy", []}
  ]

  @typedoc "What `copy/1` answers."
  @type result() :: :ok | {:error, :no_clipboard | {:exit, non_neg_integer()}}

  @doc "The clipboard tool on this machine, as `{path, arguments}`, or `nil`."
  @spec tool() :: {String.t(), [String.t()]} | nil
  def tool do
    Enum.find_value(@tools, fn {name, args} ->
      case System.find_executable(name) do
        nil -> nil
        path -> {path, args}
      end
    end)
  end

  @doc """
  A copy that goes to the clipboard of whoever is at the other end of a
  terminal, as an OSC 52 escape sequence handed to `write`. What an SSH
  session copies with: the tools `copy/1` runs would copy on the server. Most
  terminals honour it; some ask first, and tmux needs `set-clipboard on`.
  """
  @spec osc52((String.t() -> term())) :: (String.t() -> result())
  def osc52(write) when is_function(write, 1) do
    fn text when is_binary(text) ->
      write.("\e]52;c;" <> Base.encode64(text) <> "\a")
      :ok
    end
  end

  @doc "Copies `text` to the clipboard."
  @spec copy(String.t()) :: result()
  def copy(text) when is_binary(text) do
    case tool() do
      nil -> {:error, :no_clipboard}
      {path, args} -> run(path, args, text)
    end
  end

  # The tool reads its standard input to the end, so the text goes through a
  # file rather than a port, which cannot close only its writing side. Its
  # output goes nowhere: wl-copy leaves a process behind to serve the
  # clipboard, and a pipe it inherited would never close.
  defp run(path, args, text) do
    file = Path.join(System.tmp_dir!(), "tars-copy-#{System.unique_integer([:positive])}")

    try do
      File.write!(file, text)
      script = ~s(exec "$0" "$@" < ) <> shell_quote(file) <> " > /dev/null 2>&1"

      case System.cmd("sh", ["-c", script, path | args]) do
        {_output, 0} -> :ok
        {_output, status} -> {:error, {:exit, status}}
      end
    after
      File.rm(file)
    end
  end

  defp shell_quote(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"
end
