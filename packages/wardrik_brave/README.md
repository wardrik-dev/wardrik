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
# config/runtime.exs
config :wardrik_brave, WardrikBrave, api_key: System.fetch_env!("BRAVE_API_KEY")
```

```elixir
Wardrik.LLM.Config.new(tools: [WardrikBrave.WebSearch])
```

The agent calls it as `web_search`. Results are kept small, since each one
becomes part of the turn that asked for it.

The pages it returns are ones anyone could have written, so a search counts
as content from outside: once a turn has read one, its gated tools wait on a
person. See [wardrik_policy](../wardrik_policy).
