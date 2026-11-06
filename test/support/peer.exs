# An ACP coding agent over stdio, for tests. Each prompt's last text block is a JSON list of
# steps. A block with text before its steps first says "received: <text>". Steps after a blank
# line at the end of the text run too. It appends every line it receives to $PEER_LOG.
#
#   {"say": text}                          an agent_message_chunk
#   {"tool": {"kind": kind, "title": t}}   a tool_call it ran without asking
#   {"cost": usd}                          a usage_update with the session's cumulative cost
#   {"ask": {"kind": k, "title": t, "rawInput": map, "locations": [...]}}
#                                          a permission request; says "allowed T" or "refused T".
#                                          "$CWD" in a location's path is the session's directory.
#   {"write": {"path": p, "text": t}}      writes a file in the session's directory
#   {"commit": message}                    commits everything in the session's directory
#   {"exit": status}                       exits at once
#   {"hang": true}                         waits for session/cancel
#   {"stop": reason}                       ends the prompt with that stop reason
#   {"fail": message}                      answers the prompt with an error
#   {"request": method}                    sends a request, and says the error it gets back
#
# $PEER_LOAD=1 offers loadSession, and =fail refuses each load. $PEER_RESUME=1 offers resume.
# $PEER_SYSTEM=1 offers system prompts.

