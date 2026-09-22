defmodule TarsMCP.NotificationsTest do
  use Tars.Test.MCPCase, async: false

  describe "a server that says its tools changed" do
    test "is listed again without anyone asking", %{ref: ref} do
      refute "#{ref}__grown" in Enum.map(TarsMCP.tools(ref), & &1.name)

      assert {:ok, _result} = TarsMCP.call(ref, "grow", %{})

      assert eventually(fn -> "#{ref}__grown" in Enum.map(TarsMCP.tools(ref), & &1.name) end),
             "the server's new tool never reached the offer"
    end

    test "reaches a config naming every server", %{ref: ref} do
      config = Tars.LLM.Config.new(tools: [{TarsMCP, :*}])

      assert {:ok, _result} = TarsMCP.call(ref, "grow", %{})

      assert eventually(fn ->
               "#{ref}__grown" in Enum.map(Tars.LLM.Config.tools(config), & &1.name)
             end)
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

  defp eventually(check, attempts \\ 50) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(100) && eventually(check, attempts - 1)
    end
  end
end
