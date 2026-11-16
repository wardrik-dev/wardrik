# Testing

## Agents

`Wardrik.Testing.Model` is a model for tests. It serves the Chat Completions API on a port of its
own and answers each call with the next answer it's given. Point Wardrik's `:endpoints` at it, and
tests that run agents can be async.

```elixir
defmodule MyApp.AgentTest do
  use ExUnit.Case, async: true

  alias Wardrik.Testing.Model

  setup context do
    model = start_supervised!({Model, [Model.text("Friday.")]})
    name = :"wardrik #{context.test}"

    start_supervised!(
      {Wardrik,
       Wardrik.new(
         name: name,
         authorizer: {MyApp.AllowAll, []},
         resolver: {MyApp.Agents, []},
         endpoints: %{"test" => Model.endpoint(model)}
       )}
    )

    %{model: model, scope: Wardrik.as(name, "maria")}
  end

  test "answers from the script", %{scope: scope} do
    {:ok, agent} = Wardrik.Agent.define(scope, "agt_assistant", model: "test")

    assert {:ok, %Wardrik.Reply{text: "Friday."}} =
             Wardrik.Agent.reply(scope, agent, "When is the release?")
  end
end
```

`MyApp.AllowAll` and `MyApp.Agents` are the authorizer and resolver from the
[README](../README.md).

* Each test starts its own model and its own Wardrik, named for the test.
* An agent whose `model` is `"test"` calls the model.
* `Model.text/1` answers with text. `Model.calls/1` answers with tool calls, each
  `{id, name, args}`.
* `Model.answer/2` adds answers after those left.
* A function answers every call. It takes the request, and `Model.messages/1` reads the messages
  in it:

  ```elixir
  test = self()

  Model.answer(model, fn request ->
    send(test, {:sent, Model.messages(request)})
    Model.text("Monday.")
  end)
  ```

* `{:status, 400, "Bad request."}` fails a call. Wardrik keeps the turn going: it retries the
  call as the definition's `retries` say, then asks a person whether to try again. `reply/3`
  returns `{:waiting, [%Wardrik.Interrupt{reason: :model_approval}]}`.
* Retries wait between attempts. A test of a failing model can set `retries: %{attempts: 0}` to
  reach the question at once.
* A call with no answer left stops the test model, and the call fails.

## Adapters

`Wardrik.Testing.Server` is a `Wardrik.Server` that answers from a script. Use it to test a
package built on `WardrikProtocol`, such as a chat adapter, without running agents.

```elixir
defmodule MyApp.AdapterTest do
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

* Pass `{Wardrik.Testing.Server, name}` wherever a package takes a Wardrik server.
* See `Wardrik.Testing.Server` for the messages your test receives and how it answers.
