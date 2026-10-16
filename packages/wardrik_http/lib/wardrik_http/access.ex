defmodule WardrikHTTP.Access do
  @moduledoc """
  Whether a caller may act on an agent, and for how long what it was granted
  holds.

  A surface knows its callers by a credential of its own, a bearer token or an
  SSH key, and keeps what the credential grants in a record in the store the
  fleet runs on, which every function reading or holding a record is handed
  first. It reads the record with `get/2`, and asks `authorize/3` before each
  thing the caller does:

      with {:ok, token} <- WardrikHTTP.Access.get(store, {:tokens, id}),
           :ok <- WardrikHTTP.Access.authorize(token.grant, :message, key) do
        Wardrik.Agent.ask(key, text)
      end

  `authorize/3` answers `{:error, :not_found}` for an agent no grant reaches,
  which the caller is told does not exist, and `{:error, :forbidden}` for one
  a grant reaches without the action.

  ## Reading records

  `get/2` answers what this node read of a record through consensus within
  the last sweep, from `WardrikHTTP.Access.Cache`, and reads it through consensus
  again where it read nothing since. A record this node does not hold at all
  is answered as not there without consensus. `fetch/3` always reads through
  consensus.

  ## Holding

  A process that goes on acting on a record, a socket or a stream, holds it
  with `hold/2`. `revoke/2` deletes the record, refuses it on every node the
  revocation reaches, and ends every process holding it there:

      :ok = WardrikHTTP.Access.hold(store, {:tokens, id})
      # ... and elsewhere, later
      :ok = WardrikHTTP.Access.revoke(store, {:tokens, id})

  A holder is sent the exit signal `{:shutdown, :revoked}`. One that traps
  exits receives it as `{:EXIT, from, {:shutdown, :revoked}}` and ends itself;
  one still holding after the grace is killed.

  Each node also reads the records held on it through consensus every sweep,
  and ends the holders of one that is gone or cannot be read. What a node
  read lasts until a purge finds it a sweep old. So a revocation that never reached a node, or a node
  cut off from its quorum, refuses the record and ends its holders within a
  sweep.

  `holding/3` holds a record while a function runs, for a process that goes
  on after it, as a connection serving one request after another does.

  ## Starting

  It reads the store `:store` names, so a host starts it after Wardrik in its
  own tree, before `WardrikHTTP.Workers`:

      children = [
        {Wardrik.Core, host: host},
        {WardrikHTTP.Access, store: store, grace: 1_000, sweep: 15_000},
        WardrikHTTP.Workers
      ]

  `:grace` is how long the holders of a revoked record have to end
  themselves, and `:sweep` how often held records are read again, in
  milliseconds; those are the defaults.
  """

  require Logger

  alias Wardrik.Grant
  alias WardrikHTTP.Access.Cache
  alias WardrikHTTP.Access.Leases

  # How long a consistent read for get/1 may wait. Shorter than a sweep, so a
  # revocation's refusal outlasts any read begun before it.
  @confirm_timeout 5_000

  @typedoc "A record in `WardrikStore` that grants something: its namespace and key."
  @type ref() :: {WardrikStore.ns(), WardrikStore.key()}

  @doc false
  def child_spec(opts) do
    opts = Keyword.validate!(opts, [:store, grace: 1_000, sweep: :timer.seconds(15)])

    children = [
      Group.child_spec(name: __MODULE__),
      {Task.Supervisor, name: Leases.tasks()},
      Leases.registry_spec(),
      {Leases, opts}
    ]

    %{
      id: __MODULE__,
      start: {Supervisor, :start_link, [children, [strategy: :rest_for_one]]},
      type: :supervisor
    }
  end

  @doc """
  The record under `ref`, as this node read it through consensus within the
  last sweep, or as it reads it now.

  Answers `{:error, :not_found}` for a record revoked, one consensus finds
  gone, and one this node does not hold at all; and `{:error, :unavailable}`
  where it must be read through consensus and the store could not answer.
  """
  @spec get(WardrikStore.t(), ref()) :: {:ok, term()} | {:error, :not_found | :unavailable}
  def get(store, {ns, key} = ref) do
    case Cache.lookup(ref) do
      {:ok, value} ->
        {:ok, value}

      :revoked ->
        {:error, :not_found}

      :miss ->
        if WardrikStore.get(store, ns, key) == nil,
          do: {:error, :not_found},
          else: confirm(store, ref)
    end
  end

  defp confirm(store, ref) do
    case fetch(store, ref, timeout: @confirm_timeout) do
      {:ok, value} ->
        :ok = Cache.put(ref, value)
        {:ok, value}

      {:error, :not_found} = gone ->
        :ok = Cache.revoked(ref)
        gone

      {:error, :unavailable} = unavailable ->
        unavailable
    end
  end

  @doc """
  The record under `ref`, read through consensus.

  Answers `{:error, :not_found}` where nothing is written, and
  `{:error, :unavailable}` where the store could not answer. `:timeout` bounds
  the read, in milliseconds.
  """
  @spec fetch(WardrikStore.t(), ref(), timeout: pos_integer()) ::
          {:ok, term()} | {:error, :not_found | :unavailable}
  def fetch(store, {ns, key}, opts \\ []) do
    case WardrikStore.get(store, ns, key, Keyword.put(opts, :consistent, true)) do
      nil -> {:error, :not_found}
      value -> {:ok, value}
    end
  rescue
    exception in [RuntimeError] ->
      Logger.warning("#{ns}/#{key} could not be read: #{Exception.message(exception)}")
      {:error, :unavailable}
  catch
    :exit, reason ->
      Logger.warning("#{ns}/#{key} could not be read: #{inspect(reason)}")
      {:error, :unavailable}
  end

  @doc """
  Whether `grants` let their holder take `action` on the agent `id`:
  `:ok` where any of them does, `{:error, :forbidden}` where one reaches the
  agent and none allows it, and `{:error, :not_found}` where none reaches it.
  """
  @spec authorize(Grant.t() | [Grant.t()], Grant.action(), Wardrik.AgentID.t()) ::
          :ok | {:error, :not_found | :forbidden}
  def authorize(%Grant{} = grant, action, id), do: authorize([grant], action, id)

  def authorize(grants, action, %Wardrik.AgentID{} = id) when is_list(grants) do
    answers = Enum.map(grants, &Wardrik.Subject.authorize(id, &1, action))

    cond do
      :ok in answers -> :ok
      Enum.any?(answers, &match?({:error, %{type: :forbidden}}, &1)) -> {:error, :forbidden}
      true -> {:error, :not_found}
    end
  end

  @doc """
  Holds `ref` for the calling process until the process exits or the record
  is revoked.

  The record is read with `get/2` once it is held, so a revocation since the
  caller last read it is never missed. Answers what `get/2` did where it is
  gone or cannot be read, and holds nothing. `nil`, a caller whose credential
  keeps no record, holds nothing and answers `:ok`.
  """
  @spec hold(WardrikStore.t(), ref() | nil) :: :ok | {:error, :not_found | :unavailable}
  def hold(_store, nil), do: :ok

  def hold(store, ref) do
    with {:ok, _id} <- register(store, ref), do: :ok
  end

  @doc """
  Holds `ref` while `fun` runs, and answers what it answers, or what `hold/1`
  did where the record could not be held and `fun` did not run. `nil` runs
  `fun` holding nothing.
  """
  @spec holding(WardrikStore.t(), ref() | nil, (-> result)) ::
          result | {:error, :not_found | :unavailable}
        when result: term()
  def holding(_store, nil, fun) when is_function(fun, 0), do: fun.()

  def holding(store, ref, fun) when is_function(fun, 0) do
    with {:ok, id} <- register(store, ref) do
      try do
        fun.()
      after
        Leases.release(ref, id)
      end
    end
  end

  # Held first, then read: a revocation refuses the record before it looks
  # for holders, so it finds this one or this read finds its refusal.
  defp register(store, ref) do
    id = Leases.hold(ref)

    case get(store, ref) do
      {:ok, _value} ->
        {:ok, id}

      {:error, _reason} = error ->
        :ok = Leases.release(ref, id)
        error
    end
  end

  @doc """
  Deletes the record under `ref`, refuses it on every node the revocation
  reaches, and ends every process holding it there.
  """
  @spec revoke(WardrikStore.t(), ref()) :: :ok | {:error, :not_found | :conflict | term()}
  def revoke(store, {ns, key} = ref) do
    case WardrikStore.lookup(store, ns, key) do
      {_value, vsn} ->
        with :ok <- WardrikStore.delete(store, ns, key, if_vsn: vsn) do
          :ok = Cache.revoked(ref)
          Leases.revoked(ref)
        end

      nil ->
        {:error, :not_found}
    end
  end
end
