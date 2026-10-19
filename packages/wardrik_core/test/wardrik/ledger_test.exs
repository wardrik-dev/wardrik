defmodule Wardrik.LedgerTest do
  use ExUnit.Case, async: true

  import Wardrik.Test, only: [store: 0]

  alias Wardrik.Ledger
  alias Wardrik.Ledger.Entry
  alias Wardrik.Tool.Result

  setup do
    id = System.unique_integer([:positive])
    key = {Wardrik.AgentID.new!("ledger-#{id}", org: "test"), "call_#{id}"}

    {:ok, key: key, call: %{id: elem(key, 1), name: "deploy", arguments: %{"env" => "prod"}}}
  end

  defp claim(key, call), do: Ledger.claim(store(), key, call: call)
  defp settle(key, result), do: Ledger.settle(store(), key, result: result)
  defp fetch(key), do: Ledger.fetch(store(), key)
  defp release(key), do: Ledger.release(store(), key)

  describe "claim/3" do
    test "a call nothing has run is the caller's to run", %{key: key, call: call} do
      assert :ok = claim(key, call)
    end

    test "a second claim reports the first as pending", %{key: key, call: call} do
      assert :ok = claim(key, call)

      assert {:pending, %Entry{call: ^call, result: nil, settled_at: nil}} = claim(key, call)
    end

    test "a claim on a settled call reports the result", %{key: key, call: call} do
      result = Result.ok(%{"deployed" => true})

      assert :ok = claim(key, call)
      assert :ok = settle(key, result)
      assert {:settled, ^result} = claim(key, call)
    end

    test "claims under different call ids do not collide", %{key: {agent, _id}, call: call} do
      assert :ok = claim({agent, "call_a"}, call)
      assert :ok = claim({agent, "call_b"}, call)
    end
  end

  describe "settle/3" do
    test "records what the call returned", %{key: key, call: call} do
      result = Result.error(:rate_limited)

      assert :ok = claim(key, call)
      assert :ok = settle(key, result)

      assert {:ok, %Entry{result: ^result, settled_at: settled_at}} = fetch(key)
      assert is_integer(settled_at)
    end

    test "refuses a key nothing claimed", %{key: key} do
      assert {:error, :not_claimed} = settle(key, Result.ok(%{}))
    end
  end

  describe "fetch/2" do
    test "answers :error for a key holding nothing", %{key: key} do
      assert :error = fetch(key)
    end
  end

  describe "forget/3" do
    test "removes every entry of the turn, and no other", %{call: call} do
      agent = Wardrik.AgentID.new!("forget-#{System.unique_integer([:positive])}", org: "test")
      :ok = claim({agent, "trace-a/call_1"}, call)
      :ok = claim({agent, "trace-b/call_1"}, call)

      assert :ok = Ledger.forget(store(), agent, trace: "trace-a")
      assert :error = fetch({agent, "trace-a/call_1"})
      assert {:ok, %Entry{}} = fetch({agent, "trace-b/call_1"})
    end
  end

  describe "release" do
    defp claim_key,
      do:
        {Wardrik.AgentID.new!("a", org: "release-#{System.unique_integer([:positive])}"),
         "trace/call_1"}

    defp a_call, do: %{id: "call_1", name: "connect", arguments: %{}}

    test "removes a claim that never settled, so the call can be claimed again" do
      key = claim_key()
      :ok = claim(key, a_call())

      assert :ok = release(key)
      assert :ok = claim(key, a_call())
    end

    test "leaves a settled claim, and answers for one that was never made" do
      key = claim_key()
      :ok = claim(key, a_call())
      :ok = settle(key, {:ok, %{"done" => true}})

      assert :ok = release(key)
      assert {:settled, {:ok, %{"done" => true}}} = claim(key, a_call())
      assert :ok = release(claim_key())
    end
  end
end
