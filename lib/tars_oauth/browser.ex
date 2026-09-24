defmodule TarsOAuth.Browser do
  @moduledoc """
  Opens an authorization link in whatever browser this machine has.

  Used where the callback comes back to `TarsOAuth.Loopback`: the browser is
  on the same machine by definition, so there is somewhere to send the person
  and no reason to make them copy a URL out of a terminal. A deployment
  serving its own redirect URI opens nothing.

      config :tars, TarsOAuth, redirect: [open: false]

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
  session have and a server reached over SSH does not.
  """
  @spec available?() :: boolean()
  def available? do
    case opener() do
      nil -> false
      opener -> desktop?(Path.basename(opener))
    end
  end

  defp desktop?("wslview"), do: true

  defp desktop?(_opener) do
    :os.type() == {:unix, :darwin} or present?("DISPLAY") or present?("WAYLAND_DISPLAY")
  end

  defp present?(variable), do: System.get_env(variable) not in [nil, ""]

  @doc "Opens `url`, and says whether anything took it."
  @spec open(String.t()) :: :ok | {:error, :no_browser}
  def open(url) when is_binary(url) do
    case opener() do
      nil ->
        {:error, :no_browser}

      opener ->
        spawn(fn -> System.cmd(opener, [url], stderr_to_stdout: true) end)
        Logger.info("Opening an authorization link with #{Path.basename(opener)}")

        :ok
    end
  end

  defp opener do
    case Keyword.get(TarsOAuth.Config.redirect(), :opener) do
      nil -> Enum.find_value(@openers, &System.find_executable/1)
      named -> System.find_executable(named)
    end
  end
end
