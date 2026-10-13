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

  `Wardrik.Ledger.Store` writes to the store the fleet already runs on, the
  host's. A deployment that keeps its own system of record implements this
  behaviour instead. Every callback is handed the `Wardrik.Host` the call runs
  on.

      key = {~A"acme/@jon/assistant", call.id}

      case Wardrik.Ledger.claim(Wardrik.Ledger.Store, host, key, call) do
        :ok -> run(call)
        {:settled, result} -> result
        {:pending, entry} -> park(entry)
        {:error, reason} -> refuse(reason)
      end

  ## The four answers

    * `:ok` - nothing has run this call, and the claim is now held. Run it, and
      report what it returned with `settle/4`.
    * `{:settled, result}` - it ran, and this is what it returned. Answer the
      model with that rather than running it again.
    * `{:pending, entry}` - it was claimed and never settled. Whether its
      effect happened is unknown, and guessing either way is worse than
      asking, so this belongs in front of a person.
    * `{:error, reason}` - the ledger could not answer. A call with an outside
      effect does not run on an unanswered ledger.

  ## In a turn

  A scope that names a ledger, as `:ledger`, has `Wardrik.Call.Pipeline` claim
  every call the policy allows before running it, under `key/2`, and settle it
  once it has. A turn a `Wardrik.Agent` runs hands each batch of calls to its
  agent before they run, so a turn lost part way is replayed from that batch
  with the calls it had rather than asking the model again, and the ledger
  answers for each one: a settled call is answered from the ledger without
  running, and a pending one parks for a person to decide, or runs again
  under the same key where its tool declares it may (`Wardrik.Tool.Annotations`).
  A call whose tool answers in doubt keeps its claim pending, so a replay
  asks about it too. See `Wardrik.LLM.Turn`.

  A tool with an effect outside Wardrik, handed its `Wardrik.Call` (see
  `Wardrik.Tool.new!/1`), passes `idempotency_key/1` along to the system it calls,
  so the effect itself is not repeated either:

      Stripe.refund(order, idempotency_key: Wardrik.Ledger.idempotency_key(call))

  ## Claiming without a ledger

  A run with no ledger claims nothing and answers `:ok`, so the default costs
  nothing and no branch anywhere has to handle a missing one. It also keeps no
  guarantee: a turn that runs twice does its work twice.
  """

  alias Wardrik.Ledger.Entry
  alias Wardrik.Tool

  @typedoc """
  The agent a call belongs to, and the call's place within its turn: the
  turn's trace id, the batch the call was asked for in, and the id the model
  gave it, as `key/2` builds it.
  """
  @type key() :: {Wardrik.Event.Bus.agent_id(), call_id :: String.t()}

  @typedoc "What a ledger says about one call."
  @type claim() ::
          :ok
          | {:settled, Tool.Result.t()}
          | {:pending, Entry.t()}
          | {:error, term()}

  @doc """
  Records that `call` is about to run, and says whether anything already did.

  Called once per call, before the tool's callback is invoked. An
  implementation must not write over an entry it finds: the answer to a second
  claim is the first one's state, whatever it is.
  """
  @callback claim(Wardrik.Host.t(), key(), Tool.call()) :: claim()

  @doc """
  Records what a claimed call returned.

  Answers `{:error, :not_claimed}` for a key holding no entry, which is a
  settle without a claim before it rather than something to write anyway.
  """
  @callback settle(Wardrik.Host.t(), key(), Tool.Result.t()) :: :ok | {:error, term()}

  @doc "The entry a key holds, if it holds one."
  @callback fetch(Wardrik.Host.t(), key()) :: {:ok, Entry.t()} | :error

  @doc """
  Removes a claim for a call that did not run after all: one that stopped to
  ask a person before doing anything.
  """
  @callback release(Wardrik.Host.t(), key()) :: :ok | {:error, term()}

  @doc """
  Removes every entry a turn made, the calls of its delegations included, once
  the turn has ended and nothing will replay it.
  """
  @callback forget(Wardrik.Host.t(), Wardrik.Event.Bus.agent_id(), trace_id :: String.t()) ::
              :ok | {:error, term()}

  @optional_callbacks release: 2, forget: 3

  @doc """
  The key `call` is claimed under when it runs under `scope`: the agent, then
  the turn's trace id, the batch of `Wardrik.Scope.batch/2` the call belongs to,
  and the id the model gave the call.

  A model may give calls in two turns, or in two rounds of one turn, the same
  id, and a delegation's calls are named by its own turn's batches, so no two
  calls share a key. A turn replayed from its journal keeps its trace and
  names its batches as before, so a call replayed keeps its key.
  """
  @spec key(Wardrik.Scope.t(), Tool.call()) :: key()
  def key(%Wardrik.Scope{source: source, batch: batch}, %{id: id}) do
    path = [source.trace.trace_id, batch, id] |> Enum.reject(&is_nil/1) |> Enum.join("/")
    {source.agent_id, path}
  end

  @doc """
  A string naming `call` under `scope` that no other call shares, and that the
  same call replayed shares: an idempotency key for a system a tool calls. A
  `Wardrik.Call` names its own scope.
  """
  @spec idempotency_key(Wardrik.Call.t()) :: String.t()
  def idempotency_key(%Wardrik.Call{scope: %Wardrik.Scope{} = scope} = call),
    do: idempotency_key(scope, Wardrik.Call.to_map(call))

  @doc "`idempotency_key/1` for `call`, written as `t:Wardrik.Tool.call/0` writes one, under `scope`."
  @spec idempotency_key(Wardrik.Scope.t(), Tool.call()) :: String.t()
  def idempotency_key(scope, call) do
    {agent_id, call_id} = key(scope, call)
    "#{agent_id}//#{call_id}"
  end

  @doc """
  Claims `call` through `ledger`, answering `:ok` when there is no ledger.

  A ledger that raises, throws or exits answers `{:error, reason}`. A ledger
  that cannot say whether a call has run has to stop it: the guarantee is only
  worth the cases it covers, and one that fails open covers none.
  """
  @spec claim(module() | nil, Wardrik.Host.t(), key(), Tool.call()) :: claim()
  def claim(nil, _host, _key, _call), do: :ok

  def claim(ledger, host, key, call) when is_atom(ledger) do
    case ledger.claim(host, key, call) do
      :ok -> :ok
      {:settled, result} -> {:settled, result}
      {:pending, %Entry{} = entry} -> {:pending, entry}
      {:error, reason} -> {:error, reason}
      other -> {:error, "Ledger #{inspect(ledger)} returned #{inspect(other)}"}
    end
  catch
    kind, reason ->
      {:error, "Ledger #{inspect(ledger)} failed: #{Exception.format(kind, reason)}"}
  end

  @doc """
  Settles `key` through `ledger`, doing nothing when there is no ledger.

  A ledger that raises answers `{:error, reason}`. The call has already run by
  now, so a failure here loses the record rather than the work, and the entry
  stays pending until its turn is forgotten.
  """
  @spec settle(module() | nil, Wardrik.Host.t(), key(), Tool.Result.t()) :: :ok | {:error, term()}
  def settle(nil, _host, _key, _result), do: :ok

  def settle(ledger, host, key, result) when is_atom(ledger) do
    case ledger.settle(host, key, result) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, "Ledger #{inspect(ledger)} returned #{inspect(other)}"}
    end
  catch
    kind, reason ->
      {:error, "Ledger #{inspect(ledger)} failed: #{Exception.format(kind, reason)}"}
  end

  @doc """
  Releases `key` through `ledger`, doing nothing when there is no ledger or it
  keeps no releases. A failure is answered, not raised: the claim stays
  pending until its turn is forgotten.
  """
  @spec release(module() | nil, Wardrik.Host.t(), key()) :: :ok | {:error, term()}
  def release(nil, _host, _key), do: :ok

  def release(ledger, host, key) when is_atom(ledger) do
    if Code.ensure_loaded?(ledger) and function_exported?(ledger, :release, 2),
      do: ledger.release(host, key),
      else: :ok
  catch
    kind, reason ->
      {:error, "Ledger #{inspect(ledger)} failed: #{Exception.format(kind, reason)}"}
  end

  @doc """
  Forgets the entries of the turn `trace_id` through `ledger`, doing nothing
  when there is no ledger or it keeps no such thing. A failure is answered, not
  raised: the entries stay, and nothing reads them again.

  `[:wardrik, :ledger, :forgotten]` is emitted once the ledger has answered, with
  the agent id, the trace id and the answer in its metadata.
  """
  @spec forget(module() | nil, Wardrik.Host.t(), Wardrik.Event.Bus.agent_id(), String.t()) ::
          :ok | {:error, term()}
  def forget(nil, _host, _agent_id, _trace_id), do: :ok

  def forget(ledger, host, agent_id, trace_id) when is_atom(ledger) do
    answer =
      if Code.ensure_loaded?(ledger) and function_exported?(ledger, :forget, 3),
        do: ledger.forget(host, agent_id, trace_id),
        else: :ok

    :telemetry.execute([:wardrik, :ledger, :forgotten], %{}, %{
      agent_id: agent_id,
      trace_id: trace_id,
      answer: answer
    })

    answer
  catch
    kind, reason ->
      {:error, "Ledger #{inspect(ledger)} failed: #{Exception.format(kind, reason)}"}
  end

  @doc "The entry `ledger` holds for `key`, or `:error` without a ledger."
  @spec fetch(module() | nil, Wardrik.Host.t(), key()) :: {:ok, Entry.t()} | :error
  def fetch(nil, _host, _key), do: :error

  def fetch(ledger, host, key) when is_atom(ledger) do
    case ledger.fetch(host, key) do
      {:ok, %Entry{} = entry} -> {:ok, entry}
      _other -> :error
    end
  catch
    _kind, _reason -> :error
  end
end
