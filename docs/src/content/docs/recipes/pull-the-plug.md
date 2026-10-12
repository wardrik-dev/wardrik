---
title: Pull the plug, then press stop
description: Kill -9 the node an agent runs on while it sets up two new hires, and it finishes without doing any step twice. Stop it on purpose, and it stays stopped, even when its node is lost too.
sidebar:
  order: 7
---

An agent is setting up two new hires for their first day: their accounts, a laptop each and a
welcome email. That work should get finished, and each step done once: nobody wants a second laptop
on the way or two welcome emails. Part way through, you kill the node the agent runs on with
`kill -9`. It carries on on another node and finishes, with ten changes made for the eleven calls
it was sent.

Then you stop it on purpose. It stops within two seconds, and when you kill its node as well it
comes back on another node idle, and does nothing more. Losing a machine does not change what the
agent was asked to do; a stop does.

It takes a three-node cluster on one machine, and `examples/onboarding.ts` in the SDK.

## What it takes

- the `wardrik` command, [installed](/getting-started/install/), and a model provider's key;
- Node 22.18 or later, and a copy of the repository for the SDK's example.

## Three nodes

Run the demo apart from any daemon you already have, with directories of its own and the HTTP API
on another port:

```sh
export XDG_CONFIG_HOME=~/plug/config XDG_DATA_HOME=~/plug/data XDG_STATE_HOME=~/plug/state
mkdir -p ~/plug/config/wardrik
cat > ~/plug/config/wardrik/config.yaml <<'EOF'
cluster:
  nodes: [a, b, c]
http:
  port: 4848
  trusted_workers: true
EOF
```

`trusted_workers` says what tool workers answer is the deployment's own, as the example's is: it
plays your IT system.

Start the nodes with your provider's key in the shell, and make a token for the example:

```sh
export ANTHROPIC_API_KEY=sk-ant-...
wardrik start --node a
wardrik start --node b
wardrik start --node c
wardrik status                     # cluster of 3: a, b, c up
wardrik token create it --scope default/ --unlimited
export TOKEN=wardrik_...
```

## The new hires

In another terminal, from a copy of the repository:

```sh
git clone https://github.com/wardrik-dev/wardrik
cd wardrik/sdks/typescript
npm ci
WARDRIK_URL=http://127.0.0.1:4848 WARDRIK_TOKEN=wardrik_... node examples/onboarding.ts
```

The script plays IT. It offers three tools, `create_account`, `order_laptop` and `send_welcome`,
each taking three seconds a step and each marked `idempotent`. Each changes something, so each is
gated: the agent it defines, `default/onboarding`, has a policy that allows them by name, so they
run without asking. It asks the agent to set up Ana and Ben, and says which node it runs on:

```
[agent] runs on wardrik_c@localhost
[it] google account for Ana...
[it] google account for Ana: done
[it] github account for Ana...
```

## Pull the plug

While a step is running, kill the node the script named, here `c`, from the first terminal:

```sh
kill -9 "$(wardrik pid --node c)"
```

```
[it] laptop for Ana...
[it] laptop for Ana: stopped before it happened

[agent] carries on on wardrik_b@localhost
[it] laptop for Ana...
[it] laptop for Ana: done
[it] welcome email to Ana...
...
[agent] completed
[it] 10 changes made, for 11 calls:
  google account for Ana
  github account for Ana
  slack account for Ana
  laptop for Ana
  ...
```

The node died while Ana's laptop was being ordered. The call's caller died with it, so IT was told
to drop the call, and it did, before the order was placed. The agent came back on `b`, at the round
it was in, and called `order_laptop` again under the same idempotency key; this time it ran. One
laptop each, one welcome email each.

Had the order been placed before the call was dropped, IT would have kept what it did under the
call's key and answered the second call with it, and the laptop would still have been ordered once.
Either way the script's event stream reconnected through another node and carried on from the last
event it had.

Start the node again before going on:

```sh
wardrik start --node c
```

## Press stop

Remove the agent, so that it starts again from nothing rather than remembering it set them up
already, and run the script again:

