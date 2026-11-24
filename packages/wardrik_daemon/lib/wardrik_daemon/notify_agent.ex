defmodule WardrikDaemon.NotifyAgent do
  @options [name: [type: :string, required: true, doc: "The name of the agent it tells."]]

  # The moduledoc lists the options from the schema above.
  # credo:disable-for-next-line Credo.Check.Readability.StrictModuleLayout
  @moduledoc """
  Tells the agent of a name in the notifying agent's org, as `Wardrik.Notify.Agent` does.

      notify:
        targets:
          assistant: {agent: assistant}

  ## Options

  #{NimbleOptions.docs(@options)}
  """

  @behaviour Wardrik.Notify

  alias WardrikDaemon.AgentRecords

  @impl Wardrik.Notify
  def schema, do: @options

  @impl Wardrik.Notify
  def deliver(notice, opts) do
    name = Keyword.fetch!(opts, :name)
    wardrik = Wardrik.Instance.fetch!(opts[:wardrik])
    records = Wardrik.Store.scope(wardrik.store, "wardrik_daemon")

    with {:ok, %{org: org}} <- AgentRecords.fetch(records, notice.agent),
         {:ok, %{id: id}} <- AgentRecords.fetch_by_name(records, org, name) do
      Wardrik.Notify.Agent.deliver(notice, Keyword.put(opts, :agent, id))
    else
      :error -> {:skip, "but there's no agent #{name} in its org"}
    end
  end
end
