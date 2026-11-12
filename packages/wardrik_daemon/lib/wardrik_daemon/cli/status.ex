defmodule WardrikDaemon.CLI.Status do
  @moduledoc false

  # The line under a turn as it runs, saying what it does now and for how long. Owl.LiveScreen
  # redraws it in place and prints the turn's lines above it. When the turn ends or waits, it's
  # drawn once more as a summary and left, as an Owl.Spinner is.

  alias WardrikDaemon.CLI.Terminal
  alias WardrikDaemon.Console.Ansi

  @frames ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

  @enforce_keys [:screen, :colour?, :width, :since]
  defstruct @enforce_keys ++
              [
                idle: nil,
                doing: "thinking",
                running: %{},
                calls: MapSet.new(),
                frame: 0,
                shown?: false
              ]

  @type t() :: %__MODULE__{
          screen: GenServer.server(),
          colour?: boolean(),
          width: pos_integer(),
          since: integer() | nil,
          idle: String.t() | nil,
          doing: String.t(),
          running: %{String.t() => String.t()},
          calls: MapSet.t(String.t()),
          frame: non_neg_integer(),
          shown?: boolean()
        }

  @doc "How often the line is redrawn, in milliseconds."
  @spec every() :: pos_integer()
  def every, do: 100

  @doc """
  Returns the status of a turn asked at `now`, or `nil` where there's no live screen.

    * `:doing` - what it says until the turn starts. `thinking` unless set.
    * `:idle` - what it says between turns, as a `nil` `now` starts it.
  """
  @spec new(Terminal.t(), integer() | nil, doing: String.t(), idle: String.t()) :: t() | nil
  def new(terminal, now, opts \\ [])
  def new(%Terminal{live: nil}, _now, _opts), do: nil

  def new(%Terminal{live: screen} = terminal, now, opts) do
    %__MODULE__{
      screen: screen,
      colour?: terminal.colour?,
      width: terminal.width,
      since: now,
      idle: opts[:idle],
      doing: Keyword.get(opts, :doing, "thinking")
    }
  end

  @doc "Returns the status once `event` is seen at `now`."
  @spec seen(t(), map(), integer()) :: t()
  def seen(status, %{"type" => "wardrik." <> type} = event, now),
    do: did(status, type, event["data"] || %{}, now)

  def seen(status, _event, _now), do: status

  # Time spent waiting to start isn't the turn's.
  defp did(status, "run.started", _data, now), do: %{status | doing: "thinking", since: now}

  defp did(status, "reasoning.delta", _data, _now), do: %{status | doing: "thinking"}
  defp did(status, "message.delta", _data, _now), do: %{status | doing: "writing"}

  defp did(status, "message.retrying", _data, _now),
    do: %{status | doing: "trying the model again"}

  defp did(status, "tool_call.started", %{"tool" => tool}, _now),
    do: %{
      status
      | running: Map.put(status.running, call(tool), tool["name"]),
        calls: MapSet.put(status.calls, call(tool))
    }

  defp did(status, ended, %{"tool" => tool}, _now)
       when ended in ["tool_call.completed", "tool_call.denied"],
       do: %{status | running: Map.delete(status.running, call(tool)), doing: "thinking"}

  defp did(status, "run." <> ended, _data, _now)
       when ended in ~w(completed interrupted failed cancelled deadline_exceeded),
       do: %{status | since: nil, running: %{}, calls: MapSet.new()}

  defp did(status, _type, _data, _now), do: status

  defp call(tool), do: get_in(tool, ["call", "id"])

  @doc "Returns the line for `status` at `now`."
  @spec line(t(), integer()) :: Owl.Data.t()
  def line(%{since: nil} = status, _now), do: Owl.Data.tag(["· ", status.idle], :light_black)

  def line(status, now) do
    [
      Owl.Data.tag(Enum.at(@frames, rem(status.frame, length(@frames))), :cyan),
      " ",
      doing(status),
      Owl.Data.tag(" · #{seconds(status, now)}", :light_black)
    ]
    |> Owl.Data.truncate(status.width - 1)
  end

  defp doing(%{running: running, doing: doing}) when map_size(running) == 0, do: doing

  defp doing(%{running: running}) do
    [first | rest] = running |> Map.values() |> Enum.sort()
    if rest == [], do: first, else: "#{first} and #{length(rest)} more"
  end

  @doc "Draws the line at `now`, and moves it on a frame."
  @spec draw(t(), integer()) :: t()
  def draw(status, now) do
    line = Ansi.chardata(line(status, now), status.colour?)

    if status.shown?,
      do: Owl.LiveScreen.update(status.screen, __MODULE__, line),
      else: Owl.LiveScreen.add_block(status.screen, __MODULE__, state: line)

    %{status | frame: status.frame + 1, shown?: true}
  end

  @doc """
  Writes `lines` above the line. The line is brought up to `now` first: LiveScreen draws the
  line again with them, at once.
  """
  @spec puts(t(), [Owl.Data.t()], integer()) :: :ok
  def puts(_status, [], _now), do: :ok

  def puts(status, lines, now) do
    Owl.LiveScreen.update(
      status.screen,
      __MODULE__,
      Ansi.chardata(line(status, now), status.colour?)
    )

    Enum.each(lines, &IO.puts(status.screen, Ansi.chardata(&1, status.colour?)))
  end

  @doc """
  Draws the line a last time as how the turn went at `now`, and leaves it there, once what was
  written above it is out. `outcome` is `:done`, `:waiting` or `{:failed, what}`, as
  `{:failed, "cancelled"}`.
  """
  @spec finish(t(), :done | :waiting | {:failed, String.t()}, integer()) :: t()
  def finish(%{since: nil} = status, _outcome, _now), do: status

  def finish(status, outcome, now) do
    line = Ansi.chardata(summary(status, outcome, now), status.colour?)

    if status.shown?,
      do: Owl.LiveScreen.update(status.screen, __MODULE__, line),
      else: Owl.LiveScreen.add_block(status.screen, __MODULE__, state: line)

    :ok = Owl.LiveScreen.flush(status.screen)
    %{status | shown?: false}
  end

  @doc "Returns the summary line `finish/3` leaves."
  @spec summary(t(), :done | :waiting | {:failed, String.t()}, integer()) :: Owl.Data.t()
  def summary(status, :done, now),
    do: [Owl.Data.tag("✔", :green), " ", Owl.Data.tag(took(status, now), :light_black)]

  def summary(status, :waiting, now),
    do: [Owl.Data.tag("?", :yellow), " ", "waits on you", after_(status, now)]

  def summary(status, {:failed, what}, now),
    do: [Owl.Data.tag("✖", :red), " ", what, after_(status, now)]

  defp took(status, now) do
    case MapSet.size(status.calls) do
      0 -> seconds(status, now)
      1 -> "#{seconds(status, now)} · 1 tool call"
      calls -> "#{seconds(status, now)} · #{calls} tool calls"
    end
  end

  defp after_(status, now), do: Owl.Data.tag(" after #{seconds(status, now)}", :light_black)

  defp seconds(status, now), do: "#{div(now - status.since, 1_000)}s"
end
