defmodule Wardrik.Test.Files do
  @moduledoc "Declarations that declare `acme/triage`, and tell the test when they're read again."
  @behaviour Wardrik.Declarations

  @impl Wardrik.Declarations
  def declared?(_test, id), do: id == "acme/triage"

  @impl Wardrik.Declarations
  def reload(test) do
    send(test, :reloaded)
    ["acme/broken: There's no tool nope here."]
  end
end

defmodule Wardrik.DeclarationsTest do
  use ExUnit.Case, async: false

  import Wardrik.Test.Wardrik

  @model "anthropic:claude-haiku-4-5"

  setup context do
    store = Wardrik.Test.Store.new(:"store #{context.test}")
    name = :"wardrik #{context.test}"

    start_supervised!({WardrikStore, store})

    start_supervised!(
      {Wardrik, Wardrik.new(name: name, store: store, declarations: {Wardrik.Test.Files, self()})}
    )

    scope = owner(name)

    for id <- ["acme/triage", "acme/notes"],
        do: run!(scope, "agent.define", %{"agent" => id, "model" => @model})

    %{scope: scope}
  end

  test "keeps a declared agent the API asks to forget", %{scope: scope} do
    assert refused(scope, "agent.forget", %{"agent" => "acme/triage"}) == :conflict

    assert %{
             "forgotten" => ["acme/notes"],
             "kept" => [%{"id" => "acme/triage", "why" => "declared by a file"}]
           } =
             run!(scope, "agents.forget", %{"resources" => ["acme/*"]})
  end

  test "lets only a declared agent write allow_after in place", %{scope: scope} do
    policy = %{"allow_after" => %{"outside" => ["github/add_labels"]}}

    assert %{} =
             run!(scope, "agent.define", %{
               "agent" => "acme/triage",
               "model" => @model,
               "policy" => policy
             })

    assert refused(scope, "agent.define", %{
             "agent" => "acme/notes",
             "model" => @model,
             "policy" => policy
           }) == :invalid_request
  end

  test "reads its declarations again as the deployment reloads", %{scope: scope} do
    assert %{"problems" => ["acme/broken: There's no tool nope here."]} =
             run!(scope, "deployment.reload", %{})

    assert_received :reloaded
  end
end
