defmodule Tars.Fleet.SupervisorTest do
  use ExUnit.Case, async: true

  alias Tars.Fleet.Supervisor

  test "the fleet is running, with the store under it" do
    assert is_pid(Process.whereis(Supervisor))

    children = Supervisor |> Elixir.Supervisor.which_children() |> Enum.map(&elem(&1, 0))
    assert Tars.Store in children
  end
end
