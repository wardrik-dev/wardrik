defmodule WardrikMCP.BootstrapTest do
  @moduledoc """
  A server that will not list its tools to a connection with no credential —
  which is what GitHub's does — has to offer some way to get one.
  """

  use WardrikMCP.Case, async: false

  alias Wardrik.Credential
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.ToolRunner
  alias Wardrik.Scope
  alias WardrikMCP.Connection
  alias WardrikMCP.Server

  defmodule Vault do
    @moduledoc false
    @behaviour Wardrik.Credential

    @impl true
    def resolve({:user, "locked"}, %Wardrik.Call{scope: %Scope{user: "connected"}}),
      do: {:ok, Credential.secret("a-token")}

    def resolve({:user, "locked"}, %Wardrik.Call{scope: %Scope{}}),
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
    Config.new(tools: [{WardrikMCP, ref}])
    |> Scope.root("acme/#{user}/a", org: "acme", user: user, credentials: Vault)
  end

  defp call(ref, user, tool) do
    ToolRunner.execute(%{id: "c1", name: "#{ref}__#{tool}", arguments: %{}}, scope(ref, user))
  end

  setup %{ref: ref} do
    %{connect: "#{ref}__connect"}
  end

  test "offers the tool that authorizes, and nothing else", context do
    %{ref: ref, connect: connect} = context

    assert Enum.map(WardrikMCP.tools(ref), & &1.name) == [connect]
  end

  test "calling it parks on the link", context do
    %{ref: ref} = context

    assert %Wardrik.Call{state: :waiting, asks: [%{link: %{url: url}}]} =
             call(ref, "someone", "connect")

    assert url =~ "https://example.com/authorize"
  end

  test "a user who authorizes gets the server's own tools in its place", context do
    %{ref: ref, connect: connect} = context

    assert %Wardrik.Call{state: :done} = call(ref, "connected", "connect")

    names = Enum.map(WardrikMCP.tools(ref), & &1.name)

    assert "#{ref}__echo" in names
    refute connect in names
  end

  test "and a later listing by the deployment leaves those tools alone", context do
    %{ref: ref, connect: connect} = context
    %Wardrik.Call{state: :done} = call(ref, "connected", "connect")

    # What a server saying its tools changed drives, without the wait that
    # collapses a burst of them. The deployment is still refused.
    send(Connection.whereis(ref), :refresh)
    {:ok, _listed} = Connection.await(ref)

    names = Enum.map(WardrikMCP.tools(ref), & &1.name)

    assert "#{ref}__echo" in names
    refute connect in names
  end

  test "and those tools then run as that user", context do
    %{ref: ref} = context
    %Wardrik.Call{state: :done} = call(ref, "connected", "connect")

    secret = %{id: "c2", name: "#{ref}__secret", arguments: %{"name" => "DEMO_TOKEN"}}

    assert [message] =
             Wardrik.LLM.ToolRunner.messages([
               ToolRunner.execute(secret, scope(ref, "connected"))
             ])

    [part] = message.content
    assert part.text =~ "a-token"
  end

  test "a listing made on another node takes the place of the tool that authorizes", context do
    %{ref: ref} = context

    Connection.offer_listing(ref, [%{"name" => "echo", "description" => "Hands the value back."}])

    assert {:ok, tools} = Connection.await(ref)
    assert Enum.map(tools, & &1.name) == ["#{ref}__echo"]
  end

  describe "a connection started after a user has connected elsewhere" do
    # What a node that starts later has: the deployment's connection, and no
    # connection of any user's.
    setup %{ref: ref, server_opts: opts} do
      %Wardrik.Call{state: :done} = call(ref, "connected", "connect")
      :ok = Connection.close(ref, {:user, "acme", "connected"})
      :ok = WardrikMCP.disconnect(ref)

      {:ok, _pid} = WardrikMCP.Supervisor.connect(Server.new(ref, stub_options(opts)))
      started_with = Enum.map(WardrikMCP.tools(ref), & &1.name)
      await_tools(ref)

      %{started_with: started_with}
    end

    test "offers the server's own tools from the start", context do
      %{ref: ref, connect: connect, started_with: names} = context

      assert "#{ref}__echo" in names
      refute connect in names
    end

    test "runs a call as the user who connected, over a connection it opens", context do
      %{ref: ref} = context
      refute Connection.running?(ref, {:user, "acme", "connected"})

      secret = %{id: "c2", name: "#{ref}__secret", arguments: %{"name" => "DEMO_TOKEN"}}

      assert [message] =
               Wardrik.LLM.ToolRunner.messages([
                 ToolRunner.execute(secret, scope(ref, "connected"))
               ])

      [part] = message.content
      assert part.text =~ "a-token"
    end

    test "parks a call from a user who has not connected on the link", context do
      %{ref: ref} = context

      echo = %{id: "c2", name: "#{ref}__echo", arguments: %{"value" => "hello"}}

      assert %Wardrik.Call{state: :waiting, asks: [%{link: %{url: url}}]} =
               ToolRunner.execute(echo, scope(ref, "someone"))

      assert url =~ "https://example.com/authorize"
    end
  end
end
