defmodule TarsOAuth.Device do
  @moduledoc """
  The device authorization grant, RFC 8628: a user authorizes on any device,
  by entering a code at the server's page, while Tars asks the token endpoint
  whether they have yet.

      {:ok, device} = TarsOAuth.Device.request(metadata, registered, scopes: ["repo"])
      device.user_code         #=> "WDJB-MJHT"
      device.verification_uri  #=> "https://github.com/login/device"

      TarsOAuth.Device.poll(metadata, registered, device)
      #=> :pending, until the user has, then {:ok, %TarsOAuth.Token{}}

  A server offering it names a `device_authorization_endpoint` in its
  metadata. Nothing comes back to this machine, so it needs no redirect URI
  and no browser here: the code can be entered on a phone. `TarsOAuth` starts
  one where a provider's flow calls for it, and asks every `interval` seconds
  until the user has authorized, refused, or let the code expire.

  `poll/4` answers `:pending` while the user has not finished, `:slow_down`
  where the server asks to be asked less often, which adds five seconds to the
  interval, `{:retry, reason}` where the server could not be reached or
  failed, and `{:error, :access_denied}` or `{:error, :expired}` where the
  flow is over. A server that answers an error with a 200, as GitHub's does,
  is read the same as one that answers it with a 400. A token comes back bound
  to where it came from (`TarsOAuth.Token.bind/3`).

  Requests go through `TarsOAuth.Egress` under the metadata's trust. A code
  that the server says lasts longer than 30 minutes is treated as lasting 30.
  """

  alias TarsOAuth.Egress
  alias TarsOAuth.Flow
  alias TarsOAuth.Metadata
  alias TarsOAuth.Token

  @grant "urn:ietf:params:oauth:grant-type:device_code"
  @default_interval 5
  @longest :timer.minutes(30) |> div(1000)

  @enforce_keys [:device_code, :user_code, :verification_uri, :expires_in, :interval]
  defstruct [
    :device_code,
    :user_code,
    :verification_uri,
    :verification_uri_complete,
    :expires_in,
    :interval
  ]

  @typedoc "What a server answers a device authorization request with."
  @type t() :: %__MODULE__{
          device_code: String.t(),
          user_code: String.t(),
          verification_uri: String.t(),
          verification_uri_complete: String.t() | nil,
          expires_in: pos_integer(),
          interval: non_neg_integer()
        }

  @typedoc "What one poll of the token endpoint found."
  @type poll() :: {:ok, Token.t()} | :pending | :slow_down | {:retry, term()} | {:error, term()}

  @doc "The grant type a device flow polls the token endpoint with."
  @spec grant() :: String.t()
  def grant, do: @grant

  @doc "Whether the server offers the device authorization grant."
  @spec offered?(Metadata.t()) :: boolean()
  def offered?(%Metadata{device_authorization_endpoint: endpoint}), do: is_binary(endpoint)

  @doc """
  Asks the server for a code the user can enter.

  `:scopes` is what is asked for, and the resource indicator is sent where the
  metadata names one. `:req_options` is merged into the request.
  """
  @spec request(Metadata.t(), Flow.registered(), keyword()) :: {:ok, t()} | {:error, term()}
  def request(%Metadata{} = metadata, registered, opts \\ []) do
    if offered?(metadata) do
      %{"client_id" => registered.client_id}
      |> put_present("client_secret", registered.client_secret)
      |> put_present("scope", opts |> Keyword.get(:scopes, []) |> Enum.join(" "))
      |> put_present("resource", metadata.resource)
      |> post(metadata.device_authorization_endpoint, metadata.trust, opts)
      |> case do
        {:ok, 200, body} ->
          read(body)

        {:ok, status, body} ->
          {error, description} = Token.refusal(body)
          {:error, {:device_refused, error || "http_#{status}", description}}

        {:error, {:token_unreachable, reason}} ->
          {:error, {:device_unreachable, reason}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, {:no_device_flow, metadata.issuer}}
    end
  end

  @doc "Asks the token endpoint once whether the user has authorized."
  @spec poll(Metadata.t(), Flow.registered(), t(), keyword()) :: poll()
  def poll(%Metadata{} = metadata, registered, %__MODULE__{} = device, opts \\ []) do
    %{
      "grant_type" => @grant,
      "device_code" => device.device_code,
      "client_id" => registered.client_id
    }
    |> put_present("client_secret", registered.client_secret)
    |> put_present("resource", metadata.resource)
    |> post(metadata.token_endpoint, metadata.trust, opts)
    |> polled(metadata, registered)
  end

  defp polled({:ok, 200, %{"access_token" => _token} = body}, metadata, registered) do
    with {:ok, token} <- Token.from_response(body),
         do: {:ok, Token.bind(token, metadata, registered)}
  end

  defp polled({:ok, _status, %{"error" => error}}, _metadata, _registered)
       when error in ["authorization_pending", "slow_down", "access_denied", "expired_token"],
       do: waiting(error)

  defp polled({:ok, status, _body}, _metadata, _registered) when status >= 500,
    do: {:retry, "http_#{status}"}

  defp polled({:ok, status, body}, _metadata, _registered) do
    {error, description} = Token.refusal(body)
    {:error, {:token_refused, error || "http_#{status}", description}}
  end

  defp polled({:error, {:token_unreachable, reason}}, _metadata, _registered),
    do: {:retry, reason}

  defp polled({:error, reason}, _metadata, _registered), do: {:error, reason}

  defp waiting("authorization_pending"), do: :pending
  defp waiting("slow_down"), do: :slow_down
  defp waiting("access_denied"), do: {:error, :access_denied}
  defp waiting("expired_token"), do: {:error, :expired}

  @doc "How many milliseconds to wait before the next poll, after `poll` found what it found."
  @spec next_interval(poll(), non_neg_integer()) :: non_neg_integer()
  def next_interval(:slow_down, interval_ms), do: interval_ms + :timer.seconds(5)
  def next_interval(_poll, interval_ms), do: interval_ms

  # Google names the page `verification_url`, as the draft of RFC 8628 did.
  defp read(%{"device_code" => device_code, "user_code" => user_code} = body)
       when is_binary(device_code) and is_binary(user_code) do
    case {body["verification_uri"] || body["verification_url"], body["expires_in"]} do
      {uri, expires_in} when is_binary(uri) and is_integer(expires_in) and expires_in > 0 ->
        {:ok,
         %__MODULE__{
           device_code: device_code,
           user_code: user_code,
           verification_uri: uri,
           verification_uri_complete: body["verification_uri_complete"],
           expires_in: min(expires_in, @longest),
           interval: interval(body["interval"])
         }}

      _missing ->
        {:error, :device_unreadable}
    end
  end

  defp read(_body), do: {:error, :device_unreadable}

  defp interval(seconds) when is_integer(seconds) and seconds >= 0, do: seconds
  defp interval(_absent), do: @default_interval

  # A transport failure is {:token_unreachable, reason}, so poll/4 can tell it
  # from a URL Egress would not let it ask.
  defp post(form, endpoint, trust, opts) do
    request =
      [form: form, headers: [accept: "application/json"]] ++ Keyword.get(opts, :req_options, [])

    with {:ok, options} <- Egress.options(endpoint, trust, request) do
      case Req.post(options) do
        {:ok, %Req.Response{status: status, body: body}} when is_map(body) -> {:ok, status, body}
        {:ok, %Req.Response{status: status}} -> {:ok, status, %{}}
        {:error, reason} -> {:error, {:token_unreachable, reason}}
      end
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
