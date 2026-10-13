defmodule WardrikMCP.Test.Case do
  @moduledoc """
  A `WardrikMCP.Supervisor` running against `priv/stub_server.exs`, a real MCP
  server over stdio.

      use WardrikMCP.Test.Case

      test "the stub offers its tools", %{ref: ref} do
        assert "stub__echo" in Enum.map(WardrikMCP.tools(ref), & &1.name)
      end

  The supervisor is started for the test and stopped with it. `@server_opts`
  before `use` adds options to the server, such as `only:` or `env:`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import WardrikMCP.Test.Case
    end
  end

  setup context do
    ref = fresh_ref()
    opts = Map.get(context, :server_opts, [])

    start_supervised!({WardrikMCP.Supervisor, servers: [{ref, stub_options(opts)}]})
    await_tools(ref)

    %{ref: ref}
  end

  @doc """
  The context a call to a server's tool is handed under `scope`, for a test
  that calls `WardrikMCP.call/4` directly.
  """
  @spec context(Wardrik.Scope.t()) :: Wardrik.Tool.Context.t()
  def context(scope \\ Wardrik.Test.scope()), do: Wardrik.Test.context(scope)

  @doc "A ref no other test is using, so servers started in one test do not reach another."
  @spec fresh_ref() :: atom()
  def fresh_ref, do: :"stub_#{System.unique_integer([:positive])}"

  @doc """
  The options for a server that runs the stub, with `opts` merged in. A
  connection to it retries, and waits out a burst of tool changes, in
  milliseconds rather than a second or a quarter of one.
  """
  @spec stub_options(keyword()) :: keyword()
  def stub_options(opts \\ []) do
    {transport_opts, opts} = Keyword.pop(opts, :transport_opts, [])

    [first_retry: 10, refresh_after: 10, store: Wardrik.Test.store()]
    |> Keyword.merge(opts)
    |> Keyword.put(:transport, {:stdio, [command: elixir(), args: [stub()]] ++ transport_opts})
  end

  @doc "Waits until a server has reported its tools, or fails the test."
  @spec await_tools(atom(), timeout()) :: [ReqLLM.Tool.t()]
  def await_tools(ref, timeout \\ :timer.seconds(30)) do
    case WardrikMCP.Connection.await(ref, :deployment, timeout) do
      {:ok, tools} -> tools
      {:error, :timeout} -> raise "MCP server #{ref} reported no tools in time"
    end
  end

  defp elixir, do: System.find_executable("elixir") || "elixir"

  defp stub, do: Application.app_dir(:wardrik_mcp, "priv/stub_server.exs")
end
