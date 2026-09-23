defmodule TarsMCP.Config do
  @moduledoc """
  Where `TarsMCP` reads its settings.

      config :tars, TarsMCP,
        servers: [
          github: [transport: {:stdio, command: "github-mcp-server"}]
        ]

  Every read of the application environment this package makes goes through
  here, so moving the setting to `config :tars_mcp` changes one module.
  """

  @doc "The servers as configured: a keyword list of ref to `TarsMCP.Server.new/2` options."
  @spec servers() :: keyword()
  def servers, do: Keyword.get(env(), :servers, [])

  @doc "The refs of the configured servers."
  @spec refs() :: [atom()]
  def refs, do: Keyword.keys(servers())

  @doc "Whether any server is configured."
  @spec configured?() :: boolean()
  def configured?, do: servers() != []

  defp env, do: Application.get_env(:tars, TarsMCP, [])
end
