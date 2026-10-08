defmodule WardrikPolicy.Supervisor do
  @moduledoc """
  Runs the `WardrikPolicy.Meter`s budgets are kept in, over the store the fleet
  runs on. A host that governs agents with budgets starts it once per node,
  after Wardrik in its own tree:

      children = [Wardrik, WardrikPolicy.Supervisor]

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
         name: WardrikPolicy.Meter.supervisor(),
         prefix: "meters/",
         backend: Wardrik.Store.durable_backend(),
         group: [log: Keyword.get(opts, :log, false)]
       ] ++ Wardrik.Store.durable_shutdown()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
