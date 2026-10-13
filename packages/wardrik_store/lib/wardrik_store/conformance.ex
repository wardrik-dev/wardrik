defmodule WardrikStore.Conformance do
  @moduledoc """
  The tests every `WardrikStore` adapter passes.

      defmodule MyStore.PostgresTest do
        use ExUnit.Case, async: false
        use WardrikStore.Conformance

        setup_all do
          store = WardrikStore.new(adapter: MyStore.Postgres, url: "postgres://…")
          start_supervised!({WardrikStore, store})
          %{store: store}
        end
      end

  The tests run on the store under `:store` in each test's context, which
  is expected to be running. Each test writes under a key of its own in the
  `:conformance` namespace and leaves it there, so the suite is safe to run
  against a store other tests share.
  """

  defmacro __using__(_opts) do
    quote do
      @ns :conformance

      defp conformance_key(context), do: "#{context.test}/#{System.unique_integer([:positive])}"

      unquote(writing())
      unquote(listing())
    end
  end

  defp writing do
    quote do
      describe "a WardrikStore writing" do
        test "hands back what it was given", context do
          key = conformance_key(context)

          assert {:ok, _vsn} = WardrikStore.put(context.store, @ns, key, %{"a" => 1}, [])
          assert WardrikStore.get(context.store, @ns, key, []) == %{"a" => 1}
          assert {%{"a" => 1}, _vsn} = WardrikStore.lookup(context.store, @ns, key)
        end

        test "a key nothing wrote is nil", context do
          key = conformance_key(context)

          assert WardrikStore.get(context.store, @ns, key, []) == nil
          assert WardrikStore.lookup(context.store, @ns, key) == nil
        end

        test "a later write replaces an earlier one", context do
          key = conformance_key(context)

          {:ok, _vsn} = WardrikStore.put(context.store, @ns, key, :old, [])
          {:ok, _vsn} = WardrikStore.put(context.store, @ns, key, :new, [])

          assert WardrikStore.get(context.store, @ns, key, []) == :new
        end

        test "writing where nothing is written succeeds once", context do
          key = conformance_key(context)

          assert {:ok, vsn} = WardrikStore.put(context.store, @ns, key, :first, if_vsn: nil)
          assert vsn != nil

          assert {:error, :conflict} =
                   WardrikStore.put(context.store, @ns, key, :second, if_vsn: nil)

          assert WardrikStore.get(context.store, @ns, key, consistent: true) == :first
        end

        test "writing over a version succeeds only for the current one",
             %{store: store} = context do
          key = conformance_key(context)

          {:ok, first} = WardrikStore.put(context.store, @ns, key, :first, if_vsn: nil)
          assert {:ok, second} = WardrikStore.put(context.store, @ns, key, :second, if_vsn: first)
          assert second != first

          assert {:error, :conflict} =
                   WardrikStore.put(context.store, @ns, key, :third, if_vsn: first)

          assert {:second, ^second} = WardrikStore.lookup(context.store, @ns, key)
        end

        test "a version is never current again once the key is written over",
             %{store: store} = context do
          key = conformance_key(context)

          {:ok, first} = WardrikStore.put(context.store, @ns, key, :same, if_vsn: nil)
          {:ok, second} = WardrikStore.put(context.store, @ns, key, :other, if_vsn: first)
          {:ok, _third} = WardrikStore.put(context.store, @ns, key, :same, if_vsn: second)

          assert {:error, :conflict} =
                   WardrikStore.put(context.store, @ns, key, :stale, if_vsn: first)

          assert {:error, :conflict} = WardrikStore.delete(context.store, @ns, key, if_vsn: first)
          assert WardrikStore.get(context.store, @ns, key, consistent: true) == :same
        end

        test "keeps a key of any characters, and lists it by any prefix of it",
             %{store: store} = context do
          base = conformance_key(context)
          key = base <> "/a b+c%d~e&f=g?h#i/ü✓/.hidden/../x"

          {:ok, _vsn} = WardrikStore.put(context.store, @ns, key, :odd, [])

          assert WardrikStore.get(context.store, @ns, key, []) == :odd
          assert WardrikStore.keys(context.store, @ns, base <> "/a b+c") == [key]
          assert WardrikStore.keys(context.store, @ns, base <> "/a b+c%d~e&f=g?h#i/ü✓/.") == [key]
          assert WardrikStore.keys(context.store, @ns, base <> "/a c") == []
        end

        test "keeps a key with an empty part, and lists it by the parts before",
             %{store: store} = context do
          base = conformance_key(context)
          key = base <> "//tree//path"

          {:ok, _vsn} = WardrikStore.put(context.store, @ns, key, :parts, [])

          assert WardrikStore.get(context.store, @ns, key, []) == :parts
          assert WardrikStore.keys(context.store, @ns, base <> "/") == [key]
          assert WardrikStore.keys(context.store, @ns, base <> "//tree//") == [key]
          assert WardrikStore.keys(context.store, @ns, base <> "//tree/p") == []
        end

        test "matches a prefix as it is written, with nothing in it a wildcard",
             %{store: store} = context do
          base = conformance_key(context)

          for key <- ["a_b", "axb", "a%b", "a\\b"],
              do: {:ok, _vsn} = WardrikStore.put(context.store, @ns, base <> key, 1, [])

          assert WardrikStore.keys(context.store, @ns, base <> "a_") == [base <> "a_b"]
          assert WardrikStore.keys(context.store, @ns, base <> "a%") == [base <> "a%b"]
          assert WardrikStore.keys(context.store, @ns, base <> "a\\") == [base <> "a\\b"]
        end
      end
    end
  end

  defp listing do
    quote do
      describe "a WardrikStore deleting and listing" do
        test "hands back a large value whole", context do
          key = conformance_key(context)
          value = %{"bytes" => :crypto.strong_rand_bytes(1024 * 1024)}

          {:ok, _vsn} = WardrikStore.put(context.store, @ns, key, value, [])
          assert WardrikStore.get(context.store, @ns, key, []) == value
        end

        test "deleting removes the key, and deleting again is fine", context do
          key = conformance_key(context)

          {:ok, _vsn} = WardrikStore.put(context.store, @ns, key, :value, [])
          assert :ok = WardrikStore.delete(context.store, @ns, key, [])
          assert WardrikStore.get(context.store, @ns, key, []) == nil
          assert :ok = WardrikStore.delete(context.store, @ns, key, [])
        end

        test "a conditional delete removes only the version read", context do
          key = conformance_key(context)

          {:ok, first} = WardrikStore.put(context.store, @ns, key, :first, if_vsn: nil)
          {:ok, second} = WardrikStore.put(context.store, @ns, key, :second, if_vsn: first)

          assert {:error, :conflict} = WardrikStore.delete(context.store, @ns, key, if_vsn: first)
          assert {:second, ^second} = WardrikStore.lookup(context.store, @ns, key)

          assert :ok = WardrikStore.delete(context.store, @ns, key, if_vsn: second)
          assert WardrikStore.lookup(context.store, @ns, key) == nil
        end

        test "lists the keys under a prefix, in the namespace alone", context do
          prefix = conformance_key(context) <> "/"

          {:ok, _vsn} = WardrikStore.put(context.store, @ns, prefix <> "a", 1, [])
          {:ok, _vsn} = WardrikStore.put(context.store, @ns, prefix <> "b", 2, [])
          {:ok, _vsn} = WardrikStore.put(context.store, :conformance_other, prefix <> "c", 3, [])

          assert Enum.sort(WardrikStore.keys(context.store, @ns, prefix)) == [
                   prefix <> "a",
                   prefix <> "b"
                 ]
        end

        test "namespaces keep the same key apart", context do
          key = conformance_key(context)

          {:ok, _vsn} = WardrikStore.put(context.store, @ns, key, :here, [])
          assert WardrikStore.get(context.store, :conformance_other, key, []) == nil
        end
      end
    end
  end
end