defmodule Peer do
  def main do
    # WardrikACP closes stdin, then sends SIGTERM. The peer stops at end of input instead.
    :os.set_signal(:sigterm, :ignore)
    loop(%{cwd: nil, session: nil, next: 0})
  end

  defp loop(state) do
    case IO.read(:stdio, :line) do
      :eof -> :ok
      line -> line |> received() |> handle(state) |> loop()
    end
  end

  defp received(line) do
    if log = System.get_env("PEER_LOG"), do: File.write(log, line, [:append])
    JSON.decode!(line)
  end

  defp handle(%{"id" => id, "method" => "initialize"}, state) do
    session =
      %{}
      |> offer("PEER_SYSTEM", "systemPrompt")
      |> offer("PEER_RESUME", "resume")

    reply(id, %{
      "protocolVersion" => 1,
      "agentCapabilities" => %{
        "loadSession" => System.get_env("PEER_LOAD") in ["1", "fail"],
        "sessionCapabilities" => session
      }
    })

    state
  end

  defp handle(%{"id" => id, "method" => "session/new", "params" => params}, state) do
    session = "s-#{System.unique_integer([:positive])}"

    reply(id, %{
      "sessionId" => session,
      "configOptions" => [
        %{
          "id" => "mode",
          "name" => "Mode",
          "category" => "mode",
          "type" => "select",
          "currentValue" => "auto",
          "options" => [
            %{"value" => "auto", "name" => "Auto"},
            %{"value" => "ask", "name" => "Ask"}
          ]
        }
      ]
    })

    %{state | cwd: params["cwd"], session: session}
  end

  defp handle(%{"id" => id, "method" => "session/load", "params" => params}, state) do
    if System.get_env("PEER_LOAD") == "fail" do
      send_line(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{"code" => -32_002, "message" => "No such session."}
      })

      state
    else
      loaded(id, params, state)
    end
  end

  defp handle(%{"id" => id, "method" => "session/resume", "params" => params}, state) do
    reply(id, %{})
    %{state | cwd: params["cwd"], session: params["sessionId"]}
  end

  defp handle(%{"id" => id, "method" => "session/set_config_option"}, state) do
    reply(id, %{"configOptions" => []})
    state
  end

  defp handle(%{"id" => id, "method" => "session/prompt", "params" => params}, state) do
    text = params["prompt"] |> List.last() |> Map.fetch!("text")
    {reason, state} = text |> steps() |> run(state)

    case reason do
      {:fail, message} ->
        send_line(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{"code" => -32_603, "message" => message}
        })

      reason ->
        reply(id, %{"stopReason" => reason})
    end

    state
  end

  defp handle(_message, state), do: state

  defp offer(session, env, capability) do
    if System.get_env(env) == "1", do: Map.put(session, capability, %{}), else: session
  end

  defp steps(text) do
    case decoded(text) do
      {:ok, steps} -> steps
      :error -> [%{"say" => "received: " <> text} | tail(text)]
    end
  end

  defp tail(text) do
    case text |> String.split("\n\n") |> List.last() |> decoded() do
      {:ok, steps} -> steps
      :error -> []
    end
  end

  defp decoded(text) do
    case JSON.decode(text) do
      {:ok, steps} when is_list(steps) -> {:ok, steps}
      _text -> :error
    end
  end

  defp loaded(id, params, state) do
    update(params["sessionId"], %{
      "sessionUpdate" => "agent_message_chunk",
      "content" => %{"type" => "text", "text" => "replayed"}
    })

    reply(id, nil)
    %{state | cwd: params["cwd"], session: params["sessionId"]}
  end

  defp run([], state), do: {"end_turn", state}
  defp run([%{"stop" => reason} | _steps], state), do: {reason, state}
  defp run([%{"fail" => message} | _steps], state), do: {{:fail, message}, state}

  defp run([%{"request" => method} | steps], state) do
    send_line(%{"jsonrpc" => "2.0", "id" => "r1", "method" => method, "params" => %{}})
    %{"error" => %{"message" => message}} = next_line()
    say(state, message)
    run(steps, state)
  end

  defp run([%{"say" => text} | steps], state) do
    say(state, text)
    run(steps, state)
  end

  defp run([%{"tool" => tool} | steps], state) do
    update(
      state.session,
      Map.merge(%{"sessionUpdate" => "tool_call", "toolCallId" => "t1"}, tool)
    )

    run(steps, state)
  end

  defp run([%{"cost" => usd} | steps], state) do
    update(state.session, %{
      "sessionUpdate" => "usage_update",
      "used" => 1,
      "size" => 100,
      "cost" => %{"amount" => usd, "currency" => "USD"}
    })

    run(steps, state)
  end

  defp run([%{"ask" => tool_call} | steps], state) do
    id = "p#{state.next}"

    send_line(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "session/request_permission",
      "params" => %{
        "sessionId" => state.session,
        "toolCall" => tool_call |> Map.put("toolCallId", id) |> in_cwd(state.cwd),
        "options" => [
          %{"optionId" => "once", "name" => "Allow", "kind" => "allow_once"},
          %{"optionId" => "always", "name" => "Always", "kind" => "allow_always"},
          %{"optionId" => "no", "name" => "Reject", "kind" => "reject_once"}
        ]
      }
    })

    case answer(id) do
      "once" -> say(state, "allowed " <> tool_call["title"])
      "no" -> say(state, "refused " <> tool_call["title"])
      :cancelled -> :cancelled
    end
    |> case do
      :cancelled -> {"cancelled", state}
      _said -> run(steps, %{state | next: state.next + 1})
    end
  end

  defp run([%{"write" => %{"path" => path, "text" => text}} | steps], state) do
    File.write!(Path.join(state.cwd, path), text)
    run(steps, state)
  end

  defp run([%{"commit" => message} | steps], state) do
    {_output, 0} = System.cmd("git", ["-C", state.cwd, "add", "-A"])

    {_output, 0} =
      System.cmd("git", ["-C", state.cwd, "commit", "--allow-empty", "-q", "-m", message])

    run(steps, state)
  end

  defp run([%{"exit" => status} | _steps], _state), do: System.halt(status)

  defp run([%{"hang" => true} | _steps], state) do
    case next_line() do
      %{"method" => "session/cancel"} -> {"cancelled", state}
      _other -> run([%{"hang" => true}], state)
    end
  end

  defp answer(id) do
    case next_line() do
      %{"id" => ^id, "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => option}}} ->
        option

      %{"id" => ^id} ->
        :cancelled

      %{"method" => "session/cancel"} ->
        :cancelled

      _other ->
        answer(id)
    end
  end

  defp in_cwd(%{"locations" => locations} = tool_call, cwd) do
    located =
      for %{"path" => path} = location <- locations,
          do: %{location | "path" => String.replace(path, "$CWD", cwd)}

    %{tool_call | "locations" => located}
  end

  defp in_cwd(tool_call, _cwd), do: tool_call

  defp next_line do
    case IO.read(:stdio, :line) do
      :eof -> System.halt(0)
      line -> received(line)
    end
  end

  defp say(state, text) do
    update(state.session, %{
      "sessionUpdate" => "agent_message_chunk",
      "content" => %{"type" => "text", "text" => text}
    })
  end

  defp update(session, update) do
    send_line(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{"sessionId" => session, "update" => update}
    })
  end

  defp reply(id, result), do: send_line(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

  # WardrikACP may close stdout first, when it stops the peer.
  defp send_line(message) do
    IO.write([JSON.encode!(message), ?\n])
  rescue
    ErlangError -> System.halt(0)
  end
end

Peer.main()
