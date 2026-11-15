defmodule Wardrik.MCPCase.Tokens do
  @moduledoc "Credentials the tests give principals: a token each, or a sign-in."
  @behaviour Wardrik.Credentials

  @impl true
  def resolve(%{name: "stub", principal: %Wardrik.Principal{id: id}}, tokens) do
    case Map.fetch(tokens, id) do
      {:ok, token} -> {:ok, token}
      :error -> {:authorize, "https://sign.in/" <> id}
    end
  end
end

defmodule Wardrik.MCPCase.Rotating do
  @moduledoc "Credentials that hand out the token an agent holds, and a new one once the old is refused."
  @behaviour Wardrik.Credentials

  @impl true
  def resolve(%{name: "stub"}, tokens), do: {:ok, Agent.get(tokens, & &1.token)}

  @impl true
  def refused(%{name: "stub"}, tokens) do
    Agent.update(tokens, fn state ->
      send(state.test, {:refused, state.token})
      %{state | token: state.token <> "-renewed"}
    end)
  end
end

defmodule Wardrik.MCPCase do
  @moduledoc """
  Starts a `Wardrik.MCP` for each test module, with servers run by `stub_server.exs`. Its tests
  wait on servers that connect again, so they're split across modules to run side by side.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use Mimic

      alias Wardrik.Context
      alias Wardrik.MCP.Server
      alias Wardrik.Tool
      alias Wardrik.ToolCall

      @mcp Module.concat(__MODULE__, MCP)
      @stub {:stdio,
             command: "elixir", args: [Path.expand("../../support/mcp/stub_server.exs", __DIR__)]}

      setup_all do
        listen()

        start_supervised!(
          {Wardrik.MCP,
           name: @mcp,
           servers: [
             stub: [transport: @stub],
             cheap: [
               transport: @stub,
               only: ["echo", "charge"],
               cost: [usd: 0.01],
               gated: ["ec*"],
               trusted: true
             ],
             metered: [transport: @stub, except: ["slow"], cost: &%{usd: &1["_meta"]["usd"]}],
             hasty: [transport: @stub, timeout: 200, max_result_bytes: 101],
             growing: [transport: @stub],
             flaky: [transport: @stub],
             down: [transport: {:stdio, command: "no-such-mcp-server"}]
           ]}
        )

        Enum.each(~w(stub cheap metered hasty growing flaky), &connected/1)
      end

      defp requested do
        receive do
          {:http, _method, path} -> [path | requested()]
        after
          0 -> []
        end
      end

      defp answered([answer]), do: {answer, [answer]}
      defp answered([answer | rest]), do: {answer, rest}

      defp flaky_client do
        [{connection, _hash}] =
          @mcp
          |> Wardrik.MCP.Connection.registry()
          |> Registry.lookup({:connection, "flaky", nil})

        {:ok, :sys.get_state(connection).client}
      end

      defp listen do
        test = self()
        id = make_ref()

        :telemetry.attach(
          id,
          [:wardrik_mcp, :tools],
          fn _event, measured, %{mcp: mcp, server: server}, _config ->
            send(test, {:tools, mcp, server, measured})
          end,
          nil
        )

        on_exit(fn -> :telemetry.detach(id) end)
      end

      defp tools(server), do: Wardrik.MCP.tools(context(), name: @mcp, servers: server)

      defp tool(server, name) do
        server
        |> tools()
        |> Enum.find(&(&1.name == "#{server}__#{name}"))
      end

      defp call(server, name, arguments \\ %{}) do
        call = %ToolCall{id: "1", name: "#{server}__#{name}", arguments: arguments}

        server
        |> tools()
        |> Tool.call(call, context())
      end

      defp context, do: Context.new(agent_id: "mcp-test")

      defp connected(server) do
        if tools(server) == [],
          do: assert_receive({:tools, @mcp, ^server, %{count: _count}}, 10_000)
      end

      defp context(principal, tokens),
        do:
          Context.new(
            agent_id: "mcp-test",
            principal: %Wardrik.Principal{id: principal},
            credentials: {Wardrik.MCPCase.Tokens, tokens}
          )
    end
  end
end
