# Changelog

## 0.1.0-rc.2

### Breaking

- `WardrikTesting.Server` takes a conversation as its own `"conversation"` field, keeps its
  events in the log `{agent, conversation}`, and sends `{:asked, {agent, conversation}, ...}`.
  `missing` is the agent never found.
- `WardrikTesting.Server` implements `Wardrik.Server` rc.2: `run/1` and `stream/1` take a
  `Wardrik.Server.Request`, and `follow/2` a `Wardrik.Server.Follow`.
- `WardrikTesting.Server` takes `:authorize`, which decides each request, for `:secrets`, and
  `authenticate/2` and `revoke/2` are gone.
- `WardrikTesting.Server.add_agent/2` takes the agent's `:id`, `:channels` and `:description` by
  name.

## 0.1.0-rc.1 (2026-10-30)

- `WardrikTesting.Server`, a `Wardrik.Server` that runs Wardrik's operations as a script, for
  packages that can't depend on Wardrik itself.
- A message to the test for each operation, stream, message and worker's tools.
- The protocol's example output for most operations. The `:offered` agents are listed and defined,
  and `acme/missing` is never found.
- `WardrikTesting.Script`, which answers messages in the conversation's log: `echo` waits on a
  call, `fail` fails, and anything else is answered.
- Handed to an HTTP surface or a channel as `{WardrikTesting.Server, name}`, as Wardrik passes
  itself.
