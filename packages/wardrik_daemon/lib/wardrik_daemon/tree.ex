defmodule WardrikDaemon.Tree do
  @moduledoc """
  The daemon's tree, which a release starts once its store runs and its
  cluster has a quorum.

  As it starts, it reads `config.yaml` (see `WardrikDaemon.Config.load/1`),
  with what the environment does not set read from the vault in `:store`,
  builds the `Wardrik.Host` from it (see `WardrikDaemon.host/2`), and starts
  `Wardrik` on it: core, the budgets and the triggers, then the daemon's own
  processes and the packages, as the host's children, under
  `:rest_for_one`. A `config.yaml` that does not read stops the boot, with
  the reason logged.

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
    case Config.load(opts) do
      {:ok, config} ->
        host = WardrikDaemon.host(config, store: Keyword.fetch!(opts, :store))
        Supervisor.init([{Wardrik, host}], strategy: :one_for_one)

      {:error, message} ->
        Logger.error(message)
        exit({:config, message})
    end
  end
end
