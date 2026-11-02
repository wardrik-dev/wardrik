defmodule WardrikDaemon.Egress do
  @moduledoc """
  Decides which URLs orgs and people may point the daemon at: an MCP server's, a webhook's, and an
  OAuth app's. It's the daemon's Wardrik `:egress`, and `WardrikOAuth`'s `:check`.

    * A URL must be `https`, at a public address, as `Wardrik.Egress.public/1` says. Loopback,
      private, link-local and cloud metadata addresses are refused, as each is added and as each
      connection or notice is sent.
    * A host an OAuth provider in `config.yaml` names is trusted, so an IdP on your network still
      signs people in. Servers and targets in `config.yaml` aren't checked at all.
    * `allow_private_urls: true` in `config.yaml` lets any URL through. It's for local use only,
      as when every server runs on your own machine.
  """

  alias WardrikDaemon.Config

  @doc "Returns the check `config` asks for, as Wardrik's `:egress` takes it."
  @spec check(Config.t()) :: (String.t() -> :ok | {:error, String.t()})
  def check(%Config{allow_private_urls: true}), do: &Wardrik.Egress.any/1

  def check(%Config{} = config) do
    trusted = trusted(config.oauth)
    fn url -> if host(url) in trusted, do: :ok, else: Wardrik.Egress.public(url) end
  end

  defp trusted(nil), do: []

  defp trusted(oauth) do
    for {_name, provider} <- Keyword.get(oauth, :providers, []),
        {_key, value} <- provider,
        is_binary(value),
        host = host(value),
        host != nil,
        uniq: true,
        do: host
  end

  defp host(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        host

      _other ->
        nil
    end
  end
end
