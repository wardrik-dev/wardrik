# wardrik_http

[Wardrik](../wardrik)'s agents over HTTP: a versioned JSON API, each agent's
event log as server-sent events a client resumes after any disconnect, and a
socket tool workers hold open to offer agents tools of their own.

```elixir
def deps do
  [{:wardrik_http, "~> 0.1.0"}]
end
```

The daemon serves it on `127.0.0.1:4747`. Every request presents a token, which
reaches the agents under a scope and may take only the actions it was given:

```sh
wardrik token create ci --scope acme/ --role reader,messenger,definer --policy careful
wardrik token create watcher --scope acme/@ops/ --role reader

curl -H "authorization: Bearer $TOKEN" http://127.0.0.1:4747/v1/agents
```

A token allows its roles' actions on the agents under its scope, and nothing
else. Its policy holds every agent it defines, so what a definition says can
narrow it and never widen it. An expired token answers `401`. A revoked token
is refused at once, and the streams and sockets open on it are closed.

The [HTTP API reference](https://docs.wardrik.dev/reference/http-api/) lists
every route, and the [TypeScript SDK](../../sdks/typescript) drives it from
Node.
