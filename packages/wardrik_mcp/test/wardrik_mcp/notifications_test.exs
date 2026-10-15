defmodule WardrikMCP.NotificationsTest do
  use WardrikMCP.Test.Case, async: false

  describe "a server that says its tools changed" do
    setup %{key: key} do
      handler = {__MODULE__, key}
      test = self()

      :ok =
        :telemetry.attach(
          handler,
          [:wardrik_mcp, :connection, :listed],
          fn _event, _measurements, %{key: listed}, _config -> send(test, {:listed, listed}) end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    test "is listed again without anyone asking", %{key: key} do
      refute "#{key}__grown" in Enum.map(WardrikMCP.tools(key), & &1.name)

      assert {:ok, _result} =
               WardrikMCP.call(key, "grow", %{}, context())

      assert_receive {:listed, ^key}, 5_000
      assert "#{key}__grown" in Enum.map(WardrikMCP.tools(key), & &1.name)
    end

    test "reaches a config naming every server", %{key: key} do
      config = Wardrik.LLM.Config.new(tools: [{WardrikMCP, :*}])

      assert {:ok, _result} =
               WardrikMCP.call(key, "grow", %{}, context())

      assert_receive {:listed, ^key}, 5_000
      assert "#{key}__grown" in Enum.map(Wardrik.LLM.Config.tools(config), & &1.name)
    end
  end

  describe "handle/4" do
    test "ignores a notification that is not about tools" do
      assert :ok =
               WardrikMCP.Notifications.handle(
                 [:anubis_mcp, :client, :notification],
                 %{},
                 %{method: "resources/list_changed"},
                 nil
               )
    end
  end
end
