defmodule Wardrik.Notice do
  @moduledoc """
  A notice tells someone what an agent did while nobody watched. Its `kind` is one of:

    * `:parked`, a turn waits on a person for `calls`, each a `Wardrik.Interrupt` with the
      `arguments` the model wrote, where they're known
    * `:failed`, a turn failed, for `reason`
    * `:finished`, a turn answered, and `text` is what it said

  `agent` is the agent's ID, and `at` when it happened.
  """

  @enforce_keys [:agent, :kind, :at]
  defstruct [:agent, :kind, :at, :reason, :text, calls: []]

  @type kind() :: :parked | :failed | :finished

  @typedoc "A call a parked turn waits on, and its arguments."
  @type call() :: %{interrupt: Wardrik.Interrupt.t(), arguments: term()}

  @type t() :: %__MODULE__{
          agent: String.t(),
          kind: kind(),
          at: DateTime.t(),
          calls: [call()],
          reason: String.t() | nil,
          text: String.t() | nil
        }

  @doc "Returns every kind a notice may be."
  @spec kinds() :: [kind()]
  def kinds, do: [:parked, :failed, :finished]

  @doc """
  Returns the notice as JSON, as a webhook is sent it.

      Wardrik.Notice.json(notice)
      #=> %{"event" => "turn_failed", "agent" => "acme/triage", "reason" => "It timed out.", ...}
  """
  @spec json(t()) :: map()
  def json(%__MODULE__{} = notice) do
    %{
      "event" => event(notice),
      "agent" => notice.agent,
      "at" => DateTime.to_iso8601(notice.at),
      "calls" => Enum.map(notice.calls, &call/1),
      "reason" => notice.reason,
      "text" => notice.text
    }
  end

  @doc "Returns the event a notice is sent as: `turn_parked`, `turn_failed` or `turn_finished`."
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
