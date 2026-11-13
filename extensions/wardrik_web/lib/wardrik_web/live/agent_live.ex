defmodule WardrikWeb.AgentLive do
  @moduledoc false
  use Phoenix.LiveView

  import WardrikWeb.Components

  alias WardrikWeb.Follow

  @tabs [
    {"timeline", "Timeline"},
    {"runs", "Runs"},
    {"calls", "Running calls"},
    {"triggers", "Triggers"},
    {"definition", "Definition"},
    {"access", "Access"},
    {"events", "Events"}
  ]

  @impl true
  def mount(%{"agent" => agent} = params, _session, socket) do
    input =
      Map.reject(
        %{"agent" => agent, "conversation" => params["conversation"]},
        &is_nil(elem(&1, 1))
      )

    socket =
      socket
      |> assign(
        page_title: agent,
        agent: agent,
        conversation: params["conversation"],
        input: input
      )
      |> assign(tab: "timeline", read: nil, data: nil, drafts: %{}, error: nil)
      |> assign(runtime: nil, runtime_at: nil, work: nil)
      |> assign(:nodes, nodes(socket.assigns.scope))

    if connected?(socket), do: :timer.send_interval(5_000, :runtime)
    {:ok, runtime(socket)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in Enum.map(tabs(), &elem(&1, 0)), do: params["tab"], else: "timeline"
    socket = socket |> assign(:tab, tab) |> load()
    {:noreply, if(socket.assigns[:live] == nil, do: follow(socket), else: socket)}
  end

  defp follow(%{assigns: %{read: %{"cursor" => cursor}}} = socket),
    do: Follow.start(socket, "agent.events", Map.put(socket.assigns.input, "after", cursor))

  defp follow(socket), do: Follow.start(socket, "agent.events", socket.assigns.input)

  @impl true
  def handle_event("ask", %{"content" => content}, socket) do
    case String.trim(content) do
      "" -> {:noreply, socket}
      content -> {:noreply, act(socket, "agent.ask", %{"content" => content}, nil)}
    end
  end

  def handle_event("approve", %{"interrupt" => id} = params, socket) do
    input = put_present(%{"interrupt" => id}, "note", params["note"])
    {:noreply, act(socket, "agent.approve", input, "Approved.")}
  end

  def handle_event("deny", %{"interrupt" => id} = params, socket) do
    input = put_present(%{"interrupt" => id}, "reason", params["reason"])
    {:noreply, act(socket, "agent.deny", input, "Rejected.")}
  end

  def handle_event("move", %{"node" => node}, socket) when node != "",
    do: {:noreply, act(socket, "agent.move", %{"node" => node}, "Moving to #{node}.")}

  def handle_event("move", _params, socket), do: {:noreply, socket}

  def handle_event("forget", _params, socket) do
    case Wardrik.Scope.run(socket.assigns.scope, "agent.forget", %{
           "agent" => socket.assigns.agent
         }) do
      {:ok, _answer} ->
        {:noreply,
         socket
         |> put_flash(:info, "Deleted #{socket.assigns.agent}.")
         |> push_navigate(to: WardrikWeb.path(socket.assigns.dashboard, []))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  def handle_event("kill", %{"call" => call}, socket),
    do: {:noreply, act(socket, "agent.kill", %{"call" => call}, "Stopped the tool call.")}

  def handle_event(action, _params, socket) when action in ~w(cancel stop clear spawn) do
    done = %{
      "cancel" => "Cancelled.",
      "stop" => "Stopped.",
      "clear" => "Cleared.",
      "spawn" => "Started."
    }

    {:noreply, act(socket, "agent." <> action, %{}, done[action])}
  end

  @impl true
  def handle_info(:runtime, socket), do: {:noreply, runtime(socket)}

  def handle_info({WardrikWeb.Components, :flash, kind, message}, socket),
    do: {:noreply, put_flash(socket, kind, message)}

  def handle_info({Follow, _message} = message, socket),
    do: {:noreply, Follow.handle(message, socket, &load/1, on_event: &drafted/2)}

  defp act(socket, id, input, done) do
    case Wardrik.Scope.run(socket.assigns.scope, id, Map.merge(socket.assigns.input, input)) do
      {:ok, _answer} ->
        socket
        |> clear_flash()
        |> then(&if(done, do: put_flash(&1, :info, done), else: &1))
        |> load()

      {:error, error} ->
        put_flash(socket, :error, error.message)
    end
  end

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp drafted(
         %{
           "type" => "wardrik.message.delta",
           "data" => %{"message" => %{"id" => id}, "delta" => delta}
         },
         socket
       ),
       do: update(socket, :drafts, &Map.update(&1, id, delta, fn text -> text <> delta end))

  defp drafted(
         %{"type" => "wardrik.message.completed", "data" => %{"message" => %{"id" => id}}},
         socket
       ),
       do: update(socket, :drafts, &Map.delete(&1, id))

  defp drafted(_event, socket), do: socket

  defp load(socket) do
    scope = socket.assigns.scope

    with {:ok, read} <- Wardrik.Scope.run(scope, "agent.read", socket.assigns.input),
         {:ok, data} <- tab(scope, socket.assigns.tab, socket.assigns.input) do
      assign(socket, read: read, data: data, error: nil)
    else
      {:error, error} -> assign(socket, error: error.message)
    end
  end

  # Older servers don't have agent.runtime. A sleeping agent has no runtime.
  defp runtime(socket) do
    with %{} <- WardrikProtocol.operation("agent.runtime"),
         {:ok, runtime} <-
           Wardrik.Scope.run(socket.assigns.scope, "agent.runtime", socket.assigns.input) do
      now = System.monotonic_time(:millisecond)
      assign(socket, runtime: runtime, runtime_at: now, work: work(socket.assigns, runtime, now))
    else
      _none -> assign(socket, runtime: nil, work: nil)
    end
  end

  defp work(
         %{runtime: %{"reductions" => before}, runtime_at: at},
         %{"reductions" => now_count},
         now
       ),
       do: max(now_count - before, 0) * 1000 / max(now - at, 1)

  defp work(_assigns, _runtime, _now), do: nil

  defp tab(scope, "timeline", input), do: Wardrik.Scope.run(scope, "agent.timeline", input)
  defp tab(scope, "runs", input), do: Wardrik.Scope.run(scope, "agent.runs", input)
  defp tab(scope, "calls", input), do: Wardrik.Scope.run(scope, "agent.calls", input)

  # These tabs' components load the definition themselves.
  defp tab(_scope, tab, _input) when tab in ["definition", "triggers"], do: {:ok, nil}

  defp tab(scope, "events", input), do: newest(scope, input)

  defp tab(scope, "access", input),
    do: Wardrik.Scope.run(scope, "agent.resolved", Map.take(input, ["agent"]))

  # agent.events returns the oldest events first. Start from the cursor that events.head returns.
  defp newest(scope, input) do
    with {:ok, %{"events" => events}} <-
           Wardrik.Scope.run(scope, "agent.events", Map.put(input, "limit", 500)),
         do: {:ok, %{"events" => events |> Enum.take(-100) |> Enum.reverse()}}
  end

  # Show Move only when there's another node and the scope can list nodes.
  defp nodes(scope) do
    case Wardrik.Scope.run(scope, "deployment.nodes", %{}) do
      {:ok, %{"nodes" => nodes}} -> Enum.map(nodes, & &1["name"])
      {:error, _error} -> []
    end
  end

  # Older servers don't have agent.resolved.
  defp tabs do
    if WardrikProtocol.operation("agent.resolved"),
      do: @tabs,
      else: List.keydelete(@tabs, "access", 0)
  end

  defp tab_path(assigns, tab),
    do:
      WardrikWeb.path(assigns.dashboard, ["agents", assigns.agent], %{
        "conversation" => assigns.conversation,
        "tab" => if(tab == "timeline", do: nil, else: tab)
      })

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :tabs, tabs())

    ~H"""
    <.head title={@agent} lead={@conversation && "Conversation #{@conversation}"}>
      <:badge :if={@read}><.status value={@read["status"]} /></:badge>
      <:crumb><.link navigate={WardrikWeb.path(@dashboard, [])}>Agents</.link> /</:crumb>
      <:actions>
        <.live live={@live} stopped={@stopped} />
        <button :if={@read && @read["status"] == "running"} class="btn" phx-click="cancel">Cancel run</button>
        <button :if={@read && @read["status"] == "asleep"} class="btn" phx-click="spawn">Start</button>
        <button
          :if={@read && @read["status"] not in ["asleep", "unreadable"]}
          class="btn"
          phx-click="stop"
        >Stop</button>
        <button
          class="btn danger"
          phx-click="clear"
          data-confirm="Clear this agent's history? This can't be undone."
        >Clear history</button>
        <button
          :if={!@conversation}
          class="btn danger"
          phx-click="forget"
          data-confirm={"Delete #{@agent}? Its definition, history and triggers are deleted. This can't be undone."}
        >Delete</button>
      </:actions>
    </.head>

    <div :if={@error} class="flash error">{@error}</div>

    <nav class="tabs" aria-label="Agent">
      <.link :for={{tab, label} <- @tabs} patch={tab_path(assigns, tab)} class={tab == @tab && "on"}>{label}</.link>
    </nav>

    <div class="layout">
      <div>
        <.timeline :if={@tab == "timeline" && @data} items={@data["items"]} drafts={@drafts} />
        <form :if={@tab == "timeline"} class="composer" phx-submit="ask">
          <textarea
            name="content"
            placeholder="Send a message"
            aria-label="Message"
            phx-hook="SendOnEnter"
            id="composer"
          ></textarea>
          <button class="btn primary">Send</button>
        </form>
        <.runs :if={@tab == "runs" && @data} runs={@data["runs"]} totals={@data["totals"]} />
        <.calls :if={@tab == "calls" && @data} calls={@data["calls"]} />
        <.live_component
          :if={@tab == "definition"}
          module={WardrikWeb.DefinitionComponent}
          id="definition"
          scope={@scope}
          agent={@agent}
        />
        <.live_component
          :if={@tab == "triggers"}
          module={WardrikWeb.TriggersComponent}
          id="triggers"
          scope={@scope}
          agent={@agent}
        />
        <.events :if={@tab == "events" && @data} events={@data["events"]} />
        <.access :if={@tab == "access" && @data} access={@data} dashboard={@dashboard} />
      </div>

      <aside>
        <div :if={@read} class="card">
          <header>Now</header>
          <div class="body">
            <dl class="facts">
              <dt>Status</dt><dd><.status value={@read["status"]} /></dd>
              <%= if @read["problem"] do %>
                <dt>Problem</dt><dd>{@read["problem"]}. Define it again to start it over.</dd>
              <% end %>
              <dt>Queued</dt><dd>{@read["pending"]}</dd>
              <dt>Node</dt><dd class="mono">{@read["node"] || "—"}</dd>
              <dt>Next run</dt><dd>{ago(@read["next_run"])}</dd>
              <dt>Spent today</dt><dd>{usd(get_in(@read, ["spent_today", "usd"]))}</dd>
              <dt>Tokens today</dt><dd>{number(get_in(@read, ["spent_today", "tokens"]) || 0)}</dd>
              <%= if @runtime do %>
                <dt>Memory</dt><dd title="Memory of the agent's processes">
                  {bytes(@runtime["memory_bytes"])}
                </dd>
                <dt>Mailbox</dt><dd title="Messages waiting in the agent's mailbox">
                  {number(@runtime["message_queue"])}
                </dd>
                <dt>Processes</dt><dd title="The agent, its turn and its running tool calls">
                  {@runtime["processes"]}
                </dd>
                <dt>Work</dt><dd title="BEAM reductions per second">
                  {if @work, do: "#{number(round(@work))}/s", else: "—"}
                </dd>
              <% end %>
            </dl>
            <.doing :if={@read["activity"]} activity={@read["activity"]} />
            <form
              :if={length(@nodes) > 1 and !@conversation}
              id="move-form"
              class="move"
              phx-submit="move"
            >
              <select name="node" aria-label="Move to node">
                <option value="">Move to…</option>
                <option :for={node <- @nodes} :if={node != @read["node"]} value={node}>{node}</option>
              </select>
              <button class="btn small">Move</button>
            </form>
          </div>
        </div>
        <.panels
          dashboard={@dashboard}
          slot={:agent}
          scope={@scope}
          assigns={%{agent: @agent, conversation: @conversation, read: @read}}
        />
      </aside>
    </div>
    """
  end

  attr :activity, :map, required: true

  defp doing(assigns) do
    ~H"""
    <div class="doing">
      <div class="label">Doing</div>
      <ul>
        <li :if={(@activity["doing"] || []) == []} class="sub">
          Idle since {ago(@activity["since"])}
        </li>
        <li :for={item <- @activity["doing"] || []} title={item["type"]}>
          {doing_text(item)}
          <span :if={item["since"] || @activity["since"]} class="sub">
            · {ago(item["since"] || @activity["since"])}
          </span>
        </li>
      </ul>
    </div>
    """
  end

  attr :items, :list, required: true
  attr :drafts, :map, required: true

  defp timeline(assigns) do
    ~H"""
    <div class="timeline" id="timeline" phx-hook="FollowEnd">
      <div :if={@items == [] and @drafts == %{}} class="card empty">No messages yet.</div>
      <%= for item <- @items do %>
        <article :if={item["kind"] == "user"} class="msg user">
          <header><b>{item["sender"] || "user"}</b><span>{ago(item["at"])}</span></header>
          <div class="text">{item["text"]}</div>
        </article>
        <article :if={item["kind"] == "run"} class="msg">
          <header>
            <span><b>Run</b> <span :if={item["model"]} class="mono">{item["model"]}</span></span>
            <span class="actions">
              <span>{micro_usd(item["cost_micro_usd"])}</span>
              <span>{ago(item["started_at"])}</span>
              <.status value={item["status"]} />
            </span>
          </header>
          <.step :for={step <- item["steps"] || []} step={step} />
          <div :if={item["error"]} class="step">
            <span class="pill error">error</span> {item["error"]}
          </div>
          <.ask
            :for={interrupt <- item["interrupts"] || []}
            :if={item["status"] == "waiting"}
            interrupt={interrupt}
          />
        </article>
      <% end %>
      <article :for={{id, text} <- @drafts} class="msg" id={"draft-#{id}"}>
        <header><b>Generating…</b><span class="pill running">running</span></header>
        <div class="text">{text}</div>
      </article>
    </div>
    """
  end

  attr :step, :map, required: true

  defp step(%{step: %{"type" => type}} = assigns) when type in ["text", "thinking"] do
    ~H"""
    <div class={["step", @step["type"]]}>
      <div class="text">{@step["text"]}</div>
    </div>
    """
  end

  defp step(%{step: %{"type" => "tool"}} = assigns) do
    ~H"""
    <div class="step">
      <div class="tool">
        <span class="sub">tool</span><code>{@step["name"]}</code><.status value={@step["status"]} />
      </div>
      <div :if={@step["error"]} class="sub">{@step["error"]}</div>
      <details>
        <summary>Arguments and result</summary>
        <.json value={%{"arguments" => @step["arguments"], "result" => @step["result"]}} />
      </details>
    </div>
    """
  end

  defp step(assigns) do
    ~H"""
    <div class="step">
      <div class="tool">
        <span class="sub">delegate</span><code>{@step["name"] || "task"}</code><.status value={
          @step["status"]
        } /><span class="sub">{@step["tools"]} tool calls</span>
      </div>
      <div :if={@step["answer"]} class="text">{@step["answer"]}</div>
    </div>
    """
  end

  attr :interrupt, :map, required: true

  defp ask(assigns) do
    ~H"""
    <div class="ask">
      <div class="why">{@interrupt["message"] || "Approve #{@interrupt["name"]}?"}</div>
      <div class="sub">
        <code>{@interrupt["name"]}</code> · {@interrupt["reason"]}
        <span :for={label <- @interrupt["labels"] || []} class="tag">{label}</span>
      </div>
      <details :if={@interrupt["arguments"]}>
        <summary>Arguments</summary>
        <.json value={@interrupt["arguments"]} />
      </details>
      <form phx-submit="approve">
        <input type="hidden" name="interrupt" value={@interrupt["id"]} />
        <input type="text" name="note" placeholder="Note (optional)" aria-label="Note" />
        <button class="btn primary">Approve</button>
        <button
          class="btn danger"
          type="button"
          phx-click="deny"
          phx-value-interrupt={@interrupt["id"]}
        >Reject</button>
      </form>
    </div>
    """
  end

  attr :runs, :list, required: true
  attr :totals, :map, required: true

  defp runs(assigns) do
    ~H"""
    <div class="stats">
      <div class="stat">
        <b>{micro_usd(@totals["cost_micro_usd"])}</b><span>spent</span>
      </div>
      <div class="stat">
        <b>{number(@totals["runs"])}</b>
        <span>runs<span :if={@totals["failed"] > 0} class="bad"> · {@totals["failed"]} failed</span></span>
      </div>
      <div class="stat"><b>{number(@totals["tool_calls"])}</b><span>tool calls</span></div>
      <div class="stat">
        <b title={"#{number(@totals["input_tokens"])} in, #{number(@totals["output_tokens"])} out"}>
          {tokens(@totals["input_tokens"] + @totals["output_tokens"])}
        </b>
        <span>tokens</span>
      </div>
      <div class="stat">
        <b title={@totals["last_at"]}>{ago(@totals["last_at"])}</b><span>last run</span>
      </div>
    </div>
    <div class="card">
      <table class="list stack">
        <thead>
          <tr>
            <th>Started</th>
            <th>Status</th>
            <th class="num">Tool calls</th>
            <th class="num">Tokens</th>
            <th class="num">Cost</th>
            <th class="num">Took</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={run <- @runs}>
            <td class="lead" title={run["started_at"]}>
              <span class="when">{ago(run["started_at"])}</span>
              <div class="sub">
                <code :if={run["model"]}>{run["model"]}</code>
                <span :if={run["source"]}> · from {run["source"]}</span>
              </div>
            </td>
            <td data-label="Status">
              <.status value={run["status"]} />
              <div :if={run["error"]} class="sub bad">{run["error"]}</div>
            </td>
            <td class="num" data-label="Tool calls">
              {number(run["tool_calls"])}
              <div :if={run["tool_errors"] > 0} class="sub bad">{run["tool_errors"]} failed</div>
            </td>
            <td
              class="num"
              data-label="Tokens"
              title={"#{number(run["input_tokens"])} in, #{number(run["output_tokens"])} out"}
            >
              {tokens(run["input_tokens"] + run["output_tokens"])}
              <div class="sub">
                {tokens(run["input_tokens"])} in · {tokens(run["output_tokens"])} out
              </div>
            </td>
            <td class="num" data-label="Cost">{micro_usd(run["cost_micro_usd"])}</td>
            <td
              class="num"
              data-label="Took"
              title={run["duration_ms"] && "#{number(run["duration_ms"])} ms"}
            >
              {took(run["duration_ms"])}
            </td>
          </tr>
        </tbody>
      </table>
      <div :if={@runs == []} class="empty">No runs yet.</div>
    </div>
    """
  end

  attr :access, :map, required: true
  attr :dashboard, :any, required: true

  defp access(assigns) do
    ~H"""
    <p class="note">
      What your app gives this agent. Your app decides this each time the agent runs.
    </p>

    <div class="card">
      <header>Works for</header>
      <div class="body">
        <code :if={@access["principal"]}>{@access["principal"]["id"]}</code>
        <span :if={!@access["principal"]}>No one. The agent has no credentials.</span>
      </div>
    </div>

    <div class="card">
      <header>MCP servers</header>
      <table :if={@access["servers"] != []} class="list stack">
        <thead>
          <tr>
            <th>Name</th><th>Server</th><th>Tools</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={server <- @access["servers"]}>
            <td class="lead"><code>{server["name"]}</code></td>
            <td data-label="Server" class="mono">{server["server"]}</td>
            <td data-label="Tools">
              <span
                :if={server["tools"] == []}
                class="pill failed"
                title="The server is down or hasn't listed its tools yet."
              >
                no tools now
              </span>
              <details :if={server["tools"] != []}>
                <summary>{length(server["tools"])} tools</summary>
                <ul class="plain">
                  <li :for={tool <- server["tools"]} class="mono">{tool}</li>
                </ul>
              </details>
            </td>
          </tr>
        </tbody>
      </table>
      <div :if={@access["servers"] == []} class="empty">No MCP servers.</div>
    </div>

    <div class="card">
      <header>Policies</header>
      <div class="body">
        <p :if={rules(@access["policy"]) == []} class="sub">
          Your app sets no policy for this agent.
        </p>
        <.json :for={policy <- rules(@access["policy"])} value={policy} />
        <details :for={{name, policy} <- Enum.sort(@access["policies"])} class="group">
          <summary>Named policy <code>{name}</code></summary>
          <.json value={policy} />
        </details>
      </div>
    </div>

    <div class="card">
      <header>Notify targets</header>
      <table :if={@access["notify"] != []} class="list">
        <tbody>
          <tr :for={target <- @access["notify"]}>
            <td class="lead"><code>{target["name"]}</code></td>
            <td>{target["target"] || "Sent by your app"}</td>
          </tr>
        </tbody>
      </table>
      <div :if={@access["notify"] == []} class="empty">No notify targets.</div>
    </div>

    <div :if={@access["channels"] != %{} or @access["workspaces"] != %{}} class="card">
      <header>Channels and workspaces</header>
      <div class="body">
        <dl class="facts">
          <%= for {channel, workspace} <- Enum.sort(@access["channels"]) do %>
            <dt>Channel {channel}</dt><dd class="mono">{workspace}</dd>
          <% end %>
          <%= for {agent, mode} <- Enum.sort(@access["workspaces"]) do %>
            <dt>Workspace</dt>
            <dd>
              <.link navigate={WardrikWeb.path(@dashboard, ["agents", agent])}>{agent}</.link>
              <span class="sub">{if mode == "write", do: "read and write", else: "read only"}</span>
            </dd>
          <% end %>
        </dl>
      </div>
    </div>

    <div :if={@access["defaults"] != %{}} class="card">
      <header>Defaults</header>
      <div class="body"><.json value={@access["defaults"]} /></div>
    </div>
    """
  end

  # A policy with no rules encodes as %{}.
  defp rules(policies), do: Enum.reject(policies, &(&1 == %{}))

  attr :calls, :list, required: true

  defp calls(assigns) do
    ~H"""
    <div class="card">
      <table class="list">
        <thead>
          <tr>
            <th>Call</th><th>Tool</th><th class="num">Running for</th><th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={call <- @calls}>
            <td class="mono">{call["id"]}</td>
            <td class="mono">{call["name"]}</td>
            <td class="num">{Float.round(call["elapsed_ms"] / 1000, 1)}s</td>
            <td class="num">
              <button class="btn small danger" phx-click="kill" phx-value-call={call["id"]}>Stop call</button>
            </td>
          </tr>
        </tbody>
      </table>
      <div :if={@calls == []} class="empty">No tool call is running.</div>
    </div>
    """
  end
end
