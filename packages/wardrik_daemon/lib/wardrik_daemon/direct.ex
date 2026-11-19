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
  def find_agent(%Wardrik.Chat.Direct.Request{}, opts), do: fetch_agent(opts)

  @doc "Returns the ID of the agent `opts` name, in the org they give."
  @spec fetch_agent(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def fetch_agent(opts) do
    name = Keyword.fetch!(opts, :name)
    store = Keyword.fetch!(opts, :store)
    org = Keyword.fetch!(opts, :org)

    case AgentRecords.fetch_by_name(store, org, name) do
      {:ok, %{id: id}} -> {:ok, id}
      :error -> {:error, "There's no agent #{name} to answer direct messages."}
    end
  end

  @doc """
  Gives each channel's `direct` the daemon and the org it finds its agent in. `org` is the
  deployment's.
  """
  @spec place(keyword(), WardrikDaemon.CreateAgent.daemon(), String.t()) :: keyword()
  def place(channels, daemon, org) do
    for {name, {adapter, opts}} <- channels do
      {name,
       {adapter,
        Keyword.replace_lazy(opts, :direct, &locate(&1, daemon, resolve_owner(opts, org)))}}
    end
  end

  defp locate({module, opts}, daemon, org) when module in [__MODULE__, __MODULE__.Members],
    do: {module, opts ++ [store: daemon.store, wardrik: daemon.wardrik, org: org]}

  defp locate(direct, _daemon, _org), do: direct

  defp resolve_owner(opts, org) do
    case Keyword.fetch!(opts, :owner) do
      "*" -> org
      owner -> owner
    end
  end
end
