defmodule Wardrik.Egress do
  @moduledoc """
  Says which URLs a Wardrik reaches when its users name them, as an org adds an MCP server: `https`
  at a host whose every address is public. A URL is checked as it's named and as each connection
  to it starts, not on each request, so a host that resolves elsewhere between the two is reached
  where it resolves then.
  """

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
    {{0, 0, 0, 0, 0, 0, 0, 0}, 96},
    {{0x100, 0, 0, 0, 0, 0, 0, 0}, 64},
    {{0x2001, 0, 0, 0, 0, 0, 0, 0}, 32},
    {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32},
    {{0xFC00, 0, 0, 0, 0, 0, 0, 0}, 7},
    {{0xFE80, 0, 0, 0, 0, 0, 0, 0}, 10},
    {{0xFF00, 0, 0, 0, 0, 0, 0, 0}, 8}
  ]

  @doc """
  Answers `:ok` where `url` is `https` at a host whose every address is public, or says why not.

      Wardrik.Egress.public("https://10.0.0.5/mcp")
      #=> {:error, "10.0.0.5 is a private address"}
  """
  @spec public(String.t()) :: :ok | {:error, String.t()}
  def public(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> reached(host)
      _other -> {:error, "#{url} isn't an https URL"}
    end
  end

  @doc "Answers `:ok` for every URL, for a Wardrik whose operator alone names them, as a daemon's."
  @spec any(String.t()) :: :ok
  def any(_url), do: :ok

  @doc "Says whether `address` is reached on the public internet, and an IPv6 address wrapping one."
  @spec public?(:inet.ip_address()) :: boolean()
  def public?({_a, _b, _c, _d} = address),
    do: not Enum.any?(@not_public_v4, &within?(address, &1))

  def public?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: public?(ipv4(hi, lo))
  def public?({0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}), do: public?(ipv4(hi, lo))
  def public?({0x2002, hi, lo, _d, _e, _f, _g, _h}), do: public?(ipv4(hi, lo))
  def public?(address), do: not Enum.any?(@not_public_v6, &within?(address, &1))

  defp reached(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> literal(host, address)
      {:error, :einval} -> resolved(host, addresses(host))
    end
  end

  defp literal(host, address) do
    if public?(address), do: :ok, else: {:error, "#{host} is a private address"}
  end

  defp resolved(host, []), do: {:error, "#{host} doesn't resolve"}

  defp resolved(host, addresses) do
    case Enum.reject(addresses, &public?/1) do
      [] -> :ok
      [address | _rest] -> {:error, "#{host} is at #{:inet.ntoa(address)}, a private address"}
    end
  end

  defp addresses(host), do: Enum.flat_map([:inet, :inet6], &family(String.to_charlist(host), &1))

  defp family(name, family) do
    case :inet.getaddrs(name, family) do
      {:ok, addresses} -> addresses
      {:error, _reason} -> []
    end
  end

  defp within?(address, {network, bits}) do
    shift = width(address) - bits
    Bitwise.bsr(integer(address), shift) == Bitwise.bsr(integer(network), shift)
  end

  defp width({_a, _b, _c, _d}), do: 32
  defp width(_address), do: 128

  defp integer(address) do
    size = div(width(address), tuple_size(address))
    address |> Tuple.to_list() |> Enum.reduce(0, &(Bitwise.bsl(&2, size) + &1))
  end

  defp ipv4(hi, lo),
    do: {Bitwise.bsr(hi, 8), Bitwise.band(hi, 0xFF), Bitwise.bsr(lo, 8), Bitwise.band(lo, 0xFF)}
end
