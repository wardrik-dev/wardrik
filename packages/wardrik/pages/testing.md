# Testing

`Wardrik.Testing.Server` is a `Wardrik.Server` that answers from a script. Use it to test a
package built on `WardrikProtocol`, such as a chat adapter, without running agents.

## Usage

```elixir
defmodule MyApp.AgentTest do
  use ExUnit.Case, async: true

  setup context do
    name = :"server #{context.test}"
    :ok = Wardrik.Testing.Server.start(name, offered: [{"acme/triage", ["chat"]}])
    %{scope: Wardrik.Scope.new(Wardrik.Testing.Server, wardrik: name, principal: "user_42")}
  end

  test "asks the agent", %{scope: scope} do
    {:ok, _message} = Wardrik.Agent.ask(scope, "acme/triage", "Hi", conversation: "t1")
    assert_received {:asked, {"acme/triage", "t1"}, "Hi", "user_42"}
  end
end
```

Save the module as `test/agent_test.exs`. Your `test/test_helper.exs` must call `ExUnit.start()`.
Run `mix test test/agent_test.exs`.

* Pass `{Wardrik.Testing.Server, name}` wherever a package takes a Wardrik server.
* See `Wardrik.Testing.Server` for the messages your test receives and how it answers.
