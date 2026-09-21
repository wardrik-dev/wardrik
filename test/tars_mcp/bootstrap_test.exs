defmodule TarsMCP.BootstrapTest do
  @moduledoc """
  A server that will not list its tools to a connection with no credential —
  which is what GitHub's does — has to offer some way to get one.
  """

  use Tars.Test.MCPCase, async: false

  alias Tars.Credential
  alias Tars.LLM.Config
  alias Tars.LLM.ToolRunner
  alias Tars.Scope

  defmodule Vault do
    @moduledoc false
    @behaviour Tars.Credential

    @impl true
    def resolve({:user, "locked"}, %Scope{user: "connected"}),
      do: {:ok, Credential.secret("a-token")}

    def resolve({:user, "locked"}, %Scope{}),
      do: {:error, {:authorization_required, "https://example.com/authorize"}}
  end

  # The stub refuses to list its tools without a token, the way a server
  # reached as a user does, so the deployment's own connection gets nothing.
  @moduletag server_opts: [
               credential: {:user, "locked"},
               credential_env: "DEMO_TOKEN",
               transport_opts: [env: %{"STUB_REQUIRE_TOKEN" => "1"}]
             ]

  defp scope(ref, user) do
    Config.new(tools: [{TarsMCP, ref}])
    |> Scope.root("acme/#{user}/a", user: user, credentials: Vault)
  end

  defp call(ref, user, tool) do
    ToolRunner.execute(%{id: "c1", name: "#{ref}__#{tool}", arguments: %{}}, scope(ref, user))
  end

  setup %{ref: ref} do
    %{connect: "#{ref}__connect"}
  end

  test "offers the tool that authorizes, and nothing else", context do
    %{ref: ref, connect: connect} = context

    assert Enum.map(TarsMCP.tools(ref), & &1.name) == [connect]
  end

  test "calling it parks on the link", context do
    %{ref: ref} = context

    assert {:parked, _call, prompt} = call(ref, "someone", "connect")
    assert prompt =~ "https://example.com/authorize"
  end

  test "a user who authorizes gets the server's own tools in its place", context do
    %{ref: ref, connect: connect} = context

    assert {:settled, _call, _message} = call(ref, "connected", "connect")

    names = Enum.map(TarsMCP.tools(ref), & &1.name)

    assert "#{ref}__echo" in names
    refute connect in names
  end

  test "and those tools then run as that user", context do
    %{ref: ref} = context
    {:settled, _call, _message} = call(ref, "connected", "connect")

    secret = %{id: "c2", name: "#{ref}__secret", arguments: %{"name" => "DEMO_TOKEN"}}

    assert {:settled, _call, message} = ToolRunner.execute(secret, scope(ref, "connected"))

    [part] = message.content
    assert part.text =~ "a-token"
  end
end
