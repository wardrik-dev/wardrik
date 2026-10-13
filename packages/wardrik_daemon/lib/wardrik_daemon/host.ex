defmodule WardrikDaemon.Host do
  @moduledoc """
  Holds the `Wardrik.Host` the daemon was started with, for what reaches the
  daemon from outside the tree that started it: a `wardrik` command, which
  `bin/wardrik` runs on the daemon's node over rpc, builds its caller on the
  host `get/0` answers. `WardrikDaemon` starts it first, with its `:host`;
  everything it starts after it is handed the host in its options.
  """

  use GenServer

  @doc false
  @spec child_spec(Wardrik.Host.t()) :: Supervisor.child_spec()
  def child_spec(host), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [host]}}

  @doc "Starts it, holding `host`."
  @spec start_link(Wardrik.Host.t()) :: GenServer.on_start()
  def start_link(host), do: GenServer.start_link(__MODULE__, host, name: __MODULE__)

  @doc "The host the daemon was started with."
  @spec get() :: Wardrik.Host.t()
  def get, do: GenServer.call(__MODULE__, :get)

  @impl GenServer
  def init(host), do: {:ok, host}

  @impl GenServer
  def handle_call(:get, _from, host), do: {:reply, host, host}
end
