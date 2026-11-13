# WardrikRest

Tools for agents from an HTTP API's description: one tool per operation, with the API's own
sign-in and keys. Use it for an API that has no MCP server, or one whose server falls short.

```elixir
def deps do
  [
    {:wardrik_rest, "~> 0.1.0-rc.1"}
  ]
end
```

## Usage

```elixir
{:ok, analytics} =
  WardrikRest.API.load(
    {WardrikRest.Discovery,
     url: "https://analyticsdata.googleapis.com/$discovery/rest?version=v1beta"},
    name: "ga4",
    base_url: "https://analyticsdata.googleapis.com/",
    auth: %{"oauth2" => {:credential, "google"}},
    only: ["properties_runReport", "properties_getMetadata"],
    read_only: ["properties_runReport"]
  )

WardrikCore.start_agent(
  agent_id: "agt_marketing",
  model: "anthropic:claude-haiku-4-5",
  capabilities: [{WardrikRest, apis: [analytics]}],
  credentials: {MyApp.Credentials, []}
)
```

The agent gets `ga4__properties_runReport` and `ga4__properties_getMetadata`.

- Load an API once, as your app starts or adds it.
- `only` keeps tool definitions small. Each one goes into every model call.
- `GET`s and the operations in `read_only` are read-only. The rest ask a person unless the policy
  allows them.

## Credentials

`auth` maps each scheme the description names to a source:

- `{:credential, name}` - a person's token from `WardrikCore.Credentials`. Until they sign in, the
  call waits for them. A refused token is refreshed once.
- `{:key, name}` - a key from `WardrikCore.Keys`, such as one an org pasted.

`headers` adds headers the description doesn't name, such as a developer token. `schemes` adds
schemes it doesn't name, such as `%{"token" => :bearer}` for an API that documents its sign-in
elsewhere. Secrets go only
to `base_url`, and never into arguments, answers or errors.

## Formats

A source is a reader and what it reads, as `{WardrikRest.Discovery, url: url}`.

- OpenAPI 3.0 and 3.1, in JSON or YAML: `WardrikRest.OpenAPI`, from a `url`, a `path` or a decoded
  `document`. JSON and form-encoded bodies are sent; file uploads and HTTP basic aren't yet.
- Google Discovery documents: `WardrikRest.Discovery`, from a `url` or a decoded `document`.
- Other formats: a module with the `WardrikRest.Reader` behaviour, whose `read/1` returns a
  `WardrikRest.Spec`. Its schemas refer to the spec's `types` by name, and tools are fitted from
  them.

## Related

- [wardrik_core](https://github.com/wardrik-dev/wardrik/tree/main/packages/wardrik_core) - the
  `Credentials` and `Keys` seams.
- [wardrik](https://github.com/wardrik-dev/wardrik/tree/main/packages/wardrik) - MCP servers and
  OAuth sign-in.

## License

Apache-2.0
