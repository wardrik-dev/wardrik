# wardrik_brave

Web search for [Wardrik](../wardrik) agents, through Brave's LLM Context API.
A search answers with the passages of each page that bear on the query rather
than a list of links, so one call is usually enough to ground an answer.

```elixir
def deps do
  [{:wardrik_brave, "~> 0.1.0"}]
end
```

```elixir
Wardrik.LLM.Config.new(tools: [WardrikBrave.WebSearch])
```

The agent calls it as `web_search`. Results are kept small, since each one
becomes part of the turn that asked for it.

Its key is the credential `BRAVE_API_KEY`, which the host's
`Wardrik.Credentials` resolve for each call. With
[wardrik_vault](../wardrik_vault) that is the deployment's secret of that name
(`wardrik vault put BRAVE_API_KEY`), or the environment variable where the
vault holds none, where the vault shares it with every agent:

```elixir
vault = WardrikVault.new(store: store, keys: [key], shared: ["BRAVE_API_KEY"])
host = Wardrik.Host.new(store: store, credentials: vault)
```

The pages it returns are ones anyone could have written, so a search is
labelled `outside`: once a turn has read one, a policy holds its gated tools'
calls for a person. See [wardrik_policy](../wardrik_policy).
