defmodule WardrikWeb.Test.Server do
  @moduledoc "A `Wardrik.Server` that answers from fixed data and records what it was asked."
  @behaviour Wardrik.Server

  alias Wardrik.Server.Request

  @agents [
    %{
      "id" => "triage",
      "status" => "parked",
      "pending" => 1,
      "spent_today" => %{"usd" => 0.25, "tokens" => 900},
      "node" => "a@host"
    },
    %{
      "id" => "digest",
      "status" => "idle",
      "pending" => 0,
      "spent_today" => %{"usd" => 0, "tokens" => 0},
      "node" => "a@host"
    }
  ]

  @interrupt %{
    "id" => "toolu_1",
    "name" => "github__open_issue",
    "message" => "Open an issue?",
    "reason" => "tool_approval",
    "arguments" => %{"title" => "Flaky"}
  }

  def asked, do: Agent.get(__MODULE__, &Enum.reverse/1)
  def start, do: Agent.start_link(fn -> [] end, name: __MODULE__)

  @impl true
  def run(%Request{operation: id, input: input}) do
    Agent.update(__MODULE__, &[{id, input} | &1])
    reply(id, input)
  end

  defp reply("agents.list", _input), do: {:ok, %{"agents" => @agents}}

  defp reply("interrupts.list", _input),
    do: {:ok, %{"interrupts" => [%{"agent" => %{"id" => "triage"}, "interrupt" => @interrupt}]}}

  defp reply("agent.read", %{"agent" => "triage"}),
    do: {:ok, Map.merge(hd(@agents), %{"cursor" => "c1", "interrupts" => [@interrupt]})}

  defp reply("agent.read", _input),
    do: {:error, Wardrik.Error.new(:not_found, "There's no such agent.")}

  defp reply("agent.timeline", _input),
    do:
      {:ok,
       %{
         "cursor" => "c1",
         "items" => [
           %{"id" => "m1", "kind" => "user", "text" => "File the flaky test", "sender" => "ana"},
           %{
             "id" => "r1",
             "kind" => "run",
             "status" => "waiting",
             "model" => "zai:glm",
             "cost_micro_usd" => 1200,
             "steps" => [
               %{"id" => "s1", "type" => "text", "text" => "Opening an issue.", "live" => false}
             ],
             "interrupts" => [@interrupt]
           }
         ]
       }}

  defp reply("agent.approve", _input),
    do: {:ok, %{"decisions" => [%{"id" => "toolu_1", "decision" => "approved"}]}}

  defp reply("agent.deny", _input),
    do: {:ok, %{"decisions" => [%{"id" => "toolu_1", "decision" => "rejected"}]}}

  defp reply("agent.ask", _input), do: {:ok, %{"message" => %{"id" => "m2", "cursor" => "c2"}}}

  defp reply("deployment.nodes", _input),
    do: {:ok, %{"nodes" => [%{"name" => "a@host", "agents" => 2}], "asleep" => 3}}

  defp reply("audit.list", _input), do: {:ok, %{"events" => [], "next" => 0}}
  defp reply(_id, _input), do: {:error, Wardrik.Error.new(:forbidden, "Not in this test.")}

  @impl true
  def stream(%Request{}), do: {:ok, []}

  @impl true
  def follow(_follow, _opts), do: []

  @impl true
  def offer(_scope, _tools), do: :ok

  @impl true
  def answer(_call, _message), do: :ok
end
