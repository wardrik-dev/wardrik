defmodule WardrikDaemon.Config.Rest do
  @moduledoc """
  Reads `config.yaml`'s `rest`: HTTP APIs agents may call, from their descriptions.

      rest:
        ga4:
          discovery: https://analyticsdata.googleapis.com/$discovery/rest?version=v1beta
          base_url: https://analyticsdata.googleapis.com/
          auth: {oauth2: {credential: google}}
          only: [properties_runReport, properties_getMetadata]
          read_only: [properties_runReport]

    * `discovery` is a Google Discovery document's URL, or its path from the config directory.
    * Each API is a tool group of the same name: an agent file lists `tools: [ga4]` and gets
      `ga4__properties_runReport` and the rest.
    * `auth` gives each scheme the description names a source: `{credential: NAME}`, a person's
      sign-in to the OAuth provider `NAME`, or `{key: NAME}`, a key sealed `--for api_key`. See
      `WardrikDaemon.Keys`. `headers` takes
      the same, or a string.
    * It takes `WardrikRest.API`'s options too, except `name`, `egress` and `req_options`.
      `timeout` is in seconds.
    * An API no entry in `orgs` lists is the deployment's org's.
  """

  alias WardrikDaemon.Config.Options

  @managed [:name, :egress, :req_options]

  @enforce_keys [:discovery, :options]
  defstruct [:discovery, :options]

  @typedoc "An API: where its description is, and `WardrikRest.API.load/2`'s options."
  @type t() :: %__MODULE__{discovery: String.t(), options: keyword()}

  @doc "Returns the APIs `section` names, or the key that doesn't read."
  @spec read(map()) :: {:ok, [{String.t(), t()}]} | {:error, String.t()}
  def read(section), do: Options.each(section, &api/2)

  defp api(name, %{"discovery" => discovery} = api) when is_binary(discovery) do
    path = "rest.#{name}"
    schema = Options.public(WardrikRest.API.schema(), @managed)

    with {:ok, opts} <- Options.convert(Map.delete(api, "discovery"), schema, path),
         {:ok, auth} <- sources(Keyword.get(opts, :auth, %{}), "#{path}.auth", &source/1),
         {:ok, headers} <- sources(Keyword.get(opts, :headers, %{}), "#{path}.headers", &header/1),
         opts = Keyword.merge(opts, auth: auth, headers: headers) |> Enum.map(&option/1),
         {:ok, opts} <- Options.checked(opts, schema, path) do
      {:ok, %__MODULE__{discovery: discovery, options: opts}}
    end
  end

  defp api(name, _api),
    do: {:error, "rest.#{name}: is an API's keys, with the discovery document it's described by"}

  defp sources(map, path, read) when is_map(map) do
    with {:ok, read} <- Options.each(map, &sourced(&1, read.(&2), path)), do: {:ok, Map.new(read)}
  end

  defp sources(_other, path, _read), do: {:error, "#{path}: is a source for each name"}

  defp sourced(_name, {:ok, source}, _path), do: {:ok, source}

  defp sourced(name, :error, path),
    do: {:error, "#{path}.#{name}: is {credential: NAME} or {key: NAME}"}

  defp source(%{"credential" => name}) when is_binary(name), do: {:ok, {:credential, name}}
  defp source(%{"key" => name}) when is_binary(name), do: {:ok, {:key, name}}
  defp source(_other), do: :error

  defp header(value) when is_binary(value), do: {:ok, value}
  defp header(value), do: source(value)

  defp option({:timeout, seconds}) when is_number(seconds), do: {:timeout, round(seconds * 1000)}
  defp option(option), do: option
end
