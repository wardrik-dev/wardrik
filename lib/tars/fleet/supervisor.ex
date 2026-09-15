defmodule Tars.Fleet.Supervisor do
  @moduledoc """
  Starts the substrate the fleet runs on.

  Two children, in order:

    * `EKV` - the durable store agent state is written to, replicated between
      connected nodes.
    * `DurableServer.Supervisor` - keyed processes over that store, named
      `Tars.Fleet`. It starts a `Group` instance under the same name, which is
      the registry `Tars.Fleet` reads.

  ## Configuration

      config :tars, Tars.Fleet,
        data_dir: "/var/lib/tars",
        cluster_size: 3,
        log: false

  `:data_dir` falls back to `TARS_DATA_DIR`, then to a directory named after
  the node in the user's data directory, `~/.local/share/tars` on Linux.
  `:cluster_size` is the number of
  voting members EKV does quorum arithmetic against, falling back to
  `TARS_CLUSTER_SIZE` and then to 1. `:log` is passed to `Group`.
  """

  use Supervisor

  @ekv :tars_fleet

  @doc "The name of the EKV instance holding the fleet's durable state."
  @spec store() :: atom()
  def store, do: @ekv

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    children = [
      {EKV, name: @ekv, data_dir: data_dir(opts), cluster_size: cluster_size(opts)},
      {DurableServer.Supervisor,
       name: Tars.Fleet,
       prefix: Tars.Fleet.prefix(),
       backend: {DurableServer.Backends.EKVStore, name: @ekv},
       group: [log: Keyword.get(opts, :log, false)]}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc "How many voting members EKV does quorum arithmetic against."
  @spec cluster_size(keyword()) :: pos_integer()
  def cluster_size(opts \\ []) do
    Keyword.get(opts, :cluster_size) || env_integer("TARS_CLUSTER_SIZE") || 1
  end

  defp env_integer(name) do
    with value when is_binary(value) <- System.get_env(name),
         {integer, ""} <- Integer.parse(value) do
      integer
    else
      _other -> nil
    end
  end

  @doc "Where this node's durable state is written. See the module options."
  @spec data_dir(keyword()) :: String.t()
  def data_dir(opts \\ []) do
    Keyword.get(opts, :data_dir) || System.get_env("TARS_DATA_DIR") ||
      Path.join(:filename.basedir(:user_data, "tars"), to_string(node()))
  end
end
