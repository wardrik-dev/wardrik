defmodule Wardrik.Agent do
  @moduledoc """
  An agent, and the operations on one, from defining it and asking it to deciding what it waits on.

      {:ok, %Wardrik.Message{cursor: cursor}} = Wardrik.Agent.ask(scope, "acme/triage", "What's on fire?")
      {:ok, %Wardrik.Agent{status: :idle}} = Wardrik.Agent.read(scope, "acme/triage")

  An agent is its `id` and `name`, its `status`, `:idle`, `:running`, `:parked` or `:asleep`, the
  messages `pending` behind what it does, its `activity`, the `interrupts` it waits on a person
  for, and the `cursor` where its log stands. A list of agents leaves out what it doesn't read.
  """

  use Wardrik.Type,
    schema: ["agent_snapshot"],
    fields: [
      id: "agent.id",
      name: "agent.name",
      status: {"status", [:idle, :running, :parked, :asleep]},
      node: "node",
      pending: "pending",
      activity: {"activity", Wardrik.Activity},
      interrupts: {"interrupts", [Wardrik.Interrupt]},
      cursor: "cursor"
    ]

  use Wardrik.Operations.Functions, prefix: "agent"

  @doc """
  Sends the agent a message, and streams its answer's text as it's written, until its run ends. It
  raises a `Wardrik.Error` where the agent can't be reached. With `to: pid`, it sends `pid` what the
  answer brings instead, as `{Wardrik, ref, item}`, and returns `{:ok, ref}`: `{:text, chunk}`,
  then `{:done, %Wardrik.Reply{}}`, `{:waiting, interrupts}` or `{:failed, reason}`.

      scope |> Wardrik.Agent.stream("acme/triage", "What's on fire?") |> Enum.each(&IO.write/1)

  Takes `:timeout`, how long to wait between what the answer brings, ten minutes unless set.
  """
  @spec stream(Wardrik.Scope.t(), String.t() | t(), term(), keyword()) ::
          Enumerable.t() | {:ok, reference()}
  def stream(scope, agent, input, opts \\ []) do
    case Keyword.fetch(opts, :to) do
      {:ok, pid} -> Wardrik.Answers.send_to(scope, agent, input, pid, opts)
      :error -> scope |> Wardrik.Answers.follow(agent, input, opts) |> Stream.flat_map(&text/1)
    end
  end

  @doc """
  Sends the agent a message, and returns its answer once its run ends: `{:ok, %Wardrik.Reply{}}`,
  or `{:waiting, interrupts}` where it waits on a person first.

      {:ok, %Wardrik.Reply{text: text}} = Wardrik.Agent.reply(scope, "acme/triage", "What's on fire?")
  """
  @spec reply(Wardrik.Scope.t(), String.t() | t(), term(), keyword()) ::
          {:ok, Wardrik.Reply.t()}
          | {:waiting, [Wardrik.Interrupt.t()]}
          | {:error, Wardrik.Error.t()}
  def reply(scope, agent, input, opts \\ []), do: Wardrik.Answers.reply(scope, agent, input, opts)

  defp text({:text, chunk}), do: [chunk]
  defp text(_ended), do: []

  @doc "Reads one from an agent as a list gives it."
  @spec from_summary(map()) :: t()
  def from_summary(%{"id" => id, "name" => name} = summary),
    do:
      from_json(%{
        "agent" => %{"id" => id, "name" => name},
        "status" => summary["status"],
        "node" => summary["node"],
        "pending" => summary["pending"]
      })
end
