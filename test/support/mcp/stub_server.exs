# An MCP server over stdio, for tests: a handful of tools, no dependencies, and
# only the state it needs to report what it was sent. Run as
# `elixir stub_server.exs`.
#
# Anything written to stdout that is not a JSON-RPC message corrupts the
# stream, so trouble goes to stderr.

defmodule StubServer do
  @protocol "2025-06-18"

  @tools [
    %{
      "name" => "echo",
      "description" => "Hands the value back.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => "string", "description" => "Anything"}},
        "required" => ["value"]
      }
    },
    %{
      "name" => "boom",
      "description" => "Answers with a tool error.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "secret",
      "description" => "Reports the value of an environment variable.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}},
        "required" => ["name"]
      }
    },
    %{
      "name" => "slow",
      "description" => "Reports progress once, then never answers.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "noisy",
      "description" => "Reports progress, then answers.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"steps" => %{"type" => "integer"}}
      }
    },
    %{
      "name" => "refuses_once",
      "description" => "Answers the first call with a 401, and the next one properly.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "noise",
      "description" => "Writes a line to stderr, the way a chatty server does.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"line" => %{"type" => "string"}}
      }
    },
    %{
      "name" => "cancellations",
      "description" => "How many cancellations this server has been sent.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "grow",
      "description" => "Gains a tool, and says its list changed.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    }
  ]

  @grown %{
    "name" => "grown",
    "description" => "The tool `grow` added.",
    "inputSchema" => %{"type" => "object", "properties" => %{}}
  }

  def run(state \\ %{cancelled: 0, grown: false}) do
    case IO.read(:stdio, :line) do
      :eof -> :ok
      {:error, reason} -> IO.puts(:stderr, "stub: #{inspect(reason)}")
      line -> line |> String.trim() |> handle(state) |> run()
    end
  end

  defp handle("", state), do: state

  defp handle(line, state) do
    case JSON.decode(line) do
      {:ok, message} ->
        respond(message, state)

      {:error, reason} ->
        IO.puts(:stderr, "stub: bad json: #{inspect(reason)}")
        state
    end
  end

  defp respond(%{"method" => "initialize", "id" => id, "params" => params}, state) do
    reply(id, %{
      "protocolVersion" => params["protocolVersion"] || @protocol,
      "capabilities" => %{"tools" => %{"listChanged" => true}},
      "serverInfo" => %{"name" => "stub", "version" => "1.0.0"}
    })

    state
  end

  defp respond(%{"method" => "ping", "id" => id}, state) do
    reply(id, %{})
    state
  end

  # With STUB_REQUIRE_TOKEN set and no token in the environment, it refuses to
  # list anything, which is what a server reached as a user does.
  defp respond(%{"method" => "tools/list", "id" => id}, state) do
    listed = if state.grown, do: @tools ++ [@grown], else: @tools

    if System.get_env("STUB_REQUIRE_TOKEN") && is_nil(System.get_env("DEMO_TOKEN")),
      do: error(id, -32_001, "missing required Authorization header"),
      else: reply(id, %{"tools" => listed})

    state
  end

  defp respond(%{"method" => "tools/call", "id" => id, "params" => params}, state) do
    called(params["name"], params["arguments"] || %{}, token(params), id, state)
  end

  defp respond(%{"method" => "notifications/cancelled"}, state) do
    %{state | cancelled: state.cancelled + 1}
  end

  defp respond(%{"method" => "notifications/" <> _rest}, state), do: state

  defp respond(%{"id" => id, "method" => method}, state) do
    error(id, -32_601, "the stub has no method #{method}")
    state
  end

  defp respond(_message, state), do: state

  # `slow` is the point: it takes the request and never answers, so a caller
  # that goes away leaves work the server still believes in. The progress
  # notification is how a test knows the request arrived.
  defp called("slow", _arguments, token, _id, state) do
    if token, do: progress(token, 1, 1)

    state
  end

  defp called("echo", arguments, _token, id, state) do
    text(id, arguments["value"] || "")
    state
  end

  defp called("boom", _arguments, _token, id, state) do
    reply(id, %{
      "content" => [%{"type" => "text", "text" => "the tool refused"}],
      "isError" => true
    })

    state
  end

  defp called("secret", arguments, _token, id, state) do
    text(id, System.get_env(arguments["name"] || "", ""))
    state
  end

  # The shape a server takes when the credential it was given has stopped
  # working: a protocol error carrying the status, not a tool result. Whether
  # it has already refused is kept in a file, because a client that reconnects
  # to try again gets a new copy of this process.
  defp called("refuses_once", _arguments, _token, id, state) do
    flag = System.get_env("STUB_REFUSAL_FLAG")

    if flag && File.exists?(flag) do
      text(id, "accepted this time")
    else
      if flag, do: File.write(flag, "refused")

      send_message(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{
          "code" => -32_001,
          "message" => "the token is no longer valid",
          "data" => %{"status" => 401}
        }
      })
    end

    state
  end

  defp called("noise", arguments, _token, id, state) do
    IO.puts(:stderr, arguments["line"] || "npm notice something")
    text(id, "noise made")

    state
  end

  defp called("cancellations", _arguments, _token, id, state) do
    text(id, to_string(state.cancelled))
    state
  end

  defp called("grow", _arguments, _token, id, state) do
    text(id, "grown")

    send_message(%{
      "jsonrpc" => "2.0",
      "method" => "notifications/tools/list_changed",
      "params" => %{}
    })

    %{state | grown: true}
  end

  defp called("noisy", arguments, token, id, state) do
    steps = arguments["steps"] || 2

    if token, do: Enum.each(1..steps//1, &progress(token, &1, steps))
    text(id, "done in #{steps}")

    state
  end

  defp called(name, _arguments, _token, id, state) do
    reply(id, %{
      "content" => [%{"type" => "text", "text" => "no tool #{name}"}],
      "isError" => true
    })

    state
  end

  defp token(params), do: get_in(params, ["_meta", "progressToken"])

  defp progress(token, progress, total) do
    send_message(%{
      "jsonrpc" => "2.0",
      "method" => "notifications/progress",
      "params" => %{"progressToken" => token, "progress" => progress, "total" => total}
    })
  end

  defp text(id, text), do: reply(id, %{"content" => [%{"type" => "text", "text" => text}]})

  defp reply(id, result), do: send_message(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

  defp error(id, code, message) do
    send_message(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    })
  end

  defp send_message(message), do: IO.puts(JSON.encode!(message))
end

StubServer.run()
