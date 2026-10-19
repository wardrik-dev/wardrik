defmodule Wardrik.Catalog do
  @moduledoc """
  The functions of `Wardrik` an agent is offered as tools, each a
  `Wardrik.Catalog.Entry`: what it is called, what it does, and the input it
  takes. `Wardrik.Catalog.Self` offers those on one agent to the agent
  itself, and `Wardrik.Catalog.Agents` offers them, and those on every agent
  under a prefix, to the agents of its owner; `Wardrik.Catalog.Tools` says
  how a call runs.

  | Entries | Act on |
  | --- | --- |
  | `agent/0` | one agent: its snapshot and definition, a message to it, its definition and triggers |
  | `fleet/0` | every agent under a prefix: listing them |

  Each entry's `run` reads the tool's input, calls the function, and
  answers what it answered as `Wardrik.JSON` shows it, with the labels
  of what it holds: a snapshot holds the agent's history, so an answer that
  shows one carries its labels.
  """

  alias Wardrik.Agent.Message
  alias Wardrik.Catalog.Entry
  alias Wardrik.Error
  alias Wardrik.JSON

  @doc "The entries that act on one agent, the reads first."
  @spec agent() :: [Entry.t()]
  def agent do
    [
      %Entry{
        name: "agent.read",
        summary:
          "Read the agent's snapshot: whether it is running, idle or waiting on a person, what " <>
            "it waits on, how its last turn ended, and its conversation.",
        run: &__MODULE__.read/4
      },
      %Entry{
        name: "agent.definition.read",
        summary:
          "Read the agent's definition as it was last put: its instructions, tools and triggers.",
        run: &__MODULE__.definition_read/4
      },
      %Entry{
        name: "agent.ask",
        summary:
          "Send the agent a message, which it answers in a turn of its own. An agent that sends " <>
            "it is sent the answer back, later, as a message from the agent it asked.",
        run: &__MODULE__.ask/4
      },
      %Entry{
        name: "agent.define",
        summary:
          "Define the agent with a whole definition: what it is for, its instructions, model, " <>
            "tools and triggers. An agent defined already is given the new definition in place " <>
            "of its old one, and one that does not run yet starts.",
        run: &__MODULE__.define/4
      },
      %Entry{
        name: "agent.trigger.set",
        summary:
          "Set one of the agent's triggers, by name: when it is asked something, on a clock, " <>
            "from a feed, or by a webhook. A trigger of that name is replaced.",
        run: &__MODULE__.trigger_set/4
      },
      %Entry{
        name: "agent.trigger.remove",
        summary: "Remove one of the agent's triggers, by name.",
        run: &__MODULE__.trigger_remove/4
      }
    ]
  end

  @doc "The entries that act on every agent under a prefix."
  @spec fleet() :: [Entry.t()]
  def fleet do
    [
      %Entry{
        name: "agents.list",
        summary: "List the agents within reach, awake or asleep, with what each is doing.",
        run: &__MODULE__.list/4
      }
    ]
  end

  @doc false
  def read(session, agent, _input, _context) do
    with {:ok, snapshot} <- Wardrik.agent_read(session, agent),
         do: {:ok, JSON.snapshot(snapshot), snapshot.labels}
  end

  @doc false
  def definition_read(session, agent, _input, _context) do
    with {:ok, read} <- Wardrik.agent_definition_read(session, agent),
         do: {:ok, %{"definition" => read.fields, "missing" => read.missing}, []}
  end

  @doc false
  def ask(session, agent, input, _context) do
    with {:ok, text, id} <- Message.read(input),
         {:ok, message} <- Wardrik.agent_ask(session, agent, text, id: id),
         do: {:ok, %{"message" => %{"id" => message.id}}, []}
  end

  @doc false
  def define(session, agent, %{"definition" => %{} = definition}, context) do
    with {:ok, snapshot} <-
           Wardrik.agent_define(session, agent, definition, held: context.run.hooks),
         do: {:ok, JSON.snapshot(snapshot), snapshot.labels}
  end

  def define(_session, _agent, _input, _context),
    do: invalid("An agent is defined with its definition")

  @doc false
  def trigger_set(session, agent, %{"name" => name, "trigger" => %{} = fields}, _context)
      when is_binary(name) do
    with {:ok, trigger} <- Wardrik.agent_trigger_set(session, agent, name, fields),
         do: {:ok, %{"trigger" => trigger}, []}
  end

  def trigger_set(_session, _agent, _input, _context),
    do: invalid("A trigger is set with its name and the trigger")

  @doc false
  def trigger_remove(session, agent, %{"name" => name}, _context) when is_binary(name) do
    with {:ok, _trigger} <- Wardrik.agent_trigger_remove(session, agent, name),
         do: {:ok, "done", []}
  end

  def trigger_remove(_session, _agent, _input, _context),
    do: invalid("A trigger is removed by its name")

  @doc false
  def list(session, prefix, _input, _context) do
    with {:ok, members} <- Wardrik.agents_list(session, prefix),
         do: {:ok, %{"agents" => Enum.map(members, &JSON.agent/1)}, []}
  end

  defp invalid(message), do: {:error, Error.new(:invalid, message)}
end
