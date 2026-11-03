defmodule WardrikStore.Conformance do
  @moduledoc "The tests every `WardrikStore` adapter passes, run on the store under `:store`."

  defmacro __using__(_opts) do
    quote do
      import WardrikStore.Conformance, only: [unique_key: 1]

      unquote(writing())
      unquote(versions())
      unquote(listing())
      unquote(scoping())
      unquote(starting())
    end
  end

  @doc false
  def unique_key(context), do: "#{context.test}/#{System.unique_integer([:positive])}"

  defp writing do
    quote do
      describe "a WardrikStore writing" do
        setup %{store: store}, do: %{scoped: WardrikStore.scope(store, "conformance")}

        test "hands back what it was given", %{scoped: store} = context do
          key = unique_key(context)

          assert {:ok, _vsn} = WardrikStore.put(store, key, %{"a" => 1})
          assert WardrikStore.get(store, key) == %{"a" => 1}
          assert {%{"a" => 1}, _vsn} = WardrikStore.lookup(store, key)
        end

        test "a key nothing wrote is nil", %{scoped: store} = context do
          key = unique_key(context)

          assert WardrikStore.get(store, key) == nil
          assert WardrikStore.lookup(store, key) == nil
        end

        test "a later write replaces an earlier one", %{scoped: store} = context do
          key = unique_key(context)

          {:ok, _vsn} = WardrikStore.put(store, key, :old)
          {:ok, _vsn} = WardrikStore.put(store, key, :new)

          assert WardrikStore.get(store, key) == :new
        end

        test "hands back a large value whole", %{scoped: store} = context do
          key = unique_key(context)
          value = %{"bytes" => :crypto.strong_rand_bytes(1024 * 1024)}

          {:ok, _vsn} = WardrikStore.put(store, key, value)
          assert WardrikStore.get(store, key) == value
        end

        test "deleting removes the key, and deleting again is fine", %{scoped: store} = context do
          key = unique_key(context)

          {:ok, _vsn} = WardrikStore.put(store, key, :value)
          assert :ok = WardrikStore.delete(store, key)
          assert WardrikStore.get(store, key) == nil
          assert :ok = WardrikStore.delete(store, key)
        end
      end
    end
  end

  defp versions do
    quote do
      describe "a WardrikStore writing conditionally" do
        setup %{store: store}, do: %{scoped: WardrikStore.scope(store, "conformance")}

        test "writes where nothing is written only once", %{scoped: store} = context do
          key = unique_key(context)

          assert {:ok, vsn} = WardrikStore.put(store, key, :first, if_vsn: nil)
          assert vsn != nil
          assert {:error, :conflict} = WardrikStore.put(store, key, :second, if_vsn: nil)
          assert WardrikStore.get(store, key) == :first
        end

        test "writes over the current version only", %{scoped: store} = context do
          key = unique_key(context)

          {:ok, first} = WardrikStore.put(store, key, :first, if_vsn: nil)
          assert {:ok, second} = WardrikStore.put(store, key, :second, if_vsn: first)
          assert second != first
          assert {:error, :conflict} = WardrikStore.put(store, key, :third, if_vsn: first)
          assert {:second, ^second} = WardrikStore.lookup(store, key)
        end

        test "never takes a version again once it's written over", %{scoped: store} = context do
          key = unique_key(context)

          {:ok, first} = WardrikStore.put(store, key, :same, if_vsn: nil)
          {:ok, second} = WardrikStore.put(store, key, :other, if_vsn: first)
          {:ok, _third} = WardrikStore.put(store, key, :same, if_vsn: second)

          assert {:error, :conflict} = WardrikStore.put(store, key, :stale, if_vsn: first)
          assert {:error, :conflict} = WardrikStore.delete(store, key, if_vsn: first)
          assert WardrikStore.get(store, key) == :same
        end

        test "takes a version it never gave out as a conflict", %{scoped: store} = context do
          key = unique_key(context)

          assert {:error, :conflict} = WardrikStore.put(store, key, :first, if_vsn: "nope")
          {:ok, _vsn} = WardrikStore.put(store, key, :first, if_vsn: nil)
          assert {:error, :conflict} = WardrikStore.put(store, key, :second, if_vsn: "nope")
          assert {:error, :conflict} = WardrikStore.delete(store, key, if_vsn: "nope")
          assert WardrikStore.get(store, key) == :first
        end

        test "deletes only the version it names", %{scoped: store} = context do
          key = unique_key(context)

          {:ok, first} = WardrikStore.put(store, key, :first, if_vsn: nil)
          {:ok, second} = WardrikStore.put(store, key, :second, if_vsn: first)

          assert {:error, :conflict} = WardrikStore.delete(store, key, if_vsn: first)
          assert :ok = WardrikStore.delete(store, key, if_vsn: second)
          assert WardrikStore.lookup(store, key) == nil
        end
      end
    end
  end

  defp listing do
    quote do
      describe "a WardrikStore listing" do
        setup %{store: store}, do: %{scoped: WardrikStore.scope(store, "conformance")}

        test "lists the keys under a prefix, in order", %{scoped: store} = context do
          prefix = unique_key(context) <> "/"

          {:ok, _vsn} = WardrikStore.put(store, prefix <> "b", 2)
          {:ok, _vsn} = WardrikStore.put(store, prefix <> "a", 1)

          assert WardrikStore.keys(store, prefix) == [prefix <> "a", prefix <> "b"]
        end

        test "keeps a key of any characters, and lists it by any prefix",
             %{scoped: store} = context do
          base = unique_key(context)
          key = base <> "/a b+c%d~e&f=g?h#i/ü✓/.hidden/../x:y"

          {:ok, _vsn} = WardrikStore.put(store, key, :odd)

          assert WardrikStore.get(store, key) == :odd
          assert WardrikStore.keys(store, base <> "/a b+c") == [key]
          assert WardrikStore.keys(store, base <> "/a c") == []
        end

        test "matches a prefix as written, with no wildcards", %{scoped: store} = context do
          base = unique_key(context)

          for key <- ["a_b", "axb", "a%b", "a\\b"],
              do: {:ok, _vsn} = WardrikStore.put(store, base <> key, 1)

          assert WardrikStore.keys(store, base <> "a_") == [base <> "a_b"]
          assert WardrikStore.keys(store, base <> "a%") == [base <> "a%b"]
          assert WardrikStore.keys(store, base <> "a\\") == [base <> "a\\b"]
        end

        test "reads many keys at once, leaving out those that aren't there",
             %{scoped: store} = context do
          base = unique_key(context)
          {:ok, _vsn} = WardrikStore.put(store, base <> "a", 1)
          {:ok, _vsn} = WardrikStore.put(store, base <> "b", %{"b" => 2})

          assert WardrikStore.lookup_many(store, [base <> "a", base <> "b", base <> "c"]) == %{
                   (base <> "a") => WardrikStore.lookup(store, base <> "a"),
                   (base <> "b") => WardrikStore.lookup(store, base <> "b")
                 }

          assert WardrikStore.lookup_many(store, []) == %{}
        end

        test "lists the entries under a prefix, in order, with values and versions",
             %{scoped: store} = context do
          prefix = unique_key(context) <> "/"
          {:ok, _vsn} = WardrikStore.put(store, prefix <> "b", 2)
          {:ok, _vsn} = WardrikStore.put(store, prefix <> "a_", 1)
          {:ok, _vsn} = WardrikStore.put(store, prefix <> "a%", 0)
          {1, a} = WardrikStore.lookup(store, prefix <> "a_")
          {2, b} = WardrikStore.lookup(store, prefix <> "b")

          assert WardrikStore.entries(store, prefix <> "a_") == [{prefix <> "a_", 1, a}]

          assert [{_percent, 0, _vsn}, {_, 1, ^a}, {_, 2, ^b}] =
                   WardrikStore.entries(store, prefix)
        end

        test "lists the versions under a prefix, in order, without values",
             %{scoped: store} = context do
          prefix = unique_key(context) <> "/"
          {:ok, _vsn} = WardrikStore.put(store, prefix <> "b", 2)
          {:ok, _vsn} = WardrikStore.put(store, prefix <> "a_", 1)
          {:ok, _vsn} = WardrikStore.put(store, prefix <> "a%", 0)

          assert WardrikStore.versions(store, prefix) ==
                   for({key, _value, vsn} <- WardrikStore.entries(store, prefix), do: {key, vsn})

          assert [{key, _vsn}] = WardrikStore.versions(store, prefix <> "a_")
          assert key == prefix <> "a_"
        end
      end
    end
  end

  defp scoping do
    quote do
      describe "a WardrikStore scoped" do
        setup %{store: store} do
          run = "run#{System.unique_integer([:positive])}"
          %{outer: store |> WardrikStore.scope("conformance") |> WardrikStore.scope(run)}
        end

        test "keeps the same key apart in two scopes", %{outer: outer} = context do
          key = unique_key(context)
          here = WardrikStore.scope(outer, "here")
          there = WardrikStore.scope(outer, "there")

          {:ok, _vsn} = WardrikStore.put(here, key, :here)

          assert WardrikStore.get(there, key) == nil
          assert WardrikStore.keys(there, key) == []
        end

        test "never mistakes a key for a nested scope", %{outer: outer} = context do
          key = unique_key(context)
          inner = WardrikStore.scope(outer, "inner")

          {:ok, _vsn} = WardrikStore.put(outer, "inner/" <> key, :outer)
          {:ok, _vsn} = WardrikStore.put(outer, "inner:" <> key, :outer)

          assert WardrikStore.get(inner, key) == nil
          assert WardrikStore.keys(inner, key) == []
          assert WardrikStore.keys(outer, "inner") == ["inner/" <> key, "inner:" <> key]
        end
      end
    end
  end

  defp starting do
    quote do
      describe "a WardrikStore starting" do
        test "starts nothing where it's already running", %{store: store} = context do
          key = unique_key(context)
          {:ok, _vsn} = WardrikStore.put(store, key, :kept)

          assert {:ok, :undefined} =
                   start_supervised(Supervisor.child_spec({WardrikStore, store}, id: :again))

          assert WardrikStore.get(store, key) == :kept
        end
      end
    end
  end
end
