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
      `openapi` is an OpenAPI 3 document's, in JSON or YAML. An API has one or the other.
    * Each API is a tool group of the same name: an agent file lists `tools: [ga4]` and gets
      `ga4__properties_runReport` and the rest.
    * `auth` gives each scheme the description names a source: `{credential: NAME}`, a person's
      sign-in to the OAuth provider `NAME`, or `{key: NAME}`, a key sealed `--for api_key`. See
      `WardrikDaemon.Keys`. `headers` takes the same, or a string.
    * `schemes` adds schemes the description doesn't name, each `bearer`, `{header: NAME}` or
      `{query: NAME}`, sent on every operation before its own.
    * It takes `WardrikRest.API`'s options too, except `name`, `egress` and `req_options`.
      `timeout` is in seconds.
    * An API no entry in `orgs` lists is the deployment's org's.
  """

  alias WardrikDaemon.Config.Options

  @managed [:name, :egress, :req_options]

  @readers %{"discovery" => :discovery, "openapi" => :openapi}

  @enforce_keys [:reader, :location, :options]
  defstruct [:reader, :location, :options]

  @typedoc """
  An API: the format of its description, where that is, and `WardrikRest.API.load/2`'s options.
  """
  @type t() :: %__MODULE__{
          reader: :discovery | :openapi,
          location: String.t(),
          options: keyword()
        }

  @doc "Returns the APIs `section` names, or the key that doesn't read."
  @spec read(map()) :: {:ok, [{String.t(), t()}]} | {:error, String.t()}
  def read(section), do: Options.each(section, &api/2)

  defp api(name, %{} = api) do
    case Enum.filter(@readers, fn {key, _reader} -> is_binary(api[key]) end) do
      [{key, reader}] ->
        read(name, reader, api[key], Map.delete(api, key))

      _none_or_both ->
        {:error,
         "rest.#{name}: is an API's keys, with one discovery or openapi document it's described by"}
    end
  end

  defp api(name, _api),
    do:
      {:error,
       "rest.#{name}: is an API's keys, with one discovery or openapi document it's described by"}

  defp read(name, reader, location, api) do
    path = "rest.#{name}"
    schema = Options.public(WardrikRest.API.schema(), @managed)

    with {:ok, opts} <- Options.convert(api, schema, path),
         {:ok, auth} <- sources(Keyword.get(opts, :auth, %{}), "#{path}.auth", &source/1),
         {:ok, headers} <- sources(Keyword.get(opts, :headers, %{}), "#{path}.headers", &header/1),
         {:ok, schemes} <- places(Keyword.get(opts, :schemes, %{}), "#{path}.schemes"),
         opts =
           opts
           |> Keyword.merge(auth: auth, headers: headers, schemes: schemes)
           |> Enum.map(&option/1),
         {:ok, opts} <- Options.checked(opts, schema, path) do
      {:ok, %__MODULE__{reader: reader, location: location, options: opts}}
    end
  end

  defp places(map, path) when is_map(map) do
    with {:ok, read} <- Options.each(map, &placed(&1, place(&2), path)), do: {:ok, Map.new(read)}
  end

  defp places(_other, path), do: {:error, "#{path}: is a place for each name"}

  defp placed(_name, {:ok, place}, _path), do: {:ok, place}

  defp placed(name, :error, path),
    do: {:error, "#{path}.#{name}: is bearer, {header: NAME} or {query: NAME}"}

  defp place("bearer"), do: {:ok, :bearer}
  defp place(%{"header" => name}) when is_binary(name), do: {:ok, {:header, name}}
  defp place(%{"query" => name}) when is_binary(name), do: {:ok, {:query, name}}
  defp place(_other), do: :error

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
