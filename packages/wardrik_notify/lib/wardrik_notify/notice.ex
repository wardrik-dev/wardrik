defmodule WardrikNotify.Notice do
  @moduledoc """
  One thing a person should hear about, read from an agent's event.

    * `:parked` - a turn stopped on `calls`, each with the question a person
      is asked about it, `authorization: true` for one waiting on a person to
      connect an account, and the `labels` of what the turn had read, which
      may be what asked for it. Where to connect it is never in a notice.
    * `:failed` - a turn failed, for `reason`
    * `:finished` - a turn answered, and `text` is what it said last
  """

  alias Wardrik.LLM.Message

  @enforce_keys [:agent, :kind, :at]
  defstruct [:agent, :kind, :at, :reason, :text, calls: []]

  @typedoc "A call a parked turn is waiting on."
  @type call() :: %{
          id: String.t(),
          name: String.t(),
          arguments: map(),
          prompt: String.t(),
          authorization: boolean(),
          labels: [Wardrik.Label.t()]
        }

  @type t() :: %__MODULE__{
          agent: Wardrik.AgentID.t(),
          kind: WardrikNotify.Route.kind(),
          at: DateTime.t(),
          calls: [call()],
          reason: term(),
          text: String.t() | nil
        }

  @doc "The notice `event` makes, or `:none` for an event nobody is told about."
  @spec from_event(Wardrik.Event.t()) :: {:ok, t()} | :none
  def from_event(%Wardrik.Event{source: source, payload: payload, at: at}) do
    base = %{agent: source.agent_id, at: DateTime.from_unix!(at, :microsecond)}

    case payload do
      {:turn_parked, calls} ->
        {:ok, %{parked(source.agent_id, calls) | at: base.at}}

      {:turn_failed, reason} ->
        {:ok, struct!(__MODULE__, Map.merge(base, %{kind: :failed, reason: reason}))}

      {:turn_finished, messages} ->
        {:ok, struct!(__MODULE__, Map.merge(base, %{kind: :finished, text: last_said(messages)}))}

      _other ->
        :none
    end
  end

  @doc """
  The notice that `agent` waits on `calls`, as `Wardrik.Agent.parked/1`
  answers them, now.
  """
  @spec parked(Wardrik.AgentID.t(), [{Wardrik.Tool.call(), String.t()}]) :: t()
  def parked(%Wardrik.AgentID{} = agent, calls) when is_list(calls),
    do: %__MODULE__{
      agent: agent,
      kind: :parked,
      at: DateTime.utc_now(),
      calls: Enum.map(calls, &call/1)
    }

  defp call({call, prompt}) do
    %{
      id: call.id,
      name: call.name,
      arguments: Map.get(call, :arguments, %{}),
      prompt: prompt,
      authorization: Map.has_key?(call, :link),
      labels: Map.get(call, :labels, [])
    }
  end

  defp last_said(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{role: :assistant} = message -> presence(Message.text(message))
      _message -> nil
    end)
  end

  defp presence(""), do: nil
  defp presence(text), do: text

  @doc "The notice as JSON-ready data, as `WardrikNotify.Webhook` sends it."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = notice) do
    %{
      event: "turn_#{notice.kind}",
      agent: to_string(notice.agent),
      at: DateTime.to_iso8601(notice.at),
      calls: notice.calls,
      reason: notice.reason && reason_text(notice.reason),
      text: notice.text
    }
  end

  @doc """
  What a failed turn's reason says to a person: an exception's message, text
  as it is, and anything else as Elixir prints it.
  """
  @spec reason_text(term()) :: String.t()
  def reason_text(%{__exception__: true} = error), do: Exception.message(error)
  def reason_text(reason) when is_binary(reason), do: reason
  def reason_text(reason), do: inspect(reason)
end
