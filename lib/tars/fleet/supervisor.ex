defmodule Tars.Fleet.Supervisor do
  @moduledoc """
  Starts the substrate the fleet runs on.

  Two children, in order:

    * `EKV` - the durable store agent state is written to, replicated between
      connected nodes.
    * `DurableServer.Supervisor` - keyed processes over that store, named
      `Tars.Fleet`. It starts a `Group` instance under the same name, which is
      the registry `Tars.Fleet` and `Tars.Event.Bus` both read.

  ## Configuration

      config :tars, Tars.Fleet,
        enabled?: true,
        data_dir: "/var/lib/tars",
        cluster_size: 3,
        log: false

  `:data_dir` falls back to `TARS_DATA_DIR`, then to a directory named after
  the node under the system temp directory. `:cluster_size` is the number of
  voting members EKV does quorum arithmetic against. `:log` is passed to
  `Group`.
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
      {EKV,
       name: @ekv, data_dir: data_dir(opts), cluster_size: Keyword.get(opts, :cluster_size, 1)},
      {DurableServer.Supervisor,
       name: Tars.Fleet,
       prefix: Tars.Fleet.prefix(),
       backend: {DurableServer.Backends.EKVStore, name: @ekv},
       group: [log: Keyword.get(opts, :log, false)]}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc "Where this node's durable state is written. See the module options."
  @spec data_dir(keyword()) :: String.t()
  def data_dir(opts \\ []) do
    Keyword.get(opts, :data_dir) || System.get_env("TARS_DATA_DIR") ||
      Path.join([System.tmp_dir!(), "tars", to_string(node())])
  end
end
