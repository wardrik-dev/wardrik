defmodule WardrikTriggers do
  @moduledoc """
  Asks agents something on a clock, when a feed has new entries, or when a service sends a
  webhook.

  Application integration fragment. Start the required processes before calling these functions.
  See the [package README](https://github.com/wardrik-dev/wardrik/tree/main/packages/wardrik_triggers#readme) for complete setup.

      children = [
        {WardrikTriggers, name: MyApp.Triggers, store: store, target: {MyApp.Triggered, []}}
      ]

      :ok =
        WardrikTriggers.put(MyApp.Triggers, "agt_digest", [
          %{"name" => "daily", "every" => "0 9 * * *", "prompt" => "Write today's update."}
        ])

    * Triggers are kept in a `WardrikStore`. Each run happens once in the cluster.
    * Agents are asked through the `WardrikTriggers.Target` given as `:target`.
    * Trigger keys are in `WardrikTriggers.Trigger`.
  """

  use Supervisor

  alias WardrikTriggers.Records
  alias WardrikTriggers.Run
  alias WardrikTriggers.Scheduler
  alias WardrikTriggers.Trigger

  @start_options NimbleOptions.new!(
                   name: [
                     type: :atom,
                     required: true,
                     doc: "The registered trigger supervisor name."
                   ],
                   store: [
                     type: :any,
                     required: true,
                     doc: "The WardrikStore used for trigger records."
                   ],
                   target: [
                     type: :mod_arg,
                     required: true,
                     doc: "The WardrikTriggers.Target callback module and options."
                   ],
                   req_options: [
                     type: :keyword_list,
                     default: [],
                     doc: "Req options for feed requests."
                   ],
                   reconcile: [
                     type: {:or, [:pos_integer, {:in, [:infinity]}]},
                     default: 60_000,
                     doc: "Milliseconds between trigger reconciliation runs."
                   ]
                 )

  @doc """
  Starts the triggers.

  ## Options

  #{NimbleOptions.docs(@start_options)}
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    allowed =
      Enum.map(@start_options.schema, fn {key, settings} ->
        case Keyword.fetch(settings, :default) do
          {:ok, default} -> {key, default}
          :error -> key
        end
      end)

    opts = Keyword.validate!(opts, allowed)

    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, Map.new(opts), name: name)
  end

  @doc """
  Replaces the triggers of `agent_id`.

      :ok =
        WardrikTriggers.put(MyApp.Triggers, "agt_digest", [
          %{"name" => "daily", "every" => "0 9 * * *", "prompt" => "Write today's update."}
        ])

    * A trigger whose `every` and `timezone` are unchanged keeps its next run.
    * An invalid trigger returns `{:error, message}` and changes nothing.
    * A failed store write returns `{:error, reason}` part way. Call `put/3` again to finish.
  """
  @spec put(atom(), String.t(), [map()]) :: :ok | {:error, String.t() | term()}
  def put(triggers, agent_id, fields) do
    with {:ok, decoded} <- decode_all(fields),
         :ok <- set_all(triggers, agent_id, decoded),
         do: remove_others(triggers, agent_id, Enum.map(decoded, & &1.name))
  end

  @doc """
  Adds or replaces one trigger of `agent_id`, by its name.

      {:ok, trigger} =
        WardrikTriggers.set(MyApp.Triggers, "agt_digest", %{
          "every" => "@daily",
          "prompt" => "Hi"
        })
  """
  @spec set(atom(), String.t(), map()) :: {:ok, Trigger.t()} | {:error, String.t() | term()}
  def set(triggers, agent_id, fields) do
    with {:ok, trigger} <- Trigger.decode(fields),
         do: GenServer.call(scheduler(triggers), {:set, agent_id, trigger})
  end

  @doc """
  Removes a trigger. Returns `{:error, :not_found}` if there's none.

      :ok = WardrikTriggers.remove(MyApp.Triggers, agent_id: "agt_digest", name: "daily")
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
    for record <- Records.records(settings(triggers).store, agent_id),
        do: {Records.trigger(record), Records.next_at(record)}
  end

  @doc """
  Returns when each of `agent_ids` next runs on a schedule, in one read. Agents with no
  scheduled trigger are left out.

      WardrikTriggers.next_runs(MyApp.Triggers, ["agt_digest", "agt_triage"])
      #=> %{"agt_digest" => ~U[2026-11-04 09:00:00Z]}
  """
  @spec next_runs(atom(), [String.t()]) :: %{String.t() => DateTime.t()}
  def next_runs(triggers, agent_ids) do
    wanted = MapSet.new(agent_ids)

    for %{"agent_id" => agent_id} = record <- Records.records(settings(triggers).store),
        agent_id in wanted,
        next_at <- [Records.next_at(record)],
        next_at != nil,
        reduce: %{} do
      runs -> Map.update(runs, agent_id, next_at, &Enum.min([&1, next_at], DateTime))
    end
  end

  @doc """
  Asks the agent about a request sent to its webhook trigger.

      WardrikTriggers.deliver(MyApp.Triggers,
        agent_id: "agt_digest",
        name: "issues",
        request: %{body: body, headers: headers}
      )

    * `:ok` - asked, or already asked about this request.
    * `{:error, :not_found}` - no such webhook trigger, or the request fails to verify.
    * `{:error, status}` - the agent wasn't asked, as `:busy`.
  """
  @spec deliver(atom(),
          agent_id: String.t(),
          name: String.t(),
          request: WardrikTriggers.Webhook.request()
        ) :: :ok | {:error, :not_found | :busy | :no_agent | :failed}
  def deliver(triggers, args), do: Run.webhook(settings(triggers), args)

  @doc "Re-reads every trigger from the store now."
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
