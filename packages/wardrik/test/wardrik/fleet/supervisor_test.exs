defmodule Wardrik.Fleet.SupervisorTest do
  use ExUnit.Case, async: true

  alias Wardrik.Fleet.Supervisor

  test "the fleet is running, with the store under it" do
    assert is_pid(Process.whereis(Supervisor))

    children = Supervisor |> Elixir.Supervisor.which_children() |> Enum.map(&elem(&1, 0))
    assert Wardrik.Store in children
  end
end
