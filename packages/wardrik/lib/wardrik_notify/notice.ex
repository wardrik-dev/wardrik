defmodule WardrikNotify.Notice do
  @moduledoc """
  One thing a person should hear about, read from an entry of an agent's
  log.

    * `:parked` - a turn stopped on `calls`, each with the question a person
      is asked about it, `authorization: true` for one waiting on a person to
      connect an account, and the `labels` of what the turn had read, which
      may be what asked for it. Where to connect it is never in a notice.
    * `:failed` - a turn failed, for `reason`
    * `:finished` - a turn answered, and `text` is what it said last
  """

  alias Wardrik.Event.Log.Entry

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
          kind: WardrikDefinition.Route.kind(),
          at: DateTime.t(),
          calls: [call()],
          reason: term(),
          text: String.t() | nil
        }

  @doc """
  The notice `entry` of an agent's log makes, at the time its event was
  written, or `:none` for one nobody is told about. A parked turn's calls
  are read from the agent on `:host` as it is told of, as
  `Wardrik.Agent.parked/2` answers them, since the log does not say what a
  call asks: those it no longer waits on are left out, and a turn that
  waits on none of them makes none.
  """
  @spec from_entry(Entry.t(), host: Wardrik.Host.t()) :: {:ok, t()} | :none
  def from_entry(%Entry{log: agent, event: %{"type" => type} = event}, opts) do
    {:ok, at, 0} = DateTime.from_iso8601(event["time"])
    notice(type, event["data"], %{agent: agent, at: at}, Keyword.fetch!(opts, :host))
  end

  defp notice("wardrik.run.interrupted", %{"interrupts" => interrupts}, base, host) do
    ids = for %{"id" => id} <- interrupts, do: id

    case waiting(Wardrik.Agent.parked(base.agent, host: host), ids) do
      [] -> :none
      calls -> {:ok, %{parked(base.agent, calls) | at: base.at}}
    end
  end

  defp notice("wardrik.run.failed", %{"error" => error}, base, _host),
    do: {:ok, struct!(__MODULE__, Map.merge(base, %{kind: :failed, reason: error["message"]}))}

  defp notice("wardrik.run.completed", %{"messages" => messages}, base, _host),
    do: {:ok, struct!(__MODULE__, Map.merge(base, %{kind: :finished, text: last_said(messages)}))}

  defp notice(_type, _data, _base, _host), do: :none

  defp waiting({:error, :not_found}, _ids), do: []
  defp waiting(parked, ids), do: Enum.filter(parked, fn {call, _prompt} -> call.id in ids end)

  # What the last of the assistant's messages that says something says.
  defp last_said(messages) do
    said =
      for %{"role" => "assistant", "parts" => parts} <- messages,
          text = for(%{"type" => "text", "content" => text} <- parts, into: "", do: text),
          text != "",
          do: text

    List.last(said, "")
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
