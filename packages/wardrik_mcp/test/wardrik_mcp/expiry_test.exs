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
    @behaviour Wardrik.Credential

    @impl true
    def resolve("stub", %Wardrik.Call{scope: %Scope{user: user}}),
      do: {:ok, Credential.secret("token-#{user}", owner: user)}

    @impl true
    def refused(ref, %Wardrik.Call{scope: %Scope{user: user}}) do
      if pid = Process.whereis(WardrikMCP.ExpiryTest), do: send(pid, {:refused, ref, user})
      :ok
    end
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

  defp scope(ref, user) do
    Config.new(tools: [{WardrikMCP, ref}])
    |> Scope.root("acme/@#{user}/a", user: user, credentials: Vault)
  end

  describe "a connection built around a credential" do
    test "stops itself as that credential expires", %{ref: ref} do
      offer = Connection.offer(ref)

      {:ok, pid} =
        WardrikMCP.Supervisor.connect(offer.server, "briefly", offer.server.transport, 10)

      monitor = Process.monitor(pid)

      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
      refute Connection.running?(ref, "briefly")
    end

    test "outlives a credential that never expires", %{ref: ref} do
      offer = Connection.offer(ref)

      {:ok, pid} =
        WardrikMCP.Supervisor.connect(offer.server, "forever", offer.server.transport, :infinity)

      monitor = Process.monitor(pid)

      refute_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 200
      assert Connection.running?(ref, "forever")
    end
  end

  describe "a server that refuses the credential it was given" do
    test "is tried once more with a connection built afresh", %{ref: ref} do
      call = %{id: "c1", name: "#{ref}__refuses_once", arguments: %{}}

      assert [message] =
               Wardrik.LLM.ToolRunner.messages([ToolRunner.execute(call, scope(ref, "jon"))])

      [part] = message.content
      assert part.text =~ "accepted this time"
      assert_received {:refused, "stub", "jon"}
    end

    test "a server that refuses twice is reported rather than retried forever", %{ref: ref} do
      # With no flag to write, the stub refuses every call, so the retry finds
      # the same answer and that answer is what the model is told.
      WardrikMCP.disconnect(ref)
      {:ok, _pid} = WardrikMCP.Supervisor.connect(Server.new(ref, always_refusing()))
      await_tools(ref)

      call = %{id: "c1", name: "#{ref}__refuses_once", arguments: %{}}

      assert [message] =
               Wardrik.LLM.ToolRunner.messages([ToolRunner.execute(call, scope(ref, "jon"))])

      [part] = message.content
      assert part.text =~ "no longer valid"
    end

    defp always_refusing do
      stub_options(credential: "stub", credential_env: "DEMO_TOKEN")
    end
  end
end
