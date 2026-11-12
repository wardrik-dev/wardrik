defmodule WardrikDaemon.Config.OAuth do
  @moduledoc """
  Reads `config.yaml`'s `oauth`: the services people sign in to.

      oauth:
        client_name: Acme agents
        providers:
          github:
            issuer: https://github.com/login/oauth
            client_id: ${GITHUB_CLIENT_ID}
            client_secret: ${GITHUB_CLIENT_SECRET}
            scopes: [repo]
            flow: device

    * It takes `Wardrik.start_link/1`'s `:oauth` options, except `page` and `resolver`, which the
      daemon sets.
    * Each provider takes `Wardrik.OAuth.Provider`'s options, and is named after its credential.
    * With `oauth` set, orgs and people can add OAuth apps, even with no `providers`.
  """

  alias WardrikDaemon.Config.Options

  @managed [:page, :providers, :resolver]
  @atoms [:flow, :client_auth]

  @doc "Returns `section` as Wardrik's `:oauth` options, or `nil` without `oauth`."
  @spec read(map() | nil, String.t()) :: {:ok, keyword() | nil} | {:error, String.t()}
  def read(nil, _page), do: {:ok, nil}

  def read(section, page) do
    Options.loaded([Wardrik.OAuth.Provider, Req.Steps])
    {providers, own} = Map.pop(section, "providers", %{})

    with {:ok, own} <- Options.validate(own, schema(), "oauth"),
         {:ok, providers} <- providers(providers) do
      {:ok, [page: page, providers: providers] ++ own}
    end
  end

  defp schema do
    Wardrik.schema().schema
    |> Keyword.fetch!(:oauth)
    |> Keyword.fetch!(:keys)
    |> Options.public(@managed)
  end

  defp providers(providers) when is_map(providers), do: Options.each(providers, &provider/2)

  defp providers(_providers), do: {:error, "oauth.providers: is a provider for each name"}

  defp provider(name, provider) do
    path = "oauth.providers.#{name}"

    schema = Options.public(Wardrik.OAuth.Provider.schema(), [:key])

    with {:ok, opts} <- Options.convert(provider, schema, path),
         opts = Enum.map(opts, &value/1),
         {:ok, _provider} <- Options.built(fn -> built(name, opts) end, path) do
      {:ok, opts}
    end
  end

  # The daemon names each app; see `WardrikDaemon.OAuthApps.key/1`.
  defp built(name, opts) do
    key = WardrikDaemon.OAuthApps.key(%{owner: "deployment", name: to_string(name)})
    Wardrik.OAuth.Provider.new(name, [key: key] ++ opts)
  end

  defp value({key, text}) when key in @atoms, do: {key, Options.atom(text)}
  defp value(option), do: option
end
