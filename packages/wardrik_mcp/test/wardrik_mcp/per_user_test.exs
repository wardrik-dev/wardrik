defmodule WardrikMCP.PerUserTest do
  use WardrikMCP.Test.Case, async: false

  alias Wardrik.Credential
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.ToolRunner
  alias Wardrik.Scope
  alias Wardrik.Test.Calls
  alias WardrikMCP.Connection

  # Resolves stub as a vault would: each connected user's own, and an org's
  # for an agent with no user, each saying whose it is.
  defmodule Vault do
    @moduledoc false
    @behaviour Wardrik.Credential

    @impl true
    def resolve("stub", %Wardrik.Call{scope: %Scope{org: org, user: nil}}),
      do: {:ok, Credential.secret("token-for-#{org}", owner: org)}

    def resolve("stub", %Wardrik.Call{scope: %Scope{org: "globex", user: "connected"}}),
      do: {:ok, Credential.secret("token-for-globex-connected", owner: {"globex", "connected"})}

    def resolve("stub", %Wardrik.Call{scope: %Scope{org: org, user: "connected"}}),
      do: {:ok, Credential.secret("token-for-connected", owner: {org, "connected"})}

    def resolve("stub", %Wardrik.Call{scope: %Scope{user: "unconnected"}}),
      do: {:error, {:authorization_required, "https://example.com/connect"}}

    def resolve("stub", %Wardrik.Call{scope: %Scope{user: "elsewhere"}}),
      do: {:error, {:authorization_required, "https://example.com/device", "WDJB-MJHT"}}

    def resolve("stub", %Wardrik.Call{scope: %Scope{}}), do: {:error, :denied}
  end

  @moduletag server_opts: [credential: "stub", credential_env: "DEMO_TOKEN"]

  defp scope(ref, org, user) do
    key = if user, do: "#{org}/@#{user}/assistant", else: "#{org}/assistant"

    Config.new(tools: [{WardrikMCP, ref}])
    |> Scope.root(key, org: org, user: user, credentials: Vault)
  end

  defp run(ref, user, tool, arguments), do: run(ref, "acme", user, tool, arguments)

  defp run(ref, org, user, tool, arguments) do
    call = %{id: "call_1", name: "#{ref}__#{tool}", arguments: arguments}

    ToolRunner.execute(call, scope(ref, org, user))
  end

  defp text(call) do
    [message] = ToolRunner.messages([call])
    [part] = message.content
    part.text
  end

  test "the tools are listed once, over the deployment's own connection", %{ref: ref} do
    names = Enum.map(WardrikMCP.tools(ref), & &1.name)

    assert "#{ref}__echo" in names
    assert "#{ref}__secret" in names
  end

  test "a connected user calls over a connection carrying their own credential", %{ref: ref} do
    assert [message] =
             Wardrik.LLM.ToolRunner.messages([
               run(ref, "connected", "secret", %{"name" => "DEMO_TOKEN"})
             ])

    [part] = message.content
    assert part.text =~ "token-for-connected"
  end

  test "each user gets a connection of their own", %{ref: ref} do
    run(ref, "connected", "echo", %{"value" => "hello"})

    assert Connection.running?(ref, {:owner, {"acme", "connected"}})
    assert Connection.running?(ref, :deployment)
    refute Connection.running?(ref, {:owner, {"acme", "someone-else"}})
  end

  test "a user of the same name in another org calls over a connection of their own",
       %{ref: ref} do
    assert text(run(ref, "acme", "connected", "secret", %{"name" => "DEMO_TOKEN"})) =~
             "token-for-connected"

    globex = text(run(ref, "globex", "connected", "secret", %{"name" => "DEMO_TOKEN"}))

    assert globex =~ "token-for-globex-connected"
    assert Connection.running?(ref, {:owner, {"acme", "connected"}})
    assert Connection.running?(ref, {:owner, {"globex", "connected"}})
  end

  test "a credential an org holds gives each org a connection of its own", %{ref: ref} do
    assert text(run(ref, "acme", nil, "secret", %{"name" => "DEMO_TOKEN"})) =~ "token-for-acme"

    assert text(run(ref, "globex", nil, "secret", %{"name" => "DEMO_TOKEN"})) =~
             "token-for-globex"

    assert Connection.running?(ref, {:owner, "acme"})
    assert Connection.running?(ref, {:owner, "globex"})
    assert Connection.running?(ref, :deployment)
  end

  test "a user who has not authorized parks the call, with somewhere to go", %{ref: ref} do
    assert %Wardrik.Call{state: :waiting, asks: [%{prompt: prompt, link: link}]} =
             run(ref, "unconnected", "echo", %{"value" => "hello"})

    assert prompt =~ "To connect #{ref}, open its authorization link"
    refute prompt =~ "https://"
    assert link == %{url: "https://example.com/connect", code: nil}
    refute Connection.running?(ref, {:owner, {"acme", "unconnected"}})
  end

  test "a user who authorizes on another device is given the code to enter", %{ref: ref} do
    assert %Wardrik.Call{state: :waiting, asks: [%{prompt: prompt, link: link}]} =
             run(ref, "elsewhere", "echo", %{"value" => "hello"})

    assert prompt =~ "To connect #{ref}, enter the code at its authorization link"
    refute prompt =~ "WDJB-MJHT"
    assert link == %{url: "https://example.com/device", code: "WDJB-MJHT"}
  end

  test "a user the resolver refuses is told, and the turn carries on", %{ref: ref} do
    assert [message] =
             Wardrik.LLM.ToolRunner.messages([run(ref, "refused", "echo", %{"value" => "hello"})])

    [part] = message.content
    assert part.text =~ "not_authorized"
  end

  test "a call with no turn behind it cannot be made as anyone", %{ref: ref} do
    assert {:ok, %{"ok" => false, "error" => error}} =
             WardrikMCP.call(ref, "echo", Calls.tool("echo", %{"value" => "x"}))
             |> Calls.result()

    assert error["message"] =~ "this call has no one to find it for"
  end

  test "the deployment's own connection is not given a user's credential", %{ref: ref} do
    run(ref, "connected", "echo", %{"value" => "hello"})

    deployment =
      GenServer.whereis({:via, Registry, {WardrikMCP.Registry, {:connection, ref, :deployment}}})

    refute inspect(:sys.get_state(deployment)) =~ "token-for-connected"
  end
end
