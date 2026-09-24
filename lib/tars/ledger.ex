defmodule Tars.Ledger do
  @moduledoc """
  Whether a tool call has already run, recorded before it does.

  A turn is one durable unit: its tool results reach the store when the turn
  returns, not as each call lands. A turn lost part way comes back owed and
  runs again from the context it left, so every call it had already made runs a
  second time. A ledger is what lets the second run skip work the first one
  finished, and what turns work of unknown outcome into a question rather than
  a repeat.

  A ledger is not a lock. `Tars.Agent` is keyed, so one process holds an agent
  anywhere in the cluster and its turns are serialised already; there is
  nothing here to hold and nothing to wait on. An entry is written once and
  read on replay.

  `Tars.Ledger.Store` writes to the store the fleet already runs on. A deployment
  that keeps its own system of record implements this behaviour instead.

      key = {"acme/jon/assistant", call.id}

      case Tars.Ledger.claim(Tars.Ledger.Store, key, call) do
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
    * `{:error, reason}` - the ledger could not answer. A call with an outside
      effect does not run on an unanswered ledger.

  ## In a turn

  A scope that names a ledger, as `:ledger`, has `Tars.LLM.ToolRunner` claim
  every call the policy allows before running it, under `key/2`, and settle it
  once it has. A turn a `Tars.Agent` runs hands each batch of calls to its
  agent before they run, so a turn lost part way is replayed from that batch
  with the calls it had rather than asking the model again, and the ledger
  answers for each one: a settled call is answered from the ledger without
  running, and a pending one parks for a person to decide. See
  `Tars.LLM.Turn`.

  A tool with an effect outside Tars passes `idempotency_key/2` along to the
  system it calls, so the effect itself is not repeated either:

      key = Tars.Ledger.idempotency_key(Tars.Scope.Context.current(), Tars.Scope.Context.current_call())
      Stripe.refund(order, idempotency_key: key)

  ## Claiming without a ledger

  A run with no ledger claims nothing and answers `:ok`, so the default costs
  nothing and no branch anywhere has to handle a missing one. It also keeps no
  guarantee: a turn that runs twice does its work twice.
  """

  alias Tars.Ledger.Entry
  alias Tars.Tool

  @typedoc """
  The agent a call belongs to, and the call's id within its turn: the turn's
  trace id and the id the model gave the call, as `key/2` builds it.
  """
  @type key() :: {Tars.Event.Bus.agent_id(), call_id :: String.t()}

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
  @callback claim(key(), Tool.call()) :: claim()

  @doc """
  Records what a claimed call returned.

  Answers `{:error, :not_claimed}` for a key holding no entry, which is a
  settle without a claim before it rather than something to write anyway.
  """
  @callback settle(key(), Tool.Result.t()) :: :ok | {:error, term()}

  @doc "The entry a key holds, if it holds one."
  @callback fetch(key()) :: {:ok, Entry.t()} | :error

  @doc """
  Removes a claim for a call that did not run after all: one that stopped to
  ask a person before doing anything.
  """
  @callback release(key()) :: :ok | {:error, term()}

  @optional_callbacks release: 1

  @doc """
  The key `call` is claimed under when it runs under `scope`.

  A model may give two calls in different turns the same id, so the key holds
  the turn's trace id beside it, which a turn replayed from its journal keeps.
  """
  @spec key(Tars.Scope.t(), Tool.call()) :: key()
  def key(%Tars.Scope{source: source}, %{id: id}),
    do: {source.agent_id, source.trace.trace_id <> "/" <> id}

  @doc """
  A string naming `call` under `scope` that no other call shares, and that the
  same call replayed shares: an idempotency key for a system a tool calls.
  """
  @spec idempotency_key(Tars.Scope.t(), Tool.call()) :: String.t()
  def idempotency_key(scope, call) do
    {agent_id, call_id} = key(scope, call)
    "#{agent_id}/#{call_id}"
  end

  @doc """
  Claims `call` through `ledger`, answering `:ok` when there is no ledger.

  A ledger that raises, throws or exits answers `{:error, reason}`. A ledger
  that cannot say whether a call has run has to stop it: the guarantee is only
  worth the cases it covers, and one that fails open covers none.
  """
  @spec claim(module() | nil, key(), Tool.call()) :: claim()
  def claim(nil, _key, _call), do: :ok

  def claim(ledger, key, call) when is_atom(ledger) do
    case ledger.claim(key, call) do
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
  stays pending until it expires.
  """
  @spec settle(module() | nil, key(), Tool.Result.t()) :: :ok | {:error, term()}
  def settle(nil, _key, _result), do: :ok

  def settle(ledger, key, result) when is_atom(ledger) do
    case ledger.settle(key, result) do
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
  pending until it expires.
  """
  @spec release(module() | nil, key()) :: :ok | {:error, term()}
  def release(nil, _key), do: :ok

  def release(ledger, key) when is_atom(ledger) do
    if Code.ensure_loaded?(ledger) and function_exported?(ledger, :release, 1),
      do: ledger.release(key),
      else: :ok
  catch
    kind, reason ->
      {:error, "Ledger #{inspect(ledger)} failed: #{Exception.format(kind, reason)}"}
  end

  @doc "The entry `ledger` holds for `key`, or `:error` without a ledger."
  @spec fetch(module() | nil, key()) :: {:ok, Entry.t()} | :error
  def fetch(nil, _key), do: :error

  def fetch(ledger, key) when is_atom(ledger) do
    case ledger.fetch(key) do
      {:ok, %Entry{} = entry} -> {:ok, entry}
      _other -> :error
    end
  catch
    _kind, _reason -> :error
  end
end
