defmodule WardrikStore.Conformance do
  @moduledoc """
  The tests every `WardrikStore` adapter passes.

      defmodule MyStore.PostgresTest do
        use ExUnit.Case, async: false
        use WardrikStore.Conformance, adapter: MyStore.Postgres
      end

  The adapter is expected to be running. Each test writes under a key of its
  own in the `:conformance` namespace and leaves it there, so the suite is safe
  to run against a store other tests share.
  """

  defmacro __using__(opts) do
    quote bind_quoted: [adapter: Keyword.fetch!(opts, :adapter)] do
      @adapter adapter
      @ns :conformance

      defp conformance_key(context), do: "#{context.test}/#{System.unique_integer([:positive])}"

      describe "#{inspect(@adapter)} as a WardrikStore" do
        test "hands back what it was given", context do
          key = conformance_key(context)

          assert {:ok, _vsn} = @adapter.put(@ns, key, %{"a" => 1}, [])
          assert @adapter.get(@ns, key, []) == %{"a" => 1}
          assert {%{"a" => 1}, _vsn} = @adapter.lookup(@ns, key)
        end

        test "a key nothing wrote is nil", context do
          key = conformance_key(context)

          assert @adapter.get(@ns, key, []) == nil
          assert @adapter.lookup(@ns, key) == nil
        end

        test "a later write replaces an earlier one", context do
          key = conformance_key(context)

          {:ok, _vsn} = @adapter.put(@ns, key, :old, [])
          {:ok, _vsn} = @adapter.put(@ns, key, :new, [])

          assert @adapter.get(@ns, key, []) == :new
        end

        test "writing where nothing is written succeeds once", context do
          key = conformance_key(context)

          assert {:ok, vsn} = @adapter.put(@ns, key, :first, if_vsn: nil)
          assert vsn != nil
          assert {:error, :conflict} = @adapter.put(@ns, key, :second, if_vsn: nil)
          assert @adapter.get(@ns, key, consistent: true) == :first
        end

        test "writing over a version succeeds only for the current one", context do
          key = conformance_key(context)

          {:ok, first} = @adapter.put(@ns, key, :first, if_vsn: nil)
          assert {:ok, second} = @adapter.put(@ns, key, :second, if_vsn: first)
          assert second != first
          assert {:error, :conflict} = @adapter.put(@ns, key, :third, if_vsn: first)
          assert {:second, ^second} = @adapter.lookup(@ns, key)
        end

        test "a version is never current again once the key is written over", context do
          key = conformance_key(context)

          {:ok, first} = @adapter.put(@ns, key, :same, if_vsn: nil)
          {:ok, second} = @adapter.put(@ns, key, :other, if_vsn: first)
          {:ok, _third} = @adapter.put(@ns, key, :same, if_vsn: second)

          assert {:error, :conflict} = @adapter.put(@ns, key, :stale, if_vsn: first)
          assert {:error, :conflict} = @adapter.delete(@ns, key, if_vsn: first)
          assert @adapter.get(@ns, key, consistent: true) == :same
        end

        test "keeps a key of any characters, and lists it by any prefix of it", context do
          base = conformance_key(context)
          key = base <> "/a b+c%d~e&f=g?h#i/ü✓/.hidden/../x"

          {:ok, _vsn} = @adapter.put(@ns, key, :odd, [])

          assert @adapter.get(@ns, key, []) == :odd
          assert @adapter.keys(@ns, base <> "/a b+c") == [key]
          assert @adapter.keys(@ns, base <> "/a b+c%d~e&f=g?h#i/ü✓/.") == [key]
          assert @adapter.keys(@ns, base <> "/a c") == []
        end

        test "keeps a key with an empty part, and lists it by the parts before", context do
          base = conformance_key(context)
          key = base <> "//tree//path"

          {:ok, _vsn} = @adapter.put(@ns, key, :parts, [])

          assert @adapter.get(@ns, key, []) == :parts
          assert @adapter.keys(@ns, base <> "/") == [key]
          assert @adapter.keys(@ns, base <> "//tree//") == [key]
          assert @adapter.keys(@ns, base <> "//tree/p") == []
        end

        test "matches a prefix as it is written, with nothing in it a wildcard", context do
          base = conformance_key(context)

          for key <- ["a_b", "axb", "a%b", "a\\b"],
              do: {:ok, _vsn} = @adapter.put(@ns, base <> key, 1, [])

          assert @adapter.keys(@ns, base <> "a_") == [base <> "a_b"]
          assert @adapter.keys(@ns, base <> "a%") == [base <> "a%b"]
          assert @adapter.keys(@ns, base <> "a\\") == [base <> "a\\b"]
        end

        test "hands back a large value whole", context do
          key = conformance_key(context)
          value = %{"bytes" => :crypto.strong_rand_bytes(1024 * 1024)}

          {:ok, _vsn} = @adapter.put(@ns, key, value, [])
          assert @adapter.get(@ns, key, []) == value
        end

        test "deleting removes the key, and deleting again is fine", context do
          key = conformance_key(context)

          {:ok, _vsn} = @adapter.put(@ns, key, :value, [])
          assert :ok = @adapter.delete(@ns, key, [])
          assert @adapter.get(@ns, key, []) == nil
          assert :ok = @adapter.delete(@ns, key, [])
        end

        test "a conditional delete removes only the version read", context do
          key = conformance_key(context)

          {:ok, first} = @adapter.put(@ns, key, :first, if_vsn: nil)
          {:ok, second} = @adapter.put(@ns, key, :second, if_vsn: first)

          assert {:error, :conflict} = @adapter.delete(@ns, key, if_vsn: first)
          assert {:second, ^second} = @adapter.lookup(@ns, key)

          assert :ok = @adapter.delete(@ns, key, if_vsn: second)
          assert @adapter.lookup(@ns, key) == nil
        end

        test "lists the keys under a prefix, in the namespace alone", context do
          prefix = conformance_key(context) <> "/"

          {:ok, _vsn} = @adapter.put(@ns, prefix <> "a", 1, [])
          {:ok, _vsn} = @adapter.put(@ns, prefix <> "b", 2, [])
          {:ok, _vsn} = @adapter.put(:conformance_other, prefix <> "c", 3, [])

          assert Enum.sort(@adapter.keys(@ns, prefix)) == [prefix <> "a", prefix <> "b"]
        end

        test "namespaces keep the same key apart", context do
          key = conformance_key(context)

          {:ok, _vsn} = @adapter.put(@ns, key, :here, [])
          assert @adapter.get(:conformance_other, key, []) == nil
        end
      end
    end
  end
end
