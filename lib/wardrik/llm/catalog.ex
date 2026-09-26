defmodule Wardrik.LLM.Catalog do
  @moduledoc """
  Loads the `llm_db` model catalog as the application starts.

  `LLMDB.load/0` prepares the packaged snapshot with the configured filters
  and custom data and stores it for every lookup after. The load runs in a
  task started first in the supervision tree, so nothing waits on it; a lookup
  made before it finishes takes `llm_db`'s load lock and gets the catalog when
  it is ready. A load that fails is logged and left to the first lookup.
  """

  require Logger

  @doc "A child that loads the catalog once and exits."
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg) do
    Supervisor.child_spec({Task, &preload/0}, id: __MODULE__)
  end

  @doc "Loads the catalog, logging a failure."
  @spec preload() :: :ok
  def preload do
    case LLMDB.load() do
      {:ok, _snapshot} -> :ok
      {:error, reason} -> Logger.warning("the model catalog did not load: #{inspect(reason)}")
    end

    :ok
  end
end
