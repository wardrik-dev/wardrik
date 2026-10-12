defmodule WardrikHTTP.Worker do
  @moduledoc """
  One tool worker's WebSocket, `GET /v1/workers`, and the MCP client Wardrik is
  over it.

  A worker is an MCP server that dials in. It opens the socket with a credential,
  as `Authorization: Bearer wardrik_…`, and Wardrik speaks MCP to it: JSON-RPC 2.0,
  one message to a text frame, protocol version `2025-06-18`.

    1. Wardrik sends `initialize`, then `notifications/initialized` once the
       worker answers.
    2. Wardrik sends `tools/list`, and offers what the worker lists to the agents
       its credential reaches (see `WardrikHTTP.Workers`). The worker sends
       `notifications/tools/list_changed` to be listed again.
    3. Wardrik sends `tools/call` for each call an agent makes, with the agent
       it is for as `_meta.agent`, its run as `_meta.run`, and its idempotency
       key as `_meta.idempotencyKey`, and the worker answers with a
       `CallToolResult`: `structuredContent` where it has any, `content`, and
       `isError`, and what the call cost in US dollars as `_meta.costUsd`
       where it costs money. A call Wardrik stops waiting for, or stops, is sent
       `notifications/cancelled`: one not answered in time, and one whose
       caller ends first, as a call killed with
       `Wardrik.LLM.ToolRunner.kill_call/2`, past its turn's deadline, or in
       a turn that ends, does.

  Wardrik answers a worker's `ping`, and sends a WebSocket ping every 30 seconds
  so a socket at rest stays open.

  The socket holds its credential (`WardrikHTTP.Access.hold/1`), and closes with `1008`
  when it is revoked, or `1013` where it cannot be read as the
  socket opens.

  `[:wardrik, :workers, :listed]` is emitted each time a worker's tools are
  offered, with `:count` in its measurements and the socket's pid and the
  tools' names in its metadata.
  """

  @behaviour WebSock

  alias Wardrik.Tool.Result
  alias WardrikHTTP.Caller
  alias WardrikHTTP.Worker.Tool
  alias WardrikHTTP.Workers

  @protocol "2025-06-18"
  @ping :timer.seconds(30)

  @enforce_keys [:caller]
  defstruct [:caller, :since, next: 1, pending: %{}]

  @typep purpose() :: :initialize | :list | {pid(), reference(), reference()}

  @type t() :: %__MODULE__{
          caller: Caller.t(),
          since: integer() | nil,
          next: pos_integer(),
          pending: %{pos_integer() => purpose()}
        }

  @impl WebSock
  def init(%Caller{} = caller) do
    case WardrikHTTP.Access.hold(caller.ref) do
      :ok -> start(caller)
      {:error, reason} -> {:stop, {:shutdown, reason}, close(reason), %__MODULE__{caller: caller}}
    end
  end

  defp start(caller) do
    schedule_ping()

    {frame, state} =
      request(
        %__MODULE__{caller: caller, since: System.system_time(:microsecond)},
        "initialize",
        %{
          "protocolVersion" => @protocol,
          "capabilities" => %{},
          "clientInfo" => %{"name" => "wardrik", "version" => version()}
        },
        :initialize
      )

    {:push, frame, state}
  end

  @impl WebSock
  def handle_in({text, [opcode: :text]}, state) do
    case JSON.decode(text) do
      {:ok, message} -> receive_message(message, state)
      {:error, _reason} -> {:ok, state}
    end
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl WebSock
  def handle_info({:call, caller, ref, name, arguments, meta}, state) do
    params = %{"name" => name, "arguments" => arguments, "_meta" => meta}
    {frame, state} = request(state, "tools/call", params, {caller, ref, Process.monitor(caller)})
    {:push, frame, state}
  end

  def handle_info({:cancel, ref}, state),
    do:
      cancel(state, &match?({_caller, ^ref, _monitor}, &1), "The call was not answered in time.")

  def handle_info({:DOWN, monitor, :process, _caller, _reason}, state),
    do: cancel(state, &match?({_caller, _ref, ^monitor}, &1), "The call was stopped.")

  def handle_info(:ping, state) do
    schedule_ping()
    {:push, {:ping, ""}, state}
  end

  def handle_info({:EXIT, _from, {:shutdown, :revoked}}, state),
    do: {:stop, {:shutdown, :revoked}, close(:not_found), state}

  def handle_info(_message, state), do: {:ok, state}

  # -- what the worker sends ---------------------------------------------------

  defp receive_message(%{"method" => "notifications/tools/list_changed"}, state) do
    {frame, state} = request(state, "tools/list", %{}, :list)
    {:push, frame, state}
  end

  defp receive_message(%{"method" => "ping", "id" => id}, state),
    do: {:push, response(id, %{"result" => %{}}), state}

  defp receive_message(%{"method" => _method, "id" => id}, state) do
    error = %{"code" => -32_601, "message" => "Method not found"}
    {:push, response(id, %{"error" => error}), state}
  end

  defp receive_message(%{"id" => id} = message, state) when is_map_key(state.pending, id) do
    {purpose, pending} = Map.pop(state.pending, id)
    answered(purpose, message, %{state | pending: pending})
  end

  defp receive_message(_message, state), do: {:ok, state}

  defp answered(:initialize, %{"result" => _result}, state) do
    {list, state} = request(state, "tools/list", %{}, :list)
    {:push, [notification("notifications/initialized", %{}), list], state}
  end

  defp answered(:initialize, _refused, state), do: {:stop, :normal, state}

  defp answered(:list, %{"result" => %{"tools" => listed}}, state) when is_list(listed) do
    tools = for entry <- listed, {:ok, tool} <- [Tool.listed(entry)], do: tool
    :ok = Workers.offer(state.caller, tools, state.since)

    :telemetry.execute([:wardrik, :workers, :listed], %{count: length(tools)}, %{
      worker: self(),
      tools: Enum.map(tools, & &1.name)
    })

    {:ok, state}
  end

  defp answered(:list, _other, state), do: {:ok, state}

  defp answered({caller, ref, monitor}, message, state) do
    Process.demonitor(monitor, [:flush])
    send(caller, {ref, result(message)})
    {:ok, state}
  end

  defp cancel(state, call?, reason) do
    case Enum.find(state.pending, fn {_id, purpose} -> call?.(purpose) end) do
      {id, {_caller, _ref, monitor}} ->
        Process.demonitor(monitor, [:flush])
        params = %{"requestId" => id, "reason" => reason}

        {:push, notification("notifications/cancelled", params),
         %{state | pending: Map.delete(state.pending, id)}}

      nil ->
        {:ok, state}
    end
  end

  defp result(%{"result" => %{"isError" => true} = result}),
    do: Result.error(:tool_error, text(result))

  defp result(%{"result" => %{"structuredContent" => structured} = result})
       when is_map(structured),
       do: Result.ok(structured, cost: cost(result))

  defp result(%{"result" => result}),
    do: Result.ok(%{"content" => text(result)}, cost: cost(result))

  defp result(%{"error" => %{"message" => message}}), do: Result.error(:worker_error, message)

  defp result(_other),
    do: Result.error(:worker_error, "The worker answered with neither a result nor an error.")

  # What a worker says a call cost, in US dollars, as `_meta.costUsd`.
  defp cost(%{"_meta" => %{"costUsd" => usd}}) when is_number(usd) and usd >= 0, do: usd
  defp cost(_result), do: nil

  defp text(%{"content" => content}) when is_list(content),
    do: Enum.map_join(content, "\n", &part/1)

  defp text(_result), do: ""

  defp part(%{"type" => "text", "text" => text}), do: text
  defp part(%{"type" => type}), do: "[#{type} content]"
  defp part(_other), do: ""

  # -- what Wardrik sends ---------------------------------------------------------

  defp request(state, method, params, purpose) do
    id = state.next
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

    {{:text, JSON.encode!(message)},
     %{state | next: id + 1, pending: Map.put(state.pending, id, purpose)}}
  end

  defp notification(method, params),
    do: {:text, JSON.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params})}

  defp response(id, body),
    do: {:text, JSON.encode!(Map.merge(%{"jsonrpc" => "2.0", "id" => id}, body))}

  defp schedule_ping, do: Process.send_after(self(), :ping, @ping)

  defp close(:not_found), do: {1008, "The credential was revoked."}
  defp close(:unavailable), do: {1013, "The credential cannot be checked now. Try again."}

  defp version, do: :wardrik |> Application.spec(:vsn) |> to_string()
end
