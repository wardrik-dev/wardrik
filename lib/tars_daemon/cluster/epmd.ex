defmodule TarsDaemon.Cluster.Epmd do
  @moduledoc """
  The `epmd` strategy: the nodes a topology names outright, as libcluster's
  `Cluster.Strategy.Epmd` takes them.

      cluster:
        topologies:
          box:
            strategy: epmd
            config:
              hosts: [tars_a@localhost, tars_b@localhost, tars_c@localhost]

  `hosts` lists every node in the cluster, this one among them, so every node
  can read the same file.
  """

  @behaviour TarsDaemon.Cluster.Strategy

  @enforce_keys [:hosts]
  defstruct [:hosts]

  @type t() :: %__MODULE__{hosts: [node()]}

  @impl TarsDaemon.Cluster.Strategy
  def nodes(%__MODULE__{hosts: hosts}), do: hosts
end
