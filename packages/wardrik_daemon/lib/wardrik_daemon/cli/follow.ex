defmodule WardrikDaemon.CLI.Follow do
  @moduledoc """
  An agent's events on the terminal a live command came from, a line at a
  time as `WardrikConsole.Printer` completes each, or for `--json` each as the
  CloudEvent the HTTP API streams, read with `Wardrik.events/2` in the
  caller's scope.

  `turn/3` follows until the turn under way ends or waits on a person, and
  `events/2` and `json/2` until the person stops watching. The terminal
  belongs to the caller's VM, on another node: Ctrl-C there ends that VM, and
  this process stops with it, rather than waiting for an event with nowhere
  to go.
  """

  alias Wardrik.AgentAddress
  alias Wardrik.Bus
  alias Wardrik.Bus.Event
  alias WardrikConsole.Printer
  alias WardrikDaemon.CLI.Terminal

  @typedoc "How following ended: the turn finished, waits on a person, failed or was stopped, or the terminal went."
  @type outcome() :: :finished | :parked | :failed | :gone

  @doc """
  Subscribes to `key`'s events, runs `start`, and follows what it set going
  until the turn ends or waits on a person. What `start` answers other than
  `:ok` is answered as it is, and nothing is followed.
  """
  @spec turn(AgentAddress.t(), Terminal.t(), (-> :ok | term())) :: outcome() | term()
  def turn(key, %Terminal{} = terminal, start) do
    :ok = Bus.subscribe(key)

    outcome =
      case start.() do
        :ok -> printed(terminal, &ended/1)
        other -> other
      end

    Bus.unsubscribe(key)
    outcome
  end

  @doc "Writes `first` once subscribed to `key`'s events, then follows them until the terminal goes."
  @spec events(AgentAddress.t(), Terminal.t(), Owl.Data.t()) :: :gone
  def events(key, %Terminal{} = terminal, first) do
    :ok = Bus.subscribe(key)
    Terminal.puts(terminal, first)
    :gone = printed(terminal, fn _event -> nil end)
    Bus.unsubscribe(key)
    :gone
  end

  @doc """
  Writes each CloudEvent `key`'s log takes from now on, as `scope` reads it,
  a line of JSON each, until the terminal goes.
  """
  @spec json(Wardrik.Scope.t(), AgentAddress.t()) :: :gone
  def json(scope, key) do
    watching = watched()

    events =
      Wardrik.events!(scope, resources: [AgentAddress.resource(key)], after: :head, follow: true)

    # The events are taken by a task of its own, writing to the same
    # terminal, while this process waits for the terminal to go.
    task = Task.async(fn -> Enum.each(events, &IO.puts(JSON.encode!(&1.cloudevent))) end)

    receive do
      {:DOWN, ^watching, :process, _pid, _reason} -> Task.shutdown(task, :brutal_kill)
    end

    :gone
  end

  defp printed(terminal, ends) do
    printing(Printer.new(width: terminal.width), terminal, ends, watched())
  end

  defp printing(printer, terminal, ends, watching) do
    receive do
      %Event{} = event ->
        {lines, printer} = Printer.event(printer, event)
        Enum.each(lines, &Terminal.puts(terminal, &1))

        case ends.(event) do
          nil -> printing(printer, terminal, ends, watching)
          outcome -> outcome
        end

      {:DOWN, ^watching, :process, _pid, _reason} ->
        :gone
    end
  end

  # The caller's group leader, which goes with their VM.
  defp watched, do: Process.monitor(Process.group_leader())

  # How the turn's own events end it; its delegated work ending does not.
  defp ended(%Event{payload: payload} = event) do
    if Event.root?(event), do: outcome(payload)
  end

  defp outcome(%Bus.TurnFinished{}), do: :finished
  defp outcome(%Bus.TurnParked{}), do: :parked
  defp outcome(%Bus.TurnFailed{}), do: :failed
  defp outcome(%Bus.TurnInterrupted{}), do: :failed
  defp outcome(_payload), do: nil
end
