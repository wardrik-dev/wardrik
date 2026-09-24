defmodule Tars.TetherTest do
  use ExUnit.Case, async: true

  alias Tars.Tether

  defp tethered(owner) do
    test = self()

    spawn(fn ->
      :ok = Tether.to(owner)
      send(test, :tethered)
      receive do: (:never -> :ok)
    end)
  end

  test "the caller is killed when its owner exits" do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    caller = tethered(owner)
    assert_receive :tethered
    ref = Process.monitor(caller)

    send(owner, :stop)

    assert_receive {:DOWN, ^ref, :process, ^caller, :killed}
  end

  test "an owner outlives a caller that crashes" do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    caller = tethered(owner)
    assert_receive :tethered
    ref = Process.monitor(caller)

    Process.exit(caller, :boom)

    assert_receive {:DOWN, ^ref, :process, ^caller, :boom}
    assert Process.alive?(owner)
    send(owner, :stop)
  end
end
