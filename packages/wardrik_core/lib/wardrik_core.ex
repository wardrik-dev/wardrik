defmodule WardrikCore do
  @moduledoc """
  A durable agent runtime. Agents survive a crash, wait for a person, and run every call through
  your code.

  Application integration fragment. Start the required processes before calling these functions.
  See the [package README](https://github.com/wardrik-dev/wardrik/tree/main/packages/wardrik_core#readme) for complete setup.

      children = [
        {WardrikCore.Backends.MemoryStore, name: :agents},
        {WardrikCore, backend: {WardrikCore.Backends.MemoryStore, name: :agents}}
      ]

      Supervisor.start_link(children, strategy: :rest_for_one)

      {:ok, agent} =
        WardrikCore.start_agent(agent_id: "triage", model: "anthropic:claude-haiku-4-5")

      :ok = WardrikCore.ask(agent, "What's on fire?")
      WardrikCore.history(agent)

    * An agent runs one turn at a time. Tools come from `WardrikCore.Capability` modules.
    * Every model call and tool call runs through `WardrikCore.Middleware`.
    * To run more than one instance, give each child a `:name`, and pass it as `instance`.

  See the [Run agents](running-agents.html) guide.
  """

  alias WardrikCore.Agent.State
  alias WardrikCore.Context
  alias WardrikCore.Turn

  @typedoc "An agent's id and its conversation's, `nil` for the agent's own history."
  @type key() :: {String.t(), String.t() | nil}

  @typedoc "An agent's id, for its own history, or a `t:key/0` for one of its conversations."
  @type agent() :: String.t() | key()

  @typedoc "A model's price in US dollars per million tokens."
  @type price() :: [
          input: number(),
          output: number(),
          cache_read: number(),
          cache_write: number()
        ]

  @doc """
  Runs agents under your supervision tree.

      {WardrikCore, backend: {WardrikCore.Backends.MemoryStore, name: :agents}}

  ## Options

    * `:backend` - required. The durable_server backend agents are saved in.
    * `:name` - the instance's name. `WardrikCore` by default.

  Other options go to `DurableServer.Supervisor`.
  """
  def child_spec(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    spec =
      [prefix: "wardrik/"]
      |> Keyword.merge(opts)
      |> Keyword.merge(name: agents(name), backend: Keyword.fetch!(opts, :backend))
      |> DurableServer.Supervisor.child_spec()

    %{spec | id: name, start: {__MODULE__, :start_loaded, [spec.start]}}
  end

  @doc false
  def start_loaded({module, function, args}) do
    :ok = load_kept()
    apply(module, function, args)
  end

  @kept [:wardrik_core, :req_llm]

  defp load_kept do
    for {app, _description, _vsn} <- Application.loaded_applications(),
        kept?(app),
        do: app |> Application.spec(:modules) |> Code.ensure_all_loaded()

    :ok
  end

  defp kept?(app),
    do: app in @kept or :wardrik_core in (Application.spec(app, :applications) || [])

  @config [
    :instructions,
    :capabilities,
    :middleware,
    :timeout,
    :max_rounds,
    :retries,
    :model_options,
    :principal,
    :credentials,
    :keys,
    :events,
    :metadata,
    :prices
  ]

  @doc """
  Starts an agent, or loads it if it was saved before.

      {:ok, agent} =
        WardrikCore.start_agent(
          agent_id: "support",
          model: "anthropic:claude-haiku-4-5",
          instructions: "Answer customers' questions about their orders.",
          capabilities: [{MyApp.Orders, []}]
        )

  ## Options

    * `:agent_id` - required. Your ID for the agent.
    * `:model` - required. A model spec, as `"anthropic:claude-haiku-4-5"`.
    * `:conversation` - your ID for one of the agent's conversations, with its own history.
      `nil`, the main history, by default.
    * `:instructions` - the system prompt. Never kept in the history.
    * `:capabilities` - modules that give the agent its tools. See `WardrikCore.Capability`.
    * `:middleware` - wraps every step. See `WardrikCore.Middleware`.
    * `:principal` - who the agent acts as. See `WardrikCore.Principal`.
    * `:credentials` - where tools find a person's tokens. See `WardrikCore.Credentials`.
    * `:keys` - where code finds API keys. See `WardrikCore.Keys`.
    * `:events` - where events go. See `WardrikCore.Events`.
    * `:metadata` - your own data, passed to middleware. `%{}` by default.
    * `:timeout` - how long a turn may take, in milliseconds. `:infinity` by default.
    * `:max_rounds` - model calls per turn, or `:infinity`. `25` by default.
    * `:retries` - see `WardrikCore.Retry`.
    * `:model_options` - options for every model call, as `ReqLLM` takes them, such as
      `temperature: 0.2` or `finch_name: MyApp.Finch`. They merge over the defaults. Agents run
      unattended and a model may think for minutes, so a call waits up to five minutes for an
      answer, and as long on a stream gone quiet: `receive_timeout: 300_000` and
      `stream_idle_timeout: 300_000` unless set. A turn's `:timeout` bounds the whole.
    * `:prices` - US dollars per million tokens, by model spec, over the model catalog's.
      `%{}` by default.

          prices: %{"zai_coding_plan:glm-5.1" => [input: 1.54, output: 4.84]}
  """
  @spec start_agent(atom(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_agent(instance \\ __MODULE__, opts) do
    opts =
      opts
      |> Keyword.validate!([:agent_id, :model, :conversation | @config])
      |> Keyword.replace_lazy(:prices, &State.canonical_prices!/1)

    ids = [agent_id: Keyword.fetch!(opts, :agent_id), conversation: opts[:conversation]]
    context = Context.new(ids ++ Keyword.take(opts, @config))
    state = State.new(ids ++ [model: Keyword.fetch!(opts, :model), context: context])

    child =
      {WardrikCore.Agent,
       key: durable({ids[:agent_id], ids[:conversation]}), initial_state: state}

    case DurableServer.Supervisor.start_child(agents(instance), child) do
      {:ok, {pid, _meta}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Changes an agent's model or settings, from its next turn.

  Takes `:model` and the options of `start_agent/2`, except `:agent_id` and `:conversation`.
  """
  @spec configure(GenServer.server(), keyword()) :: :ok
  def configure(agent, opts) do
    opts =
      opts
      |> Keyword.validate!([:model | @config])
      |> Keyword.replace_lazy(:model, &State.canonical_spec!/1)
      |> Keyword.replace_lazy(:prices, &State.canonical_prices!/1)

    GenServer.call(agent, {:configure, opts})
  end

  @doc "Returns the key of every saved agent."
  @spec list(atom()) :: [key()]
  def list(instance \\ __MODULE__) do
    instance
    |> agents()
    |> saved_keys()
    |> Enum.flat_map(&key/1)
  end

  @doc """
  Returns the running agent, or `nil`.

      WardrikCore.whereis("support")
      WardrikCore.whereis({"support", "C1"})
  """
  @spec whereis(atom(), agent()) :: pid() | nil
  def whereis(instance \\ __MODULE__, agent) do
    case DurableServer.Supervisor.lookup(agents(instance), durable(agent)) do
      {pid, _meta} -> pid
      nil -> nil
    end
  end

  @doc """
  Queues a message. Returns once it's stored. A running turn ends at its next step.

      :ok = WardrikCore.ask(agent, "Open an issue for the login bug.", %{principal: maria})

  ## Metadata

    * `:principal` - the `WardrikCore.Principal` who asked. The turn acts for them.
    * `:id` - the message's ID. Generated by default.
    * `:sent_at` - when it was sent, as a `DateTime`. Now by default. The model sees it after the
      text, as `(Sent Thursday 2026-11-12 23:40 UTC.)`, so it knows the date.
  """
  @spec ask(GenServer.server(), String.t(), map()) :: :ok
  def ask(agent, text, metadata \\ %{}) when is_binary(text) and is_map(metadata),
    do: GenServer.call(agent, {:ask, text, metadata})

  @doc "Returns the agent's conversation."
  @spec history(GenServer.server()) :: [ReqLLM.Message.t()]
  def history(agent), do: GenServer.call(agent, :history)

  @doc """
  Returns the context the agent's next turn starts from, with its conversation as `messages`.

      context = WardrikCore.context(agent)
      summarizing = %{context | instructions: "Summarise this conversation.", tools: []}
      {:ok, summarized} = WardrikCore.Context.run(summarizing, {:step, "summary"}, &WardrikCore.generate/1)

  Steps run through it pass the agent's middleware, and leave its conversation as it was.
  """
  @spec context(GenServer.server()) :: Context.t()
  def context(agent), do: GenServer.call(agent, :context)

  @doc """
  Returns what the agent is doing: `:idle`, `:running`, `:waiting` on `resume/3`, or `:due` to
  run a turn.
  """
  @spec status(GenServer.server()) :: :idle | :running | :waiting | :due
  def status(agent), do: GenServer.call(agent, :status)

  @doc "Stops the agent. It stays saved, and runs again when started."
  @spec stop(GenServer.server()) :: :ok
  def stop(agent), do: GenServer.call(agent, :stop)

  @doc "Returns the names of the cluster nodes agents run on, sorted."
  @spec nodes(atom()) :: [String.t()]
  def nodes(instance \\ __MODULE__) do
    instance
    |> agents()
    |> DurableServer.Supervisor.get_cluster_nodes()
    |> Map.keys()
    |> Enum.sort()
  end

  @doc "Returns each saved agent's key mapped to the node running it, or `nil` if it isn't running."
  @spec placements(atom()) :: %{key() => String.t() | nil}
  def placements(instance \\ __MODULE__) do
    instance
    |> agents()
    |> DurableServer.Supervisor.stream_all_server_info()
    |> Enum.flat_map(fn info -> Enum.map(key(info.key), &{&1, placed(info)}) end)
    |> Map.new()
  end

  @doc """
  Returns the process of each running agent, by key. It covers every node in the cluster.

      WardrikCore.running()
      #=> %{{"support", nil} => #PID<0.312.0>, {"support", "C1"} => #PID<12345.401.0>}
  """
  @spec running(atom()) :: %{key() => pid()}
  def running(instance \\ __MODULE__) do
    instance
    |> agents()
    |> DurableServer.Supervisor.global_members()
    |> Enum.flat_map(fn {durable, {pid, _meta}} -> Enum.map(key(durable), &{&1, pid}) end)
    |> Map.new()
  end

  @doc """
  Restarts the agent on the node `:to`, ending its turn.

      WardrikCore.move("triage", to: "wardrik@10.0.0.2")

  Returns `{:error, :no_such_node}` or `{:error, :not_found}`.
  """
  @spec move(atom(), agent(), to: String.t()) :: {:ok, pid()} | {:error, term()}
  def move(instance \\ __MODULE__, agent, args) do
    with {:ok, target} <- node(Keyword.fetch!(args, :to), nodes(instance)),
         :ok <- saved(instance, keyed(agent)) do
      child = {WardrikCore.Agent, key: durable(agent), initial_state: %{}}

      case DurableServer.Supervisor.rehome_child(agents(instance), child, target_node: target) do
        {:ok, {pid, _meta}} -> {:ok, pid}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Stops the agent and deletes its saved state. Returns `:ok` if there's no such agent."
  @spec delete(atom(), agent()) :: :ok | {:error, term()}
  def delete(instance \\ __MODULE__, agent) do
    case DurableServer.Supervisor.terminate_and_delete_child(agents(instance), durable(agent)) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Stops the running tool call `call_id`. The model gets an error, and the turn goes on."
  @spec kill(GenServer.server(), String.t()) :: :ok | {:error, :not_running}
  def kill(agent, call_id) when is_binary(call_id), do: GenServer.call(agent, {:kill, call_id})

  @doc "Stops the running or parked turn. Returns `{:error, :idle}` if there's none."
  @spec interrupt(GenServer.server()) :: :ok | {:error, :idle}
  def interrupt(agent), do: GenServer.call(agent, :interrupt)

  @doc """
  Returns what the agent waits on, or `nil`.

  Parked tool calls return `{:tool_calls, [{call, outcome}]}`.
  """
  @spec parked(GenServer.server()) :: term() | nil
  def parked(agent), do: GenServer.call(agent, :parked)

  @doc """
  Resumes a parked turn, passing `input` to whatever parked it.

      WardrikCore.resume(agent, %{"call_1" => :approve}, %{by: maria})

    * Answer parked tool calls by ID, one at a time or together.
    * `metadata` is yours. It appears on the turn's `[:wardrik_core, :turn, :start]` event.
    * Returns `{:error, :not_parked}` if the agent isn't waiting.
  """
  @spec resume(GenServer.server(), term(), map()) :: :ok | {:error, :not_parked}
  def resume(agent, input, metadata \\ %{}) when is_map(metadata),
    do: GenServer.call(agent, {:resume, input, metadata})

  @doc """
  Asks an evaluation `:model` the `:questions` about `:state`, from inside a turn.

      questions = %{"urgent" => %{type: :boolean, instructions: "Is this urgent?"}}

      {:ok, %{"urgent" => %{"probability" => p}}, measurements} =
        WardrikCore.evaluate(context,
          model: "typesafe:jev-latest",
          state: "The site is down.",
          questions: questions
        )

      context = WardrikCore.Context.measure(context, measurements)

  Returns each answer by question name, and what the call used.
  """
  @spec evaluate(Context.t(),
          model: String.t(),
          state: String.t() | map(),
          questions: map()
        ) :: {:ok, map(), %{atom() => number()}} | {:error, term()}
  def evaluate(%Context{} = context, args) do
    model = Keyword.fetch!(args, :model)

    with {:ok, response} <-
           ReqLLM.evaluate(
             model,
             Keyword.fetch!(args, :state),
             Keyword.fetch!(args, :questions),
             Context.model_options(context, model)
           ) do
      {:ok, response.object, WardrikCore.Usage.measurements(response, model, context.prices)}
    end
  end

  @doc """
  Calls the context's model once, from inside a turn, through the middleware.

      summarizing = %{context | instructions: "Summarise this conversation.", tools: []}
      {:ok, summarized} = WardrikCore.generate(summarizing)
      ReqLLM.Response.text(summarized.response)
      #=> "The user asked about..."

  Returns the context with `response` set and the reply added to `messages`. Streams nothing.
  """
  @spec generate(Context.t()) :: WardrikCore.Middleware.result()
  def generate(%Context{} = context), do: Turn.call_model(context)

  @doc """
  Runs `prompt` as one turn of a subagent, from inside a tool or middleware.

      {:ok, %{text: text, labels: labels}, measurements} =
        WardrikCore.subagent(context, "Find this week's releases.", name: "researcher")

    * Uses the caller's model, middleware and tools.
    * Returns `{:error, reason, measurements}` if it fails. Pass the measurements to
      `WardrikCore.Context.measure/2`.
    * It can't wait for a person. A call that would park fails it.
    * It emits `[:wardrik_core, :subagent, _]` events in place of its own steps'. See
      `WardrikCore.Telemetry`.

  ## Options

    * `:name` - `"subagent"` by default. Set as the context's `subagent` while it runs.
    * `:instructions`, `:capabilities`, `:max_rounds` - replace the caller's.
    * `:except_tools` - tool names to leave out. `[]` by default.
    * `:timeout` - milliseconds before it fails with `:timeout`. `:infinity` by default.
  """
  @spec subagent(Context.t(), String.t(), keyword()) ::
          {:ok, %{text: String.t(), labels: [String.t()]}, map()} | {:error, term(), map()}
  def subagent(%Context{} = context, prompt, opts \\ []),
    do: WardrikCore.Subagent.run(context, prompt, opts)

  @doc """
  Returns `model`'s price from the model catalog, in US dollars per million tokens, or `nil`.

      WardrikCore.price("anthropic:claude-haiku-4-5")
      #=> [input: 1.0, output: 5.0, cache_read: 0.1, cache_write: 1.25]
  """
  @spec price(LLMDB.Model.t() | String.t()) :: price() | nil
  def price(model), do: WardrikCore.Usage.price(model)

  @doc "Returns `model`'s context window in tokens, from the model catalog, or `nil`."
  @spec context_window(LLMDB.Model.t() | String.t()) :: pos_integer() | nil
  def context_window(model) do
    case ReqLLM.model(model) do
      {:ok, %LLMDB.Model{limits: %{context: window}}} when is_integer(window) -> window
      _unknown -> nil
    end
  end

  defp placed(%{running: true, node: node}), do: to_string(node)
  defp placed(_info), do: nil

  defp node(node, nodes) do
    if node in nodes,
      do: {:ok, String.to_existing_atom(node)},
      else: {:error, :no_such_node}
  end

  defp saved(instance, key) do
    if key in list(instance), do: :ok, else: {:error, :not_found}
  end

  defp keyed(agent_id) when is_binary(agent_id), do: {agent_id, nil}
  defp keyed({_agent_id, _conversation} = key), do: key

  @doc """
  Returns the key the agent's state is saved under in the instance's backend.

      WardrikCore.saved_key({"acme.drafts", nil})
      #=> "wardrik/agents/acme.drafts"
  """
  @spec saved_key(atom(), String.t() | {String.t(), String.t() | nil}) :: String.t()
  def saved_key(instance \\ __MODULE__, agent) do
    %{prefix: prefix} = DurableServer.Supervisor.__get_config__(agents(instance))
    prefix <> durable(agent)
  end

  # DurableServer keys are binaries: each id is encoded on its own, so no id is ever split.
  defp durable(agent) do
    {agent_id, conversation} = keyed(agent)
    ids = Enum.reject([agent_id, conversation], &is_nil/1)
    Enum.map_join(["agents" | Enum.map(ids, &URI.encode_www_form/1)], "/", & &1)
  end

  # DurableServer's public listing reads every server's state, one read per key. Its backend
  # lists keys alone, so read that listing until DurableServer offers one.
  defp saved_keys(supervisor) do
    %{storage_backend: backend, prefix: prefix} =
      DurableServer.Supervisor.__get_config__(supervisor)

    backend
    |> DurableServer.StorageBackend.list_all_objects_stream(prefix,
      error_handler: fn _reason -> :halt end
    )
    |> Stream.map(fn %{key: key} -> String.replace_prefix(key, prefix, "") end)
  end

  defp key("agents/" <> encoded) do
    case encoded |> String.split("/") |> Enum.map(&URI.decode_www_form/1) do
      [agent_id] -> [{agent_id, nil}]
      [agent_id, conversation] -> [{agent_id, conversation}]
    end
  end

  defp key(_other), do: []

  defp agents(instance), do: Module.concat(instance, Agents)
end
