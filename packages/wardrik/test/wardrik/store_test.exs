defmodule Wardrik.StoreTest do
  use ExUnit.Case, async: false

  alias Wardrik.Store

  test "the configured adapter is the EKV one in this suite" do
    assert Store.adapter() == Wardrik.Store.EKV
  end

  test "the configured adapter is the one every call goes to" do
    settings = kept()
    :ignore = Store.configure(Keyword.put(settings, :adapter, Wardrik.StoreTest.Configured))
    on_exit(fn -> Store.configure(settings) end)

    assert Store.adapter() == Wardrik.StoreTest.Configured
    assert Store.config() == Keyword.delete(settings, :adapter)
    assert Store.quorum(3) == 7
    assert Store.check() == {:ok, "configured"}
  end

  test "the store keeps the settings it starts with" do
    settings = kept()
    on_exit(fn -> Store.configure(settings) end)

    spec = Store.child_spec(adapter: Wardrik.StoreTest.Elsewhere, bucket: "b")
    {module, function, args} = spec.start

    assert spec.id == Store
    assert apply(module, function, args) == :ignore
    assert Store.adapter() == Wardrik.StoreTest.Elsewhere
    assert Store.config() == [bucket: "b"]
  end

  test "settings naming no adapter name the EKV one" do
    settings = kept()
    on_exit(fn -> Store.configure(settings) end)

    :ignore = Store.configure(data_dir: "/nowhere")

    assert Store.adapter() == Wardrik.Store.EKV
    assert Store.config() == [data_dir: "/nowhere"]
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

  test "an adapter this node does not have is named, with what the optional ones need" do
    settings = kept()
    :ignore = Store.configure(adapter: Wardrik.StoreTest.Absent)
    on_exit(fn -> Store.configure(settings) end)

    message =
      "Wardrik.StoreTest.Absent is not a module this node has. WardrikEcto.Store needs " <>
        ":ecto_sql and :postgrex among the application's dependencies, and " <>
        "Wardrik.Store.EKV, the store where no adapter is named, needs :ekv"

    assert Store.check() == {:error, message}

    assert_raise ArgumentError, message, fn ->
      Store.child_spec(adapter: Wardrik.StoreTest.Absent)
    end
  end

  test "quorum/1 is the configured adapter's" do
    assert Store.quorum(3) == 2
  end

  test "durable_backend/0 is the adapter's" do
    assert {DurableServer.Backends.EKVStore, _opts} = Store.durable_backend()
  end

  test "durable_backend/1 is that of the adapter the settings name" do
    assert {Wardrik.Store.Durable, opts} = Store.durable_backend(adapter: Wardrik.Store.Memory)
    assert opts[:store] == Wardrik.Store.Memory
  end

  defp kept, do: [adapter: Store.adapter()] ++ Store.config()
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

defmodule Wardrik.StoreTest.Elsewhere do
  @moduledoc false
  # A store kept somewhere else, with nothing to run here.

  def child_spec(_opts), do: nil
end
