defmodule Wardrik.Delegation do
  @moduledoc """
  Sends an agent's answer back to the agent that asked it with `agent_ask`.

      From agent agt_reconciler:
      In answer to your message msg_x1:
      Two deposits match no invoice: …

    * The answer arrives as a new message once the run completes, fails or is cancelled.
    * It's sent for the answering agent's principal, with actor `{:agent, id}`.
    * It carries the answering conversation's labels.
    * Questions are kept in the store, so answers survive a restart.
  """

  use GenServer

  alias Wardrik.Operations.Running
  alias WardrikCore.Context
  alias WardrikCore.Principal

  require Logger

  @doc "Starts delegation."
  @spec start_link(Wardrik.t()) :: GenServer.on_start()
  def start_link(wardrik),
    do: GenServer.start_link(__MODULE__, wardrik, name: Module.concat(wardrik.name, Delegation))

  @doc """
  Records that `:asker`, as `{agent, conversation}`, sent `:agent` the `:message`.

      :ok =
        Wardrik.Delegation.asked(MyApp.AgentRuntime,
          asker: {"agt_ops", nil},
          agent: "agt_reconciler",
          message: "msg_x1"
        )
  """
  @spec asked(atom() | Wardrik.t(),
          asker: Running.key(),
          agent: String.t(),
          message: String.t()
        ) :: :ok
  def asked(instance, args) do
    {agent, conversation} = Keyword.fetch!(args, :asker)
    log = {Keyword.fetch!(args, :agent), nil}
    asker = %{"agent" => agent, "conversation" => conversation}
    wardrik = Wardrik.Instance.fetch!(instance)
    key = key("asked", log, Keyword.fetch!(args, :message))
    store = store(wardrik)
    {:ok, _vsn} = Wardrik.Store.put(store, key, asker)
    :ok
  end

  @impl GenServer
  def init(wardrik), do: {:ok, wardrik, {:continue, :subscribe}}

  @impl GenServer
  def handle_continue(:subscribe, wardrik) do
    events = Wardrik.events(wardrik)
    :ok = Wardrik.EventLog.subscribe(events, :all)

    wardrik
    |> pending()
    |> Enum.each(&caught_up(wardrik, &1))

    {:noreply, wardrik}
  end

  @impl GenServer
  def handle_info({Wardrik.EventLog, log, event}, wardrik) do
    seen(wardrik, log, event)
    {:noreply, wardrik}
  end

  defp seen(wardrik, log, %{"type" => "wardrik.run.started", "data" => %{"run" => run}}) do
    run
    |> Map.get("message_ids", [])
    |> Enum.each(&taken(wardrik, log, run["id"], &1))
  end

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
        key <- Wardrik.Store.keys(store, prefix),
        uniq: true,
        do: logged(String.replace_prefix(key, prefix, ""))
  end

  # Each key holds the log's agent and conversation, and the ID, each URL-encoded on its own.
  defp key(kind, {agent, conversation}, id) do
    [agent, conversation, id]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join("/", &URI.encode_www_form/1)
    |> then(&"delegation/#{kind}/#{&1}")
  end

  defp logged(key) do
    segments =
      key
      |> String.split("/")
      |> Enum.map(&URI.decode_www_form/1)

    case segments do
      [agent, _id] -> {agent, nil}
      [agent, conversation, _id] -> {agent, conversation}
    end
  end

  defp caught_up(wardrik, log, cursor \\ nil) do
    {:ok, %{events: events, next: next}} =
      wardrik
      |> Wardrik.events()
      |> Wardrik.EventLog.page([log], after: cursor, limit: 500)

    Enum.each(events, &seen(wardrik, log, &1))
    if events != [], do: caught_up(wardrik, log, next)
  end

  defp taken(wardrik, log, run, id) do
    store = store(wardrik)

    with %{} = asker <- Wardrik.Store.get(store, key("asked", log, id)) do
      {:ok, _vsn} =
        Wardrik.Store.put(store, key("runs", log, run), %{"asker" => asker, "message" => id})

      :ok = Wardrik.Store.delete(store, key("asked", log, id))
    end
  end

  defp answered(wardrik, log, run, said) do
    store = store(wardrik)
    key = key("runs", log, run)

    with %{"asker" => asker, "message" => id} <- Wardrik.Store.get(store, key) do
      {from, _conversation} = log
      text = "From agent #{from}:\nIn answer to your message #{id}:\n#{said}"

      with {:ok, scope} <- scope(wardrik, log, from) do
        input = %{"content" => text, "id" => "answer_" <> id}

        Wardrik.run(
          scope,
          "agent.ask",
          Map.merge(input, Map.reject(asker, &(elem(&1, 1) == nil)))
        )
      end

      :ok = Wardrik.Store.delete(store, key)
    end
  end

  defp scope(wardrik, log, from) do
    case Wardrik.Resolver.defined(wardrik, from) do
      {:ok, %Wardrik.Resolved{principal: %Principal{} = principal}} ->
        scope = Wardrik.as(wardrik.name, principal, actor: {:agent, from})
        {:ok, %{scope | labels: labels(wardrik, log)}}

      _none ->
        Logger.warning("#{from} acts for no one, so its answer isn't sent.")
        :error
    end
  end

  defp labels(wardrik, log) do
    case Running.whereis(wardrik, log) do
      nil ->
        ["outside"]

      pid ->
        pid
        |> WardrikCore.history()
        |> Context.labels()
    end
  end

  defp store(%Wardrik{store: store}), do: Wardrik.Store.scope(store, "wardrik")
end
