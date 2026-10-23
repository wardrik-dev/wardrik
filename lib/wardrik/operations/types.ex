defmodule Wardrik.Operations.Types do
  @moduledoc """
  What each operation takes and answers in Elixir: its input from keyword lists and structs, and
  its output as structs, lists and `:ok`, in place of the protocol's JSON.
  """

  alias Wardrik.Agent
  alias Wardrik.Authorization
  alias Wardrik.Call
  alias Wardrik.Decision
  alias Wardrik.Definition
  alias Wardrik.Event
  alias Wardrik.Forgotten
  alias Wardrik.Interrupt
  alias Wardrik.Message
  alias Wardrik.Page
  alias Wardrik.Runs
  alias Wardrik.Timeline
  alias Wardrik.Type

  @snapshots ~w(agent.read agent.define agent.clear)
  @decided ~w(agent.decide agent.approve agent.deny)
  @answered_nothing ~w(agent.cancel agent.forget agent.kill)
  @pages ~w(agent.events events.list audit.list)

  @doc "Turns `input`, as an Elixir caller gives it, into the operation's JSON input."
  @spec encode(String.t(), term()) :: map()
  def encode("agent.define", %Definition{} = definition), do: Definition.to_json(definition)
  def encode("agent.define", fields), do: fields |> Definition.new!() |> Definition.to_json()
  def encode("agent.ask", text) when is_binary(text), do: %{"content" => text}

  def encode("agent.decide", decisions) when is_map(decisions),
    do: %{"decisions" => Enum.map(decisions, &decision/1)}

  def encode(_id, []), do: %{}
  def encode(_id, input), do: Type.json(input)

  @doc "Turns the operation's JSON output into what an Elixir caller gets."
  @spec decode(String.t(), map() | nil) :: term()
  def decode(id, output) when id in @snapshots, do: {:ok, Agent.from_json(output)}

  def decode(id, %{"decisions" => decisions}) when id in @decided,
    do: {:ok, Enum.map(decisions, &Decision.from_json/1)}

  def decode(id, nil) when id in @answered_nothing, do: :ok
  def decode(id, output) when id in @pages, do: {:ok, Page.from_json(output)}

  def decode(id, %{"agent" => agent}) when id in ~w(agent.spawn agent.stop),
    do: {:ok, Agent.from_summary(agent)}

  def decode("agent.ask", %{"message" => message}), do: {:ok, Message.from_json(message)}
  def decode("agent.authorization", output), do: {:ok, Authorization.from_json(output)}
  def decode("agent.calls", %{"calls" => calls}), do: {:ok, Enum.map(calls, &Call.from_json/1)}

  def decode("agent.definition", %{"definition" => definition, "missing" => missing}),
    do: {:ok, Definition.from_json(definition), missing}

  def decode("agent.timeline", output), do: {:ok, Timeline.from_json(output)}
  def decode("agent.runs", output), do: {:ok, Runs.from_json(output)}

  def decode("agents.list", %{"agents" => agents}),
    do: {:ok, Enum.map(agents, &Agent.from_summary/1)}

  def decode("agents.cancel", %{"cancelled" => cancelled}), do: {:ok, cancelled}
  def decode("agents.forget", output), do: {:ok, Forgotten.from_json(output)}

  def decode("interrupts.list", %{"interrupts" => listed}),
    do: {:ok, Enum.map(listed, &Interrupt.from_listed/1)}

  def decode("events.head", %{"cursor" => cursor}), do: {:ok, cursor}

  @doc "Turns a streamed event and its cursor into what an Elixir caller gets."
  @spec event({map(), String.t()}) :: {Event.t(), String.t()}
  def event({event, cursor}), do: {Event.from_json(event), cursor}

  defp decision({id, :approve}), do: %{"id" => id, "decision" => "approve"}

  defp decision({id, {:approve, note}}),
    do: %{"id" => id, "decision" => "approve", "note" => note}

  defp decision({id, {:deny, reason}}),
    do: %{"id" => id, "decision" => "reject", "reason" => reason}
end
