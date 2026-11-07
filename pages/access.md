# Who may do what

> See it in action: [Operation authorization](../notebooks/access-demo.livemd)

Wardrik asks your app before every operation. You write an authorizer module that answers yes or
no. Wardrik keeps no roles of its own.

## Setup

Maps stand in for your tables:

```elixir
Mix.install([{:wardrik, "~> 0.1.0-rc.8"}])

defmodule MyApp.Authorizer do
  @behaviour Wardrik.Authorizer

  alias Wardrik.Authorizer.Request

  @teams %{"maria" => "acme", "jon" => "acme", "sam" => "globex"}
  @agents %{"agt_books" => "acme", "agt_triage" => "acme"}
  @operators ["maria"]

  @impl true
  def authorize(%Request{resource: {:agent, id}, principal: %{id: who}} = request, _opts) do
    if @agents[id] && @agents[id] == @teams[who], do: allowed(request), else: {:error, :not_found}
  end

  def authorize(%Request{resource: {:deployment, _}, principal: %{id: id}}, _opts)
      when id in @operators,
      do: :ok

  def authorize(_request, _opts), do: {:error, :forbidden}

  # Agents never forget agents.
  defp allowed(%Request{actor: {:agent, _}, action: "agent.forget"}), do: {:error, :forbidden}

  # In a chat, only an operator or whoever asked decides.
  defp allowed(%Request{actor: {:channel, _}, action: "agent.decide"} = request) do
    if request.principal.id in [request.context[:asked_by] | @operators],
      do: :ok,
      else: {:error, :forbidden}
  end

  defp allowed(_request), do: :ok
end

# Every agent works for Maria.
defmodule MyApp.Agents do
  @behaviour Wardrik.Resolver
  def resolve(_request, _opts), do: {:ok, %Wardrik.Resolved{principal: Wardrik.principal("maria")}}
end

{:ok, _} =
  Wardrik.start_link(
    name: MyApp.AgentRuntime,
    authorizer: {MyApp.Authorizer, []},
    resolver: {MyApp.Agents, []}
  )

maria = Wardrik.as(MyApp.AgentRuntime, "maria")
{:ok, _} = Wardrik.Agent.define(maria, "agt_books", model: "anthropic:claude-haiku-4-5")
```

`:authorizer` is required.

## Scopes

```elixir
jon = Wardrik.as(MyApp.AgentRuntime, "jon")
{:ok, _agent} = Wardrik.Agent.read(jon, "agt_books")

sam = Wardrik.as(MyApp.AgentRuntime, "sam")
Wardrik.Agent.read(sam, "agt_books")
#=> {:error, %Wardrik.Error{type: :not_found, message: "There's no agent agt_books."}}
```

`Wardrik.as/3` takes an ID or a `Wardrik.principal/2`, and:

- `:actor` - who acts for that person, as `{:agent, id}` or `{:channel, name}`. Wardrik sets it
  for agents and chat members.
- `:context` - what your authorizer may read. `%{}` unless set.

## The authorizer

`c:Wardrik.Authorizer.authorize/2` gets a `Wardrik.Authorizer.Request` and returns:

- `:ok` - allowed.
- `{:error, :not_found}` - they can't see it. Return this for what they mustn't know exists.
- `{:error, :forbidden}` - they see it, but may not do this.

| Resource | Actions |
| --- | --- |
| `{:agent, id}` | `agent.read`, `agent.events`, `agent.ask`, `agent.cancel`, `agent.clear`, `agent.decide`, `agent.define`, `agent.spawn`, `agent.stop`, `agent.forget`, `agent.serve` |
| `{:deployment, name}` | `deployment.audit`, `deployment.nodes`, `deployment.move`, `deployment.reload` |

- An agent's conversations are authorized as the agent.
- `{:deployment, name}` names Wardrik's `:deployment`.

## Many agents

`agents.list`, `agents.cancel`, `agents.forget`, `interrupts.list` and `events.*` ask once per
agent, and leave out what's refused:

```elixir
Wardrik.Agents.list(jon)
#=> {:ok, [%Wardrik.Agent{id: "agt_books", ...}]}

Wardrik.Agents.list(sam)
#=> {:ok, []}

Wardrik.Events.list(maria, agents: ["agt_books"])
```

## Agents

An agent's `agents/*` and `self/*` tools act for the person your resolver gives it, with
`actor: {:agent, id}`. This is the scope `agt_triage` acts in:

```elixir
triage = Wardrik.as(MyApp.AgentRuntime, "maria", actor: {:agent, "agt_triage"})

{:ok, _agent} = Wardrik.Agent.read(triage, "agt_books")

Wardrik.Agent.forget(triage, "agt_books")
#=> {:error, %Wardrik.Error{type: :forbidden, message: "You may not do this to the agent agt_books."}}
```

- `:actor` lets your authorizer give an agent less than the person it works for.
- An agent that works for nobody can't use those tools.

## Channels

A chat member acts as whoever `WardrikChannel.Identities` says, with `actor: {:channel, name}`.
The context has `:installation`, and `:asked_by` when deciding:

```elixir
member =
  Wardrik.as(MyApp.AgentRuntime, "jon",
    actor: {:channel, "slack"},
    context: %{installation: %{owner: "acme", workspace: "T0123"}, asked_by: "ana"}
  )

Wardrik.Agent.approve(member, agent: "agt_books", interrupt: "toolu_01")
#=> {:error, %Wardrik.Error{type: :forbidden, message: "You may not do this to the agent agt_books."}}
```

## Over HTTP

Your app's sessions or tokens are the credential. A `WardrikHTTP.Authenticator` turns each
request into a scope:

```elixir
defmodule MyAppWeb.WardrikSession do
  @behaviour WardrikHTTP.Authenticator

  @impl true
  def authenticate(%{conn: conn, wardrik: wardrik}, _opts) do
    with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
         {:ok, id} <- Phoenix.Token.verify(MyAppWeb.Endpoint, "wardrik", token, max_age: 86_400) do
      {:ok, Wardrik.as(wardrik, id)}
    else
      _ -> {:error, Wardrik.Error.new(:unauthorized, "Sign in first.")}
    end
  end
end

# In your router
forward "/agents", Wardrik.HTTP,
  wardrik: MyApp.AgentRuntime,
  authenticator: {MyAppWeb.WardrikSession, []}
```

It runs again while a stream or worker socket stays open. See `Wardrik.HTTP`.
