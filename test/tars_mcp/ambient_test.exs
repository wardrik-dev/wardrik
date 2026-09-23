defmodule TarsMCP.AmbientTest do
  use TarsMCP.Case, async: false

  alias Tars.LLM.Config

  describe "{TarsMCP, :*}" do
    test "offers what the connected server offers", %{ref: ref} do
      assert TarsMCP.tools(:*) == TarsMCP.tools(ref)
    end

    test "takes in a server that connects after it was named", %{ref: ref} do
      config = Config.new(tools: [{TarsMCP, :*}])
      before = Config.tools(config)

      later = connect_another()

      names = config |> Config.tools() |> Enum.map(& &1.name)

      assert length(names) == length(before) + length(TarsMCP.tools(later))
      assert "#{ref}__echo" in names
      assert "#{later}__echo" in names
    end

    test "drops a server that disconnects", %{ref: ref} do
      later = connect_another()

      assert "#{later}__echo" in Enum.map(TarsMCP.tools(:*), & &1.name)

      :ok = TarsMCP.disconnect(later)

      names = Enum.map(TarsMCP.tools(:*), & &1.name)
      refute "#{later}__echo" in names
      assert "#{ref}__echo" in names
    end

    test "travels, and is still a source after it does", %{ref: ref} do
      loaded = [tools: [{TarsMCP, :*}]] |> Config.new() |> Config.dump() |> Config.load()

      assert loaded.tools == [{TarsMCP, :*}]
      assert "#{ref}__echo" in Enum.map(Config.tools(loaded), & &1.name)
    end
  end

  defp connect_another do
    ref = fresh_ref()
    {:ok, _pid} = TarsMCP.connect(ref, stub_options())
    await_tools(ref)

    ref
  end
end

defmodule TarsMCP.AmbientWithoutServersTest do
  use ExUnit.Case, async: false

  test "a host that started no MCP servers offers none rather than raising" do
    assert TarsMCP.Connection.refs() == []
    assert TarsMCP.tools(:*) == []
    assert TarsMCP.Connection.tools(:absent) == []
    assert TarsMCP.Connection.refs_for(self()) == []
  end
end
