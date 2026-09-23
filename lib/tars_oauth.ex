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

  `{:user, "github"}` then resolves to that user's access token, and a user who
  has not authorized yet gets `{:error, {:authorization_required, url}}` — a
  tool parks on that, and approving the parked call runs it again with the
  token in hand. Where the callback comes back to this machine the link is
  opened in a browser as the flow starts, since there is one there; see
  `TarsOAuth.Browser`.

  What is stored is stored by `TarsVault`: sealed, in the store the fleet
  already runs on, inside the customer's network. Tars is not a broker and
  holds no other tenant's tokens.

  ## What it does per server

  `TarsOAuth.Flow` takes the least work a server will accept: a `:client_id`
  the deployment registered by hand, else the client's metadata document URL
  where the server supports one, else dynamic registration. Discovery is
  `TarsOAuth.Metadata`, the token is `TarsOAuth.Token`, and a token that has
  expired is refreshed before the user is asked for anything.

  ## Extracting this package

  When OAuth moves out into `tars_oauth`, `lib/tars_oauth/` and
  `test/tars_oauth/` move into a project declaring `{:tars, "~> 0.1"}`,
  `{:tars_vault, "~> 0.1"}` and `{:req, "~> 0.7"}`, and the setting becomes
  `config :tars_oauth, providers: [...]`.
  """

  @behaviour Tars.Credential

  require Logger

  alias Tars.Credential
  alias Tars.Scope
  alias TarsOAuth.Browser
  alias TarsOAuth.Client
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
    case TarsVault.fetch({:user, provider.name}, owner) do
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
    TarsVault.forget({:user, provider.name}, owner)

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
  """
  @spec finish(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def finish(state, code) when is_binary(state) and is_binary(code) do
    with {:ok, %Flight{} = flight} <- claim(state), do: complete(flight, code)
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
  def disconnect(provider, owner), do: TarsVault.forget({:user, provider}, owner)

  @doc "Whether a user has authorized a provider."
  @spec connected?(String.t(), term()) :: boolean()
  def connected?(provider, owner), do: TarsVault.has?({:user, provider}, owner)

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
         {:ok, fresh} <- Flow.refresh(metadata, registered, token, req_options: req_options()),
         :ok <- store(provider, owner, fresh) do
      {:ok, credential(fresh)}
    else
      _no ->
        Logger.info("#{provider.name} could not be renewed for #{inspect(owner)}; asking again")
        begin(provider, owner)
    end
  end

  # A flow already under way is offered again rather than restarted: an agent
  # retrying a parked call should keep showing the same link.
  defp begin(%Provider{} = provider, owner) do
    resume = Credential.continuation()

    case Pending.under_way(provider.name, owner, resume) do
      {:ok, %Flight{url: url}} -> {:error, {:authorization_required, url}}
      :error -> open(provider, owner, resume)
    end
  end

  defp open(%Provider{} = provider, owner, resume) do
    with {:ok, metadata, registered} <- prepare(provider) do
      {verifier, challenge} = Flow.pkce()
      state = Flow.state()

      url =
        Flow.authorize_url(metadata, registered, challenge,
          state: state,
          scopes: scopes(provider, metadata)
        )

      opened(url)

      {:ok, url} =
        Pending.start(%Flight{
          state: state,
          provider: provider,
          owner: owner,
          metadata: metadata,
          registered: registered,
          verifier: verifier,
          url: url,
          started_at: System.monotonic_time(:millisecond),
          resumes: List.wrap(resume)
        })

      {:error, {:authorization_required, url}}
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
    if Keyword.get(redirect(), :open, loopback?()), do: Browser.open(url)
  end

  defp loopback?, do: is_nil(Keyword.get(redirect(), :uri))

  defp redirect, do: :tars |> Application.get_env(__MODULE__, []) |> Keyword.get(:redirect, [])

  defp prepare(%Provider{} = provider) do
    client = Client.new(redirect_uri: redirect_uri(), req_options: req_options())

    with {:ok, metadata} <- discover(provider),
         {:ok, registered} <- Flow.register(metadata, client, provider) do
      {:ok, metadata, registered}
    end
  end

  defp discover(%Provider{} = provider) do
    Metadata.discover(provider.resource, issuer: provider.issuer, req_options: req_options())
  end

  defp exchange(%Flight{} = flight, code) do
    Flow.exchange(flight.metadata, flight.registered, code, flight.verifier,
      req_options: req_options()
    )
  end

  defp claim(state) do
    case Pending.claim(state) do
      {:ok, flight} -> {:ok, flight}
      :error -> {:error, :no_such_flow}
    end
  end

  defp store(%Provider{} = provider, owner, %Token{} = token) do
    TarsVault.put({:user, provider.name}, owner, Token.encode(token))
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

  defp redirect_uri, do: Keyword.get(redirect(), :uri) || Loopback.redirect_uri()

  defp req_options do
    :tars |> Application.get_env(__MODULE__, []) |> Keyword.get(:req_options, [])
  end
end
