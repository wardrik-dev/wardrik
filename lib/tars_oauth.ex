defmodule TarsOAuth do
  @moduledoc """
  A `Tars.Credential` resolver that gets its secrets by asking the user.

      config :tars, TarsOAuth,
        client: [name: "Tars", client_uri: "https://tars.dev"],
        providers: [
          github: [
            resource: "https://api.githubcopilot.com/mcp/",
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
  where the server supports one, else dynamic registration. Discovery is
  `TarsOAuth.Metadata`, the token is `TarsOAuth.Token`, and a token that has
  expired is refreshed before the user is asked for anything.

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
  alias TarsOAuth.Flow
  alias TarsOAuth.Loopback
  alias TarsOAuth.Metadata
  alias TarsOAuth.Pending
  alias TarsOAuth.Pending.Flight
  alias TarsOAuth.Provider
  alias TarsOAuth.Token

  @impl Tars.Credential
  def resolve({kind, name} = ref, %Scope{} = scope) when kind in [:user, :org] do
    with {:ok, provider} <- provider(name),
         {:ok, owner} <- owner(ref, scope) do
      hold(provider, owner)
    end
  end

  def resolve(ref, %Scope{}), do: {:error, {:unknown_reference, ref}}

  @doc """
  The token a user holds for a provider, renewing or asking for one as needed.

  What `resolve/2` does, without a scope: for a surface that wants to connect a
  user before an agent ever asks.
  """
  @spec hold(Provider.t(), term()) :: Credential.outcome()
  def hold(%Provider{} = provider, owner) do
    case Config.tokens().fetch(provider.name, owner) do
      {:ok, encoded} -> held(provider, owner, encoded)
      {:error, :not_found} -> begin(provider, owner)
      {:error, reason} -> unreadable(provider, owner, reason)
    end
  end

  # A token nothing can read is a token nobody has: a key that has been
  # rotated away, or something else written where a token belongs. The user is
  # asked again rather than left with an error they cannot act on.
  # The expiry travels with the token, so anything holding a connection open
  # around it knows when to stop and ask for another.
  defp credential(%Token{} = token) do
    Credential.secret(token.access_token, expires_at: token.expires_at)
  end

  defp unreadable(%Provider{} = provider, owner, reason) do
    Logger.warning("#{provider.name} for #{inspect(owner)} cannot be read (#{inspect(reason)})")
    Config.tokens().forget(provider.name, owner)

    begin(provider, owner)
  end

  @doc """
  Finishes the flow a callback belongs to and writes the token down.

  `TarsOAuth.Loopback` calls this; a deployment serving its own redirect URI
  calls it from there instead.

  The token is written before the call parked on it is answered, so the turn
  that carries on finds the credential it asked for. A callback that cannot be
  turned into a token leaves the flow where it was, so the same link still
  works and the calls parked on it are still answered when one does.

  A flow is held by the node that started it. One this node did not start is
  finished on whichever connected node did, where the calls parked on it
  wait.
  """
  @spec finish(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def finish(state, code) when is_binary(state) and is_binary(code) do
    case finish_here(state, code) do
      {:error, :no_such_flow} -> finish_elsewhere(state, code)
      finished -> finished
    end
  end

  @doc false
  @spec finish_here(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def finish_here(state, code) do
    with {:ok, %Flight{} = flight} <- claim(state), do: complete(flight, code)
  end

  defp finish_elsewhere(state, code) do
    Enum.find_value(Node.list(), {:error, :no_such_flow}, &finish_on(&1, state, code))
  end

  # A node that does not hold the flow, or cannot be asked, answers nil.
  defp finish_on(node, state, code) do
    case :erpc.call(node, __MODULE__, :finish_here, [state, code], :timer.seconds(30)) do
      {:error, :no_such_flow} -> nil
      finished -> finished
    end
  catch
    :error, {:erpc, _reason} -> nil
    :error, {:exception, _reason, _stack} -> nil
  end

  # The flow is claimed before the token is asked for, and the calls parked on
  # it travel with it, so a flow that gets no token goes back rather than
  # taking them with it.
  defp complete(%Flight{} = flight, code) do
    with {:ok, token} <- exchange(flight, code),
         :ok <- store(flight.provider, flight.owner, token) do
      Logger.info("#{flight.provider.name} authorized for #{inspect(flight.owner)}")
      resume(flight)

      {:ok, flight.provider.name}
    else
      trouble ->
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

  @doc "The client identity this deployment presents, and the document to serve for it."
  @spec document() :: map()
  def document, do: redirect_uri() |> then(&Client.new(redirect_uri: &1)) |> Client.document()

  defp held(provider, owner, encoded) do
    case Token.decode(encoded) do
      {:ok, %Token{} = token} ->
        if Token.fresh?(token, System.system_time(:second)),
          do: {:ok, credential(token)},
          else: renew(provider, owner, token)

      {:error, reason} ->
        unreadable(provider, owner, reason)
    end
  end

  defp renew(provider, owner, %Token{} = token) do
    with true <- Token.renewable?(token),
         {:ok, metadata, registered} <- prepare(provider),
         {:ok, fresh} <-
           Flow.refresh(metadata, registered, token, req_options: Config.req_options()),
         :ok <- store(provider, owner, fresh) do
      {:ok, credential(fresh)}
    else
      _no ->
        Logger.info("#{provider.name} could not be renewed for #{inspect(owner)}; asking again")
        begin(provider, owner)
    end
  end

  # A flow already under way is offered again rather than restarted: an agent
  # retrying a parked call should keep showing the same link, or code.
  defp begin(%Provider{} = provider, owner) do
    resume = Credential.continuation()

    case Pending.under_way(provider.name, owner, resume) do
      {:ok, %Flight{} = flight} -> {:error, required(flight)}
      :error -> open(provider, owner, resume)
    end
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

  defp open(:browser, %Flight{} = flight) do
    {verifier, challenge} = Flow.pkce()

    url =
      Flow.authorize_url(flight.metadata, flight.registered, challenge,
        state: flight.state,
        scopes: scopes(flight.provider, flight.metadata)
      )

    opened(url)
    {:ok, url} = Pending.start(%{flight | verifier: verifier, url: url})

    {:error, {:authorization_required, url}}
  end

  defp open(:device, %Flight{} = flight) do
    request =
      Device.request(flight.metadata, flight.registered,
        scopes: scopes(flight.provider, flight.metadata),
        req_options: Config.req_options()
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
        "To connect #{flight.provider.name} for #{inspect(flight.owner)}, " <>
          "enter #{device.user_code} at #{url}"
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

  # Asks the token endpoint every interval the server named whether the user
  # has entered the code, until they have, refused, or let it expire. The
  # token is written down, and the calls parked on it answered, as a
  # callback's would be.
  defp poll(%Flight{} = flight, %Device{} = device) do
    deadline = flight.started_at + flight.expires_after
    poll(flight, device, :timer.seconds(device.interval), deadline)
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
        else:
          Device.poll(flight.metadata, flight.registered, device,
            req_options: Config.req_options()
          )

    case polled do
      {:ok, %Token{} = token} ->
        authorized(flight, token)
        done(flight, :authorized)

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
      resume(flight)
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
  # answering somewhere else does not, and opens nothing.
  defp opened(url) do
    if Keyword.get(Config.redirect(), :open, loopback?()), do: Browser.open(url)
  end

  defp loopback?, do: is_nil(Keyword.get(Config.redirect(), :uri))

  defp prepare(%Provider{} = provider) do
    client = Client.new(redirect_uri: redirect_uri(), req_options: Config.req_options())

    with {:ok, metadata} <- discover(provider),
         {:ok, registered} <- Flow.register(metadata, client, provider) do
      {:ok, metadata, registered}
    end
  end

  defp discover(%Provider{} = provider) do
    Metadata.discover(provider.resource,
      issuer: provider.issuer,
      req_options: Config.req_options()
    )
  end

  defp exchange(%Flight{} = flight, code) do
    Flow.exchange(flight.metadata, flight.registered, code, flight.verifier,
      req_options: Config.req_options()
    )
  end

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

  defp owner({_kind, _name}, %Scope{user: nil}), do: {:error, :no_user}
  defp owner({_kind, _name}, %Scope{user: user}), do: {:ok, user}

  defp scopes(%Provider{scopes: []}, %Metadata{scopes_supported: supported}), do: supported
  defp scopes(%Provider{scopes: scopes}, %Metadata{}), do: scopes

  defp redirect_uri, do: Keyword.get(Config.redirect(), :uri) || Loopback.redirect_uri()
end
