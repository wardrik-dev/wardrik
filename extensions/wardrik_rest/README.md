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
{:ok, discovery} =
  WardrikRest.Discovery.fetch(
    "https://analyticsdata.googleapis.com/$discovery/rest?version=v1beta"
  )

{:ok, analytics} =
  WardrikRest.API.load(discovery,
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

`headers` adds headers the description doesn't name, such as a developer token. Secrets go only
to `base_url`, and never into arguments, answers or errors.

## Formats

- Google Discovery documents: `WardrikRest.Discovery`.
- Other formats: implement `WardrikRest.Reader` for a struct holding the description.

## Related

- [wardrik_core](https://github.com/wardrik-dev/wardrik/tree/main/packages/wardrik_core) - the
  `Credentials` and `Keys` seams.
- [wardrik](https://github.com/wardrik-dev/wardrik/tree/main/packages/wardrik) - MCP servers and
  OAuth sign-in.

## License

Apache-2.0
