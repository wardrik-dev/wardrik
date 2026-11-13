defmodule Wardrik.UnreadableTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Wardrik.Test.Wardrik

  alias Wardrik.Store.Durable
  alias Wardrik.Store.Durable.Unreadable

  @model "anthropic:claude-haiku-4-5"
  @why "it names WardrikGoneModule, which this release doesn't have"

  # A state naming a module no release has, written byte by byte so the atom is never
  # created: %{policy: WardrikGoneModule}.
  @gone <<131, 116, 0, 0, 0, 1, 119, 6, "policy", 119, 24, "Elixir.WardrikGoneModule">>

  setup context do
    started = start_wardrik(context)
    Map.put(started, :scope, owner(started.wardrik))
  end

  defp saved_as_gone(%{wardrik: wardrik, store: store, scope: scope}, id) do
    run!(scope, "agent.define", %{"agent" => id, "model" => @model})
    run!(scope, "agent.stop", %{"agent" => id})

    key =
      wardrik
      |> Wardrik.agents()
      |> WardrikCore.saved_key({id, nil})

    durable = Wardrik.Store.scope(store, "durable")
    {value, vsn} = Wardrik.Store.lookup(durable, key)
    {:ok, _vsn} = Wardrik.Store.put(durable, key, %{value | "state" => @gone}, if_vsn: vsn)
    key
  end

  test "refuses to start an agent whose saved state can't be read, and says why", context do
    saved_as_gone(context, "acme/old")

    log =
      capture_log(fn ->
        assert {:error, %Wardrik.Error{type: :conflict, message: message}} =
                 Wardrik.run(context.scope, "agent.ask", %{
                   "agent" => "acme/old",
                   "content" => "Hi"
                 })

        assert message ==
                 "acme/old can't start, as its saved state can't be read: #{@why}. Define it again to start it over; its definition, files and events stay."

        assert refused(context.scope, "agent.ask", %{"agent" => "acme/old", "content" => "Hi"}) ==
                 :conflict
      end)

    assert [_once] = Regex.scan(~r/can't be read/, log)
  end

  test "lists the agent as unreadable, with why", context do
    key = saved_as_gone(context, "acme/old")
    assert :ok != Durable.check(context.store, key)

    assert %{"agents" => [listed]} = run!(context.scope, "agents.list", %{})
    assert %{"id" => "acme/old", "status" => "unreadable", "problem" => @why} = listed

    assert %{"status" => "unreadable", "problem" => @why} =
             run!(context.scope, "agent.read", %{"agent" => "acme/old"})

    assert %{"agent" => %{"status" => "unreadable"}} =
             run!(context.scope, "agent.stop", %{"agent" => "acme/old"})
  end

  test "defining the agent again starts it over, and says so", context do
    key = saved_as_gone(context, "acme/old")
    capture_log(fn -> Durable.check(context.store, key) end)

    assert %{"reset" => [reset], "status" => status} =
             run!(context.scope, "agent.define", %{"agent" => "acme/old", "model" => @model})

    assert reset == "acme/old started over, as its saved state couldn't be read: #{@why}."
    assert status in ["idle", "running"]
    assert Durable.noted(context.store, key) == :error

    defined = run!(context.scope, "agent.define", %{"agent" => "acme/old", "model" => @model})
    refute Map.has_key?(defined, "reset")
  end

  test "notes a state only until it's written again", context do
    key = saved_as_gone(context, "acme/old")
    capture_log(fn -> Durable.check(context.store, key) end)
    assert {:ok, @why} = Durable.noted(context.store, key)

    durable = Wardrik.Store.scope(context.store, "durable")
    {value, vsn} = Wardrik.Store.lookup(durable, key)
    {:ok, _vsn} = Wardrik.Store.put(durable, key, value, if_vsn: vsn)

    assert Durable.noted(context.store, key) == :error
    assert Durable.check(context.store, "wardrik/agents/none") == :ok
  end

  describe "the reason" do
    test "names the modules a term names that this release doesn't have" do
      assert Unreadable.reason(@gone) == @why

      many =
        for n <- 1..7, into: <<131, 108, 0, 0, 0, 7>> do
          name = "Elixir.WardrikGone#{n}"
          <<119, byte_size(name), name::binary>>
        end

      assert Unreadable.reason(many <> <<106>>) ==
               "it names WardrikGone1, WardrikGone2, WardrikGone3, WardrikGone4, WardrikGone5 and 2 more, which this release doesn't have"

      assert Unreadable.reason(<<131, 119, 13, "wardrik_gone1">>) ==
               "it names :wardrik_gone1, which this release doesn't have"
    end

    test "reads every kind of term, and compressed ones" do
      term =
        {self(), make_ref(), [1.5, 2 | 3], "x", <<1::3>>, 10 ** 40, -(10 ** 300), 2 ** 40,
         &Enum.map/2, fn -> 1 end, %{a: :b}, ~c"chars", hd(Port.list()), 1.0e10}

      binary = :erlang.term_to_binary(term)
      assert {:ok, atoms} = Unreadable.atoms(binary)
      assert "Elixir.Enum" in atoms and "a" in atoms
      compressed = :erlang.term_to_binary(:b, compressed: 9)
      assert {:ok, ["b"]} = Unreadable.atoms(compressed)
      assert {:ok, ["latin"]} = Unreadable.atoms(<<131, 100, 0, 5, "latin">>)
      assert {:ok, ["s"]} = Unreadable.atoms(<<131, 115, 1, "s">>)
      assert {:ok, []} = Unreadable.atoms(<<131, 99>> <> String.duplicate("0", 31))
    end

    test "says so when a term can't be read at all" do
      for broken <- ["not a term", <<131, 255>>, <<131, 104, 2, 97>>, <<131, 112, 0, 0, 0, 9>>] do
        assert Unreadable.reason(broken) == "it isn't in a form this release can read"
      end

      map = :erlang.term_to_binary(%{a: 1})

      assert Unreadable.reason(map) ==
               "it isn't in a form this release can read"
    end

    test "loads a module a state names before calling it unreadable" do
      named = :erlang.term_to_binary(Enum)
      refute Unreadable.load_named(named)
      refute Unreadable.load_named("not a term")

      # Compiled by another VM, so this one has never seen the module's name.
      name = "WardrikLazy#{System.unique_integer([:positive])}"
      dir = Path.join(System.tmp_dir!(), name)
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      source = Path.join(dir, "lazy.ex")
      File.write!(source, "defmodule #{name}, do: defstruct [:x]")
      {_out, 0} = System.cmd("elixirc", ["-o", dir, source])
      true = Code.prepend_path(dir)

      module = "Elixir." <> name
      named = <<131, 119, byte_size(module), module::binary>>

      assert Unreadable.reason(named) == "it names #{name}, which this release doesn't have"
      assert Unreadable.load_named(named)
      assert :erlang.binary_to_term(named, [:safe]) == String.to_existing_atom(module)
    end
  end
end
