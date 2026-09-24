defmodule Tars.Fleet.Supervisor do
  @moduledoc """
  Starts the substrate the fleet runs on.

  Three children, in order:

    * `Tars.Store` - the durable store agent state is written to, as the
      deployment configured it.
    * `DurableServer.Supervisor` - keyed processes over that store, named
      `Tars.Fleet`. It starts a `Group` instance under the same name, which is
      the registry `Tars.Fleet` reads.
    * `DurableServer.Supervisor` - the same for `Tars.Schedule`, named
      `Tars.Schedules`.

  ## Configuration

      config :tars, Tars.Store, adapter: Tars.Store.EKV, data_dir: "/var/lib/tars"
      config :tars, Tars.Fleet, log: false

  The store's options belong to its adapter; see `Tars.Store.EKV`. `:log` is
  passed to `Group`.
  """

  use Supervisor

  alias Tars.Store

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    children = [
      Store.child_spec(),
      {DurableServer.Supervisor,
       name: Tars.Fleet,
       prefix: Tars.Fleet.prefix(),
       backend: Store.durable_backend(),
       group: [log: Keyword.get(opts, :log, false)]},
      {DurableServer.Supervisor,
       name: Tars.Schedule.supervisor(),
       prefix: Tars.Schedule.prefix(),
       backend: Store.durable_backend(),
       group: [log: Keyword.get(opts, :log, false)]}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
