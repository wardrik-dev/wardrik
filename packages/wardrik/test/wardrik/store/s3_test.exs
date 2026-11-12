defmodule WardrikStore.S3Test do
  use ExUnit.Case, async: false

  alias WardrikStore.S3
  alias WardrikStore.Test.S3Bucket

  setup_all do
    S3Bucket.reset()
    store = S3.new(S3Bucket.store_opts(conditional_delete: true))
    start_supervised!({WardrikStore, store})
    %{store: store, lost: WardrikStore.scope(store, "lost")}
  end

  use WardrikStore.Conformance
  use WardrikStore.DurableConformance

  describe "a write whose answer is lost" do
    test "is answered as written where it landed", %{lost: store} do
      S3Bucket.drop(:after)
      assert {:ok, vsn} = WardrikStore.put(store, "landed", :value, if_vsn: nil)
      assert WardrikStore.lookup(store, "landed") == {:value, vsn}
    end

    test "fails where it didn't land, and the condition still holds", %{lost: store} do
      S3Bucket.drop(:before)

      assert {:error, %Req.TransportError{reason: :timeout}} =
               WardrikStore.put(store, "missed", :value, if_vsn: nil)

      assert WardrikStore.lookup(store, "missed") == nil

      {:ok, vsn} = WardrikStore.put(store, "missed", :first)
      S3Bucket.drop(:before)

      assert {:error, %Req.TransportError{}} =
               WardrikStore.put(store, "missed", :second, if_vsn: vsn)

      S3Bucket.drop(:before)
      assert {:error, %Req.TransportError{}} = WardrikStore.put(store, "missed", :second)
    end

    test "conflicts where the condition no longer holds", %{lost: store} do
      {:ok, first} = WardrikStore.put(store, "moved", :first)
      {:ok, _second} = WardrikStore.put(store, "moved", :second, if_vsn: first)

      S3Bucket.drop(:before)
      assert {:error, :conflict} = WardrikStore.put(store, "moved", :third, if_vsn: first)

      S3Bucket.drop(:before)
      assert {:error, :conflict} = WardrikStore.put(store, "moved", :third, if_vsn: nil)
    end

    test "conflicts where a version was named and nothing is written", %{lost: store} do
      S3Bucket.drop(:before)
      assert {:error, :conflict} = WardrikStore.put(store, "never", :value, if_vsn: ~s("0"))
    end
  end

  describe "a delete whose answer is lost" do
    test "is done where the key is gone", %{lost: store} do
      {:ok, vsn} = WardrikStore.put(store, "delete-landed", :value)
      S3Bucket.drop(:after)
      assert :ok = WardrikStore.delete(store, "delete-landed", if_vsn: vsn)
    end

    test "fails where the version is still there, and conflicts where another is", %{lost: store} do
      {:ok, first} = WardrikStore.put(store, "delete-missed", :first)
      S3Bucket.drop(:before)

      assert {:error, %Req.TransportError{}} =
               WardrikStore.delete(store, "delete-missed", if_vsn: first)

      S3Bucket.drop(:before)
      assert {:error, %Req.TransportError{}} = WardrikStore.delete(store, "delete-missed")

      {:ok, _second} = WardrikStore.put(store, "delete-missed", :second, if_vsn: first)
      S3Bucket.drop(:before)
      assert {:error, :conflict} = WardrikStore.delete(store, "delete-missed", if_vsn: first)
    end
  end

  describe "a bucket that answers an error" do
    setup do
      on_exit(fn -> S3Bucket.refuse(nil) end)
    end

    test "fails a write and a delete with what it said", %{lost: store} do
      S3Bucket.refuse(403)

      assert {:error, %S3.Error{status: 403, code: "Refused"}} = WardrikStore.put(store, "k", 1)
      assert {:error, %S3.Error{status: 403}} = WardrikStore.delete(store, "k")
    end

    test "raises on a read or a listing, since no answer would be true", %{lost: store} do
      S3Bucket.refuse(500)

      assert_raise S3.Error, ~r/answered 500 Refused/, fn -> WardrikStore.get(store, "k") end
      assert_raise S3.Error, fn -> WardrikStore.keys(store) end
    end
  end

  test "lists every page of a prefix", %{store: store} do
    store = WardrikStore.scope(store, "pages")
    keys = for n <- 1..5, do: "paged/#{n}"
    for key <- keys, do: {:ok, _vsn} = WardrikStore.put(store, key, 1)

    assert WardrikStore.keys(store, "paged/") == keys
    assert [{"paged/1", _vsn} | _more] = WardrikStore.versions(store, "paged/")
  end

  test "keeps the key an object is written under, and every prefix of it" do
    for key <- ["plain/key", "a b/ü/.x/..", "~tilde", "/lead//double/", "scope:key"] do
      assert S3.unescape(S3.escape(key)) == key
      assert String.starts_with?(S3.escape(key), S3.escape(String.slice(key, 0, 3)))
      assert S3.escape(key) =~ ~r{\A[A-Za-z0-9._~/-]*\z}
      refute S3.escape(key) =~ ~r{\A/|//}
    end
  end

  test "is shown without its credentials", %{store: store} do
    refute inspect(store) =~ "test-secret"
  end
end

defmodule WardrikStore.S3TombstoneTest do
  use ExUnit.Case, async: false

  alias WardrikStore.Test.S3Bucket

  setup_all do
    S3Bucket.reset()

    store =
      WardrikStore.S3.new(
        S3Bucket.store_opts([conditional_delete: false, no_such_key: true], prefix: "mo")
      )

    start_supervised!({WardrikStore, store})
    %{store: store}
  end

  use WardrikStore.Conformance

  test "a conditional delete leaves a tombstone that reads, lists and writes as nothing", %{
    store: store
  } do
    store = WardrikStore.scope(store, "tombstones")
    {:ok, vsn} = WardrikStore.put(store, "k", :value)
    :ok = WardrikStore.delete(store, "k", if_vsn: vsn)

    assert WardrikStore.lookup(store, "k") == nil
    assert WardrikStore.keys(store) == []
    assert :ok = WardrikStore.delete(store, "k", if_vsn: vsn)
    assert {:ok, _vsn} = WardrikStore.put(store, "k", :again, if_vsn: nil)
    assert WardrikStore.get(store, "k") == :again
  end

  test "a lost tombstone is done where it landed", %{store: store} do
    store = WardrikStore.scope(store, "tombstones")
    {:ok, vsn} = WardrikStore.put(store, "lost", :value)
    S3Bucket.drop(:after)
    assert :ok = WardrikStore.delete(store, "lost", if_vsn: vsn)
  end
end

defmodule WardrikStore.S3StartTest do
  use ExUnit.Case, async: false

  alias WardrikStore.S3
  alias WardrikStore.Test.S3Bucket

  setup do
    S3Bucket.reset()
    on_exit(fn -> S3Bucket.refuse(nil) end)
  end

  defp start(opts) do
    %WardrikStore{config: config} = S3.new(opts)
    S3.start_link(config)
  end

  test "names the options it needs and wasn't given" do
    assert_raise ArgumentError,
                 "WardrikStore.S3 needs :endpoint, :access_key_id, :secret_access_key",
                 fn -> S3.new(bucket: "b") end
  end

  test "refuses a bucket that writes where a key is already written" do
    assert {:error, "The bucket wardrik wrote a key where one was already written" <> _rest} =
             start(S3Bucket.store_opts([conditional_put: false], prefix: "unconditional"))
  end

  test "fails where the bucket can't be written" do
    S3Bucket.refuse(403)
    assert {:error, %S3.Error{status: 403}} = start(S3Bucket.store_opts([], prefix: "refusing"))
  end

  test "takes temporary credentials" do
    assert :ignore = start(S3Bucket.store_opts([], session_token: "token", prefix: "temporary"))
  end

  test "says why no answer arrived" do
    assert S3.Error.exception(%Req.TransportError{reason: :econnrefused}).message =~
             "Couldn't reach the bucket"

    assert S3.Error.exception(:closed).message == "Couldn't reach the bucket: :closed"
    assert %S3.Error{code: nil} = S3.Error.exception(%Req.Response{status: 500, body: nil})
  end

  test "a conditional delete before it starts finds how the bucket deletes" do
    store = S3.new(S3Bucket.store_opts([conditional_delete: true], prefix: "unstarted"))
    {:ok, vsn} = WardrikStore.put(store, "k", :value)

    assert :ok = WardrikStore.delete(store, "k", if_vsn: vsn)
    assert WardrikStore.lookup(store, "k") == nil
  end

  test "a conditional delete raises where how the bucket deletes can't be found" do
    store = S3.new(S3Bucket.store_opts([], prefix: "unprobed"))
    {:ok, vsn} = WardrikStore.put(store, "k", :value)
    S3Bucket.refuse(403)

    assert_raise S3.Error, fn -> WardrikStore.delete(store, "k", if_vsn: vsn) end
  end
end

if endpoint = System.get_env("S3_TEST_ENDPOINT") do
  defmodule WardrikStore.S3LiveTest do
    use ExUnit.Case, async: false
    use WardrikStore.Conformance
    use WardrikStore.DurableConformance

    @endpoint endpoint

    setup_all do
      opts = [
        bucket: System.get_env("S3_TEST_BUCKET", "wardrik-test"),
        endpoint: @endpoint,
        region: System.get_env("S3_TEST_REGION", "us-east-1"),
        access_key_id: System.get_env("S3_TEST_ACCESS_KEY_ID", "wardrik"),
        secret_access_key: System.get_env("S3_TEST_SECRET_ACCESS_KEY", "wardrik-secret"),
        prefix: "run-#{System.system_time(:millisecond)}"
      ]

      %{status: status} =
        Req.put!(
          Req.new(
            base_url: @endpoint,
            aws_sigv4: [
              access_key_id: opts[:access_key_id],
              secret_access_key: opts[:secret_access_key],
              region: opts[:region],
              service: :s3
            ],
            retry: false
          ),
          url: "/" <> opts[:bucket]
        )

      true = status in [200, 409]
      store = WardrikStore.S3.new(opts)
      start_supervised!({WardrikStore, store})
      %{store: store}
    end
  end
end