```sh
curl -X DELETE -H "authorization: Bearer $TOKEN" http://127.0.0.1:4848/v1/agents/default/onboarding
```

This time stop the agent part way, over the HTTP API:

```sh
curl -X POST -H "authorization: Bearer $TOKEN" \
  http://127.0.0.1:4848/v1/agents/default/onboarding/cancel
```

```
[it] github account for Ana...
[it] github account for Ana: done
[agent] cancelled
[it] 2 changes made, for 2 calls:
  google account for Ana
  github account for Ana
[it] still answering calls, until Ctrl-C
```

The step that was running finished, since it had less than two seconds to go; one with longer to
go would have been dropped, as the laptop was. Now kill the node the agent runs on, as before:

```sh
wardrik ls onboarding               # which node
kill -9 "$(wardrik pid --node b)"
wardrik ls onboarding               # idle, on another node
```

The agent starts again on another node, idle. The script is still answering calls, and none
arrives. The turn was stopped, and the store says so: a lost node brings back what the agent was
doing, and it was doing nothing.

A stop:

- ends the turn at its next step, and drops the messages waiting behind it;
- gives a running tool call two seconds to finish, then ends the turn and drops the call, which a
  tool worker sees as its `signal` aborting;
- abandons a turn waiting on a person, without answering it.

The agent answers its next message as usual. The other ways to stop one are the same stop:
`agent.cancel()` in the SDK, and `/stop` in the [terminal client](/guides/tui/), where
`/stop default/` stops every agent under a prefix at once.

## Keeping it stopped

A stop ends what an agent is doing now. To keep it from starting again:

- **Its schedules.** Remove `schedule` from its file and `wardrik reload`, or delete one over the
  HTTP API. See [Run an agent on a schedule](/guides/schedules/#changing-and-removing-schedules).
- **Whoever messages it.** Revoke the token that sends it messages, `wardrik token revoke ID`. See
  [Tokens](/operate/security/#tokens).
- **Its tools.** Revoke a tool worker's token, and its tools are gone from every agent at once; or
  deny a tool in the agent's policy, and `wardrik reload`. See
  [Policy and approvals](/concepts/policy/).
- **Its spending.** A [budget](/concepts/policy/#budgets) with `on_exhausted: deny` ends any turn
  that would spend past it.
- **The agent.** `/shutdown NAME` in the terminal client stops it and keeps its conversation, and
  `DELETE /v1/agents/{key}` removes one the HTTP API defined.

## What happened

- **The agent is a process, and its state is in the store.** Before a turn runs a round of tool
  calls it writes the round down, so the node that holds the agent next carries on from that round
  rather than asking the model again. A stopped turn is written down as stopped. See
  [Durable runs](/concepts/durable-runs/).
- **The ledger.** Every call is claimed before it runs and settled after. A call that finished is
  answered from the ledger without running, marked `"replayed": true`; one that began and never
  finished may have done what it does, so it runs again only where the tool says that is safe, and
  otherwise waits on a person. The three tools say so with `idempotent: true`. See
  [The ledger](/concepts/durable-runs/#the-ledger).
- **Idempotency keys.** Each call has a key that is the same every time it runs. IT keeps what each
  call did under its key, as a provider's API does, so running a call again does nothing again. See
  [Running a call twice](/guides/tool-workers/#running-a-call-twice).
- **Quorum.** With the store on the nodes' disks, two of three carry on. With it in Postgres or a
  bucket, one is enough. See [Run a cluster](/operate/cluster/).

## Taking it further

- Kill the node while the model is answering rather than while a step runs. The agent comes back at
  the round before, and the steps in it are answered from the ledger, marked as replayed, without
  reaching IT at all.
- Take `idempotent: true` off the tools and pull the plug again. The call that was running waits on
  a person instead: `wardrik parked` says it may already have done what it does.
- Run the nodes on three machines with the store in Postgres, and unplug one.

When you are done, stop the script with Ctrl-C, stop the nodes, remove `~/plug`, and open a new
shell, so that the XDG variables are your own again:

```sh
wardrik stop --node a && wardrik stop --node b && wardrik stop --node c
rm -rf ~/plug
```
