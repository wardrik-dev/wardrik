defmodule Wardrik.Workspace.AgentsTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.LLM
  import Wardrik.Test.Wardrik

  @model "anthropic:claude-haiku-4-5"
  @shares %{
    "acme/ops" => %{"acme/runbooks" => :write},
    "acme/@jon/notes" => %{"acme/runbooks" => :read}
  }

  setup :set_mimic_global

  setup context do
    store = Wardrik.Test.Store.new(:"store #{context.test}")

    wardrik =
      Wardrik.new(
        authorizer: {Wardrik.Test.Allow, []},
        resolver: {Wardrik.Test.Owned, {:"wardrik #{context.test}", shares: @shares}},
        name: :"wardrik #{context.test}",
        store: store
      )

    start_supervised!({Wardrik.Store, store})
    start_supervised!({Wardrik, wardrik})
    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    :ok = Wardrik.EventLog.subscribe(Wardrik.events(wardrik), :all)
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

    run!(scope, "agent.ask", %{
      "agent" => "acme/triage",
      "conversation" => "C1",
      "content" => "What do I like?"
    })

    assert_receive {:prompted, _second}
    assert_receive {:prompted, third}
    assert system(third) =~ ~r/<file path="MEMORY.md" version="[^"]+">\nLikes tea.\n<\/file>/
  end

  test "mounts only the workspaces the resolver shares, with only the access given", %{
    scope: scope
  } do
    files = %{"model" => @model, "tools" => ["files"]}
    shared = &Map.put(files, "workspace", %{"shared" => &1})

    assert {:ok, _agent} = define(scope, "acme/ops", shared.(%{"runbooks" => "acme/runbooks"}))

    assert {:ok, _agent} =
             define(scope, "acme/@jon/notes", shared.(%{"runbooks" => "acme/runbooks"}))

    reading = %{"runbooks" => %{"agent" => "acme/runbooks", "mode" => "read"}}
    assert {:ok, _agent} = define(scope, "acme/ops", shared.(reading))

    writing = %{"runbooks" => %{"agent" => "acme/runbooks", "mode" => "write"}}

    assert {:error, %Wardrik.Error{message: why}} =
             define(scope, "acme/@jon/notes", shared.(writing))

    assert why =~ "acme/@jon/notes can't write acme/runbooks's workspace"

    assert {:error, %Wardrik.Error{message: why}} =
             define(scope, "acme/triage", shared.(%{"runbooks" => "acme/runbooks"}))

    assert why =~ "its resolver doesn't share it"

    assert {:error, _error} = define(scope, "acme/ops", shared.(%{"bad name" => "acme/runbooks"}))
  end

  test "mounts a read share read only, and a write share as written" do
    wardrik =
      Wardrik.new(
        authorizer: {Wardrik.Test.Allow, []},
        resolver: {Wardrik.Test.Owned, :w},
        name: :w
      )

    definition = %{"workspace" => %{"shared" => %{"runbooks" => "acme/runbooks"}}}

    resolve =
      &Wardrik.Workspace.Agents.resolve(wardrik,
        agent: &1,
        definition: definition,
        workspaces: &2,
        files: true
      )

    assert {:ok, [capabilities: [{Wardrik.Workspace, read}], middleware: []]} =
             resolve.("acme/@jon/notes", %{"acme/runbooks" => :read})

    assert [
             %Wardrik.Workspace.Mount{
               name: "runbooks",
               tree: "agents/acme%2Frunbooks",
               mode: :read
             }
           ] =
             read[:shared]

    assert {:ok, [capabilities: [{Wardrik.Workspace, written}], middleware: []]} =
             resolve.("acme/ops", %{"acme/runbooks" => :write})

    assert [%Wardrik.Workspace.Mount{mode: :write}] = written[:shared]
    assert written[:tree] == "agents/acme%2Fops"

    assert {:error, _error} = resolve.("acme/triage", %{"acme/other" => :write})
  end

  test "keeps each agent's tree in one segment, whatever its ID holds" do
    ids = ["..", "../acme/ops", "acme/ops", "acme//ops", "acme%2Fops", "acme ops/.."]
    trees = Enum.map(ids, &Wardrik.Workspace.Agents.tree/1)

    for {id, tree} <- Enum.zip(ids, trees) do
      assert ["agents", segment] = String.split(tree, "/")
      assert URI.decode_www_form(segment) == id
    end

    assert trees == Enum.uniq(trees)
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
