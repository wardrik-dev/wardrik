defmodule WardrikTriggers do
  @moduledoc """
  Asks agents something on a clock, when a feed has new entries, or when a service sends a
  webhook.

      children = [
        {WardrikTriggers, name: MyApp.Triggers, store: store, target: {MyApp.Agents, []}}
      ]

      :ok =
        WardrikTriggers.put(MyApp.Triggers, "acme/digest", [
          %{"name" => "daily", "every" => "0 9 * * *", "prompt" => "Write today's update."}
        ])

  Each run happens once in the cluster, on the node that claims it first. It asks the agent
  through the `WardrikTriggers.Target` given as `:target`.
  """

  use Supervisor

  alias WardrikTriggers.Records
  alias WardrikTriggers.Run
  alias WardrikTriggers.Scheduler
  alias WardrikTriggers.Trigger

  @doc """
  Starts the triggers.

      WardrikTriggers.start_link(name: MyApp.Triggers, store: store, target: {MyApp.Triggered, []})

  ## Options

    * `:name` - required. What you pass to every other function.
    * `:store` - required. The `WardrikStore` triggers are kept in.
    * `:target` - required. A `WardrikTriggers.Target`, as `{module, config}`.
    * `:req_options` - `Req` options for reading feeds. `[]` unless set.
    * `:reconcile` - milliseconds between each node reading every trigger again, or `:infinity`.
      `60_000` unless set.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    opts =
      Keyword.validate!(opts, [
        :name,
        :store,
        :target,
        req_options: [],
        reconcile: :timer.minutes(1)
      ])

    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, Map.new(opts), name: name)
  end

  @doc """
  Replaces the triggers of `agent_id` with those `fields` describe.

  A trigger whose `every` and `timezone` are unchanged keeps its next run. Returns
  `{:error, message}` if any trigger is invalid, and changes nothing. See `WardrikTriggers.Trigger`
  for the keys.

      :ok =
        WardrikTriggers.put(MyApp.Triggers, "acme/digest", [
          %{"name" => "daily", "every" => "0 9 * * *", "prompt" => "Write today's update."}
        ])

  Each trigger is its own write. It sets the new triggers first, then removes the others. If a
  write fails, it stops there and returns `{:error, reason}`: the triggers written before it are
  changed, the rest are as they were. Call `put/3` again with the same `fields` to finish.
  """
  @spec put(atom(), String.t(), [map()]) :: :ok | {:error, String.t() | term()}
  def put(triggers, agent_id, fields) do
    with {:ok, decoded} <- decode_all(fields),
         :ok <- set_all(triggers, agent_id, decoded),
         do: remove_others(triggers, agent_id, Enum.map(decoded, & &1.name))
  end

  @doc """
  Adds or replaces one trigger of `agent_id`, by its name.

  Returns `{:error, message}` if the trigger is invalid, or `{:error, reason}` if the store fails.
  """
  @spec set(atom(), String.t(), map()) :: {:ok, Trigger.t()} | {:error, String.t() | term()}
  def set(triggers, agent_id, fields) do
    with {:ok, trigger} <- Trigger.decode(fields),
         do: GenServer.call(scheduler(triggers), {:set, agent_id, trigger})
  end

  @doc """
  Removes the trigger `:name` of `:agent_id`. Returns `{:error, :not_found}` if it has none, or
  `{:error, reason}` if the store fails.

      :ok = WardrikTriggers.remove(MyApp.Triggers, agent_id: "acme/digest", name: "daily")
  """
  @spec remove(atom(), agent_id: String.t(), name: String.t()) ::
          :ok | {:error, :not_found | term()}
  def remove(triggers, args) do
    agent_id = Keyword.fetch!(args, :agent_id)
    name = Keyword.fetch!(args, :name)
    GenServer.call(scheduler(triggers), {:remove, agent_id, name})
  end

  @doc "Returns the triggers of `agent_id`, each with its next run. A webhook's next run is `nil`."
  @spec list(atom(), String.t()) :: [{Trigger.t(), DateTime.t() | nil}]
  def list(triggers, agent_id) do
    store = settings(triggers).store

    for name <- Records.of(store, agent_id),
        {record, _vsn} <- [Records.lookup(store, agent_id: agent_id, name: name)],
        do: {Records.trigger(record), Records.next_at(record)}
  end

  @doc """
  Asks `:agent_id` about the `:request` sent to its webhook trigger `:name`.

      WardrikTriggers.deliver(MyApp.Triggers,
        agent_id: "acme/digest",
        name: "issues",
        request: %{body: body, headers: headers}
      )

  The request must verify against the trigger's secret. See `WardrikTriggers.Webhook`. A request
  already asked about returns `:ok` and asks nothing.

  Returns `{:error, :not_found}` if the trigger doesn't exist, isn't a webhook, or the request
  fails to verify. Otherwise returns `{:error, status}` when the agent wasn't asked.
  """
  @spec deliver(atom(),
          agent_id: String.t(),
          name: String.t(),
          request: WardrikTriggers.Webhook.request()
        ) :: :ok | {:error, :not_found | :busy | :no_agent | :failed}
  def deliver(triggers, args), do: Run.webhook(settings(triggers), args)

  @doc "Reads every trigger from the store again. Each node does this every `:reconcile` milliseconds."
  @spec reconcile(atom()) :: :ok
  def reconcile(triggers), do: GenServer.call(scheduler(triggers), :reconcile)

  @impl Supervisor
  def init(opts) do
    settings = %{
      store: WardrikStore.scope(opts.store, "wardrik_triggers"),
      target: opts.target,
      req_options: opts.req_options,
      reconcile: opts.reconcile,
      tasks: Module.concat(opts.name, "Tasks"),
      scheduler: scheduler(opts.name)
    }

    :ets.new(table(opts.name), [:named_table, :protected, read_concurrency: true])
    true = :ets.insert(table(opts.name), {:settings, settings})

    children = [{Task.Supervisor, name: settings.tasks}, {Scheduler, settings}]
    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp scheduler(triggers), do: Module.concat(triggers, "Scheduler")
  defp table(triggers), do: Module.concat(triggers, "Settings")

  defp settings(triggers) do
    [{:settings, settings}] = :ets.lookup(table(triggers), :settings)
    settings
  rescue
    ArgumentError ->
      reraise ArgumentError,
              "#{inspect(triggers)} isn't started. Add {WardrikTriggers, name: #{inspect(triggers)}, store: store, target: target} to your supervision tree, ahead of what uses it.",
              __STACKTRACE__
  end

  defp decode_all(fields) do
    fields
    |> Enum.with_index(1)
    |> Enum.map(fn {trigger, index} -> Trigger.decode(trigger, index) end)
    |> Enum.reduce({:ok, []}, &collected/2)
    |> reversed()
  end

  defp collected({:ok, trigger}, {:ok, triggers}), do: {:ok, [trigger | triggers]}
  defp collected({:error, why}, {:ok, _triggers}), do: {:error, why}
  defp collected(_result, error), do: error

  defp reversed({:ok, triggers}), do: {:ok, Enum.reverse(triggers)}
  defp reversed(error), do: error

  defp set_all(triggers, agent_id, decoded) do
    Enum.reduce_while(decoded, :ok, fn trigger, :ok ->
      case GenServer.call(scheduler(triggers), {:set, agent_id, trigger}) do
        {:ok, _trigger} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp remove_others(triggers, agent_id, keeping) do
    store = settings(triggers).store

    Records.of(store, agent_id)
    |> Enum.reject(&(&1 in keeping))
    |> Enum.reduce_while(:ok, fn name, :ok ->
      case remove(triggers, agent_id: agent_id, name: name) do
        {:error, reason} when reason != :not_found -> {:halt, {:error, reason}}
        _removed -> {:cont, :ok}
      end
    end)
  end
end
