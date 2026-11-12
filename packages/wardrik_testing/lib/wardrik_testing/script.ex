defmodule WardrikTesting.Script do
  @moduledoc """
  How `WardrikTesting.Server` answers messages.

  Answers are written to the conversation's log if the test started `WardrikEvents` under
  `WardrikTesting.Server.events/1`.

  ## Messages

    * `echo` waits on the call `call_1`, to the `echo` tool with `%{"text" => "hi"}`.
    * `fail` fails with `"It broke."`.
    * Anything else is answered `"Answered: "` followed by the message.

  ## Decisions

    * Approving or denying `call_1` answers `"Done."`.
    * A denial without a reason is recorded as `"Rejected."`.

  Cancelling stops the run.
  """

  alias Wardrik.Scope
  alias WardrikTesting.Server

  @doc "Answers the message in `input`, as `agent.ask` does."
  @spec ask(Scope.t(), map()) :: {:ok, map()}
  def ask(%Scope{wardrik: name} = scope, %{"content" => text} = input) do
    conversation = Server.log(input)
    Server.tell(name, {:asked, conversation, text, scope.principal.id})
    message = input["id"] || "m-#{System.unique_integer([:positive])}"
    sender = %{"id" => scope.principal.id}

    write(scope, conversation, "message.created", %{
      "message" => %{"id" => message, "role" => "user"},
      "sender" => sender
    })

    write(scope, conversation, "run.started", %{
      "run" => %{"id" => "r1", "message_ids" => [message]}
    })

    turn(scope, conversation, text)
    {:ok, %{"message" => %{"id" => message, "cursor" => "c"}}}
  end

  @doc "Approves or denies the call in `input`, as `agent.approve` and `agent.deny` do."
  @spec decide(Scope.t(), String.t(), map()) :: {:ok, map()}
  def decide(
        %Scope{wardrik: name} = scope,
        id,
        %{"interrupt" => call} = input
      ) do
    conversation = Server.log(input)
    decision = if id == "agent.approve", do: "approved", else: "rejected"
    by = %{"id" => scope.principal.id, "name" => scope.principal.attributes[:name]}
    resolved = %{"interrupt" => %{"id" => call}, "decision" => decision, "resolved_by" => by}
    write(scope, conversation, "interrupt.resolved", Map.merge(resolved, said(id, input)))
    Server.hold(name, conversation, {"idle", []})
    answered(scope, conversation, "Done.")
    {:ok, %{"decisions" => [%{"id" => call, "decision" => decision}]}}
  end

  @doc "Cancels the run in `input`, as `agent.cancel` does."
  @spec cancel(Scope.t(), map()) :: {:ok, nil}
  def cancel(%Scope{wardrik: name} = scope, input) do
    conversation = Server.log(input)
    Server.hold(name, conversation, {"idle", []})
    write(scope, conversation, "run.cancelled", %{"run" => %{"id" => "r1"}})
    {:ok, nil}
  end

  defp said("agent.deny", input), do: %{"reason" => input["reason"] || "Rejected."}
  defp said(_approve, input), do: Map.take(input, ["note"])

  defp turn(%Scope{wardrik: name} = scope, conversation, "echo" <> _rest) do
    call = %{"id" => "call_1", "name" => "echo", "arguments" => %{"text" => "hi"}}

    interrupt = %{
      "id" => "call_1",
      "tool_call_id" => "call_1",
      "reason" => "tool_approval",
      "name" => "echo",
      "arguments" => %{"text" => "hi"},
      "message" => "Run echo?"
    }

    write(scope, conversation, "tool_call.started", %{
      "tool" => %{"name" => "echo", "call" => call},
      "decided" => %{"by" => "policy"}
    })

    Server.hold(name, conversation, {"parked", [interrupt]})

    write(scope, conversation, "run.interrupted", %{
      "run" => %{"id" => "r1"},
      "interrupts" => [interrupt]
    })
  end

  defp turn(scope, conversation, "fail" <> _rest) do
    error = %{"type" => "internal", "message" => "It broke."}
    write(scope, conversation, "run.failed", %{"run" => %{"id" => "r1"}, "error" => error})
  end

  defp turn(scope, conversation, text), do: answered(scope, conversation, "Answered: " <> text)

  defp answered(scope, conversation, text) do
    messages = [%{"role" => "assistant", "parts" => [%{"type" => "text", "content" => text}]}]

    write(scope, conversation, "run.completed", %{
      "run" => %{"id" => "r1"},
      "messages" => messages
    })
  end

  defp write(%Scope{wardrik: name}, conversation, type, data) do
    events = Server.events(name)

    if Process.whereis(events),
      do: :ok = WardrikEvents.append(events, conversation, {type, "runs/r1", data}),
      else: :ok
  end
end
