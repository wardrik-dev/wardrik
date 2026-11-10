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
    do:
      {:ok,
       Map.merge(hd(@agents), %{
         "cursor" => "c1",
         "interrupts" => [@interrupt],
         "activity" => %{
           "since" => "2026-11-10T18:00:00Z",
           "doing" => [
             %{"type" => "wardrik.tool_call.started", "tool" => %{"name" => "github__search"}}
           ]
         }
       })}

  defp reply("agent.runs", _input),
    do:
      {:ok,
       %{
         "runs" => [
           %{
             "id" => "r1",
             "status" => "completed",
             "model" => "zai:glm",
             "source" => "message",
             "started_at" => "2026-11-10T18:00:00Z",
             "duration_ms" => 4200,
             "input_tokens" => 8400,
             "output_tokens" => 1200,
             "cost_micro_usd" => 1200,
             "tool_calls" => 2,
             "tool_errors" => 1
           },
           %{
             "id" => "r2",
             "status" => "failed",
             "started_at" => "2026-11-10T17:00:00Z",
             "error" => "The model timed out.",
             "input_tokens" => 0,
             "output_tokens" => 0,
             "cost_micro_usd" => 0,
             "tool_calls" => 0,
             "tool_errors" => 0
           }
         ],
         "totals" => %{
           "runs" => 2,
           "failed" => 1,
           "input_tokens" => 8400,
           "output_tokens" => 1_200_000,
           "cost_micro_usd" => 1200,
           "tool_calls" => 2,
           "last_at" => "2026-11-10T18:00:00Z"
         }
       }}

  defp reply("agent.calls", _input),
    do:
      {:ok, %{"calls" => [%{"id" => "toolu_2", "name" => "github__search", "elapsed_ms" => 900}]}}

  defp reply("agent.events", _input),
    do:
      {:ok,
       %{
         "events" => [
           %{
             "id" => "e1",
             "type" => "wardrik.run.started",
             "time" => "2026-11-10T18:00:00Z",
             "agent" => "triage",
             "data" => %{"model" => "zai:glm"}
           }
         ]
       }}

  defp reply("deployment.reload", _input), do: {:ok, %{"reloaded" => 2}}

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
               %{"id" => "s1", "type" => "text", "text" => "Opening an issue.", "live" => false},
               %{
                 "id" => "s2",
                 "type" => "tool",
                 "name" => "github__search",
                 "status" => "failed",
                 "error" => "Rate limited.",
                 "arguments" => %{"q" => "flaky"},
                 "result" => nil
               },
               %{
                 "id" => "s3",
                 "type" => "delegate",
                 "name" => "research",
                 "status" => "completed",
                 "tools" => 3,
                 "answer" => "Found two reports."
               }
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
    do:
      {:ok,
       %{
         "nodes" => [%{"name" => "a@host", "agents" => 2}, %{"name" => "b@host", "agents" => 0}],
         "asleep" => 3
       }}

  defp reply("agent.definition", _input),
    do:
      {:ok,
       %{
         "definition" => %{
           "model" => "zai:glm",
           "instructions" => "Triage issues.",
           "tools" => ["github/*"],
           "triggers" => [%{"name" => "sweep", "every" => "*/30 * * * *", "prompt" => "Sweep."}]
         },
         "missing" => [],
         "next_runs" => %{"sweep" => "2026-11-10T19:00:00Z"}
       }}

  defp reply(id, input)
       when id in ~w(agent.define agent.trigger_set agent.trigger_remove agent.forget agent.move
                     agent.cancel agent.stop agent.clear agent.spawn agent.kill),
       do: {:ok, input}

  defp reply("audit.list", %{"starting_after" => _next}),
    do: {:ok, %{"events" => [], "next" => 0}}

  defp reply("audit.list", _input),
    do:
      {:ok,
       %{
         "events" => [
           %{
             "id" => "a1",
             "type" => "wardrik.agent.defined",
             "time" => "2026-11-10T18:00:00Z",
             "agent" => "triage",
             "data" => %{"actor" => "ana"}
           }
         ],
         "next" => 1
       }}

  defp reply(_id, _input), do: {:error, Wardrik.Error.new(:forbidden, "Not in this test.")}

  @impl true
  def stream(%Request{}),
    do:
      {:ok,
       [
         {%{"id" => "e1", "type" => "wardrik.message.delta", "data" => %{"text" => "Hi"}}, "c1"},
         {%{"id" => "e2", "type" => "wardrik.run.started"}, "c2"},
         {%{"id" => "e3", "type" => "wardrik.run.completed"}, "c3"}
       ]}

  @impl true
  def follow(_follow, _opts), do: []

  @impl true
  def offer(_scope, _tools), do: :ok

  @impl true
  def answer(_call, _message), do: :ok
end
