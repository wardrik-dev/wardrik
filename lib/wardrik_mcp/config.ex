defmodule WardrikMCP.Config do
  @moduledoc """
  Where `WardrikMCP` reads its settings.

      config :wardrik, WardrikMCP,
        servers: [
          github: [transport: {:stdio, command: "github-mcp-server"}]
        ]

  `:first_retry` is how many milliseconds a connection that could not list a
  server's tools waits before asking again the first time, doubling each time
  after, a second by default. `:refresh_after` is how long it waits after a
  server says its tools changed before listing them, so a burst of changes
  costs one listing, 250 by default.

  Every read of the application environment this package makes goes through
  here, so moving the setting to `config :wardrik_mcp` changes one module.
  """

  @doc "The servers as configured: a keyword list of ref to `WardrikMCP.Server.new/2` options."
  @spec servers() :: keyword()
  def servers, do: Keyword.get(env(), :servers, [])

  @doc "The refs of the configured servers."
  @spec refs() :: [atom()]
  def refs, do: Keyword.keys(servers())

  @doc "Whether any server is configured."
  @spec configured?() :: boolean()
  def configured?, do: servers() != []

  @doc "Milliseconds before a connection asks a server for its tools again the first time."
  @spec first_retry() :: pos_integer()
  def first_retry, do: Keyword.get(env(), :first_retry, :timer.seconds(1))

  @doc "Milliseconds a connection waits after a server says its tools changed."
  @spec refresh_after() :: non_neg_integer()
  def refresh_after, do: Keyword.get(env(), :refresh_after, 250)

  defp env, do: Application.get_env(:wardrik, WardrikMCP, [])
end
