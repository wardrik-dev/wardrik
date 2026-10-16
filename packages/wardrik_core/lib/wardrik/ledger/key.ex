defmodule Wardrik.Ledger.Key do
  @moduledoc """
  What a call is claimed under in a `Wardrik.Ledger`, and the idempotency key
  a tool passes to the system it calls, both the same when the call is
  replayed.
  """

  alias Wardrik.Tool

  @doc """
  The key `call` is claimed under when it runs under `scope`: the agent, then
  the turn's trace id, the batch of `Wardrik.Scope.batch/2` the call belongs to,
  and the id the model gave the call.

  A model may give calls in two turns, or in two rounds of one turn, the same
  id, and a delegation's calls are named by its own turn's batches, so no two
  calls share a key. A turn replayed from its journal keeps its trace and
  names its batches as before, so a call replayed keeps its key.
  """
  @spec of(Wardrik.Scope.t(), Tool.call()) :: Wardrik.Ledger.key()
  def of(%Wardrik.Scope{source: source, batch: batch}, %{id: id}) do
    path = [source.trace.trace_id, batch, id] |> Enum.reject(&is_nil/1) |> Enum.join("/")
    {source.agent_id, path}
  end

  @doc """
  A string naming `call` under `scope` that no other call shares, and that the
  same call replayed shares: an idempotency key for a system a tool calls. A
  `Wardrik.Call` names its own scope.
  """
  @spec idempotency(Wardrik.Call.t()) :: String.t()
  def idempotency(%Wardrik.Call{scope: %Wardrik.Scope{} = scope} = call),
    do: idempotency(scope, Wardrik.Call.to_map(call))

  @doc "`idempotency/1` for `call`, written as `t:Wardrik.Tool.call/0` writes one, under `scope`."
  @spec idempotency(Wardrik.Scope.t(), Tool.call()) :: String.t()
  def idempotency(scope, call) do
    {agent_id, call_id} = of(scope, call)
    "#{agent_id}//#{call_id}"
  end
end
