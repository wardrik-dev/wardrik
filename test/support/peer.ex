defmodule Wardrik.Test.RemoteStore do
  @moduledoc """
  A store that forwards every call to an in-memory store on another node.

  It lets peers that aren't clustered with each other share one store, the way two releases of a
  blue-green deploy share one database.
  """
  @behaviour WardrikStore.Adapter

  @doc "Builds a store over the in-memory store `name` on `host`."
  @spec new(node(), atom()) :: WardrikStore.t()
  def new(host, name), do: WardrikStore.new(__MODULE__, {host, name})

  @impl WardrikStore.Adapter
  def child_spec({_host, name}), do: %{id: name, start: {Function, :identity, [:ignore]}}

  @impl WardrikStore.Adapter
  def put(config, path, value, opts), do: forward(config, :put, [path, value, opts])

  @impl WardrikStore.Adapter
  def lookup(config, path), do: forward(config, :lookup, [path])

  @impl WardrikStore.Adapter
  def delete(config, path, opts), do: forward(config, :delete, [path, opts])

  @impl WardrikStore.Adapter
  def keys(config, prefix), do: forward(config, :keys, [prefix])

  defp forward({host, name}, function, args),
    do: :erpc.call(host, WardrikStore.ETS, function, [name | args])
end

defmodule Wardrik.Test.Peer do
  @moduledoc """
  Starts peer nodes that run Wardrik on a store the test node holds, without joining each other.

  Each peer runs with `-connect_all false`, so being connected to the test node doesn't connect
  it to the other peers: they can't see each other's processes, as releases that aren't clustered
  can't.
  """

  @name :wardrik_peer

  @doc "Starts a peer with the test node's code. Returns its node."
  @spec start(atom()) :: node()
  def start(name) do
    ensure_distributed()

    paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

    {:ok, _peer, node} =
      :peer.start_link(%{
        name: :"#{name}_#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        args: [~c"-connect_all", ~c"false" | paths]
      })

    :ok = :erpc.call(node, Logger, :configure, [[level: :error]])
    {:ok, _apps} = :erpc.call(node, Application, :ensure_all_started, [:wardrik])
    node
  end

  @doc "Starts Wardrik on `node`, on the in-memory store `store` of the test node."
  @spec wardrik(node(), atom()) :: {:ok, pid()} | {:error, term()}
  def wardrik(node, store), do: :erpc.call(node, __MODULE__, :start_wardrik, [node(), store])

  @doc false
  def start_wardrik(host, store) do
    wardrik =
      Wardrik.new(
        authorizer: {Wardrik.Test.Allow, []},
        resolver: {Wardrik.Test.Owned, @name},
        name: @name,
        store: Wardrik.Test.RemoteStore.new(host, store)
      )

    # Started unlinked: the call that starts it ends as soon as it returns.
    case Supervisor.start_link([{Wardrik, wardrik}], strategy: :one_for_one) do
      {:ok, pid} ->
        Process.unlink(pid)
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Stops Wardrik on `node` the way a release shuts down."
  @spec stop(node(), pid()) :: :ok
  def stop(node, supervisor), do: :erpc.call(node, Supervisor, :stop, [supervisor])

  @doc """
  Sends the calling process `{:notifier_started, node}` each time the notifier starts on `node`.
  """
  @spec watch(node()) :: :ok
  def watch(node),
    do:
      :erpc.call(node, :telemetry, :attach, [
        {__MODULE__, self()},
        [:wardrik, :notify, :started],
        &__MODULE__.started/4,
        self()
      ])

  @doc false
  def started(_event, _measurements, _metadata, test), do: send(test, {:notifier_started, node()})

  @doc "Whether the notifier runs on `node`."
  @spec notifier?(node()) :: boolean()
  def notifier?(node), do: :erpc.call(node, __MODULE__, :local_notifier?, [])

  @doc false
  def local_notifier? do
    supervisor = Module.concat(@name, Wardrik.Notify)

    Process.whereis(supervisor) != nil and
      match?(
        {pid, _meta} when node(pid) == node(),
        DurableServer.Supervisor.lookup(supervisor, "notifier")
      )
  end

  defp ensure_distributed do
    # Long names on loopback: a host's short name can resolve only to addresses the node
    # doesn't listen on, and then peers never connect back.
    unless Node.alive?() do
      {:ok, _pid} =
        :net_kernel.start(:"wardrik_test_#{System.unique_integer([:positive])}@127.0.0.1", %{
          name_domain: :longnames
        })
    end
  end
end
