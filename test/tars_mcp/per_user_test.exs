defmodule TarsMCP.PerUserTest do
  use TarsMCP.Case, async: false

  alias Tars.Credential
  alias Tars.LLM.Config
  alias Tars.LLM.ToolRunner
  alias Tars.Scope
  alias Tars.Test.Calls
  alias TarsMCP.Connection

  defmodule Vault do
    @moduledoc false
    @behaviour Tars.Credential

    @impl true
    def resolve({:user, "stub"}, %Tars.Call{scope: %Scope{user: "connected"}}),
      do: {:ok, Credential.secret("token-for-connected")}

    def resolve({:user, "stub"}, %Tars.Call{scope: %Scope{user: "unconnected"}}),
      do: {:error, {:authorization_required, "https://example.com/connect"}}

    def resolve({:user, "stub"}, %Tars.Call{scope: %Scope{user: "elsewhere"}}),
      do: {:error, {:authorization_required, "https://example.com/device", "WDJB-MJHT"}}

    def resolve({:user, "stub"}, %Tars.Call{scope: %Scope{}}), do: {:error, :denied}
  end

  @moduletag server_opts: [
               credential: {:user, "stub"},
               credential_env: "DEMO_TOKEN"
             ]

  defp scope(ref, user) do
    Config.new(tools: [{TarsMCP, ref}])
    |> Scope.root("acme/#{user}/assistant", user: user, credentials: Vault)
  end

  defp run(ref, user, tool, arguments) do
    call = %{id: "call_1", name: "#{ref}__#{tool}", arguments: arguments}

    ToolRunner.execute(call, scope(ref, user))
  end

  test "the tools are listed once, over the deployment's own connection", %{ref: ref} do
    names = Enum.map(TarsMCP.tools(ref), & &1.name)

    assert "#{ref}__echo" in names
    assert "#{ref}__secret" in names
  end

  test "a connected user calls over a connection carrying their own credential", %{ref: ref} do
    assert [message] =
             Tars.LLM.ToolRunner.messages([
               run(ref, "connected", "secret", %{"name" => "DEMO_TOKEN"})
             ])

    [part] = message.content
    assert part.text =~ "token-for-connected"
  end

  test "each user gets a connection of their own", %{ref: ref} do
    run(ref, "connected", "echo", %{"value" => "hello"})

    assert Connection.running?(ref, "connected")
    assert Connection.running?(ref, :deployment)
    refute Connection.running?(ref, "someone-else")
  end

  test "a user who has not authorized parks the call, with somewhere to go", %{ref: ref} do
    assert %Tars.Call{state: :waiting, asks: [%{prompt: prompt, link: link}]} =
             run(ref, "unconnected", "echo", %{"value" => "hello"})

    assert prompt =~ "To connect #{ref}, open its authorization link"
    refute prompt =~ "https://"
    assert link == %{url: "https://example.com/connect", code: nil}
    refute Connection.running?(ref, "unconnected")
  end

  test "a user who authorizes on another device is given the code to enter", %{ref: ref} do
    assert %Tars.Call{state: :waiting, asks: [%{prompt: prompt, link: link}]} =
             run(ref, "elsewhere", "echo", %{"value" => "hello"})

    assert prompt =~ "To connect #{ref}, enter the code at its authorization link"
    refute prompt =~ "WDJB-MJHT"
    assert link == %{url: "https://example.com/device", code: "WDJB-MJHT"}
  end

  test "a user the resolver refuses is told, and the turn carries on", %{ref: ref} do
    assert [message] =
             Tars.LLM.ToolRunner.messages([run(ref, "refused", "echo", %{"value" => "hello"})])

    [part] = message.content
    assert part.text =~ "not_authorized"
  end

  test "a call with no turn behind it cannot be made as anyone", %{ref: ref} do
    assert {:ok, %{"ok" => false, "error" => error}} =
             TarsMCP.call(ref, "echo", Calls.tool("echo", %{"value" => "x"}))
             |> Calls.result()

    assert error["message"] =~ "this call has none"
  end

  test "the deployment's own connection is not given a user's credential", %{ref: ref} do
    run(ref, "connected", "echo", %{"value" => "hello"})

    deployment =
      GenServer.whereis({:via, Registry, {TarsMCP.Registry, {:connection, ref, :deployment}}})

    refute inspect(:sys.get_state(deployment)) =~ "token-for-connected"
  end
end
