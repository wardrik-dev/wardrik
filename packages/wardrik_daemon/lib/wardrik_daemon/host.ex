defmodule WardrikDaemon.Host do
  @moduledoc """
  Holds the `Wardrik.Host` and the `WardrikDaemon.Config` the daemon's tree
  was started with, for what reaches the daemon from outside the tree that
  started it: a `wardrik` command, which `bin/wardrik` runs on the daemon's
  node over rpc, builds its caller on the host `get/0` answers, and reads
  the config `config/0` does. `WardrikDaemon.Tree` starts it first;
  everything started after it is handed both in its options.
  """

  use GenServer

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc "Starts it, holding `:host` and `:config`."
  @spec start_link(host: Wardrik.Host.t(), config: WardrikDaemon.Config.t()) ::
          GenServer.on_start()
  def start_link(opts) do
    held = Map.new(Keyword.validate!(opts, [:host, :config]))
    GenServer.start_link(__MODULE__, held, name: __MODULE__)
  end

  @doc "The host the daemon was started with."
  @spec get() :: Wardrik.Host.t()
  def get, do: GenServer.call(__MODULE__, :host)

  @doc "The config the daemon was started with."
  @spec config() :: WardrikDaemon.Config.t()
  def config, do: GenServer.call(__MODULE__, :config)

  @doc "The held host's definitions, the daemon's `WardrikDaemon.Agents`."
  @spec agents() :: WardrikDaemon.Agents.t()
  def agents, do: Wardrik.Host.definitions(get())

  @doc "The agent files that read, by the ID each declares, as `WardrikDaemon.declared/1` has them."
  @spec declared() :: %{Wardrik.AgentID.t() => {Path.t(), Wardrik.Agent.Spec.t()}}
  def declared, do: WardrikDaemon.declared(WardrikDaemon.Agents.files(agents()))

  @doc "The deployment's secret `name` in the held host's vault, as `WardrikDaemon.Secrets.named/2` reads it."
  @spec secret(String.t()) :: String.t() | nil
  def secret(name), do: WardrikDaemon.Secrets.named(Wardrik.Host.credentials(get()), name)

  @impl GenServer
  def init(held), do: {:ok, held}

  @impl GenServer
  def handle_call(key, _from, held), do: {:reply, Map.fetch!(held, key), held}
end
