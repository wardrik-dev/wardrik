defmodule Wardrik.StoreTest do
  use ExUnit.Case, async: false

  alias Wardrik.Store

  test "the configured adapter is the EKV one in this suite" do
    assert Store.adapter() == Wardrik.Store.EKV
  end

  test "the configured adapter is the one every call goes to" do
    settings = Application.fetch_env!(:wardrik, Store)

    Application.put_env(
      :wardrik,
      Store,
      Keyword.put(settings, :adapter, Wardrik.StoreTest.Configured)
    )

    on_exit(fn -> Application.put_env(:wardrik, Store, settings) end)

    assert Store.adapter() == Wardrik.StoreTest.Configured
    assert Store.config() == Keyword.delete(settings, :adapter)
    assert Store.quorum(3) == 7
    assert Store.check() == {:ok, "configured"}
  end

  test "config/0 is the adapter's options without the adapter" do
    assert Keyword.has_key?(Store.config(), :data_dir)
    refute Keyword.has_key?(Store.config(), :adapter)
  end

  test "reads and writes go through the adapter" do
    key = "probe/#{System.unique_integer([:positive])}"

    assert {:ok, _vsn} = Store.put(:store_test, key, :ok)
    assert Store.get(:store_test, key) == :ok
    assert {:ok, _vsn} = Store.lookup(:store_test, key)
    assert key in Store.keys(:store_test, "probe/")
    assert :ok = Store.delete(:store_test, key)
    assert Store.get(:store_test, key) == nil
  end

  test "check/1 asks the adapter the settings name, the configured one by default" do
    assert {:ok, "on this node's disk, at " <> _dir} = Store.check()
    assert Store.check(adapter: Wardrik.Store.Memory) == {:ok, "in this node's memory"}
  end

  test "quorum/1 is the configured adapter's" do
    assert Store.quorum(3) == 2
  end

  test "durable_backend/0 is the adapter's" do
    assert {DurableServer.Backends.EKVStore, _opts} = Store.durable_backend()
  end
end

defmodule Wardrik.StoreTest.Configured do
  @moduledoc false
  # The suite's own store, under another name, so the suite runs on as it is
  # configured.

  @behaviour Wardrik.Store

  alias Wardrik.Store.EKV

  @impl Wardrik.Store
  defdelegate child_spec(opts), to: EKV

  @impl Wardrik.Store
  defdelegate durable_backend(opts), to: EKV

  @impl Wardrik.Store
  defdelegate put(ns, key, value, opts), to: EKV

  @impl Wardrik.Store
  defdelegate get(ns, key, opts), to: EKV

  @impl Wardrik.Store
  defdelegate lookup(ns, key), to: EKV

  @impl Wardrik.Store
  defdelegate delete(ns, key, opts), to: EKV

  @impl Wardrik.Store
  defdelegate keys(ns, prefix), to: EKV

  @impl Wardrik.Store
  def check(_opts), do: {:ok, "configured"}

  @impl Wardrik.Store
  def quorum(_size), do: 7
end
