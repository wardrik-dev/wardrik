defmodule WardrikOAuth.Egress do
  @moduledoc """
  Where `WardrikOAuth` may send a request, or send a person, and how a request
  gets there.

  Every URL is held to one of two trusts:

    * `:operator` - a URL the deployment named: a provider's `:resource` or
      `:issuer`, and the endpoints a named issuer's metadata lists
    * `:discovered` - a URL a server named: an issuer a resource's metadata
      points to, and the endpoints that issuer lists

  A URL is `https`, or `http` to a loopback host under `:operator` trust, for
  a server run on this machine. A request to a `:discovered` URL goes only to
  a host whose every address is public, and connects to the address it
  checked, with the hostname kept for TLS and the `Host` header, so a name
  that resolves elsewhere a moment later is not followed. No request follows
  a redirect, and each gives up after 15 seconds.

  `:resolver` in `WardrikOAuth.Config` names the module whose `resolve/1`
  answers a host's addresses, this one by default.
  """

  alias WardrikOAuth.Config

  @typedoc "Whose word a URL rests on."
  @type trust() :: :operator | :discovered

  @timeout :timer.seconds(15)

  @doc "Whether `url` may be requested, or opened, under `trust`."
  @spec check(String.t(), trust()) :: :ok | {:error, {:insecure_url, String.t()}}
  def check(url, trust) when is_binary(url) and trust in [:operator, :discovered],
    do: url |> URI.parse() |> allowed(url, trust)

  defp allowed(%URI{scheme: "https", host: host}, _url, _trust)
       when is_binary(host) and host != "",
       do: :ok

  defp allowed(%URI{scheme: "http", host: host}, url, :operator) when is_binary(host),
    do: if(loopback?(host), do: :ok, else: {:error, {:insecure_url, url}})

  defp allowed(_uri, url, _trust), do: {:error, {:insecure_url, url}}

  @doc """
  The `Req` options for a request to `url` under `trust`, with `options` and
  the configured `:req_options` merged in, or why it may not be made.
  """
  @spec options(String.t(), trust(), keyword()) :: {:ok, keyword()} | {:error, term()}
  def options(url, trust, options \\ []) do
    with :ok <- check(url, trust),
         {:ok, target} <- target(url, trust) do
      {:ok,
       [redirect: false, retry: false, receive_timeout: @timeout]
       |> Keyword.merge(target)
       |> Keyword.merge(options)
       |> Keyword.merge(Config.req_options())}
    end
  end

  @doc "Every address `host` resolves to, IPv4 first."
  @spec resolve(String.t()) :: {:ok, [:inet.ip_address()]} | {:error, term()}
  def resolve(host) when is_binary(host) do
    name = String.to_charlist(host)

    case Enum.flat_map([:inet, :inet6], &addresses(name, &1)) do
      [] -> {:error, :nxdomain}
      addresses -> {:ok, addresses}
    end
  end

  defp addresses(name, family) do
    case :inet.getaddrs(name, family) do
      {:ok, addresses} -> addresses
      {:error, _reason} -> []
    end
  end

  defp target(url, :operator), do: {:ok, [url: url]}

  defp target(url, :discovered) do
    %URI{host: host} = uri = URI.parse(url)

    case Config.resolver().resolve(host) do
      {:ok, [_ | _] = addresses} ->
        if Enum.all?(addresses, &public?/1),
          do: {:ok, pinned(uri, hd(addresses))},
          else: {:error, {:private_address, host}}

      {:ok, []} ->
        {:error, {:unresolved, host}}

      {:error, reason} ->
        {:error, {:unresolved, host, reason}}
    end
  end

  # The request goes to the address checked; Mint keeps the hostname for SNI,
  # certificate verification and the Host header.
  defp pinned(%URI{host: host} = uri, address) do
    connect = [hostname: host, timeout: @timeout]

    connect =
      if tuple_size(address) == 8, do: [transport_opts: [inet6: true]] ++ connect, else: connect

    [
      url: URI.to_string(%{uri | host: address |> :inet.ntoa() |> to_string()}),
      connect_options: connect
    ]
  end

  defp loopback?("localhost"), do: true

  defp loopback?(host) do
    case :inet.parse_address(String.to_charlist(String.trim(host, "[]"))) do
      {:ok, {127, _b, _c, _d}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _other -> false
    end
  end

  # Loopback, private, shared, link-local, reserved, documentation and
  # multicast networks, as {address, prefix length}.
  @not_public_v4 [
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{172, 16, 0, 0}, 12},
    {{192, 0, 0, 0}, 24},
    {{192, 0, 2, 0}, 24},
    {{192, 168, 0, 0}, 16},
    {{198, 18, 0, 0}, 15},
    {{198, 51, 100, 0}, 24},
    {{203, 0, 113, 0}, 24},
    {{224, 0, 0, 0}, 3}
  ]

  @not_public_v6 [
    {{0x100, 0, 0, 0, 0, 0, 0, 0}, 64},
    {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32},
    {{0xFC00, 0, 0, 0, 0, 0, 0, 0}, 7},
    {{0xFE80, 0, 0, 0, 0, 0, 0, 0}, 9},
    {{0xFF00, 0, 0, 0, 0, 0, 0, 0}, 8}
  ]

  @doc """
  Whether `address` is reachable on the public internet: not loopback,
  private, shared, link-local, reserved, documentation or multicast, and not
  an IPv6 address wrapping an IPv4 one that is.
  """
  @spec public?(:inet.ip_address()) :: boolean()
  def public?({_a, _b, _c, _d} = address),
    do: not Enum.any?(@not_public_v4, &within?(address, &1))

  # IPv4-compatible and -mapped, NAT64 and 6to4 addresses carry an IPv4 one.
  def public?({0, 0, 0, 0, 0, high, hi, lo}) when high in [0, 0xFFFF], do: public?(ipv4(hi, lo))
  def public?({0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}), do: public?(ipv4(hi, lo))
  def public?({0x2002, hi, lo, _d, _e, _f, _g, _h}), do: public?(ipv4(hi, lo))

  def public?({_a, _b, _c, _d, _e, _f, _g, _h} = address),
    do: not Enum.any?(@not_public_v6, &within?(address, &1))

  defp within?(address, {network, bits}) do
    shift = bits(address) - bits
    Bitwise.bsr(integer(address), shift) == Bitwise.bsr(integer(network), shift)
  end

  defp bits(address) when tuple_size(address) == 4, do: 32
  defp bits(_address), do: 128

  defp integer(address) do
    width = div(bits(address), tuple_size(address))
    address |> Tuple.to_list() |> Enum.reduce(0, &(Bitwise.bsl(&2, width) + &1))
  end

  defp ipv4(hi, lo),
    do: {Bitwise.bsr(hi, 8), Bitwise.band(hi, 0xFF), Bitwise.bsr(lo, 8), Bitwise.band(lo, 0xFF)}
end
