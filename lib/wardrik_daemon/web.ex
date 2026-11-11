defmodule WardrikDaemon.Web do
  @moduledoc """
  The web dashboard. The daemon serves it at `/web`, on the same port as the HTTP API.

  It is the `WardrikWeb` dashboard. Its settings pages show the daemon's MCP servers, secrets,
  notify targets, OAuth apps and connections. Three more pages show ceilings, tokens and the
  configuration.

    * To turn it off, set `web.enabled: false` in `config.yaml`.
    * To sign in, run `wardrik web`. It prints a sign-in link. The link expires after two
      minutes.
    * Signing in creates a token for the same user as the command. The token expires after
      12 hours. Signing out revokes it.
    * The pages check permissions with `WardrikDaemon.Authorizer`, like the HTTP API.
  """

  alias Wardrik.Error
  alias WardrikDaemon.Config
  alias WardrikDaemon.Tokens

  @salt "wardrik web sign-in"
  @link_age 120
  @session_hours 12

  @doc "Returns the dashboard's secret key base. It is derived from the vault's first key."
  @spec key([String.t()]) :: String.t()
  def key([vault_key | _rest]) do
    [
      :crypto.mac(:hmac, :sha256, vault_key, "wardrik web 1"),
      :crypto.mac(:hmac, :sha256, vault_key, "wardrik web 2")
    ]
    |> IO.iodata_to_binary()
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Creates a sign-in link for the user that `scope` acts as.

  Only user tokens can create a link. Returns `not_found` when the dashboard is off.
  """
  @spec sign_in(map(), Wardrik.Scope.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def sign_in(%{web: nil}, _scope),
    do:
      {:error,
       Error.new(:not_found, "The dashboard is off. Set web.enabled to true in config.yaml.")}

  def sign_in(daemon, %Wardrik.Scope{actor: nil} = scope), do: link(daemon, scope)

  def sign_in(_daemon, _scope),
    do: {:error, Error.new(:forbidden, "Only a user token can sign in to the dashboard.")}

  defp link(daemon, scope) do
    {:ok, %{secret: secret}} =
      Tokens.create(daemon.store,
        name: "web dashboard",
        subject: "user:" <> scope.principal.id,
        groups: Map.get(scope.principal.attributes || %{}, :groups, []),
        expires: DateTime.add(DateTime.utc_now(), @session_hours, :hour)
      )

    code = Plug.Crypto.encrypt(daemon.web, @salt, secret)
    {:ok, base_url(daemon.config) <> "/web/sign-in?" <> URI.encode_query(%{"code" => code})}
  end

  @doc "Returns the token secret in a sign-in `code`. Returns `:error` if the code is more than two minutes old."
  @spec secret(String.t(), String.t()) :: {:ok, String.t()} | :error
  def secret(key, code) do
    case Plug.Crypto.decrypt(key, @salt, code, max_age: @link_age) do
      {:ok, secret} -> {:ok, secret}
      {:error, _reason} -> :error
    end
  end

  defp base_url(%Config{base_url: nil} = config), do: Config.url(config)
  defp base_url(%Config{base_url: url}), do: String.trim_trailing(url, "/")
end
