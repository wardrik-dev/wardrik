defmodule WardrikMCP.ConnectionTest do
  use WardrikMCP.Test.Case, async: false

  defp annotations(ref, name), do: Wardrik.Tool.annotations({WardrikMCP, ref}, name)

  describe "a server that filters its tools" do
    @describetag server_opts: [only: ~w(echo)]

    test "offers only what it was told to", %{ref: ref} do
      assert Enum.map(WardrikMCP.tools(ref), & &1.name) == ["#{ref}__echo"]
    end

    test "still calls a tool it does not offer, when asked directly", %{ref: ref} do
      assert {:ok, %{"ok" => true}} =
               WardrikMCP.call(ref, "echo", %{"value" => "x"}, context())
    end
  end

  describe "a server left to say which of its tools may change something" do
    test "gates the tools it does not mark read-only", %{ref: ref} do
      refute annotations(ref, "#{ref}__echo").gated
      assert annotations(ref, "#{ref}__grow").gated
    end
  end

  describe "a server that gates some of its tools" do
    @describetag server_opts: [gated: ["ech*"]]

    test "gates those, and its answers are content from outside", %{ref: ref} do
      assert annotations(ref, "#{ref}__echo").gated
      assert annotations(:*, "#{ref}__echo").gated
      refute annotations(ref, "#{ref}__secret").gated

      assert annotations(ref, "#{ref}__echo").labels == ["outside"]
      assert annotations(ref, "#{ref}__nothing_it_offers").labels == ["outside"]
    end
  end

  describe "a server marked trusted" do
    @describetag server_opts: [trusted: true]

    test "answers with what is the deployment's own", %{ref: ref} do
      assert annotations(ref, "#{ref}__echo").labels == []
      assert annotations(:*, "#{ref}__echo").labels == []
      refute annotations(ref, "#{ref}__echo").gated
    end
  end

  describe "a server given a credential" do
    @describetag server_opts: [transport_opts: [env: %{"DEMO_TOKEN" => "s3cret"}]]

    test "reads it from the environment it was started with", %{ref: ref} do
      assert {:ok, %{"result" => %{"content" => "s3cret"}}} =
               WardrikMCP.call(ref, "secret", %{"name" => "DEMO_TOKEN"}, context())
    end

    test "and the credential is nowhere in the tools the model sees", %{ref: ref} do
      refute ref |> WardrikMCP.tools() |> inspect() =~ "s3cret"
    end
  end

  describe "a server whose results are capped" do
    @describetag server_opts: [max_result_bytes: 16]

    test "cuts a long result and says so", %{ref: ref} do
      long = String.duplicate("a", 100)

      assert {:ok, %{"result" => %{"content" => content}}} =
               WardrikMCP.call(ref, "echo", %{"value" => long}, context())

      assert content =~ "[cut:"
      assert content =~ String.duplicate("a", 16)
      refute content =~ String.duplicate("a", 20)
    end

    test "leaves a short result whole", %{ref: ref} do
      assert {:ok, %{"result" => %{"content" => "short"}}} =
               WardrikMCP.call(ref, "echo", %{"value" => "short"}, context())
    end
  end

  describe "refresh/1" do
    test "asks the server for its tools again", %{ref: ref} do
      assert :ok = WardrikMCP.Connection.refresh(ref)

      assert await_tools(ref) |> Enum.map(& &1.name) |> Enum.member?("#{ref}__echo")
    end
  end
end
