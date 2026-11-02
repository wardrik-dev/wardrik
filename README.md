# WardrikTesting

A `Wardrik.Server` for testing packages built on
[Wardrik's protocol](https://hexdocs.pm/wardrik_protocol), without Wardrik itself.

Packages under the hub, such as a channel or an HTTP surface, can't depend on the hub, even in
tests. They test against this server instead. The hub's own suite tests them together, end to end.

## Install

```elixir
def deps do
  [
    {:wardrik_testing, "~> 0.1.0-rc.1", only: :test}
  ]
end
```

## Usage

Start the server under a name unique to the test, and act through a scope on it:

```elixir
setup context do
  name = :"server #{context.test}"

  :ok = WardrikTesting.Server.start(name, offered: [{"acme/triage", ["chat"]}])
  scope = Wardrik.Scope.new(WardrikTesting.Server, wardrik: name, principal: "acme/@maria")

  %{scope: scope}
end

test "asks the agent", %{scope: scope} do
  {:ok, _message} = Wardrik.Agent.ask(scope, "acme/triage/t1", "Hi")
  assert_received {:asked, "acme/triage/t1", "Hi", "acme/@maria"}
end
```

Give an HTTP surface or a channel the server as `{WardrikTesting.Server, name}`, the same way the
hub passes itself.

## What the test receives

| Message | Sent for |
| --- | --- |
| `{:ran, id, input}` | each operation |
| `{:streamed, id, input}` | each stream |
| `{:asked, conversation, text, principal_id}` | each message |
| `{:offered, worker, tools}` | each worker's tools |

## How it answers

* `:authorize` decides each operation and stream first, as a `Wardrik.Authorizer` would. It
  allows everything unless set.
* Most operations return the protocol's own example output.
* The `:offered` agents are listed and defined.
* `acme/missing` is never found.

To have messages answered in the conversation's log, start `WardrikEvents` under
`WardrikTesting.Server.events(name)`. Then:

* `echo` waits on the call `call_1`.
* `fail` fails.
* Anything else is answered `"Answered: "` followed by the message.

See `WardrikTesting.Script`.
