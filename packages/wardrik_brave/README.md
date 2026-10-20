# wardrik_brave

Web search for [Wardrik](../wardrik) agents, through Brave's LLM Context API.
A search answers with the passages of each page that bear on the query rather
than a list of links, so one call is usually enough to ground an answer.

```elixir
def deps do
  [{:wardrik_brave, "~> 0.1.0"}]
end
```

Attach it to the `Wardrik.Host` agents run on, before Wardrik starts, with
the key it searches with, and a definition names it as `web_search`:

```elixir
host = WardrikBrave.attach(host, api_key: System.fetch_env!("BRAVE_API_KEY"))
```

Results are kept small, since each one becomes part of the turn that asked
for it.

The key is the deployment's, for every agent the host runs, whatever org
it is in. The host holds it, never the store; without one, a search answers
that the key is missing. The daemon attaches it with `config.yaml`'s
`brave.api_key`.

The pages it returns are ones anyone could have written, so a search is
labelled `outside`: once a turn has read one, a policy holds its gated tools'
calls for a person. See [policies](../wardrik/guides/policy.md).
