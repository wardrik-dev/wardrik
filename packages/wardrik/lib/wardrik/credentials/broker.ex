defmodule Wardrik.Credentials.Broker do
  @options [
    url: [type: :string, required: true, doc: "Where Wardrik asks for credentials."],
    secret: [
      type: {:or, [:string, {:tuple, [{:in, [:secret]}, :string]}]},
      required: true,
      doc: """
      Signs requests both ways, as [Standard Webhooks](https://www.standardwebhooks.com/)
      specifies. A string, as `"whsec_..."`, or `{:secret, name}` from the deployment's secrets.
      """
    ],
    credentials: [
      type: {:list, :string},
      required: true,
      doc: "The credential names the broker answers. Wardrik's vault answers the rest."
    ],
    req_options: [type: :keyword_list, default: [], doc: "Merged into each `Req` request."]
  ]

  # The moduledoc lists the options from the schema above.
  # credo:disable-for-next-line Credo.Check.Readability.StrictModuleLayout
  @moduledoc """
  Asks a service of your own for credentials, in place of Wardrik's vault.

      Wardrik.start_link(
        name: MyApp.AgentRuntime,
        broker: [
          url: "https://broker.internal/credentials",
          secret: {:secret, "BROKER_SECRET"},
          credentials: ["gmail", "github"]
        ]
      )

  For each call that needs a credential the broker answers, Wardrik posts:

      {"credential": "gmail", "principal": "acme/@maria", "agent": "triage", "call": "call_1",
       "refused": false}

  `refused` is `true` when the service refused the last token the broker gave. The broker
  answers `200` with one of:

    * `{"token": "...", "expires_in": 3600}` - the call goes ahead. Without `expires_in`, the
      broker is asked again on the next call.
    * `{"authorize": "https://..."}` - the call waits on that link, as for a sign-in.
    * `{"error": "..."}` - the call fails with that message.

  The broker tells Wardrik when something changes, at `Wardrik.Hook.broker/2` (over HTTP,
  `POST /v1/broker`), with a signed body:

    * `{"type": "granted", "credential": "gmail", "principal": "acme/@maria"}` - the calls
      waiting on it carry on.
    * `{"type": "revoked", ...}` - Wardrik forgets the token and closes MCP connections that use
      it.

  Tokens are kept in memory only, for each agent, until `expires_in`.

  ## Options

  #{NimbleOptions.docs(@options)}
  """

  @behaviour Wardrik.Credentials

  use GenServer

  alias Wardrik.Credentials.Request
  alias Wardrik.Principal
  alias Wardrik.Triggers.Webhook

  @doc false
  @spec schema() :: keyword()
  def schema, do: @options

  @doc false
  @spec child_spec(Wardrik.t()) :: Supervisor.child_spec()
  def child_spec(wardrik),
    do: %{id: __MODULE__, start: {GenServer, :start_link, [__MODULE__, table(wardrik.name)]}}

  @impl GenServer
  def init(table) do
    :ets.new(table, [:named_table, :public, read_concurrency: true])
    {:ok, table}
  end

  @impl Wardrik.Credentials
  def resolve(%Request{name: name} = request, instance) do
    wardrik = Wardrik.Instance.fetch!(instance)
    settings = wardrik.broker

    if name in settings.credentials,
      do: brokered(request, wardrik),
      else: fallback(settings.fallback, :resolve, request)
  end

  @impl Wardrik.Credentials
  def refused(%Request{principal: nil}, _instance), do: :ok

  def refused(%Request{name: name} = request, instance) do
    wardrik = Wardrik.Instance.fetch!(instance)
    settings = wardrik.broker

    if name in settings.credentials do
      table = table(wardrik.name)
      :ets.delete(table, key(request))
      :ets.insert(table, {{:refused, key(request)}})
      :ok
    else
      fallback(settings.fallback, :refused, request)
    end
  end

  @doc """
  Takes a signed request from the broker: `granted` carries on the calls waiting on the
  credential, `revoked` forgets its tokens and closes MCP connections that use it.
  """
  @spec deliver(Wardrik.t(), Webhook.request(), DateTime.t()) ::
          :ok | {:error, :not_found | String.t()}
  def deliver(%Wardrik{broker: nil}, _request, _now), do: {:error, :not_found}

  def deliver(%Wardrik{} = wardrik, request, now) do
    with {:ok, secret} <- secret(wardrik),
         :ok <- Webhook.verify(request, verify: :standard, secret: secret, now: now),
         {:ok, change} <- change(request.body) do
      changed(wardrik, change)
    end
  end

  defp change(body) do
    case JSON.decode(body) do
      {:ok, %{"type" => type, "credential" => name, "principal" => id}}
      when type in ["granted", "revoked"] and is_binary(name) and is_binary(id) ->
        {:ok, {type, name, %Principal{id: id}}}

      _other ->
        {:error, "its body isn't a granted or revoked change"}
    end
  end

  defp changed(wardrik, {"granted", name, principal}) do
    forget(wardrik, name, principal)
    Wardrik.SignIns.granted(name, principal, Wardrik.agents(wardrik))
  end

  defp changed(wardrik, {"revoked", name, principal}) do
    forget(wardrik, name, principal)
    mcp = Wardrik.mcp(wardrik)
    Wardrik.MCP.disconnect(mcp, credential: name, principal: principal.id)
  end

  defp forget(wardrik, name, %Principal{id: id}) do
    table = table(wardrik.name)
    :ets.match_delete(table, {{name, id, :_}, :_, :_})
  end

  defp brokered(%Request{principal: nil}, _wardrik), do: {:error, :no_principal}

  defp brokered(request, wardrik) do
    table = table(wardrik.name)
    key = key(request)
    now = System.monotonic_time(:second)

    case :ets.lookup(table, key) do
      [{^key, token, expires}] when expires > now -> {:ok, token}
      _missing -> asked(request, wardrik, table, now)
    end
  end

  defp asked(request, wardrik, table, now) do
    refused = :ets.take(table, {:refused, key(request)}) != []

    body =
      JSON.encode!(%{
        credential: request.name,
        principal: request.principal.id,
        agent: request.agent,
        call: request.call,
        refused: refused
      })

    with {:ok, secret} <- secret(wardrik),
         {:ok, answer} <- post(wardrik.broker, secret, body) do
      answered(answer, request, table, now)
    end
  end

  defp answered(%{"token" => token} = answer, request, table, now) when is_binary(token) do
    case answer["expires_in"] do
      seconds when is_integer(seconds) and seconds > 0 ->
        :ets.insert(table, {key(request), token, now + seconds})

      _uncached ->
        :ok
    end

    {:ok, token}
  end

  defp answered(%{"authorize" => url}, _request, _table, _now) when is_binary(url),
    do: {:authorize, url}

  defp answered(%{"error" => message}, _request, _table, _now) when is_binary(message),
    do: {:error, message}

  defp answered(_answer, _request, _table, _now),
    do: {:error, "The credential broker's answer has no token, authorize or error."}

  defp post(settings, secret, body) do
    options =
      Keyword.merge(
        [
          body: body,
          headers: [{"content-type", "application/json"} | Webhook.sign(secret, body)],
          retry: :transient,
          receive_timeout: 10_000
        ],
        settings.req_options
      )

    case Req.post(settings.url, options) do
      {:ok, %Req.Response{status: 200, body: %{} = answer}} ->
        {:ok, answer}

      {:ok, %Req.Response{status: status}} ->
        {:error, "The credential broker answered #{status}."}

      {:error, exception} ->
        {:error, "The credential broker can't be reached: #{Exception.message(exception)}"}
    end
  end

  defp secret(%Wardrik{broker: %{secret: secret}} = wardrik) do
    case Wardrik.Vault.Lookup.resolved(wardrik, "broker", secret: secret) do
      [secret: value] when is_binary(value) -> {:ok, value}
      [secret: nil] -> {:error, "The deployment hasn't sealed the credential broker's secret."}
    end
  end

  defp fallback(nil, :resolve, %Request{name: name}),
    do: {:error, "No credentials to give #{name}."}

  defp fallback(nil, :refused, _request), do: :ok

  defp fallback(entry, callback, request) do
    {module, opts} = Wardrik.Context.entry(entry)

    cond do
      callback == :resolve ->
        module.resolve(request, opts)

      Code.ensure_loaded?(module) and function_exported?(module, :refused, 2) ->
        module.refused(request, opts)

      true ->
        :ok
    end
  end

  defp key(%Request{name: name, principal: %Principal{id: id}, agent: agent}),
    do: {name, id, agent}

  defp table(name), do: Module.concat(name, Broker)
end
