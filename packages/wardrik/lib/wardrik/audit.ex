defmodule Wardrik.Audit do
  @moduledoc """
  What people changed, and who changed it: one log for the whole cluster,
  beside each agent's own.

      :ok = Wardrik.Audit.record({:agent_forgotten, ~A"acme/triage"}, by)

  A surface people act through, the CLI, the TUI or the HTTP API, records
  each change it makes once it is made, with the `Wardrik.Principal` who
  asked for it, or `nil` where none is known. What an agent does on its own,
  and what a node does as it starts, is not recorded here; an agent's own log
  holds what it did.

  ## The log

  Each change is a CloudEvent, as `Wardrik.Event.Codec` writes it, in the
  `Wardrik.Event.Log` named `:audit`, which is read, followed and trimmed as
  an agent's log is. Its numbers start at 1 and run without a gap.

  Any node writes it. This process holds the last number it knows was
  written, and writes the next change after it on the condition that nothing
  is there yet. Where a write on another node took that number first, it
  finds the new end through consensus and writes after that. A write the
  store fails is logged and not retried. After each write it drops what is
  older than `Wardrik.Event.Log.retention_days/0`.
  """

  use GenServer

  require Logger

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Event.Codec
  alias Wardrik.Event.Log
  alias Wardrik.Event.Log.Entry
  alias Wardrik.Principal
  alias Wardrik.Trace

  @enforce_keys [:id, :action, :at, :trace]
  defstruct [:id, :action, :by, :at, :trace]

  @typedoc """
  A change, as a tuple whose first element names it.

  Agents, by their ID:

    * `{:agent_defined, id}` - its definition was written, and the agent
      started or brought to it
    * `{:agent_spawned, id, node}` - it was started, on `node`
    * `{:agent_stopped, id}` - it was stopped, keeping its conversation
    * `{:agent_forgotten, id}` - it was removed, with everything it had;
      `{:agent_forgotten, id, prefix}` where it was one of the agents under
      `prefix` someone removed at once
    * `{:agent_moved, id, node}` - it was started again on `node`
    * `{:agent_cancelled, id}` - its turn, and what was queued behind it,
      were dropped; `{:agent_cancelled, id, prefix}` where it was one of the
      agents under `prefix` someone cancelled at once
    * `{:agent_cleared, id}` - its conversation was emptied
    * `{:trigger_set, id, name}`, `{:trigger_removed, id, name}`
    * `{:agents_reloaded, nodes}` - the files that declare agents were read
      again on `nodes`

  Rooms, by the channel they are in and their id there:

    * `{:room_bound, channel, room, agent, answers}` - the agent `agent`
      answers in the room from now on: when mentioned, `:mentions`, or to
      every message, `:everything`
    * `{:room_unbound, channel, room}` - no agent answers in it any longer

  Credentials:

    * `{:token_created, token_id, name, grant, for}` - an API token was made,
      reaching what its `Wardrik.Grant` reaches, for the principal `for`
      names, or for itself where `nil`
    * `{:token_revoked, token_id}`
    * `{:secret_stored, name, owner}`, `{:secret_removed, name, owner}` - a
      secret was sealed in the vault, or taken out, for the org or user
      `owner` names, or for the whole deployment where it is every agent
  """
  @type action() ::
          {:agent_defined, AgentID.t()}
          | {:agent_spawned, AgentID.t(), node()}
          | {:agent_stopped, AgentID.t()}
          | {:agent_forgotten, AgentID.t()}
          | {:agent_forgotten, AgentID.t(), Prefix.t()}
          | {:agent_moved, AgentID.t(), node()}
          | {:agent_cancelled, AgentID.t()}
          | {:agent_cancelled, AgentID.t(), Prefix.t()}
          | {:agent_cleared, AgentID.t()}
          | {:trigger_set, AgentID.t(), String.t()}
          | {:trigger_removed, AgentID.t(), String.t()}
          | {:agents_reloaded, [node()]}
          | {:room_bound, String.t(), String.t(), AgentID.t(), :mentions | :everything}
          | {:room_unbound, String.t(), String.t()}
          | {:token_created, String.t(), String.t(), Wardrik.Grant.t(), Principal.t() | nil}
          | {:token_revoked, String.t()}
          | {:secret_stored, String.t(), Prefix.t()}
          | {:secret_removed, String.t(), Prefix.t()}

  @typedoc """
  A change, who made it, and when, under a UUIDv7 of its own, at the root of
  a trace of its own.
  """
  @type t() :: %__MODULE__{
          id: String.t(),
          action: action(),
          by: Principal.t() | nil,
          at: integer(),
          trace: Trace.t()
        }

  @doc "A change `by` made, now, without recording it, under `trace` or a trace of its own."
  @spec new(action(), Principal.t() | nil, Trace.t()) :: t()
  def new(action, by, trace \\ Trace.root())
      when is_tuple(action) and (is_struct(by, Principal) or is_nil(by)) do
    %__MODULE__{
      id: Wardrik.UUID.v7(),
      action: action,
      by: by,
      at: System.system_time(:microsecond),
      trace: trace
    }
  end

  @doc "Records `action`, made by `by`, in the audit log."
  @spec record(action(), Principal.t() | nil) :: :ok
  def record(action, by), do: GenServer.call(__MODULE__, {:record, new(action, by)})

  @doc """
  Records `actions`, made by `by` as one change, in the audit log: each its
  own entry, all under one trace, so the entries say they were one change.
  """
  @spec record_all([action()], Principal.t() | nil) :: :ok
  def record_all(actions, by) when is_list(actions) do
    trace = Trace.root()
    Enum.each(actions, &(:ok = GenServer.call(__MODULE__, {:record, new(&1, by, trace)})))
  end

  @doc false
  @spec start_link(WardrikStore.t()) :: GenServer.on_start()
  def start_link(%WardrikStore{} = store),
    do: GenServer.start_link(__MODULE__, store, name: __MODULE__)

  # The head is found on the first write, not as the process starts.
  @impl true
  def init(store), do: {:ok, {store, nil}}

  @impl true
  def handle_call({:record, audit}, _from, {store, head}) do
    head = head || Log.head(store, :audit, Log.oldest(store, :audit, consistent: true) - 1)
    head = write(store, audit, head + 1)
    {:reply, :ok, {store, head}, {:continue, :trim}}
  end

  @impl true
  def handle_continue(:trim, {store, head}) do
    cutoff = DateTime.add(DateTime.utc_now(), -Log.retention_days(), :day)

    # Another node trimming the same log at once is the one conflict here,
    # and leaves the log as trimmed as this would.
    case Log.trim(store, :audit, head, cutoff) do
      :ok -> :ok
      {:error, :conflict} -> :ok
      {:error, reason} -> Logger.warning("Could not trim the audit log: #{inspect(reason)}")
    end

    {:noreply, {store, head}}
  end

  # The head after writing `audit` at `sequence`, or past it where that is
  # taken.
  defp write(store, audit, sequence) do
    {:ok, event} = Codec.encode(audit, sequence: sequence)

    case WardrikStore.put(store, Log.namespace(), Log.key(:audit, sequence), event, if_vsn: nil) do
      {:ok, _vsn} ->
        :ok = Log.publish(:audit, %Entry{event: event, sequence: sequence, follows: sequence - 1})
        sequence

      {:error, :conflict} ->
        write(store, audit, Log.head(store, :audit, sequence) + 1)

      {:error, reason} ->
        Logger.warning("Could not write #{event["type"]} to the audit log: #{inspect(reason)}")
        sequence - 1
    end
  end
end
