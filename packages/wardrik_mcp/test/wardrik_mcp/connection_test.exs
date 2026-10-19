defmodule WardrikMCP.ConnectionTest do
  use WardrikMCP.Test.Case, async: false

  alias Wardrik.Resource

  defp annotations(key, name), do: Wardrik.Tool.annotations({WardrikMCP, key}, name)

  describe "a server that filters its tools" do
    @describetag server_opts: [only: ~w(echo)]

    test "offers only what it was told to", %{key: key} do
      assert Enum.map(WardrikMCP.tools(key), & &1.name) == ["#{Resource.basename(key)}__echo"]
    end

    test "still calls a tool it does not offer, when asked directly", %{key: key} do
      assert {:ok, %{"ok" => true}} =
               WardrikMCP.call(key, "echo", %{"value" => "x"}, context())
    end
  end

  describe "a server left to say which of its tools may change something" do
    test "gates the tools it does not mark read-only", %{key: key} do
      refute annotations(key, "#{Resource.basename(key)}__echo").gated
      assert annotations(key, "#{Resource.basename(key)}__grow").gated
    end
  end

  describe "a server that gates some of its tools" do
    @describetag server_opts: [gated: ["ech*"]]

    test "gates those, and its answers are content from outside", %{key: key} do
      assert annotations(key, "#{Resource.basename(key)}__echo").gated
      assert annotations(:*, "#{Resource.basename(key)}__echo").gated
      refute annotations(key, "#{Resource.basename(key)}__secret").gated

      assert annotations(key, "#{Resource.basename(key)}__echo").labels == ["outside"]

      assert annotations(key, "#{Resource.basename(key)}__nothing_it_offers").labels == [
               "outside"
             ]
    end
  end

  describe "a server marked trusted" do
    @describetag server_opts: [trusted: true]

    test "answers with what is the deployment's own", %{key: key} do
      assert annotations(key, "#{Resource.basename(key)}__echo").labels == []
      assert annotations(:*, "#{Resource.basename(key)}__echo").labels == []
      refute annotations(key, "#{Resource.basename(key)}__echo").gated
    end
  end

  describe "a server given a credential" do
    @describetag server_opts: [transport_opts: [env: %{"DEMO_TOKEN" => "s3cret"}]]

    test "reads it from the environment it was started with", %{key: key} do
      assert {:ok, %{"result" => %{"content" => "s3cret"}}} =
               WardrikMCP.call(key, "secret", %{"name" => "DEMO_TOKEN"}, context())
    end

    test "and the credential is nowhere in the tools the model sees", %{key: key} do
      refute key |> WardrikMCP.tools() |> inspect() =~ "s3cret"
    end
  end

  describe "a server whose results are capped" do
    @describetag server_opts: [max_result_bytes: 16]

    test "cuts a long result and says so", %{key: key} do
      long = String.duplicate("a", 100)

      assert {:ok, %{"result" => %{"content" => content}}} =
               WardrikMCP.call(key, "echo", %{"value" => long}, context())

      assert content =~ "[cut:"
      assert content =~ String.duplicate("a", 16)
      refute content =~ String.duplicate("a", 20)
    end

    test "leaves a short result whole", %{key: key} do
      assert {:ok, %{"result" => %{"content" => "short"}}} =
               WardrikMCP.call(key, "echo", %{"value" => "short"}, context())
    end
  end

  describe "refresh/1" do
    test "asks the server for its tools again", %{key: key} do
      assert :ok = WardrikMCP.Connection.refresh(key)

      assert await_tools(key)
             |> Enum.map(& &1.name)
             |> Enum.member?("#{Resource.basename(key)}__echo")
    end
  end
end
