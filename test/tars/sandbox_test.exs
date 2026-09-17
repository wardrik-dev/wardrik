defmodule Tars.SandboxTest do
  use ExUnit.Case, async: true

  alias Tars.Sandbox
  alias Tars.Sandbox.Limits

  defmodule Reporting do
    @moduledoc "A sandbox that reports on the process it was given, and evaluates nothing."

    @behaviour Tars.Sandbox

    @impl true
    def check("unrunnable"), do: {:error, "this one cannot run"}
    def check(_code), do: :ok

    @impl true
    def evaluate("block", _limits), do: receive(do: (:never -> {:ok, :never}))

    def evaluate("where", _limits) do
      {:ok, %{pid: self(), priority: Process.info(self(), :priority)}}
    end

    def evaluate(code, limits), do: {:ok, {code, limits}}
  end

  describe "run/3" do
    test "hands back what the sandbox evaluated" do
      limits = Limits.new()

      assert Sandbox.run(Reporting, "anything", limits) == {:ok, {"anything", limits}}
    end

    test "refuses code the sandbox will not take, without evaluating it" do
      assert Sandbox.run(Reporting, "unrunnable", Limits.new()) == {:error, "this one cannot run"}
    end

    test "evaluates in a bounded process the sandbox did not have to start" do
      assert {:ok, %{pid: pid, priority: {:priority, :low}}} =
               Sandbox.run(Reporting, "where", Limits.new())

      refute pid == self()
    end

    test "stops an evaluation that runs past the deadline it was given" do
      assert {:error, message} = Sandbox.run(Reporting, "block", Limits.new(timeout_ms: 50))
      assert message =~ "longer than 50ms"
    end
  end
end
