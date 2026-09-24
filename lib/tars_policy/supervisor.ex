defmodule TarsPolicy.Supervisor do
  @moduledoc """
  Runs the `TarsPolicy.Meter`s budgets are kept in, over the store the fleet
  runs on. A host that governs agents with budgets starts it once per node,
  after the fleet, as one of core's `:children`:

      config :tars, :children, [TarsPolicy.Supervisor]

  Without it a budget cannot be read, and a call it governs is refused.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    children = [
      {DurableServer.Supervisor,
       [
         name: TarsPolicy.Meter.supervisor(),
         prefix: "tars/meters/",
         backend: Tars.Store.durable_backend(),
         group: [log: Keyword.get(opts, :log, false)]
       ] ++ Tars.Store.durable_shutdown()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
