defmodule WardrikMCP.NotificationsTest do
  use WardrikMCP.Case, async: false

  alias Wardrik.Test.Calls

  describe "a server that says its tools changed" do
    setup %{ref: ref} do
      handler = {__MODULE__, ref}
      test = self()

      :ok =
        :telemetry.attach(
          handler,
          [:wardrik_mcp, :connection, :listed],
          fn _event, _measurements, %{ref: listed}, _config -> send(test, {:listed, listed}) end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    test "is listed again without anyone asking", %{ref: ref} do
      refute "#{ref}__grown" in Enum.map(WardrikMCP.tools(ref), & &1.name)

      assert {:ok, _result} =
               WardrikMCP.call(ref, "grow", Calls.tool("grow", %{}))
               |> Calls.result()

      assert_receive {:listed, ^ref}, 5_000
      assert "#{ref}__grown" in Enum.map(WardrikMCP.tools(ref), & &1.name)
    end

    test "reaches a config naming every server", %{ref: ref} do
      config = Wardrik.LLM.Config.new(tools: [{WardrikMCP, :*}])

      assert {:ok, _result} =
               WardrikMCP.call(ref, "grow", Calls.tool("grow", %{}))
               |> Calls.result()

      assert_receive {:listed, ^ref}, 5_000
      assert "#{ref}__grown" in Enum.map(Wardrik.LLM.Config.tools(config), & &1.name)
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
