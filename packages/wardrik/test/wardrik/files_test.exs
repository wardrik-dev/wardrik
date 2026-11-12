defmodule Wardrik.FilesTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.LLM
  import Wardrik.Test.Wardrik

  @model "anthropic:claude-haiku-4-5"
  @agent "acme/triage"

  setup :set_mimic_global

  setup context do
    store = Wardrik.Test.Store.new(:"store #{context.test}")

    wardrik =
      Wardrik.new(
        authorizer: {Wardrik.Test.Allow, []},
        resolver: {Wardrik.Test.Owned, {:"wardrik #{context.test}", []}},
        name: :"wardrik #{context.test}",
        store: store
      )

    start_supervised!({Wardrik.Store, store})
    start_supervised!({Wardrik, wardrik})
    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    scope = owner(wardrik)

    {:ok, _agent} =
      Wardrik.run(scope, "agent.define", %{
        "agent" => @agent,
        "model" => @model,
        "tools" => ["files"],
        "context" => ["MEMORY.md"]
      })

    %{scope: scope}
  end

  defp put(scope, path, content, input \\ %{}),
    do:
      Wardrik.run(
        scope,
        "agent.file_put",
        Map.merge(%{"agent" => @agent, "path" => path, "content" => content}, input)
      )

  test "writes a file the agent reads into its turn, as its own", %{scope: scope} do
    {:ok, written} = put(scope, "MEMORY.md", "Likes tea.")

    assert %{"path" => "MEMORY.md", "bytes" => 10, "by" => by, "labels" => []} = written
    assert by == scope.principal.id

    test = self()

    stub(ReqLLM, :stream_text, fn _model, messages, _opts ->
      send(test, {:prompted, messages})
      {:ok, answer("Tea.")}
    end)

    run!(scope, "agent.ask", %{"agent" => @agent, "content" => "What do I like?"})
    assert_receive {:prompted, [%{role: :system, content: [%{text: system}]} | _rest]}
    assert system =~ ~r/<file path="MEMORY.md" version="[^"]+">\nLikes tea.\n<\/file>/
  end

  test "reads, lists by glob, and deletes", %{scope: scope} do
    {:ok, _written} = put(scope, "skills/triage/SKILL.md", "---\nname: triage\n---\n")
    {:ok, _written} = put(scope, "notes/today.md", "Quiet.")

    assert %{"files" => [%{"path" => "skills/triage/SKILL.md"}]} =
             run!(scope, "agent.files", %{"agent" => @agent, "glob" => "skills/**"})

    assert %{"files" => [_newest, _older]} = run!(scope, "agent.files", %{"agent" => @agent})

    assert {:ok, %Wardrik.AgentFile{path: "notes/today.md", bytes: 6}, "Quiet."} =
             Wardrik.Agent.file(scope, @agent, path: "./notes//today.md")

    assert run!(scope, "agent.file_delete", %{"agent" => @agent, "path" => "notes/today.md"}) ==
             nil

    assert refused(scope, "agent.file", %{"agent" => @agent, "path" => "notes/today.md"}) ==
             :not_found

    assert %{"events" => changes} = run!(scope, "audit.list", %{})
    types = Enum.map(changes, & &1["type"])
    assert "wardrik.file.written" in types
    assert "wardrik.file.removed" in types
  end

  test "writes over a version only while the file is at it", %{scope: scope} do
    {:ok, %{"version" => first}} = put(scope, "MEMORY.md", "One.")
    {:ok, %{"version" => second}} = put(scope, "MEMORY.md", "Two.")
    refute second == first

    assert {:error, %Wardrik.Error{type: :conflict}} =
             put(scope, "MEMORY.md", "Three.", %{"version" => first})

    assert {:ok, %{"version" => _third}} =
             put(scope, "MEMORY.md", "Three.", %{"version" => second})
  end

  test "refuses paths outside the workspace, files over 4 MiB, and agents not there", %{
    scope: scope
  } do
    assert {:error, %Wardrik.Error{type: :invalid_request}} = put(scope, "../x.md", "No.")
    assert {:error, %Wardrik.Error{type: :invalid_request}} = put(scope, "/etc/x", "No.")

    assert {:error, %Wardrik.Error{type: :invalid_request}} =
             put(scope, "big.md", String.duplicate("a", 4 * 1024 * 1024 + 1))

    assert refused(scope, "agent.files", %{"agent" => "acme/none"}) == :not_found
  end
end
