defmodule Wardrik.Ledger.Guarded do
  @moduledoc """
  A `Wardrik.Ledger` asked on a call's behalf: one that raises, throws or
  exits, or answers what the protocol does not name, answers an error, so a
  ledger that breaks never takes the turn with it.
  """

  alias Wardrik.Ledger
  alias Wardrik.Ledger.Entry

  @doc """
  Claims the `:call` `opts` name through `ledger`, in `:store`.

  A ledger that cannot say whether a call has run has to stop it: the
  guarantee is only worth the cases it covers, and one that fails open covers
  none.
  """
  @spec claim(Ledger.t(), Ledger.key(), keyword()) :: Ledger.claim()
  def claim(ledger, key, opts) do
    case Ledger.claim(ledger, key, opts) do
      :ok -> :ok
      {:settled, result} -> {:settled, result}
      {:pending, %Entry{} = entry} -> {:pending, entry}
      {:error, reason} -> {:error, reason}
    end
  catch
    kind, reason -> failed(ledger, kind, reason)
  end

  @doc """
  Settles `key` with the `:result` `opts` name through `ledger`. The call has
  already run by now, so a failure here loses the record rather than the
  work, and the entry stays pending until its turn is forgotten.
  """
  @spec settle(Ledger.t(), Ledger.key(), keyword()) :: :ok | {:error, term()}
  def settle(ledger, key, opts) do
    ledger |> Ledger.settle(key, opts) |> settled()
  catch
    kind, reason -> failed(ledger, kind, reason)
  end

  @doc """
  Releases `key` through `ledger`. A failure is answered, not raised: the
  claim stays pending until its turn is forgotten.
  """
  @spec release(Ledger.t(), Ledger.key(), keyword()) :: :ok | {:error, term()}
  def release(ledger, key, opts) do
    Ledger.release(ledger, key, opts)
  catch
    kind, reason -> failed(ledger, kind, reason)
  end

  @doc """
  Forgets the entries of the turn `:trace` through `ledger`. A failure is
  answered, not raised: the entries stay, and nothing reads them again.

  `[:wardrik, :ledger, :forgotten]` is emitted once the ledger has answered, with
  the agent id, the trace id and the answer in its metadata.
  """
  @spec forget(Ledger.t(), Wardrik.Event.Bus.agent_id(), keyword()) :: :ok | {:error, term()}
  def forget(ledger, agent_id, opts) do
    answer = Ledger.forget(ledger, agent_id, opts)

    :telemetry.execute([:wardrik, :ledger, :forgotten], %{}, %{
      agent_id: agent_id,
      trace_id: Keyword.fetch!(opts, :trace),
      answer: answer
    })

    answer
  catch
    kind, reason -> failed(ledger, kind, reason)
  end

  @doc "The entry `ledger` holds for `key`, or `:error` where it holds none or fails."
  @spec fetch(Ledger.t(), Ledger.key(), keyword()) :: {:ok, Entry.t()} | :error
  def fetch(ledger, key, opts) do
    case Ledger.fetch(ledger, key, opts) do
      {:ok, %Entry{} = entry} -> {:ok, entry}
      _other -> :error
    end
  catch
    _kind, _reason -> :error
  end

  # An answer the protocol does not name raises here, and is answered as a
  # ledger that failed.
  defp settled(:ok), do: :ok
  defp settled({:error, reason}), do: {:error, reason}

  defp failed(ledger, kind, reason),
    do: {:error, "Ledger #{inspect(ledger)} failed: #{Exception.format(kind, reason)}"}
end
