defmodule WardrikOAuth do
  @moduledoc """
  Accounts users connect by authorizing: the settings every flow runs
  with, and the `WardrikVault.Grants` that ask a user, or an org, for a
  grant, and renew the grants they gave. A vault grants through them, and
  the host's credentials are that vault:

      oauth =
        WardrikOAuth.new(
          client: [name: "Wardrik", client_uri: "https://wardrik.dev"],
          redirect: [url: "https://agents.example.com/oauth"],
          providers: [
            github: [
              resource: "https://api.githubcopilot.com/mcp/",
              issuer: "https://github.com/login/oauth",
              client_id: System.get_env("GITHUB_CLIENT_ID"),
              client_secret: System.get_env("GITHUB_CLIENT_SECRET"),
              scopes: ~w(repo)
            ]
          ]
        )

      vault = WardrikVault.new(store: store, keys: keys, grants: oauth)
      host = Wardrik.new(store: store, credentials: vault) |> WardrikOAuth.attach(oauth: oauth)

  A credential named `github` that the vault holds for nobody the call
  reaches is then asked for: of the call's user, or of its org where it has
  no user. A tool parks on the answer,
  `{:error, {:authorization_required, link, owner}}`. Once they have
  authorized, the token is kept in the vault as a grant for whoever did, and
  `Wardrik.Credential.available/3` carries the parked call on, with nobody
  approving it; the token is the credential their calls resolve from then
  on. They authorize one of two ways, as the provider's `:flow` says; see
  `WardrikOAuth.Provider`:

    * in a browser: a link that comes back to this deployment's redirect
      URL. Where that is this machine's loopback the link is opened as the
      flow starts, since there is a browser here; where it is a URL the
      deployment serves over HTTPS, a browser anywhere comes back to it. See
      `WardrikOAuth.Browser` and `WardrikOAuth.Callback`.
    * on another device: a code to enter at the server's page, from a phone
      or any browser at all, while the flow's process here asks the server
      whether they have; see `WardrikOAuth.Device`. Nothing comes back to this machine, so
      a daemon on a server with no browser and no open port can be
      authorized from anywhere.

  By default a provider whose server offers the device grant is authorized
  that way where a browser flow could not finish, on a machine with no
  browser whose redirect is its own loopback, and in a browser everywhere
  else.

  `[:wardrik_oauth, :device, :done]` is emitted as a device flow ends, with the
  provider, the owner, and `:authorized` or why not as its metadata.

  Tokens are kept in `WardrikVault`, sealed, inside the customer's network.
  Wardrik is not a broker and holds no other tenant's tokens.

  `attach/2` has the host serve the pages a browser comes back to, and run
  the flows, and `config/1` reads `config.yaml`'s `oauth` into the options
  `new/1` takes.

  ## What it does per server

  `WardrikOAuth.Flow` takes the least work a server will accept: a `:client_id`
  the deployment registered by hand, else the client's metadata document URL
  where the server supports one, else dynamic registration, kept in
  `WardrikOAuth.Registrations` so it happens once. Discovery is
  `WardrikOAuth.Metadata`, and every request goes through `WardrikOAuth.Egress`. A
  browser flow wants a server that takes a SHA-256 PKCE challenge.

  ## Renewing

  A token that has expired, or that a server refused (`c:WardrikVault.Grants.refused/2`),
  is refreshed before the user is asked for anything, at the token endpoint
  it came from, as the client it was issued to (`WardrikOAuth.Token`). One
  process in the cluster renews a user's token for a provider at a time, and
  the others use what it wrote. A server that says the refresh token is no
  longer good starts a new flow; one that cannot be reached fails the call,
  and the next one tries again.

  A token that cannot be read, sealed under a key rotated away, starts a new
  flow and is replaced once the user finishes; it is never deleted. A vault
  with no key is an error, and starts nothing.
  """

  @behaviour Wardrik.Plugin

  require Logger

  alias Wardrik.Credential
  alias WardrikOAuth.Browser
  alias WardrikOAuth.Callback
  alias WardrikOAuth.Client
  alias WardrikOAuth.Device
  alias WardrikOAuth.Egress
  alias WardrikOAuth.Flow
  alias WardrikOAuth.Metadata
  alias WardrikOAuth.Pending
  alias WardrikOAuth.Pending.Flight
  alias WardrikOAuth.Provider
  alias WardrikOAuth.Registrations
  alias WardrikOAuth.Token

  @enforce_keys []
  defstruct client: [],
            providers: [],
            added: %WardrikOAuth.Providers.None{},
            redirect: [],
            req_options: [],
            resolve: &Egress.resolve/1,
            poll_floor: :timer.seconds(5),
            audit: Wardrik.Audit

  @typedoc """
  What every flow runs with:

  | Key | What it is |
  | --- | --- |
  | `:client` | the identity this deployment presents, see `WardrikOAuth.Client` |
  | `:providers` | what a user can authorize, see `WardrikOAuth.Provider` |
  | `:added` | providers added beyond those, each for an owner, see `WardrikOAuth.Providers` |
  | `:redirect` | where a code comes back to: `:url`, `:open`, `:opener`; see `WardrikOAuth.Callback` |
  | `:req_options` | merged into every request |
  | `:resolve` | answers a host's addresses, `WardrikOAuth.Egress.resolve/1` by default |
  | `:poll_floor` | the fewest milliseconds between two polls of a device flow, 5 seconds by default |
  | `:audit` | the `Wardrik.Audit` log a connection is recorded in, the host's `Wardrik.Host.audit/1` |
  """
  @type t() :: %__MODULE__{
          client: keyword(),
          providers: keyword(),
          added: WardrikOAuth.Providers.t(),
          redirect: keyword(),
          req_options: keyword(),
          resolve: (String.t() -> {:ok, [:inet.ip_address()]} | {:error, term()}),
          poll_floor: non_neg_integer(),
          audit: GenServer.name()
        }

  @client ~w(name document_url client_uri logo_uri policy_uri tos_uri)a
  @redirect ~w(url open)a
  @provider ~w(resource issuer client_id client_secret scopes authorization_params flow)a
  @keys Map.new(@client ++ @redirect ++ @provider, &{Atom.to_string(&1), &1})

  # The settings a plugin builds its WardrikOAuth from, in place of `:oauth`.
  @settings ~w(client redirect providers req_options resolve poll_floor)a

  @doc """
  `host` serving the pages a browser comes back to from a sign-in, under
  its redirect URL, among its routes (see `WardrikOAuth.Callback.pages/1`),
  and running `WardrikOAuth.Supervisor`, the flows under way, among its
  children.

  As a plugin, it takes the settings `new/1` does: `:providers`,
  `:redirect` and `:client`, and `:req_options`, `:resolve` and
  `:poll_floor`. It keeps each token in the host's vault, which grants
  through it, and offers its providers as the accounts people connect. On
  an instance, it signs in to what its other plugins register as well, such
  as the servers people add (`WardrikOAuth.Providers.Registered`):

      config :my_app, MyApp.Agents,
        store: [repo: MyApp.Repo],
        vault: [keys: [System.fetch_env!("WARDRIK_VAULT_KEY")]],
        plugins: [
          {WardrikOAuth,
           redirect: [url: "https://myapp.example.com/agents/oauth"],
           providers: [
             github: [
               resource: "https://api.githubcopilot.com/mcp/",
               issuer: "https://github.com/login/oauth",
               client_id: System.fetch_env!("GITHUB_CLIENT_ID"),
               client_secret: System.fetch_env!("GITHUB_CLIENT_SECRET"),
               scopes: ~w(repo)
             ]
           ]}
        ]

  A host that builds its seams itself passes `oauth:`, a `WardrikOAuth`
  it wired them with, and gets the pages and the flows alone.
  """
  @spec attach(Wardrik.Host.t(), keyword()) :: Wardrik.Host.t()
  @impl true
  def attach(%Wardrik.Host{} = host, opts) do
    opts = Keyword.validate!(opts, [:oauth | @settings])
    {oauth, settings} = Keyword.pop(opts, :oauth)
    served(host, oauth, settings)
  end

  defp served(host, %__MODULE__{} = oauth, []), do: serving(host, oauth)

  defp served(host, nil, settings) do
    oauth = new([audit: Wardrik.Host.audit(host), added: registered(host)] ++ settings)
    vault = %{vault!(host) | grants: oauth}

    host
    |> Wardrik.Host.put(:credentials, vault)
    |> Wardrik.Host.put(:connections, %WardrikOAuth.Connections{oauth: oauth, vault: vault})
    |> serving(oauth)
  end

  defp served(_host, _oauth, _settings),
    do: raise(ArgumentError, "WardrikOAuth takes :oauth, or the settings to build one, not both")

  defp serving(host, oauth) do
    host
    |> Wardrik.Host.register(:routes, Callback.pages(oauth))
    |> Wardrik.Host.register(:settings, [{__MODULE__, oauth: oauth}])
    |> Wardrik.Host.child({WardrikOAuth.Supervisor, []})
  end

  defp registered(host) do
    case Wardrik.Instance.of(host) do
      nil -> %WardrikOAuth.Providers.None{}
      instance -> %WardrikOAuth.Providers.Registered{instance: instance}
    end
  end

  defp vault!(host) do
    case Wardrik.Host.credentials(host) do
      %WardrikVault{} = vault ->
        vault

      _none ->
        raise ArgumentError,
              "WardrikOAuth keeps the tokens people sign in with in a vault; " <>
                "give the instance one, as vault: [keys: [System.fetch_env!(\"WARDRIK_VAULT_KEY\")]]"
    end
  end

  @doc """
  `:ok` where a plugin's `opts` name a redirect URL a provider may send a
  browser back to and providers each as `new/1` takes them, or why not.
  """
  @spec validate(keyword()) :: :ok | {:error, String.t()}
  @impl true
  def validate(opts) do
    url = opts[:redirect][:url]

    cond do
      not Keyword.keyword?(opts[:providers] || []) ->
        {:error, "providers is a keyword list, each provider by its name"}

      not is_binary(url) ->
        {:error, "redirect names the URL a sign-in comes back to, as redirect: [url: url]"}

      not Callback.redirect?(url) ->
        {:error,
         "#{url} is not one a provider sends a browser back to: https, or http on loopback"}

      true ->
        :ok
    end
  end

  @doc """
  Reads `config.yaml`'s `oauth`, its `client`, `redirect` and `providers`,
  into the options `new/1` takes, or the key that does not read, as a path
  within the section, and why. A redirect URL is https, or http on this
  machine's loopback; see `WardrikOAuth.Callback.redirect?/1`.
  """
  @spec config(map() | nil) :: {:ok, keyword()} | {:error, [String.t()], String.t()}
  def config(nil), do: {:ok, []}

  def config(%{} = section) do
    known!(section, ~w(client redirect providers), [])
    {:ok, Enum.map(section, &setting!/1)}
  catch
    {:invalid, path, message} -> {:error, path, message}
  end

  def config(_section), do: {:error, [], "is a set of keys"}

  defp setting!({"client", client}), do: {:client, options!(client, @client, ["client"])}

  defp setting!({"redirect", redirect}) do
    {:redirect,
     Enum.map(options!(redirect, @redirect, ["redirect"]), fn
       {:url, url} -> {:url, url!(url)}
       {:open, open} when is_boolean(open) -> {:open, open}
       {:open, _open} -> invalid!(["redirect", "open"], "is true or false")
     end)}
  end

  defp setting!({"providers", providers}) do
    {:providers,
     for {name, provider} <- table!(providers, ["providers"]) do
       path = ["providers", name]

       # reach:disable-next-line unsafe_atom_creation -- config.yaml's own provider names
       {String.to_atom(name),
        provider
        |> options!(@provider, path)
        |> flow!(path)
        |> secret!(path)
        |> authorization_params!(path)}
     end}
  end

  defp url!(url) do
    if is_binary(url) and Callback.redirect?(url),
      do: String.trim_trailing(url, "/"),
      else:
        invalid!(
          ["redirect", "url"],
          "is an https:// URL, or http:// on loopback, with no query or fragment"
        )
  end

  defp flow!(provider, path) do
    case Keyword.fetch(provider, :flow) do
      {:ok, flow} when flow in ["auto", "browser", "device"] ->
        Keyword.put(provider, :flow, Provider.flow!(flow))

      {:ok, _flow} ->
        invalid!(path ++ ["flow"], "is auto, browser or device")

      :error ->
        provider
    end
  end

  defp secret!(provider, path) do
    if Keyword.has_key?(provider, :client_secret) and not Keyword.has_key?(provider, :issuer),
      do:
        invalid!(
          path ++ ["client_secret"],
          "is sent only to an issuer the provider names; add issuer"
        ),
      else: provider
  end

  defp authorization_params!(provider, path) do
    path = path ++ ["authorization_params"]

    case Keyword.fetch(provider, :authorization_params) do
      {:ok, params} when is_map(params) ->
        Keyword.put(provider, :authorization_params, Map.new(params, &param!(&1, path)))

      {:ok, _params} ->
        invalid!(path, "is a table of names to the values to send")

      :error ->
        provider
    end
  end

  defp param!({name, value}, path) do
    cond do
      name in Flow.own_params() -> invalid!(path ++ [name], "is one Wardrik sets itself")
      is_binary(value) or is_number(value) or is_boolean(value) -> {name, to_string(value)}
      true -> invalid!(path ++ [name], "is a string, a number or true or false")
    end
  end

  defp options!(table, keys, path) do
    table = table!(table, path)
    known!(table, Enum.map(keys, &Atom.to_string/1), path)
    Enum.map(table, fn {key, value} -> {@keys[key], value} end)
  end

  defp table!(nil, _path), do: %{}
  defp table!(%{} = table, _path), do: table
  defp table!(_value, path), do: invalid!(path, "is a set of keys")

  defp known!(table, keys, path) do
    case Map.keys(table) -- keys do
      [] ->
        :ok

      [key | _] ->
        invalid!(path ++ [key], "is not a setting; expected one of #{Enum.join(keys, ", ")}")
    end
  end

  defp invalid!(path, message), do: throw({:invalid, path, message})

  @doc "The settings `opts` name, each one left out at its default; see `t:t/0`."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    keys = __MODULE__ |> struct() |> Map.from_struct() |> Map.keys()
    struct!(__MODULE__, Keyword.validate!(opts, keys))
  end

  @doc "Whether `oauth` configures any provider."
  @spec configured?(t()) :: boolean()
  def configured?(%__MODULE__{providers: providers}), do: providers != []

  @doc "The options every request to a server takes under `oauth`: its `:req_options` and `:resolve`."
  @spec requests(t()) :: keyword()
  def requests(%__MODULE__{} = oauth),
    do: [req_options: oauth.req_options, resolve: oauth.resolve]

  @doc false
  def grants?(oauth, name, owner),
    do: match?({:ok, _provider}, Provider.fetch(oauth, name, owner))

  @doc false
  def renew(oauth, name, owner, opts) do
    with {:ok, provider} <- provider(oauth, name, owner),
         do: held(oauth, vault(opts), provider, owner, Keyword.fetch!(opts, :value))
  end

  @doc false
  def ask(oauth, name, owner, opts) do
    with {:ok, provider} <- provider(oauth, name, owner),
         do: begin(oauth, vault(opts), provider, owner)
  end

  @doc false
  def refused(oauth, name, owner, opts) do
    vault = vault(opts)

    with {:ok, provider} <- provider(oauth, name, owner),
         do: single_flight(provider, owner, fn -> expire(vault, provider, owner) end)

    :ok
  end

  defp vault(opts), do: Keyword.fetch!(opts, :vault)

  defp expire(vault, provider, owner) do
    case current(vault, provider, owner) do
      %Token{} = token -> keep(vault, provider, owner, Token.expire(token))
      nil -> :ok
    end
  end

  @doc """
  The token `owner` holds for a provider, renewing or asking for one as
  needed.

  What resolving does, without a call: for a surface that wants to connect a
  user before an agent ever asks. A secret the vault holds under the
  provider's name for `owner` is not a token, and is left be. `:by` is who
  asked, whom the token is recorded in the audit as stored by once it is.
  The token is kept in the `:vault` `opts` name.
  """
  @spec hold(t(), Provider.t(), term(), vault: WardrikVault.t(), by: Wardrik.Principal.t() | nil) ::
          Credential.outcome()
  def hold(%__MODULE__{} = oauth, %Provider{} = provider, owner, opts) do
    vault = vault(opts)

    case WardrikVault.lookup(vault, provider.name, owner) do
      {:ok, :grant, encoded} -> held(oauth, vault, provider, owner, encoded)
      {:ok, :secret, _secret} -> {:error, :held_as_a_secret}
      {:error, :not_found} -> begin(oauth, vault, provider, owner, opts[:by])
      {:error, :no_key} -> {:error, :no_key}
      {:error, _kind, reason} -> unreadable(oauth, vault, provider, owner, reason)
      {:error, reason} -> {:error, reason}
    end
  end

  # The expiry travels with the token, so anything holding a connection open
  # around it knows when to stop and ask for another.
  defp credential(%Token{} = token, owner) do
    Credential.secret(token.access_token, expires_at: token.expires_at, owner: owner)
  end

  # A token nothing can read, sealed under a key rotated away or written in
  # another shape, is asked for again and replaced when the user finishes. It
  # is left where it is until then.
  defp unreadable(oauth, vault, %Provider{} = provider, owner, reason) do
    Logger.warning(
      "#{provider.name} for #{inspect(owner)} cannot be read (#{tag(reason)}); asking again"
    )

    begin(oauth, vault, provider, owner)
  end

  defp tag(reason) when is_atom(reason), do: reason
  defp tag(reason) when is_tuple(reason), do: elem(reason, 0)
  defp tag(_reason), do: :unreadable

  @doc """
  Finishes the flow a callback belongs to and writes the token down.

  `WardrikOAuth.Callback` calls this; a deployment serving its own redirect URI
  calls it from there instead, with what the callback carried:

    * `:provider` - the provider the callback's path names; a flow for
      another provider is not finished by it
    * `:iss` - the `iss` parameter (RFC 9207), which must name the flow's
      issuer, and must be there where the issuer says it sends one

  Only a browser flow still under way is finished; a device flow waits for
  its code. The token is written, to the vault the flow was begun with,
  before the calls parked on it are told,
  through `Wardrik.Credential.available/3`, so the turn that carries on finds
  the credential it asked for. A callback that cannot be turned into a token
  leaves the flow where it was, so the same link still works. A flow that
  finishes ends.

  A flow is found by the state it was started with on whichever node it
  runs; see `WardrikOAuth.Pending`.
  """
  @spec finish(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def finish(state, code, opts \\ []) when is_binary(state) and is_binary(code) do
    case Pending.claim(state, &answerable?(&1, opts)) do
      {:ok, %Flight{} = flight} -> complete(flight, code)
      :error -> {:error, :no_such_flow}
    end
  end

  # A callback finishes a browser flow for the provider its path names, and
  # one whose issuer it names where it names one, or must.
  defp answerable?(%Flight{user_code: code}, _opts) when is_binary(code), do: false

  defp answerable?(%Flight{} = flight, opts) do
    provider = Keyword.get(opts, :provider)

    (is_nil(provider) or provider == flight.provider.name) and
      issued?(flight.metadata, opts[:iss])
  end

  defp issued?(%Metadata{issuer: issuer}, issuer), do: true
  defp issued?(%Metadata{iss_supported?: supported?}, nil), do: not supported?
  defp issued?(%Metadata{}, _other), do: false

  # The flow is claimed before the token is asked for, so a flow that gets no
  # token is released rather than being lost.
  defp complete(%Flight{} = flight, code) do
    with {:ok, token} <- exchange(flight, code),
         :ok <- keep(flight.vault, flight.provider, flight.owner, token) do
      Logger.info("#{flight.provider.name} authorized for #{inspect(flight.owner)}")
      :ok = Pending.drop(flight.provider.name, flight.owner)
      connected(flight)

      {:ok, flight.provider.name}
    else
      trouble ->
        forget_client(flight, trouble)
        :ok = Pending.release(flight.state)

        trouble
    end
  end

  @doc "Forgets a user's token in `vault`, so the next call asks them to authorize again."
  @spec disconnect(WardrikVault.t(), String.t(), term()) :: :ok | {:error, term()}
  def disconnect(vault, provider, owner), do: WardrikVault.forget(vault, provider, owner)

  @doc "Whether a user has authorized a provider, by what `vault` holds."
  @spec connected?(WardrikVault.t(), String.t(), term()) :: boolean()
  def connected?(vault, provider, owner),
    do: match?({:ok, :grant, _token}, WardrikVault.lookup(vault, provider, owner))

  @doc "The providers `oauth` offers, and whether this owner has each in the `:vault` `opts` name."
  @spec connections(t(), term(), vault: WardrikVault.t()) :: [
          %{provider: String.t(), connected?: boolean()}
        ]
  def connections(oauth, owner, opts) do
    for provider <- Provider.all(oauth) do
      %{provider: provider.name, connected?: connected?(vault(opts), provider.name, owner)}
    end
  end

  @doc """
  The client identity this deployment presents, and the document to serve for
  it, naming every provider's redirect URI.
  """
  @spec document(t()) :: map()
  def document(%__MODULE__{} = oauth) do
    uris = oauth |> Provider.names() |> Enum.map(&Callback.redirect_uri(oauth, &1)) |> Enum.uniq()
    %{Client.document(Client.new(oauth.client)) | "redirect_uris" => uris}
  end

  defp held(oauth, vault, provider, owner, encoded) do
    case Token.decode(encoded) do
      {:ok, %Token{} = token} ->
        if Token.fresh?(token, System.system_time(:second)),
          do: {:ok, credential(token, owner)},
          else: renewed(oauth, vault, provider, owner)

      {:error, reason} ->
        unreadable(oauth, vault, provider, owner, reason)
    end
  end

  defp renewed(oauth, vault, provider, owner) do
    case single_flight(provider, owner, fn -> refresh(oauth, vault, provider, owner) end) do
      {:ok, %Token{} = fresh} ->
        {:ok, credential(fresh, owner)}

      :ask ->
        Logger.info("#{provider.name} could not be renewed for #{inspect(owner)}; asking again")
        begin(oauth, vault, provider, owner)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Run holding the renewal lock. The token is read again first: whoever held
  # the lock before may have renewed it already.
  defp refresh(oauth, vault, provider, owner) do
    case current(vault, provider, owner) do
      nil -> :ask
      %Token{} = token -> refresh(oauth, vault, provider, owner, token)
    end
  end

  defp refresh(oauth, vault, provider, owner, %Token{} = token) do
    cond do
      Token.fresh?(token, System.system_time(:second)) ->
        {:ok, token}

      not Token.renewable?(token) ->
        :ask

      true ->
        token
        |> Flow.refresh(refresh_options(oauth, provider, token))
        |> refreshed(oauth, vault, provider, owner, token)
    end
  end

  defp refreshed({:ok, fresh}, _oauth, vault, provider, owner, _token) do
    with :ok <- keep(vault, provider, owner, fresh), do: {:ok, fresh}
  end

  defp refreshed(
         {:error, {:token_refused, "invalid_grant", _}},
         _oauth,
         _vault,
         _provider,
         _owner,
         _token
       ),
       do: :ask

  defp refreshed(
         {:error, {:token_refused, "invalid_client", _}},
         oauth,
         vault,
         provider,
         _owner,
         token
       ) do
    :ok =
      Registrations.forget(vault.store, provider.name,
        issuer: token.issuer,
        redirect_uri: redirect(oauth, provider),
        client_id: token.client_id
      )

    :ask
  end

  defp refreshed({:error, reason}, _oauth, _vault, _provider, _owner, _token),
    do: {:error, reason}

  # A token from the issuer the deployment named is renewed under its trust,
  # and with the provider's secret where it was issued to the provider's own
  # client. Any other is renewed as a discovered server, with no secret.
  defp refresh_options(oauth, %Provider{} = provider, %Token{} = token) do
    named? = is_binary(provider.issuer) and provider.issuer == token.issuer
    secret = if named? and token.client_id == provider.client_id, do: provider.client_secret

    [trust: if(named?, do: :operator, else: :discovered), client_secret: secret] ++
      requests(oauth)
  end

  defp single_flight(%Provider{name: name}, owner, fun) do
    case :global.trans({{__MODULE__, name, owner}, self()}, fun, [node() | Node.list()], 20) do
      :aborted -> {:error, :renewing}
      result -> result
    end
  end

  defp current(vault, provider, owner) do
    with {:ok, :grant, encoded} <- WardrikVault.lookup(vault, provider.name, owner),
         {:ok, %Token{} = token} <- Token.decode(encoded) do
      token
    else
      _none -> nil
    end
  end

  # A flow already under way is offered again rather than restarted: an agent
  # retrying a parked call should keep showing the same link, or code. Flows
  # begin one at a time for a user and provider across the cluster, and one
  # under way on any node is joined, so calls parking at once, on any node,
  # share one.
  defp begin(oauth, vault, %Provider{} = provider, owner, by \\ nil) do
    single_flight(provider, owner, fn ->
      case Pending.under_way(provider.name, owner) do
        {:ok, %Flight{} = flight} -> {:error, required(flight)}
        :error -> open(oauth, vault, provider, owner, by)
      end
    end)
  end

  defp required(%Flight{url: url, user_code: code, owner: owner}),
    do: {:authorization_required, %{url: url, code: code}, owner}

  defp open(oauth, vault, %Provider{} = provider, owner, by) do
    with {:ok, metadata, registered} <- prepare(oauth, vault, provider),
         {:ok, flow} <- flow(oauth, provider, metadata) do
      flight = %Flight{
        oauth: oauth,
        vault: vault,
        state: Flow.state(),
        provider: provider,
        owner: owner,
        by: by,
        metadata: metadata,
        registered: registered,
        url: nil,
        started_at: System.monotonic_time(:millisecond)
      }

      open(flow, flight)
    end
  end

  defp open(:browser, %Flight{metadata: metadata} = flight) do
    if Metadata.pkce?(metadata) do
      {verifier, challenge} = Flow.pkce()

      url =
        Flow.authorize_url(metadata, flight.registered, challenge,
          state: flight.state,
          scopes: scopes(flight.provider, metadata),
          params: flight.provider.authorization_params
        )

      flight = %{flight | verifier: verifier, url: url}
      {:ok, ^url} = Pending.start(flight)
      opened(flight.oauth, url, metadata.trust)

      {:error, required(flight)}
    else
      {:error, {:no_pkce, metadata.issuer}}
    end
  end

  defp open(:device, %Flight{} = flight) do
    request =
      Device.request(
        flight.metadata,
        flight.registered,
        [scopes: scopes(flight.provider, flight.metadata)] ++ requests(flight.oauth)
      )

    with {:ok, %Device{} = device} <- request do
      url = device.verification_uri_complete || device.verification_uri

      flight = %{
        flight
        | user_code: device.user_code,
          url: url,
          expires_after: :timer.seconds(device.expires_in)
      }

      {:ok, _url} = Pending.start(flight, device: device, done: &device_done/2)

      Logger.info(
        "A device flow for #{flight.provider.name} started for #{inspect(flight.owner)}"
      )

      {:error, required(flight)}
    end
  end

  # The provider's flow, where `:auto` is the device grant only where the
  # server offers it and the browser flow could not finish: its redirect
  # comes back to this machine's loopback, and there is no browser here.
  defp flow(_oauth, %Provider{flow: :browser}, %Metadata{}), do: {:ok, :browser}

  defp flow(_oauth, %Provider{flow: :device}, %Metadata{} = metadata) do
    if Device.offered?(metadata),
      do: {:ok, :device},
      else: {:error, {:no_device_flow, metadata.issuer}}
  end

  defp flow(oauth, %Provider{flow: :auto}, %Metadata{} = metadata) do
    if Device.offered?(metadata) and Callback.loopback?(oauth) and
         not Browser.available?(opener: oauth.redirect[:opener]),
       do: {:ok, :device},
       else: {:ok, :browser}
  end

  # How a device flow ended: the token is written down, and the calls parked
  # on it answered, as a callback's would be.
  defp device_done(%Flight{} = flight, {:ok, %Token{} = token}),
    do: done(flight, authorized(flight, token))

  defp device_done(%Flight{} = flight, {:error, reason}) do
    Logger.warning(
      "#{flight.provider.name} was not connected for #{inspect(flight.owner)}: #{inspect(reason)}"
    )

    done(flight, reason)
  end

  defp done(%Flight{} = flight, outcome) do
    :telemetry.execute([:wardrik_oauth, :device, :done], %{}, %{
      provider: flight.provider.name,
      owner: flight.owner,
      outcome: outcome
    })
  end

  defp authorized(%Flight{} = flight, %Token{} = token) do
    case keep(flight.vault, flight.provider, flight.owner, token) do
      :ok ->
        Logger.info("#{flight.provider.name} authorized for #{inspect(flight.owner)}")
        connected(flight)
        :authorized

      {:error, reason} ->
        Logger.warning(
          "#{flight.provider.name} was authorized for #{inspect(flight.owner)}, " <>
            "but the token could not be kept (#{tag(reason)})"
        )

        {:error, reason}
    end
  end

  # Every call parked on the provider for this owner carries on, approved by
  # the authorization that finished: whoever finished it is known only as
  # that, not as the user the token is kept for. The audit names who asked
  # for the connection, where someone did.
  defp connected(%Flight{provider: %Provider{name: name}, owner: owner, by: asked} = flight) do
    by = Wardrik.Principal.new("oauth:" <> name, name: "#{name} authorization")

    :ok =
      Wardrik.Audit.record(
        flight.oauth.audit,
        {:secret_stored, name, owner},
        by: asked || by
      )

    Credential.available(name, owner, by: by)
  end

  # A flow whose callback comes back to this machine has a browser on it. One
  # answering somewhere else does not, and opens nothing. Only a URL Egress
  # allows is opened, so a server cannot have another program launched.
  defp opened(%__MODULE__{redirect: redirect} = oauth, url, trust) do
    if Keyword.get(redirect, :open, Callback.loopback?(oauth)) and
         Egress.check(url, trust) == :ok,
       do: Browser.open(url, opener: redirect[:opener])
  end

  # A client registered dynamically before, for this issuer and redirect URI,
  # is used again; a new one is kept.
  defp prepare(oauth, vault, %Provider{} = provider) do
    client = Client.new(Keyword.put(oauth.client, :redirect_uri, redirect(oauth, provider)))
    discovered = [issuer: provider.issuer, trust: provider.trust] ++ requests(oauth)

    with {:ok, metadata} <- Metadata.discover(provider.resource, discovered),
         {:ok, registered} <- registered(oauth, vault, provider, metadata, client) do
      {:ok, metadata, registered}
    end
  end

  defp registered(oauth, vault, provider, metadata, client) do
    known =
      case Registrations.fetch(vault.store, provider.name,
             issuer: metadata.issuer,
             redirect_uri: redirect(oauth, provider)
           ) do
        {:ok, registered} -> registered
        :error -> nil
      end

    with {:ok, registered} <-
           Flow.register(metadata, client, provider, [known: known] ++ requests(oauth)) do
      if registered.how == :dynamic and is_nil(known),
        do:
          Registrations.put(vault.store, provider.name,
            issuer: metadata.issuer,
            registered: registered
          )

      {:ok, registered}
    end
  end

  defp exchange(%Flight{} = flight, code),
    do:
      Flow.exchange(
        flight.metadata,
        flight.registered,
        code,
        flight.verifier,
        requests(flight.oauth)
      )

  # A server that no longer knows a client registered dynamically has it
  # forgotten, so the next flow registers again.
  defp forget_client(
         %Flight{registered: %{how: :dynamic} = registered} = flight,
         {:error, {:token_refused, "invalid_client", _description}}
       ) do
    Registrations.forget(flight.vault.store, flight.provider.name,
      issuer: flight.metadata.issuer,
      redirect_uri: registered.redirect_uri,
      client_id: registered.client_id
    )
  end

  defp forget_client(_flight, _trouble), do: :ok

  defp keep(vault, %Provider{} = provider, owner, %Token{} = token) do
    WardrikVault.put(vault, provider.name, owner, value: Token.encode(token), kind: :grant)
  end

  defp provider(oauth, name, owner) do
    case Provider.fetch(oauth, name, owner) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, {:no_such_provider, name}}
    end
  end

  defp scopes(%Provider{} = provider, %Metadata{} = metadata), do: Flow.scopes(provider, metadata)

  defp redirect(oauth, %Provider{name: name}), do: Callback.redirect_uri(oauth, name)
end

defimpl WardrikVault.Grants, for: WardrikOAuth do
  defdelegate grants?(oauth, name, owner), to: WardrikOAuth
  defdelegate renew(oauth, name, owner, opts), to: WardrikOAuth
  defdelegate ask(oauth, name, owner, opts), to: WardrikOAuth
  defdelegate refused(oauth, name, owner, opts), to: WardrikOAuth
end
