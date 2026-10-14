defmodule Wardrik.Fleet.SupervisorTest do
  use ExUnit.Case, async: true

  alias Wardrik.Fleet.Supervisor

  test "the fleet is running" do
    assert is_pid(Process.whereis(Supervisor))

    children = Supervisor |> Elixir.Supervisor.which_children() |> Enum.map(&elem(&1, 0))
    assert children == [Wardrik.Fleet]
  end

  test "keeps the fleet in the host's store, and hands every agent the host" do
    host = Wardrik.Test.host()

    {:ok, {_flags, [%{start: {DurableServer.Supervisor, :start_link, [opts]}}]}} =
      Supervisor.init(host: host)

    assert opts[:backend] == WardrikStore.durable_backend(host.store)
    assert opts[:init_info] == %{host: host}
  end
end
