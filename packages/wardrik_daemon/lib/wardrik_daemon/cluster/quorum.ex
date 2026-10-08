defmodule WardrikDaemon.Cluster.Quorum do
  @moduledoc """
  Holds the fleet back until a quorum of the cluster's nodes is connected.

  Core starts it after `WardrikDaemon.Cluster` and before the fleet, both as its
  `:cluster`:

      {Wardrik, cluster: [WardrikDaemon.Cluster, WardrikDaemon.Cluster.Quorum]}

  It does not return from starting until `WardrikDaemon.Cluster.waiting/0` has
  nothing to say: until a quorum of the cluster's nodes, as the store counts
  one, is connected, this one among them. That is more than half of them for a
  store kept on the nodes, and this one alone for a store kept elsewhere. The
  fleet's first write to the store needs that quorum, so it is made only once
  it can succeed. It logs what it is waiting for as it begins, and again every
  half minute, while the cluster's topologies, already running, connect to the
  nodes they find.

  A node that is not one of `cluster.nodes` does not start, and without a
  cluster there is nothing to wait for.
  """

  require Logger

  alias WardrikDaemon.Cluster

  @log_every :timer.seconds(30)

  @doc false
  @spec child_spec([]) :: Supervisor.child_spec()
  def child_spec([]), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}

  @doc "Returns `:ignore` once a quorum is connected, or refuses a node the cluster does not name."
  @spec start_link() :: :ignore | {:error, String.t()}
  def start_link do
    cond do
      not Cluster.configured?() ->
        :ignore

      reason = Cluster.refusal() ->
        Logger.error(reason)
        {:error, reason}

      true ->
        # The wait runs in a task, so the node events it receives never reach
        # the supervisor starting this.
        Task.await(Task.async(&await/0), :infinity)
        :ignore
    end
  end

  defp await do
    :ok = :net_kernel.monitor_nodes(true)
    await(&Cluster.waiting/0, @log_every)
  end

  @doc false
  # Returns once `waiting` answers nil, asking it again at each `{:nodeup, _}`
  # this process receives, and logging what it answers every `log_every`
  # milliseconds meanwhile.
  @spec await((-> String.t() | nil), pos_integer()) :: :ok
  def await(waiting, log_every), do: wait(waiting.(), waiting, log_every)

  defp wait(nil, _waiting, _log_every), do: :ok

  defp wait(reason, waiting, log_every) do
    Logger.info(reason)
    wait_for_node(System.monotonic_time(:millisecond) + log_every, waiting, log_every)
  end

  defp wait_for_node(log_at, waiting, log_every) do
    receive do
      {:nodeup, _node} ->
        if waiting.(), do: wait_for_node(log_at, waiting, log_every), else: :ok

      {:nodedown, _node} ->
        wait_for_node(log_at, waiting, log_every)
    after
      max(log_at - System.monotonic_time(:millisecond), 0) ->
        wait(waiting.(), waiting, log_every)
    end
  end
end
