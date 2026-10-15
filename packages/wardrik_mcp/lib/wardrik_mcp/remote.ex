defmodule WardrikMCP.Remote do
  @moduledoc """
  An MCP server an owner added for their own agents, as it is kept in the
  store: its `Wardrik.Servers.Key`, its URL, how its agents sign in to it,
  and which of its tools they take.

  It is reached over Streamable HTTP alone: a command would run on the
  deployment's own machine, so only the deployment's configuration names
  one. It serves its owner's agents and no others, waits on a person for
  every tool it does not mark `readOnlyHint`, and what it answers is
  labelled `"outside"`; an owner sets none of that, so the deployment's
  policies decide what relaxes it.

  `server/2` is the `WardrikMCP.Server` it is reached as, whose own
  connection stops after a quarter of an hour with no call through it.
  """

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Servers.Key
  alias WardrikMCP.Auth
  alias WardrikMCP.Server

  @ns :mcp_servers
  @fields ~w(url auth only except)
  @idle_after :timer.minutes(15)

  @enforce_keys [:key, :url, :auth, :filters]
  defstruct [:key, :url, :auth, :filters]

  @type t() :: %__MODULE__{
          key: Key.t(),
          url: String.t(),
          auth: Auth.t(),
          filters: [only: [String.t()], except: [String.t()]]
        }

  @doc """
  The server `key` names, from `fields` as a request gave them: its `url`,
  its `auth`, and the `only` and `except` lists of its tools' own names.
  """
  @spec decode(Key.t(), map()) :: {:ok, t()} | {:error, String.t()}
  def decode(%Key{} = key, fields) when is_map(fields) do
    with :ok <- named(key.name),
         :ok <- known(fields),
         {:ok, url} <- url(fields["url"]),
         {:ok, auth} <- auth(fields["auth"]),
         {:ok, filters} <- filters(fields) do
      {:ok, %__MODULE__{key: key, url: url, auth: auth, filters: filters}}
    end
  end

  @doc """
  What its owner's agents reach it as: over HTTP, serving them alone, with
  what it lists kept in `:store` for the next connection that starts.
  """
  @spec server(t(), store: WardrikStore.t()) :: Server.t()
  def server(%__MODULE__{} = remote, store: store) do
    Server.new(
      remote.key,
      [
        transport: {:streamable_http, base_url: remote.url},
        serves: [remote.key.owner],
        store: store,
        idle_after: @idle_after
      ] ++ Auth.options(remote.auth) ++ remote.filters
    )
  end

  @doc """
  Whether `url` may be reached for an owner: `https`, at a host whose every
  address is public, as `WardrikOAuth.Egress` checks a URL a server named.

  Checked as a server is added and as each node starts its connection, not
  for each request the connection makes, so a host whose name resolves
  elsewhere between the two is reached where it resolves then.
  """
  @spec reachable(String.t()) :: :ok | {:error, term()}
  def reachable(url) do
    case WardrikOAuth.Egress.options(url, :discovered) do
      {:ok, _options} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Keeps `remote`, unless its owner has a server by its name already."
  @spec put(WardrikStore.t(), t()) :: :ok | {:error, :conflict}
  def put(store, %__MODULE__{key: key} = remote) do
    case WardrikStore.put(store, @ns, to_string(key), remote, if_vsn: nil) do
      {:ok, _vsn} -> :ok
      {:error, :conflict} -> {:error, :conflict}
    end
  end

  @doc "The server `key` names, where its owner added it."
  @spec fetch(WardrikStore.t(), Key.t()) :: {:ok, t()} | :error
  def fetch(store, %Key{} = key) do
    case WardrikStore.get(store, @ns, to_string(key)) do
      %__MODULE__{} = remote -> {:ok, remote}
      nil -> :error
    end
  end

  @doc "The servers `owner` added, by name."
  @spec list(WardrikStore.t(), Prefix.t()) :: [t()]
  def list(store, owner) do
    under = to_string(owner)

    for text <- WardrikStore.keys(store, @ns, under),
        not String.contains?(String.replace_prefix(text, under, ""), "/"),
        remote = WardrikStore.get(store, @ns, text),
        do: remote
  end

  @doc "Forgets the server `key` names."
  @spec delete(WardrikStore.t(), Key.t()) :: :ok | {:error, :not_found}
  def delete(store, %Key{} = key) do
    case fetch(store, key) do
      {:ok, _remote} -> WardrikStore.delete(store, @ns, to_string(key))
      :error -> {:error, :not_found}
    end
  end

  defp named(name) do
    if name =~ ~r/^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$/ and not String.contains?(name, "__"),
      do: :ok,
      else:
        {:error,
         "#{inspect(name)} is not a server's name: letters, digits, - and _, up to 32, never __"}
  end

  defp known(fields) do
    case Map.keys(fields) -- @fields do
      [] ->
        :ok

      [field | _rest] ->
        {:error, "#{field} is not a server's field; one is #{Enum.join(@fields, ", ")}"}
    end
  end

  defp url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> {:ok, url}
      _other -> {:error, "#{url} is not an https URL"}
    end
  end

  defp url(_url), do: {:error, "a server is added with its url"}

  defp auth(%{"none" => none}) when none == %{}, do: {:ok, %Auth.None{}}

  defp auth(%{"secret" => %{"name" => name} = secret}) when is_binary(name) and name != "" do
    with {:ok, header} <- text(secret, "header", "authorization"),
         {:ok, scheme} <- text(secret, "scheme", "Bearer") do
      {:ok, %Auth.Secret{name: name, header: header, scheme: scheme}}
    end
  end

  defp auth(_auth),
    do: {:error, ~s(auth is {"none": {}}, or {"secret": {"name": ...}} naming a vault secret)}

  defp text(fields, key, default) do
    case Map.get(fields, key, default) do
      text when is_binary(text) -> {:ok, text}
      _other -> {:error, "auth's secret #{key} is text"}
    end
  end

  defp filters(fields) do
    with {:ok, only} <- names(fields, :only),
         {:ok, except} <- names(fields, :except),
         do: {:ok, only ++ except}
  end

  # The filter `field` sets, where the request sets one.
  defp names(fields, field) do
    case Map.fetch(fields, Atom.to_string(field)) do
      :error ->
        {:ok, []}

      {:ok, names} when is_list(names) ->
        if(text?(names), do: {:ok, [{field, names}]}, else: listed(field))

      {:ok, _other} ->
        listed(field)
    end
  end

  defp text?(names), do: Enum.all?(names, &is_binary/1)

  defp listed(field), do: {:error, "#{field} lists the server's own names of its tools, as text"}
end
