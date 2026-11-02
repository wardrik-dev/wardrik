# WardrikBrave

Web search for agents, through Brave's LLM Context API. A search returns the relevant passages of
each page, not a list of links, so one call is usually enough to ground an answer.

```elixir
def deps do
  [
    {:wardrik_brave, "~> 0.1.0-rc.1"}
  ]
end
```

## Usage

Start it under a name of your own, then give agents the capability by that name:

```elixir
children = [{WardrikBrave, name: MyApp.Brave, api_key: System.fetch_env!("BRAVE_API_KEY")}]

WardrikCore.start_agent(
  agent_id: "acme/triage",
  model: "anthropic:claude-haiku-4-5",
  capabilities: [{WardrikBrave, brave: MyApp.Brave}]
)
```

In [Wardrik](https://hexdocs.pm/wardrik), offer it by name. A definition then names it in its
`tools`:

```elixir
config :my_app, MyApp.AgentRuntime, capabilities: [web_search: {WardrikBrave, brave: MyApp.Brave}]
```

The daemon sets this up from `brave.api_key` in `config.yaml`. `wardrik vault put BRAVE_API_KEY`
can hold the key.

## Keys

Each search looks for `BRAVE_API_KEY` in this order:

1. The agent's `WardrikCore.Keys`, Wardrik's `:key_source`. In `wardrik_daemon`, that's the
   vault: the owner's, the org's, then the deployment's.
2. The `:api_key` it was started with.

So an org can bring its own key, and changing the deployment's needs no restart:

```sh
echo "$KEY" | wardrik vault put BRAVE_API_KEY --for api_key
```

If every agent's keys hold one, nothing needs starting. Give the capability its settings inline:

```elixir
capabilities: [web_search: {WardrikBrave, []}]
```

Neither key is kept in the store with an agent's state. Without a key, the search returns an error
saying so, and the agent can tell the user.

Results are kept small, since each becomes part of the turn that asked: 10 results and about 4,096
tokens unless the agent asks for more.
