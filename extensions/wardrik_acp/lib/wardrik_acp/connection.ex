defmodule WardrikACP.Connection do
  @moduledoc false
  use GenServer

  alias WardrikACP.Harness
  alias WardrikACP.RPC
  alias WardrikACP.Worktree

  @protocol 1
  @inherited ~w(HOME LANG LC_ALL LOGNAME PATH SHELL TERM TMPDIR USER)
  @method_not_found -32_601

  @type spec() :: %{
          key: term(),
          harness: Harness.t(),
          worktree: Worktree.t(),
          file: Path.t()
        }

  @type event() ::
          {:update, map()}
          | {:cost, number()}
          | {:permission, term(), map()}
          | {:stopped, String.t()}
          | {:failed, String.t()}

  @spec registry(atom()) :: atom()
  def registry(acp), do: Module.concat(acp, "Registry")

  @spec supervisor(atom()) :: atom()
  def supervisor(acp), do: Module.concat(acp, "Connections")

  @doc "Returns the connection for `spec.key`, started if it isn't running."
  @spec open(atom(), spec()) :: {:ok, pid()} | {:error, term()}
  def open(acp, spec) do
    case Registry.lookup(registry(acp), spec.key) do
      [{pid, _value}] -> {:ok, pid}
      [] -> started(DynamicSupervisor.start_child(supervisor(acp), {__MODULE__, {acp, spec}}))
    end
  end

  defp started({:ok, pid}), do: {:ok, pid}
  defp started({:error, {:already_started, pid}}), do: {:ok, pid}
  defp started({:error, reason}), do: {:error, reason}

  @doc """
  Makes the caller the reader once the session is ready. The reader receives each event as
  `{WardrikACP, pid, event}`, then every permission request still unanswered.

  Returns whether a prompt is running, and the permission request a previous process left
  unanswered.
  """
  @spec attach(pid()) ::
          {:ok, %{prompting: boolean(), restored: map() | nil}} | {:error, String.t()}
  def attach(pid), do: GenServer.call(pid, :attach, :infinity)

  @doc "Stops sending events to the caller. Unanswered permission requests stay held."
  @spec detach(pid()) :: :ok
  def detach(pid), do: GenServer.cast(pid, {:detach, self()})

  @doc "Sends a prompt. The reader receives `{:stopped, reason}` when it ends."
  @spec prompt(pid(), String.t()) :: :ok
  def prompt(pid, text), do: GenServer.cast(pid, {:prompt, text})

  @doc "Stops the connection if no call is attached, no prompt runs and no request waits."
  @spec stop_idle(pid()) :: :ok | :busy
  def stop_idle(pid), do: GenServer.call(pid, :stop_idle)

  @doc "Answers the permission request `id`."
  @spec answer(pid(), term(), :allow | :reject) :: :ok
  def answer(pid, id, outcome), do: GenServer.cast(pid, {:answer, id, outcome})

  @spec child_spec({atom(), spec()}) :: Supervisor.child_spec()
  def child_spec({_acp, spec} = args),
    do: %{
      id: {__MODULE__, spec.key},
      start: {__MODULE__, :start_link, [args]},
      restart: :temporary
    }

  @spec start_link({atom(), spec()}) :: GenServer.on_start()
  def start_link({acp, spec}),
    do: GenServer.start_link(__MODULE__, spec, name: {:via, Registry, {registry(acp), spec.key}})

  @impl GenServer
  def init(spec) do
    Process.flag(:trap_exit, true)
    saved = saved(spec.file)

    state = %{
      spec: spec,
      name: spec.harness.name,
      port: nil,
      buffer: "",
      next: 0,
      calls: %{},
      status: :starting,
      capabilities: %{},
      session: nil,
      saved: saved,
      restored: saved["pending"],
      cost: saved["cost"] || 0,
      preface: nil,
      waiting: [],
      reader: nil,
      monitor: nil,
      outbox: [],
      pending: %{},
      prompt: nil,
      idle: nil
    }

    {:ok, state, {:continue, :start}}
  end

  @impl GenServer
  def handle_continue(:start, %{spec: spec} = state) do
    with :ok <- Worktree.open(spec.worktree),
         {:ok, path} <- executable(spec.harness.command) do
      port =
        Port.open({:spawn_executable, path}, [
          :binary,
          :exit_status,
          :use_stdio,
          :hide,
          args: spec.harness.args,
          env: env(spec.harness.env),
          cd: spec.worktree.path
        ])

      params = %{
        "protocolVersion" => @protocol,
        "clientCapabilities" => %{
          "fs" => %{"readTextFile" => false, "writeTextFile" => false},
          "terminal" => false
        },
        "clientInfo" => %{"name" => "wardrik_acp", "version" => version()}
      }

      {:noreply, request(%{state | port: port}, "initialize", params, :initialize)}
    else
      {:error, reason} -> fail(state, reason)
    end
  end

  @impl GenServer
  def handle_call(:attach, from, %{status: :ready} = state), do: attached(from, state)

  def handle_call(:attach, _from, %{status: {:failed, reason}} = state),
    do: {:stop, {:shutdown, reason}, {:error, reason}, state}

  def handle_call(:attach, from, state),
    do: {:noreply, %{state | waiting: [from | state.waiting]}}

  def handle_call(:stop_idle, _from, %{reader: nil, prompt: nil, pending: pending} = state)
      when pending == %{},
      do: {:stop, :normal, :ok, state}

  def handle_call(:stop_idle, _from, state), do: {:reply, :busy, state}

  @impl GenServer
  def handle_cast({:detach, pid}, %{reader: pid} = state),
    do: {:noreply, idle(%{unwatch(state) | reader: nil})}

  def handle_cast({:detach, _pid}, state), do: {:noreply, state}

  def handle_cast({:prompt, text}, state) do
    blocks = Enum.map(List.wrap(state.preface) ++ [text], &%{"type" => "text", "text" => &1})
    params = %{"sessionId" => state.session, "prompt" => blocks}
    id = state.next

    {:noreply,
     request(%{state | preface: nil, prompt: id}, "session/prompt", params, {:prompt, id})}
  end

  def handle_cast({:answer, id, outcome}, state) do
    {params, pending} = Map.pop(state.pending, id)
    write(state, RPC.result(id, %{"outcome" => outcome(outcome, params["options"] || [])}))
    {:noreply, save(%{state | pending: pending})}
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {messages, buffer} = RPC.split(state.buffer <> data)
    Enum.reduce_while(messages, {:noreply, %{state | buffer: buffer}}, &handled/2)
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    reason = "#{state.name} exited with status #{status}."
    state = deliver(%{state | port: nil}, {:failed, reason})
    fail(state, reason)
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state),
    do: {:noreply, idle(released(%{state | monitor: nil}))}

  def handle_info(:idle, %{reader: nil} = state), do: {:stop, :normal, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{port: port}) when is_port(port) do
    with {:os_pid, pid} <- Port.info(port, :os_pid) do
      Port.close(port)
      System.cmd("kill", ["-TERM", to_string(pid)], stderr_to_stdout: true)
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp handled(message, {:noreply, state}), do: {:cont, message(message, state)}
  defp handled(_message, stop), do: {:halt, stop}

  defp message({:result, id, result}, state) do
    {tag, calls} = Map.pop(state.calls, id)
    result(tag, result, %{state | calls: calls})
  end

  defp message({:error, id, error}, state) do
    {tag, calls} = Map.pop(state.calls, id)
    error(tag, error, %{state | calls: calls})
  end

  defp message({:request, id, "session/request_permission", params}, state) do
    state = save(%{state | pending: Map.put(state.pending, id, params)})
    {:noreply, deliver(state, {:permission, id, params})}
  end

  defp message({:request, id, method, _params}, state) do
    write(state, RPC.error(id, @method_not_found, "Method not found: #{method}"))
    {:noreply, state}
  end

  defp message({:notification, "session/update", %{"update" => update}}, state),
    do: {:noreply, update(update, state)}

  defp message({:notification, _method, _params}, state), do: {:noreply, state}

  defp update(_update, %{status: :loading} = state), do: state

  defp update(
         %{"sessionUpdate" => "usage_update", "cost" => %{"currency" => "USD"} = cost} = update,
         state
       ) do
    amount = cost["amount"]
    state = deliver(state, {:update, update})
    save(deliver(%{state | cost: amount}, {:cost, amount - state.cost}))
  end

  defp update(update, state), do: deliver(state, {:update, update})

  defp result(:initialize, result, state) do
    state = %{state | capabilities: Map.get(result || %{}, "agentCapabilities") || %{}}
    {:noreply, start_session(state)}
  end

  defp result(:session, _result, state), do: ready(state)

  defp result(:new, result, state) do
    state = save(%{state | session: result["sessionId"], cost: 0})
    configure(%{state | status: :configuring}, result)
  end

  defp result({:option, options}, _result, state), do: set_options(state, options)

  defp result({:prompt, id}, result, %{prompt: id} = state),
    do: {:noreply, deliver(%{state | prompt: nil}, {:stopped, result["stopReason"]})}

  defp result({:prompt, _cancelled}, _result, state), do: {:noreply, state}

  defp error(:session, _error, state), do: {:noreply, new_session(state)}

  defp error({:prompt, id}, error, %{prompt: id} = state),
    do: {:noreply, deliver(%{state | prompt: nil}, {:failed, error["message"]})}

  defp error({:prompt, _cancelled}, _error, state), do: {:noreply, state}

  defp error(_tag, error, state), do: fail(state, "#{state.name} refused: #{error["message"]}")

  defp start_session(%{saved: %{"session" => id}, capabilities: capabilities} = state)
       when is_binary(id) do
    cond do
      capabilities["loadSession"] == true ->
        params = %{"sessionId" => id, "cwd" => state.spec.worktree.path, "mcpServers" => []}
        request(%{state | session: id, status: :loading}, "session/load", params, :session)

      is_map(get_in(capabilities, ["sessionCapabilities", "resume"])) ->
        params = %{"sessionId" => id, "cwd" => state.spec.worktree.path}
        request(%{state | session: id}, "session/resume", params, :session)

      true ->
        new_session(state)
    end
  end

  defp start_session(state), do: new_session(state)

  defp new_session(state) do
    instructions = instructions(state.spec)
    system? = is_map(get_in(state.capabilities, ["sessionCapabilities", "systemPrompt"]))

    params =
      %{"cwd" => state.spec.worktree.path, "mcpServers" => []}
      |> put_present("_meta", state.spec.harness.meta)
      |> put_present("systemPrompt", system_prompt(system?, instructions))

    preface = if system?, do: nil, else: instructions
    request(%{state | preface: preface, status: :starting}, "session/new", params, :new)
  end

  defp system_prompt(true, text) when is_binary(text),
    do: %{"mode" => "append", "content" => [%{"type" => "text", "text" => text}]}

  defp system_prompt(_system?, _text), do: nil

  defp configure(state, result) do
    offered = result["configOptions"] || []

    options =
      for {key, value} <- Enum.sort(state.spec.harness.options),
          do: {key, Enum.find(offered, &(&1["category"] == key or &1["id"] == key)), value}

    case Enum.find(options, &match?({_key, nil, _value}, &1)) do
      {key, nil, _value} -> fail(state, missing_option(state.name, key, offered))
      nil -> set_options(state, for({_key, option, value} <- options, do: {option["id"], value}))
    end
  end

  defp missing_option(name, key, offered) do
    names = Enum.map_join(offered, ", ", &(&1["category"] || &1["id"]))
    "#{name} has no config option #{key}. It has: #{names}."
  end

  defp set_options(state, []), do: ready(state)

  defp set_options(state, [{id, value} | options]) do
    params = Map.merge(%{"sessionId" => state.session, "configId" => id}, value(value))
    {:noreply, request(state, "session/set_config_option", params, {:option, options})}
  end

  defp value(value) when is_boolean(value), do: %{"type" => "boolean", "value" => value}
  defp value(value), do: %{"value" => value}

  defp ready(state) do
    state = %{state | status: :ready}

    state.waiting
    |> Enum.reverse()
    |> Enum.reduce({:noreply, %{state | waiting: []}}, fn from, {:noreply, state} ->
      {:reply, reply, state} = attached(from, state)
      GenServer.reply(from, reply)
      {:noreply, state}
    end)
  end

  defp attached({pid, _tag} = from, %{reader: reader} = state)
       when is_pid(reader) and reader != pid do
    if Process.alive?(reader),
      do:
        {:reply, {:error, "#{state.name} is already working on this. Use another work name."},
         state},
      else: attached(from, released(unwatch(state)))
  end

  defp attached({pid, _tag}, state) do
    state = cancel_idle(%{state | reader: pid, monitor: Process.monitor(pid)})
    Enum.each(Enum.reverse(state.outbox), &send(pid, {WardrikACP, self(), &1}))

    state.pending
    |> Enum.sort()
    |> Enum.each(fn {id, params} ->
      send(pid, {WardrikACP, self(), {:permission, id, params}})
    end)

    {:reply, {:ok, %{prompting: state.prompt != nil, restored: state.restored}},
     %{state | outbox: [], restored: nil}}
  end

  defp deliver(state, {:permission, _id, _params} = event), do: send_reader(state, event)

  # A prompt that ends with no reader is dropped with what it sent. The next call prompts again.
  defp deliver(%{reader: nil} = state, {ended, _reason}) when ended in [:stopped, :failed],
    do: %{state | outbox: []}

  defp deliver(%{reader: nil} = state, event), do: %{state | outbox: [event | state.outbox]}
  defp deliver(state, event), do: send_reader(state, event)

  defp send_reader(%{reader: nil} = state, _event), do: state

  defp send_reader(%{reader: reader} = state, event) do
    send(reader, {WardrikACP, self(), event})
    state
  end

  # The reader stopped without detaching, so its call was stopped. Its prompt is cancelled.
  defp released(%{prompt: nil} = state), do: %{state | reader: nil, outbox: []}

  defp released(state) do
    write(state, RPC.notification("session/cancel", %{"sessionId" => state.session}))

    for {id, _params} <- state.pending,
        do: write(state, RPC.result(id, %{"outcome" => %{"outcome" => "cancelled"}}))

    save(%{state | reader: nil, outbox: [], prompt: nil, pending: %{}})
  end

  # A process that fails before anyone attached stays until someone does, to tell them why.
  defp fail(%{waiting: [], reader: nil, status: status} = state, reason) when status != :ready,
    do: {:noreply, idle(%{state | status: {:failed, reason}})}

  defp fail(state, reason) do
    Enum.each(state.waiting, &GenServer.reply(&1, {:error, reason}))
    {:stop, {:shutdown, reason}, %{state | waiting: []}}
  end

  defp request(state, method, params, tag) do
    id = state.next
    write(state, RPC.request(id, method, params))
    %{state | next: id + 1, calls: Map.put(state.calls, id, tag)}
  end

  defp write(%{port: port}, line), do: Port.command(port, line)

  defp outcome(:allow, options), do: selected(options, ["allow_once"])
  defp outcome(:reject, options), do: selected(options, ["reject_once", "reject_always"])

  defp selected(options, kinds) do
    case Enum.find(kinds, &Enum.find(options, fn option -> option["kind"] == &1 end)) do
      nil -> %{"outcome" => "cancelled"}
      kind -> %{"outcome" => "selected", "optionId" => option_id(options, kind)}
    end
  end

  defp option_id(options, kind), do: Enum.find(options, &(&1["kind"] == kind))["optionId"]

  defp idle(%{reader: nil} = state),
    do: %{cancel_idle(state) | idle: Process.send_after(self(), :idle, state.spec.harness.idle)}

  defp cancel_idle(%{idle: nil} = state), do: state

  defp cancel_idle(%{idle: timer} = state) do
    Process.cancel_timer(timer)
    %{state | idle: nil}
  end

  defp unwatch(%{monitor: nil} = state), do: state

  defp unwatch(%{monitor: ref} = state) do
    Process.demonitor(ref, [:flush])
    %{state | monitor: nil}
  end

  defp save(state) do
    saved = %{
      "session" => state.session,
      "cost" => state.cost,
      "pending" => state.pending |> Enum.sort() |> Enum.map(&elem(&1, 1)) |> List.first()
    }

    File.write!(state.spec.file, JSON.encode!(saved))
    state
  end

  defp saved(file) do
    with {:ok, body} <- File.read(file),
         {:ok, %{} = saved} <- JSON.decode(body) do
      saved
    else
      _missing -> %{}
    end
  end

  defp instructions(spec) do
    files =
      for name <- spec.harness.context,
          {:ok, body} <- [File.read(Path.join(spec.worktree.path, name))],
          do: "#{name}:\n\n#{body}"

    case Enum.reject([spec.harness.instructions | files], &is_nil/1) do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  defp executable(command) do
    case System.find_executable(command) do
      nil -> {:error, "#{command} isn't installed or isn't on PATH."}
      path -> {:ok, path}
    end
  end

  defp env(given) do
    kept = Map.merge(Map.take(System.get_env(), @inherited), given)

    unset =
      for {name, _value} <- System.get_env(), not Map.has_key?(kept, name), do: {name, false}

    Enum.map(Map.to_list(kept) ++ unset, fn {name, value} -> {~c"#{name}", charlist(value)} end)
  end

  defp charlist(false), do: false
  defp charlist(value), do: String.to_charlist(value)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, empty) when empty == %{}, do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp version, do: :wardrik_acp |> Application.spec(:vsn) |> to_string()
end
