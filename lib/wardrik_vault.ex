defmodule WardrikVault do
  @moduledoc """
  Keeps credentials sealed in a `WardrikStore`, and gives them to WardrikCore agents' tools.

      children = [
        {WardrikStore, store},
        {WardrikVault, name: MyApp.Vault, store: store, keys: [System.fetch_env!("VAULT_KEY")]}
      ]

      WardrikCore.start_agent(
        agent_id: "digest",
        model: "anthropic:claude-haiku-4-5",
        principal: %WardrikCore.Principal{id: "user:jon"},
        credentials: {WardrikVault, MyApp.Vault}
      )

  The vault implements `WardrikCore.Credentials`. A tool gets only what the agent's principal
  holds.

  Functions that take a vault raise `ArgumentError` if it isn't started.
  """

  @behaviour WardrikCore.Credentials

  use GenServer

  require Logger

  alias WardrikCore.Credentials
  alias WardrikCore.Principal
  alias WardrikVault.Grants
  alias WardrikVault.Sealed
  alias WardrikVault.Secret

  @typedoc "A vault, by the name your app gave it."
  @type t() :: atom()

  @typedoc """
  What a value is for. Each is sealed with its value, so it can't be relabelled.

    * `:grant` - an account someone connected by signing in.
    * `:api_key` - a key code calls a service with, such as a model provider's.
    * `:client_secret` - an OAuth app's client secret.
    * `:header` - a value sent in a request header, such as an MCP server's.
    * `:signing_secret` - a secret that signs or checks a webhook.
    * `:token` - a token a chat app gave on install.
    * `:secret` - a secret for no one purpose. Only a fetch that names no `:kind` reads it.

  A fetch that names a kind reads only a value of that kind, so a client secret can never be
  read as an API key.
  """
  @type kind() :: :secret | :grant | purpose()

  @typedoc "A kind that says what a secret is for."
  @type purpose() :: :api_key | :client_secret | :header | :signing_secret | :token

  @kinds [:secret, :grant, :api_key, :client_secret, :header, :signing_secret, :token]

  @typedoc "An option that holds a secret: the secret itself, or `{:secret, name}` for one of the deployment's."
  @type value() :: String.t() | {:secret, String.t()} | nil

  @deployment %Principal{id: "deployment"}

  @doc """
  Starts the vault.

      WardrikVault.start_link(
        name: MyApp.Vault,
        store: store,
        keys: [System.fetch_env!("VAULT_KEY"), System.fetch_env!("OLD_VAULT_KEY")]
      )

  Values are sealed with AES-256-GCM. The first key seals. Any key unseals. To rotate, put a new
  key first and keep the old one until nothing needs it.

  ## Options

    * `:name` - required. What the vault is reached by.
    * `:store` - required. The `WardrikStore` to keep credentials in.
    * `:keys` - base64 keys from `generate_key/0`. `[]` unless set. Without keys, nothing is
      sealed or unsealed. A key that isn't 32 bytes is dropped with a warning.
    * `:grants` - `{module, opts}`, where `module` implements `WardrikVault.Grants`. `nil` unless
      set.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:name, :store, keys: [], grants: nil])
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Seals the secret's value as its `name` for its `principal`. Returns `{:ok, vsn}`, or
  `{:error, :no_key}` without keys.

      {:ok, vsn} =
        WardrikVault.put(MyApp.Vault, %WardrikVault.Secret{
          principal: principal,
          name: "github",
          value: "ghp_..."
        })

  ## Options

    * `:kind` - what it's for. See `t:kind/0`. `:secret` unless set.
    * `:if_vsn` - writes only over this version. See `WardrikStore.put/4`.
  """
  @spec put(t(), Secret.t(), kind: kind(), if_vsn: WardrikStore.vsn()) ::
          {:ok, WardrikStore.vsn()} | {:error, term()}
  def put(vault, secret, opts \\ [])

  def put(vault, %Secret{principal: %Principal{} = principal, name: name, value: value}, opts)
      when is_binary(value) do
    {kind, opts} = Keyword.pop(opts, :kind, :secret)
    unless kind in @kinds, do: raise(ArgumentError, "#{inspect(kind)} isn't a vault kind")
    %{store: store, keys: keys} = settings(vault)
    path = path(principal, name)

    case keys do
      [key | _rest] ->
        WardrikStore.put(store, path, Sealed.seal(value, key: key, path: path, kind: kind), opts)

      [] ->
        {:error, :no_key}
    end
  end

  @doc """
  Returns the value `principal` holds as `name`, unsealed.

      WardrikVault.fetch(MyApp.Vault, principal, "github")
      #=> {:ok, "ghp_..."}

  Returns `{:error, :not_found}` if there's none, and `{:error, :no_key}` without keys.

  ## Options

    * `:kind` - reads the value only if it's of this kind, and returns `{:error, :wrong_kind}`
      otherwise. Name the kind wherever a value is used for one purpose. See `t:kind/0`.
  """
  @spec fetch(t(), Principal.t(), String.t(), kind: kind()) :: {:ok, binary()} | {:error, term()}
  def fetch(vault, principal, name, opts \\ []) do
    kind = Keyword.get(opts, :kind)

    case lookup(vault, principal, name) do
      {:ok, held, value, _vsn} when kind in [nil, held] -> {:ok, value}
      {:ok, _other, _value, _vsn} -> {:error, :wrong_kind}
      {:error, _kind, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns what `principal` holds as `name`, unsealed, with its kind and version.

      WardrikVault.lookup(MyApp.Vault, principal, "github")
      #=> {:ok, :secret, "ghp_...", vsn}

  Returns `{:error, kind, reason}` if the value is there but won't unseal.
  """
  @spec lookup(t(), Principal.t(), String.t()) ::
          {:ok, kind(), binary(), WardrikStore.vsn()}
          | {:error, term()}
          | {:error, kind(), term()}
  def lookup(vault, %Principal{} = principal, name) do
    %{store: store, keys: keys} = settings(vault)
    path = path(principal, name)

    with :ok <- has_keys(keys),
         {%Sealed{} = sealed, vsn} <- WardrikStore.lookup(store, path) do
      unsealed(Sealed.unseal(sealed, keys, path), sealed.kind, vsn)
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the value `principal` holds as `name`, without a running vault.

  Use it to read a secret before the vault starts, such as while reading config. `store` and
  `:keys` are what the vault is started with.

      WardrikVault.read(store, principal, "github", keys: [System.fetch_env!("VAULT_KEY")])
      #=> {:ok, "ghp_..."}
  """
  @spec read(WardrikStore.t(), Principal.t(), String.t(), keys: [String.t()]) ::
          {:ok, binary()} | {:error, term()}
  def read(store, %Principal{} = principal, name, args) do
    keys = Keyword.fetch!(args, :keys)
    path = path(principal, name)

    case WardrikStore.lookup(WardrikStore.scope(store, "wardrik_vault"), path) do
      {%Sealed{} = sealed, _vsn} -> Sealed.unseal(sealed, Sealed.decode_keys(keys), path)
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Returns the principal that holds the deployment's own secrets.

  These are your app's keys, such as a model provider's, and the secrets options name with
  `{:secret, name}`. No agent works for this principal.

      {:ok, _vsn} =
        WardrikVault.put(MyApp.Vault, %WardrikVault.Secret{
          principal: WardrikVault.deployment(),
          name: "SLACK_SIGNING_SECRET",
          value: secret
        })
  """
  @spec deployment() :: Principal.t()
  def deployment, do: @deployment

  @doc """
  Returns the secret an option holds.

      WardrikVault.value(MyApp.Vault, {:secret, "SLACK_SIGNING_SECRET"})
      #=> {:ok, "8f14..."}

      WardrikVault.value(MyApp.Vault, "8f14...")
      #=> {:ok, "8f14..."}

  `{:secret, name}` reads the deployment's secret on each call, so a new one takes effect at once.
  A string or `nil` is returned as it is.
  """
  @spec value(t(), value()) :: {:ok, String.t() | nil} | {:error, term()}
  def value(vault, {:secret, name}) when is_binary(name), do: fetch(vault, @deployment, name)
  def value(_vault, value) when is_binary(value) or is_nil(value), do: {:ok, value}

  @doc "Returns the secret an option holds, as `value/2` does, without a running vault. See `read/4`."
  @spec read_value(WardrikStore.t(), [String.t()], value()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def read_value(store, keys, {:secret, name}) when is_binary(name),
    do: read(store, @deployment, name, keys: keys)

  def read_value(_store, _keys, value) when is_binary(value) or is_nil(value), do: {:ok, value}

  @doc "Removes what `principal` holds as `name`. Returns `:ok`, also when there's nothing to remove."
  @spec delete(t(), Principal.t(), String.t()) :: :ok | {:error, term()}
  def delete(vault, %Principal{} = principal, name),
    do: vault |> settings() |> Map.fetch!(:store) |> WardrikStore.delete(path(principal, name))

  @doc "Returns the names `principal` holds. Needs no key."
  @spec names(t(), Principal.t()) :: [String.t()]
  def names(vault, %Principal{} = principal) do
    vault
    |> list()
    |> Enum.filter(fn {id, _name, _kind} -> id == principal.id end)
    |> Enum.map(fn {_id, name, _kind} -> name end)
  end

  @doc """
  Returns every credential as `{principal_id, name, kind}`. Needs no key.

      WardrikVault.list(MyApp.Vault)
      #=> [{"user:jon", "github", :secret}]

  Names aren't sealed. Anyone who can read the store can see who holds a credential of which name.
  """
  @spec list(t()) :: [{String.t(), String.t(), kind()}]
  def list(vault) do
    %{store: store} = settings(vault)

    store
    |> WardrikStore.keys()
    |> Enum.flat_map(fn path -> listed(store, path) end)
  end

  @doc "Returns a new key, base64-encoded, for `:keys`."
  @spec generate_key() :: String.t()
  defdelegate generate_key, to: Sealed

  @impl WardrikCore.Credentials
  def resolve(%Credentials.Request{principal: nil}, _vault), do: {:error, :no_principal}

  def resolve(%Credentials.Request{name: name, principal: principal}, vault) do
    request = %Grants.Request{vault: vault, name: name, principal: principal}

    case lookup(vault, principal, name) do
      {:ok, :secret, value, _vsn} ->
        {:ok, value}

      {:ok, :grant, value, vsn} ->
        grants(:renew, %{request | grant: %{value: value, vsn: vsn}})

      {:error, :not_found} ->
        grants(:ask, request)

      {:error, :grant, reason} ->
        ask_again(request, reason)

      {:error, _kind, reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl WardrikCore.Credentials
  def refused(%Credentials.Request{principal: nil}, _vault), do: :ok

  def refused(%Credentials.Request{name: name, principal: principal}, vault) do
    case lookup(vault, principal, name) do
      {:ok, :grant, _value, _vsn} ->
        grants(:refused, %Grants.Request{vault: vault, name: name, principal: principal})

      _secret_or_none ->
        :ok
    end
  end

  @impl GenServer
  def init(opts) do
    keys = Keyword.fetch!(opts, :keys)
    decoded = Sealed.decode_keys(keys)
    if length(decoded) < length(keys), do: Logger.warning("A vault key isn't 32 bytes of base64")

    settings = %{
      store: opts |> Keyword.fetch!(:store) |> WardrikStore.scope("wardrik_vault"),
      keys: decoded,
      grants: Keyword.fetch!(opts, :grants)
    }

    table =
      :ets.new(table(Keyword.fetch!(opts, :name)), [
        :named_table,
        :protected,
        read_concurrency: true
      ])

    true = :ets.insert(table, {:settings, settings})
    {:ok, table}
  end

  defp settings(vault) do
    [{:settings, settings}] = :ets.lookup(table(vault), :settings)
    settings
  rescue
    ArgumentError ->
      reraise ArgumentError,
              "#{inspect(vault)} isn't started. Add {WardrikVault, name: #{inspect(vault)}, store: store, keys: keys} to your supervision tree, ahead of what uses it.",
              __STACKTRACE__
  end

  defp table(vault), do: Module.concat(vault, "Settings")

  defp has_keys([]), do: {:error, :no_key}
  defp has_keys(_keys), do: :ok

  defp unsealed({:ok, value}, kind, vsn), do: {:ok, kind, value, vsn}
  defp unsealed({:error, reason}, kind, _vsn), do: {:error, kind, reason}

  defp ask_again(%Grants.Request{name: name, principal: principal} = request, reason) do
    Logger.warning(
      "#{name} for #{principal.id} can't be unsealed (#{inspect(reason)}), so asking again"
    )

    grants(:ask, request)
  end

  defp grants(callback, %Grants.Request{vault: vault} = request) do
    case settings(vault).grants do
      {module, opts} -> apply(module, callback, [request, opts])
      nil -> nothing_granted(callback)
    end
  end

  defp nothing_granted(:refused), do: :ok
  defp nothing_granted(_renew_or_ask), do: {:error, :not_found}

  defp listed(store, path) do
    case {String.split(path, "/"), WardrikStore.lookup(store, path)} do
      {[id, name], {%Sealed{kind: kind}, _vsn}} -> [{decode(id), decode(name), kind}]
      _other -> []
    end
  end

  defp path(%Principal{id: id}, name) when is_binary(name), do: encode(id) <> "/" <> encode(name)

  defp encode(segment), do: URI.encode_www_form(segment)
  defp decode(segment), do: URI.decode_www_form(segment)
end
