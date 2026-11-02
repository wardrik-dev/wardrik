# Credentials

A tool that acts as a person needs their token. A `WardrikCore.Credentials` module finds it, by
the credential's name and the principal the turn acts for.

## Setup

Paste this into a fresh IEx session. The model calls need an Anthropic key. `MyApp.Tokens` stands
in for your app's own token table:

```elixir
Mix.install([{:wardrik_core, "~> 0.1.0-rc.1"}])
System.put_env("ANTHROPIC_API_KEY", "sk-ant-...")

defmodule MyApp.Tokens do
  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)
  def get(id, name), do: Agent.get(__MODULE__, &Map.get(&1, {id, name}))
  def put(id, name, token), do: Agent.update(__MODULE__, &Map.put(&1, {id, name}, token))
  def delete(id, name), do: Agent.update(__MODULE__, &Map.delete(&1, {id, name}))
end

children = [
  MyApp.Tokens,
  {WardrikCore.Backends.MemoryStore, name: :agents},
  {WardrikCore, backend: {WardrikCore.Backends.MemoryStore, name: :agents}}
]

{:ok, _} = Supervisor.start_link(children, strategy: :rest_for_one)
```

Replace `"sk-ant-..."` with your key.

## A credentials module

This one finds tokens in `MyApp.Tokens`, and sends the person to sign in when there's none yet:

```elixir
defmodule MyApp.Vault do
  @behaviour WardrikCore.Credentials

  @impl true
  def resolve(%{principal: nil}, _opts), do: {:error, "There's no one to act for."}

  def resolve(%{name: name, principal: %WardrikCore.Principal{id: id}}, opts) do
    case MyApp.Tokens.get(id, name) do
      nil -> {:authorize, "#{opts[:base_url]}/connect/#{name}"}
      token -> {:ok, token}
    end
  end

  @impl true
  def refused(%{name: name, principal: %WardrikCore.Principal{id: id}}, _opts),
    do: MyApp.Tokens.delete(id, name)
end
```

Each callback takes a `WardrikCore.Credentials.Request`, naming the credential and the principal,
then your options. `resolve/2` returns one of:

- `{:ok, token}` - the token.
- `{:authorize, url}` - the person must sign in first. The URL is a page in your app that starts
  the provider's OAuth flow for whoever is signed in.
- `{:error, reason}` - it can't help.

`refused/2` is optional. A tool calls it through `WardrikCore.Credentials.refused/2` when a service
rejects a token, such as with a 401. This vault forgets the token, so the next fetch sends the
person to sign in again.

## Using credentials

Give the module to the agent. A tool fetches what it needs:

```elixir
defmodule MyApp.Issues do
  @behaviour WardrikCore.Capability

  @impl true
  def tools(_context, _opts) do
    [
      WardrikCore.Tool.new!(
        name: "create_issue",
        description: "Open a GitHub issue.",
        schema: [title: [type: :string, required: true]],
        run: fn %{title: title}, context ->
          with {:ok, _token} <- WardrikCore.Credentials.fetch(context, "github") do
            # Call GitHub's API with the token here.
            {:ok, "Opened \"#{title}\"."}
          end
        end
      )
    ]
  end
end

{:ok, agent} =
  WardrikCore.start_agent(
    agent_id: "support",
    model: "anthropic:claude-haiku-4-5",
    capabilities: [MyApp.Issues],
    credentials: {MyApp.Vault, base_url: "https://app.example.com"}
  )

maria = %WardrikCore.Principal{id: "user:maria", attributes: %{org: "acme"}}
:ok = WardrikCore.ask(agent, "Open an issue for the login bug.", %{principal: maria})
```

Credentials are never kept in the context, so they're never saved or emitted.

## Signing in

Maria has no GitHub token yet, so the call parks on a `WardrikCore.Authorization`. It holds the
`url`, the `credential` and the `principal`, so you can show the right person where to sign in:

```elixir
{:tool_calls, [{_call, {:park, %WardrikCore.Authorization{url: url}}}]} =
  WardrikCore.parked(agent)

url
#=> "https://app.example.com/connect/github"
```

1. Remember which agent asked, such as in the OAuth `state` your app signs.
2. In the callback, store the token in `MyApp.Tokens`.
3. Resume that agent. Its id finds it on any node in the cluster. The call runs again, this time
   with the token:

```elixir
:ok = MyApp.Tokens.put("user:maria", "github", "gho_...")

{"support", nil}
|> WardrikCore.whereis()
|> WardrikCore.resume(%{}, %{by: maria})
```

Another agent parked on the same sign-in still shows its own link. When the person opens it, your
app finds the token already stored and resumes that agent straight away. They only sign in once.

To watch who's waiting on what, such as for a dashboard or an alert, handle
`[:wardrik_core, :turn, :stop]`. It carries a parked turn's `reason`. Handlers run in the agent's
own process, so use them to watch, not to resume agents.

## Keys

Credentials are what a tool needs to act as a person. Keys are what your code needs as itself: a
model provider's key, or a search API's. Give the agent a `WardrikCore.Keys` module. This one
reads the environment:

```elixir
defmodule MyApp.Keys do
  @behaviour WardrikCore.Keys

  @impl true
  def fetch(%WardrikCore.Keys.Request{name: name}, _opts), do: System.fetch_env(name)
end

:ok = WardrikCore.configure(agent, keys: MyApp.Keys)
```

Keys are fetched by name, for the agent's principal, so an org can bring its own.

- Every model call fetches its provider's key by the name ReqLLM gives it, such as
  `ANTHROPIC_API_KEY`, and passes it to that call only.
- A capability or middleware fetches with `WardrikCore.Keys.fetch(context, "BRAVE_API_KEY")`.
- If no key is held, ReqLLM finds one in its config or the environment.

Keep keys apart from credentials. A credential's name comes from what an agent's owner configures.
A key's name never should.
