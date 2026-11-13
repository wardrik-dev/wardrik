defmodule Wardrik.Agent do
  @moduledoc """
  An agent, and the operations on one.

      Wardrik.Agent.ask(scope, "agt_1", "What's on fire?")
      #=> {:ok, %Wardrik.Message{id: "msg_Xq3f...", cursor: "W1siYWd0XzEiLG51bGwsNDFdXQ"}}

      Wardrik.Agent.read(scope, "agt_1")
      #=> {:ok, %Wardrik.Agent{id: "agt_1", status: :running, node: "wardrik@box1", pending: 0, ...}}

  A conversation shares its agent's definition, with its own history:

      Wardrik.Agent.ask(scope, "agt_1", "What's on fire?", conversation: "C1")
      Wardrik.Agent.approve(scope, agent: "agt_1", interrupt: "call_1", conversation: "C1")

  ## Fields

    * `:id` - the agent's ID, as your app chose it.
    * `:conversation` - the conversation's ID, or `nil` for the main one.
    * `:description` - what the agent is for, from its definition.
    * `:model` - the model it runs on, from its definition or the deployment's default.
    * `:status` - `:idle`, `:running`, `:parked`, `:asleep` or `:unreadable`.
    * `:problem` - why its saved state can't be read, while it's `:unreadable`. Defining it again
      starts it over.
    * `:node` - the node it runs on.
    * `:pending` - how many messages wait behind the current one.
    * `:next_run` - when it next runs.
    * `:spent_today` - what it has spent today.
    * `:activity` - what it's doing now. See `Wardrik.Activity`.
    * `:interrupts` - the calls it waits on a person for. See `Wardrik.Interrupt`.
    * `:cursor` - where its event log stands.
    * `:reset` - what defining it started over because its saved state couldn't be read, and why.

  `Wardrik.Agents.list/2` leaves out `:activity`, `:interrupts` and `:cursor`.
  """

  use Wardrik.Type,
    schema: ["agent_snapshot"],
    fields: [
      id: "agent.id",
      conversation: "conversation",
      description: "description",
      model: "model",
      status: {"status", [:idle, :running, :parked, :asleep, :unreadable]},
      problem: "problem",
      node: "node",
      pending: "pending",
      next_run: {"next_run", :datetime},
      spent_today: "spent_today",
      activity: {"activity", Wardrik.Activity},
      interrupts: {"interrupts", [Wardrik.Interrupt]},
      cursor: "cursor",
      reset: "reset"
    ]

  use Wardrik.Operations.Functions, prefix: "agent"

  @doc """
  Sends the agent a message and streams the text of its answer.

      scope |> Wardrik.Agent.stream("agt_1", "What's on fire?") |> Enum.each(&IO.write/1)

    * The stream ends when the run ends or fails. `reply/4` says how it ended.
    * Raises `Wardrik.Error` if the agent can't be reached.
    * With `to: pid`, returns `{:ok, ref}`. `pid` receives `{Wardrik, ref, {:text, chunk}}`, then
      `{:done, %Wardrik.Reply{}}`, `{:waiting, interrupts}` or `{:failed, why}`.

  ## Options

    * `:conversation` - the conversation to send it to. The main one unless set.
    * `:to` - a pid to send the answer to, in place of returning a stream.
    * `:timeout` - milliseconds to wait for each part of the answer. Ten minutes unless set.
  """
  @spec stream(Wardrik.Scope.t(), String.t() | t(), term(), keyword()) ::
          Enumerable.t() | {:ok, reference()}
  def stream(scope, agent, input, opts \\ []) do
    case Keyword.fetch(opts, :to) do
      {:ok, pid} ->
        send_to(scope, agent, input, pid, opts)

      :error ->
        scope
        |> follow(agent, input, opts)
        |> Stream.flat_map(&text/1)
    end
  end

  @doc """
  Sends the agent a message and returns its answer once the run ends.

      Wardrik.Agent.reply(scope, "agt_1", "What's on fire?")
      #=> {:ok, %Wardrik.Reply{message: "msg_Xq3f...", run: "0af76519...", text: "Nothing's on fire."}}

  Returns `{:waiting, interrupts}` if the run waits on a person, or `{:error, %Wardrik.Error{}}`.
  Takes `stream/4`'s `:conversation` and `:timeout`.
  """
  @spec reply(Wardrik.Scope.t(), String.t() | t(), term(), keyword()) ::
          {:ok, Wardrik.Reply.t()}
          | {:waiting, [Wardrik.Interrupt.t()]}
          | {:error, Wardrik.Error.t()}
  def reply(scope, agent, input, opts \\ []) do
    scope
    |> follow(agent, input, opts)
    |> Enum.reduce(nil, &ended/2)
  rescue
    error in Wardrik.Error -> {:error, error}
  end

  defp follow(%Wardrik.Scope{server: server} = scope, agent, input, opts) do
    {conversation, opts} = Keyword.pop(opts, :conversation)

    server.follow(
      %Wardrik.Server.Follow{
        scope: scope,
        agent: agent,
        conversation: conversation,
        input: input
      },
      opts
    )
  end

  defp send_to(scope, agent, input, pid, opts) do
    ref = make_ref()

    {:ok, _task} =
      Task.start(fn ->
        scope
        |> follow(agent, input, opts)
        |> Enum.each(&send(pid, {Wardrik, ref, &1}))
      end)

    {:ok, ref}
  end

  defp ended({:done, reply}, _acc), do: {:ok, reply}
  defp ended({:waiting, interrupts}, _acc), do: {:waiting, interrupts}

  defp ended({:failed, why}, _acc),
    do: {:error, Wardrik.Error.new(:unavailable, "The run failed: #{why}")}

  defp ended({:text, _chunk}, acc), do: acc

  defp text({:text, chunk}), do: [chunk]
  defp text(_ended), do: []

  @doc "Builds an agent from one item of `agents.list`'s output."
  @spec from_summary(map()) :: t()
  def from_summary(%{"id" => id} = summary),
    do:
      from_json(%{
        "agent" => %{"id" => id},
        "conversation" => summary["conversation"],
        "description" => summary["description"],
        "model" => summary["model"],
        "status" => summary["status"],
        "node" => summary["node"],
        "pending" => summary["pending"],
        "next_run" => summary["next_run"],
        "spent_today" => summary["spent_today"]
      })
end
