defmodule WardrikOAuth.Config do
  @moduledoc """
  Where `WardrikOAuth` reads its settings.

      config :wardrik, WardrikOAuth,
        client: [name: "Wardrik", document_url: "https://wardrik.dev/oauth/client"],
        providers: [github: [resource: "https://api.githubcopilot.com/mcp/"]],
        redirect: [port: 4599, open: true],
        req_options: []

  | Key | What it is |
  | --- | --- |
  | `:client` | the identity this deployment presents, see `WardrikOAuth.Client` |
  | `:providers` | what a user can authorize, see `WardrikOAuth.Provider` |
  | `:redirect` | where a code comes back to: `:uri`, `:port`, `:open`, `:opener` |
  | `:req_options` | merged into every request |
  | `:resolver` | the module whose `resolve/1` answers a host's addresses, `WardrikOAuth.Egress` by default |
  | `:poll_floor` | the fewest milliseconds between two polls of a device flow, 5 seconds by default |

  Every read of the application environment this package makes goes through
  here, so moving the setting to `config :wardrik_oauth` changes one module.
  """

  @spec client() :: keyword()
  def client, do: Keyword.get(env(), :client, [])

  @spec providers() :: keyword()
  def providers, do: Keyword.get(env(), :providers, [])

  @spec redirect() :: keyword()
  def redirect, do: Keyword.get(env(), :redirect, [])

  @spec req_options() :: keyword()
  def req_options, do: Keyword.get(env(), :req_options, [])

  @doc "The module whose `resolve/1` answers a host's addresses; see `WardrikOAuth.Egress`."
  @spec resolver() :: module()
  def resolver, do: Keyword.get(env(), :resolver, WardrikOAuth.Egress)

  @doc "The fewest milliseconds between two polls of a device flow, whatever the server asks."
  @spec poll_floor() :: non_neg_integer()
  def poll_floor, do: Keyword.get(env(), :poll_floor, :timer.seconds(5))

  @doc "Whether any provider is configured."
  @spec configured?() :: boolean()
  def configured?, do: providers() != []

  defp env, do: Application.get_env(:wardrik, WardrikOAuth, [])
end
