defmodule WardrikMCP.BootstrapTest do
  @moduledoc """
  A server that will not list its tools to a connection with no credential —
  which is what GitHub's does — has to offer some way to get one.
  """

  use WardrikMCP.Test.Case, async: false

  alias Wardrik.AgentID
  alias Wardrik.Credential
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.ToolRunner
  alias Wardrik.Scope
  alias WardrikMCP.Connection
  alias WardrikMCP.Server

  defmodule Vault do
    @moduledoc false
    defstruct []

    def resolve("locked", %Wardrik.Call{scope: scope}), do: locked(Scope.agent_id(scope))

    defp locked(%AgentID{org: org, user: "connected"}),
      do: {:ok, Credential.secret("a-token", owner: {org, "connected"})}

    defp locked(%AgentID{org: org, user: user}),
      do:
        {:error, {:authorization_required, %{url: "https://example.com/authorize"}, {org, user}}}
  end

  defimpl Wardrik.Credentials, for: Vault do
    def resolve(_vault, key, call), do: Vault.resolve(key, call)
    def refused(_vault, _ref, _call), do: :ok
    def key(_vault, _name), do: :error
  end

  # The stub refuses to list its tools without a token, the way a server
  # reached as a user does, so the deployment's own connection gets nothing.
  @moduletag server_opts: [
               credential: "locked",
               credential_env: "DEMO_TOKEN",
               transport_opts: [env: %{"STUB_REQUIRE_TOKEN" => "1"}]
             ]

  defp scope(key, user) do
    Config.new(tools: [{WardrikMCP, key}])
    |> Scope.root(AgentID.new!("a", org: "acme", user: user),
      host: Wardrik.Test.host(credentials: %Vault{})
    )
  end

  defp call(key, user, tool) do
    ToolRunner.execute(%{id: "c1", name: "#{key}__#{tool}", arguments: %{}}, scope(key, user))
  end

  setup %{key: key} do
    %{connect: "#{key}__connect"}
  end

  test "offers the tool that authorizes, and nothing else", context do
    %{key: key, connect: connect} = context

    assert Enum.map(WardrikMCP.tools(key), & &1.name) == [connect]
  end

  test "calling it parks on the link", context do
    %{key: key} = context

    assert %Wardrik.Call{state: :waiting, asks: [%{link: %{url: url}}]} =
             call(key, "someone", "connect")

    assert url =~ "https://example.com/authorize"
  end

  test "a user who authorizes gets the server's own tools in its place", context do
    %{key: key, connect: connect} = context

    assert %Wardrik.Call{state: :done} = call(key, "connected", "connect")

    names = Enum.map(WardrikMCP.tools(key), & &1.name)

    assert "#{key}__echo" in names
    refute connect in names
  end

  test "and a later listing by the deployment leaves those tools alone", context do
    %{key: key, connect: connect} = context
    %Wardrik.Call{state: :done} = call(key, "connected", "connect")

    # What a server saying its tools changed drives, without the wait that
    # collapses a burst of them. The deployment is still refused.
    send(Connection.whereis(key), :refresh)
    {:ok, _listed} = Connection.await(key)

    names = Enum.map(WardrikMCP.tools(key), & &1.name)

    assert "#{key}__echo" in names
    refute connect in names
  end

  test "and those tools then run as that user", context do
    %{key: key} = context
    %Wardrik.Call{state: :done} = call(key, "connected", "connect")

    secret = %{id: "c2", name: "#{key}__secret", arguments: %{"name" => "DEMO_TOKEN"}}

    assert [message] =
             Wardrik.LLM.ToolRunner.messages([
               ToolRunner.execute(secret, scope(key, "connected"))
             ])

    [part] = message.content
    assert part.text =~ "a-token"
  end

  test "a listing made on another node takes the place of the tool that authorizes", context do
    %{key: key} = context

    Connection.offer_listing(key, [%{"name" => "echo", "description" => "Hands the value back."}])

    assert {:ok, tools} = Connection.await(key)
    assert Enum.map(tools, & &1.name) == ["#{key}__echo"]
  end

  describe "a connection started after a user has connected elsewhere" do
    # What a node that starts later has: the deployment's connection, and no
    # connection of any user's.
    setup %{key: key, server_opts: opts} do
      %Wardrik.Call{state: :done} = call(key, "connected", "connect")
      :ok = Connection.close(key, {:owner, {"acme", "connected"}})
      :ok = WardrikMCP.disconnect(key)

      {:ok, _pid} = WardrikMCP.Supervisor.connect(Server.new(key, stub_options(opts)))
      started_with = Enum.map(WardrikMCP.tools(key), & &1.name)
      await_tools(key)

      %{started_with: started_with}
    end

    test "offers the server's own tools from the start", context do
      %{key: key, connect: connect, started_with: names} = context

      assert "#{key}__echo" in names
      refute connect in names
    end

    test "runs a call as the user who connected, over a connection it opens", context do
      %{key: key} = context
      refute Connection.running?(key, {:owner, {"acme", "connected"}})

      secret = %{id: "c2", name: "#{key}__secret", arguments: %{"name" => "DEMO_TOKEN"}}

      assert [message] =
               Wardrik.LLM.ToolRunner.messages([
                 ToolRunner.execute(secret, scope(key, "connected"))
               ])

      [part] = message.content
      assert part.text =~ "a-token"
    end

    test "parks a call from a user who has not connected on the link", context do
      %{key: key} = context

      echo = %{id: "c2", name: "#{key}__echo", arguments: %{"value" => "hello"}}

      assert %Wardrik.Call{state: :waiting, asks: [%{link: %{url: url}}]} =
               ToolRunner.execute(echo, scope(key, "someone"))

      assert url =~ "https://example.com/authorize"
    end
  end
end
