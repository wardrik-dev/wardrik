defmodule Wardrik.Operations.Types do
  @moduledoc false

  alias Wardrik.Agent
  alias Wardrik.AgentFile
  alias Wardrik.AgentResolved
  alias Wardrik.AgentRuntime
  alias Wardrik.Authorization
  alias Wardrik.Call
  alias Wardrik.ChannelResponse
  alias Wardrik.Decision
  alias Wardrik.Definition
  alias Wardrik.Event
  alias Wardrik.Forgotten
  alias Wardrik.Interrupt
  alias Wardrik.Message
  alias Wardrik.Nodes
  alias Wardrik.Page
  alias Wardrik.Runs
  alias Wardrik.Runtime
  alias Wardrik.Timeline
  alias Wardrik.Trigger
  alias Wardrik.Type

  @snapshots ~w(agent.read agent.define agent.clear)
  @decided ~w(agent.decide agent.approve agent.deny)
  @answered_nothing ~w(agent.cancel agent.forget agent.kill agent.file_delete hook.deliver
                       hook.deliver_with_secret)
  @triggers ~w(agent.trigger_set agent.trigger_remove)
  @pages ~w(agent.events events.list audit.list)

  @structs %{
    "channel.deliver" => ChannelResponse,
    "agent.authorization" => Authorization,
    "agent.timeline" => Timeline,
    "agent.runs" => Runs,
    "agents.forget" => Forgotten,
    "deployment.nodes" => Nodes,
    "deployment.runtime" => Runtime,
    "agent.runtime" => AgentRuntime,
    "agent.resolved" => AgentResolved,
    "agent.file_put" => AgentFile
  }

  @lists %{
    "agent.calls" => {"calls", Call, :from_json},
    "agent.files" => {"files", AgentFile, :from_json},
    "agents.list" => {"agents", Agent, :from_summary},
    "interrupts.list" => {"interrupts", Interrupt, :from_listed}
  }

  @listed Map.keys(@lists)

  @doc "Returns the path segment for `value`: a string as given, or a struct's ID or name."
  @spec path(String.t() | struct()) :: String.t()
  def path(text) when is_binary(text), do: text
  def path(%Agent{id: id}), do: id
  def path(%Interrupt{id: id}), do: id
  def path(%Call{id: id}), do: id
  def path(%Trigger{name: name}), do: name

  @doc "Converts an Elixir caller's `input` to the operation's JSON input."
  @spec encode(String.t(), term()) :: map()
  def encode("agent.define", %Definition{} = definition), do: Definition.to_json(definition)
  def encode("agent.define", fields), do: fields |> Definition.new!() |> Definition.to_json()
  def encode("agent.ask", text) when is_binary(text), do: %{"content" => text}

  def encode("agent.decide", input) when is_list(input) do
    Map.new(input, fn
      {:decisions, decisions} -> {"decisions", Enum.map(decisions, &decision/1)}
      {key, value} -> {to_string(key), value}
    end)
  end

  def encode(_id, []), do: %{}
  def encode(_id, input), do: Type.json(input)

  @doc """
  Puts `opts`' `:conversation`, if set, into the JSON `input`.
  """
  @spec conversation(map(), keyword()) :: map()
  def conversation(input, opts) do
    case Keyword.validate!(opts, [:conversation]) do
      [conversation: conversation] when is_binary(conversation) ->
        Map.put(input, "conversation", conversation)

      _none ->
        input
    end
  end

  @doc """
  Converts a keyword `input` holding the path parameters `keys`, and any `:conversation`, to JSON.
  An `:interrupt` struct gives its `:agent` and `:conversation` where they're missing.
  Raises `KeyError` for a missing parameter and `ArgumentError` for an unknown key.
  """
  @spec named(String.t(), keyword(), [atom()]) :: map()
  def named(id, input, keys) do
    input = interrupted(input)
    path = Map.new(keys, &{Atom.to_string(&1), path(Keyword.fetch!(input, &1))})
    {held, rest} = Keyword.split(Keyword.drop(input, keys), held(id))

    id
    |> encode(rest)
    |> then(&checked(id, &1))
    |> Map.merge(path)
    |> conversation(held)
  end

  # An interrupt from `reply/4` or `interrupts.list` names its agent and conversation.
  defp interrupted(input) do
    case Keyword.get(input, :interrupt) do
      %Interrupt{agent: agent, conversation: conversation} when is_binary(agent) ->
        input
        |> Keyword.put_new(:agent, agent)
        |> then(&if(conversation, do: Keyword.put_new(&1, :conversation, conversation), else: &1))

      _other ->
        input
    end
  end

  defp held(id) do
    case WardrikProtocol.operation(id) do
      %{conversation: nil} -> []
      _operation -> [:conversation]
    end
  end

  @doc """
  Returns the JSON `input` if it holds only the operation's own fields, or raises `ArgumentError`.
  """
  @spec checked(String.t(), map()) :: map()
  def checked(id, input) do
    case id |> WardrikProtocol.operation() |> fields() do
      :any ->
        input

      fields ->
        case Map.keys(input) -- fields do
          [] ->
            input

          unknown ->
            raise ArgumentError,
                  "unknown input #{inspect(unknown)} for #{id}, which takes #{inspect(fields)}"
        end
    end
  end

  @doc """
  Returns `operation`'s input fields, or `:any`. Path parameters and `conversation` aren't fields.
  """
  @spec fields(WardrikProtocol.operation()) :: [String.t()] | :any
  def fields(operation) do
    case operation.input do
      %{"additionalProperties" => false} = input ->
        Map.keys(input["properties"] || %{}) --
          ["conversation" | Wardrik.Operations.Functions.path(operation)]

      _open ->
        :any
    end
  end

  @doc "Converts the operation's JSON output to what an Elixir caller gets."
  @spec decode(String.t(), map() | nil) :: term()
  def decode(id, output) when id in @snapshots, do: {:ok, Agent.from_json(output)}

  def decode(id, %{"decisions" => decisions}) when id in @decided,
    do: {:ok, Enum.map(decisions, &Decision.from_json/1)}

  def decode(id, nil) when id in @answered_nothing, do: :ok
  def decode(id, output) when id in @pages, do: {:ok, Page.from_json(output)}
  def decode(id, output) when id in @triggers, do: {:ok, Trigger.from_json(output)}

  def decode(id, output) when is_map_key(@structs, id),
    do: {:ok, Map.fetch!(@structs, id).from_json(output)}

  def decode(id, output) when id in @listed do
    {key, type, read} = Map.fetch!(@lists, id)
    {:ok, Enum.map(Map.fetch!(output, key), &apply(type, read, [&1]))}
  end

  def decode(id, %{"agent" => agent}) when id in ~w(agent.spawn agent.stop agent.move),
    do: {:ok, Agent.from_summary(agent)}

  def decode("agent.ask", %{"message" => message}), do: {:ok, Message.from_json(message)}

  def decode("agent.definition", %{"definition" => definition, "missing" => missing}),
    do: {:ok, Definition.from_json(definition), missing}

  def decode("agent.file", %{"file" => file, "content" => content}),
    do: {:ok, AgentFile.from_json(file), content}

  def decode("agents.cancel", %{"cancelled" => cancelled}), do: {:ok, cancelled}
  def decode("events.head", %{"cursor" => cursor}), do: {:ok, cursor}
  def decode("deployment.reload", %{"reloaded" => nodes}), do: {:ok, nodes}

  @doc "Converts a streamed event and its cursor to `{%Wardrik.Event{}, cursor}`."
  @spec event({map(), String.t()}) :: {Event.t(), String.t()}
  def event({event, cursor}), do: {Event.from_json(event), cursor}

  defp decision({id, :approve}), do: %{"id" => id, "decision" => "approve"}

  defp decision({id, {:approve, note}}),
    do: %{"id" => id, "decision" => "approve", "note" => note}

  defp decision({id, {:deny, reason}}),
    do: %{"id" => id, "decision" => "reject", "reason" => reason}
end
