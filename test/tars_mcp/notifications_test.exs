defmodule TarsMCP.NotificationsTest do
  use TarsMCP.Case, async: false

  describe "a server that says its tools changed" do
    setup %{ref: ref} do
      handler = {__MODULE__, ref}
      test = self()

      :ok =
        :telemetry.attach(
          handler,
          [:tars_mcp, :connection, :listed],
          fn _event, _measurements, %{ref: listed}, _config -> send(test, {:listed, listed}) end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    test "is listed again without anyone asking", %{ref: ref} do
      refute "#{ref}__grown" in Enum.map(TarsMCP.tools(ref), & &1.name)

      assert {:ok, _result} = TarsMCP.call(ref, "grow", %{})

      assert_receive {:listed, ^ref}, 5_000
      assert "#{ref}__grown" in Enum.map(TarsMCP.tools(ref), & &1.name)
    end

    test "reaches a config naming every server", %{ref: ref} do
      config = Tars.LLM.Config.new(tools: [{TarsMCP, :*}])

      assert {:ok, _result} = TarsMCP.call(ref, "grow", %{})

      assert_receive {:listed, ^ref}, 5_000
      assert "#{ref}__grown" in Enum.map(Tars.LLM.Config.tools(config), & &1.name)
    end
  end

  describe "handle/4" do
    test "ignores a notification that is not about tools" do
      assert :ok =
               TarsMCP.Notifications.handle(
                 [:anubis_mcp, :client, :notification],
                 %{},
                 %{method: "resources/list_changed"},
                 nil
               )
    end
  end
end
