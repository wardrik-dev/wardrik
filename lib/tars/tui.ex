defmodule Tars.TUI do
  @moduledoc """
  A terminal client for one agent.

  It is an ordinary `Tars.Event.Bus` subscriber. It holds no conversation
  state and never talks to the turn loop, so several can watch the same agent.

  The transcript is append-only. The answer is rendered a line at a time as it
  streams, and every span the turn opens prints one line when it starts and one
  when it ends, indented by its depth — so a fan-out reads as a tree in
  scrollback without anything being repainted.

  One line is live: a status line on the terminal's bottom row, naming the
  innermost work in flight and how long it has been going. It is drawn where
  nothing else can reach, so it never overwrites a line being typed.

  `/stop` reaches `Tars.Agent.interrupt/1`, which is a control path rather than
  a message: it never enters the conversation, so stopping does not depend on a
  model reading the word.

  `verbose: true` adds a trace line for the lower-level events — model
  requests, tool calls, metadata — and commits the model's reasoning to the
  transcript rather than leaving it on the status line.

  Reading input blocks, so it happens in a separate reader process. That reader
  never stops reading: a line typed while a turn is running is handed to the
  agent like any other, and the agent decides whether it starts a turn or joins
  the one in flight.
  """
  use GenServer

  alias Tars.Agent
  alias Tars.Event
  alias Tars.TUI.Activity
  alias Tars.TUI.Markdown
  alias Tars.TUI.View

  @tick 100

  defstruct [
    :agent,
    :agent_id,
    :screen,
    :reader,
    :width,
    :rows,
    :verbose?,
    activity: nil,
    answer: nil,
    reasoning: nil,
    frame: 0,
    chars: 0,
    ticking?: false
  ]

  def start_link(opts) do
    {server_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  @typedoc "How a line typed at the prompt is interpreted."
  @type command() :: :blank | :quit | :stop | {:ask, String.t()}

  @doc """
  Interpret one line of input.

  Pure, so the prompt's vocabulary can be tested without a terminal.
  """
  @spec command(String.t()) :: command()
  def command(line) do
    case String.trim(line) do
      "" -> :blank
      slash when slash in ["/quit", "/exit"] -> :quit
      "/stop" -> :stop
      text -> {:ask, text}
    end
  end

  @impl true
  def init(opts) do
    agent = Keyword.fetch!(opts, :agent)
    agent_id = Keyword.get(opts, :agent_id, agent)
    screen = Keyword.get(opts, :screen, Tars.TUI.Screen.Terminal)

    # Trapping exits does two jobs: `terminate/2` actually runs on shutdown so
    # the reader is cleaned up, and a reader that dies (stdin closed) arrives
    # as a message rather than taking the TUI down with it.
    Process.flag(:trap_exit, true)
    :ok = Event.Bus.subscribe(agent_id)
    :ok = screen.open(Keyword.get(opts, :rows))

    state = %__MODULE__{
      agent: agent,
      agent_id: agent_id,
      screen: screen,
      width: Keyword.get(opts, :width, 100),
      rows: Keyword.get(opts, :rows),
      verbose?: Keyword.get(opts, :verbose, false),
      reader: reader(opts)
    }

    screen.write(View.banner(Keyword.get(opts, :model, ""), state.verbose?, geometry(state)))

    {:ok, prompt(clear(state))}
  end

  defp geometry(%{width: width, rows: nil}), do: "#{width}x?"
  defp geometry(%{width: width, rows: rows}), do: "#{width}x#{rows}"

  # -- input -----------------------------------------------------------------

  @impl true
  def handle_info({:input, text}, state) do
    :ok = Agent.ask(state.agent, text)

    {:noreply, echo(state, text)}
  end

  def handle_info(:stop, state) do
    :ok = Agent.interrupt(state.agent)
    {:noreply, state}
  end

  def handle_info(:quit, state), do: {:stop, :normal, state}

  # -- published events ------------------------------------------------------

  # Every event is folded, whatever span it came from: the tree is the point.
  def handle_info(%Event{} = event, state) do
    handle_event(event, fold(state, event))
  end

  def handle_info(:tick, %{ticking?: true} = state) do
    state = %{state | frame: state.frame + 1}
    {:noreply, refresh_status(schedule_tick(state))}
  end

  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.reader), do: Process.exit(state.reader, :kill)
    state.screen.close(state.rows)
    :ok
  end

  # -- turn lifecycle --------------------------------------------------------

  defp handle_event(%Event{payload: {:turn_started, _questions}} = event, state) do
    trace(state, event)
    {:noreply, start_ticking(state)}
  end

  defp handle_event(%Event{payload: {:turn_finished, _messages}} = event, state) do
    state = state |> settle() |> stop_ticking()
    trace(state, event)
    state.screen.write("\n")
    {:noreply, prompt(state)}
  end

  defp handle_event(%Event{payload: {:turn_interrupted, stats}} = event, state) do
    state = state |> settle() |> stop_ticking()
    trace(state, event)
    state.screen.write(View.interrupted(stats))

    {:noreply, prompt(state)}
  end

  defp handle_event(%Event{payload: {:turn_failed, reason}} = event, state) do
    state = state |> settle() |> stop_ticking()
    trace(state, event)
    state.screen.write(View.error(reason))
    {:noreply, prompt(state)}
  end

  # -- the tree --------------------------------------------------------------

  defp handle_event(%Event{payload: {:span_started, _name}} = event, state) do
    {:noreply, write_span(state, event)}
  end

  defp handle_event(%Event{payload: {:span_finished, _outcome, _ms}} = event, state) do
    {:noreply, write_span(state, event)}
  end

  # -- streaming -------------------------------------------------------------

  defp handle_event(%Event{payload: {:result, text}}, state) do
    {lines, answer} = Markdown.push(state.answer, text)
    state = %{state | answer: answer, chars: state.chars + String.length(text)}

    write_lines(state, lines, &View.answer/1)

    {:noreply, refresh_status(state)}
  end

  defp handle_event(%Event{payload: {:thinking, text}}, state) do
    {lines, reasoning} = Markdown.push(state.reasoning, text)
    state = %{state | reasoning: reasoning}

    if state.verbose?, do: write_lines(state, lines, &View.reasoning/1)

    {:noreply, refresh_status(state)}
  end

  # -- everything else, only interesting when tracing -------------------------

  defp handle_event(%Event{} = event, state) do
    trace(state, event)
    {:noreply, refresh_status(state)}
  end

  # -- output ----------------------------------------------------------------

  # A turn starts a fresh tree: the previous turn's spans are history.
  defp fold(state, %Event{payload: {:turn_started, _questions}} = event) do
    state = clear(state)
    %{state | activity: Activity.fold(state.activity, event, now: now())}
  end

  defp fold(state, event) do
    %{state | activity: Activity.fold(state.activity, event, now: now())}
  end

  defp write_span(state, %Event{source: source}) do
    span = Activity.fetch(state.activity, source.trace.span_id)
    depth = Activity.depth(state.activity, source.trace.span_id)

    state.screen.clear_status(state.rows)
    state.screen.write(View.span(span, depth, now(), state.width))

    refresh_status(state)
  end

  # Only while a turn is running. Idle input is echoed by the terminal itself
  # and answered immediately; a steering line is not, and would otherwise
  # vanish into the turn with nothing to show it was taken.
  defp echo(%{ticking?: false} = state, _text), do: state

  defp echo(state, text) do
    state.screen.clear_status(state.rows)
    state.screen.write(View.steer(text, state.width))

    refresh_status(state)
  end

  defp write_lines(_state, [], _render), do: :ok

  defp write_lines(state, lines, render) do
    state.screen.clear_status(state.rows)
    state.screen.write(Enum.map(lines, render))
  end

  defp trace(%{verbose?: true} = state, %Event{payload: payload}) do
    case View.trace(payload) do
      nil ->
        :ok

      line ->
        state.screen.clear_status(state.rows)
        state.screen.write(line)
    end
  end

  defp trace(_state, _event), do: :ok

  # Whatever never got its newline still belongs on the screen.
  defp settle(state) do
    {answer, _buffer} = Markdown.flush(state.answer)
    {reasoning, _buffer} = Markdown.flush(state.reasoning)

    if state.verbose?, do: write_lines(state, reasoning, &View.reasoning/1)
    write_lines(state, answer, &View.answer/1)

    state
  end

  defp clear(state) do
    %{
      state
      | activity: Activity.new(),
        answer: Markdown.new(),
        reasoning: Markdown.new(),
        chars: 0
    }
  end

  defp refresh_status(%{ticking?: false} = state), do: state

  defp refresh_status(state) do
    state.screen.status(View.status(status_state(state), state.width), state.rows)
    state
  end

  defp status_state(state) do
    %{
      frame: state.frame,
      activity: state.activity,
      thinking: Markdown.tail(state.reasoning),
      chars: state.chars,
      now: now()
    }
  end

  defp start_ticking(state) do
    state = %{state | ticking?: true, frame: 0}
    refresh_status(schedule_tick(state))
  end

  defp stop_ticking(%{ticking?: false} = state), do: state

  defp stop_ticking(state) do
    state.screen.clear_status(state.rows)
    %{state | ticking?: false}
  end

  defp schedule_tick(state) do
    Process.send_after(self(), :tick, @tick)
    state
  end

  defp prompt(%{reader: reader} = state) when is_pid(reader) do
    state.screen.write(View.prompt())
    state
  end

  defp prompt(state), do: state

  defp now, do: System.monotonic_time(:millisecond)

  # -- input reader ----------------------------------------------------------

  # An explicit `reader: nil` means "no input" — used by tests, which drive the
  # TUI from events alone.
  defp reader(opts) do
    case Keyword.fetch(opts, :reader) do
      {:ok, reader} -> reader
      :error -> spawn_reader()
    end
  end

  defp spawn_reader do
    tui = self()
    spawn_link(fn -> reader_loop(tui) end)
  end

  defp reader_loop(tui) do
    case IO.gets("") do
      line when is_binary(line) -> dispatch(tui, command(line))
      _eof_or_error -> send(tui, :quit)
    end

    reader_loop(tui)
  end

  defp dispatch(_tui, :blank), do: :ok
  defp dispatch(tui, :quit), do: send(tui, :quit)
  defp dispatch(tui, :stop), do: send(tui, :stop)
  defp dispatch(tui, {:ask, text}), do: send(tui, {:input, text})
end
