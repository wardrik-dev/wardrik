# Credentials

A tool that acts as a person needs their token. You write a `WardrikCore.Credentials` module that
finds it.

Run the [setup](running-agents.md#setup) in IEx first. `MyApp.Tokens` stands in for your app's
token table:

```elixir
defmodule MyApp.Tokens do
  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)
  def get(id, name), do: Agent.get(__MODULE__, &Map.get(&1, {id, name}))
  def put(id, name, token), do: Agent.update(__MODULE__, &Map.put(&1, {id, name}, token))
  def delete(id, name), do: Agent.update(__MODULE__, &Map.delete(&1, {id, name}))
end

{:ok, _} = MyApp.Tokens.start_link([])
```

## A credentials module

```elixir
defmodule MyApp.Vault do
  @behaviour WardrikCore.Credentials

  @impl true
  def resolve(%{principal: nil}, _opts), do: {:error, "There's no one to act for."}

  def resolve(%{name: name, principal: %{id: id}}, opts) do
    case MyApp.Tokens.get(id, name) do
      nil -> {:authorize, "#{opts[:base_url]}/connect/#{name}"}
      token -> {:ok, token}
    end
  end

  @impl true
  def refused(%{name: name, principal: %{id: id}}, _opts), do: MyApp.Tokens.delete(id, name)
end
```

`resolve/2` returns:

- `{:ok, token}`.
- `{:authorize, url}`: the person must sign in first, at a page in your app.
- `{:error, reason}`.

`refused/2` is optional. A tool calls `WardrikCore.Credentials.refused/2` when a service rejects
a token, such as with a 401.

## Use it from a tool

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

maria = %WardrikCore.Principal{id: "user:maria"}
:ok = WardrikCore.ask(agent, "Open an issue for the login bug.", %{principal: maria})
```

Tokens are never saved with the agent or sent in events.

## Signing in

Maria has no token yet, so the call waits on a `WardrikCore.Authorization`:

```elixir
{:tool_calls, [{_call, {:park, %WardrikCore.Authorization{url: url}}}]} =
  WardrikCore.parked(agent)

url
#=> "https://app.example.com/connect/github"
```

Show her the URL. When your OAuth callback has the token, store it and resume the agent:

```elixir
:ok = MyApp.Tokens.put("user:maria", "github", "gho_...")

"support"
|> WardrikCore.whereis()
|> WardrikCore.resume(%{}, %{by: maria})
```

- The call runs again, now with the token.
- Keep the agent's ID in the OAuth `state`, so the callback knows which agent to resume.

## Keys

Keys are your app's own API keys, such as a model provider's. Give the agent a `WardrikCore.Keys`
module:

```elixir
defmodule MyApp.Keys do
  @behaviour WardrikCore.Keys

  @impl true
  def fetch(%WardrikCore.Keys.Request{name: name}, _opts) do
    case System.fetch_env(name) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, :not_found}
    end
  end
end

:ok = WardrikCore.configure(agent, keys: MyApp.Keys)
```

- Each model call fetches its provider's key, such as `ANTHROPIC_API_KEY`.
- Your code fetches others with `WardrikCore.Keys.fetch(context, "BRAVE_API_KEY")`.
- With no key, ReqLLM falls back to its config and the environment.
