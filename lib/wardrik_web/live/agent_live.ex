defmodule WardrikWeb.AgentLive do
  @moduledoc false
  use Phoenix.LiveView

  import WardrikWeb.Components

  alias WardrikWeb.Follow

  @tabs [
    {"timeline", "Timeline"},
    {"runs", "Runs"},
    {"calls", "Running calls"},
    {"definition", "Definition"},
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

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in Enum.map(@tabs, &elem(&1, 0)), do: params["tab"], else: "timeline"
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

  def handle_event("kill", %{"call" => call}, socket),
    do: {:noreply, act(socket, "agent.kill", %{"call" => call}, "Stopped the call.")}

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

  defp tab(scope, "timeline", input), do: Wardrik.Scope.run(scope, "agent.timeline", input)
  defp tab(scope, "runs", input), do: Wardrik.Scope.run(scope, "agent.runs", input)
  defp tab(scope, "calls", input), do: Wardrik.Scope.run(scope, "agent.calls", input)

  defp tab(scope, "definition", input),
    do: Wardrik.Scope.run(scope, "agent.definition", Map.take(input, ["agent"]))

  defp tab(scope, "events", input), do: newest(scope, input)

  # agent.events pages oldest first; the newest page is the one events.head points past.
  defp newest(scope, input) do
    with {:ok, %{"events" => events}} <-
           Wardrik.Scope.run(scope, "agent.events", Map.put(input, "limit", 500)),
         do: {:ok, %{"events" => events |> Enum.take(-100) |> Enum.reverse()}}
  end

  defp tab_path(assigns, tab),
    do:
      WardrikWeb.path(assigns.dashboard, ["agents", assigns.agent], %{
        "conversation" => assigns.conversation,
        "tab" => if(tab == "timeline", do: nil, else: tab)
      })

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :tabs, @tabs)

    ~H"""
    <.head title={@agent} lead={@conversation && "Conversation #{@conversation}"}>
      <:crumb><.link navigate={WardrikWeb.path(@dashboard, [])}>Agents</.link> /</:crumb>
      <:actions>
        <.live live={@live} stopped={@stopped} />
        <.status :if={@read} value={@read["status"]} />
        <button :if={@read && @read["status"] == "running"} class="btn" phx-click="cancel">Cancel run</button>
        <button :if={@read && @read["status"] == "asleep"} class="btn" phx-click="spawn">Start</button>
        <button :if={@read && @read["status"] != "asleep"} class="btn" phx-click="stop">Stop</button>
        <button
          class="btn danger"
          phx-click="clear"
          data-confirm="Clear this agent's history? It can't be undone."
        >Clear history</button>
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
        <div :if={@tab == "definition" && @data} class="card">
          <header>
            Definition
            <span :if={@data["missing"] != []} class="sub">missing: {Enum.join(
              @data["missing"] || [],
              ", "
            )}</span>
          </header>
          <div class="body"><.json value={@data["definition"]} /></div>
        </div>
        <.events :if={@tab == "events" && @data} events={@data["events"]} />
      </div>

      <aside>
        <div :if={@read} class="card">
          <header>Now</header>
          <div class="body">
            <dl class="facts">
              <dt>Status</dt><dd><.status value={@read["status"]} /></dd>
              <dt>Waiting</dt><dd>{@read["pending"]}</dd>
              <dt>Node</dt><dd class="mono">{@read["node"] || "—"}</dd>
              <dt>Next run</dt><dd>{ago(@read["next_run"])}</dd>
              <dt>Spent today</dt><dd>{usd(get_in(@read, ["spent_today", "usd"]))}</dd>
              <dt>Tokens today</dt><dd>{get_in(@read, ["spent_today", "tokens"]) || 0}</dd>
            </dl>
            <details :if={@read["activity"]} style="margin-top: 12px">
              <summary>Activity</summary>
              <.json value={@read["activity"]} />
            </details>
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
        <header><b>Writing…</b><span class="pill running">running</span></header>
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
      <div :for={{key, value} <- @totals || %{}} class="stat">
        <b>{if key == "cost_micro_usd", do: micro_usd(value), else: value}</b><span>{String.replace(
          key,
          "_",
          " "
        )}</span>
      </div>
    </div>
    <div class="card">
      <table class="list">
        <thead>
          <tr>
            <th>Started</th><th>Status</th><th class="wide">Model</th><th class="num">Tools</th><th class="num">
              Tokens in / out
            </th><th class="num">Cost</th><th class="num">Took</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={run <- @runs}>
            <td>
              {ago(run["started_at"])}
              <div :if={run["source"]} class="sub">{run["source"]}</div>
            </td>
            <td>
              <.status value={run["status"]} /><div :if={run["error"]} class="sub">
                {run["error"]}
              </div>
            </td>
            <td class="wide mono">{run["model"] || "—"}</td>
            <td class="num">
              {run["tool_calls"]}<span :if={run["tool_errors"] > 0} class="sub"> ({run["tool_errors"]} failed)</span>
            </td>
            <td class="num">{run["input_tokens"]} / {run["output_tokens"]}</td>
            <td class="num">{micro_usd(run["cost_micro_usd"])}</td>
            <td class="num">
              {if run["duration_ms"], do: "#{Float.round(run["duration_ms"] / 1000, 1)}s", else: "—"}
            </td>
          </tr>
        </tbody>
      </table>
      <div :if={@runs == []} class="empty">No runs yet.</div>
    </div>
    """
  end

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

  attr :events, :list, required: true

  defp events(assigns) do
    ~H"""
    <div class="card">
      <table class="list">
        <thead>
          <tr>
            <th>Time</th><th>Type</th><th>Data</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={event <- @events}>
            <td class="sub" title={event["time"]}>{ago(event["time"])}</td>
            <td class="mono">{String.replace_prefix(event["type"], "wardrik.", "")}</td>
            <td>
              <details>
                <summary>data</summary><.json value={event["data"]} />
              </details>
            </td>
          </tr>
        </tbody>
      </table>
      <div :if={@events == []} class="empty">No events.</div>
    </div>
    """
  end
end
