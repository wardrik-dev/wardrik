defmodule WardrikDaemon.Tree do
  @moduledoc """
  The daemon's tree, which a release starts once its store runs and its
  cluster has a quorum.

  As it starts, it reads `config.yaml` (see `WardrikDaemon.Config.load/1`),
  with what the environment does not set read from the vault in `:store`,
  builds the `Wardrik.Host` from it (see `WardrikDaemon.host/2`), and starts,
  each handed the host or its store:

    * `WardrikDaemon.Host`, which holds the host and the config for the
      `wardrik` commands that reach the node over rpc
    * `Wardrik.Core`, whose fleet every agent runs in
    * `WardrikPolicy.Supervisor`, which keeps the budgets agents' policies set
    * `WardrikTrigger`, which runs their triggers
    * `WardrikDaemon`, the rest

  One that stops takes those after it with it. A `config.yaml` that does not
  read stops the boot, with the reason logged.

  `:store` is required. `:base` is what the release's own configuration says
  of each module, which `config.yaml` is merged over; `:config_dir`,
  `:data_dir`, `:state_dir` and `:adapters` are as
  `WardrikDaemon.Config.new/1` takes them.
  """

  use Supervisor

  require Logger

  alias WardrikDaemon.Config

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    store = Keyword.fetch!(opts, :store)

    case Config.load(opts) do
      {:ok, config} ->
        host = WardrikDaemon.host(config, store: store)

        children = [
          {WardrikDaemon.Host, host: host, config: config},
          {Wardrik.Core, host: host},
          {WardrikPolicy.Supervisor, store: store},
          {WardrikTrigger, store: store, host: host},
          {WardrikDaemon, host: host, config: config}
        ]

        Supervisor.init(children, strategy: :rest_for_one)

      {:error, message} ->
        Logger.error(message)
        exit({:config, message})
    end
  end
end
