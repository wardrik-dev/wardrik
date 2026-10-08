defmodule WardrikOAuth do
  @moduledoc """
  Accounts users connect by authorizing: the `WardrikVault.Grants` module
  that asks a user, or an org, for a grant, and renews the grants it gave.

      children = [
        Wardrik,
        {WardrikVault, keys: [...], grants: WardrikOAuth},
        {WardrikOAuth.Supervisor,
         client: [name: "Wardrik", client_uri: "https://wardrik.dev"],
         providers: [
           github: [
             resource: "https://api.githubcopilot.com/mcp/",
             issuer: "https://github.com/login/oauth",
             client_id: System.get_env("GITHUB_CLIENT_ID"),
             client_secret: System.get_env("GITHUB_CLIENT_SECRET"),
             scopes: ~w(repo)
           ]
         ]}
      ]

      Wardrik.Fleet.spawn(id, config: config, credentials: WardrikVault)

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
      URI. Where that is this machine's loopback the link is opened as the
      flow starts, since there is a browser here; see `WardrikOAuth.Browser`
      and `WardrikOAuth.Loopback`.
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

  @behaviour WardrikVault.Grants

  require Logger

  alias Wardrik.Credential
  alias WardrikOAuth.Browser
  alias WardrikOAuth.Client
  alias WardrikOAuth.Config
  alias WardrikOAuth.Device
  alias WardrikOAuth.Egress
  alias WardrikOAuth.Flow
  alias WardrikOAuth.Loopback
  alias WardrikOAuth.Metadata
  alias WardrikOAuth.Pending
  alias WardrikOAuth.Pending.Flight
  alias WardrikOAuth.Provider
  alias WardrikOAuth.Registrations
  alias WardrikOAuth.Token

  @doc "Whether a provider named `name` is configured, so a user can be asked to authorize it."
  @impl WardrikVault.Grants
  def grants?(name), do: match?({:ok, _provider}, Provider.fetch(name))

  @doc "The credential a token held for `owner` answers with, renewed where it has run out."
  @impl WardrikVault.Grants
  def renew(name, owner, encoded) do
    with {:ok, provider} <- provider(name), do: held(provider, owner, encoded)
  end

  @doc "Asks `owner` to authorize `name`, for a call to park on until they have."
  @impl WardrikVault.Grants
  def ask(name, owner) do
    with {:ok, provider} <- provider(name), do: begin(provider, owner)
  end

  @doc "Treats the token held for `owner` as expired, so the next resolve renews it."
  @impl WardrikVault.Grants
  def refused(name, owner) do
    with {:ok, provider} <- provider(name),
         do: single_flight(provider, owner, fn -> expire(provider, owner) end)

    :ok
  end

  defp expire(provider, owner) do
    case current(provider, owner) do
      %Token{} = token -> store(provider, owner, Token.expire(token))
      nil -> :ok
    end
  end

  @doc """
  The token `owner` holds for a provider, renewing or asking for one as
  needed.

  What resolving does, without a call: for a surface that wants to connect a
  user before an agent ever asks. A secret the vault holds under the
  provider's name for `owner` is not a token, and is left be.
  """
  @spec hold(Provider.t(), term()) :: Credential.outcome()
  def hold(%Provider{} = provider, owner) do
    case WardrikVault.lookup(provider.name, owner) do
      {:ok, :grant, encoded} -> held(provider, owner, encoded)
      {:ok, :secret, _secret} -> {:error, :held_as_a_secret}
      {:error, :not_found} -> begin(provider, owner)
      {:error, :no_key} -> {:error, :no_key}
      {:error, _kind, reason} -> unreadable(provider, owner, reason)
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
  defp unreadable(%Provider{} = provider, owner, reason) do
    Logger.warning(
      "#{provider.name} for #{inspect(owner)} cannot be read (#{tag(reason)}); asking again"
    )

    begin(provider, owner)
  end

  defp tag(reason) when is_atom(reason), do: reason
  defp tag(reason) when is_tuple(reason), do: elem(reason, 0)
  defp tag(_reason), do: :unreadable

  @doc """
  Finishes the flow a callback belongs to and writes the token down.

  `WardrikOAuth.Loopback` calls this; a deployment serving its own redirect URI
  calls it from there instead, with what the callback carried:

    * `:provider` - the provider the callback's path names; a flow for
      another provider is not finished by it
    * `:iss` - the `iss` parameter (RFC 9207), which must name the flow's
      issuer, and must be there where the issuer says it sends one

  Only a browser flow still under way is finished; a device flow waits for
  its code. The token is written before the calls parked on it are told,
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
         :ok <- store(flight.provider, flight.owner, token) do
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

  @doc "Forgets a user's token, so the next call asks them to authorize again."
  @spec disconnect(String.t(), term()) :: :ok | {:error, term()}
  def disconnect(provider, owner), do: WardrikVault.forget(provider, owner)

  @doc "Whether a user has authorized a provider."
  @spec connected?(String.t(), term()) :: boolean()
  def connected?(provider, owner),
    do: match?({:ok, :grant, _token}, WardrikVault.lookup(provider, owner))

  @doc "The providers this deployment can offer, and whether this owner has each."
  @spec connections(term()) :: [%{provider: String.t(), connected?: boolean()}]
  def connections(owner) do
    for provider <- Provider.all() do
      %{provider: provider.name, connected?: connected?(provider.name, owner)}
    end
  end

  @doc """
  The client identity this deployment presents, and the document to serve for
  it, naming every provider's redirect URI.
  """
  @spec document() :: map()
  def document do
    uris = Provider.all() |> Enum.map(&redirect/1) |> Enum.uniq()
    %{Client.document(Client.new()) | "redirect_uris" => uris}
  end

  defp held(provider, owner, encoded) do
    case Token.decode(encoded) do
      {:ok, %Token{} = token} ->
        if Token.fresh?(token, System.system_time(:second)),
          do: {:ok, credential(token, owner)},
          else: renew(provider, owner)

      {:error, reason} ->
        unreadable(provider, owner, reason)
    end
  end

  defp renew(provider, owner) do
    case single_flight(provider, owner, fn -> refresh(provider, owner) end) do
      {:ok, %Token{} = fresh} ->
        {:ok, credential(fresh, owner)}

      :ask ->
        Logger.info("#{provider.name} could not be renewed for #{inspect(owner)}; asking again")
        begin(provider, owner)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Run holding the renewal lock. The token is read again first: whoever held
  # the lock before may have renewed it already.
  defp refresh(provider, owner) do
    case current(provider, owner) do
      nil -> :ask
      %Token{} = token -> refresh(provider, owner, token)
    end
  end

  defp refresh(provider, owner, %Token{} = token) do
    cond do
      Token.fresh?(token, System.system_time(:second)) ->
        {:ok, token}

      not Token.renewable?(token) ->
        :ask

      true ->
        token
        |> Flow.refresh(refresh_options(provider, token))
        |> refreshed(provider, owner, token)
    end
  end

  defp refreshed({:ok, fresh}, provider, owner, _token) do
    with :ok <- store(provider, owner, fresh), do: {:ok, fresh}
  end

  defp refreshed({:error, {:token_refused, "invalid_grant", _}}, _provider, _owner, _token),
    do: :ask

  defp refreshed({:error, {:token_refused, "invalid_client", _}}, provider, _owner, token) do
    :ok = Registrations.forget(provider.name, token.issuer, redirect(provider), token.client_id)
    :ask
  end

  defp refreshed({:error, reason}, _provider, _owner, _token), do: {:error, reason}

  # A token from the issuer the deployment named is renewed under its trust,
  # and with the provider's secret where it was issued to the provider's own
  # client. Any other is renewed as a discovered server, with no secret.
  defp refresh_options(%Provider{} = provider, %Token{} = token) do
    named? = is_binary(provider.issuer) and provider.issuer == token.issuer
    secret = if named? and token.client_id == provider.client_id, do: provider.client_secret

    [trust: if(named?, do: :operator, else: :discovered), client_secret: secret]
  end

  defp single_flight(%Provider{name: name}, owner, fun) do
    case :global.trans({{__MODULE__, name, owner}, self()}, fun, [node() | Node.list()], 20) do
      :aborted -> {:error, :renewing}
      result -> result
    end
  end

  defp current(provider, owner) do
    with {:ok, :grant, encoded} <- WardrikVault.lookup(provider.name, owner),
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
  defp begin(%Provider{} = provider, owner) do
    single_flight(provider, owner, fn ->
      case Pending.under_way(provider.name, owner) do
        {:ok, %Flight{} = flight} -> {:error, required(flight)}
        :error -> open(provider, owner)
      end
    end)
  end

  defp required(%Flight{url: url, user_code: code, owner: owner}),
    do: {:authorization_required, %{url: url, code: code}, owner}

  defp open(%Provider{} = provider, owner) do
    with {:ok, metadata, registered} <- prepare(provider),
         {:ok, flow} <- flow(provider, metadata) do
      flight = %Flight{
        state: Flow.state(),
        provider: provider,
        owner: owner,
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
      opened(url, metadata.trust)

      {:error, required(flight)}
    else
      {:error, {:no_pkce, metadata.issuer}}
    end
  end

  defp open(:device, %Flight{} = flight) do
    request =
      Device.request(flight.metadata, flight.registered,
        scopes: scopes(flight.provider, flight.metadata)
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
  defp flow(%Provider{flow: :browser}, %Metadata{}), do: {:ok, :browser}

  defp flow(%Provider{flow: :device}, %Metadata{} = metadata) do
    if Device.offered?(metadata),
      do: {:ok, :device},
      else: {:error, {:no_device_flow, metadata.issuer}}
  end

  defp flow(%Provider{flow: :auto}, %Metadata{} = metadata) do
    if Device.offered?(metadata) and loopback?() and not Browser.available?(),
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
    case store(flight.provider, flight.owner, token) do
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
  # that, not as the user the token is kept for.
  defp connected(%Flight{provider: %Provider{name: name}, owner: owner}) do
    by = Wardrik.Principal.new(:oauth, name, name: "#{name} authorization")
    Credential.available(name, owner, by: by)
  end

  # A flow whose callback comes back to this machine has a browser on it. One
  # answering somewhere else does not, and opens nothing. Only a URL Egress
  # allows is opened, so a server cannot have another program launched.
  defp opened(url, trust) do
    if Keyword.get(Config.redirect(), :open, loopback?()) and Egress.check(url, trust) == :ok,
      do: Browser.open(url)
  end

  defp loopback?, do: is_nil(Keyword.get(Config.redirect(), :uri))

  # A client registered dynamically before, for this issuer and redirect URI,
  # is used again; a new one is kept.
  defp prepare(%Provider{} = provider) do
    client = Client.new(redirect_uri: redirect(provider))

    with {:ok, metadata} <- Metadata.discover(provider.resource, issuer: provider.issuer),
         {:ok, registered} <- registered(provider, metadata, client) do
      {:ok, metadata, registered}
    end
  end

  defp registered(provider, metadata, client) do
    known =
      case Registrations.fetch(provider.name, metadata.issuer, redirect(provider)) do
        {:ok, registered} -> registered
        :error -> nil
      end

    with {:ok, registered} <- Flow.register(metadata, client, provider, known: known) do
      if registered.how == :dynamic and is_nil(known),
        do: Registrations.put(provider.name, metadata.issuer, registered)

      {:ok, registered}
    end
  end

  defp exchange(%Flight{} = flight, code),
    do: Flow.exchange(flight.metadata, flight.registered, code, flight.verifier)

  # A server that no longer knows a client registered dynamically has it
  # forgotten, so the next flow registers again.
  defp forget_client(
         %Flight{registered: %{how: :dynamic} = registered} = flight,
         {:error, {:token_refused, "invalid_client", _description}}
       ) do
    Registrations.forget(
      flight.provider.name,
      flight.metadata.issuer,
      registered.redirect_uri,
      registered.client_id
    )
  end

  defp forget_client(_flight, _trouble), do: :ok

  defp store(%Provider{} = provider, owner, %Token{} = token) do
    WardrikVault.put(provider.name, owner, Token.encode(token), kind: :grant)
  end

  defp provider(name) do
    case Provider.fetch(name) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, {:no_such_provider, name}}
    end
  end

  defp scopes(%Provider{} = provider, %Metadata{} = metadata), do: Flow.scopes(provider, metadata)

  # A provider's own redirect URI where it names one, the deployment's where
  # it serves one, and otherwise the loopback path of the provider's own.
  defp redirect(%Provider{redirect_uri: uri}) when is_binary(uri), do: uri

  defp redirect(%Provider{name: name}),
    do: Keyword.get(Config.redirect(), :uri) || Loopback.redirect_uri(name)
end
