defprotocol Wardrik.Ledger do
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

  `%Wardrik.Ledger.Store{}` writes to the store the fleet already runs on, the
  host's. A deployment that keeps its own system of record implements this
  protocol for a struct of its own instead. Every function is handed the
  store of the host the call runs on as `:store`.

      key = {~A"acme/@jon/assistant", call.id}

      case Wardrik.Ledger.claim(%Wardrik.Ledger.Store{}, key, call: call, store: store) do
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

  A run's `:ledger` has `Wardrik.Call.Pipeline` claim every call the policy
  allows before running it, under `Wardrik.Ledger.Key.of/2`, and settle it
  once it has. A turn a `Wardrik.Agent` runs hands each batch of calls to its
  agent before they run, so a turn lost part way is replayed from that batch
  with the calls it had rather than asking the model again, and the ledger
  answers for each one: a settled call is answered from the ledger without
  running, and a pending one parks for a person to decide, or runs again
  under the same key where its tool declares it may (`Wardrik.Tool.Annotations`).
  A call whose tool answers in doubt keeps its claim pending, so a replay
  asks about it too. See `Wardrik.LLM.Turn`.

  A tool with an effect outside Wardrik passes the idempotency key of the
  `Wardrik.Tool.Context` it is handed along to the system it calls, so the
  effect itself is not repeated either:

      Stripe.refund(order, idempotency_key: context.idempotency_key)

  `Wardrik.Ledger.Guarded` asks a ledger on a call's behalf, so one that
  raises answers an error rather than taking the turn with it.

  ## Claiming without a ledger

  A run that names none has `%Wardrik.Ledger.None{}`, which claims nothing
  and answers `:ok`, so the default costs nothing and no branch anywhere has
  to handle a missing one. It also keeps no guarantee: a turn that runs twice
  does its work twice.
  """

  alias Wardrik.Ledger.Entry
  alias Wardrik.Tool

  @typedoc """
  The agent a call belongs to, and the call's place within its turn: the
  turn's trace id, the batch the call was asked for in, and the id the model
  gave it, as `Wardrik.Ledger.Key.of/2` builds it.
  """
  @type key() :: {Wardrik.Event.Bus.agent_id(), call_id :: String.t()}

  @typedoc "What a ledger says about one call."
  @type claim() ::
          :ok
          | {:settled, Tool.Result.t()}
          | {:pending, Entry.t()}
          | {:error, term()}

  @doc """
  Records that the `:call` `opts` name is about to run, and says whether
  anything already did.

  Called once per call, before its tool runs. An implementation must not
  write over an entry it finds: the answer to a second claim is the first
  one's state, whatever it is.
  """
  @spec claim(t(), key(), call: Tool.call(), store: WardrikStore.t()) :: claim()
  def claim(ledger, key, opts)

  @doc """
  Records the `:result` a claimed call returned.

  Answers `{:error, :not_claimed}` for a key holding no entry, which is a
  settle without a claim before it rather than something to write anyway.
  """
  @spec settle(t(), key(), result: Tool.Result.t(), store: WardrikStore.t()) ::
          :ok | {:error, term()}
  def settle(ledger, key, opts)

  @doc "The entry a key holds, if it holds one."
  @spec fetch(t(), key(), store: WardrikStore.t()) :: {:ok, Entry.t()} | :error
  def fetch(ledger, key, opts)

  @doc """
  Removes a claim for a call that did not run after all: one that stopped to
  ask a person before doing anything. `:ok` for a ledger that keeps no such
  thing.
  """
  @spec release(t(), key(), store: WardrikStore.t()) :: :ok | {:error, term()}
  def release(ledger, key, opts)

  @doc """
  Removes every entry the turn `:trace` made, the calls of its delegations
  included, once the turn has ended and nothing will replay it. `:ok` for a
  ledger that keeps no such thing.
  """
  @spec forget(t(), Wardrik.Event.Bus.agent_id(), trace: String.t(), store: WardrikStore.t()) ::
          :ok | {:error, term()}
  def forget(ledger, agent_id, opts)
end
