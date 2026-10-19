defmodule WardrikHTTP do
  @moduledoc """
  Wardrik's agents over HTTP: a versioned JSON API, and each agent's event log
  as server-sent events a client resumes after any disconnect. The
  [HTTP API](http-api.md) guide is every route, for whoever calls them.

  `WardrikHTTP.Listener` serves it, on `127.0.0.1:4747` unless `config.yaml`'s
  `http` says otherwise. Every request presents a token, which
  `WardrikHTTP.Token` makes and `WardrikHTTP.Tokens` checks, unless the
  listener is given another `WardrikHTTP.Authenticator`, such as a sign-in,
  which answers the caller's `Wardrik.Token` the same way.

  ## The host

  The routes act through the `Wardrik.Host` the listener was started with. Its
  `:definitions`, `Wardrik.Definitions`, keep the definitions put, read as
  `Wardrik.Definition` reads them, and refuse the keys agent files declare:
  such a key answers `409`. A route the host's module answers
  `:unsupported`, as every one where the host names none does, answers
  `501`. Connections are offered by the host's `:connections`; see
  `Wardrik.Connections`.

  ## What answers

  Each route calls a function of `Wardrik`, and `Wardrik.JSON` shows
  what it answers. `WardrikProtocol`'s `openapi.json` is every route, what
  it takes and answers, and that function, each resource a JSON Schema
  beside the events'. `WardrikHTTP.EventStream` serves agents' logs as
  `Wardrik.events/2` reads them, and `WardrikHTTP.Worker` and
  `WardrikHTTP.Workers` tool workers. A request that
  changes something is recorded in `Wardrik.Audit` with the caller's
  principal.

  ## On a host

  `attach/2` has a `Wardrik.Host` serve it, and `config/1` reads
  `config.yaml`'s `http` into the options it takes:

      host = WardrikHTTP.attach(host, port: 4747, workers: [trusted: true])
  """

  @doc """
  `host` served over HTTP: among its tool sources, `workers`, the tools the
  connected tool workers offer, `WardrikHTTP.Workers`; and among its
  children, `WardrikHTTP.Access` over the host's store, the workers' group,
  and `WardrikHTTP.Listener`, which serves the API and the host's routes,
  with its `:port`, `:ip`, `:workers` and `:authenticator` from `opts`.
  """
  @spec attach(Wardrik.Host.t(), keyword()) :: Wardrik.Host.t()
  def attach(%Wardrik.Host{} = host, opts \\ []) do
    opts = Keyword.validate!(opts, [:port, :ip, :workers, :authenticator])

    host
    |> Wardrik.Host.register(:sources, [{"workers", WardrikHTTP.Workers}])
    |> Wardrik.Host.child({WardrikHTTP.Access, store: Wardrik.Host.store(host)})
    |> Wardrik.Host.child({WardrikHTTP.Workers, []})
    |> Wardrik.Host.child({WardrikHTTP.Listener, opts})
  end

  @doc """
  Reads `config.yaml`'s `http` into the options `attach/2` takes, or the
  key that does not read, as a path within the section, and why: the
  `port` and `ip` it listens on, and `trusted_workers`, whether what tool
  workers answer is the deployment's own.
  """
  @spec config(map() | nil) :: {:ok, keyword()} | {:error, [String.t()], String.t()}
  def config(nil), do: {:ok, []}

  def config(%{} = section) do
    case Map.keys(section) -- ~w(port ip trusted_workers) do
      [] -> settings(Enum.to_list(section), [])
      [key | _] -> {:error, [key], "is not a setting; expected one of port, ip, trusted_workers"}
    end
  end

  def config(_section), do: {:error, [], "is a set of keys"}

  defp settings([], read), do: {:ok, Enum.reverse(read)}

  defp settings([{"port", port} | rest], read) when is_integer(port) and port in 1..65_535,
    do: settings(rest, [{:port, port} | read])

  defp settings([{"port", _port} | _rest], _read), do: {:error, ["port"], "is a port number"}

  defp settings([{"trusted_workers", trusted} | rest], read) when is_boolean(trusted),
    do: settings(rest, [{:workers, [trusted: trusted]} | read])

  defp settings([{"trusted_workers", _trusted} | _rest], _read),
    do: {:error, ["trusted_workers"], "is true or false"}

  defp settings([{"ip", ip} | rest], read) do
    with true <- is_binary(ip),
         {:ok, address} <- :inet.parse_address(String.to_charlist(ip)) do
      settings(rest, [{:ip, address} | read])
    else
      _not_an_address -> {:error, ["ip"], "is an address, such as 127.0.0.1 or 0.0.0.0"}
    end
  end
end
