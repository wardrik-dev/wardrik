defmodule TarsPolicy.Spend do
  @moduledoc """
  What an agent has spent in one budget period, and what people have granted
  it beyond its limit there, as `Tars.Store` holds them.

  Each agent's period is one entry, under the agent's key and the period's name
  from `TarsPolicy.Budget.window/3`, so it survives a restart and is read the
  same from whichever node holds the agent. Writes to one entry take a lock
  across the connected nodes and are conditional on the version they read, so
  calls settling at once, from delegations running side by side, each count.
  """

  defstruct spent: 0.0, tokens: 0, granted: 0.0, granted_tokens: 0

  @type t() :: %__MODULE__{
          spent: float(),
          tokens: non_neg_integer(),
          granted: float(),
          granted_tokens: non_neg_integer()
        }

  @ns :budgets
  @lock_retries 50

  @doc "The entry for `agent` in `window`: its key in the store."
  @spec key(String.t(), String.t()) :: String.t()
  def key(agent, window), do: agent <> "|" <> window

  @doc "What has been spent and granted under `key`, zero where nothing has."
  @spec read(String.t()) :: t()
  def read(key) do
    case Tars.Store.lookup(@ns, key) do
      {%__MODULE__{} = spend, _vsn} -> spend
      nil -> %__MODULE__{}
    end
  end

  @doc "Adds `usd` and `tokens` to what has been spent under `key`."
  @spec spend(String.t(), float(), non_neg_integer()) :: :ok | {:error, term()}
  def spend(key, usd, tokens),
    do: update(key, &%{&1 | spent: &1.spent + usd, tokens: &1.tokens + tokens})

  @doc "Adds `usd` and `tokens` to what people have granted under `key`."
  @spec grant(String.t(), float(), non_neg_integer()) :: :ok | {:error, term()}
  def grant(key, usd, tokens),
    do:
      update(key, &%{&1 | granted: &1.granted + usd, granted_tokens: &1.granted_tokens + tokens})

  defp update(key, change) do
    lock = {{__MODULE__, key}, self()}

    case :global.trans(lock, fn -> write(key, change) end, [node() | Node.list()], @lock_retries) do
      :aborted -> {:error, :locked}
      result -> result
    end
  end

  defp write(key, change) do
    {current, vsn} =
      case Tars.Store.lookup(@ns, key) do
        {%__MODULE__{} = spend, vsn} -> {spend, vsn}
        nil -> {%__MODULE__{}, nil}
      end

    case Tars.Store.put(@ns, key, change.(current), if_vsn: vsn) do
      {:ok, _vsn} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
