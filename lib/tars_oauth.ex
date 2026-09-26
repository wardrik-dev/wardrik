defmodule TarsOAuth do
  @moduledoc """
  A `Tars.Credential` resolver that gets its secrets by asking the user.

      config :tars, TarsOAuth,
        client: [name: "Tars", client_uri: "https://tars.dev"],
        providers: [
          github: [
            resource: "https://api.githubcopilot.com/mcp/",
            issuer: "https://github.com/login/oauth",
            client_id: System.get_env("GITHUB_CLIENT_ID"),
            client_secret: System.get_env("GITHUB_CLIENT_SECRET"),
            scopes: ~w(repo)
          ]
        ]

      children = [TarsOAuth.Supervisor]

      Tars.Fleet.spawn("assistant", config: config, credentials: TarsOAuth)

  `{:user, "github"}` then resolves to that user's access token. A user who
  has not authorized yet is asked to, a tool parks on the answer, and the
  parked call runs again with the token in hand once they have, with nobody
  approving it. They authorize one of two ways, as the provider's `:flow`
  says; see `TarsOAuth.Provider`:

    * in a browser: `{:error, {:authorization_required, url}}`, a link that
      comes back to this deployment's redirect URI. Where that is this
      machine's loopback the link is opened as the flow starts, since there is
      a browser here; see `TarsOAuth.Browser` and `TarsOAuth.Loopback`.
    * on another device: `{:error, {:authorization_required, url, code}}`, a
      code to enter at the server's page, from a phone or any browser at all,
      while a task here asks the server whether they have; see
      `TarsOAuth.Device`. Nothing comes back to this machine, so a daemon on a
      server with no browser and no open port can be authorized from
      anywhere.

  By default a provider whose server offers the device grant is authorized
  that way where a browser flow could not finish, on a machine with no
  browser whose redirect is its own loopback, and in a browser everywhere
  else.

  `[:tars_oauth, :device, :done]` is emitted as a device flow ends, with the
  provider, the owner, and `:authorized` or why not as its metadata.

  Tokens are kept by a `TarsOAuth.Tokens` module, `TarsOAuth.Tokens.Vault` by
  default: sealed by `TarsVault`, inside the customer's network. Tars is not a
  broker and holds no other tenant's tokens.

  ## What it does per server

  `TarsOAuth.Flow` takes the least work a server will accept: a `:client_id`
  the deployment registered by hand, else the client's metadata document URL
  where the server supports one, else dynamic registration, kept in
  `TarsOAuth.Registrations` so it happens once. Discovery is
  `TarsOAuth.Metadata`, and every request goes through `TarsOAuth.Egress`. A
  browser flow wants a server that takes a SHA-256 PKCE challenge.

  ## Renewing

  A token that has expired, or that a server refused (`c:Tars.Credential.refused/2`),
  is refreshed before the user is asked for anything, at the token endpoint
  it came from, as the client it was issued to (`TarsOAuth.Token`). One
  process in the cluster renews a user's token for a provider at a time, and
  the others use what it wrote. A server that says the refresh token is no
  longer good starts a new flow; one that cannot be reached fails the call,
  and the next one tries again.

  A token that cannot be read, sealed under a key rotated away, starts a new
  flow and is replaced once the user finishes; it is never deleted. A vault
  with no key is an error, and starts nothing.

  ## Extracting this package

  When OAuth moves out into `tars_oauth`, `lib/tars_oauth/` and
  `test/tars_oauth/` move into a project declaring `{:tars, "~> 0.1"}`,
  `{:tars_vault, "~> 0.1", optional: true}` and `{:req, "~> 0.7"}`, and
  `TarsOAuth.Config` reads `config :tars_oauth` instead.
  """

  @behaviour Tars.Credential

  require Logger

  alias Tars.Credential
  alias Tars.Scope
  alias TarsOAuth.Browser
  alias TarsOAuth.Client
  alias TarsOAuth.Config
  alias TarsOAuth.Device
  alias TarsOAuth.Egress
  alias TarsOAuth.Flow
  alias TarsOAuth.Loopback
  alias TarsOAuth.Metadata
  alias TarsOAuth.Pending
  alias TarsOAuth.Pending.Flight
  alias TarsOAuth.Provider
  alias TarsOAuth.Registrations
  alias TarsOAuth.Token

  @impl Tars.Credential
  def resolve({kind, name} = ref, %Tars.Call{scope: %Scope{} = scope} = call)
      when kind in [:user, :org] do
    with {:ok, provider} <- provider(name),
         {:ok, owner} <- owner(ref, scope) do
      hold(provider, owner, Credential.continuation(call, flow_principal(provider)))
    end
  end

  def resolve(ref, %Tars.Call{}), do: {:error, {:unknown_reference, ref}}

  # Whoever finishes a flow is known only as the flow itself: the provider's
  # authorization, not the user the token is kept for.
  defp flow_principal(%Provider{name: name}),
    do: %Tars.Principal{type: :oauth, id: name, name: "#{name} authorization"}

  @doc "Treats the token held for `ref` as expired, so the next resolve renews it."
  @impl Tars.Credential
  def refused({kind, name} = ref, %Tars.Call{scope: %Scope{} = scope})
      when kind in [:user, :org] do
    with {:ok, provider} <- provider(name),
         {:ok, owner} <- owner(ref, scope) do
      single_flight(provider, owner, fn -> expire(provider, owner) end)
    end

    :ok
  end

  def refused(_ref, %Tars.Call{}), do: :ok

  defp expire(provider, owner) do
    case current(provider, owner) do
      %Token{} = token -> store(provider, owner, Token.expire(token))
      nil -> :ok
    end
  end

  @doc """
  The token a user holds for a provider, renewing or asking for one as needed.

  What `resolve/2` does, without a call: for a surface that wants to connect a
  user before an agent ever asks. `resume` is applied once the user has
  connected, where one is given.
  """
  @spec hold(Provider.t(), term(), Credential.continuation() | nil) :: Credential.outcome()
  def hold(%Provider{} = provider, owner, resume \\ nil) do
    case Config.tokens().fetch(provider.name, owner) do
      {:ok, encoded} -> held(provider, owner, encoded, resume)
      {:error, :not_found} -> begin(provider, owner, resume)
      {:error, :no_key} -> {:error, :no_key}
      {:error, reason} -> unreadable(provider, owner, reason, resume)
    end
  end

  # The expiry travels with the token, so anything holding a connection open
  # around it knows when to stop and ask for another.
  defp credential(%Token{} = token) do
    Credential.secret(token.access_token, expires_at: token.expires_at)
  end

  # A token nothing can read, sealed under a key rotated away or written in
  # another shape, is asked for again and replaced when the user finishes. It
  # is left where it is until then.
  defp unreadable(%Provider{} = provider, owner, reason, resume) do
    Logger.warning(
      "#{provider.name} for #{inspect(owner)} cannot be read (#{tag(reason)}); asking again"
    )

    begin(provider, owner, resume)
  end

  defp tag(reason) when is_atom(reason), do: reason
  defp tag(reason) when is_tuple(reason), do: elem(reason, 0)
  defp tag(_reason), do: :unreadable

  @doc """
  Finishes the flow a callback belongs to and writes the token down.

  `TarsOAuth.Loopback` calls this; a deployment serving its own redirect URI
  calls it from there instead, with what the callback carried:

    * `:provider` - the provider the callback's path names; a flow for
      another provider is not finished by it
    * `:iss` - the `iss` parameter (RFC 9207), which must name the flow's
      issuer, and must be there where the issuer says it sends one

  Only a browser flow still under way is finished; a device flow waits for
  its code. The token is written before the call parked on it is answered, so
  the turn that carries on finds the credential it asked for. A callback that
  cannot be turned into a token leaves the flow where it was, so the same
  link still works. Once one flow for a user and provider finishes, any other
  under way on this node for them is dropped.

  A flow is held by the node that started it. One this node did not start is
  finished on whichever connected node did, all of them asked at once.
  """
  @spec finish(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def finish(state, code, opts \\ []) when is_binary(state) and is_binary(code) do
    case finish_here(state, code, opts) do
      {:error, :no_such_flow} -> finish_elsewhere(state, code, opts)
      finished -> finished
    end
  end

  @doc false
  @spec finish_here(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def finish_here(state, code, opts) do
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

  defp finish_elsewhere(state, code, opts) do
    Node.list()
    |> :erpc.multicall(__MODULE__, :finish_here, [state, code, opts], :timer.seconds(20))
    |> Enum.find_value({:error, :no_such_flow}, fn
      {:ok, {:error, :no_such_flow}} -> nil
      {:ok, finished} -> finished
      _unreachable -> nil
    end)
  end

  # The flow is claimed before the token is asked for, and the calls parked on
  # it travel with it, so a flow that gets no token goes back rather than
  # taking them with it.
  defp complete(%Flight{} = flight, code) do
    with {:ok, token} <- exchange(flight, code),
         :ok <- store(flight.provider, flight.owner, token) do
      Logger.info("#{flight.provider.name} authorized for #{inspect(flight.owner)}")
      Pending.drop(flight.provider.name, flight.owner)
      resume(flight)

      {:ok, flight.provider.name}
    else
      trouble ->
        forget_client(flight, trouble)
        {:ok, _url} = Pending.start(flight)

        trouble
    end
  end

  @doc "Forgets a user's token, so the next call asks them to authorize again."
  @spec disconnect(String.t(), term()) :: :ok | {:error, term()}
  def disconnect(provider, owner), do: Config.tokens().forget(provider, owner)

  @doc "Whether a user has authorized a provider."
  @spec connected?(String.t(), term()) :: boolean()
  def connected?(provider, owner), do: Config.tokens().has?(provider, owner)

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

  defp held(provider, owner, encoded, resume) do
    case Token.decode(encoded) do
      {:ok, %Token{} = token} ->
        if Token.fresh?(token, System.system_time(:second)),
          do: {:ok, credential(token)},
          else: renew(provider, owner, resume)

      {:error, reason} ->
        unreadable(provider, owner, reason, resume)
    end
  end

  defp renew(provider, owner, resume) do
    case single_flight(provider, owner, fn -> refresh(provider, owner) end) do
      {:ok, %Token{} = fresh} ->
        {:ok, credential(fresh)}

      :ask ->
        Logger.info("#{provider.name} could not be renewed for #{inspect(owner)}; asking again")
        begin(provider, owner, resume)

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
    with {:ok, encoded} <- Config.tokens().fetch(provider.name, owner),
         {:ok, %Token{} = token} <- Token.decode(encoded) do
      token
    else
      _none -> nil
    end
  end

  # A flow already under way is offered again rather than restarted: an agent
  # retrying a parked call should keep showing the same link, or code. Flows
  # begin one at a time for a user and provider, so two calls parking at once
  # share one.
  defp begin(%Provider{} = provider, owner, resume) do
    single_flight(provider, owner, fn ->
      case Pending.under_way(provider.name, owner, resume) do
        {:ok, %Flight{} = flight} -> {:error, required(flight)}
        :error -> open(provider, owner, resume)
      end
    end)
  end

  defp required(%Flight{user_code: nil, url: url}), do: {:authorization_required, url}
  defp required(%Flight{user_code: code, url: url}), do: {:authorization_required, url, code}

  defp open(%Provider{} = provider, owner, resume) do
    with {:ok, metadata, registered} <- prepare(provider),
         {:ok, flow} <- flow(provider, metadata) do
      flight = %Flight{
        state: Flow.state(),
        provider: provider,
        owner: owner,
        metadata: metadata,
        registered: registered,
        url: nil,
        started_at: System.monotonic_time(:millisecond),
        resumes: List.wrap(resume)
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
          scopes: scopes(flight.provider, metadata)
        )

      {:ok, url} = Pending.start(%{flight | verifier: verifier, url: url})
      opened(url, metadata.trust)

      {:error, {:authorization_required, url}}
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

      {:ok, _url} = Pending.start(flight)

      {:ok, _poller} =
        Task.Supervisor.start_child(TarsOAuth.Tasks, fn -> poll(flight, device) end)

      Logger.info(
        "A device flow for #{flight.provider.name} started for #{inspect(flight.owner)}"
      )

      {:error, {:authorization_required, url, device.user_code}}
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

  # Asks the token endpoint every interval the server named, and never more
  # often than the floor, whether the user has entered the code, until they
  # have, refused, or let it expire. A server that cannot be reached, or
  # fails, is asked again at the next interval. The token is written down,
  # and the calls parked on it answered, as a callback's would be.
  defp poll(%Flight{} = flight, %Device{} = device) do
    deadline = flight.started_at + flight.expires_after
    poll(flight, device, max(:timer.seconds(device.interval), Config.poll_floor()), deadline)
  end

  defp poll(%Flight{} = flight, %Device{} = device, interval, deadline) do
    wait = min(interval, max(deadline - System.monotonic_time(:millisecond), 0))

    receive do
    after
      wait -> :ok
    end

    polled =
      if System.monotonic_time(:millisecond) >= deadline,
        do: {:error, :expired},
        else: Device.poll(flight.metadata, flight.registered, device)

    case polled do
      {:ok, %Token{} = token} ->
        done(flight, authorized(flight, token))

      {:retry, reason} ->
        Logger.info("#{flight.provider.name} could not be polled (#{tag(reason)}); asking again")
        poll(flight, device, interval, deadline)

      {:error, reason} ->
        Pending.drop(flight.state)

        Logger.warning(
          "#{flight.provider.name} was not connected for #{inspect(flight.owner)}: #{inspect(reason)}"
        )

        done(flight, reason)

      waiting ->
        poll(flight, device, Device.next_interval(waiting, interval), deadline)
    end
  end

  defp done(%Flight{} = flight, outcome) do
    :telemetry.execute([:tars_oauth, :device, :done], %{}, %{
      provider: flight.provider.name,
      owner: flight.owner,
      outcome: outcome
    })
  end

  defp authorized(%Flight{} = flight, %Token{} = token) do
    with {:ok, %Flight{} = flight} <- claim(flight.state),
         :ok <- store(flight.provider, flight.owner, token) do
      Logger.info("#{flight.provider.name} authorized for #{inspect(flight.owner)}")
      Pending.drop(flight.provider.name, flight.owner)
      resume(flight)
      :authorized
    else
      {:error, reason} ->
        Logger.warning(
          "#{flight.provider.name} was authorized for #{inspect(flight.owner)}, " <>
            "but the token could not be kept (#{tag(reason)})"
        )

        {:error, reason}
    end
  end

  # A flow started outside a parked call has nothing to answer, and a turn
  # answered already says so rather than failing the callback.
  defp resume(%Flight{} = flight), do: Enum.each(flight.resumes, &answer(&1, flight))

  defp answer({module, function, args}, %Flight{} = flight) do
    case apply(module, function, args) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Logger.warning(
          "#{flight.provider.name} was authorized, but the agent waiting on it is not running " <>
            "here; its call is still parked"
        )

      {:error, reason} ->
        Logger.info("#{flight.provider.name}: nothing parked (#{reason})")
    end
  catch
    kind, reason ->
      Logger.warning(
        "#{flight.provider.name} was authorized, but a call waiting on it could not be " <>
          "answered: #{Exception.format(kind, reason, __STACKTRACE__)}"
      )

      :ok
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

  defp claim(state) do
    case Pending.claim(state) do
      {:ok, flight} -> {:ok, flight}
      :error -> {:error, :no_such_flow}
    end
  end

  defp store(%Provider{} = provider, owner, %Token{} = token) do
    Config.tokens().put(provider.name, owner, Token.encode(token))
  end

  defp provider(name) do
    case Provider.fetch(name) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, {:no_such_provider, name}}
    end
  end

  # A user's token is kept for the org and the user together; an org's for the
  # org alone.
  defp owner({:user, _name}, %Scope{user: nil}), do: {:error, :no_user}
  defp owner({:user, _name}, %Scope{org: org, user: user}), do: {:ok, {org, user}}
  defp owner({:org, _name}, %Scope{org: nil}), do: {:error, :no_org}
  defp owner({:org, _name}, %Scope{org: org}), do: {:ok, {org, nil}}

  defp scopes(%Provider{} = provider, %Metadata{} = metadata), do: Flow.scopes(provider, metadata)

  # A provider's own redirect URI where it names one, the deployment's where
  # it serves one, and otherwise the loopback path of the provider's own.
  defp redirect(%Provider{redirect_uri: uri}) when is_binary(uri), do: uri

  defp redirect(%Provider{name: name}),
    do: Keyword.get(Config.redirect(), :uri) || Loopback.redirect_uri(name)
end
