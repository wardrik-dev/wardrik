defmodule Wardrik.Agent.Activity.English do
  @moduledoc """
  A `Wardrik.Agent.Activity.Presenter` in plain English, the one a surface
  uses unless it is given another.

  | Doing | Label |
  | --- | --- |
  | a model call, a turn starting or carrying on, a tool call just ended | `thinking` |
  | `Wardrik.Event.ModelRetrying` | `retrying the model, 2 of 6` |
  | tool calls | `running web_search and fetch_page` |
  | `Wardrik.Event.SpanStarted` | its name, such as `compacting history` |
  | `Wardrik.Event.TurnParked` | `waiting on a person to approve send_email` |
  | `:idle` | `idle` |

  Messages waiting follow, as `thinking, 1 message waiting`, or stand alone
  when it is idle. A park on a budget, or on a model that kept failing, is a
  park on a model call, `waiting on a person to approve a model call`, and its
  prompt says why.
  """

  defstruct []

  @type t() :: %__MODULE__{}
end

defimpl Wardrik.Agent.Activity.Presenter, for: Wardrik.Agent.Activity.English do
  alias Wardrik.Agent.Activity
  alias Wardrik.Event

  def label(_english, %Activity{doing: :idle, pending: 0}), do: "idle"
  def label(_english, %Activity{doing: :idle, pending: pending}), do: waiting(pending)
  def label(_english, %Activity{doing: doing, pending: 0}), do: doing(doing)

  def label(_english, %Activity{doing: doing, pending: pending}),
    do: doing(doing) <> ", " <> waiting(pending)

  defp waiting(1), do: "1 message waiting"
  defp waiting(pending), do: "#{pending} messages waiting"

  defp doing([_ | _] = calls), do: "running " <> listed(Enum.map(calls, & &1.name))

  defp doing(%Event.ModelRetrying{} = retry),
    do: "retrying the model, #{retry.attempt} of #{retry.attempts}"

  defp doing(%Event.SpanStarted{name: name}), do: name

  defp doing(%Event.TurnParked{calls: calls}),
    do: "waiting on a person to approve " <> listed(Enum.map(calls, &called/1))

  defp doing(_thinking), do: "thinking"

  defp called({%{name: "model"}, _prompt}), do: "a model call"
  defp called({%{name: name}, _prompt}), do: name

  defp listed([name]), do: name

  defp listed(names) do
    {most, [last]} = Enum.split(names, -1)
    IO.iodata_to_binary([Enum.intersperse(most, ", "), " and ", last])
  end
end
