defmodule Wardrik.Test.Durable do
  @moduledoc """
  Checks that a `Wardrik.Store` adapter holds a `DurableServer` through a
  restart, through `Wardrik.Store.Durable`.

      test "holds a DurableServer in Postgres through a restart" do
        :ignore = WardrikEcto.Store.start_link(repo: MyApp.Repo)
        Wardrik.Test.Durable.survives_a_restart(WardrikEcto.Store, :durable_over_postgres)
      end

  `name` names the `DurableServer.Supervisor` the check starts, and the prefix
  it writes under, so checks of two adapters can run in one suite.
  """

  defmodule Counter do
    @moduledoc false
    use DurableServer, vsn: 1

    def dump_state(state), do: %{"count" => state.count}
    def load_state(_vsn, %{"count" => count}), do: %{count: count}

    def handle_call(:bump, _from, state) do
      state = %{state | count: state.count + 1}
      {:reply, state.count, state, sync: true}
    end
  end

  @doc "Counts to two under `store`, restarts the counter, and counts on to three."
  @spec survives_a_restart(module(), atom()) :: 3
  def survives_a_restart(store, name) do
    ExUnit.Callbacks.start_supervised!(
      {DurableServer.Supervisor,
       name: name,
       prefix: "#{name}/",
       backend:
         {Wardrik.Store.Durable,
          store: store, discovery_interval_ms: 200, heartbeat_interval_ms: 200},
       group: [log: false]},
      id: name
    )

    :ok = DurableServer.Supervisor.wait_until_ready(name, timeout: 10_000)
    key = "counter-#{System.unique_integer([:positive])}"
    spec = {Counter, key: key, initial_state: %{count: 0}}

    {:ok, {pid, _meta}} = DurableServer.Supervisor.start_child(name, spec)
    1 = GenServer.call(pid, :bump)
    2 = GenServer.call(pid, :bump)

    :ok = DurableServer.Supervisor.terminate_child(name, key)
    false = Process.alive?(pid)

    {:ok, {pid, _meta}} = DurableServer.Supervisor.start_child(name, spec)
    3 = GenServer.call(pid, :bump)
  end
end
