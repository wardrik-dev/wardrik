defmodule WardrikMCP.PerUserTest do
  use WardrikMCP.Test.Case, async: false

  alias Wardrik.Resource

  alias Wardrik.AgentID
  alias Wardrik.Credential
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.ToolRunner
  alias Wardrik.Run
  alias WardrikMCP.Connection

  # Resolves stub as a vault would: each connected user's own, and an org's
  # for an agent with no user, each saying whose it is.
  defmodule Vault do
    @moduledoc false
    defstruct []

    def resolve("stub", %Wardrik.Call{run: run}), do: stub(Run.agent_id(run))

    defp stub(%AgentID{org: org, user: nil}),
      do: {:ok, Credential.secret("token-for-#{org}", owner: org)}

    defp stub(%AgentID{org: "globex", user: "connected"}),
      do: {:ok, Credential.secret("token-for-globex-connected", owner: {"globex", "connected"})}

    defp stub(%AgentID{org: org, user: "connected"}),
      do: {:ok, Credential.secret("token-for-connected", owner: {org, "connected"})}

    defp stub(%AgentID{org: org, user: "unconnected"}),
      do:
        {:error,
         {:authorization_required, %{url: "https://example.com/connect"}, {org, "unconnected"}}}

    defp stub(%AgentID{org: org, user: "elsewhere"}),
      do:
        {:error,
         {:authorization_required, %{url: "https://example.com/device", code: "WDJB-MJHT"},
          {org, "elsewhere"}}}

    defp stub(%AgentID{}), do: {:error, :denied}
  end

  defimpl Wardrik.Credentials, for: Vault do
    def resolve(_vault, key, call), do: Vault.resolve(key, call)
    def refused(_vault, _ref, _call), do: :ok
    def key(_vault, _name), do: :error
  end

  @moduletag server_opts: [credential: "stub", credential_env: "DEMO_TOKEN"]

  defp run_for(key, org, user) do
    Config.new(tools: [{WardrikMCP, key}])
    |> Run.root(AgentID.new!("assistant", org: org, user: user),
      host: Wardrik.Test.host(credentials: %Vault{})
    )
  end

  defp run(key, user, tool, arguments), do: run(key, "acme", user, tool, arguments)

  defp run(key, org, user, tool, arguments) do
    call = %{id: "call_1", name: "#{Resource.basename(key)}__#{tool}", arguments: arguments}

    ToolRunner.execute(call, run_for(key, org, user))
  end

  defp text(call) do
    [message] = ToolRunner.messages([call])
    [part] = message.parts
    part.text
  end

  test "the tools are listed once, over the deployment's own connection", %{key: key} do
    names = Enum.map(WardrikMCP.tools(key), & &1.name)

    assert "#{Resource.basename(key)}__echo" in names
    assert "#{Resource.basename(key)}__secret" in names
  end

  test "a connected user calls over a connection carrying their own credential", %{key: key} do
    assert [message] =
             Wardrik.LLM.ToolRunner.messages([
               run(key, "connected", "secret", %{"name" => "DEMO_TOKEN"})
             ])

    [part] = message.parts
    assert part.text =~ "token-for-connected"
  end

  test "each user gets a connection of their own", %{key: key} do
    run(key, "connected", "echo", %{"value" => "hello"})

    assert Connection.running?(key, {:owner, {"acme", "connected"}})
    assert Connection.running?(key, :deployment)
    refute Connection.running?(key, {:owner, {"acme", "someone-else"}})
  end

  test "a user of the same name in another org calls over a connection of their own",
       %{key: key} do
    assert text(run(key, "acme", "connected", "secret", %{"name" => "DEMO_TOKEN"})) =~
             "token-for-connected"

    globex = text(run(key, "globex", "connected", "secret", %{"name" => "DEMO_TOKEN"}))

    assert globex =~ "token-for-globex-connected"
    assert Connection.running?(key, {:owner, {"acme", "connected"}})
    assert Connection.running?(key, {:owner, {"globex", "connected"}})
  end

  test "a credential an org holds gives each org a connection of its own", %{key: key} do
    assert text(run(key, "acme", nil, "secret", %{"name" => "DEMO_TOKEN"})) =~ "token-for-acme"

    assert text(run(key, "globex", nil, "secret", %{"name" => "DEMO_TOKEN"})) =~
             "token-for-globex"

    assert Connection.running?(key, {:owner, "acme"})
    assert Connection.running?(key, {:owner, "globex"})
    assert Connection.running?(key, :deployment)
  end

  test "a user who has not authorized parks the call, with somewhere to go", %{key: key} do
    assert %Wardrik.Call{state: :waiting, asks: [%{prompt: prompt, link: link}]} =
             run(key, "unconnected", "echo", %{"value" => "hello"})

    assert prompt =~ "To use #{Resource.basename(key)}__echo, connect stub at its link"
    refute prompt =~ "https://"
    assert link == %{url: "https://example.com/connect", code: nil}
    refute Connection.running?(key, {:owner, {"acme", "unconnected"}})
  end

  test "a user who authorizes on another device is given the code to enter", %{key: key} do
    assert %Wardrik.Call{state: :waiting, asks: [%{prompt: prompt, link: link}]} =
             run(key, "elsewhere", "echo", %{"value" => "hello"})

    assert prompt =~ "To use #{Resource.basename(key)}__echo, connect stub at its link"
    refute prompt =~ "WDJB-MJHT"
    assert link == %{url: "https://example.com/device", code: "WDJB-MJHT"}
  end

  test "a user the resolver refuses is told, and the turn carries on", %{key: key} do
    assert [message] =
             Wardrik.LLM.ToolRunner.messages([run(key, "refused", "echo", %{"value" => "hello"})])

    [part] = message.parts
    assert part.text =~ "not_authorized"
  end

  test "the deployment's own connection is not given a user's credential", %{key: key} do
    run(key, "connected", "echo", %{"value" => "hello"})

    deployment =
      GenServer.whereis({:via, Registry, {WardrikMCP.Registry, {:connection, key, :deployment}}})

    refute inspect(:sys.get_state(deployment)) =~ "token-for-connected"
  end
end
