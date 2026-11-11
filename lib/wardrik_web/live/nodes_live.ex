defmodule WardrikWeb.NodesLive do
  @moduledoc false
  use Phoenix.LiveView

  import WardrikWeb.Components

  @every 5_000
  # Five minutes of samples, one every five seconds.
  @kept 60

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@every, :tick)

    {:ok,
     socket
     |> assign(page_title: "Nodes", nodes: [], asleep: 0, states: nil, runtime: nil, history: %{})
     |> assign(agents: [], last: %{}, rates: %{}, error: nil, runtime_error: nil)
     |> load()}
  end

  @impl true
  def handle_event("reload", _params, socket) do
    case Wardrik.Scope.run(socket.assigns.scope, "deployment.reload", %{}) do
      {:ok, _answer} ->
        {:noreply, socket |> put_flash(:info, "Reloaded agent definitions.") |> load()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  @impl true
  def handle_info(:tick, socket), do: {:noreply, load(socket)}

  defp load(socket), do: socket |> nodes() |> runtime()

  defp nodes(socket) do
    case Wardrik.Scope.run(socket.assigns.scope, "deployment.nodes", %{}) do
      {:ok, %{"nodes" => nodes, "asleep" => asleep} = answer} ->
        assign(socket, nodes: nodes, asleep: asleep, states: states(answer), error: nil)

      {:error, error} ->
        assign(socket, error: error.message)
    end
  end

  # Older servers don't have deployment.runtime. The page then shows only the node list.
  defp runtime(socket) do
    with %{} <- WardrikProtocol.operation("deployment.runtime"),
         {:ok, runtime} <- Wardrik.Scope.run(socket.assigns.scope, "deployment.runtime", %{}) do
      socket
      |> assign(runtime: runtime, runtime_error: nil)
      |> assign(history: record(socket.assigns.history, runtime["nodes"]))
      |> rates(runtime["agents"])
    else
      nil -> socket
      {:error, error} -> assign(socket, runtime_error: error.message)
    end
  end

  # Older servers count only the agents on each node.
  defp states(%{"running" => running, "idle" => idle, "parked" => parked}),
    do: %{running: running, idle: idle, parked: parked}

  defp states(_answer), do: nil

  defp record(history, nodes) do
    Map.new(nodes, fn node ->
      sample = %{
        cpu: node["scheduler_utilization"],
        memory: node["memory"]["total"],
        run_queue: node["run_queue"],
        processes: node["processes"]["count"]
      }

      {node["name"], Enum.take([sample | Map.get(history, node["name"], [])], @kept)}
    end)
  end

  # Reductions per second, from the change since the last sample.
  defp rates(socket, agents) do
    now = System.monotonic_time(:millisecond)

    rates =
      for agent <- agents,
          key = {agent["agent"], agent["conversation"]},
          {at, before} <- [socket.assigns.last[key]],
          now > at,
          into: %{},
          do: {key, max(agent["reductions"] - before, 0) * 1000 / (now - at)}

    last = Map.new(agents, &{{&1["agent"], &1["conversation"]}, {now, &1["reductions"]}})
    assign(socket, agents: agents, rates: rates, last: last)
  end

  defp series(history, name, field),
    do: history |> Map.get(name, []) |> Enum.map(& &1[field]) |> Enum.reverse()

  # Mounts of the same disk report the same size and use, so show it once, at its shortest path.
  # Disks under 1 GB are system mounts, not storage.
  defp disks(node) do
    (node["os"]["disks"] || [])
    |> Enum.filter(&(&1["total_bytes"] >= 1024 ** 3))
    |> Enum.sort_by(&String.length(&1["path"]))
    |> Enum.uniq_by(&{&1["total_bytes"], &1["used_percent"]})
    |> Enum.sort_by(& &1["used_percent"], :desc)
  end

  defp cpu(value), do: "#{round(value * 100)}%"

  defp rate(nil), do: "—"
  defp rate(per_second), do: number(round(per_second))

  @memory [
    {"processes", "Processes", "Memory of every process on the node, agents included."},
    {"code", "Code", "Loaded modules. A release loads all of its code when it starts."},
    {"binary", "Binaries",
     "Large binaries that processes share, such as HTTP bodies and model replies."},
    {"persistent_term", "Persistent terms",
     "Data that libraries load once and read often, such as the catalog of LLM models."},
    {"ets", "ETS tables", "In-memory tables that Wardrik and libraries keep."},
    {"atom", "Atoms", "The names that code uses. They stay for the life of the node."}
  ]

  # Applications listed before "more applications".
  @shown 8

  # The memory the listed types don't cover: the runtime's own allocators, ports and the rest.
  defp other(memory) do
    listed = Enum.sum_by(@memory, fn {type, _label, _tip} -> memory[type] || 0 end)
    max(memory["total"] - listed, 0)
  end

  # Process groups by application, the busiest first.
  defp applications(node) do
    (node["process_groups"] || [])
    |> Enum.group_by(& &1["application"])
    |> Enum.map(fn {application, modules} ->
      %{
        name: application || "No application",
        processes: Enum.sum_by(modules, & &1["processes"]),
        memory: Enum.sum_by(modules, & &1["memory_bytes"]),
        modules: modules
      }
    end)
    |> Enum.sort_by(&{-&1.processes, &1.name})
  end

  defp memory_tip(memory) do
    beam =
      "Memory the BEAM has allocated for its own data. On an idle node, most of it is loaded code and data that libraries keep."

    if memory["resident"],
      do:
        beam <>
          " The OS counts #{bytes(memory["resident"])}, because the BEAM keeps freed memory for reuse.",
      else: beam
  end

  attr :app, :map, required: true

  defp application(assigns) do
    ~H"""
    <details class="app">
      <summary>
        <span>{@app.name}</span>
        <span class="num">{number(@app.processes)} {plural(@app.processes, "process", "processes")}</span>
        <span class="num">{bytes(@app.memory)}</span>
      </summary>
      <div class="mods">
        <%= for module <- @app.modules do %>
          <code>{module["module"]}</code>
          <span class="num">{number(module["processes"])}</span>
          <span class="num">{bytes(module["memory_bytes"])}</span>
        <% end %>
      </div>
    </details>
    """
  end

  defp plural(1, one, _many), do: one
  defp plural(_count, _one, many), do: many

  @impl true
  def render(assigns) do
    assigns = assign(assigns, memory_types: @memory, shown: @shown)

    ~H"""
    <.head
      title="Nodes"
      lead="The nodes in the cluster, their resource use, and the agents that use the most memory. This page refreshes every 5 seconds."
    >
      <:actions>
        <button class="btn" phx-click="reload" data-confirm="Reload all agent definitions?">Reload definitions</button>
      </:actions>
    </.head>
    <div :if={@error} class="flash error">{@error}</div>
    <div class="stats">
      <div class="stat"><b>{length(@nodes)}</b><span>nodes</span></div>
      <div :if={!@states} class="stat">
        <b>{Enum.sum_by(@nodes, & &1["agents"])}</b><span>agents running</span>
      </div>
      <div :if={@states} class="stat">
        <b>{@states.running}</b><span>working<.tip text="Agents answering a message or running a tool now." /></span>
      </div>
      <div :if={@states} class="stat">
        <b>{@states.idle}</b><span>idle<.tip text="Agents in memory that wait for a message. An idle agent uses a few hundred KB and no CPU." /></span>
      </div>
      <div :if={@states} class="stat">
        <b>{@states.parked}</b><span>wait on a person<.tip text="Agents that wait for someone to approve or deny a call. Approvals lists them." /></span>
      </div>
      <div class="stat">
        <b>{@asleep}</b><span>asleep<.tip text="Agents saved to the store, not in memory. A sleeping agent uses no memory or CPU, and wakes when something asks it." /></span>
      </div>
    </div>

    <div :if={@runtime_error} class="flash info">
      Resource use isn't available: {@runtime_error}
    </div>

    <div :if={!@runtime} class="card">
      <table class="list">
        <thead>
          <tr>
            <th>Node</th><th class="num">Agents</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={node <- @nodes}>
            <td class="mono">{node["name"]}</td><td class="num">{node["agents"]}</td>
          </tr>
        </tbody>
      </table>
    </div>

    <section
      :for={node <- (@runtime && @runtime["nodes"]) || []}
      class="card node"
      id={"node-" <> node["name"]}
    >
      <header>
        <span class="mono">{node["name"]}</span>
        <span class="node-meta">
          Up {took(node["uptime_ms"])} · OTP {node["otp_release"]} · Elixir {node["elixir_version"]}
        </span>
      </header>
      <div class="body">
        <div class="tiles">
          <div class="tile">
            <span class="tile-label">
              Scheduler use<.tip text="How busy the BEAM's schedulers were over the last 250 ms. An idle node stays near 0%." />
            </span>
            <span class="tile-value">{cpu(node["scheduler_utilization"])}</span>
            <.spark
              values={series(@history, node["name"], :cpu)}
              max={1}
              format={&cpu/1}
              label={"Scheduler use on #{node["name"]} over the last 5 minutes"}
            />
          </div>
          <div class="tile">
            <span class="tile-label">
              BEAM memory<.tip text={memory_tip(node["memory"])} />
            </span>
            <span class="tile-value">
              {bytes(node["memory"]["total"])}<span
                :if={node["memory"]["resident"]}
                class="tile-sub"
              >{bytes(node["memory"]["resident"])} in the OS</span>
            </span>
            <.spark
              values={series(@history, node["name"], :memory)}
              format={&bytes/1}
              label={"Memory on #{node["name"]} over the last 5 minutes"}
            />
          </div>
          <div class="tile">
            <span class="tile-label">
              Run queue<.tip text="Processes ready to run that wait for a scheduler. 0 means the node keeps up with its work." />
            </span>
            <span class="tile-value">{number(node["run_queue"])}</span>
            <.spark
              values={series(@history, node["name"], :run_queue)}
              label={"Processes waiting to run on #{node["name"]} over the last 5 minutes"}
            />
          </div>
          <div class="tile">
            <span class="tile-label">
              Processes<.tip text="BEAM processes are light, a few KB each. Most belong to the web server and libraries. What runs on this node lists them." />
            </span>
            <span class="tile-value">{number(node["processes"]["count"])}</span>
            <.spark
              values={series(@history, node["name"], :processes)}
              label={"Processes on #{node["name"]} over the last 5 minutes"}
            />
          </div>
        </div>

        <div class="split">
          <div>
            <h3 class="section">Memory by type</h3>
            <div class="meters">
              <.meter
                :for={{type, label, tip} <- @memory_types}
                :if={node["memory"][type]}
                label={label}
                tip={tip}
                count={node["memory"][type]}
                limit={node["memory"]["total"]}
                format={&bytes/1}
                warn={false}
              />
              <.meter
                label="Other"
                tip="The runtime's own memory: allocators, ports, schedulers and the rest."
                count={other(node["memory"])}
                limit={node["memory"]["total"]}
                format={&bytes/1}
                warn={false}
              />
            </div>
          </div>
          <div>
            <h3 class="section">
              Limits<.tip text="How close the node is to the BEAM's fixed limits. A bar turns red at 80%." />
            </h3>
            <div class="meters">
              <.meter
                label="Processes"
                count={node["processes"]["count"]}
                limit={node["processes"]["limit"]}
              />
              <.meter label="Ports" count={node["ports"]["count"]} limit={node["ports"]["limit"]} />
              <.meter label="Atoms" count={node["atoms"]["count"]} limit={node["atoms"]["limit"]} />
              <.meter
                label="ETS tables"
                count={node["ets_tables"]["count"]}
                limit={node["ets_tables"]["limit"]}
              />
            </div>
          </div>
          <div :if={node["os"]}>
            <h3 class="section">Machine</h3>
            <dl class="facts">
              <dt>Load</dt>
              <dd class="num">
                {Float.round(node["os"]["load_1"] / 1, 2)}, {Float.round(node["os"]["load_5"] / 1, 2)} and {Float.round(
                  node["os"]["load_15"] / 1,
                  2
                )}
                <span class="sub">over 1, 5 and 15 minutes</span>
              </dd>
              <dt>Cores</dt>
              <dd>{node["logical_processors"] || "—"}</dd>
              <dt>Schedulers</dt>
              <dd>{node["schedulers_online"]} of {node["schedulers"]} online</dd>
            </dl>
            <div class="meters" style="margin-top: 12px">
              <.meter
                :if={node["os"]["memory_total_bytes"] && node["os"]["memory_available_bytes"]}
                label="Machine memory"
                tip="Memory in use by everything on the machine, not only this node."
                count={node["os"]["memory_total_bytes"] - node["os"]["memory_available_bytes"]}
                limit={node["os"]["memory_total_bytes"]}
                format={&bytes/1}
              />
              <.meter
                :for={disk <- Enum.take(disks(node), 3)}
                label={"Disk " <> disk["path"]}
                count={div(disk["total_bytes"] * disk["used_percent"], 100)}
                limit={disk["total_bytes"]}
                format={&bytes/1}
              />
            </div>
            <details :if={length(disks(node)) > 3} class="group" style="margin-top: 12px">
              <summary>{length(disks(node)) - 3} more disks</summary>
              <div class="meters" style="margin-top: 12px">
                <.meter
                  :for={disk <- Enum.drop(disks(node), 3)}
                  label={"Disk " <> disk["path"]}
                  count={div(disk["total_bytes"] * disk["used_percent"], 100)}
                  limit={disk["total_bytes"]}
                  format={&bytes/1}
                />
              </div>
            </details>
          </div>
        </div>

        <h3 class="section" style="margin-top: 20px">
          What runs on this node<.tip text="Processes grouped by the application whose code they run. Each running agent adds one process, and one more for each turn or tool call in progress. Sleeping agents add none." />
        </h3>
        <div class="groups">
          <.application :for={app <- Enum.take(applications(node), @shown)} app={app} />
          <details :if={length(applications(node)) > @shown} class="group">
            <summary>{length(applications(node)) - @shown} more applications</summary>
            <.application :for={app <- Enum.drop(applications(node), @shown)} app={app} />
          </details>
        </div>
      </div>
    </section>

    <div :if={@runtime} class="card">
      <header>Agents by memory</header>
      <table class="list stack">
        <thead>
          <tr>
            <th>Agent</th><th>Node</th><th class="num">Memory</th><th class="num">Binaries</th>
            <th class="num">Mailbox</th><th class="num">Processes</th><th class="num">
              Work per second
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :for={agent <- @agents}>
            <td class="lead">
              <.link navigate={
                WardrikWeb.path(@dashboard, ["agents", agent["agent"]], %{
                  "conversation" => agent["conversation"]
                })
              }>
                {agent["agent"]}
              </.link>
              <div :if={agent["conversation"]} class="sub">{agent["conversation"]}</div>
            </td>
            <td data-label="Node" class="mono">{agent["node"]}</td>
            <td data-label="Memory" class="num">{bytes(agent["memory_bytes"])}</td>
            <td data-label="Binaries" class="num">{bytes(agent["binary_bytes"])}</td>
            <td data-label="Mailbox" class="num">{number(agent["message_queue"])}</td>
            <td data-label="Processes" class="num">{agent["processes"]}</td>
            <td data-label="Work per second" class="num" title="BEAM reductions per second">
              {rate(@rates[{agent["agent"], agent["conversation"]}])}
            </td>
          </tr>
        </tbody>
      </table>
      <div :if={@agents == []} class="empty">No agents are running.</div>
    </div>
    """
  end
end
