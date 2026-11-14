defmodule Wardrik.Workspace.ContextTest do
  use ExUnit.Case, async: true

  alias Wardrik.Workspace.Context
  alias Wardrik.Workspace.Mount

  setup context do
    store = Wardrik.Store.ETS.new(name: :"store #{context.test}")
    start_supervised!({Wardrik.Store, store})

    opts = [
      store: store,
      tree: "agents/acme/agent/triage",
      shared: [%Mount{name: "runbooks", tree: "shared/acme/runbooks", mode: :read}]
    ]

    offered = Wardrik.Workspace.tools(nil, opts)
    tools = Map.new(offered, &{&1.name, &1})

    write = fn path, content ->
      tools["write_file"].run.(
        %{path: path, content: content},
        Wardrik.Context.new(agent_id: "a")
      )
    end

    %{opts: opts, write: write}
  end

  test "tells the agent the files it names, what's not written, what else is there, and what's shared",
       %{opts: opts, write: write} do
    write.("MEMORY.md", "Likes tea.")
    write.("notes/a.md", "x")
    write.("todo.md", "y")
    file = %Wardrik.Workspace.File{content: "z"}

    {:ok, _version} =
      Wardrik.Workspace.Files.write(opts[:store],
        tree: "shared/acme/runbooks",
        path: "deploy.md",
        file: file,
        version: nil
      )

    spec = Wardrik.Workspace.Spec.new(opts)
    text = Context.text(spec, ["MEMORY.md", "SOUL.md", "shared/runbooks/deploy.md"], 16_384)

    assert text =~ "# Your workspace"
    assert text =~ ~r/<file path="MEMORY.md" version="[^"]+">\nLikes tea.\n<\/file>/
    assert text =~ ~s(<file path="shared/runbooks/deploy.md")
    assert text =~ "Not written yet: SOUL.md."
    assert text =~ "Also at the top of your workspace: notes/, todo.md."
    assert text =~ "Shared with you: shared/runbooks (read only)."
  end

  test "reads a long file's start and end, and asks for it shorter", %{opts: opts, write: write} do
    write.("MEMORY.md", Enum.map_join(1..200, "\n", &"line #{&1}"))
    write.("SOUL.md", "short")

    spec = Wardrik.Workspace.Spec.new(opts)
    text = Context.text(spec, ["MEMORY.md", "SOUL.md"], 200)

    assert text =~ "line 1\n"
    assert text =~ "line 200\n</file>"
    assert text =~ "bytes are left out here"
    assert text =~ "MEMORY.md is longer than what's read of it into each turn."
    assert text =~ "<file path=\"SOUL.md\""
  end

  test "labels the turn with what the files it reads hold", %{opts: opts} do
    reader = %{
      Wardrik.Context.new(agent_id: "a")
      | messages: [ReqLLM.Context.user("Hi.", %{labels: ["outside"]})]
    }

    offered = Wardrik.Workspace.tools(nil, opts)
    tools = Map.new(offered, &{&1.name, &1})
    tools["write_file"].run.(%{path: "MEMORY.md", content: "From a page."}, reader)

    turn = %{
      Wardrik.Context.new(agent_id: "a")
      | step: :turn,
        messages: [ReqLLM.Context.user("Go.")]
    }

    assert {:ok, %{messages: [%{metadata: %{labels: ["outside"]}}]}} =
             Context.call(turn, &{:ok, &1}, opts ++ [files: ["MEMORY.md"]])

    assert {:ok, %{messages: [%{metadata: metadata}]}} = Context.call(turn, &{:ok, &1}, opts)
    refute Map.has_key?(metadata, :labels)
  end

  test "adds itself to a turn's instructions, and leaves them as they were after", %{opts: opts} do
    context = Wardrik.Context.new(agent_id: "a")
    turn = %{context | step: :turn, instructions: "Be brief."}

    next = fn context ->
      send(self(), {:instructions, context.instructions})
      {:ok, context}
    end

    assert {:ok, %{instructions: "Be brief."}} =
             Context.call(turn, next, opts ++ [files: ["MEMORY.md"]])

    assert_received {:instructions, "Be brief.\n\n# Your workspace" <> _rest}

    parking = fn context -> {:park, :waiting, context} end
    assert {:park, :waiting, %{instructions: "Be brief."}} = Context.call(turn, parking, opts)
    assert {:error, :boom} = Context.call(turn, fn _context -> {:error, :boom} end, opts)

    bare = %{turn | instructions: nil}
    assert {:ok, %{messages: []}} = Context.call(bare, next, opts ++ [files: ["MEMORY.md"]])
    assert_received {:instructions, _text}
    bare = %{turn | instructions: nil}
    assert {:ok, %{instructions: nil}} = Context.call(bare, next, opts)
    assert_received {:instructions, "# Your workspace" <> _rest}

    other = %{turn | step: :generate}
    assert {:ok, %{instructions: "Be brief."}} = Context.call(other, next, opts)
  end
end
