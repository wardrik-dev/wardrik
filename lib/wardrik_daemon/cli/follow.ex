defmodule WardrikDaemon.CLI.Follow do
  @moduledoc false

  alias WardrikDaemon.CLI.Context
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

    with {:ok, client} <- Context.client(cx),
         {:ok, stream} <- open(client, log),
         {:ok, %{"message" => %{"id" => id}}} <- asked(client, log, text, stream) do
      state = %{
        cx: cx,
        name: named(args),
        log: log,
        message: id,
        run: nil,
        said?: false,
        calls: %{},
        printer: printer(cx)
      }

      follow(stream, state, @timeout)
    end
  end

  @doc "Follows `:agent`, or its `:conversation`, until Ctrl-C. `:name` is how it's shown."
  @spec events(Context.t(), agent: String.t(), name: String.t(), conversation: String.t() | nil) ::
          :ok | {:error, String.t()}
  def events(cx, args) do
    with {:ok, client} <- Context.client(cx),
         {:ok, stream} <- open(client, log(args)) do
      unless cx.json?,
        do:
          Context.puts(cx, Owl.Data.tag("Following #{args[:name]}. Ctrl-C stops.", :light_black))

      follow(stream, %{cx: cx, name: named(args), run: :all, printer: printer(cx)}, :infinity)
    end
  end

  defp printer(cx), do: Printer.new(width: cx.terminal.width)

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

  defp follow(stream, state, timeout) do
    case Client.next(stream, timeout) do
      {:ok, events, stream} ->
        followed(stream, seen(events, state), timeout)

      :done ->
        {:error, "The daemon stopped the stream before it ended."}

      :timeout ->
        stopped(stream, {:error, "Nothing came for ten minutes, so it stopped waiting."})
    end
  end

  defp followed(stream, {:ended, outcome}, _timeout), do: stopped(stream, outcome)
  defp followed(stream, state, timeout), do: follow(stream, state, timeout)

  defp stopped(stream, outcome) do
    Client.close(stream)
    outcome
  end

  defp seen([], state), do: state

  defp seen([event | events], state) do
    case step(event, state) do
      {:ended, outcome} -> {:ended, outcome}
      state -> seen(events, state)
    end
  end

  defp step(event, %{run: :all} = state), do: shown(event, state)

  defp step(%{"type" => "wardrik.run.started", "data" => %{"run" => run}}, %{run: nil} = state) do
    if state.message in Map.get(run, "message_ids", []),
      do: %{state | run: run["id"]},
      else: state
  end

  defp step(event, %{run: run} = state) when is_binary(run) do
    if trace(event) == run, do: ours(event, state), else: state
  end

  defp step(_event, state), do: state

  # At a terminal, each call the turn waits on is asked about where it stops. The turn goes on
  # once every one is decided.
  defp ours(
         %{"type" => "wardrik.run.interrupted", "data" => %{"interrupts" => interrupts}},
         %{cx: %{json?: false, terminal: %{input?: true}}} = state
       ) do
    case Enum.reject(interrupts, &decided?(&1, state)) do
      [] ->
        state

      left ->
        hint(left, state)
        {:ended, :ok}
    end
  end

  defp ours(%{"type" => "wardrik.tool_call.started", "data" => %{"tool" => tool}} = event, state) do
    state = shown(event, state)
    put_in(state.calls[get_in(tool, ["call", "id"])], get_in(tool, ["call", "arguments"]))
  end

  defp ours(%{"type" => type} = event, state) when type in @ended do
    state = shown(unsaid(event, state), state)
    state = shown(event, state)
    hinted(event, state)
    {:ended, outcome(event)}
  end

  defp ours(%{"type" => "wardrik.message.delta"} = event, state),
    do: shown(event, %{state | said?: true})

  defp ours(event, state), do: shown(event, state)

  defp shown(event, %{cx: %{json?: true}} = state) do
    IO.puts(JSON.encode!(event))
    state
  end

  defp shown(nil, state), do: state

  defp shown(event, %{cx: cx} = state) do
    {lines, printer} = Printer.event(state.printer, event)
    Enum.each(lines, &Context.puts(cx, &1))
    %{state | printer: printer}
  end

  defp hinted(
         %{"type" => "wardrik.run.interrupted", "data" => %{"interrupts" => interrupts}},
         %{cx: %{json?: false}} = state
       ),
       do: hint(interrupts, state)

  defp hinted(_event, _state), do: :ok

  defp hint(interrupts, %{cx: cx} = state) do
    commands =
      for interrupt <- interrupts,
          verb <- ~w(approve deny),
          do: "  #{cx.program} approval #{verb} #{decision(state, interrupt)}"

    Context.puts(cx, Owl.Data.tag(Enum.join(["Decide with:" | commands], "\n"), :light_black))
  end

  # The arguments of `approval approve` and `approval deny` that name `interrupt`.
  defp decision(%{name: name}, interrupt) do
    case String.split(name, " ", parts: 2) do
      [agent, conversation] -> "#{agent} #{interrupt["id"]} #{conversation}"
      [agent] -> "#{agent} #{interrupt["id"]}"
    end
  end

  defp decided?(interrupt, %{cx: cx} = state) do
    Context.puts(cx, ["\n", card(interrupt, state)])

    case Owl.IO.input(
           label: "Approve #{called(interrupt)}? [y/n, Enter leaves it]",
           optional: true,
           cast: &answered/1
         ) do
      :leave -> false
      :approve -> decide(state, interrupt, "agent.approve", %{})
      :deny -> decide(state, interrupt, "agent.deny", reason())
    end
  end

  defp answered(nil), do: {:ok, :leave}

  defp answered(answer) do
    case String.downcase(answer) do
      yes when yes in ~w(y yes) -> {:ok, :approve}
      no when no in ~w(n no) -> {:ok, :deny}
      _other -> {:error, "y approves it, n denies it, and Enter leaves it waiting"}
    end
  end

  defp reason do
    case Owl.IO.input(label: "Why? The model reads it. Enter gives no reason.", optional: true) do
      nil -> %{}
      reason -> %{"reason" => reason}
    end
  end

  defp decide(%{cx: cx} = state, interrupt, operation, given) do
    input = state.log |> Map.put("interrupt", interrupt["id"]) |> Map.merge(given)

    case Context.call(cx, operation, input) do
      {:ok, _decided} ->
        true

      {:error, why} ->
        Context.puts(cx, Owl.Data.tag(why, :red))
        false
    end
  end

  defp called(%{"name" => name}), do: name
  defp called(_interrupt), do: "the model call"

  defp card(interrupt, state) do
    arguments =
      case state.calls[interrupt["tool_call_id"]] do
        empty when empty in [nil, %{}] -> []
        arguments -> [Owl.Data.tag(pretty(arguments), :light_black)]
      end

    [why(interrupt), held(interrupt), arguments]
    |> Enum.reject(&(&1 == []))
    |> Enum.intersperse("\n\n")
    |> Owl.Box.new(
      title: [" ", called(interrupt), " "],
      border_style: :solid_rounded,
      border_tag: :yellow,
      padding_x: 1,
      max_width: min(state.cx.terminal.width, 100),
      word_wrap: :normal
    )
  end

  # The prompt asks for a tool's approval, so the card says why only for another reason.
  defp why(%{"reason" => "tool_approval"}), do: []
  defp why(interrupt), do: interrupt["message"]

  defp held(%{"labels" => [_label | _labels]}),
    do: Owl.Data.tag("It follows content from outside.", :yellow)

  defp held(_interrupt), do: []

  defp pretty(arguments),
    do: arguments |> :json.format() |> IO.iodata_to_binary() |> String.trim_trailing()

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

  defp trace(%{"traceparent" => "00-" <> rest}), do: rest |> String.split("-", parts: 2) |> hd()
  defp trace(_event), do: nil
end
