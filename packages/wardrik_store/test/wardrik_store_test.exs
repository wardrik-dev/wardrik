defmodule WardrikStoreTest do
  use ExUnit.Case, async: false

  test "the configured adapter is the EKV one in this suite" do
    assert WardrikStore.adapter() == WardrikStore.EKV
  end

  test "the configured adapter is the one every call goes to" do
    settings = kept()
    :ignore = WardrikStore.configure(Keyword.put(settings, :adapter, WardrikStoreTest.Configured))
    on_exit(fn -> WardrikStore.configure(settings) end)

    assert WardrikStore.adapter() == WardrikStoreTest.Configured
    assert WardrikStore.config() == Keyword.delete(settings, :adapter)
    assert WardrikStore.quorum(3) == 7
    assert WardrikStore.check() == {:ok, "configured"}
  end

  test "the store keeps the settings it starts with" do
    settings = kept()
    on_exit(fn -> WardrikStore.configure(settings) end)

    spec = WardrikStore.child_spec(adapter: WardrikStoreTest.Elsewhere, bucket: "b")
    {module, function, args} = spec.start

    assert spec.id == WardrikStore
    assert apply(module, function, args) == :ignore
    assert WardrikStore.adapter() == WardrikStoreTest.Elsewhere
    assert WardrikStore.config() == [bucket: "b"]
  end

  test "settings naming no adapter name the EKV one" do
    settings = kept()
    on_exit(fn -> WardrikStore.configure(settings) end)

    :ignore = WardrikStore.configure(data_dir: "/nowhere")

    assert WardrikStore.adapter() == WardrikStore.EKV
    assert WardrikStore.config() == [data_dir: "/nowhere"]
  end

  test "config/0 is the adapter's options without the adapter" do
    assert Keyword.has_key?(WardrikStore.config(), :data_dir)
    refute Keyword.has_key?(WardrikStore.config(), :adapter)
  end

  test "reads and writes go through the adapter" do
    key = "probe/#{System.unique_integer([:positive])}"

    assert {:ok, _vsn} = WardrikStore.put(:store_test, key, :ok)
    assert WardrikStore.get(:store_test, key) == :ok
    assert {:ok, _vsn} = WardrikStore.lookup(:store_test, key)
    assert key in WardrikStore.keys(:store_test, "probe/")
    assert :ok = WardrikStore.delete(:store_test, key)
    assert WardrikStore.get(:store_test, key) == nil
  end

  test "check/1 asks the adapter the settings name, the configured one by default" do
    assert {:ok, "on this node's disk, at " <> _dir} = WardrikStore.check()
    assert WardrikStore.check(adapter: WardrikStore.Memory) == {:ok, "in this node's memory"}
  end

  test "an adapter this node does not have is named, with what the optional ones need" do
    settings = kept()
    :ignore = WardrikStore.configure(adapter: WardrikStoreTest.Absent)
    on_exit(fn -> WardrikStore.configure(settings) end)

    message =
      "WardrikStoreTest.Absent is not a module this node has. WardrikEcto.Store needs " <>
        ":ecto_sql and :postgrex among the application's dependencies, and " <>
        "WardrikStore.EKV, the store where no adapter is named, needs :ekv"

    assert WardrikStore.check() == {:error, message}

    assert_raise ArgumentError, message, fn ->
      WardrikStore.child_spec(adapter: WardrikStoreTest.Absent)
    end
  end

  test "quorum/1 is the configured adapter's" do
    assert WardrikStore.quorum(3) == 2
  end

  test "durable_backend/0 is the adapter's" do
    assert {DurableServer.Backends.EKVStore, _opts} = WardrikStore.durable_backend()
  end

  test "durable_backend/1 is that of the adapter the settings name" do
    assert {WardrikStore.Durable, opts} =
             WardrikStore.durable_backend(adapter: WardrikStore.Memory)

    assert opts[:store] == WardrikStore.Memory
  end

  defp kept, do: [adapter: WardrikStore.adapter()] ++ WardrikStore.config()
end

defmodule WardrikStoreTest.Configured do
  @moduledoc false
  # The suite's own store, under another name, so the suite runs on as it is
  # configured.

  @behaviour WardrikStore

  alias WardrikStore.EKV

  @impl WardrikStore
  defdelegate child_spec(opts), to: EKV

  @impl WardrikStore
  defdelegate durable_backend(opts), to: EKV

  @impl WardrikStore
  defdelegate put(ns, key, value, opts), to: EKV

  @impl WardrikStore
  defdelegate get(ns, key, opts), to: EKV

  @impl WardrikStore
  defdelegate lookup(ns, key), to: EKV

  @impl WardrikStore
  defdelegate delete(ns, key, opts), to: EKV

  @impl WardrikStore
  defdelegate keys(ns, prefix), to: EKV

  @impl WardrikStore
  def check(_opts), do: {:ok, "configured"}

  @impl WardrikStore
  def quorum(_size), do: 7
end

defmodule WardrikStoreTest.Elsewhere do
  @moduledoc false
  # A store kept somewhere else, with nothing to run here.

  def child_spec(_opts), do: nil
end
