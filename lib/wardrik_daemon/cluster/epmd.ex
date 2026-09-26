defmodule WardrikDaemon.Cluster.Epmd do
  @moduledoc """
  The `epmd` strategy: the nodes a topology names outright, as libcluster's
  `Cluster.Strategy.Epmd` takes them.

      cluster:
        topologies:
          box:
            strategy: epmd
            config:
              hosts: [wardrik_a@localhost, wardrik_b@localhost, wardrik_c@localhost]

  `hosts` lists every node in the cluster, this one among them, so every node
  can read the same file.
  """

  @behaviour WardrikDaemon.Cluster.Strategy

  @enforce_keys [:hosts]
  defstruct [:hosts]

  @type t() :: %__MODULE__{hosts: [node()]}

  @impl WardrikDaemon.Cluster.Strategy
  def nodes(%__MODULE__{hosts: hosts}), do: hosts
end
