defmodule Wardrik.Test.Server do
  @moduledoc """
  A server that runs nothing: it tells the test each operation it's asked for, and answers with the
  protocol's own example of what the operation gives.
  """

  @behaviour Wardrik.Server

  @event %{
    "specversion" => "1.0",
    "id" => "1",
    "source" => "wardrik://local/agents/acme%2Ftriage",
    "agent" => "acme/triage",
    "type" => "wardrik.run.started",
    "time" => "2026-10-28T12:00:00Z",
    "data" => %{"run" => %{"id" => "r1"}}
  }

  @impl Wardrik.Server
  def run(%Wardrik.Server.Request{
        scope: %Wardrik.Scope{wardrik: test},
        operation: id,
        input: input
      }) do
    send(test, {:ran, id, input})
    {:ok, example(id)}
  end

  @impl Wardrik.Server
  def stream(%Wardrik.Server.Request{
        scope: %Wardrik.Scope{wardrik: test},
        operation: id,
        input: input
      }) do
    send(test, {:streamed, id, input})
    {:ok, [{@event, "cursor-1"}]}
  end

  @impl Wardrik.Server
  def follow(%{agent: "acme/broken"}, _opts), do: [{:text, "Half"}, {:failed, "It broke."}]

  def follow(%{agent: "acme/waiting"}, _opts),
    do: [
      {:waiting, [%Wardrik.Interrupt{id: "c1", reason: :tool_approval, agent: "acme/waiting"}]}
    ]

  def follow(%{conversation: "C1", input: input}, _opts),
    do: [{:done, %Wardrik.Reply{message: "m1", run: "r1", text: "In C1: " <> input}}]

  def follow(%{input: input}, _opts),
    do: [
      {:text, "Re: "},
      {:text, input},
      {:done, %Wardrik.Reply{message: "m1", run: "r1", text: "Re: " <> input}}
    ]

  @impl Wardrik.Server
  def offer(_scope, _tools), do: :ok

  @impl Wardrik.Server
  def answer(_call, _message), do: :ok

  @answers %{
    "agents.list" => %{"agents" => [%{"id" => "acme/triage", "conversation" => nil}]},
    "agent.timeline" => %{"items" => [], "next" => nil},
    "agent.runs" => %{"runs" => [], "totals" => %{}, "next" => nil}
  }

  @doc "Returns whether the server answers the operation `id`: by its example, or with nothing."
  @spec answers?(WardrikProtocol.operation()) :: boolean()
  def answers?(%{id: id, output: output}),
    do: output == nil or Map.has_key?(@answers, id) or match?(%{"examples" => [_ | _]}, output)

  defp example(id) do
    case WardrikProtocol.operation(id).output do
      %{"examples" => [example | _rest]} -> example
      _none -> Map.get(@answers, id)
    end
  end
end
