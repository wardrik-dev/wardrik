defmodule WardrikLua.Sandbox.RunnerTest do
  use ExUnit.Case, async: true

  alias WardrikLua.Sandbox.Limits
  alias WardrikLua.Sandbox.Runner

  defp run(fun, opts \\ []), do: Runner.run(fun, Limits.new(opts))

  # Work that only ever ends when the runner stops it.
  defp blocked, do: receive(do: (:never -> {:ok, :never}))

  test "hands back what the evaluation returned" do
    assert run(fn -> {:ok, 4} end) == {:ok, 4}
    assert run(fn -> {:error, "no"} end) == {:error, "no"}
  end

  @tag :capture_log
  test "reports a crash rather than raising it in the caller" do
    assert {:error, message} = run(fn -> raise "boom" end)
    assert message =~ "the code crashed"
    assert message =~ "boom"
  end

  test "stops an evaluation that runs past its deadline" do
    assert run(&blocked/0, timeout_ms: 50) ==
             {:error, "the code ran for longer than 50ms and was stopped"}
  end

  test "runs the evaluation at low priority, out of the caller's way" do
    assert run(fn -> {:ok, Process.info(self(), :priority)} end) == {:ok, {:priority, :low}}
  end

  test "caps the evaluation's heap" do
    assert {:ok, {:max_heap_size, %{size: words, kill: true}}} =
             run(fn -> {:ok, Process.info(self(), :max_heap_size)} end, max_heap_bytes: 8_000_000)

    assert words == div(8_000_000, :erlang.system_info(:wordsize))
  end

  test "leaves the heap uncapped when the budget is lifted" do
    assert {:ok, {:max_heap_size, %{size: 0}}} =
             run(fn -> {:ok, Process.info(self(), :max_heap_size)} end, max_heap_bytes: :infinity)
  end

  test "stops an evaluation holding more binary than its budget" do
    hoard = fn ->
      {:ok, Enum.map(1..200, fn index -> :binary.copy("x", 100_000) <> "#{index}" end)}
    end

    assert {:error, message} = run(hoard, max_heap_bytes: 1_000_000, timeout_ms: 10_000)
    assert message =~ "more memory than it is allowed"
  end

  test "kills the evaluation when the caller dies" do
    test = self()

    caller =
      spawn(fn ->
        run(fn ->
          send(test, {:evaluating, self()})
          blocked()
        end)
      end)

    assert_receive {:evaluating, evaluation}
    reaped = Process.monitor(evaluation)
    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^reaped, :process, ^evaluation, :shutdown}
  end

  test "waits as long as it is told when nothing bounds it" do
    task =
      Task.async(fn ->
        run(fn -> {:ok, :eventually} end, timeout_ms: :infinity, max_heap_bytes: :infinity)
      end)

    assert Task.await(task) == {:ok, :eventually}
  end
end
