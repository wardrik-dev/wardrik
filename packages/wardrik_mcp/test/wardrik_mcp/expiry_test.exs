defmodule WardrikMCP.ExpiryTest do
  use WardrikMCP.Test.Case, async: false

  alias Wardrik.Credential
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.ToolRunner
  alias Wardrik.Scope
  alias WardrikMCP.Connection
  alias WardrikMCP.Server

  defmodule Vault do
    @moduledoc false
    defstruct []

    def resolve("stub", %Wardrik.Call{scope: scope}) do
      user = Scope.agent_id(scope).user
      {:ok, Credential.secret("token-#{user}", owner: user)}
    end

    def refused(key, %Wardrik.Call{scope: scope}) do
      user = Scope.agent_id(scope).user
      if pid = Process.whereis(WardrikMCP.ExpiryTest), do: send(pid, {:refused, key, user})
      :ok
    end
  end

  defimpl Wardrik.Credentials, for: Vault do
    def resolve(_vault, key, call), do: Vault.resolve(key, call)
    def refused(_vault, key, call), do: Vault.refused(key, call)
    def key(_vault, _name), do: :error
  end

  @flag Path.join(System.tmp_dir!(), "wardrik-refusal-#{System.unique_integer([:positive])}")

  @moduletag server_opts: [
               credential: "stub",
               credential_env: "DEMO_TOKEN",
               transport_opts: [env: %{"STUB_REFUSAL_FLAG" => @flag}]
             ]

  setup do
    Process.register(self(), WardrikMCP.ExpiryTest)
    on_exit(fn -> File.rm(@flag) end)

    :ok
  end

  defp scope(key, user) do
    Config.new(tools: [{WardrikMCP, key}])
    |> Scope.root(Wardrik.AgentID.new!("a", org: "acme", user: user),
      host: Wardrik.Test.host(credentials: %Vault{})
    )
  end

  describe "a connection built around a credential" do
    test "stops itself as that credential expires", %{key: key} do
      offer = Connection.offer(key)

      {:ok, pid} =
        WardrikMCP.Supervisor.connect(offer.server, "briefly", offer.server.transport, 10)

      monitor = Process.monitor(pid)

      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
      refute Connection.running?(key, "briefly")
    end

    test "outlives a credential that never expires", %{key: key} do
      offer = Connection.offer(key)

      {:ok, pid} =
        WardrikMCP.Supervisor.connect(offer.server, "forever", offer.server.transport, :infinity)

      monitor = Process.monitor(pid)

      refute_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 200
      assert Connection.running?(key, "forever")
    end
  end

  describe "a server that refuses the credential it was given" do
    test "is tried once more with a connection built afresh", %{key: key} do
      call = %{id: "c1", name: "#{key}__refuses_once", arguments: %{}}

      assert [message] =
               Wardrik.LLM.ToolRunner.messages([ToolRunner.execute(call, scope(key, "jon"))])

      [part] = message.content
      assert part.text =~ "accepted this time"
      assert_received {:refused, "stub", "jon"}
    end

    test "a server that refuses twice is reported rather than retried forever", %{key: key} do
      # With no flag to write, the stub refuses every call, so the retry finds
      # the same answer and that answer is what the model is told.
      WardrikMCP.disconnect(key)
      {:ok, _pid} = WardrikMCP.Supervisor.connect(Server.new(key, always_refusing()))
      await_tools(key)

      call = %{id: "c1", name: "#{key}__refuses_once", arguments: %{}}

      assert [message] =
               Wardrik.LLM.ToolRunner.messages([ToolRunner.execute(call, scope(key, "jon"))])

      [part] = message.content
      assert part.text =~ "no longer valid"
    end

    defp always_refusing do
      stub_options(credential: "stub", credential_env: "DEMO_TOKEN")
    end
  end
end
