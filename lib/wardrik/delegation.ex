defmodule Wardrik.Delegation do
  @moduledoc """
  Delegation brings an agent's answer back to the agent that asked for it with `agent_ask`, as a
  message that starts a turn of its own:

      From agent acme/reconciler:
      In answer to your message msg_x1:
      Two deposits match no invoice: …

  It notes each question in the store, follows the run that takes it up, and asks the asker once
  that run finishes, fails or stops. A run waiting on a person tells nothing yet. As it starts, it
  reads the logs of the agents it waits on, so a run that ended while it was down is answered too.
  An answer is asked under an id of its own, so one delivered twice is taken once. It carries the
  labels of what the answering agent's conversation holds, or `"outside"` where that agent isn't
  running to say.
  """

  use GenServer

  alias Wardrik.AgentID
  alias Wardrik.Operations.Running
  alias WardrikCore.Context
  alias WardrikCore.Principal

  @doc "Starts bringing answers back for `wardrik`."
  @spec start_link(Wardrik.t()) :: GenServer.on_start()
  def start_link(wardrik),
    do: GenServer.start_link(__MODULE__, wardrik, name: Module.concat(wardrik.name, Delegation))

  @doc "Notes that `asker` asked `agent` the message `id`, so the answer comes back to it."
  @spec asked(atom() | Wardrik.t(), String.t(), String.t(), String.t()) :: :ok
  def asked(instance, asker, agent, id) do
    wardrik = Wardrik.Instance.fetch!(instance)
    {:ok, _vsn} = WardrikStore.put(store(wardrik), "delegation/asked/#{agent}/#{id}", asker)
    :ok
  end

  @impl GenServer
  def init(wardrik), do: {:ok, wardrik, {:continue, :subscribe}}

  @impl GenServer
  def handle_continue(:subscribe, wardrik) do
    :ok = WardrikEvents.subscribe(Wardrik.events(wardrik), ["*"])
    Enum.each(pending(wardrik), &caught_up(wardrik, &1))
    {:noreply, wardrik}
  end

  @impl GenServer
  def handle_info({WardrikEvents, log, event}, wardrik) do
    seen(wardrik, log, event)
    {:noreply, wardrik}
  end

  defp seen(wardrik, log, %{"type" => "wardrik.run.started", "data" => %{"run" => run}}),
    do: Enum.each(Map.get(run, "message_ids", []), &taken(wardrik, log, run["id"], &1))

  defp seen(wardrik, log, %{"type" => "wardrik.run.completed", "data" => data}),
    do: answered(wardrik, log, data["run"]["id"], "#{Wardrik.Reply.text(data["messages"])}")

  defp seen(wardrik, log, %{"type" => "wardrik.run.failed", "data" => data}),
    do:
      answered(wardrik, log, data["run"]["id"], "It couldn't answer: #{data["error"]["message"]}")

  defp seen(wardrik, log, %{"type" => "wardrik.run.cancelled", "data" => data}),
    do: answered(wardrik, log, data["run"]["id"], "It stopped before it answered.")

  defp seen(_wardrik, _log, _event), do: :ok

  defp pending(wardrik) do
    store = store(wardrik)

    for prefix <- ["delegation/asked/", "delegation/runs/"],
        key <- WardrikStore.keys(store, prefix),
        uniq: true,
        do: key |> String.replace_prefix(prefix, "") |> logged()
  end

  defp logged(key) do
    [_last | log] = key |> String.split("/") |> Enum.reverse()
    log |> Enum.reverse() |> Enum.join("/")
  end

  defp caught_up(wardrik, log, cursor \\ nil) do
    {:ok, %{events: events, next: next}} =
      WardrikEvents.page(Wardrik.events(wardrik), [log], after: cursor, limit: 500)

    Enum.each(events, &seen(wardrik, log, &1))
    if events != [], do: caught_up(wardrik, log, next)
  end

  defp taken(wardrik, log, run, id) do
    store = store(wardrik)

    with asker when is_binary(asker) <- WardrikStore.get(store, "delegation/asked/#{log}/#{id}") do
      {:ok, _vsn} =
        WardrikStore.put(store, "delegation/runs/#{log}/#{run}", %{
          "asker" => asker,
          "message" => id
        })

      :ok = WardrikStore.delete(store, "delegation/asked/#{log}/#{id}")
    end
  end

  defp answered(wardrik, log, run, said) do
    store = store(wardrik)
    key = "delegation/runs/#{log}/#{run}"

    with %{"asker" => asker, "message" => id} <- WardrikStore.get(store, key) do
      text = "From agent #{AgentID.agent(log)}:\nIn answer to your message #{id}:\n#{said}"

      _asked =
        Wardrik.run(scope(wardrik, log, asker), "agent.ask", %{
          "agent" => asker,
          "content" => text,
          "id" => "answer_" <> id
        })

      :ok = WardrikStore.delete(store, key)
    end
  end

  defp scope(wardrik, log, asker) do
    {:ok, from} = Wardrik.Resource.agent(log)
    {:ok, to} = Wardrik.Resource.agent(asker)
    scope = Wardrik.as(wardrik.name, %Principal{id: from}, roles: [:messenger], resources: [to])
    %{scope | labels: labels(wardrik, log)}
  end

  defp labels(wardrik, log) do
    case Running.whereis(wardrik, log) do
      nil -> ["outside"]
      pid -> pid |> WardrikCore.history() |> Context.labels()
    end
  end

  defp store(%Wardrik{store: store}), do: WardrikStore.scope(store, "wardrik")
end
