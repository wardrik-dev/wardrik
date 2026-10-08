# wardrik_policy

Policies for [Wardrik](../wardrik) agents, written as data: the tools an agent
may call, the ones that ask a person first, the ones it may not call at all,
and what it may spend on models.

```elixir
def deps do
  [{:wardrik_policy, "~> 0.1.0"}]
end
```

```elixir
policy =
  WardrikPolicy.decode!(%{
    "allow" => ["web_search", "linear/*"],
    "ask" => %{"github/create_*" => "This opens an issue on GitHub."},
    "deny" => ["run_lua"],
    "default" => "allow"
  })

Wardrik.Fleet.spawn(id, config: config, hooks: WardrikPolicy.hooks(policy))
```

In the daemon, the same policy is a file in `policies/` that agents name:

```yaml
# ~/.config/wardrik/policies/careful.yaml
allow: [web_search, linear/*]
ask:
  github/create_*: This opens an issue on GitHub.
deny: [run_lua]
default: allow
```

The strictest rule that names a call decides it: deny over ask over allow. A
call a rule asks about waits until a person answers it. A rule can name what
a call acts on, for a tool that says, as `write_file(notes/*)`.

Some tools are gated, and wait on a person unless an `allow` rule names them.
A turn carries the labels of what it has read. Once it carries `outside`,
content such as a page a search found or an issue anyone could have filed,
gated tools wait on a person however the rules allow them, since what the turn
read may be what asked for the call. `allow_after` names, for a label, the
tools that may go ahead even then:

```yaml
allow: [linear/*, github/*]
allow_after:
  outside: [github/add_labels]
```

A label `allow_after` names holds gated tools the same way. Any other label is
carried and shown, and holds nothing.

## Budgets

A policy can limit what an agent spends on model calls, in dollars, in tokens,
or both:

```yaml
budget:
  usd: 5.00
  tokens: 200000
  per: day            # turn, day, week, month or total
  on_exhausted: ask   # or deny
```

Budgets are kept by meters in the fleet, so start `WardrikPolicy.Supervisor`
after Wardrik in your tree:

```elixir
children = [Wardrik, WardrikPolicy.Supervisor]
```
