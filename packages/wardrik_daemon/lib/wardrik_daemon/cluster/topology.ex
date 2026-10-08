defmodule WardrikDaemon.Cluster.Topology do
  @moduledoc """
  One topology of `config.yaml`'s `cluster`, and the process that keeps this
  node connected to the nodes its strategy finds.

  It asks the strategy once it has started, without holding up the supervisor
  starting it, and again every `polling_interval` milliseconds, connecting to
  each node it finds that this node is not connected to. A node that cannot be reached is tried
  again at the next poll, so nodes may start in any order and one that comes
  back rejoins. It never disconnects a node.

  `connect` and `list_nodes` are how it connects and what it counts as
  connected, as libcluster's topologies take them: `:net_kernel.connect_node/1`
  and `:erlang.nodes(:connected)` unless set.

  A node that is not distributed has nothing to connect with, and the topology
  does not start.
  """

  use GenServer

  require Logger

  alias WardrikDaemon.Cluster.Strategy

  @enforce_keys [:name, :strategy]
  defstruct [
    :name,
    :strategy,
    polling_interval: 5_000,
    connect: {:net_kernel, :connect_node, []},
    list_nodes: {:erlang, :nodes, [:connected]}
  ]

  @type t() :: %__MODULE__{
          name: String.t(),
          strategy: struct(),
          polling_interval: pos_integer(),
          connect: {module(), atom(), [term()]},
          list_nodes: {module(), atom(), [term()]}
        }

  @doc false
  @spec child_spec(t()) :: Supervisor.child_spec()
  def child_spec(%__MODULE__{name: name} = topology) do
    %{id: {__MODULE__, name}, start: {__MODULE__, :start_link, [topology]}}
  end

  @spec start_link(t()) :: GenServer.on_start() | :ignore
  def start_link(%__MODULE__{} = topology), do: GenServer.start_link(__MODULE__, topology)

  @impl true
  def init(%__MODULE__{} = topology) do
    if Node.alive?() do
      {:ok, {topology, MapSet.new()}, {:continue, :poll}}
    else
      Logger.warning(
        "Cluster topology #{topology.name} is not started: this node is not distributed"
      )

      :ignore
    end
  end

  @impl true
  def handle_continue(:poll, {topology, unreached}) do
    {:noreply, topology |> poll(unreached) |> schedule()}
  end

  @impl true
  def handle_info(:poll, state), do: handle_continue(:poll, state)

  @doc false
  # The nodes found that are neither this one nor already connected, each
  # connected to at once. `unreached` is the nodes the last poll could not
  # reach, so each is reported once until it is reached.
  @spec poll(t(), MapSet.t(node())) :: {t(), MapSet.t(node())}
  def poll(%__MODULE__{} = topology, unreached) do
    connected = MapSet.new([node() | call(topology.list_nodes, [])])

    wanted =
      topology.strategy
      |> Strategy.nodes()
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(connected, &1))

    results =
      wanted
      |> Task.async_stream(&{&1, call(topology.connect, [&1])},
        timeout: :timer.seconds(15),
        on_timeout: :kill_task
      )
      |> Enum.zip(wanted)
      |> Enum.map(fn
        {{:ok, {node, true}}, _node} -> {node, true}
        {_failed, node} -> {node, false}
      end)

    for {node, true} <- results,
        do: Logger.info("Connected to #{node}, found by cluster topology #{topology.name}")

    unreached_now = for {node, false} <- results, into: MapSet.new(), do: node

    for node <- MapSet.difference(unreached_now, unreached),
        do: Logger.info("Could not reach #{node} yet, found by cluster topology #{topology.name}")

    {topology, unreached_now}
  end

  defp schedule({topology, _unreached} = state) do
    Process.send_after(self(), :poll, topology.polling_interval)
    state
  end

  defp call({module, function, args}, extra), do: apply(module, function, args ++ extra)
end
