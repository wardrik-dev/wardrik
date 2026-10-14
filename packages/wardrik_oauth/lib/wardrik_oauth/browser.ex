defmodule WardrikOAuth.Browser do
  @moduledoc """
  Opens an authorization link in whatever browser this machine has.

  Used where the callback comes back to this machine's loopback: the browser is
  on the same machine by definition, so there is somewhere to send the person
  and no reason to make them copy a URL out of a terminal. A deployment
  serving its own redirect URI opens nothing.

      {WardrikOAuth.Supervisor, redirect: [open: false]}

  `:opener` names the command to open a link with, for a desktop this does not
  know about and for a test that must not open anything.

  Nothing here fails a flow. A machine with no browser, or a command that will
  not run, leaves the link where it was: in the prompt the turn parked on.
  """

  require Logger

  @openers ~w(xdg-open open wslview)

  @doc """
  Whether this machine has a browser to open: a command that opens links,
  and a desktop for it to open them on, as macOS, WSL, and an X or Wayland
  session have and a server reached over SSH does not. `:opener` is as
  `open/2` takes it.
  """
  @spec available?(opener: String.t() | nil) :: boolean()
  def available?(opts \\ []) do
    case opener(opts[:opener]) do
      nil -> false
      opener -> desktop?(Path.basename(opener))
    end
  end

  defp desktop?("wslview"), do: true

  defp desktop?(_opener) do
    :os.type() == {:unix, :darwin} or present?("DISPLAY") or present?("WAYLAND_DISPLAY")
  end

  defp present?(variable), do: System.get_env(variable) not in [nil, ""]

  @doc """
  Opens `url`, and says whether anything took it. `:opener` names the
  command that opens it, as a deployment's redirect settings name one, else
  the first of the usual ones this machine has.
  """
  @spec open(String.t(), opener: String.t() | nil) :: :ok | {:error, :no_browser}
  def open(url, opts \\ []) when is_binary(url) do
    case opener(opts[:opener]) do
      nil ->
        {:error, :no_browser}

      opener ->
        {:ok, _pid} =
          Task.Supervisor.start_child(WardrikOAuth.Tasks, fn ->
            System.cmd(opener, [url], stderr_to_stdout: true)
          end)

        Logger.info("Opening an authorization link with #{Path.basename(opener)}")

        :ok
    end
  end

  defp opener(nil), do: Enum.find_value(@openers, &System.find_executable/1)
  defp opener(named), do: System.find_executable(named)
end
