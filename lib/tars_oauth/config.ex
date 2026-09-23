defmodule TarsOAuth.Config do
  @moduledoc """
  Where `TarsOAuth` reads its settings.

      config :tars, TarsOAuth,
        client: [name: "Tars", document_url: "https://tars.dev/oauth/client"],
        providers: [github: [resource: "https://api.githubcopilot.com/mcp/"]],
        redirect: [port: 4599, open: true],
        tokens: TarsOAuth.Tokens.Vault,
        req_options: []

  | Key | What it is |
  | --- | --- |
  | `:client` | the identity this deployment presents, see `TarsOAuth.Client` |
  | `:providers` | what a user can authorize, see `TarsOAuth.Provider` |
  | `:redirect` | where a code comes back to: `:uri`, `:port`, `:open`, `:opener` |
  | `:tokens` | the `TarsOAuth.Tokens` module tokens are kept in |
  | `:req_options` | merged into every request |

  Every read of the application environment this package makes goes through
  here, so moving the setting to `config :tars_oauth` changes one module.
  """

  @default_tokens TarsOAuth.Tokens.Vault

  @spec client() :: keyword()
  def client, do: Keyword.get(env(), :client, [])

  @spec providers() :: keyword()
  def providers, do: Keyword.get(env(), :providers, [])

  @spec redirect() :: keyword()
  def redirect, do: Keyword.get(env(), :redirect, [])

  @spec req_options() :: keyword()
  def req_options, do: Keyword.get(env(), :req_options, [])

  @doc "The `TarsOAuth.Tokens` module tokens are kept in, `TarsOAuth.Tokens.Vault` by default."
  @spec tokens() :: module()
  def tokens, do: Keyword.get(env(), :tokens, @default_tokens)

  @doc "Whether any provider is configured."
  @spec configured?() :: boolean()
  def configured?, do: providers() != []

  defp env, do: Application.get_env(:tars, TarsOAuth, [])
end
