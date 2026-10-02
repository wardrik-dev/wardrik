defmodule WardrikTUI.Editor do
  @moduledoc """
  Edits a prompt draft in the editor `$VISUAL` names, or `$EDITOR`.

  `edit/2` writes the draft to a file, hands the terminal to the editor, and
  reads the file back once the editor exits. Handing over means: a blank frame
  is displayed through `Breeze.Runtime.display_frame/3`, which pauses the
  view; the mouse, the enhanced keyboard protocol, the hidden cursor and the
  alternate screen are undone; and the terminal's reader is stopped, so the
  editor alone reads keys. Everything is put back before returning, and the
  live frame is redrawn in full.

  The answer is `{:ok, text}` with the file's contents, trailing newlines
  removed, when the editor exits with status zero. Otherwise it is
  `{:error, :no_editor}` when neither variable is set, `{:error, {:exit,
  status}}` for any other exit status, which is how `:cq` in Vim cancels, or
  the file error met. Without a terminal to hand over, as in a test, the
  editor runs as is.
  """

  alias Termite.Screen

  @typedoc "What the handoff needs: the terminal the view draws on, and the Breeze server."
  @type context() :: %{terminal: %Termite.Terminal{} | nil, server: pid() | nil}

  @typedoc "What `edit/2` answers."
  @type result() :: {:ok, String.t()} | {:error, term()}

  # How long the terminal reader is given to acknowledge a stop or a start.
  @reader_after 1_000

  @doc "The editor command `$VISUAL` names, or `$EDITOR`, or `nil`."
  @spec command() :: String.t() | nil
  def command, do: present(System.get_env("VISUAL")) || present(System.get_env("EDITOR"))

  defp present(nil), do: nil
  defp present(value), do: if(String.trim(value) == "", do: nil, else: value)

  @doc "Edits `draft` in the editor, with the terminal handed over meanwhile."
  @spec edit(String.t(), context()) :: result()
  def edit(draft, context) do
    with {:ok, command} <- command_or_error(),
         {:ok, directory, path} <- write(draft) do
      try do
        hand_over(context, fn -> run(command, path) end)
      after
        File.rm_rf(directory)
      end
    end
  end

  defp command_or_error do
    case command() do
      nil -> {:error, :no_editor}
      command -> {:ok, command}
    end
  end

  defp write(draft) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    directory = Path.join(System.tmp_dir!(), "wardrik-prompt-#{token}")

    case File.mkdir(directory) do
      :ok -> write_private(directory, draft)
      {:error, reason} -> {:error, {:write, reason}}
    end
  end

  defp write_private(directory, draft) do
    path = Path.join(directory, "prompt.md")

    with :ok <- File.chmod(directory, 0o700),
         :ok <- File.write(path, draft, [:exclusive]),
         :ok <- File.chmod(path, 0o600) do
      {:ok, directory, path}
    else
      {:error, reason} ->
        File.rm_rf(directory)
        {:error, {:write, reason}}
    end
  end

  @doc """
  Runs `command` on `path` with the terminal, and reads the file back.

  The command is run through the shell, so `$VISUAL` may carry arguments.
  """
  @spec run(String.t(), Path.t()) :: result()
  def run(command, path) do
    port = Port.open({:spawn, command <> " " <> quote_arg(path)}, [:nouse_stdio, :exit_status])

    receive do
      {^port, {:exit_status, 0}} -> read(path)
      {^port, {:exit_status, status}} -> {:error, {:exit, status}}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, String.trim_trailing(text, "\n")}
      {:error, reason} -> {:error, {:read, reason}}
    end
  end

  @doc "`path` quoted for the shell."
  @spec quote_arg(String.t()) :: String.t()
  def quote_arg(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"

  # -- the terminal ----------------------------------------------------------

  defp hand_over(
         %{terminal: %Termite.Terminal{adapter: {_module, _state}} = terminal, server: server},
         fun
       )
       when is_pid(server) do
    with :ok <- Breeze.Runtime.display_frame(server, %{lines: []}, owner: self()) do
      leave(terminal)
      reader = stop_reader()

      try do
        fun.()
      after
        start_reader(reader)
        return(terminal)
        Breeze.Runtime.display_frame(server, :live)
      end
    end
  end

  defp hand_over(_context, fun), do: fun.()

  defp leave(terminal) do
    terminal
    |> Screen.disable_mouse()
    |> Screen.disable_enhanced_keyboard()
    |> Screen.show_cursor()
    |> Screen.exit_alt_screen()
  end

  defp return(terminal) do
    terminal
    |> Screen.alt_screen()
    |> Screen.enable_enhanced_keyboard()
    |> Screen.hide_cursor()
    |> Screen.enable_mouse()
    |> Screen.clear_screen()
  end

  # The reader `prim_tty` starts for the terminal is registered as
  # `user_drv_reader`, and stops reading between a `disable` and an `enable`,
  # each acknowledged. Without it, or without an acknowledgement, the editor
  # runs anyway.
  defp stop_reader do
    with pid when is_pid(pid) <- Process.whereis(:user_drv_reader),
         :ok <- call(pid, :disable) do
      pid
    else
      _other -> nil
    end
  end

  defp start_reader(nil), do: :ok
  defp start_reader(pid), do: call(pid, :enable)

  defp call(pid, message) do
    alias = Process.monitor(pid, alias: :reply_demonitor)
    send(pid, {alias, message})

    receive do
      {^alias, reply} -> reply
      {:DOWN, ^alias, :process, ^pid, reason} -> {:error, reason}
    after
      @reader_after ->
        Process.demonitor(alias, [:flush])
        {:error, :timeout}
    end
  end
end
