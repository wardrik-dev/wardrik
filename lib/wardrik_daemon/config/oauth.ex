defmodule WardrikDaemon.Config.OAuth do
  @moduledoc """
  Reads `config.yaml`'s `oauth`: the services people sign in to, and the deployment's providers.

      oauth:
        client_name: Acme agents
        providers:
          github:
            issuer: https://github.com/login/oauth
            client_id: ${GITHUB_CLIENT_ID}
            client_secret: ${GITHUB_CLIENT_SECRET}
            scopes: [repo]
            flow: device
          google:
            issuer: https://accounts.google.com
            client_id: ${GOOGLE_CLIENT_ID}
            client_secret: ${GOOGLE_CLIENT_SECRET}
            authorization_params: {access_type: offline, prompt: consent}

  `oauth` takes Wardrik's `:oauth` options, as `Wardrik.start_link/1` documents them, but `page`,
  which is `base_url` with `/oauth`, and `resolver`, which is `WardrikDaemon.OAuthApps`. Each
  provider is the deployment's OAuth app, named like the credential it grants, and takes
  `WardrikOAuth.Provider`'s options, with `flow` and `client_auth` written as `device`, `basic` and
  so on.

  With `oauth` set, people connect accounts, and orgs and people add OAuth apps of their own, even
  with no `providers` here.
  """

  alias WardrikDaemon.Config.Options

  @managed [:page, :providers, :resolver]
  @atoms [:flow, :client_auth]

  @doc """
  Returns `section` as Wardrik's `:oauth` options, coming back to `page`, with the deployment's
  `:providers`. `nil` without `oauth`.
  """
  @spec read(map() | nil, String.t()) :: {:ok, keyword() | nil} | {:error, String.t()}
  def read(nil, _page), do: {:ok, nil}

  def read(section, page) do
    Options.loaded([WardrikOAuth.Provider, Req.Steps])
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

    with {:ok, opts} <- Options.convert(provider, [], path),
         opts = Enum.map(opts, &value/1),
         {:ok, _provider} <- Options.built(fn -> WardrikOAuth.Provider.new(name, opts) end, path) do
      {:ok, opts}
    end
  end

  defp value({key, text}) when key in @atoms, do: {key, Options.atom(text)}
  defp value(option), do: option
end
