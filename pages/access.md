# Who may do what

Every operation runs in a scope: on whose behalf it acts, who acts, and what they know. Your app
decides what each scope may do, with a `Wardrik.Authorizer`. Wardrik keeps no grants or roles of
its own.

> See it in action: [Who may do what](../notebooks/access-demo.livemd)

## Setup

In a fresh IEx session, write an authorizer and start Wardrik with it. Your app knows who belongs
to which org, and which org each agent is in, so the authorizer looks that up, never reading it
from an ID. Maps stand in for your tables here:

```elixir
Mix.install([{:wardrik, "~> 0.1.0-rc.2"}])

defmodule MyApp.Authorizer do
  @behaviour Wardrik.Authorizer

  alias Wardrik.Authorizer.Request

  # Who belongs to which org: people, chat members, and the org itself, for its own agents.
  @orgs %{
    "acme" => "acme",
    "acme/@maria" => "acme",
    "acme/@jon" => "acme",
    "globex/@sam" => "globex",
    "slack:T0123/U024BE7LH" => "acme"
  }

  # Which org each agent is in.
  @agents %{"acme/triage" => "acme", "acme/@maria/books" => "acme"}

  @operators ["acme/@maria"]

  @impl true
  def authorize(%Request{resource: {:agent, id}} = request, _opts) do
    with :ok <- same_org(request.principal.id, Wardrik.AgentID.agent(id)), do: allowed(request)
  end

  def authorize(%Request{resource: {:deployment, _name}, principal: %{id: id}}, _opts)
      when id in @operators,
      do: :ok

  def authorize(%Request{resource: {:owner, owner}, principal: %{id: owner}}, _opts), do: :ok

  def authorize(_request, _opts), do: {:error, :forbidden}

  defp same_org(principal, agent) do
    case {Map.fetch(@orgs, principal), Map.fetch(@agents, agent)} do
      {{:ok, org}, {:ok, org}} -> :ok
      _other -> {:error, :not_found}
    end
  end

  # Agents never forget agents, whoever they act for.
  defp allowed(%Request{actor: {:agent, _id}, action: "agent.forget"}), do: {:error, :forbidden}

  # In a chat, only an approver or whoever asked decides.
  defp allowed(%Request{actor: {:channel, _name}, action: "agent.decide"} = request) do
    if request.context[:approver] || request.context[:asked_by] == request.principal.id,
      do: :ok,
      else: {:error, :forbidden}
  end

  defp allowed(_request), do: :ok
end

{:ok, _} = Wardrik.start_link(name: MyApp.AgentRuntime, authorizer: {MyApp.Authorizer, []})
maria = Wardrik.as(MyApp.AgentRuntime, "acme/@maria")

{:ok, _} = Wardrik.Agent.define(maria, "acme/@maria/books", model: "anthropic:claude-haiku-4-5")
```

`:authorizer` is required. Wardrik won't start without one.

## Scopes

`Wardrik.as/3` takes Wardrik and a principal: an ID, or a `Wardrik.principal/2` with attributes
your authorizer reads. In your app, `MyApp.AgentRuntime.as/2` fills in Wardrik:

```elixir
jon = Wardrik.as(MyApp.AgentRuntime, "acme/@jon")

{:ok, _agent} = Wardrik.Agent.read(jon, "acme/@maria/books")
```

It also takes:

  * `:actor` - who acts for the principal, as `{:agent, id}` or `{:channel, name}`. `nil`, the
    principal itself, unless set.
  * `:context` - what the actor knows that the authorizer may read. `%{}` unless set.

