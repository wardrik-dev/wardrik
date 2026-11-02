defmodule WardrikCore do
  @moduledoc """
  A durable agent runtime. Agents survive a crash, wait for a person, and run every call through
  your code.

      children = [
        {WardrikCore.Backends.MemoryStore, name: :agents},
        {WardrikCore, backend: {WardrikCore.Backends.MemoryStore, name: :agents}}
      ]

      Supervisor.start_link(children, strategy: :rest_for_one)

      {:ok, agent} =
        WardrikCore.start_agent(agent_id: "triage", model: "anthropic:claude-haiku-4-5")

      :ok = WardrikCore.ask(agent, "What's on fire?")
      WardrikCore.history(agent)

  `ask/3` returns once the message is stored. Agents in memory, as here, are gone when the node
  stops. An agent that crashes comes back by itself and picks its message back up. With a backend
  that keeps them, such as a disk or an S3 bucket, so does one whose node dies. See
  [Run agents](running-agents.html#where-agents-are-kept) for the backends.

  ## Turns

  An agent runs one turn at a time. A message that arrives mid-turn ends the turn at its next
  step, and the next turn answers it. Tools come from `WardrikCore.Capability` modules. Every
  model call and tool call runs through `WardrikCore.Middleware`.

  ## Instances

  To run more than one instance, give each child a `:name`. Pass that name as the first argument
  to the functions that take an `instance`.
  """

  alias WardrikCore.Agent.State
  alias WardrikCore.Context
  alias WardrikCore.Turn

  @doc """
  Runs agents under your supervision tree.

      {WardrikCore, backend: {WardrikCore.Backends.MemoryStore, name: :agents}}

  Before starting, it loads every module of `wardrik_core`, `req_llm` and each app that depends
  on `wardrik_core`. That way a backend that decodes saved agents with `[:safe]` knows every
  struct they name.

  ## Options

    * `:backend` - required. The durable_server backend agents are saved in.
    * `:name` - the instance's name. `WardrikCore` unless set.

  Any other option is passed to `DurableServer.Supervisor`.
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

    * `:agent_id` - required. The agent's id, unique within the instance.
    * `:model` - required. A model spec, as `"anthropic:claude-haiku-4-5"`.
    * `:instructions` - the system prompt. Sent with every model call, never kept in the history.
    * `:capabilities` - modules that give the agent its tools. See `WardrikCore.Capability`.
    * `:middleware` - wraps every step. See `WardrikCore.Middleware`.
    * `:principal` - who the agent acts as. See `WardrikCore.Principal`.
    * `:credentials` - where tools find a person's credentials. See `WardrikCore.Credentials`.
    * `:keys` - where code finds API keys. See `WardrikCore.Keys`.
    * `:events` - where events go. See `WardrikCore.Events`.
    * `:metadata` - anything of yours, passed to middleware. `%{}` unless set.
    * `:timeout` - how long a turn may take, in milliseconds. `:infinity` unless set.
    * `:max_rounds` - model calls a turn may make, or `:infinity`. `25` unless set.
    * `:retries` - how failed calls are retried. See `WardrikCore.Retry`.
    * `:prices` - model prices in US dollars per million tokens, by spec. Takes precedence over
      the model catalog. `%{}` unless set.

          prices: %{"zai_coding_plan:glm-5.1" => [input: 1.54, output: 4.84]}
  """
  @spec start_agent(atom(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_agent(instance \\ __MODULE__, opts) do
    opts =
      opts
      |> Keyword.validate!([:agent_id, :model | @config])
      |> Keyword.replace_lazy(:prices, &State.canonical_prices!/1)

    agent_id = Keyword.fetch!(opts, :agent_id)
    context = Context.new([agent_id: agent_id] ++ Keyword.take(opts, @config))
    state = State.new(agent_id: agent_id, model: Keyword.fetch!(opts, :model), context: context)
    child = {WardrikCore.Agent, key: agent_id, initial_state: state}

    case DurableServer.Supervisor.start_child(agents(instance), child) do
      {:ok, {pid, _meta}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Changes an agent's model or settings, from its next turn.

  Takes `:model` and the options of `start_agent/2`, except `:agent_id`.
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

  @doc "Returns the id of every saved agent."
  @spec list(atom()) :: [String.t()]
  def list(instance \\ __MODULE__) do
    instance
    |> agents()
    |> DurableServer.Supervisor.stream_all_server_info()
    |> Enum.map(fn info -> info.key end)
  end

  @doc "Returns the running agent for `agent_id`, or `nil`."
  @spec whereis(atom(), String.t()) :: pid() | nil
  def whereis(instance \\ __MODULE__, agent_id) do
    case DurableServer.Supervisor.lookup(agents(instance), agent_id) do
      {pid, _meta} -> pid
      nil -> nil
    end
  end

  @doc """
  Queues a message. Returns once it's stored.

  A running turn ends at its next step, and the next turn answers the message.

      :ok = WardrikCore.ask(agent, "Open an issue for the login bug.", %{principal: maria})

  ## Metadata

    * `:principal` - the `WardrikCore.Principal` who asked. The turn that answers acts for them.
      A turn only answers consecutive messages from one principal.
    * `:id` - the message's id. Generated unless set.
  """
  @spec ask(GenServer.server(), String.t(), map()) :: :ok
  def ask(agent, text, metadata \\ %{}) when is_binary(text) and is_map(metadata),
    do: GenServer.call(agent, {:ask, text, metadata})

  @doc "Returns the agent's conversation."
  @spec history(GenServer.server()) :: [ReqLLM.Message.t()]
  def history(agent), do: GenServer.call(agent, :history)

  @doc """
  Returns what the agent is doing.

    * `:idle` - nothing to do.
    * `:running` - taking a turn.
    * `:waiting` - parked, waiting on `resume/3`.
    * `:due` - a turn is ready to run, such as one lost in a restart.
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

  @doc "Returns each saved agent's id mapped to the node running it, or `nil` if it isn't running."
  @spec placements(atom()) :: %{String.t() => String.t() | nil}
  def placements(instance \\ __MODULE__) do
    instance
    |> agents()
    |> DurableServer.Supervisor.stream_all_server_info()
    |> Map.new(fn info -> {info.key, placed(info)} end)
  end

  @doc """
  Restarts the agent on the node `:to`, with its saved state.

      WardrikCore.move("triage", to: "wardrik@10.0.0.2")

  Ends the turn it's taking, and abandons anything it's waiting on. Returns
  `{:error, :no_such_node}` or `{:error, :not_found}` if the node or the agent doesn't exist.
  """
  @spec move(atom(), String.t(), to: String.t()) :: {:ok, pid()} | {:error, term()}
  def move(instance \\ __MODULE__, agent_id, args) do
    with {:ok, target} <- node(Keyword.fetch!(args, :to), nodes(instance)),
         :ok <- saved(instance, agent_id) do
      child = {WardrikCore.Agent, key: agent_id, initial_state: %{}}

      case DurableServer.Supervisor.rehome_child(agents(instance), child, target_node: target) do
        {:ok, {pid, _meta}} -> {:ok, pid}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Stops the agent and deletes its saved state. Returns `:ok` if there's no such agent."
  @spec delete(atom(), String.t()) :: :ok | {:error, term()}
  def delete(instance \\ __MODULE__, agent_id) do
    case DurableServer.Supervisor.terminate_and_delete_child(agents(instance), agent_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stops the running tool call `call_id`.

  The model gets an error as the call's answer, and the turn goes on.
  """
  @spec kill(GenServer.server(), String.t()) :: :ok | {:error, :not_running}
  def kill(agent, call_id) when is_binary(call_id), do: GenServer.call(agent, {:kill, call_id})

  @doc "Stops the running or parked turn. Returns `{:error, :idle}` if there's none."
  @spec interrupt(GenServer.server()) :: :ok | {:error, :idle}
  def interrupt(agent), do: GenServer.call(agent, :interrupt)

  @doc """
  Returns why the agent is parked, or `nil` if it isn't.

  Parked tool calls return `{:tool_calls, [{call, outcome}]}`. While a resumed turn runs, it's the
  calls it parked on that aren't answered yet.
  """
  @spec parked(GenServer.server()) :: term() | nil
  def parked(agent), do: GenServer.call(agent, :parked)

  @doc """
  Resumes a parked turn, passing `input` to whatever parked it.

      WardrikCore.resume(agent, %{"call_1" => :approve}, %{by: maria})

  `metadata` is yours, such as who answered. It's reported on the resumed turn's
  `[:wardrik_core, :turn, :start]` event. Returns `{:error, :not_parked}` if the agent isn't
  parked.

  Parked tool calls may be answered one at a time, as `%{call_id => answer}`. While a resumed turn
  runs, a call it parked on and isn't answered yet still takes an answer: the turn resumes with it
  once it parks again.
  """
  @spec resume(GenServer.server(), term(), map()) :: :ok | {:error, :not_parked}
  def resume(agent, input, metadata \\ %{}) when is_map(metadata),
    do: GenServer.call(agent, {:resume, input, metadata})

  @doc """
  Asks an evaluation `:model` the `:questions` about `:state`, from inside a turn.

  Use it when middleware needs a model's judgement on a call.

      questions = %{"urgent" => %{type: :boolean, instructions: "Is this urgent?"}}

      {:ok, %{"urgent" => %{"probability" => p}}, measurements} =
        WardrikCore.evaluate(context,
          model: "typesafe:jev-latest",
          state: "The site is down.",
          questions: questions
        )

      context = WardrikCore.Context.measure(context, measurements)

  Returns each answer under its question's name, and the call's measurements. Pass them to
  `WardrikCore.Context.measure/2`.
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
             WardrikCore.Keys.model_options(context, model)
           ) do
      {:ok, response.object, WardrikCore.Usage.measurements(response, model, context.prices)}
    end
  end

  @doc """
  Calls the context's model once, from inside a turn.

  Sends the context's instructions, messages and tools. Runs as a `:generate` step through the
  middleware, so policy and budgets see it like any other model call. Streams nothing.

  Use it when middleware needs the agent's own model, such as to summarise a long history.

      summarizing = %{context | instructions: "Summarise this conversation.", tools: []}
      {:ok, summarized} = WardrikCore.generate(summarizing)
      ReqLLM.Response.text(summarized.response)
      #=> "The user asked about..."

  Returns the context with `response` set, the reply added to `messages`, and the call's
  measurements added.
  """
  @spec generate(Context.t()) :: WardrikCore.Middleware.result()
  def generate(%Context{} = context), do: Turn.call_model(context)

  @doc """
  Runs `prompt` as one turn of a subagent, from inside a tool or middleware.

  The subagent uses the caller's model, middleware and tools, with `prompt` as its only message.

      {:ok, %{text: text, labels: labels}, measurements} =
        WardrikCore.subagent(context, "Find this week's releases.", name: "researcher")

  Returns its answer's `text` and the `labels` of what it read. Returns `{:error, reason,
  measurements}` if it fails. Either way, pass the measurements to
  `WardrikCore.Context.measure/2`.

  It can't wait on a person. A call that would park ends it with an error. A subagent that crashes
  fails with `{:exit, reason}`.

  ## Options

    * `:name` - its name. `"subagent"` unless set.
    * `:instructions` - replaces the caller's.
    * `:capabilities` - replaces the caller's.
    * `:except_tools` - names of tools to leave out. `[]` unless set.
    * `:max_rounds` - replaces the caller's.
    * `:timeout` - milliseconds it may run before failing with `:timeout`. `:infinity` unless set.

  ## Events

  Its own steps emit nothing to the caller's events. Instead it emits:

    * `[:wardrik_core, :subagent, :started]` - with its `prompt`.
    * `[:wardrik_core, :subagent, :progress]` - as it begins each tool call.
    * `[:wardrik_core, :subagent, :completed]` - with its `message`.
    * `[:wardrik_core, :subagent, :failed]` - with its `error`.

  See `WardrikCore.Telemetry` for their metadata.

  While it runs, its context's `subagent` field holds its name. Middleware that counts what each
  call measures can use it to skip the subagent's calls, and count the totals the caller adds
  instead.
  """
  @spec subagent(Context.t(), String.t(), keyword()) ::
          {:ok, %{text: String.t(), labels: [String.t()]}, map()} | {:error, term(), map()}
  def subagent(%Context{} = context, prompt, opts \\ []),
    do: WardrikCore.Subagent.run(context, prompt, opts)

  @doc """
  Returns `model`'s price from the model catalog, in US dollars per million tokens.

  Returns `nil` if the catalog has no price in dollars. Use the result, or one built from it, in
  an agent's `:prices`.

      WardrikCore.price("anthropic:claude-haiku-4-5")
      #=> [input: 1.0, output: 5.0, cache_read: 0.1, cache_write: 1.25]
  """
  @spec price(LLMDB.Model.t() | String.t()) :: WardrikCore.Usage.price() | nil
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

  defp saved(instance, agent_id) do
    if agent_id in list(instance), do: :ok, else: {:error, :not_found}
  end

  defp agents(instance), do: Module.concat(instance, Agents)
end
