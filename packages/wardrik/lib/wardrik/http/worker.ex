defmodule WardrikHTTP.Worker do
  @moduledoc """
  The tool workers' WebSocket at `GET /v1/workers`. Wardrik is the MCP client over it.

  A worker is an MCP server that connects in. It serves the agents your authorizer lets it
  `agent.serve`. Messages are JSON-RPC 2.0, one per text frame, as MCP `2025-06-18` says:

      {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
       "params": {"name": "refund_order", "arguments": {"order": "A1"},
                  "_meta": {"agent": "agt_1", "run": "4bf92f35...",
                            "principal": "user_42", "idempotencyKey": "call_1"}}}

    1. Wardrik sends `initialize`, then `notifications/initialized`.
    2. Wardrik sends `tools/list`. Send `notifications/tools/list_changed` to be listed again.
    3. Wardrik sends `tools/call` for each call. Answer with a `CallToolResult`, and its cost as
       `_meta.costUsd`.
    4. Wardrik sends `notifications/cancelled` when it stops waiting on a call.

    * Agents name the tools `workers/<name>`. A tool without `readOnlyHint` counts as one that
      changes things.
    * Wardrik pings every `:keepalive` milliseconds and authenticates again. It closes with `1008`
      if that fails.
  """

  @behaviour WebSock

  @protocol "2025-06-18"

  @enforce_keys [:scope, :alive?, :keepalive]
  defstruct [:scope, :alive?, :keepalive, next: 1, pending: %{}]

  @impl WebSock
  def init(%{scope: scope, alive?: alive?, keepalive: keepalive}) do
    state = %__MODULE__{scope: scope, alive?: alive?, keepalive: keepalive}
    keep_alive(state)

    params = %{
      "protocolVersion" => @protocol,
      "capabilities" => %{},
      "clientInfo" => %{"name" => "wardrik", "version" => version()}
    }

    {frame, state} = request(state, "initialize", params, :initialize)
    {:push, frame, state}
  end

  @impl WebSock
  def handle_in({text, [opcode: :text]}, state) do
    case JSON.decode(text) do
      {:ok, message} -> received(message, state)
      {:error, _reason} -> {:ok, state}
    end
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl WebSock
  def handle_info({Wardrik.Workers, :call, {caller, _ref} = call, name, arguments, meta}, state) do
    params = %{"name" => name, "arguments" => arguments, "_meta" => meta}
    {frame, state} = request(state, "tools/call", params, {call, Process.monitor(caller)})
    {:push, frame, state}
  end

  def handle_info({Wardrik.Workers, :cancel, call}, state),
    do: cancel(state, &match?({^call, _monitor}, &1), "Wardrik stopped waiting for it.")

  def handle_info({:DOWN, monitor, :process, _caller, _reason}, state),
    do: cancel(state, &match?({_call, ^monitor}, &1), "The call was stopped.")

  def handle_info(:keepalive, state) do
    case state.alive?.() do
      true -> pinged(state)
      false -> {:stop, :normal, {1008, "The request no longer authenticates."}, state}
    end
  end

  def handle_info(_message, state), do: {:ok, state}

  defp pinged(state) do
    keep_alive(state)
    {:push, {:ping, ""}, state}
  end

  defp received(%{"method" => "notifications/tools/list_changed"}, state) do
    {frame, state} = request(state, "tools/list", %{}, :list)
    {:push, frame, state}
  end

  defp received(%{"method" => "ping", "id" => id}, state),
    do: {:push, response(id, %{"result" => %{}}), state}

  defp received(%{"method" => _method, "id" => id}, state),
    do:
      {:push, response(id, %{"error" => %{"code" => -32_601, "message" => "Method not found"}}),
       state}

  defp received(%{"id" => id} = message, state) when is_map_key(state.pending, id) do
    {purpose, pending} = Map.pop(state.pending, id)
    answered(purpose, message, %{state | pending: pending})
  end

  defp received(_message, state), do: {:ok, state}

  defp answered(:initialize, %{"result" => _result}, state) do
    {list, state} = request(state, "tools/list", %{}, :list)
    {:push, [notification("notifications/initialized", %{}), list], state}
  end

  defp answered(:initialize, _refused, state), do: {:stop, :normal, state}

  defp answered(:list, %{"result" => %{"tools" => tools}}, state) when is_list(tools) do
    :ok = state.scope.server.offer(state.scope, tools)
    {:ok, state}
  end

  defp answered(:list, _refused, state), do: {:ok, state}

  defp answered({call, monitor}, message, state) do
    Process.demonitor(monitor, [:flush])
    :ok = state.scope.server.answer(call, message)
    {:ok, state}
  end

  defp cancel(state, call?, reason) do
    case Enum.find(state.pending, fn {_id, purpose} -> call?.(purpose) end) do
      {id, {_call, monitor}} ->
        Process.demonitor(monitor, [:flush])

        cancelled =
          notification("notifications/cancelled", %{"requestId" => id, "reason" => reason})

        {:push, cancelled, %{state | pending: Map.delete(state.pending, id)}}

      nil ->
        {:ok, state}
    end
  end

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

  defp keep_alive(state), do: Process.send_after(self(), :keepalive, state.keepalive)

  defp version, do: :wardrik_http |> Application.spec(:vsn) |> to_string()
end
