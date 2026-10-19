defmodule Wardrik.Ledger do
  @moduledoc """
  Whether a tool call has already run, recorded before it does.

  A turn is one durable unit: its tool results reach the store when the turn
  returns, not as each call lands. A turn lost part way comes back owed and
  runs again from the context it left, so every call it had already made runs a
  second time. A ledger is what lets the second run skip work the first one
  finished, and what turns work of unknown outcome into a question rather than
  a repeat.

  A ledger is not a lock. `Wardrik.Agent` is keyed, so one process holds an agent
  anywhere in the cluster and its turns are serialised already; there is
  nothing here to hold and nothing to wait on. An entry is written once and
  read on replay.

  Every run has one, kept in the store of the host it runs on, the store the
  fleet already runs on, so a host configures nothing for it. Entries are
  written under the `:claims` namespace, one per agent and call id, as the
  agent's resource name, then `//`, which no name holds, then the call id. A claim is a
  write conditional on nothing being written yet, so a second claim answers
  with the first one's state whatever adapter is underneath.

      key = {~A"acme/@jon/assistant", call.id}

      case Wardrik.Ledger.claim(store, key, call: call) do
        :ok -> run(call)
        {:settled, result} -> result
        {:pending, entry} -> park(entry)
        {:error, reason} -> refuse(reason)
      end

  ## The four answers

    * `:ok` - nothing has run this call, and the claim is now held. Run it, and
      report what it returned with `settle/3`.
    * `{:settled, result}` - it ran, and this is what it returned. Answer the
      model with that rather than running it again.
    * `{:pending, entry}` - it was claimed and never settled. Whether its
      effect happened is unknown, and guessing either way is worse than
      asking, so this belongs in front of a person.
    * `{:error, reason}` - the store could not answer. A call with an outside
      effect does not run on an unanswered ledger.

  A store that raises as a call is claimed takes the call with it, as a tool
  that raises does: `Wardrik.LLM.ToolRunner` answers it as crashed, and its
  tool does not run. On `WardrikStore.None`, whose every read and write
  raises, no tool call runs. One that raises as a call is settled loses the
  record alone: the call has run, so `Wardrik.Call.Pipeline` answers it with
  what it returned, and its claim stays pending for a replay to ask about.

  ## In a turn

  `Wardrik.Call.Pipeline` claims every call the policy allows before running
  it, under `Wardrik.Ledger.Key.of/2`, and settles it once it has. A turn a
  `Wardrik.Agent` runs hands each batch of calls to its agent before they
  run, so a turn lost part way is replayed from that batch with the calls it
  had rather than asking the model again, and the ledger answers for each
  one: a settled call is answered from the ledger without running, and a
  pending one parks for a person to decide, or runs again under the same key
  where its tool declares it may (`Wardrik.Tool.Annotations`). A call whose
  tool answers in doubt keeps its claim pending, so a replay asks about it
  too. See `Wardrik.LLM.Turn`.

  A tool with an effect outside Wardrik passes the idempotency key of the
  `Wardrik.Tool.Context` it is handed along to the system it calls, so the
  effect itself is not repeated either:

      Stripe.refund(order, idempotency_key: context.idempotency_key)

  ## Retention

  An entry lasts as long as the turn that made it, however long that turn
  waits on a person, and `forget/3` removes the turn's entries once it has
  ended.
  """

  alias Wardrik.AgentAddress
  alias Wardrik.Ledger.Entry
  alias Wardrik.Tool

  @ns :claims

  @typedoc """
  The agent a call belongs to, and the call's place within its turn: the
  turn's trace id, the batch the call was asked for in, and the id the model
  gave it, as `Wardrik.Ledger.Key.of/2` builds it.
  """
  @type key() :: {Wardrik.Event.Bus.agent_id(), call_id :: String.t()}

  @typedoc "What the ledger says about one call."
  @type claim() ::
          :ok
          | {:settled, Tool.Result.t()}
          | {:pending, Entry.t()}
          | {:error, term()}

  @doc """
  Records in `store` that the `:call` `opts` name is about to run, and says
  whether anything already did.

  Called once per call, before its tool runs. An entry already written is
  never written over: the answer to a second claim is the first one's state,
  whatever it is.
  """
  @spec claim(WardrikStore.t(), key(), call: Tool.call()) :: claim()
  def claim(store, key, opts) do
    entry = Entry.claimed(Keyword.fetch!(opts, :call))

    case WardrikStore.put(store, @ns, encoded(key), entry, if_vsn: nil) do
      {:ok, _vsn} -> :ok
      {:error, :conflict} -> held(store, key)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Records the `:result` a claimed call returned.

  Answers `{:error, :not_claimed}` for a key holding no entry, which is a
  settle without a claim before it rather than something to write anyway.
  """
  @spec settle(WardrikStore.t(), key(), result: Tool.Result.t()) :: :ok | {:error, term()}
  def settle(store, key, opts) do
    encoded = encoded(key)

    case WardrikStore.lookup(store, @ns, encoded) do
      nil ->
        {:error, :not_claimed}

      {%Entry{} = entry, vsn} ->
        write(store, encoded, Entry.settled(entry, Keyword.fetch!(opts, :result)), vsn)

      {other, _vsn} ->
        {:error, {:unexpected_entry, other}}
    end
  end

  @doc "The entry `key` holds in `store`, if it holds one."
  @spec fetch(WardrikStore.t(), key()) :: {:ok, Entry.t()} | :error
  def fetch(store, key) do
    case WardrikStore.get(store, @ns, encoded(key)) do
      %Entry{} = entry -> {:ok, entry}
      _other -> :error
    end
  end

  @doc """
  Removes a claim for a call that did not run after all: one that stopped to
  ask a person before doing anything. A claim settled since it was made is
  not the claim being released, and stays.
  """
  @spec release(WardrikStore.t(), key()) :: :ok | {:error, term()}
  def release(store, key) do
    encoded = encoded(key)

    case WardrikStore.lookup(store, @ns, encoded) do
      {%Entry{result: nil}, vsn} -> delete(store, encoded, vsn)
      _settled_or_gone -> :ok
    end
  end

  @doc """
  Removes every entry the turn `:trace` made, the calls of its delegations
  included, which share its trace, once the turn has ended and nothing will
  replay it.

  `[:wardrik, :ledger, :forgotten]` is emitted once the store has answered,
  with the agent id, the trace id and the answer in its metadata.
  """
  @spec forget(WardrikStore.t(), Wardrik.Event.Bus.agent_id(), trace: String.t()) ::
          :ok | {:error, term()}
  def forget(store, agent_id, opts) do
    trace_id = Keyword.fetch!(opts, :trace)

    answer =
      store
      |> WardrikStore.keys(@ns, "#{AgentAddress.resource(agent_id)}//#{trace_id}/")
      |> Enum.reduce_while(:ok, fn encoded, :ok ->
        case WardrikStore.lookup(store, @ns, encoded) do
          {_entry, vsn} -> delete(store, encoded, vsn) |> continue()
          nil -> {:cont, :ok}
        end
      end)

    :telemetry.execute([:wardrik, :ledger, :forgotten], %{}, %{
      agent_id: agent_id,
      trace_id: trace_id,
      answer: answer
    })

    answer
  end

  defp continue(:ok), do: {:cont, :ok}
  defp continue({:error, reason}), do: {:halt, {:error, reason}}

  defp encoded({agent_id, call_id}), do: "#{AgentAddress.resource(agent_id)}//#{call_id}"

  defp delete(store, encoded, vsn) do
    case WardrikStore.delete(store, @ns, encoded, if_vsn: vsn) do
      :ok -> :ok
      {:error, :conflict} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp write(store, encoded, entry, vsn) do
    case WardrikStore.put(store, @ns, encoded, entry, if_vsn: vsn) do
      {:ok, _vsn} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp held(store, key) do
    case WardrikStore.get(store, @ns, encoded(key), consistent: true) do
      %Entry{result: nil} = entry -> {:pending, entry}
      %Entry{result: result} -> {:settled, result}
      nil -> {:error, :forgotten}
      other -> {:error, {:unexpected_entry, other}}
    end
  end
end
