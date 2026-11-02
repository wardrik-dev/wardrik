defmodule Wardrik.Notice do
  @moduledoc """
  Tells someone what an agent did while nobody watched.

  `conversation` is `nil` for the agent's main one. `kind` is one of:

    * `:parked` - a turn waits on a person. `calls` lists each `Wardrik.Interrupt` and its
      `arguments`.
    * `:failed` - a turn failed. `reason` says why.
    * `:finished` - a turn answered. `text` is the answer.
  """

  @enforce_keys [:agent, :kind, :at]
  defstruct [:agent, :kind, :at, :conversation, :reason, :text, calls: []]

  @type kind() :: :parked | :failed | :finished

  @typedoc "A call a parked turn waits on, with its arguments."
  @type call() :: %{interrupt: Wardrik.Interrupt.t(), arguments: term()}

  @type t() :: %__MODULE__{
          agent: String.t(),
          conversation: String.t() | nil,
          kind: kind(),
          at: DateTime.t(),
          calls: [call()],
          reason: String.t() | nil,
          text: String.t() | nil
        }

  @doc "Returns every kind of notice."
  @spec kinds() :: [kind()]
  def kinds, do: [:parked, :failed, :finished]

  @doc """
  Returns the notice as the JSON a webhook receives.

      Wardrik.Notice.json(notice)
      #=> %{"event" => "turn_failed", "agent" => "agt_1", "reason" => "It timed out.", ...}
  """
  @spec json(t()) :: map()
  def json(%__MODULE__{} = notice) do
    %{
      "event" => event(notice),
      "agent" => notice.agent,
      "conversation" => notice.conversation,
      "at" => DateTime.to_iso8601(notice.at),
      "calls" => Enum.map(notice.calls, &call/1),
      "reason" => notice.reason,
      "text" => notice.text
    }
  end

  @doc "Returns the notice's event name: `turn_parked`, `turn_failed` or `turn_finished`."
  @spec event(t()) :: String.t()
  def event(%__MODULE__{kind: kind}), do: "turn_#{kind}"

  defp call(%{interrupt: interrupt, arguments: arguments}) do
    %{
      "id" => interrupt.tool_call_id || interrupt.id,
      "name" => interrupt.name,
      "arguments" => arguments,
      "prompt" => interrupt.message,
      "authorization" => interrupt.reason == :authorization,
      "labels" => interrupt.labels || []
    }
  end
end
