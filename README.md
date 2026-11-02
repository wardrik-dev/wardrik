# WardrikTesting

A `Wardrik.Server` for testing packages built on
[WardrikProtocol](https://hexdocs.pm/wardrik_protocol), without Wardrik itself.

## Install

```elixir
def deps do
  [
    {:wardrik_testing, "~> 0.1.0-rc.2", only: :test}
  ]
end
```

## Usage

```elixir
setup context do
  name = :"server #{context.test}"
  :ok = WardrikTesting.Server.start(name, offered: [{"acme/triage", ["chat"]}])
  %{scope: Wardrik.Scope.new(WardrikTesting.Server, wardrik: name, principal: "user_42")}
end

test "asks the agent", %{scope: scope} do
  {:ok, _message} = Wardrik.Agent.ask(scope, "acme/triage", "Hi", conversation: "t1")
  assert_received {:asked, {"acme/triage", "t1"}, "Hi", "user_42"}
end
```

* Pass `{WardrikTesting.Server, name}` wherever a package takes a Wardrik server.
* See `WardrikTesting.Server` for the messages your test receives and how it answers.
