defmodule WardrikMCP.Remotes do
  @moduledoc """
  The servers owners added, as this node reaches them: the first time an
  agent's tools are built with one, or one of its tools is called, it starts
  the server's own connection from the `WardrikMCP.Remote` kept in the store,
  which offers the tools last listed at once. That connection stops once
  nothing has called through it for a while, and starts again the same way.

  `WardrikMCP.Supervisor` starts one, with its `:store`. `:check` says
  whether a server's URL may be reached as it starts, `WardrikMCP.Remote.reachable/1`
  unless it says.
  """

  use GenServer

  alias Wardrik.Servers.Key
  alias WardrikMCP.Connection
  alias WardrikMCP.Offer
  alias WardrikMCP.Remote

  @doc "Starts the node's servers that owners added."
  @spec start_link(store: WardrikStore.t(), check: (String.t() -> :ok | {:error, term()})) ::
          GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:store, check: &Remote.reachable/1])
    GenServer.start_link(__MODULE__, Map.new(opts), name: __MODULE__)
  end

  @doc """
  What the server `key` names is offering, starting its connection on this
  node where an owner added it and it is not running: `nil` where no owner
  added it, or where this node runs no `WardrikMCP.Supervisor`.
  """
  @spec offer(Key.t()) :: Offer.t() | nil
  def offer(%Key{} = key) do
    GenServer.call(__MODULE__, {:offer, key})
  catch
    :exit, {:noproc, _call} -> nil
  end

  @doc """
  The servers `owner` added, by key: none where this node runs no
  `WardrikMCP.Supervisor`.
  """
  @spec added(Wardrik.AgentID.Prefix.t()) :: [Key.t()]
  def added(owner) do
    GenServer.call(__MODULE__, {:added, owner})
  catch
    :exit, {:noproc, _call} -> []
  end

  @impl GenServer
  def init(settings), do: {:ok, settings}

  @impl GenServer
  def handle_call({:offer, key}, _from, settings) do
    {:reply, Connection.offer(key) || started(key, settings), settings}
  end

  def handle_call({:added, owner}, _from, %{store: store} = settings),
    do: {:reply, for(remote <- Remote.list(store, owner), do: remote.key), settings}

  defp started(key, %{store: store, check: check}) do
    with {:ok, remote} <- Remote.fetch(store, key),
         :ok <- check.(remote.url),
         server = Remote.server(remote, store: store),
         {:ok, _pid} <- WardrikMCP.Supervisor.connect(server, :deployment, server.transport) do
      Connection.offer(key)
    else
      _none -> nil
    end
  end
end
