defmodule WardrikDaemon.Direct do
  @moduledoc """
  Answers a channel's direct messages with the agent its `direct` names in `config.yaml`. It's the
  daemon's `Wardrik.Chat.Direct`.

      channels:
        slack: {type: slack, ..., direct: assistant}

  The agent is the one of that name in the org the channel serves, or the deployment's org for a
  channel every org shares.
  """

  @behaviour Wardrik.Chat.Direct

  alias WardrikDaemon.AgentRecords

  @impl Wardrik.Chat.Direct
  def agent(%Wardrik.Chat.Direct.Request{}, opts) do
    name = Keyword.fetch!(opts, :name)
    store = Keyword.fetch!(opts, :store)
    org = Keyword.fetch!(opts, :org)

    case AgentRecords.fetch_by_name(store, org, name) do
      {:ok, %{id: id}} -> {:ok, id}
      :error -> {:error, "There's no agent #{name} to answer direct messages."}
    end
  end

  @doc """
  Gives each channel's `direct` the store and the org it finds its agent in. `org` is the
  deployment's.
  """
  @spec place(keyword(), Wardrik.Store.t(), String.t()) :: keyword()
  def place(channels, store, org) do
    for {name, {adapter, opts}} <- channels do
      {name,
       {adapter, Keyword.replace_lazy(opts, :direct, &locate(&1, store, serving(opts, org)))}}
    end
  end

  defp locate({__MODULE__, opts}, store, org), do: {__MODULE__, opts ++ [store: store, org: org]}
  defp locate(direct, _store, _org), do: direct

  defp serving(opts, org) do
    case Keyword.fetch!(opts, :owner) do
      "*" -> org
      owner -> owner
    end
  end
end
