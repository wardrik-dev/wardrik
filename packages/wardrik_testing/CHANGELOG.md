# Changelog

## 0.1.0-rc.3 (2026-11-06)

- Requires `wardrik_protocol` 0.1.0-rc.5 and `wardrik_events` 0.1.0-rc.6.
- The scripted `echo` interrupt carries its `arguments`.

## 0.1.0-rc.2 (2026-11-02)

### Breaking

- `WardrikTesting.Server` implements rc.2's `Wardrik.Server`: `run/1` and `stream/1` take a
  `Wardrik.Server.Request`, and `follow/2` a `Wardrik.Server.Follow`.
- A conversation is the input's `"conversation"` field. Events go to the log
  `{agent, conversation}`, and the test receives `{:asked, {agent, conversation}, text, principal_id}`.
- `missing` is the agent never found.
- `:authorize`, a function that decides each request, replaces `:secrets`. `authenticate/2` and
  `revoke/2` are gone.
- `add_agent/2` takes `:id`, `:channels` and `:description` by name.

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