Wardrik sets both for agents and channels. See [Agents](#agents) and [Channels](#channels).

## The authorizer

`c:Wardrik.Authorizer.authorize/2` takes a `Wardrik.Authorizer.Request`:

  * `:principal` - on whose behalf it acts, as RFC 8693's `sub`.
  * `:actor` - who acts, as RFC 8693's `act`, or `nil`.
  * `:action` - what it does, as `"agent.ask"`.
  * `:resource` - what it acts on, as `{kind, id}`.
  * `:context` - the scope's context, and an owner's item's `:name`.
  * `:scope` - the `Wardrik.Scope` acting.

| Resource | Is | Actions |
| --- | --- | --- |
| `{:agent, id}` | an agent or one of its conversations, by ID | `agent.read`, `agent.events`, `agent.ask`, `agent.cancel`, `agent.clear`, `agent.decide`, `agent.define`, `agent.spawn`, `agent.stop`, `agent.forget`, `agent.serve` |
| `{:deployment, name}` | the deployment, by Wardrik's `:deployment` | `deployment.audit`, `deployment.nodes`, `deployment.move`, `deployment.reload` |
| `{:owner, owner}` | an org's or person's providers, MCP servers, notify targets and connections | `provider.add`, `mcp_server.read`, `mcp_server.add`, `connection.connect`, ... |

A conversation's ID is its agent's plus one segment. `Wardrik.AgentID.agent/1` returns the agent's.

It returns:

  * `:ok` - allowed.
  * `{:error, :not_found}` - the principal can't see the resource. The caller learns nothing about
    it.
  * `{:error, :forbidden}` - it can see it, but may not take the action.

Return `not_found` for what a principal can't see, so it can't tell what exists:

```elixir
sam = Wardrik.as(MyApp.AgentRuntime, "globex/@sam")

Wardrik.Agent.read(sam, "acme/@maria/books")
#=> {:error, %Wardrik.Error{type: :not_found, message: "There's no agent acme/@maria/books."}}
```

## Operations over many agents

`agents.list`, `agents.cancel`, `agents.forget`, `interrupts.list`, `events.list` and
`events.head` ask the authorizer once per agent, with the action each takes on it: `agent.read`
to list, `agent.events` to read events. Agents it refuses are left out, as if they weren't there:

```elixir
Wardrik.Agents.list(jon)
#=> {:ok, [%Wardrik.Agent{id: "acme/@maria/books", ...}]}

Wardrik.Agents.list(sam)
#=> {:ok, []}
```

`agents:` names exact agent IDs. Every agent the scope may see unless set:

```elixir
Wardrik.Events.list(maria, agents: ["acme/@maria/books"])
```

`deployment.reload` asks once, on `{:deployment, name}`, and takes `agents:` the same way.

## Agents

An agent's `agents/*` and `self/*` tools, from `Wardrik.AgentTools`, act for the principal its
`Wardrik.Resolver` gives it, with the agent as actor. Without a resolver, that's its owner: `acme`
for `acme/triage`, `acme/@jon` for `acme/@jon/notes`. An agent answering another, through
`Wardrik.Delegation`, acts the same way. An agent that resolves to no principal can't use those
tools.

Here's the scope `acme/triage` acts in:

```elixir
triage = Wardrik.as(MyApp.AgentRuntime, "acme", actor: {:agent, "acme/triage"})

{:ok, _agent} = Wardrik.Agent.read(triage, "acme/@maria/books")

Wardrik.Agent.forget(triage, "acme/@maria/books")
#=> {:error, %Wardrik.Error{type: :forbidden, message: "You may not do this to the agent acme/@maria/books."}}
```

The actor lets your authorizer give an agent less than the principal it acts for.

## Channels

A chat member acts as themselves, as `slack:T0123/U024BE7LH`, with the channel as actor,
`{:channel, "slack"}`. The context has `:installation`, as `%{owner: owner, workspace: workspace}`.
Deciding a call adds:

  * `:asked_by` - the principal ID that asked in the conversation, where known.
  * `:approver` - whether the member is one of the installation's approvers.

The channel builds the scope. Built by hand, it shows what the authorizer above sees:

```elixir
member =
  Wardrik.as(MyApp.AgentRuntime, "slack:T0123/U024BE7LH",
    actor: {:channel, "slack"},
    context: %{
      installation: %{owner: "acme", workspace: "T0123"},
      asked_by: "slack:T0123/U0G9QF9C6",
      approver: false
    }
  )

Wardrik.Agent.approve(member, agent: "acme/@maria/books", interrupt: "toolu_01")
#=> {:error, %Wardrik.Error{type: :forbidden, message: "You may not do this to the agent acme/@maria/books."}}
```

## Over HTTP

Wardrik issues no tokens. Your app's sessions or tokens are the credential, and a
`WardrikHTTP.Authenticator` turns each request into a scope:

```elixir
defmodule MyAppWeb.WardrikSession do
  @behaviour WardrikHTTP.Authenticator

  @impl true
  def authenticate(%{conn: conn, wardrik: wardrik}, _opts) do
    with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
         {:ok, id} <- Phoenix.Token.verify(MyAppWeb.Endpoint, "wardrik", token, max_age: 86_400) do
      {:ok, Wardrik.as(wardrik, id)}
    else
      _not_signed_in -> {:error, Wardrik.Error.new(:unauthorized, "Sign in first.")}
    end
  end
end
```

`Wardrik.HTTP` requires one:

```elixir
children = [
  MyApp.AgentRuntime,
  {Wardrik.HTTP,
   wardrik: MyApp.AgentRuntime, authenticator: {MyAppWeb.WardrikSession, []}, port: 4000}
]
```

Or from your router:

```elixir
forward "/agents", Wardrik.HTTP,
  wardrik: MyApp.AgentRuntime,
  authenticator: {MyAppWeb.WardrikSession, []}
```

It's called again while an event stream or worker socket stays open, and the connection closes
once it returns an error. The authorizer decides the rest, as for any scope.
