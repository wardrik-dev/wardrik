defmodule Wardrik.Operations.Runtime do
  @moduledoc false

  # Reads resource use from the BEAM. `measure/1` runs on each node, through :erpc, and measures
  # that node and the agents running on it.

  alias Wardrik.Operations.Running
  alias Wardrik.Operations.Snapshot

  @sample_ms 250
  @timeout 5_000
  @limit 20
  @keys [:memory, :reductions, :message_queue_len, :binary, :links]

  @doc "Returns resource use for each node, and the running agents that use the most memory."
  @spec deployment(Wardrik.Scope.t(), map()) :: {:ok, map()}
  def deployment(%Wardrik.Scope{wardrik: wardrik}, input) do
    agents = Wardrik.agents(wardrik)
    running = agents |> WardrikCore.running() |> Enum.group_by(fn {_key, pid} -> node(pid) end)

    nodes =
      Enum.uniq(
        Enum.map(WardrikCore.nodes(agents), &String.to_existing_atom/1) ++ Map.keys(running)
      )

    measured =
      nodes
      |> Task.async_stream(
        &:erpc.call(&1, __MODULE__, :measure, [Map.get(running, &1, [])], @timeout),
        timeout: @timeout + 1_000,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.flat_map(fn
        {:ok, result} -> [result]
        {:exit, _reason} -> []
      end)

    top =
      measured
      |> Enum.flat_map(fn {_node, agents} -> agents end)
      |> Enum.sort_by(& &1["memory_bytes"], :desc)
      |> Enum.take(input["limit"] || @limit)

    {:ok, %{"nodes" => Enum.map(measured, fn {node, _agents} -> node end), "agents" => top}}
  end

  @doc "Returns a running agent's resource use, or `not_found` while it sleeps."
  @spec agent(Wardrik.Scope.t(), map()) :: {:ok, map()} | {:error, Wardrik.Error.t()}
  def agent(%Wardrik.Scope{wardrik: wardrik}, input) do
    key = Running.key(input)

    with {:ok, pid} <- Snapshot.running(wardrik, key) do
      case :erpc.call(node(pid), __MODULE__, :processes, [[{key, pid}]], @timeout) do
        [measured] -> {:ok, measured}
        [] -> {:error, Wardrik.Error.new(:not_found, "#{Running.describe(key)} sleeps.")}
      end
    end
  end

  @doc false
  @spec measure([{Running.agent(), pid()}]) :: {map(), [map()]}
  def measure(agents), do: {node_stats(length(agents)), processes(agents)}

  @doc false
  @spec processes([{Running.agent(), pid()}]) :: [map()]
  def processes(agents) do
    for {{agent, conversation}, pid} <- agents,
        [{_root, root} | _rest] = tree <- [walk([pid], MapSet.new([pid]), [])],
        do: agent_stats(agent, conversation, root, tree)
  end

  # The agent's turn and tool calls are linked processes whose parent is in the agent's tree.
  defp walk([], _seen, acc), do: Enum.reverse(acc)

  defp walk([pid | rest], seen, acc) do
    case Process.info(pid, @keys) do
      nil ->
        walk(rest, seen, acc)

      info ->
        children =
          for linked <- info[:links],
              is_pid(linked),
              node(linked) == node(),
              not MapSet.member?(seen, linked),
              parent(linked) == pid,
              do: linked

        walk(rest ++ children, MapSet.union(seen, MapSet.new(children)), [{pid, info} | acc])
    end
  end

  defp parent(pid) do
    case Process.info(pid, :parent) do
      {:parent, parent} -> parent
      nil -> nil
    end
  end

  defp agent_stats(agent, conversation, root, tree) do
    infos = Enum.map(tree, fn {_pid, info} -> info end)

    binaries =
      infos
      |> Enum.flat_map(& &1[:binary])
      |> Enum.uniq_by(fn {id, _size, _refs} -> id end)
      |> Enum.sum_by(fn {_id, size, _refs} -> size end)

    %{
      "agent" => agent,
      "node" => to_string(node()),
      "memory_bytes" => Enum.sum_by(infos, & &1[:memory]),
      "binary_bytes" => binaries,
      "processes" => length(infos),
      "message_queue" => root[:message_queue_len],
      "reductions" => Enum.sum_by(infos, & &1[:reductions])
    }
    |> put_present("conversation", conversation)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp node_stats(agents) do
    utilization = utilization()

    {uptime, _since} = :erlang.statistics(:wall_clock)
    {reductions, _since} = :erlang.statistics(:reductions)
    {collections, reclaimed, _zero} = :erlang.statistics(:garbage_collection)
    {{:input, input}, {:output, output}} = :erlang.statistics(:io)
    {switches, _zero} = :erlang.statistics(:context_switches)

    %{
      "name" => to_string(node()),
      "agents" => agents,
      "uptime_ms" => uptime,
      "otp_release" => to_string(:erlang.system_info(:otp_release)),
      "erts_version" => to_string(:erlang.system_info(:version)),
      "elixir_version" => System.version(),
      "architecture" => to_string(:erlang.system_info(:system_architecture)),
      "schedulers" => :erlang.system_info(:schedulers),
      "schedulers_online" => :erlang.system_info(:schedulers_online),
      "dirty_cpu_schedulers" => :erlang.system_info(:dirty_cpu_schedulers),
      "dirty_io_schedulers" => :erlang.system_info(:dirty_io_schedulers),
      "scheduler_utilization" => Float.round(utilization, 4),
      "run_queue" => :erlang.statistics(:total_run_queue_lengths),
      "memory" => memory(),
      "process_groups" => groups(),
      "processes" => used(:process_count, :process_limit),
      "ports" => used(:port_count, :port_limit),
      "atoms" => used(:atom_count, :atom_limit),
      "ets_tables" => used(:ets_count, :ets_limit),
      "reductions" => reductions,
      "garbage_collections" => %{"count" => collections, "words_reclaimed" => reclaimed},
      "io" => %{"input_bytes" => input, "output_bytes" => output},
      "context_switches" => switches,
      "connected_nodes" => Enum.map(Node.list(), &to_string/1)
    }
    |> put_present("logical_processors", processors())
    |> put_present("os", os())
  end

  # The flag stays on only while this process lives, so measuring leaves it as it was.
  defp utilization do
    :erlang.system_flag(:scheduler_wall_time, true)
    first = :erlang.statistics(:scheduler_wall_time)
    Process.sleep(@sample_ms)
    second = :erlang.statistics(:scheduler_wall_time)
    normal = :erlang.system_info(:schedulers)

    {active, total} =
      for {{id, active1, total1}, {id, active2, total2}} <-
            Enum.zip(Enum.sort(first), Enum.sort(second)),
          id <= normal,
          reduce: {0, 0} do
        {active, total} -> {active + active2 - active1, total + total2 - total1}
      end

    if total > 0, do: active / total, else: 0.0
  end

  defp memory do
    :erlang.memory()
    |> Map.new(fn {type, bytes} -> {Atom.to_string(type), bytes} end)
    |> Map.put("persistent_term", :persistent_term.info().memory)
    |> put_present("resident", resident())
  end

  # Linux reports the resident set size in /proc. Elsewhere it stays absent.
  defp resident do
    with {:ok, status} <- File.read("/proc/self/status"),
         [_line, kilobytes] <- Regex.run(~r/^VmRSS:\s+(\d+) kB/m, status) do
      String.to_integer(kilobytes) * 1024
    else
      _none -> nil
    end
  end

  # Processes counted by the module that runs them, and the application that module belongs to.
  defp groups do
    owners =
      for {app, _description, _version} <- :application.loaded_applications(),
          {:ok, modules} = :application.get_key(app, :modules),
          module <- modules,
          into: %{},
          do: {module, app}

    Process.list()
    |> Enum.flat_map(fn pid ->
      case Process.info(pid, [
             {:dictionary, :"$initial_call"},
             :initial_call,
             :registered_name,
             :memory
           ]) do
        [{_key, started}, {:initial_call, initial}, {:registered_name, name}, {:memory, memory}] ->
          [{runs(started, initial, name), memory}]

        nil ->
          []
      end
    end)
    |> Enum.group_by(fn {module, _memory} -> module end, fn {_module, memory} -> memory end)
    |> Enum.map(fn {module, memories} ->
      %{
        "module" => inspect(module),
        "processes" => length(memories),
        "memory_bytes" => Enum.sum(memories)
      }
      |> put_present("application", owners[module] && Atom.to_string(owners[module]))
    end)
    |> Enum.sort_by(&{-&1["processes"], &1["module"]})
  end

  # proc_lib keeps the callback module: {supervisor, Module, 1} for a supervisor, and
  # {Module, init, 1} for other behaviours. A process spawned from a fun starts in :erlang, so a
  # registered one goes by its name, such as :code_server.
  defp runs({:supervisor, module, _arity}, _initial, _name), do: module
  defp runs({module, _function, _arity}, _initial, _name), do: module
  defp runs(:undefined, {:erlang, :apply, 2}, name) when name != [], do: name
  defp runs(:undefined, {module, _function, _arity}, _name), do: module

  defp used(count, limit),
    do: %{"count" => :erlang.system_info(count), "limit" => :erlang.system_info(limit)}

  defp processors do
    case :erlang.system_info(:logical_processors) do
      count when is_integer(count) -> count
      :unknown -> nil
    end
  end

  defp os do
    if List.keymember?(Application.started_applications(), :os_mon, 0) do
      memory = :memsup.get_system_memory_data()

      %{
        "load_1" => :cpu_sup.avg1() / 256,
        "load_5" => :cpu_sup.avg5() / 256,
        "load_15" => :cpu_sup.avg15() / 256,
        "disks" => disks()
      }
      |> put_present("memory_total_bytes", memory[:system_total_memory] || memory[:total_memory])
      |> put_present("memory_available_bytes", memory[:available_memory] || memory[:free_memory])
    end
  end

  defp disks do
    for {path, kilobytes, percent} <- :disksup.get_disk_data(),
        kilobytes > 0,
        do: %{
          "path" => to_string(path),
          "total_bytes" => kilobytes * 1024,
          "used_percent" => percent
        }
  end
end
