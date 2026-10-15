defmodule WardrikMCP.Test.Case do
  @moduledoc """
  A `WardrikMCP.Supervisor` running against `priv/stub_server.exs`, a real MCP
  server over stdio.

      use WardrikMCP.Test.Case

      test "the stub offers its tools", %{key: key} do
        assert "\#{key}__echo" in Enum.map(WardrikMCP.tools(key), & &1.name)
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
    name = fresh_name()
    opts = Map.get(context, :server_opts, [])

    start_supervised!({WardrikMCP.Supervisor, servers: [{name, stub_options(opts)}]})
    key = Wardrik.Servers.Key.deployment(Atom.to_string(name))
    await_tools(key)

    %{key: key}
  end

  @doc """
  The context a call to a server's tool is handed under `scope`, for a test
  that calls `WardrikMCP.call/4` directly.
  """
  @spec context(Wardrik.Scope.t()) :: Wardrik.Tool.Context.t()
  def context(scope \\ Wardrik.Test.scope()), do: Wardrik.Test.context(scope)

  @doc "A name no other test is using, so servers started in one test do not reach another."
  @spec fresh_name() :: atom()
  def fresh_name, do: :"stub_#{System.unique_integer([:positive])}"

  @doc "The key of a deployment server no other test is using."
  @spec fresh_key() :: Wardrik.Servers.Key.t()
  def fresh_key, do: Wardrik.Servers.Key.deployment(Atom.to_string(fresh_name()))

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
  @spec await_tools(Wardrik.Servers.Key.t(), timeout()) :: [ReqLLM.Tool.t()]
  def await_tools(key, timeout \\ :timer.seconds(30)) do
    case WardrikMCP.Connection.await(key, :deployment, timeout) do
      {:ok, tools} -> tools
      {:error, :timeout} -> raise "MCP server #{key} reported no tools in time"
    end
  end

  defp elixir, do: System.find_executable("elixir") || "elixir"

  defp stub, do: Application.app_dir(:wardrik_mcp, "priv/stub_server.exs")
end
