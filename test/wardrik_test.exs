defmodule WardrikTest do
  use ExUnit.Case, async: false

  test "the application starts Wardrik, and the fleet under it" do
    ids = for {id, _pid, _type, _modules} <- Supervisor.which_children(Wardrik.Supervisor), do: id

    assert Wardrik.Fleet.Supervisor in ids
    assert Wardrik.Access in ids
  end

  test "a host that starts Wardrik in its own tree has the application start nothing" do
    Application.put_env(:wardrik, :start, :host)
    on_exit(fn -> Application.delete_env(:wardrik, :start) end)

    {:ok, pid} = Wardrik.Application.start(:normal, [])

    assert Supervisor.which_children(pid) == []
    Supervisor.stop(pid)
  end
end
