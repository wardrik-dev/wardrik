defmodule Wardrik.Store.Conformance do
  @moduledoc "The tests every `Wardrik.Store` adapter passes, run on the store under `:store`."

  defmacro __using__(_opts) do
    quote do
      import Wardrik.Store.Conformance, only: [unique_key: 1]

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
      describe "a Wardrik.Store writing" do
        setup %{store: store}, do: %{scoped: Wardrik.Store.scope(store, "conformance")}

        test "hands back what it was given", %{scoped: store} = context do
          key = unique_key(context)

          assert {:ok, _vsn} = Wardrik.Store.put(store, key, %{"a" => 1})
          assert Wardrik.Store.get(store, key) == %{"a" => 1}
          assert {%{"a" => 1}, _vsn} = Wardrik.Store.lookup(store, key)
        end

        test "a key nothing wrote is nil", %{scoped: store} = context do
          key = unique_key(context)

          assert Wardrik.Store.get(store, key) == nil
          assert Wardrik.Store.lookup(store, key) == nil
        end

        test "a later write replaces an earlier one", %{scoped: store} = context do
          key = unique_key(context)

          {:ok, _vsn} = Wardrik.Store.put(store, key, :old)
          {:ok, _vsn} = Wardrik.Store.put(store, key, :new)

          assert Wardrik.Store.get(store, key) == :new
        end

        test "hands back a large value whole", %{scoped: store} = context do
          key = unique_key(context)
          value = %{"bytes" => :crypto.strong_rand_bytes(1024 * 1024)}

          {:ok, _vsn} = Wardrik.Store.put(store, key, value)
          assert Wardrik.Store.get(store, key) == value
        end

        test "deleting removes the key, and deleting again is fine", %{scoped: store} = context do
          key = unique_key(context)

          {:ok, _vsn} = Wardrik.Store.put(store, key, :value)
          assert :ok = Wardrik.Store.delete(store, key)
          assert Wardrik.Store.get(store, key) == nil
          assert :ok = Wardrik.Store.delete(store, key)
        end
      end
    end
  end

  defp versions do
    quote do
      describe "a Wardrik.Store writing conditionally" do
        setup %{store: store}, do: %{scoped: Wardrik.Store.scope(store, "conformance")}

        test "writes where nothing is written only once", %{scoped: store} = context do
          key = unique_key(context)

          assert {:ok, vsn} = Wardrik.Store.put(store, key, :first, if_vsn: nil)
          assert vsn != nil
          assert {:error, :conflict} = Wardrik.Store.put(store, key, :second, if_vsn: nil)
          assert Wardrik.Store.get(store, key) == :first
        end

        test "writes over the current version only", %{scoped: store} = context do
          key = unique_key(context)

          {:ok, first} = Wardrik.Store.put(store, key, :first, if_vsn: nil)
          assert {:ok, second} = Wardrik.Store.put(store, key, :second, if_vsn: first)
          assert second != first
          assert {:error, :conflict} = Wardrik.Store.put(store, key, :third, if_vsn: first)
          assert {:second, ^second} = Wardrik.Store.lookup(store, key)
        end

        test "takes a plain write and delete over a key written conditionally",
             %{scoped: store} = context do
          key = unique_key(context)

          {:ok, _vsn} = Wardrik.Store.put(store, key, :first, if_vsn: nil)
          assert {:ok, _vsn} = Wardrik.Store.put(store, key, :second)
          assert Wardrik.Store.get(store, key) == :second
          assert :ok = Wardrik.Store.delete(store, key)
          assert Wardrik.Store.get(store, key) == nil
          assert {:ok, _vsn} = Wardrik.Store.put(store, key, :again, if_vsn: nil)
        end

        test "never takes a version again once it's written over", %{scoped: store} = context do
          key = unique_key(context)

          {:ok, first} = Wardrik.Store.put(store, key, :same, if_vsn: nil)
          {:ok, second} = Wardrik.Store.put(store, key, :other, if_vsn: first)
          {:ok, _third} = Wardrik.Store.put(store, key, :same, if_vsn: second)

          assert {:error, :conflict} = Wardrik.Store.put(store, key, :stale, if_vsn: first)
          assert {:error, :conflict} = Wardrik.Store.delete(store, key, if_vsn: first)
          assert Wardrik.Store.get(store, key) == :same
        end

        test "takes a version it never gave out as a conflict", %{scoped: store} = context do
          key = unique_key(context)

          assert {:error, :conflict} = Wardrik.Store.put(store, key, :first, if_vsn: "nope")
          {:ok, _vsn} = Wardrik.Store.put(store, key, :first, if_vsn: nil)
          assert {:error, :conflict} = Wardrik.Store.put(store, key, :second, if_vsn: "nope")
          assert {:error, :conflict} = Wardrik.Store.delete(store, key, if_vsn: "nope")
          assert Wardrik.Store.get(store, key) == :first
        end

        test "deletes only the version it names", %{scoped: store} = context do
          key = unique_key(context)

          {:ok, first} = Wardrik.Store.put(store, key, :first, if_vsn: nil)
          {:ok, second} = Wardrik.Store.put(store, key, :second, if_vsn: first)

          assert {:error, :conflict} = Wardrik.Store.delete(store, key, if_vsn: first)
          assert :ok = Wardrik.Store.delete(store, key, if_vsn: second)
          assert Wardrik.Store.lookup(store, key) == nil
        end
      end
    end
  end

  defp listing do
    quote do
      describe "a Wardrik.Store listing" do
        setup %{store: store}, do: %{scoped: Wardrik.Store.scope(store, "conformance")}

        test "lists the keys under a prefix, in order", %{scoped: store} = context do
          prefix = unique_key(context) <> "/"

          {:ok, _vsn} = Wardrik.Store.put(store, prefix <> "b", 2)
          {:ok, _vsn} = Wardrik.Store.put(store, prefix <> "a", 1)

          assert Wardrik.Store.keys(store, prefix) == [prefix <> "a", prefix <> "b"]
        end

        test "keeps a key of any characters, and lists it by any prefix",
             %{scoped: store} = context do
          base = unique_key(context)
          key = base <> "/a b+c%d~e&f=g?h#i/ü✓/.hidden/../x:y"

          {:ok, _vsn} = Wardrik.Store.put(store, key, :odd)

          assert Wardrik.Store.get(store, key) == :odd
          assert Wardrik.Store.keys(store, base <> "/a b+c") == [key]
          assert Wardrik.Store.keys(store, base <> "/a c") == []
        end

        test "matches a prefix as written, with no wildcards", %{scoped: store} = context do
          base = unique_key(context)

          for key <- ["a_b", "axb", "a%b", "a\\b"],
              do: {:ok, _vsn} = Wardrik.Store.put(store, base <> key, 1)

          assert Wardrik.Store.keys(store, base <> "a_") == [base <> "a_b"]
          assert Wardrik.Store.keys(store, base <> "a%") == [base <> "a%b"]
          assert Wardrik.Store.keys(store, base <> "a\\") == [base <> "a\\b"]
        end

        test "reads many keys at once, leaving out those that aren't there",
             %{scoped: store} = context do
          base = unique_key(context)
          {:ok, _vsn} = Wardrik.Store.put(store, base <> "a", 1)
          {:ok, _vsn} = Wardrik.Store.put(store, base <> "b", %{"b" => 2})

          assert Wardrik.Store.lookup_many(store, [base <> "a", base <> "b", base <> "c"]) == %{
                   (base <> "a") => Wardrik.Store.lookup(store, base <> "a"),
                   (base <> "b") => Wardrik.Store.lookup(store, base <> "b")
                 }

          assert Wardrik.Store.lookup_many(store, []) == %{}
        end

        test "lists the entries under a prefix, in order, with values and versions",
             %{scoped: store} = context do
          prefix = unique_key(context) <> "/"
          {:ok, _vsn} = Wardrik.Store.put(store, prefix <> "b", 2)
          {:ok, _vsn} = Wardrik.Store.put(store, prefix <> "a_", 1)
          {:ok, _vsn} = Wardrik.Store.put(store, prefix <> "a%", 0)
          {1, a} = Wardrik.Store.lookup(store, prefix <> "a_")
          {2, b} = Wardrik.Store.lookup(store, prefix <> "b")

          assert Wardrik.Store.entries(store, prefix <> "a_") == [{prefix <> "a_", 1, a}]

          assert [{_percent, 0, _vsn}, {_, 1, ^a}, {_, 2, ^b}] =
                   Wardrik.Store.entries(store, prefix)
        end

        test "lists the versions under a prefix, in order, without values",
             %{scoped: store} = context do
          prefix = unique_key(context) <> "/"
          {:ok, _vsn} = Wardrik.Store.put(store, prefix <> "b", 2)
          {:ok, _vsn} = Wardrik.Store.put(store, prefix <> "a_", 1)
          {:ok, _vsn} = Wardrik.Store.put(store, prefix <> "a%", 0)

          assert Wardrik.Store.versions(store, prefix) ==
                   for({key, _value, vsn} <- Wardrik.Store.entries(store, prefix), do: {key, vsn})

          assert [{key, _vsn}] = Wardrik.Store.versions(store, prefix <> "a_")
          assert key == prefix <> "a_"
        end
      end
    end
  end

  defp scoping do
    quote do
      describe "a Wardrik.Store scoped" do
        setup %{store: store} do
          run = "run#{System.unique_integer([:positive])}"
          %{outer: store |> Wardrik.Store.scope("conformance") |> Wardrik.Store.scope(run)}
        end

        test "keeps the same key apart in two scopes", %{outer: outer} = context do
          key = unique_key(context)
          here = Wardrik.Store.scope(outer, "here")
          there = Wardrik.Store.scope(outer, "there")

          {:ok, _vsn} = Wardrik.Store.put(here, key, :here)

          assert Wardrik.Store.get(there, key) == nil
          assert Wardrik.Store.keys(there, key) == []
        end

        test "never mistakes a key for a nested scope", %{outer: outer} = context do
          key = unique_key(context)
          inner = Wardrik.Store.scope(outer, "inner")

          {:ok, _vsn} = Wardrik.Store.put(outer, "inner/" <> key, :outer)
          {:ok, _vsn} = Wardrik.Store.put(outer, "inner:" <> key, :outer)

          assert Wardrik.Store.get(inner, key) == nil
          assert Wardrik.Store.keys(inner, key) == []
          assert Wardrik.Store.keys(outer, "inner") == ["inner/" <> key, "inner:" <> key]
        end
      end
    end
  end

  defp starting do
    quote do
      describe "a Wardrik.Store starting" do
        test "starts nothing where it's already running", %{store: store} = context do
          key = unique_key(context)
          {:ok, _vsn} = Wardrik.Store.put(store, key, :kept)

          assert {:ok, :undefined} =
                   start_supervised(Supervisor.child_spec({Wardrik.Store, store}, id: :again))

          assert Wardrik.Store.get(store, key) == :kept
        end
      end
    end
  end
end
