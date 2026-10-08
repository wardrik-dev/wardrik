defmodule WardrikS3.StoreTest do
  use ExUnit.Case, async: false

  alias WardrikS3.Store
  alias WardrikS3.Test.S3Bucket

  setup_all do
    S3Bucket.reset()
    :ignore = Store.start_link(S3Bucket.store_opts(conditional_delete: true))
    :ok
  end

  use WardrikStore.Conformance, adapter: WardrikS3.Store

  describe "a write whose answer is lost" do
    test "is answered as written where it landed" do
      S3Bucket.drop(:after)
      assert {:ok, vsn} = Store.put(:lost, "landed", :value, if_vsn: nil)
      assert Store.lookup(:lost, "landed") == {:value, vsn}
    end

    test "fails where it did not land, and the condition still holds" do
      S3Bucket.drop(:before)

      assert {:error, %Req.TransportError{reason: :timeout}} =
               Store.put(:lost, "missed", :value, if_vsn: nil)

      assert Store.lookup(:lost, "missed") == nil

      {:ok, vsn} = Store.put(:lost, "missed", :first, [])
      S3Bucket.drop(:before)
      assert {:error, %Req.TransportError{}} = Store.put(:lost, "missed", :second, if_vsn: vsn)
      S3Bucket.drop(:before)
      assert {:error, %Req.TransportError{}} = Store.put(:lost, "missed", :second, [])
    end

    test "conflicts where the condition no longer holds" do
      {:ok, first} = Store.put(:lost, "moved", :first, [])
      {:ok, _second} = Store.put(:lost, "moved", :second, if_vsn: first)

      S3Bucket.drop(:before)
      assert {:error, :conflict} = Store.put(:lost, "moved", :third, if_vsn: first)

      S3Bucket.drop(:before)
      assert {:error, :conflict} = Store.put(:lost, "moved", :third, if_vsn: nil)
    end

    test "conflicts where a version was named and nothing is written" do
      S3Bucket.drop(:before)
      assert {:error, :conflict} = Store.put(:lost, "never", :value, if_vsn: ~s("0"))
    end
  end

  describe "a delete whose answer is lost" do
    test "is done where the key is gone" do
      {:ok, vsn} = Store.put(:lost, "delete-landed", :value, [])
      S3Bucket.drop(:after)
      assert :ok = Store.delete(:lost, "delete-landed", if_vsn: vsn)
    end

    test "fails where the version is still there, and conflicts where another is" do
      {:ok, first} = Store.put(:lost, "delete-missed", :first, [])
      S3Bucket.drop(:before)
      assert {:error, %Req.TransportError{}} = Store.delete(:lost, "delete-missed", if_vsn: first)
      S3Bucket.drop(:before)
      assert {:error, %Req.TransportError{}} = Store.delete(:lost, "delete-missed", [])

      {:ok, _second} = Store.put(:lost, "delete-missed", :second, if_vsn: first)
      S3Bucket.drop(:before)
      assert {:error, :conflict} = Store.delete(:lost, "delete-missed", if_vsn: first)
    end
  end

  describe "a bucket that answers an error" do
    setup do
      on_exit(fn -> S3Bucket.refuse(nil) end)
    end

    test "fails a write and a delete with what it said" do
      S3Bucket.refuse(403)

      assert {:error, %WardrikS3.Error{status: 403, code: "Refused"}} =
               Store.put(:refused, "k", 1, [])

      assert {:error, %WardrikS3.Error{status: 403}} = Store.delete(:refused, "k", [])
    end

    test "raises on a read or a listing, since no answer would be true" do
      S3Bucket.refuse(500)

      assert_raise WardrikS3.Error, ~r/answered 500 Refused/, fn ->
        Store.get(:refused, "k", [])
      end

      assert_raise WardrikS3.Error, fn -> Store.keys(:refused, "") end
    end
  end

  test "lists every page of a prefix" do
    keys = for n <- 1..5, do: "paged/#{n}"
    for key <- keys, do: {:ok, _vsn} = Store.put(:pages, key, 1, [])

    assert Store.keys(:pages, "paged/") == keys
  end

  test "keeps the key an object is written under, and every prefix of it" do
    for key <- ["plain/key", "a b/ü/.x/..", "~tilde", "/lead//double/"] do
      assert Store.unescape(Store.escape(key)) == key
      assert String.starts_with?(Store.escape(key), Store.escape(String.slice(key, 0, 3)))
      assert Store.escape(key) =~ ~r{\A[A-Za-z0-9._~/-]*\z}
      refute Store.escape(key) =~ ~r{\A/|//}
    end
  end

  test "names WardrikStore.Durable to hold a fleet" do
    assert Store.durable_backend([]) ==
             {WardrikStore.Durable, store: Store, discovery_interval_ms: 30_000}
  end
end

defmodule WardrikS3.StoreTombstoneTest do
  use ExUnit.Case, async: false

  alias WardrikS3.Store
  alias WardrikS3.Test.S3Bucket

  setup_all do
    S3Bucket.reset()
    :ignore = Store.start_link(S3Bucket.store_opts(conditional_delete: false))
    :ok
  end

  use WardrikStore.Conformance, adapter: WardrikS3.Store

  test "a conditional delete leaves a tombstone that reads, lists and writes as nothing" do
    {:ok, vsn} = Store.put(:tombstones, "k", :value, [])
    :ok = Store.delete(:tombstones, "k", if_vsn: vsn)

    assert Store.lookup(:tombstones, "k") == nil
    assert Store.keys(:tombstones, "") == []
    assert :ok = Store.delete(:tombstones, "k", if_vsn: vsn)
    assert {:ok, _vsn} = Store.put(:tombstones, "k", :again, if_vsn: nil)
    assert Store.get(:tombstones, "k", []) == :again
  end

  test "a lost tombstone is done where it landed" do
    {:ok, vsn} = Store.put(:tombstones, "lost", :value, [])
    S3Bucket.drop(:after)
    assert :ok = Store.delete(:tombstones, "lost", if_vsn: vsn)
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

  test "names the options it needs and was not given" do
    assert Store.start_link(bucket: "b") ==
             {:error, {:missing_options, [:endpoint, :access_key_id, :secret_access_key]}}
  end

  test "refuses a bucket that writes where a key is already written" do
    assert {:error,
            {:unconditional_bucket, "the bucket wrote a key where one was already written", _}} =
             Store.start_link(S3Bucket.store_opts(conditional_put: false))
  end

  test "fails where the bucket cannot be written" do
    S3Bucket.refuse(403)
    assert {:error, %WardrikS3.Error{status: 403}} = Store.start_link(S3Bucket.store_opts())
  end

  test "takes temporary credentials" do
    assert :ignore = Store.start_link(S3Bucket.store_opts([], session_token: "token"))
  end

  describe "check/1" do
    test "says what a bucket that keeps the contract does with a delete" do
      assert Store.check(S3Bucket.store_opts(conditional_delete: true)) ==
               {:ok,
                "the bucket wardrik at http://s3.test refuses a write whose condition fails, " <>
                  "and deletes over a version"}

      assert {:ok, found} = Store.check(S3Bucket.store_opts(conditional_delete: false))
      assert found =~ "deletes over any version, so a delete over one writes a tombstone"
    end

    test "says what a bucket let through" do
      assert Store.check(S3Bucket.store_opts(conditional_put: false)) ==
               {:error,
                "the bucket wardrik at http://s3.test: the bucket wrote a key where one was " <>
                  "already written, so it cannot hold the store"}
    end

    test "says what the bucket answered" do
      S3Bucket.refuse(403)

      assert Store.check(S3Bucket.store_opts()) ==
               {:error, "the bucket wardrik at http://s3.test: the bucket answered 403 Refused"}
    end

    test "names the options it needs" do
      assert Store.check(bucket: "b", endpoint: "http://s3.test") ==
               {:error, "the bucket b at http://s3.test needs access_key_id, secret_access_key"}
    end

    test "needs no other node" do
      assert Store.quorum(3) == 1
    end
  end

  test "a call before it starts says so" do
    :persistent_term.erase({Store, :config})
    assert_raise WardrikS3.Error, ~r/not started/, fn -> Store.get(:none, "k", []) end
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
