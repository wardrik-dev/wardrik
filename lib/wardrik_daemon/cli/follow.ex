defmodule WardrikDaemon.CLI.Follow do
  @moduledoc """
  Prints an agent's events as they happen.

  Each event is printed as lines, by `WardrikDaemon.Console.Printer`, or with `--json` as the
  CloudEvent the HTTP API streams.

    * `turn/2` asks an agent something, then follows the run that answers it until it ends or
      waits on a person.
    * `events/2` follows everything the agent does until Ctrl-C.
  """

  alias WardrikDaemon.CLI.Context
  alias WardrikDaemon.Client
  alias WardrikDaemon.Console.Printer

  @timeout :timer.minutes(10)
  @ended ~w(wardrik.run.completed wardrik.run.interrupted wardrik.run.failed wardrik.run.cancelled
            wardrik.run.deadline_exceeded)

  @doc """
  Asks `:agent` `:text`, then follows the run that answers it until it ends or waits on a person.
  Gives up after ten minutes with nothing new.

      Follow.turn(cx, agent: "agt_01JF8X5RQ2", name: "triage", text: "What's on fire?")

  `:agent` is its ID and `:name` how it's shown. `:conversation` asks one of its conversations.
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
        message: id,
        run: nil,
        said?: false,
        printer: printer(cx)
      }

      follow(stream, state, @timeout)
    end
  end

  @doc """
  Follows what `:agent`, or its `:conversation`, does until Ctrl-C. `:name` is how it's shown.
  """
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

  defp hinted(%{"type" => "wardrik.run.interrupted"}, %{cx: %{json?: false} = cx, name: agent}) do
    Context.puts(
      cx,
      Owl.Data.tag(
        "Decide with: #{cx.program} approval approve #{agent} ID, or #{cx.program} approval deny #{agent} ID",
        :light_black
      )
    )
  end

  defp hinted(_event, _state), do: :ok

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
