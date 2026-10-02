defmodule WardrikDaemon.Cluster.DNSPoll do
  @moduledoc """
  The `dns_poll` strategy: a node at each address a DNS name resolves to, as
  libcluster's `Cluster.Strategy.DNSPoll` and `DNSCluster` find them.

      cluster:
        size: 3
        topologies:
          fly:
            strategy: dns_poll
            config:
              query: wardrik.internal
              node_basename: wardrik

  Each A and AAAA record `query` resolves to is a node named
  `node_basename@address`. `node_basename` is this node's own basename, the
  part of its name before `@`, when absent, which is right wherever every node
  runs under the same one. Nodes named by address run with long names,
  `RELEASE_DISTRIBUTION=name`, and `RELEASE_NODE` set to `basename@address`.
  """

  @behaviour WardrikDaemon.Cluster.Strategy

  @enforce_keys [:query]
  defstruct [:query, :node_basename, resolver: {__MODULE__, :resolve, []}]

  @type t() :: %__MODULE__{
          query: String.t(),
          node_basename: String.t() | nil,
          resolver: {module(), atom(), [term()]}
        }

  @impl WardrikDaemon.Cluster.Strategy
  def nodes(%__MODULE__{query: query, resolver: {module, function, args}} = strategy) do
    basename = strategy.node_basename || basename(node())

    for address <- apply(module, function, [query | args]),
        # reach:disable-next-line unsafe_atom_creation -- a node name is an atom, one per address the query answers
        do: String.to_atom("#{basename}@#{:inet.ntoa(address)}")
  end

  @doc "The IPv4 and IPv6 addresses `query` resolves to."
  @spec resolve(String.t()) :: [:inet.ip_address()]
  def resolve(query) do
    name = String.to_charlist(query)
    :inet_res.lookup(name, :in, :a) ++ :inet_res.lookup(name, :in, :aaaa)
  end

  defp basename(node), do: node |> Atom.to_string() |> String.split("@", parts: 2) |> hd()
end
