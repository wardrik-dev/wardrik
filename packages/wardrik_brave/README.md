# wardrik_brave

Web search for [Wardrik](../wardrik) agents, through Brave's LLM Context API.
A search answers with the passages of each page that bear on the query rather
than a list of links, so one call is usually enough to ground an answer.

```elixir
def deps do
  [{:wardrik_brave, "~> 0.1.0"}]
end
```

Attach it to the `Wardrik.Host` agents run on, before Wardrik starts, and
a definition names it as `web_search`:

```elixir
host = WardrikBrave.attach(host)
```

Results are kept small, since each one becomes part of the turn that asked
for it.

Its key is the credential `BRAVE_API_KEY`, which the host's
`Wardrik.Credentials` resolve for each call as the agent's owner holds it.
With [the vault](../wardrik/guides/vault.md) each org seals its own
(`wardrik vault put BRAVE_API_KEY --org acme`):

```elixir
:ok = WardrikVault.put(vault, "BRAVE_API_KEY", Wardrik.Resource.parse!("acme"), value: key)
host = Wardrik.Host.new(store: store, credentials: vault)
```

The pages it returns are ones anyone could have written, so a search is
labelled `outside`: once a turn has read one, a policy holds its gated tools'
calls for a person. See [policies](../wardrik/guides/policy.md).
