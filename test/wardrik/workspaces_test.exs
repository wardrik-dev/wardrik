defmodule Wardrik.WorkspacesTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.LLM
  import Wardrik.Test.Wardrik

  @model "anthropic:claude-haiku-4-5"

  setup :set_mimic_global

  setup context do
    store = Wardrik.Test.Store.new(:"store #{context.test}")

    wardrik =
      Wardrik.new(
        name: :"wardrik #{context.test}",
        store: store,
        workspace: [
          shared: %{
            "acme/runbooks" => [
              read: ["acme/@jon/*"],
              write: ["acme/agent/ops", "acme/agent/ops/*"]
            ]
          }
        ]
      )

    start_supervised!({WardrikStore, store})
    start_supervised!({Wardrik, wardrik})
    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    :ok = WardrikEvents.subscribe(Wardrik.events(wardrik), ["*"])
    %{scope: owner(wardrik)}
  end

  defp answers(responses) do
    {:ok, queue} = Agent.start_link(fn -> responses end)
    test = self()

    stub(ReqLLM, :stream_text, fn _model, messages, _opts ->
      send(test, {:prompted, messages})
      {:ok, Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end)}
    end)
  end

  defp system(messages) do
    [%{role: :system, content: [%{text: text}]} | _rest] = messages
    text
  end

  defp define(scope, id, definition),
    do: Wardrik.run(scope, "agent.define", Map.put(definition, "agent", id))

  test "keeps an agent's files, and reads its context into every turn", %{scope: scope} do
    answers([
      calling([
        call("call_1", "write_file", %{"path" => "MEMORY.md", "content" => "Likes tea."})
      ]),
      answer("Noted."),
      answer("Tea.")
    ])

    {:ok, _agent} =
      define(scope, "acme/triage", %{
        "model" => @model,
        "instructions" => "Be brief.",
        "tools" => ["files"],
        "context" => ["MEMORY.md"]
      })

    run!(scope, "agent.ask", %{"agent" => "acme/triage", "content" => "Remember I like tea."})
    assert_receive {:prompted, first}
    assert system(first) =~ "Be brief.\n\n# Your workspace"
    assert system(first) =~ "Not written yet: MEMORY.md."
    until("wardrik.run.completed")

    run!(scope, "agent.ask", %{"agent" => "acme/triage/C1", "content" => "What do I like?"})
    assert_receive {:prompted, _second}
    assert_receive {:prompted, third}
    assert system(third) =~ ~r/<file path="MEMORY.md" version="[^"]+">\nLikes tea.\n<\/file>/
  end

  test "shares trees its owner holds, and those the Wardrik shares", %{scope: scope} do
    files = %{"model" => @model, "tools" => ["files"]}

    assert {:ok, _agent} =
             define(
               scope,
               "acme/triage",
               Map.put(files, "workspace", %{"shared" => %{"team" => "acme"}})
             )

    assert {:ok, _agent} =
             define(
               scope,
               "acme/ops",
               Map.put(files, "workspace", %{"shared" => %{"runbooks" => "acme/runbooks"}})
             )

    read_only = %{"shared" => %{"runbooks" => %{"tree" => "acme/runbooks", "mode" => "read"}}}

    assert {:ok, _agent} =
             define(scope, "acme/@jon/notes", Map.put(files, "workspace", read_only))

    writing = %{"shared" => %{"runbooks" => "acme/runbooks"}}

    assert {:error, %Wardrik.Error{message: why}} =
             define(scope, "acme/@jon/notes", Map.put(files, "workspace", writing))

    assert why =~ "acme/@jon/notes can't write the tree acme/runbooks"

    assert {:error, _error} =
             define(
               scope,
               "acme/@jon/notes",
               Map.put(files, "workspace", %{"shared" => %{"t" => "globex"}})
             )

    assert {:error, _error} =
             define(
               scope,
               "acme/triage",
               Map.put(files, "workspace", %{"shared" => %{"t" => "acme/@jon/x"}})
             )

    assert {:ok, _agent} =
             define(
               scope,
               "acme/@jon/mine",
               Map.put(files, "workspace", %{"shared" => %{"t" => "acme/@jon/x"}})
             )

    assert {:error, _error} =
             define(
               scope,
               "acme/triage",
               Map.put(files, "workspace", %{"shared" => %{"bad name" => "acme"}})
             )
  end

  test "reads a budget of context, and refuses one out of range", %{scope: scope} do
    base = %{"model" => @model}

    assert {:ok, _agent} =
             define(
               scope,
               "acme/triage",
               Map.put(base, "context", %{"files" => ["A.md"], "max_bytes" => 2048})
             )

    assert {:error, _error} =
             define(
               scope,
               "acme/triage",
               Map.put(base, "context", %{"files" => ["A.md"], "max_bytes" => 10})
             )

    many = for n <- 1..21, do: "#{n}.md"
    assert {:error, _error} = define(scope, "acme/triage", Map.put(base, "context", many))
  end
end
