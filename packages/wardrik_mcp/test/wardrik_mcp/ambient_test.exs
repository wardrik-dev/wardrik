defmodule WardrikMCP.AmbientTest do
  use WardrikMCP.Case, async: false

  alias Wardrik.LLM.Config

  describe "{WardrikMCP, :*}" do
    test "offers what the connected server offers", %{ref: ref} do
      assert WardrikMCP.tools(:*) == WardrikMCP.tools(ref)
    end

    test "takes in a server that connects after it was named", %{ref: ref} do
      config = Config.new(tools: [{WardrikMCP, :*}])
      before = Config.tools(config)

      later = connect_another()

      names = config |> Config.tools() |> Enum.map(& &1.name)

      assert length(names) == length(before) + length(WardrikMCP.tools(later))
      assert "#{ref}__echo" in names
      assert "#{later}__echo" in names
    end

    test "drops a server that disconnects", %{ref: ref} do
      later = connect_another()

      assert "#{later}__echo" in Enum.map(WardrikMCP.tools(:*), & &1.name)

      :ok = WardrikMCP.disconnect(later)

      names = Enum.map(WardrikMCP.tools(:*), & &1.name)
      refute "#{later}__echo" in names
      assert "#{ref}__echo" in names
    end

    test "travels, and is still a source after it does", %{ref: ref} do
      loaded = [tools: [{WardrikMCP, :*}]] |> Config.new() |> Config.dump() |> Config.load()

      assert loaded.tools == [{WardrikMCP, :*}]
      assert "#{ref}__echo" in Enum.map(Config.tools(loaded), & &1.name)
    end
  end

  defp connect_another do
    ref = fresh_ref()
    {:ok, _pid} = WardrikMCP.connect(ref, stub_options())
    await_tools(ref)

    ref
  end
end

defmodule WardrikMCP.AmbientWithoutServersTest do
  use ExUnit.Case, async: false

  test "a host that started no MCP servers offers none rather than raising" do
    assert WardrikMCP.Connection.refs() == []
    assert WardrikMCP.tools(:*) == []
    assert WardrikMCP.Connection.tools(:absent) == []
    assert WardrikMCP.Connection.refs_for(self()) == []
  end
end
