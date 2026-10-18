defmodule WardrikHTTP do
  @moduledoc """
  Wardrik's agents over HTTP: a versioned JSON API, and each agent's event log
  as server-sent events a client resumes after any disconnect. The
  [HTTP API](http-api.md) guide is every route, for whoever calls them.

  `WardrikHTTP.Listener` serves it, on `127.0.0.1:4747` unless `config.yaml`'s
  `http` says otherwise. Every request presents a token, which
  `WardrikHTTP.Token` makes and `WardrikHTTP.Tokens` checks, unless the
  listener is given another `WardrikHTTP.Authenticator`, such as a sign-in,
  which answers the caller's `Wardrik.Token` the same way.

  ## The host

  The routes act through the `Wardrik.Host` the listener was started with. Its
  `:definitions`, a `Wardrik.Definition`, reads a definition put, and decides
  whether definitions are kept and who owns a key: a key it refuses answers
  `409`. A daemon reads one as an agent file (see `WardrikDaemon.AgentFile`)
  and refuses the keys its agent files declare. A route the host's module
  answers `:unsupported`, as every one where the host names none does,
  answers `501`. Connections are offered by the host's `:connections`; see
  `Wardrik.Connections`.

  ## What answers

  Each route calls a function of `Wardrik`, and `Wardrik.Resource` shows
  what it answers. `WardrikProtocol`'s `openapi.json` is every route, what
  it takes and answers, and that function, each resource a JSON Schema
  beside the events'. `WardrikHTTP.EventStream`
  serves an agent's log, `Wardrik.Event.Export` an export, and
  `WardrikHTTP.Worker` and `WardrikHTTP.Workers` tool workers. A request that
  changes something is recorded in `Wardrik.Audit` with the caller's
  principal.
  """
end
