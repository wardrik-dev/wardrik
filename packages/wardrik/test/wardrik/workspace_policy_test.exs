defmodule Wardrik.WorkspacePolicyTest do
  @moduledoc "A policy's rules name a file tool's call by its path, as the workspace declares it."

  use ExUnit.Case, async: true

  alias Wardrik.Call
  alias WardrikWorkspace.Spec

  test "a policy names a file tool's call by its path" do
    policy = WardrikPolicy.decode!(%{"deny" => ["write_file(secrets/*)", "delete_file(*)"]})
    id = Wardrik.AgentID.parse!("ws#{System.unique_integer([:positive])}/agent")
    {:ok, spec} = Spec.new(id, %{})

    scope =
      Wardrik.Test.scope(
        tools: [{WardrikWorkspace, spec}],
        id: id,
        name: "turn",
        hooks: WardrikPolicy.hooks(policy),
        host:
          Wardrik.Test.host(
            workspace: %WardrikWorkspace.Backend.Store{store: Wardrik.Test.store()}
          )
      )

    assert {:ok, %{"ok" => true}} =
             answered(scope, "write_file", %{"path" => "notes/a.md", "content" => "x"})

    assert {:ok, %{"ok" => false}} =
             answered(scope, "write_file", %{"path" => "secrets/key", "content" => "x"})

    assert {:ok, %{"ok" => false}} = answered(scope, "delete_file", %{"path" => "notes/a.md"})
  end

  defp answered(scope, tool, arguments) do
    %Call{state: :done, result: result} = Wardrik.Test.call(scope, tool, arguments)
    result
  end
end
