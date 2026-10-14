defmodule WardrikS3.StoreTest do
  use ExUnit.Case, async: false

  alias WardrikS3.Store
  alias WardrikS3.Test.S3Bucket

  setup_all do
    S3Bucket.reset()
    store = WardrikStore.new([adapter: Store] ++ S3Bucket.store_opts(conditional_delete: true))
    start_supervised!({WardrikStore, store})
    %{store: store}
  end

  use WardrikStore.Conformance

  describe "a write whose answer is lost" do
    test "is answered as written where it landed", %{store: store} do
      S3Bucket.drop(:after)
      assert {:ok, vsn} = WardrikStore.put(store, :lost, "landed", :value, if_vsn: nil)
      assert WardrikStore.lookup(store, :lost, "landed") == {:value, vsn}
    end

    test "fails where it did not land, and the condition still holds", %{store: store} do
      S3Bucket.drop(:before)

      assert {:error, %Req.TransportError{reason: :timeout}} =
               WardrikStore.put(store, :lost, "missed", :value, if_vsn: nil)

      assert WardrikStore.lookup(store, :lost, "missed") == nil

      {:ok, vsn} = WardrikStore.put(store, :lost, "missed", :first)
      S3Bucket.drop(:before)

      assert {:error, %Req.TransportError{}} =
               WardrikStore.put(store, :lost, "missed", :second, if_vsn: vsn)

      S3Bucket.drop(:before)
      assert {:error, %Req.TransportError{}} = WardrikStore.put(store, :lost, "missed", :second)
    end

    test "conflicts where the condition no longer holds", %{store: store} do
      {:ok, first} = WardrikStore.put(store, :lost, "moved", :first)
      {:ok, _second} = WardrikStore.put(store, :lost, "moved", :second, if_vsn: first)

      S3Bucket.drop(:before)
      assert {:error, :conflict} = WardrikStore.put(store, :lost, "moved", :third, if_vsn: first)

      S3Bucket.drop(:before)
      assert {:error, :conflict} = WardrikStore.put(store, :lost, "moved", :third, if_vsn: nil)
    end

    test "conflicts where a version was named and nothing is written", %{store: store} do
      S3Bucket.drop(:before)

      assert {:error, :conflict} =
               WardrikStore.put(store, :lost, "never", :value, if_vsn: ~s("0"))
    end
  end

  describe "a delete whose answer is lost" do
    test "is done where the key is gone", %{store: store} do
      {:ok, vsn} = WardrikStore.put(store, :lost, "delete-landed", :value)
      S3Bucket.drop(:after)
      assert :ok = WardrikStore.delete(store, :lost, "delete-landed", if_vsn: vsn)
    end

    test "fails where the version is still there, and conflicts where another is", %{store: store} do
      {:ok, first} = WardrikStore.put(store, :lost, "delete-missed", :first)
      S3Bucket.drop(:before)

      assert {:error, %Req.TransportError{}} =
               WardrikStore.delete(store, :lost, "delete-missed", if_vsn: first)

      S3Bucket.drop(:before)
      assert {:error, %Req.TransportError{}} = WardrikStore.delete(store, :lost, "delete-missed")

      {:ok, _second} = WardrikStore.put(store, :lost, "delete-missed", :second, if_vsn: first)
      S3Bucket.drop(:before)

      assert {:error, :conflict} =
               WardrikStore.delete(store, :lost, "delete-missed", if_vsn: first)
    end
  end

  describe "a bucket that answers an error" do
    setup do
      on_exit(fn -> S3Bucket.refuse(nil) end)
    end

    test "fails a write and a delete with what it said", %{store: store} do
      S3Bucket.refuse(403)

      assert {:error, %WardrikS3.Error{status: 403, code: "Refused"}} =
               WardrikStore.put(store, :refused, "k", 1)

      assert {:error, %WardrikS3.Error{status: 403}} = WardrikStore.delete(store, :refused, "k")
    end

    test "raises on a read or a listing, since no answer would be true", %{store: store} do
      S3Bucket.refuse(500)

      assert_raise WardrikS3.Error, ~r/answered 500 Refused/, fn ->
        WardrikStore.get(store, :refused, "k")
      end

      assert_raise WardrikS3.Error, fn -> WardrikStore.keys(store, :refused, "") end
    end
  end

  test "lists every page of a prefix", %{store: store} do
    keys = for n <- 1..5, do: "paged/#{n}"
    for key <- keys, do: {:ok, _vsn} = WardrikStore.put(store, :pages, key, 1)

    assert WardrikStore.keys(store, :pages, "paged/") == keys
  end

  test "keeps the key an object is written under, and every prefix of it" do
    for key <- ["plain/key", "a b/ü/.x/..", "~tilde", "/lead//double/"] do
      assert Store.unescape(Store.escape(key)) == key
      assert String.starts_with?(Store.escape(key), Store.escape(String.slice(key, 0, 3)))
      assert Store.escape(key) =~ ~r{\A[A-Za-z0-9._~/-]*\z}
      refute Store.escape(key) =~ ~r{\A/|//}
    end
  end

  test "names WardrikStore.Durable to hold a fleet", %{store: store} do
    assert WardrikStore.durable_backend(store) ==
             {WardrikStore.Durable, store: store, discovery_interval_ms: 30_000}
  end
end

defmodule WardrikS3.StoreTombstoneTest do
  use ExUnit.Case, async: false

  alias WardrikS3.Store
  alias WardrikS3.Test.S3Bucket

  setup_all do
    S3Bucket.reset()
    store = WardrikStore.new([adapter: Store] ++ S3Bucket.store_opts(conditional_delete: false))
    start_supervised!({WardrikStore, store})
    %{store: store}
  end

  use WardrikStore.Conformance

  test "a conditional delete leaves a tombstone that reads, lists and writes as nothing", %{
    store: store
  } do
    {:ok, vsn} = WardrikStore.put(store, :tombstones, "k", :value)
    :ok = WardrikStore.delete(store, :tombstones, "k", if_vsn: vsn)

    assert WardrikStore.lookup(store, :tombstones, "k") == nil
    assert WardrikStore.keys(store, :tombstones, "") == []
    assert :ok = WardrikStore.delete(store, :tombstones, "k", if_vsn: vsn)
    assert {:ok, _vsn} = WardrikStore.put(store, :tombstones, "k", :again, if_vsn: nil)
    assert WardrikStore.get(store, :tombstones, "k") == :again
  end

  test "a lost tombstone is done where it landed", %{store: store} do
    {:ok, vsn} = WardrikStore.put(store, :tombstones, "lost", :value)
    S3Bucket.drop(:after)
    assert :ok = WardrikStore.delete(store, :tombstones, "lost", if_vsn: vsn)
  end
end

defmodule WardrikS3.StoreStartTest do
  use ExUnit.Case, async: false

  alias WardrikS3.Store
  alias WardrikS3.Test.S3Bucket

  setup do
    S3Bucket.reset()
    on_exit(fn -> S3Bucket.refuse(nil) end)
  end

  defp store(opts), do: WardrikStore.new([adapter: Store] ++ opts)
  defp check(opts), do: WardrikStore.check([adapter: Store] ++ opts)

  test "names the options it needs and was not given" do
    assert_raise ArgumentError,
                 "WardrikS3.Store needs :endpoint, :access_key_id, :secret_access_key",
                 fn -> WardrikStore.new(adapter: Store, bucket: "b") end
  end

  test "refuses a bucket that writes where a key is already written" do
    assert {:error,
            {:unconditional_bucket, "the bucket wrote a key where one was already written", _}} =
             Store.start_link(store(S3Bucket.store_opts(conditional_put: false)))
  end

  test "fails where the bucket cannot be written" do
    S3Bucket.refuse(403)

    assert {:error, %WardrikS3.Error{status: 403}} =
             Store.start_link(store(S3Bucket.store_opts()))
  end

  test "takes temporary credentials" do
    assert :ignore =
             Store.start_link(store(S3Bucket.store_opts([], session_token: "token")))
  end

  describe "check/1" do
    test "says what a bucket that keeps the contract does with a delete" do
      assert check(S3Bucket.store_opts(conditional_delete: true)) ==
               {:ok,
                "the bucket wardrik at http://s3.test refuses a write whose condition fails, " <>
                  "and deletes over a version"}

      assert {:ok, found} = check(S3Bucket.store_opts(conditional_delete: false))
      assert found =~ "deletes over any version, so a delete over one writes a tombstone"
    end

    test "says what a bucket let through" do
      assert check(S3Bucket.store_opts(conditional_put: false)) ==
               {:error,
                "the bucket wardrik at http://s3.test: the bucket wrote a key where one was " <>
                  "already written, so it cannot hold the store"}
    end

    test "says what the bucket answered" do
      S3Bucket.refuse(403)

      assert check(S3Bucket.store_opts()) ==
               {:error, "the bucket wardrik at http://s3.test: the bucket answered 403 Refused"}
    end

    test "names the options it needs" do
      assert check(bucket: "b", endpoint: "http://s3.test") ==
               {:error, "WardrikS3.Store needs :access_key_id, :secret_access_key"}
    end

    test "needs no other node" do
      assert WardrikStore.quorum(store(S3Bucket.store_opts()), 3) == 1
    end
  end

  test "a conditional delete before it starts finds how the bucket deletes" do
    store = WardrikStore.new([adapter: Store] ++ S3Bucket.store_opts(conditional_delete: true))
    {:ok, vsn} = WardrikStore.put(store, :unstarted, "k", :value)

    assert :ok = WardrikStore.delete(store, :unstarted, "k", if_vsn: vsn)
    assert WardrikStore.lookup(store, :unstarted, "k") == nil
  end

  test "a conditional delete raises where how the bucket deletes cannot be found" do
    store = WardrikStore.new([adapter: Store] ++ S3Bucket.store_opts([], prefix: "refused"))
    {:ok, vsn} = WardrikStore.put(store, :unstarted, "k", :value)
    S3Bucket.refuse(403)

    assert_raise WardrikS3.Error, fn ->
      WardrikStore.delete(store, :unstarted, "k", if_vsn: vsn)
    end
  end
end

defmodule WardrikS3.ErrorTest do
  use ExUnit.Case, async: true

  alias WardrikS3.Error

  test "reads the service's code from what it answered" do
    assert %Error{status: 409, code: "Busy", message: "the bucket answered 409 Busy"} =
             Error.exception(%Req.Response{status: 409, body: "<Error><Code>Busy</Code></Error>"})

    assert %Error{code: nil, message: "the bucket answered 500"} =
             Error.exception(%Req.Response{status: 500, body: nil})
  end

  test "says why no answer arrived" do
    assert Error.exception(%Req.TransportError{reason: :econnrefused}).message =~
             "could not be reached"

    assert Error.exception(:closed).message == "the bucket could not be reached: :closed"
  end
end
