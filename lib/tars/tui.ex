defmodule Tars.TUI do
  @moduledoc """
  A terminal client for one agent.

  It is an ordinary `Tars.Events` subscriber — it holds no conversation state
  and never talks to the turn loop, so several can watch the same agent.

  Two modes over the same event stream. By default it reads as a chat: the
  answer streams out as plain text, with progress on a single status line that
  is erased before any real output.

  With `verbose: true` the structural events — turn boundaries, tool calls,
  metadata — each get a trace line, while token-level events are accumulated
  into the status line's counters. A turn emits hundreds of `:chunk` and
  `:result` messages, so printing them is what makes a trace unreadable.

  Reading input blocks, so it happens in a separate reader process, and the
  reader only prompts while the agent is idle. Typing during a turn is not
  possible yet — that lands with interruption.
  """
  use GenServer

  alias Tars.Agent
  alias Tars.Events
  alias Tars.TUI.View

  @tick 100

  defstruct [
    :agent,
    :agent_id,
    :screen,
    :reader,
    :width,
    :verbose?,
    thinking: "",
    tools: [],
    frame: 0,
    chunks: 0,
    chars: 0,
    ticking?: false
  ]

  def start_link(opts) do
    {server_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  @typedoc "How a line typed at the prompt is interpreted."
  @type command() :: :blank | :quit | {:ask, String.t()}

  @doc """
  Interpret one line of input.

  Pure, so the prompt's vocabulary can be tested without a terminal.
  """
  @spec command(String.t()) :: command()
  def command(line) do
    case String.trim(line) do
      "" -> :blank
      slash when slash in ["/quit", "/exit"] -> :quit
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
    :ok = Events.subscribe(agent_id)

    state = %__MODULE__{
      agent: agent,
      agent_id: agent_id,
      screen: screen,
      width: Keyword.get(opts, :width, 100),
      verbose?: Keyword.get(opts, :verbose, false),
      reader: reader(opts)
    }

    screen.write(View.banner(Keyword.get(opts, :model, ""), state.verbose?))

    {:ok, prompt(state)}
  end

  # -- input -----------------------------------------------------------------

  @impl true
  def handle_info({:input, text}, state) do
    Agent.ask(state.agent, text)
    {:noreply, state}
  end

  def handle_info(:quit, state), do: {:stop, :normal, state}

  # -- turn lifecycle --------------------------------------------------------

  def handle_info({:turn_started, _questions} = event, state) do
    state = %{state | thinking: "", tools: [], chunks: 0, chars: 0}
    trace(state, event)
    {:noreply, start_ticking(state)}
  end

  def handle_info({:turn_finished, _messages} = event, state) do
    state = finish_stream(state)
    trace(state, event)
    unless state.verbose?, do: state.screen.write("\n")
    {:noreply, prompt(state)}
  end

  def handle_info({:turn_failed, reason} = event, state) do
    state = finish_stream(state)
    trace(state, event)
    unless state.verbose?, do: state.screen.write(View.error(reason))
    {:noreply, prompt(state)}
  end

  # -- streaming -------------------------------------------------------------

  def handle_info({:thinking, text} = event, state) do
    state = %{state | thinking: state.thinking <> text}
    trace(state, event)
    {:noreply, refresh_status(state)}
  end

  # In chat mode the answer arriving is itself the progress indicator, so the
  # status line steps aside for good once text starts. In verbose mode nothing
  # else is being written per token, so the counters keep ticking instead.
  def handle_info({:result, text} = event, state) do
    state = %{state | chars: state.chars + String.length(text)}
    trace(state, event)

    if state.verbose? do
      {:noreply, state}
    else
      state = stop_ticking(state)
      state.screen.write(View.answer(text))
      {:noreply, state}
    end
  end

  # -- tools -----------------------------------------------------------------

  def handle_info({:tool_started, _id, name} = event, state) do
    state = %{state | tools: [{name, :running} | state.tools]}
    trace(state, event)
    {:noreply, refresh_status(state)}
  end

  def handle_info({:tool_finished, _id, name, result} = event, state) do
    resolution = if match?({:ok, _}, result), do: :ok, else: :error
    state = %{state | tools: List.keyreplace(state.tools, name, 0, {name, resolution})}
    trace(state, event)
    {:noreply, refresh_status(state)}
  end

  # -- low-level events, only interesting when tracing ------------------------

  def handle_info({:chunk, _chunk} = event, state) do
    state = %{state | chunks: state.chunks + 1}
    trace(state, event)
    {:noreply, state}
  end

  def handle_info({kind, _payload} = event, state) when kind in [:meta, :tool_call] do
    trace(state, event)
    {:noreply, state}
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
    :ok
  end

  # -- output ----------------------------------------------------------------

  # Verbose prints the structural events as trace lines; token-level events are
  # left to the status line counters, and chat mode prints nothing here at all.
  defp trace(%{verbose?: true} = state, event) do
    if View.structural?(event) do
      state.screen.clear_status()
      state.screen.write(View.event(event, state.width))
    end

    :ok
  end

  defp trace(_state, _event), do: :ok

  # Collapse a whole stream into one line before the turn's closing event.
  defp finish_stream(state) do
    state = stop_ticking(state)
    if state.verbose?, do: state.screen.write(View.summary(status_state(state)))
    state
  end

  defp refresh_status(%{ticking?: false} = state), do: state

  defp refresh_status(state) do
    state.screen.status(View.status(status_state(state), state.width))
    state
  end

  defp status_state(state), do: Map.take(state, [:frame, :thinking, :tools, :chunks, :chars])

  defp start_ticking(state) do
    state = %{state | ticking?: true, frame: 0}
    refresh_status(schedule_tick(state))
  end

  defp stop_ticking(%{ticking?: false} = state), do: state

  defp stop_ticking(state) do
    state.screen.clear_status()
    %{state | ticking?: false}
  end

  defp schedule_tick(state) do
    Process.send_after(self(), :tick, @tick)
    state
  end

  defp prompt(%{reader: reader} = state) when is_pid(reader) do
    state.screen.write(View.prompt())
    send(reader, :prompt)
    state
  end

  defp prompt(state), do: state

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
    receive do
      :prompt -> read(tui)
    end

    reader_loop(tui)
  end

  defp read(tui) do
    case IO.gets("") do
      line when is_binary(line) -> dispatch(tui, command(line))
      _eof_or_error -> send(tui, :quit)
    end
  end

  defp dispatch(tui, :blank), do: read(tui)
  defp dispatch(tui, :quit), do: send(tui, :quit)
  defp dispatch(tui, {:ask, text}), do: send(tui, {:input, text})
end
