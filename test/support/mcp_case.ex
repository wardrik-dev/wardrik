defmodule Tars.Test.MCPCase do
  @moduledoc """
  A `TarsMCP.Supervisor` running against `test/support/mcp/stub_server.exs`, a
  real MCP server over stdio.

      use Tars.Test.MCPCase

      test "the stub offers its tools", %{ref: ref} do
        assert "stub__echo" in Enum.map(TarsMCP.tools(ref), & &1.name)
      end

  The supervisor is started for the test and stopped with it. `@server_opts`
  before `use` adds options to the server, such as `only:` or `env:`.
  """

  use ExUnit.CaseTemplate

  @stub Path.expand("mcp/stub_server.exs", __DIR__)

  using do
    quote do
      import Tars.Test.MCPCase
    end
  end

  setup context do
    ref = :"stub_#{System.unique_integer([:positive])}"
    opts = Map.get(context, :server_opts, [])

    start_supervised!({TarsMCP.Supervisor, servers: [{ref, stub_options(opts)}]})
    await_tools(ref)

    %{ref: ref}
  end

  @doc "The options for a server that runs the stub, with `opts` merged in."
  @spec stub_options(keyword()) :: keyword()
  def stub_options(opts \\ []) do
    {transport_opts, opts} = Keyword.pop(opts, :transport_opts, [])

    Keyword.put(opts, :transport, {:stdio, [command: elixir(), args: [@stub]] ++ transport_opts})
  end

  @doc "Waits until a server has reported its tools, or fails the test."
  @spec await_tools(atom(), timeout()) :: [ReqLLM.Tool.t()]
  def await_tools(ref, timeout \\ :timer.seconds(30)) do
    case TarsMCP.Connection.await(ref, :deployment, timeout) do
      {:ok, tools} -> tools
      {:error, :timeout} -> raise "MCP server #{ref} reported no tools in time"
    end
  end

  defp elixir, do: System.find_executable("elixir") || "elixir"
end
