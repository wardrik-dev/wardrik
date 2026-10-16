defmodule Wardrik.LedgerTest do
  use ExUnit.Case, async: true

  import Wardrik.Test, only: [store: 0]

  alias Wardrik.Ledger
  alias Wardrik.Ledger.Entry
  alias Wardrik.Ledger.Guarded
  alias Wardrik.Tool.Result

  defmodule Raising do
    defstruct []
  end

  defimpl Wardrik.Ledger, for: Raising do
    def claim(_ledger, _key, _opts), do: raise("no store")
    def settle(_ledger, _key, _opts), do: raise("no store")
    def fetch(_ledger, _key, _opts), do: raise("no store")
    def release(_ledger, _key, _opts), do: raise("no store")
    def forget(_ledger, _agent_id, _opts), do: raise("no store")
  end

  defmodule Wrong do
    defstruct []
  end

  defimpl Wardrik.Ledger, for: Wrong do
    def claim(_ledger, _key, _opts), do: :maybe
    def settle(_ledger, _key, _opts), do: :maybe
    def fetch(_ledger, _key, _opts), do: :maybe
    def release(_ledger, _key, _opts), do: :ok
    def forget(_ledger, _agent_id, _opts), do: :ok
  end

  @kept %Ledger.Store{}
  @none %Ledger.None{}

  setup do
    id = System.unique_integer([:positive])
    key = {"test/ledger-#{id}", "call_#{id}"}

    {:ok, key: key, call: %{id: elem(key, 1), name: "deploy", arguments: %{"env" => "prod"}}}
  end

  defp claim(ledger, key, call), do: Guarded.claim(ledger, key, call: call, store: store())

  defp settle(ledger, key, result),
    do: Guarded.settle(ledger, key, result: result, store: store())

  defp fetch(ledger, key), do: Guarded.fetch(ledger, key, store: store())
  defp release(ledger, key), do: Guarded.release(ledger, key, store: store())

  describe "claim/3 through the store" do
    test "a call nothing has run is the caller's to run", %{key: key, call: call} do
      assert :ok = claim(@kept, key, call)
    end

    test "a second claim reports the first as pending", %{key: key, call: call} do
      assert :ok = claim(@kept, key, call)

      assert {:pending, %Entry{call: ^call, result: nil, settled_at: nil}} =
               claim(@kept, key, call)
    end

    test "a claim on a settled call reports the result", %{key: key, call: call} do
      result = Result.ok(%{"deployed" => true})

      assert :ok = claim(@kept, key, call)
      assert :ok = settle(@kept, key, result)
      assert {:settled, ^result} = claim(@kept, key, call)
    end

    test "claims under different call ids do not collide", %{key: {agent, _id}, call: call} do
      assert :ok = claim(@kept, {agent, "call_a"}, call)
      assert :ok = claim(@kept, {agent, "call_b"}, call)
    end
  end

  describe "settle/3 through the store" do
    test "records what the call returned", %{key: key, call: call} do
      result = Result.error(:rate_limited)

      assert :ok = claim(@kept, key, call)
      assert :ok = settle(@kept, key, result)

      assert {:ok, %Entry{result: ^result, settled_at: settled_at}} = fetch(@kept, key)
      assert is_integer(settled_at)
    end

    test "refuses a key nothing claimed", %{key: key} do
      assert {:error, :not_claimed} = settle(@kept, key, Result.ok(%{}))
    end
  end

  describe "fetch/3 through the store" do
    test "answers :error for a key holding nothing", %{key: key} do
      assert :error = fetch(@kept, key)
    end
  end

  describe "forget/3 through the store" do
    test "removes every entry of the turn, and no other", %{call: call} do
      agent = "test/forget-#{System.unique_integer([:positive])}"
      :ok = claim(@kept, {agent, "trace-a/call_1"}, call)
      :ok = claim(@kept, {agent, "trace-b/call_1"}, call)

      assert :ok = Guarded.forget(@kept, agent, trace: "trace-a", store: store())
      assert :error = fetch(@kept, {agent, "trace-a/call_1"})
      assert {:ok, %Entry{}} = fetch(@kept, {agent, "trace-b/call_1"})
    end
  end

  describe "without a ledger" do
    test "every call is the caller's to run", %{key: key, call: call} do
      assert :ok = claim(@none, key, call)
      assert :ok = claim(@none, key, call)
    end

    test "settling, releasing and forgetting do nothing", %{key: key} do
      assert :ok = settle(@none, key, Result.ok(%{}))
      assert :ok = release(@none, key)
      assert :ok = Guarded.forget(@none, "test/none", trace: "t", store: store())
    end

    test "nothing is held", %{key: key} do
      assert :error = fetch(@none, key)
    end
  end

  describe "a ledger that cannot answer" do
    test "a raising claim stops the call", %{key: key, call: call} do
      assert {:error, message} = claim(%Raising{}, key, call)
      assert message =~ "no store"
    end

    test "a raising settle, release or forget reports rather than raises", %{key: key} do
      assert {:error, message} = settle(%Raising{}, key, Result.ok(%{}))
      assert message =~ "no store"
      assert {:error, _message} = release(%Raising{}, key)
      assert {:error, _message} = Guarded.forget(%Raising{}, "test/r", trace: "t", store: store())
    end

    test "a raising fetch holds nothing", %{key: key} do
      assert :error = fetch(%Raising{}, key)
    end

    test "an answer the protocol does not name stops the call", %{key: key, call: call} do
      assert {:error, message} = claim(%Wrong{}, key, call)
      assert message =~ ":maybe"

      assert {:error, message} = settle(%Wrong{}, key, Result.ok(%{}))
      assert message =~ "failed"

      assert :error = fetch(%Wrong{}, key)
    end
  end

  describe "release" do
    defp claim_key, do: {"release-#{System.unique_integer([:positive])}/a", "trace/call_1"}
    defp a_call, do: %{id: "call_1", name: "connect", arguments: %{}}

    test "removes a claim that never settled, so the call can be claimed again" do
      key = claim_key()
      :ok = claim(@kept, key, a_call())

      assert :ok = release(@kept, key)
      assert :ok = claim(@kept, key, a_call())
    end

    test "leaves a settled claim, and answers for one that was never made" do
      key = claim_key()
      :ok = claim(@kept, key, a_call())
      :ok = settle(@kept, key, {:ok, %{"done" => true}})

      assert :ok = release(@kept, key)
      assert {:settled, {:ok, %{"done" => true}}} = claim(@kept, key, a_call())
      assert :ok = release(@kept, claim_key())
    end
  end
end
