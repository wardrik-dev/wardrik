defmodule WardrikDaemon.Egress do
  @moduledoc """
  Checks the URLs orgs and people add: MCP servers, webhooks and OAuth apps.

    * A URL must be `https` at a public address, checked when added and on each request.
    * Hosts `config.yaml`'s OAuth providers name are trusted. `config.yaml`'s own servers and
      targets aren't checked.
    * `allow_private_urls: true` lets any URL through. For local use only.
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
