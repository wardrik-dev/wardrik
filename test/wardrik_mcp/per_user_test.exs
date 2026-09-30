defmodule WardrikMCP.PerUserTest do
  use WardrikMCP.Case, async: false

  alias Wardrik.Credential
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.ToolRunner
  alias Wardrik.Scope
  alias Wardrik.Test.Calls
  alias WardrikMCP.Connection

  defmodule Vault do
    @moduledoc false
    @behaviour Wardrik.Credential

    @impl true
    def resolve({:user, "stub"}, %Wardrik.Call{scope: %Scope{org: "globex", user: "connected"}}),
      do: {:ok, Credential.secret("token-for-globex-connected")}

    def resolve({:user, "stub"}, %Wardrik.Call{scope: %Scope{user: "connected"}}),
      do: {:ok, Credential.secret("token-for-connected")}

    def resolve({:user, "stub"}, %Wardrik.Call{scope: %Scope{user: "unconnected"}}),
      do: {:error, {:authorization_required, "https://example.com/connect"}}

    def resolve({:user, "stub"}, %Wardrik.Call{scope: %Scope{user: "elsewhere"}}),
      do: {:error, {:authorization_required, "https://example.com/device", "WDJB-MJHT"}}

    def resolve({:user, "stub"}, %Wardrik.Call{scope: %Scope{}}), do: {:error, :denied}

    def resolve({:org, "stub"}, %Wardrik.Call{scope: %Scope{org: org}}),
      do: {:ok, Credential.secret("token-for-#{org}")}
  end

  @moduletag server_opts: [
               credential: {:user, "stub"},
               credential_env: "DEMO_TOKEN"
             ]

  defp scope(ref, org, user) do
    Config.new(tools: [{WardrikMCP, ref}])
    |> Scope.root("#{org}/#{user || "_"}/assistant", org: org, user: user, credentials: Vault)
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

    assert Connection.running?(ref, {:user, "acme", "connected"})
    assert Connection.running?(ref, :deployment)
    refute Connection.running?(ref, {:user, "acme", "someone-else"})
  end

  test "a user of the same name in another org calls over a connection of their own",
       %{ref: ref} do
    assert text(run(ref, "acme", "connected", "secret", %{"name" => "DEMO_TOKEN"})) =~
             "token-for-connected"

    globex = text(run(ref, "globex", "connected", "secret", %{"name" => "DEMO_TOKEN"}))

    assert globex =~ "token-for-globex-connected"
    assert Connection.running?(ref, {:user, "acme", "connected"})
    assert Connection.running?(ref, {:user, "globex", "connected"})
  end

  test "an agent with no user is refused, and the deployment's own connection is left alone",
       %{ref: ref} do
    assert text(run(ref, nil, "secret", %{"name" => "DEMO_TOKEN"})) =~
             "is reached as a user, and this call has none"

    assert Connection.running?(ref, :deployment)
  end

  @tag server_opts: [credential: {:org, "stub"}, credential_env: "DEMO_TOKEN"]
  test "an org credential gives each org a connection of its own", %{ref: ref} do
    assert text(run(ref, "acme", "jon", "secret", %{"name" => "DEMO_TOKEN"})) =~
             "token-for-acme"

    assert text(run(ref, "globex", "jon", "secret", %{"name" => "DEMO_TOKEN"})) =~
             "token-for-globex"

    assert text(run(ref, "acme", nil, "secret", %{"name" => "DEMO_TOKEN"})) =~
             "token-for-acme"

    assert Connection.running?(ref, {:org, "acme"})
    assert Connection.running?(ref, {:org, "globex"})
    refute Connection.running?(ref, {:user, "acme", "jon"})
  end

  test "a user who has not authorized parks the call, with somewhere to go", %{ref: ref} do
    assert %Wardrik.Call{state: :waiting, asks: [%{prompt: prompt, link: link}]} =
             run(ref, "unconnected", "echo", %{"value" => "hello"})

    assert prompt =~ "To connect #{ref}, open its authorization link"
    refute prompt =~ "https://"
    assert link == %{url: "https://example.com/connect", code: nil}
    refute Connection.running?(ref, {:user, "acme", "unconnected"})
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

    assert error["message"] =~ "this call has none"
  end

  test "the deployment's own connection is not given a user's credential", %{ref: ref} do
    run(ref, "connected", "echo", %{"value" => "hello"})

    deployment =
      GenServer.whereis({:via, Registry, {WardrikMCP.Registry, {:connection, ref, :deployment}}})

    refute inspect(:sys.get_state(deployment)) =~ "token-for-connected"
  end
end
