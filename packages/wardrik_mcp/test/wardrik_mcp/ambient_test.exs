defmodule WardrikMCP.AmbientTest do
  use WardrikMCP.Test.Case, async: false

  alias Wardrik.LLM.Config
  alias Wardrik.Resource

  describe "{WardrikMCP, :*}" do
    test "offers what the connected server offers", %{key: key} do
      assert WardrikMCP.tools(:*) == WardrikMCP.tools(key)
    end

    test "takes in a server that connects after it was named", %{key: key} do
      config = Config.new(tools: [{WardrikMCP, :*}])
      before = Config.tools(config)

      later = connect_another()

      names = config |> Config.tools() |> Enum.map(& &1.name)

      assert length(names) == length(before) + length(WardrikMCP.tools(later))
      assert "#{Resource.basename(key)}__echo" in names
      assert "#{Resource.basename(later)}__echo" in names
    end

    test "drops a server that disconnects", %{key: key} do
      later = connect_another()

      assert "#{Resource.basename(later)}__echo" in Enum.map(WardrikMCP.tools(:*), & &1.name)

      :ok = WardrikMCP.disconnect(later)

      names = Enum.map(WardrikMCP.tools(:*), & &1.name)
      refute "#{Resource.basename(later)}__echo" in names
      assert "#{Resource.basename(key)}__echo" in names
    end

    test "travels, and is still a source after it does", %{key: key} do
      loaded = [tools: [{WardrikMCP, :*}]] |> Config.new() |> Config.dump() |> Config.load()

      assert loaded.tools == [{WardrikMCP, :*}]
      assert "#{Resource.basename(key)}__echo" in Enum.map(Config.tools(loaded), & &1.name)
    end
  end

  defp connect_another do
    key = fresh_key()
    {:ok, _pid} = WardrikMCP.connect(key, stub_options())
    await_tools(key)

    key
  end
end

defmodule WardrikMCP.AmbientWithoutServersTest do
  use ExUnit.Case, async: false

  alias Wardrik.Resource

  test "a host that started no MCP servers offers none rather than raising" do
    assert WardrikMCP.Connection.keys() == []
    assert WardrikMCP.tools(:*) == []
    assert WardrikMCP.Connection.tools(Resource.parse!("deployment/server/absent")) == []
    assert WardrikMCP.Connection.keys_for(self()) == []
  end
end
