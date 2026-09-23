defmodule TarsMCP.ConnectionTest do
  use TarsMCP.Case, async: false

  describe "a server that filters its tools" do
    @describetag server_opts: [only: ~w(echo)]

    test "offers only what it was told to", %{ref: ref} do
      assert Enum.map(TarsMCP.tools(ref), & &1.name) == ["#{ref}__echo"]
    end

    test "still calls a tool it does not offer, when asked directly", %{ref: ref} do
      assert {:ok, %{"ok" => true}} = TarsMCP.call(ref, "echo", %{"value" => "x"})
    end
  end

  describe "a server given a credential" do
    @describetag server_opts: [transport_opts: [env: %{"DEMO_TOKEN" => "s3cret"}]]

    test "reads it from the environment it was started with", %{ref: ref} do
      assert {:ok, %{"result" => %{"content" => "s3cret"}}} =
               TarsMCP.call(ref, "secret", %{"name" => "DEMO_TOKEN"})
    end

    test "and the credential is nowhere in the tools the model sees", %{ref: ref} do
      refute ref |> TarsMCP.tools() |> inspect() =~ "s3cret"
    end
  end

  describe "a server whose results are capped" do
    @describetag server_opts: [max_result_bytes: 16]

    test "cuts a long result and says so", %{ref: ref} do
      long = String.duplicate("a", 100)

      assert {:ok, %{"result" => %{"content" => content}}} =
               TarsMCP.call(ref, "echo", %{"value" => long})

      assert content =~ "[cut:"
      assert content =~ String.duplicate("a", 16)
      refute content =~ String.duplicate("a", 20)
    end

    test "leaves a short result whole", %{ref: ref} do
      assert {:ok, %{"result" => %{"content" => "short"}}} =
               TarsMCP.call(ref, "echo", %{"value" => "short"})
    end
  end

  describe "refresh/1" do
    test "asks the server for its tools again", %{ref: ref} do
      assert :ok = TarsMCP.Connection.refresh(ref)

      assert await_tools(ref) |> Enum.map(& &1.name) |> Enum.member?("#{ref}__echo")
    end
  end
end
