defmodule WardrikDaemon.CLI.Browser do
  @moduledoc """
  Opens a link in the browser of the person at the terminal.

    * `BROWSER` names the command, as other tools read it. A `%s` in it stands for the link;
      without one, the link goes last. Only the first of a `:`-separated list is tried.
    * Without `BROWSER`, it's `open` on macOS and `xdg-open` elsewhere. Over SSH, or on Linux
      with neither `DISPLAY` nor `WAYLAND_DISPLAY`, it opens nothing: the browser isn't here.
    * The command runs in the background, so a browser that stays in the foreground doesn't hold
      up the command that opened it. Whether it worked isn't known; show the link as well.
  """

  @doc "Returns whether `open/2` opens a browser with the environment `env`."
  @spec opens?(%{String.t() => String.t()}) :: boolean()
  def opens?(env), do: match?({:ok, _command}, command(env, :os.type()))

  @doc "Opens `url` with the environment `env`. Returns why it didn't, if it didn't."
  @spec open(%{String.t() => String.t()}, String.t()) :: :ok | {:error, :remote | :none}
  def open(env, url) do
    with {:ok, command} <- command(env, :os.type()) do
      # sh gets the link as $1, so it is never read as shell.
      {_out, 0} =
        System.cmd("sh", ["-c", command <> " > /dev/null 2>&1 &", "sh", url])

      :ok
    end
  end

  defp command(%{"BROWSER" => browser}, _os) when browser != "" do
    [first | _rest] = String.split(browser, ":")

    if first =~ "%s",
      do: {:ok, String.replace(first, "%s", ~s("$1"))},
      else: {:ok, first <> ~s( "$1")}
  end

  defp command(%{"SSH_CONNECTION" => _ssh}, _os), do: {:error, :remote}
  defp command(%{"SSH_TTY" => _ssh}, _os), do: {:error, :remote}
  defp command(_env, {:unix, :darwin}), do: found("open")

  defp command(env, _os) do
    if env["DISPLAY"] || env["WAYLAND_DISPLAY"],
      do: found("xdg-open"),
      else: {:error, :remote}
  end

  defp found(program) do
    if System.find_executable(program), do: {:ok, program <> ~s( "$1")}, else: {:error, :none}
  end
end
