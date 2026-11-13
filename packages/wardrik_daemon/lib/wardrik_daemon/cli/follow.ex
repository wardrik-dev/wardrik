defmodule WardrikDaemon.CLI.Follow do
  @moduledoc false

  alias WardrikDaemon.CLI.Context
  alias WardrikDaemon.CLI.Decide
  alias WardrikDaemon.CLI.Status
  alias WardrikDaemon.Client
  alias WardrikDaemon.Console.Printer

  @timeout :timer.minutes(10)
  @ended ~w(wardrik.run.completed wardrik.run.interrupted wardrik.run.failed wardrik.run.cancelled
            wardrik.run.deadline_exceeded)

  @doc """
  Asks `:agent` `:text`, then follows until the turn ends or waits on a person.

      Follow.turn(cx, agent: "agt_01JF8X5RQ2", name: "triage", text: "What's on fire?")

    * `:agent` - the agent's ID. `:name` - how it's shown.
    * `:conversation` - one of its conversations.

  Gives up after ten minutes with nothing new.
  """
  @spec turn(Context.t(),
          agent: String.t(),
          name: String.t(),
          text: String.t(),
          conversation: String.t() | nil
        ) :: :ok | {:error, String.t()}
  def turn(cx, args) do
    log = log(args)
    text = Keyword.fetch!(args, :text)

    state = %{
      cx: cx,
      name: named(args),
      log: log,
      message: nil,
      run: nil,
      said?: false,
      waited: 0,
      status: starting(cx, args),
      printer: printer(cx)
    }

    with {:ok, client} <- Context.client(cx),
         {:ok, stream} <- open(client, log),
         :ok <- first(stream, state, args[:name]),
         {:ok, %{"message" => %{"id" => id}}} <- asked(client, log, text, stream) do
      follow(stream, %{state | message: id}, @timeout)
    end
  end

  # A message waits behind the calls its agent already waits on a person for. At a terminal
  # they're asked about first, and the message is sent once they're decided. Otherwise it's
  # sent, and the hint says what it waits behind.
  defp first(stream, state, name) do
    case waiting(state) do
      {:ok, []} ->
        :ok

      {:ok, interrupts} ->
        before(stream, state, name, interrupts)

      {:error, why} ->
        stopped(stream, {:error, why})
    end
  end

  defp waiting(%{cx: cx, log: log}) do
    with {:ok, %{"interrupts" => listed}} <- Context.call(cx, "interrupts.list", %{}) do
      {:ok,
       for(
         %{"agent" => %{"id" => agent}, "interrupt" => interrupt} = waiting <- listed,
         agent == log["agent"] and waiting["conversation"] == log["conversation"],
         do: interrupt
       )}
    end
  end

  defp before(_stream, %{cx: %{json?: true}}, _name, _interrupts), do: :ok

  defp before(stream, %{cx: %{terminal: %{input?: true}} = cx} = state, name, interrupts) do
    Context.puts(cx, Owl.Data.tag("#{name} waits on you first:", :yellow))

    case Enum.reject(interrupts, &decided?(&1, state)) do
      [] ->
        :ok

      left ->
        hint(left, state)

        stopped(
          stream,
          {:error, "#{name} answers nothing until those are decided, so it wasn't asked."}
        )
    end
  end

  defp before(_stream, %{cx: cx} = state, name, interrupts) do
    Context.puts(cx, Owl.Data.tag("#{name} answers once these are decided.", :yellow))
    hint(interrupts, state)
  end

  @doc """
  Follows `:agent`, or its `:conversation`, until Ctrl-C. `:name` is how it's shown.

  It shows first what the agent already waits on a person for, and at a terminal asks about
  each call, then and as the agent stops for one.
  """
  @spec events(Context.t(), agent: String.t(), name: String.t(), conversation: String.t() | nil) ::
          :ok | {:error, String.t()}
  def events(cx, args) do
    state = %{
      cx: cx,
      name: named(args),
      log: log(args),
      run: :all,
      waited: 0,
      status: watching(cx, args),
      printer: printer(cx)
    }

    with {:ok, client} <- Context.client(cx),
         {:ok, stream} <- open(client, state.log),
         {:ok, waiting} <- waiting(state) do
      follow(stream, pending(state, waiting), :infinity)
    end
  end

  defp pending(state, []), do: state
  defp pending(%{cx: %{json?: true}} = state, _waiting), do: state

  defp pending(%{cx: cx} = state, waiting) do
    Context.puts(cx, Owl.Data.tag("#{state.name} waits on you:", :yellow))
    asked(state, waiting)
    state
  end

  # At a terminal each call is asked about, and the rest are hinted at. Returns those left.
  defp asked(%{cx: %{terminal: %{input?: true}}} = state, interrupts) do
    left = Enum.reject(interrupts, &decided?(&1, state))
    if left != [], do: hint(left, state)
    left
  end

  defp asked(state, interrupts) do
    hint(interrupts, state)
    interrupts
  end

  # The live line says what's followed, or a line does where there's none.
  defp watching(%{json?: true}, _args), do: nil

  defp watching(cx, args) do
    following = "Following #{args[:name]}. Ctrl-C stops."

    with nil <- Status.new(cx.terminal, nil, idle: following) do
      Context.puts(cx, Owl.Data.tag(following, :light_black))
      nil
    end
  end

  defp printer(cx), do: Printer.new(width: cx.terminal.width)

  # Until its run starts, the line says the agent hasn't started rather than that it thinks.
  defp starting(%{json?: true}, _args), do: nil

  defp starting(cx, args),
    do: Status.new(cx.terminal, now(), doing: "waiting for #{args[:name]} to start")

  # How the agent is typed, as the hints show it.
  defp named(args) do
    case args[:conversation] do
      nil -> args[:name]
      conversation -> "#{args[:name]} --conversation #{conversation}"
    end
  end

  # The input that names the agent, or its conversation.
  defp log(args),
    do: Context.conversation(%{"agent" => Keyword.fetch!(args, :agent)}, Map.new(args))

  defp open(client, log) do
    case Client.open(client, "agent.events", log) do
      {:ok, stream} -> {:ok, stream}
      {:error, _type, message} -> {:error, message}
    end
  end

  defp asked(client, log, text, stream) do
    case Client.run(client, "agent.ask", Map.put(log, "content", text)) do
      {:ok, asked} ->
        {:ok, asked}

      {:error, _type, message} ->
        Client.close(stream)
        {:error, message}
    end
  end

  # With a live status line, it wakes every frame to redraw it, and counts the quiet time.
  defp follow(stream, state, timeout) do
    case Client.next(stream, wait(state, timeout)) do
      {:ok, events, stream} ->
        followed(stream, seen(events, %{state | waited: 0}), timeout)

      :done ->
        stopped(stream, state, {:error, "The daemon stopped the stream before it ended."})

      :timeout ->
        quiet(stream, state, timeout)
    end
  end

  defp wait(%{status: nil}, timeout), do: timeout
  defp wait(_state, _timeout), do: Status.every()

  defp quiet(stream, %{status: nil} = state, _timeout), do: stopped(stream, state, gave_up())

  defp quiet(stream, state, timeout) do
    waited = state.waited + Status.every()

    if timeout != :infinity and waited >= timeout,
      do: stopped(stream, state, gave_up()),
      else: follow(stream, drawn(%{state | waited: waited}), timeout)
  end

  defp gave_up, do: {:error, "Nothing came for ten minutes, so it stopped waiting."}

  defp followed(stream, {:ended, outcome}, _timeout), do: stopped(stream, outcome)
  defp followed(stream, state, timeout), do: follow(stream, drawn(state), timeout)

  defp drawn(%{status: nil} = state), do: state
  defp drawn(state), do: %{state | status: Status.draw(state.status, now())}

  defp finished(%{status: nil} = state, _outcome), do: state

  defp finished(state, outcome),
    do: %{state | status: Status.finish(state.status, outcome, now())}

  defp stopped(stream, state, outcome) do
    _state = finished(state, {:failed, "stopped"})
    stopped(stream, outcome)
  end

  defp stopped(stream, outcome) do
    Client.close(stream)
    outcome
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp seen([], state), do: state

  defp seen([event | events], state) do
    case step(event, state) do
      {:ended, outcome} -> {:ended, outcome}
      state -> seen(events, state)
    end
  end

  # Following, a call the agent stops for is asked about at a terminal, as a turn's is.
  defp step(
         %{"type" => "wardrik.run.interrupted", "data" => %{"interrupts" => interrupts}} = event,
         %{run: :all, cx: %{json?: false, terminal: %{input?: true}}} = state
       ) do
    state = finished(state, :waiting)
    _left = asked(state, interrupts)
    noted(state, event)
  end

  defp step(event, %{run: :all} = state), do: shown(event, state)

  defp step(
         %{"type" => "wardrik.run.started", "data" => %{"run" => run}} = event,
         %{run: nil} = state
       ) do
    if state.message in Map.get(run, "message_ids", []),
      do: started(%{state | run: run["id"]}, event),
      else: state
  end

  defp step(event, %{run: run} = state) when is_binary(run) do
    if trace(event) == run, do: ours(event, state), else: state
  end

  defp step(_event, state), do: state

  defp started(%{status: nil} = state, _event), do: state
  defp started(state, event), do: %{state | status: Status.seen(state.status, event, now())}

  # At a terminal, each call the turn waits on is asked about where it stops. The turn goes on
  # once every one is decided.
  defp ours(
         %{"type" => "wardrik.run.interrupted", "data" => %{"interrupts" => interrupts}},
         %{cx: %{json?: false, terminal: %{input?: true}}} = state
       ) do
    state = finished(state, :waiting)

    case Enum.reject(interrupts, &decided?(&1, state)) do
      [] ->
        resumed(state)

      left ->
        hint(left, state)
        {:ended, :ok}
    end
  end

  # The end of the turn is shown, but the status line sums the turn up rather than taking it.
  defp ours(%{"type" => type} = event, state) when type in @ended do
    state = shown(unsaid(event, state), state)
    state = finished(printed(event, state), went(type))
    hinted(event, state)
    {:ended, outcome(event)}
  end

  defp ours(%{"type" => "wardrik.message.delta"} = event, state),
    do: shown(event, %{state | said?: true})

  defp ours(event, state), do: shown(event, state)

  defp shown(nil, state), do: state
  defp shown(event, state), do: printed(event, noted(state, event))

  defp noted(%{status: nil} = state, _event), do: state
  defp noted(state, event), do: %{state | status: Status.seen(state.status, event, now())}

  defp printed(event, %{cx: %{json?: true}} = state) do
    event
    |> JSON.encode!()
    |> IO.puts()

    state
  end

  defp printed(event, state) do
    {lines, printer} = Printer.event(state.printer, event)
    state = %{state | printer: printer}
    written(lines, state)
    state
  end

  # Above the status line while it shows.
  defp written(lines, %{status: %Status{shown?: true} = status}),
    do: Status.puts(status, lines, now())

  defp written(lines, %{cx: cx}), do: Enum.each(lines, &Context.puts(cx, &1))

  defp went("wardrik.run.completed"), do: :done
  defp went("wardrik.run.interrupted"), do: :waiting
  defp went("wardrik.run.failed"), do: {:failed, "failed"}
  defp went("wardrik.run.cancelled"), do: {:failed, "cancelled"}
  defp went("wardrik.run.deadline_exceeded"), do: {:failed, "ran out of time"}

  defp resumed(%{status: nil} = state), do: state
  # The summary after a wait covers the turn since it went on.
  defp resumed(state), do: %{state | status: %{state.status | since: now(), calls: MapSet.new()}}

  defp hinted(
         %{"type" => "wardrik.run.interrupted", "data" => %{"interrupts" => interrupts}},
         %{cx: %{json?: false}} = state
       ),
       do: hint(interrupts, state)

  defp hinted(_event, _state), do: :ok

  defp hint(interrupts, state), do: Decide.hint(state.cx, interrupts, state.name)

  defp decided?(interrupt, state),
    do:
      Decide.asked?(state.cx, interrupt,
        log: state.log,
        name: state.name,
        arguments: interrupt["arguments"]
      )

  defp unsaid(%{"type" => "wardrik.run.completed", "data" => data}, %{said?: false}),
    do: %{"type" => "wardrik.message.delta", "data" => %{"delta" => last_said(data["messages"])}}

  defp unsaid(_event, _state), do: nil

  defp outcome(%{"type" => "wardrik.run.failed"}), do: {:error, "The turn failed."}
  defp outcome(_event), do: :ok

  defp last_said(messages) do
    messages
    |> Enum.filter(&(&1["role"] == "assistant"))
    |> Enum.flat_map(&Map.get(&1, "parts", []))
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join(& &1["content"])
  end

  defp trace(%{"traceparent" => "00-" <> rest}), do: hd(String.split(rest, "-", parts: 2))
  defp trace(_event), do: nil
end
