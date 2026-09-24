defmodule Tars.LedgerTest do
  use ExUnit.Case, async: true

  alias Tars.Ledger
  alias Tars.Ledger.Entry
  alias Tars.Tool.Result

  defmodule Raising do
    @behaviour Tars.Ledger

    @impl true
    def claim(_key, _call), do: raise("no store")

    @impl true
    def settle(_key, _result), do: raise("no store")

    @impl true
    def fetch(_key), do: raise("no store")
  end

  defmodule Wrong do
    @behaviour Tars.Ledger

    @impl true
    def claim(_key, _call), do: :maybe

    @impl true
    def settle(_key, _result), do: :maybe

    @impl true
    def fetch(_key), do: :maybe
  end

  setup do
    id = System.unique_integer([:positive])
    key = {"test/_/ledger-#{id}", "call_#{id}"}

    {:ok, key: key, call: %{id: elem(key, 1), name: "deploy", arguments: %{"env" => "prod"}}}
  end

  describe "claim/3 through the store" do
    test "a call nothing has run is the caller's to run", %{key: key, call: call} do
      assert :ok = Ledger.claim(Ledger.Store, key, call)
    end

    test "a second claim reports the first as pending", %{key: key, call: call} do
      assert :ok = Ledger.claim(Ledger.Store, key, call)

      assert {:pending, %Entry{call: ^call, result: nil, settled_at: nil}} =
               Ledger.claim(Ledger.Store, key, call)
    end

    test "a claim on a settled call reports the result", %{key: key, call: call} do
      result = Result.ok(%{"deployed" => true})

      assert :ok = Ledger.claim(Ledger.Store, key, call)
      assert :ok = Ledger.settle(Ledger.Store, key, result)
      assert {:settled, ^result} = Ledger.claim(Ledger.Store, key, call)
    end

    test "claims under different call ids do not collide", %{key: {agent, _id}, call: call} do
      assert :ok = Ledger.claim(Ledger.Store, {agent, "call_a"}, call)
      assert :ok = Ledger.claim(Ledger.Store, {agent, "call_b"}, call)
    end
  end

  describe "settle/3 through the store" do
    test "records what the call returned", %{key: key, call: call} do
      result = Result.error(:rate_limited)

      assert :ok = Ledger.claim(Ledger.Store, key, call)
      assert :ok = Ledger.settle(Ledger.Store, key, result)

      assert {:ok, %Entry{result: ^result, settled_at: settled_at}} =
               Ledger.fetch(Ledger.Store, key)

      assert is_integer(settled_at)
    end

    test "refuses a key nothing claimed", %{key: key} do
      assert {:error, :not_claimed} = Ledger.settle(Ledger.Store, key, Result.ok(%{}))
    end
  end

  describe "fetch/2 through the store" do
    test "answers :error for a key holding nothing", %{key: key} do
      assert :error = Ledger.fetch(Ledger.Store, key)
    end
  end

  describe "without a ledger" do
    test "every call is the caller's to run", %{key: key, call: call} do
      assert :ok = Ledger.claim(nil, key, call)
      assert :ok = Ledger.claim(nil, key, call)
    end

    test "settling does nothing", %{key: key} do
      assert :ok = Ledger.settle(nil, key, Result.ok(%{}))
    end

    test "nothing is held", %{key: key} do
      assert :error = Ledger.fetch(nil, key)
    end
  end

  describe "a ledger that cannot answer" do
    test "a raising claim stops the call", %{key: key, call: call} do
      assert {:error, message} = Ledger.claim(Raising, key, call)
      assert message =~ "no store"
    end

    test "a raising settle reports rather than raises", %{key: key} do
      assert {:error, message} = Ledger.settle(Raising, key, Result.ok(%{}))
      assert message =~ "no store"
    end

    test "a raising fetch holds nothing", %{key: key} do
      assert :error = Ledger.fetch(Raising, key)
    end

    test "an answer the behaviour does not name stops the call", %{key: key, call: call} do
      assert {:error, message} = Ledger.claim(Wrong, key, call)
      assert message =~ ":maybe"

      assert {:error, message} = Ledger.settle(Wrong, key, Result.ok(%{}))
      assert message =~ ":maybe"

      assert :error = Ledger.fetch(Wrong, key)
    end
  end

  describe "release" do
    defp claim_key, do: {"release-#{System.unique_integer([:positive])}/_/a", "trace/call_1"}
    defp a_call, do: %{id: "call_1", name: "connect", arguments: %{}}

    test "removes a claim that never settled, so the call can be claimed again" do
      key = claim_key()
      :ok = Tars.Ledger.claim(Tars.Ledger.Store, key, a_call())

      assert :ok = Tars.Ledger.release(Tars.Ledger.Store, key)
      assert :ok = Tars.Ledger.claim(Tars.Ledger.Store, key, a_call())
    end

    test "leaves a settled claim, and answers for one that was never made" do
      key = claim_key()
      :ok = Tars.Ledger.claim(Tars.Ledger.Store, key, a_call())
      :ok = Tars.Ledger.settle(Tars.Ledger.Store, key, {:ok, %{"done" => true}})

      assert :ok = Tars.Ledger.release(Tars.Ledger.Store, key)

      assert {:settled, {:ok, %{"done" => true}}} =
               Tars.Ledger.claim(Tars.Ledger.Store, key, a_call())

      assert :ok = Tars.Ledger.release(Tars.Ledger.Store, claim_key())
    end

    test "is a no-op without a ledger, or with one that keeps no releases" do
      assert :ok = Tars.Ledger.release(nil, claim_key())
      assert :ok = Tars.Ledger.release(Tars.Test.EchoTool, claim_key())
    end
  end
end
