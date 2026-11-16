defmodule WardrikWeb.Timeline do
  @moduledoc """
  An agent's conversation as people read it: the messages, each run's text and tool calls, the
  calls that wait on a person, and the answer as it streams in. The agent page and the chat page
  both show it.

  A page that shows it assigns `:scope`, `:input` (the agent and conversation) and `:drafts`, and
  passes its events here:

      def handle_event(event, params, socket) when event in ~w(ask approve deny),
        do: {:noreply, WardrikWeb.Timeline.handle_event(event, params, socket, &load/1)}

      def handle_info({WardrikWeb.Follow, _message} = message, socket),
        do: {:noreply, WardrikWeb.Follow.handle(message, socket, &load/1, on_event: &WardrikWeb.Timeline.drafted/2)}
  """

  use Phoenix.Component

  import Phoenix.LiveView, only: [clear_flash: 1, push_event: 3, put_flash: 3]
  import WardrikWeb.Components

  @markdown [
    extension: [strikethrough: true, table: true, autolink: true, tasklist: true],
    render: [hardbreaks: true],
    sanitize: MDEx.Document.default_sanitize_options()
  ]

  @doc """
  Runs the page's `"ask"`, `"approve"` or `"deny"` event on the agent, then calls `reload` with
  the socket. An error goes to the flash.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t(), (term() -> term())) ::
          Phoenix.LiveView.Socket.t()
  def handle_event("ask", %{"content" => content}, socket, reload) do
    case String.trim(content) do
      "" -> socket
      content -> act(socket, "agent.ask", %{"content" => content}, nil, &sent(&1, reload))
    end
  end

  def handle_event("approve", %{"interrupt" => id} = params, socket, reload) do
    input = put_present(%{"interrupt" => id}, "note", params["note"])
    act(socket, "agent.approve", input, "Approved.", reload)
  end

  def handle_event("deny", %{"interrupt" => id} = params, socket, reload) do
    input = put_present(%{"interrupt" => id}, "reason", params["reason"])
    act(socket, "agent.deny", input, "Rejected.", reload)
  end

  # A message that fails to send stays in the composer.
  defp sent(socket, reload) do
    socket
    |> push_event("composer:sent", %{})
    |> reload.()
  end

  @doc """
  Runs operation `id` on the page's agent with `input`. Says `done` in the flash, unless it's
  `nil`, and calls `reload` with the socket. An error goes to the flash.
  """
  @spec act(Phoenix.LiveView.Socket.t(), String.t(), map(), String.t() | nil, (term() -> term())) ::
          Phoenix.LiveView.Socket.t()
  def act(socket, id, input, done, reload) do
    case Wardrik.Scope.run(socket.assigns.scope, id, Map.merge(socket.assigns.input, input)) do
      {:ok, _answer} ->
        socket
        |> clear_flash()
        |> then(&if(done, do: put_flash(&1, :info, done), else: &1))
        |> reload.()

      {:error, error} ->
        put_flash(socket, :error, error.message)
    end
  end

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  @doc "Adds a streamed piece of an answer to `:drafts`, and drops the answer once it's complete."
  @spec drafted(map(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def drafted(
        %{
          "type" => "wardrik.message.delta",
          "data" => %{"message" => %{"id" => id}, "delta" => delta}
        },
        socket
      ),
      do: update(socket, :drafts, &Map.update(&1, id, delta, fn text -> text <> delta end))

  def drafted(
        %{"type" => "wardrik.message.completed", "data" => %{"message" => %{"id" => id}}},
        socket
      ),
      do: update(socket, :drafts, &Map.delete(&1, id))

  def drafted(_event, socket), do: socket

  @doc """
  The conversation, oldest first, with the answers being written at its end.

  `chat` shows it as a chat: no run headers, costs or models, and thinking folded away.
  """
  attr :items, :list, required: true
  attr :drafts, :map, required: true
  attr :chat, :boolean, default: false
  attr :empty, :string, default: "No messages yet."

  attr :doing, :map,
    default: nil,
    doc: "The agent's activity while a run goes, as `agent.read` gives it. Shown at the end."

  @spec timeline(map()) :: Phoenix.LiveView.Rendered.t()
  def timeline(assigns) do
    ~H"""
    <div class={["timeline", @chat && "chat"]} id="timeline" phx-hook="FollowEnd">
      <div :if={@items == [] and @drafts == %{}} class="card empty">{@empty}</div>
      <%= for item <- @items do %>
        <article :if={item["kind"] == "user"} class="msg user">
          <header :if={!@chat}>
            <b>{item["sender"] || "user"}</b><span>{ago(item["at"])}</span>
          </header>
          <div class="text">{item["text"]}</div>
        </article>
        <article :if={item["kind"] == "run"} class="msg">
          <header :if={!@chat}>
            <span><b>Run</b> <span :if={item["model"]} class="mono">{item["model"]}</span></span>
            <span class="actions">
              <span>{micro_usd(item["cost_micro_usd"])}</span>
              <span>{ago(item["started_at"])}</span>
              <.status value={item["status"]} />
            </span>
          </header>
          <.step :for={step <- item["steps"] || []} step={step} chat={@chat} />
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
        <header :if={!@chat}><b>Generating…</b><span class="pill running">running</span></header>
        <div class="step"><.markdown text={text} /></div>
      </article>
      <.working :if={@doing} doing={@doing} />
    </div>
    """
  end

  attr :doing, :map, required: true

  # A line saying what the agent does now, with how long it has been at it.
  defp working(assigns) do
    assigns = assign(assigns, :label, working_label(assigns.doing["doing"] || []))

    ~H"""
    <div class="working" role="status">
      <span class="dots" aria-hidden="true"><i></i><i></i><i></i></span>
      <span>{@label}</span>
      <span
        :if={@doing["since"]}
        class="sub"
        id="working-elapsed"
        phx-hook="Elapsed"
        phx-update="ignore"
        data-since={@doing["since"]}
      ></span>
    </div>
    """
  end

  @running ~w(wardrik.tool_call.started wardrik.tool_call.retrying)

  defp working_label(doing) do
    case Enum.filter(doing, &(&1["type"] in @running)) do
      [] -> step_label(List.last(doing))
      calls -> "Using " <> Enum.map_join(calls, ", ", &tool_name(&1["tool"]["name"]))
    end
  end

  defp step_label(%{"type" => "wardrik.message.retrying"}), do: "Trying the model again"
  defp step_label(%{"type" => "wardrik.message.started"}), do: "Thinking"
  defp step_label(_step), do: "Working"

  @doc """
  The name a person reads for tool `name`: an MCP tool's `server__tool` as `server/tool`, as
  policies name it.
  """
  @spec tool_name(String.t() | nil) :: String.t()
  def tool_name(nil), do: "a tool"
  def tool_name(name), do: String.replace(name, "__", "/", global: false)

  @doc "The box to write a message in. Enter sends it; Shift+Enter starts a new line. It empties once the message is sent."
  attr :placeholder, :string, default: "Send a message"

  @spec composer(map()) :: Phoenix.LiveView.Rendered.t()
  def composer(assigns) do
    ~H"""
    <form class="composer" phx-submit="ask">
      <textarea
        name="content"
        placeholder={@placeholder}
        aria-label="Message"
        phx-hook="SendOnEnter"
        id="composer"
      ></textarea>
      <button class="btn primary">Send</button>
    </form>
    """
  end

  @doc "Markdown, as HTML. Raw HTML and unsafe links in it are dropped."
  attr :text, :string, required: true

  @spec markdown(map()) :: Phoenix.LiveView.Rendered.t()
  def markdown(assigns) do
    assigns = assign(assigns, :html, MDEx.to_html!(assigns.text, @markdown))

    ~H"""
    <div class="text md">{Phoenix.HTML.raw(@html)}</div>
    """
  end

  attr :step, :map, required: true
  attr :chat, :boolean, required: true

  defp step(%{step: %{"type" => "text"}} = assigns) do
    ~H"""
    <div class="step"><.markdown text={@step["text"]} /></div>
    """
  end

  defp step(%{step: %{"type" => "thinking"}, chat: true} = assigns) do
    ~H"""
    <details class="step thinking">
      <summary>Thinking</summary>
      <div class="text">{@step["text"]}</div>
    </details>
    """
  end

  defp step(%{step: %{"type" => "thinking"}} = assigns) do
    ~H"""
    <div class="step thinking">
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

  # Arguments a person can read at a glance: a few short values, none of them nested.
  defp plain?(arguments) when is_map(arguments) and map_size(arguments) in 1..6,
    do: Enum.all?(arguments, fn {_key, value} -> short?(value) end)

  defp plain?(_arguments), do: false

  defp short?(value) when is_binary(value), do: String.length(value) <= 300
  defp short?(value), do: is_number(value) or is_boolean(value)

  attr :interrupt, :map, required: true

  defp ask(assigns) do
    ~H"""
    <div class="ask">
      <div class="why">
        {@interrupt["message"] || "Allow #{tool_name(@interrupt["name"])}?"}
      </div>
      <div class="sub">
        Waiting for your approval to use <code>{tool_name(@interrupt["name"])}</code>.
        <span :for={label <- @interrupt["labels"] || []} class="tag">{label}</span>
      </div>
      <dl :if={plain?(@interrupt["arguments"])} class="args">
        <%= for {key, value} <- @interrupt["arguments"] do %>
          <dt>{key}</dt>
          <dd><code>{value}</code></dd>
        <% end %>
      </dl>
      <details :if={@interrupt["arguments"] && !plain?(@interrupt["arguments"])}>
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
end
